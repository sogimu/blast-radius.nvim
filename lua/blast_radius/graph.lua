local M = {}

M._lsp_available = nil

local function check_ignore_pattern(path, patterns)
  for _, pattern in ipairs(patterns) do
    if path:find(vim.pesc(pattern), 1, true) then
      return true
    end
  end
  return false
end

local function get_node_text(bufnr)
  local cursor_row, cursor_col = unpack(vim.api.nvim_win_get_cursor(0))
  cursor_row = cursor_row - 1

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return vim.fn.expand("<cword>")
  end

  local root = parser:parse()[1]:root()
  local node = root:named_descendant_for_range(cursor_row, cursor_col, cursor_row, cursor_col)
  if node then
    local text = vim.treesitter.get_node_text(node, bufnr)
    if text and #text > 0 then
      return text
    end
  end

  return vim.fn.expand("<cword>")
end

local function has_lsp_client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if client.server_capabilities and client.server_capabilities.callHierarchyProvider then
      return true
    end
  end
  return false
end

local function build_lsp_graph(bufnr, symbol_name, depth, ignore_patterns, callback)
  local files = {}
  local edges = {}
  local visited = {}

  local function dedup()
    local seen = {}
    local result = {}
    for _, f in ipairs(files) do
      if not seen[f] then
        seen[f] = true
        table.insert(result, f)
      end
    end
    return result
  end

  local function get_outgoing(item, current_depth, on_done)
    if current_depth > depth then
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

    if check_ignore_pattern(file_path, ignore_patterns) then
      on_done()
      return
    end

    table.insert(files, file_path)
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

      local function handle_one(call)
        local target_path = vim.uri_to_fname(call.to.uri)
        if not check_ignore_pattern(target_path, ignore_patterns) then
          table.insert(files, target_path)
          table.insert(edges[file_path], target_path)
        end

        if current_depth < depth and not visited[call.to.uri] then
          visited[call.to.uri] = true
          get_outgoing(call.to, current_depth + 1, function()
            pending = pending - 1
            if pending == 0 then on_done() end
          end)
        else
          pending = pending - 1
          if pending == 0 then on_done() end
        end
      end

      for _, call in ipairs(result) do
        handle_one(call)
      end
    end)
  end

  vim.lsp.buf_request(bufnr, "textDocument/prepareCallHierarchy", {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
    position = vim.lsp.util.make_position_params(0, bufnr).position,
  }, function(err, result)
    if err or not result or vim.tbl_isempty(result) then
      callback(nil)
      return
    end

    get_outgoing(result[1], 0, function()
      callback({ files = dedup(), edges = edges })
    end)
  end)
end

local function build_treesitter_graph(bufnr, depth, ignore_patterns, virtual_overrides)
  local files = {}
  local edges = {}
  local src_bufname = vim.api.nvim_buf_get_name(bufnr)

  if not check_ignore_pattern(src_bufname, ignore_patterns) then
    table.insert(files, src_bufname)
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if ok and parser then
    local query = vim.treesitter.query.get(bufnr, "includes")
    if not query then
      local query_dir = debug.getinfo(1, "S").source:match("@?(.*/)")
      local plugin_root = vim.fn.fnamemodify(query_dir .. "../../../..", ":p")
      local includes_scm_path = plugin_root .. "queries/cpp/includes.scm"

      if vim.uv.fs_stat(includes_scm_path) then
        local f = io.open(includes_scm_path, "r")
        if f then
          local query_str = f:read("*all")
          f:close()
          query = vim.treesitter.query.parse("cpp", query_str)
        end
      end
    end

    if query then
      local root = parser:parse()[1]:root()
      for _, match in query:iter_matches(root, bufnr, 0, -1) do
        for id, node in pairs(match) do
          local name = query.captures[id]
          if name == "include.path" then
            local path = vim.treesitter.get_node_text(node, bufnr)
            path = path:gsub('"', ""):gsub("<", ""):gsub(">", "")

            local include_path = path
            if not vim.uv.fs_stat(include_path) then
              local buf_dir = vim.fn.fnamemodify(src_bufname, ":h")
              include_path = buf_dir .. "/" .. path
            end

            if vim.uv.fs_stat(include_path) and not check_ignore_pattern(include_path, ignore_patterns) then
              table.insert(files, include_path)

              if not edges[src_bufname] then
                edges[src_bufname] = {}
              end
              table.insert(edges[src_bufname], include_path)
            end
          end
        end
      end
    end
  end

  for base_class, derived_classes in pairs(virtual_overrides) do
    for _, derived in ipairs(derived_classes) do
      if not edges[src_bufname] then
        edges[src_bufname] = {}
      end
      table.insert(edges[src_bufname], derived)
      for _, f in ipairs(files) do
        if f:find(derived, 1, true) then
          goto continue
        end
      end
      table.insert(files, derived)
      ::continue::
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
  local virtual_overrides = opts.virtual_overrides or {}

  if has_lsp_client(bufnr) then
    local symbol_name = get_node_text(bufnr)
    local timeout_reached = false

    local timeout_timer = vim.uv.new_timer()
    timeout_timer:start(3000, 0, function()
      timeout_reached = true
      timeout_timer:close()
    end)

    build_lsp_graph(bufnr, symbol_name, depth, ignore_patterns, function(lsp_result)
      timeout_timer:stop()
      if not timeout_reached and lsp_result and not vim.tbl_isempty(lsp_result.files) then
        callback(lsp_result)
        return
      end

      if fallback_no_lsp then
        local ts_result = build_treesitter_graph(bufnr, depth, ignore_patterns, virtual_overrides)
        callback(ts_result)
      else
        callback({ files = {}, edges = {} })
      end
    end)
  else
    if fallback_no_lsp then
      local ts_result = build_treesitter_graph(bufnr, depth, ignore_patterns, virtual_overrides)
      callback(ts_result)
    else
      vim.notify("blast-radius.nvim: LSP not available and fallback disabled", vim.log.levels.WARN)
      callback({ files = {}, edges = {} })
    end
  end
end

return M