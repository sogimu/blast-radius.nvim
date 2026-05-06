local M = {}

local function check_ignore_pattern(path, patterns)
  for _, pattern in ipairs(patterns) do
    if path:find(vim.pesc(pattern), 1, true) then
      return true
    end
  end
  return false
end

local function has_lsp_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  return #clients > 0
end

local function build_lsp_graph(bufnr, depth, ignore_patterns, callback)
  local files = {}
  local edges = {}
  local visited = {}

  local function add_file(path)
    if not path or path == "" then return end
    if check_ignore_pattern(path, ignore_patterns) then return end
    for _, f in ipairs(files) do
      if f == path then return end
    end
    table.insert(files, path)
  end

  local function get_outgoing(item, current_depth, on_done)
    if current_depth >= depth then
      on_done()
      return
    end

    local uri = item.uri
    if visited[uri] then
      on_done()
      return
    end
    visited[uri] = true

    local file_path = vim.uri_to_fname(uri)
    add_file(file_path)
    if not edges[file_path] then
      edges[file_path] = {}
    end

    vim.lsp.buf_request(bufnr, "callHierarchy/outgoingCalls", { item = item }, function(err, result)
      if err or not result or vim.tbl_isempty(result) then
        on_done()
        return
      end

      local pending = #result
      if pending == 0 then
        on_done()
        return
      end

      local function handle_one(call_item)
        local target_path = vim.uri_to_fname(call_item.to.uri)
        if not check_ignore_pattern(target_path, ignore_patterns) then
          add_file(target_path)
          table.insert(edges[file_path], target_path)
        end

        if not visited[call_item.to.uri] then
          get_outgoing(call_item.to, current_depth + 1, function()
            pending = pending - 1
            if pending == 0 then on_done() end
          end)
        else
          pending = pending - 1
          if pending == 0 then on_done() end
        end
      end

      for _, call_item in ipairs(result) do
        handle_one(call_item)
      end
    end)
  end

  vim.lsp.buf_request(bufnr, "textDocument/prepareCallHierarchy", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = vim.api.nvim_win_get_cursor(0)[1] - 1, character = vim.api.nvim_win_get_cursor(0)[2] },
  }, function(err, result)
    if err or not result or vim.tbl_isempty(result) then
      callback(nil)
      return
    end

    add_file(vim.uri_to_fname(result[1].uri))

    get_outgoing(result[1], 0, function()
      local seen = {}
      local deduped = {}
      for _, f in ipairs(files) do
        if not seen[f] then
          seen[f] = true
          table.insert(deduped, f)
        end
      end
      callback({ files = deduped, edges = edges })
    end)
  end)
end

local function build_references_graph(bufnr, depth, ignore_patterns, callback)
  local src_bufname = vim.api.nvim_buf_get_name(bufnr)
  local cursor_row, cursor_col = unpack(vim.api.nvim_win_get_cursor(0))
  local cursor_row_0 = cursor_row - 1

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  if #clients == 0 then
    callback(nil)
    return
  end

  local client = clients[1]

  client.request("textDocument/definition", {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = cursor_row_0, character = cursor_col },
  }, function(err, def_result)
    local target_uri
    if def_result and #def_result > 0 then
      target_uri = def_result[1].uri or (def_result[1].targetUri and def_result[1].targetUri)
      if not target_uri and def_result[1].targetRange then
        target_uri = def_result[1].targetUri
      end
    end
    if not target_uri then
      callback(nil)
      return
    end

    local def_path = vim.uri_to_fname(target_uri)

    client.request("textDocument/references", {
      textDocument = { uri = target_uri },
      position = { line = cursor_row_0, character = cursor_col },
      context = { includeDeclaration = true },
    }, function(err2, refs)
      if err2 or not refs or vim.tbl_isempty(refs) then
        callback(nil)
        return
      end

      local files = {}
      local seen = {}

      local function add_ref(filepath)
        if not filepath or filepath == "" then return end
        if check_ignore_pattern(filepath, ignore_patterns) then return end
        if not seen[filepath] then
          seen[filepath] = true
          table.insert(files, filepath)
        end
      end

      table.insert(files, def_path)

      for _, ref in ipairs(refs) do
        local ref_path = vim.uri_to_fname(ref.uri)
        add_ref(ref_path)
      end

      callback({ files = files, edges = {} })
    end)
  end)
