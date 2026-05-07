local utils = require("blast_radius.utils")
local config = require("blast_radius.config")

local M = {}

--- Check if any attached LSP client supports call hierarchy
--- @param bufnr? number
--- @return boolean
function M.has_call_hierarchy_support(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if client.server_capabilities and client.server_capabilities.callHierarchyProvider then
      return true
    end
  end

  return false
end

--- Get the symbol text under the cursor using treesitter
--- @param bufnr? number
--- @return string? symbol_name
--- @return { buf: number, line: number, col: number }? position
function M.get_symbol_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local ok_node, node = pcall(function()
    local win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(win)
    return vim.treesitter.get_node({ pos = { cursor[1] - 1, cursor[2] }, bufnr = bufnr })
  end)

  if not ok_node or not node then
    return nil, nil
  end

  local symbol_name = vim.treesitter.get_node_text(node, bufnr)

  local start_row, start_col, _, _ = node:range()
  local position = { buf = bufnr, line = start_row, col = start_col }

  return symbol_name, position
end

--- Make an async LSP request with timeout
--- @param method string LSP method name
--- @param params table LSP parameters
--- @param opts { timeout_ms?: number, on_done: function(result, error) }
function M.lsp_request_async(method, params, opts)
  local timeout_ms = opts.timeout_ms or (config.current and config.current.git.timeout) or 30000
  local done = false
  local timer = nil

  local result_callback = function(result, err)
    if done then
      return
    end
    done = true
    if timer then
      timer:stop()
      timer:close()
    end
    opts.on_done(result, err)
  end

  timer = vim.defer_fn(function()
    if done then
      return
    end
    done = true
    vim.schedule(function()
      opts.on_done(nil, { message = "request_timeout" })
    end)
  end, timeout_ms)

  local clients = vim.lsp.get_clients { bufnr = vim.api.nvim_get_current_buf() }
  if #clients == 0 then
    vim.schedule(function()
      opts.on_done(nil, { message = "no_lsp_client" })
    end)
    timer:stop()
    return
  end

  local active_requests = 0
  for _, client in ipairs(clients) do
    if client.server_capabilities and (client.server_capabilities.callHierarchyProvider or method ~= "callHierarchy/incomingCalls") then
      active_requests = active_requests + 1
      local ok_req, req_err = pcall(function()
        client:request(method, params, result_callback)
      end)
      if not ok_req then
        active_requests = active_requests - 1
        result_callback(nil, { message = req_err })
      end
    end
  end

  if active_requests == 0 then
    vim.schedule(function()
      opts.on_done(nil, { message = "no_capable_client" })
    end)
    timer:stop()
  end
end

--- Generate a unique key for cycle detection from incoming call item
--- @param item table LSP incoming call item
--- @return string
local function make_visited_key(item)
  local from = item.from
  if not from then
    return ""
  end
  local uri = from.uri or ""
  local range = from.selectionRange or from.range
  local line = (range and range.start and range.start.line) or 0
  local char = (range and range.start and range.start.character) or 0
  return string.format("%s:%d:%d", uri, line, char)
end

--- Check if a URI matches any ignore patterns
--- @param uri string
--- @param ignore_patterns string[]
--- @return boolean
local function should_ignore(uri, ignore_patterns)
  local path = uri:gsub("^file://", "")
  for _, pattern in ipairs(ignore_patterns) do
    if path:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

--- Recursive traversal of incoming calls graph
--- @param root_item table LSP call hierarchy item
--- @param ctx { files: table<string, boolean>, edges: table<string, string[]>, visited: table<string, boolean>, depth: number, start_time_sec: number, ignore_patterns: string[], max_depth: number, max_traversal_time_sec: number }
--- @param callback function() Called when traversal is complete
local function traverse_incoming_calls(root_item, ctx, callback)
  utils.stats.start("traverse_incoming")

  local elapsed_sec = (vim.loop.hrtime() / 1e9) - ctx.start_time_sec
  if ctx.max_traversal_time_sec and elapsed_sec >= ctx.max_traversal_time_sec then
    utils.stats.stop("traverse_incoming")
    callback()
    return
  end

  if ctx.depth > ctx.max_depth then
    utils.stats.stop("traverse_incoming")
    callback()
    return
  end

  ctx.depth = ctx.depth + 1

  local root_key = make_visited_key { from = root_item }
  if root_key ~= "" then
    if ctx.visited[root_key] then
      ctx.depth = ctx.depth - 1
      utils.stats.stop("traverse_incoming")
      callback()
      return
    end
    ctx.visited[root_key] = true
  end

  local root_uri = root_item.uri
  if root_uri then
    local path = root_uri:gsub("^file://", "")
    ctx.files[path] = true
  end

  local params = {
    item = root_item,
  }

  M.lsp_request_async("callHierarchy/incomingCalls", params, {
    timeout_ms = (config.current and config.current.git.timeout) or 30000,
    on_done = function(result, err)
      if err then
        ctx.depth = ctx.depth - 1
        utils.stats.stop("traverse_incoming")
        callback()
        return
      end

      if not result or #result == 0 then
        ctx.depth = ctx.depth - 1
        utils.stats.stop("traverse_incoming")
        callback()
        return
      end

      local from_uri = root_uri
      local from_key = from_uri or ""
      if not ctx.edges[from_key] then
        ctx.edges[from_key] = {}
      end

      local pending = 0
      for _, incoming in ipairs(result) do
        local caller = incoming.from
        if not caller then
          goto continue
        end

        local caller_uri = caller.uri
        local caller_path = caller_uri and caller_uri:gsub("^file://", "") or ""

        if caller_path ~= "" and not should_ignore(caller_uri or "", ctx.ignore_patterns) then
          ctx.files[caller_path] = true
          table.insert(ctx.edges[from_key], caller_uri)

          local caller_key = make_visited_key(incoming)
          if not ctx.visited[caller_key] then
            pending = pending + 1
            traverse_incoming_calls(caller, ctx, function()
              pending = pending - 1
              if pending == 0 then
                ctx.depth = ctx.depth - 1
                utils.stats.stop("traverse_incoming")
                callback()
              end
            end)
          end
        end

        ::continue::
      end

      if pending == 0 then
        ctx.depth = ctx.depth - 1
        utils.stats.stop("traverse_incoming")
        callback()
      end
    end,
  })
end

--- Build the dependency graph starting from the symbol at cursor
--- @param opts? { max_depth?: number, ignore_patterns?: string[], max_traversal_time_sec?: number }
--- @param callback function(graph: { files: string[], edges: table<string, string[]>, root_symbol: string, root_file: string })
function M.build_from_cursor(opts, callback)
  opts = opts or {}
  utils.stats.start("build_from_cursor")

  local bufnr = vim.api.nvim_get_current_buf()
  local symbol_name, position = M.get_symbol_at_cursor(bufnr)

  if not symbol_name or not position then
    utils.stats.stop("build_from_cursor")
    callback {
      files = {},
      edges = {},
      root_symbol = "",
      root_file = vim.api.nvim_buf_get_name(bufnr),
    }
    return
  end

  local params = {
    textDocument = vim.lsp.util.make_text_document(bufnr),
    position = {
      line = position.line,
      character = position.col,
    },
  }

  M.lsp_request_async("textDocument/prepareCallHierarchy", params, {
    on_done = function(result, err)
      if err or not result or #result == 0 then
        -- Fallback to includes-based detection
        local ok, includes = pcall(require, "blast_radius.includes")
        if ok and includes and includes.build_from_cursor then
          includes.build_from_cursor(opts, callback)
        else
          utils.stats.stop("build_from_cursor")
          callback {
            files = { vim.api.nvim_buf_get_name(bufnr) },
            edges = {},
            root_symbol = symbol_name,
            root_file = vim.api.nvim_buf_get_name(bufnr),
          }
        end
        return
      end

      local root_item = result[1]
      local ctx = {
        files = {},
        edges = {},
        visited = {},
        depth = 0,
        start_time_sec = vim.loop.hrtime() / 1e9,
        ignore_patterns = opts.ignore_patterns or (config.current and config.current.git.exclude_patterns) or {},
        max_depth = opts.max_depth or 10,
        max_traversal_time_sec = opts.max_traversal_time_sec or 30,
      }

      traverse_incoming_calls(root_item, ctx, function()
        local files = {}
        for path in pairs(ctx.files) do
          table.insert(files, path)
        end

        table.sort(files)

        utils.stats.stop("build_from_cursor")
        callback {
          files = files,
          edges = ctx.edges,
          root_symbol = symbol_name,
          root_file = vim.api.nvim_buf_get_name(bufnr),
        }
      end)
    end,
  })
end

return M