end

local function resolve_include_path(include_text, src_bufname)
  local clean_path = include_text:gsub('^"', ""):gsub('"$', ""):gsub("^<", ""):gsub(">$", "")

  if clean_path:sub(1, 1) == "/" then
    return vim.fn.fnamemodify(clean_path, ":p")
  end

  local project_roots = vim.fs.root(vim.fn.expand("%:p"), { ".git", "CMakeLists.txt", "Makefile" }) or {}
  local workspace_root = project_roots[1] or vim.fn.getcwd()

  local direct = vim.fn.fnamemodify(workspace_root .. "/" .. clean_path, ":p")
  if vim.fn.filereadable(direct) ~= 0 then
    return direct
  end

  local buf_dir = vim.fn.fnamemodify(src_bufname, ":h")
  local local_path = vim.fn.fnamemodify(buf_dir .. "/" .. clean_path, ":p")
  if vim.fn.filereadable(local_path) ~= 0 then
    return local_path
  end

  return local_path
end

local function build_treesitter_includes_graph(bufnr, ignore_patterns)
  local files = {}
  local edges = {}
  local src_bufname = vim.api.nvim_buf_get_name(bufnr)

  local function add_file(path)
    if not path or path == "" then return end
    if check_ignore_pattern(path, ignore_patterns) then return end
    for _, f in ipairs(files) do
      if f == path then return end
    end
    table.insert(files, path)
    if not edges[path] then
      edges[path] = {}
    end
  end

  add_file(src_bufname)

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return { files = files, edges = edges }
  end

  local query_str = [[
    (preproc_include
      path: (system_lib_string) @include
    )
    (preproc_include
      path: (string_literal) @include
    )
  ]]

  local ok_parse, query = pcall(vim.treesitter.query.parse, "cpp", query_str)
  if not ok_parse or not query then
    ok_parse, query = pcall(vim.treesitter.query.parse, "c", query_str)
    if not ok_parse or not query then
      return { files = files, edges = edges }
    end
  end

  for line_num = 0, vim.api.nvim_buf_line_count(bufnr) do
    local line = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1]
    if not line then break end

    local raw_path = line:match("#include%s*[\"<]([^\">]+)[\">]")
    if raw_path then
      local resolved = resolve_include_path(raw_path, src_bufname)
      if vim.fn.filereadable(resolved) ~= 0 then
        add_file(resolved)
        if edges[src_bufname] then
          table.insert(edges[src_bufname], resolved)
        end
      end
    end
  end

  return { files = files, edges = edges }
end

function M.build_from_cursor(bufnr, opts, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  opts = opts or {}
  local depth = opts.depth or 3
  local ignore_patterns = opts.ignore_patterns or {}
  local fallback_no_lsp = opts.fallback_no_lsp ~= false

  if has_lsp_client(bufnr) then
    local called_back = false

    local function on_result(result, source)
      if called_back then return end
      called_back = true
      if result and #result.files > 0 then
        callback(result)
      elseif fallback_no_lsp then
        local ts_result = build_treesitter_includes_graph(bufnr, ignore_patterns)
        callback(ts_result)
      else
        callback({ files = {}, edges = {} })
      end
    end

    local timer = vim.uv.new_timer()
    timer:start(4000, 0, function()
      timer:close()
      on_result(nil, "timeout")
    end)

    build_lsp_graph(bufnr, depth, ignore_patterns, function(result)
      if result and #result.files > 0 then
        timer:stop()
        timer:close()
        on_result(result, "call_hierarchy")
      else
        build_references_graph(bufnr, depth, ignore_patterns, function(result)
          if result and #result.files > 1 then
            timer:stop()
            timer:close()
            on_result(result, "references")
          else
            timer:stop()
            timer:close()
            on_result(nil, "empty")
          end
        end)
      end
    end)
  else
    if fallback_no_lsp then
      local ts_result = build_treesitter_includes_graph(bufnr, ignore_patterns)
      callback(ts_result)
    else
      vim.notify("blast-radius.nvim: LSP not available and fallback disabled", vim.log.levels.WARN)
      callback({ files = {}, edges = {} })
    end
  end
end

return M
