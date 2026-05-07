local utils = require("blast_radius.utils")
local config = require("blast_radius.config")

local M = {}

local DEBUG_LOG = "/tmp/blast-radius-debug.log"
local function dlog(msg)
  local f = io.open(DEBUG_LOG, "a")
  if f then
    f:write(os.date("[%H:%M:%S] ") .. msg .. "\n")
    f:close()
  end
end

--- Check if any attached LSP client supports call hierarchy
--- @param bufnr? number
--- @return boolean
function M.has_call_hierarchy_support(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local clients = vim.lsp.get_clients({ bufnr = bufnr })
  dlog("has_call_hierarchy_support: found #" .. #clients .. " clients for bufnr " .. bufnr)
  for _, client in ipairs(clients) do
    local name = client.name or "<unnamed>"
    local has = client.server_capabilities and client.server_capabilities.callHierarchyProvider
    dlog("has_call_hierarchy_support: client=" .. name .. " callHierarchyProvider=" .. tostring(has))
    if client.server_capabilities and client.server_capabilities.callHierarchyProvider then
      dlog("has_call_hierarchy_support: returning true (capable client=" .. name .. ")")
      return true
    end
  end

  dlog("has_call_hierarchy_support: no capable client found, returning false")
  return false
end

--- Get the symbol text under the cursor using treesitter
--- @param bufnr? number
--- @return string? symbol_name
--- @return { buf: number, line: number, col: number }? position
function M.get_symbol_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local row = cursor[1] - 1
  local col = cursor[2]

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok_parser or not parser then
    dlog("get_symbol_at_cursor: parser not found for bufnr " .. bufnr)
    return nil, nil
  end

  local ok_node, node = pcall(vim.treesitter.get_node, { pos = { row, col }, bufnr = bufnr })
  while (ok_node and node) do
    local text = vim.treesitter.get_node_text(node, bufnr)
    dlog("get_symbol_at_cursor: node text=" .. tostring(text))
    if text and text ~= "" and text:match("^[%w_]+$") then
      local start_row, start_col, _, _ = node:range()
      dlog("get_symbol_at_cursor: found valid symbol=" .. text)
      return text, { buf = bufnr, line = start_row, col = start_col }
    end

    local parent = node:parent()
    if not parent then
      dlog("get_symbol_at_cursor: no parent node, stopping walk")
      break
    end
    node = parent
  end

  dlog("get_symbol_at_cursor: no valid symbol found, returning nil")
  return nil, nil
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
    dlog("lsp_request_async: on_done called, err=" .. (err and err.message or "nil"))
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
    dlog("lsp_request_async: timeout reached after " .. timeout_ms .. "ms")
    vim.schedule(function()
      opts.on_done(nil, { message = "request_timeout" })
    end)
  end, timeout_ms)

  local clients = vim.lsp.get_clients { bufnr = vim.api.nvim_get_current_buf() }
  dlog("lsp_request_async: found #" .. #clients .. " clients, method=" .. method)
  if #clients == 0 then
    dlog("lsp_request_async: no clients found, scheduling on_done with no_lsp_client error")
    vim.schedule(function()
      opts.on_done(nil, { message = "no_lsp_client" })
    end)
    timer:stop()
    return
  end

  local active_requests = 0
  for _, client in ipairs(clients) do
    local name = client.name or "<unnamed>"
    local is_call_hierarchy = method:find("^callHierarchy/") ~= nil
    local capable = client.server_capabilities and (client.server_capabilities.callHierarchyProvider or not is_call_hierarchy)
    dlog("lsp_request_async: client=" .. name .. " capable=" .. tostring(capable))
    if capable then
      active_requests = active_requests + 1
      local ok_req, req_err = pcall(function()
        dlog("lsp_request_async: requesting method=" .. method .. " from client=" .. name)
        client:request(method, params, result_callback)
      end)
      if not ok_req then
        dlog("lsp_request_async: pcall failed for client=" .. name .. " err=" .. tostring(req_err))
        active_requests = active_requests - 1
        result_callback(nil, { message = req_err })
      end
    end
  end

  dlog("lsp_request_async: active_requests=" .. active_requests)
  if active_requests == 0 then
    dlog("lsp_request_async: no capable client found, scheduling on_done with no_capable_client error")
    vim.schedule(function()
      opts.on_done(nil, { message = "no_capable_client" })
    end)
    timer:stop()
  end
end

--- Generate a unique key for cycle detection from a CallHierarchyItem
--- @param item table LSP CallHierarchyItem
--- @return string
local function make_visited_key(item)
  local uri = item.uri or ""
  local range = item.selectionRange or item.range
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

--- Recursive traversal of outgoing calls graph (what does this function call?)
--- @param root_item table LSP CallHierarchyItem
--- @param ctx { files: table<string, boolean>, edges: table<string, string[]>, visited: table<string, boolean>, depth: number, start_time_sec: number, ignore_patterns: string[], max_depth: number, max_traversal_time_sec: number }
--- @param callback function() Called when traversal is complete
local function traverse_outgoing_calls(root_item, ctx, callback)
  dlog("traverse_outgoing_calls: entry, depth=" .. ctx.depth .. " item=" .. (root_item.name or "<anonymous>"))
  utils.stats.start("traverse_outgoing")

  local elapsed_sec = (vim.loop.hrtime() / 1e9) - ctx.start_time_sec
  if ctx.max_traversal_time_sec and elapsed_sec >= ctx.max_traversal_time_sec then
    dlog("traverse_outgoing_calls: max traversal time reached, elapsed=" .. string.format("%.2f", elapsed_sec) .. "s")
    utils.stats.stop("traverse_outgoing")
    callback()
    return
  end

  if ctx.depth > ctx.max_depth then
    dlog("traverse_outgoing_calls: max depth reached, depth=" .. ctx.depth .. " max=" .. ctx.max_depth)
    utils.stats.stop("traverse_outgoing")
    callback()
    return
  end

  ctx.depth = ctx.depth + 1

  local root_key = make_visited_key(root_item)
  if root_key ~= "" then
    if ctx.visited[root_key] then
      dlog("traverse_outgoing_calls: cycle detected, key=" .. root_key)
      ctx.depth = ctx.depth - 1
      utils.stats.stop("traverse_outgoing")
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

  M.lsp_request_async("callHierarchy/outgoingCalls", { item = root_item }, {
    timeout_ms = (config.current and config.current.git.timeout) or 30000,
    on_done = function(result, err)
      if err then
        dlog("traverse_outgoing_calls: LSP error=" .. (err.message or "unknown"))
        ctx.depth = ctx.depth - 1
        utils.stats.stop("traverse_outgoing")
        callback()
        return
      end

      if not result or #result == 0 then
        dlog("traverse_outgoing_calls: no outgoing calls for " .. (root_item.name or "<anonymous>"))
        ctx.depth = ctx.depth - 1
        utils.stats.stop("traverse_outgoing")
        callback()
        return
      end

      dlog("traverse_outgoing_calls: processing #" .. #result .. " outgoing calls for " .. (root_item.name or "<anonymous>"))

      local from_key = root_uri or ""
      if not ctx.edges[from_key] then
        ctx.edges[from_key] = {}
      end

      local pending = 0
      for _, outgoing in ipairs(result) do
        local callee = outgoing.to
        if not callee then goto continue end

        local callee_uri = callee.uri
        local callee_path = callee_uri and callee_uri:gsub("^file://", "") or ""

        if callee_path ~= "" and not should_ignore(callee_uri or "", ctx.ignore_patterns) then
          ctx.files[callee_path] = true
          table.insert(ctx.edges[from_key], callee_uri)

          local callee_key = make_visited_key(callee)
          if not ctx.visited[callee_key] then
            pending = pending + 1
            traverse_outgoing_calls(callee, ctx, function()
              pending = pending - 1
              if pending == 0 then
                ctx.depth = ctx.depth - 1
                utils.stats.stop("traverse_outgoing")
                callback()
              end
            end)
          end
        end

        ::continue::
      end

      if pending == 0 then
        ctx.depth = ctx.depth - 1
        utils.stats.stop("traverse_outgoing")
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
  local root_file = vim.api.nvim_buf_get_name(bufnr)

  dlog("build_from_cursor: symbol_name=" .. tostring(symbol_name) .. " position=" .. tostring(position))

  -- Check LSP support
  local has_ch = M.has_call_hierarchy_support(bufnr)
  dlog("build_from_cursor: has_call_hierarchy_support=" .. tostring(has_ch))
  vim.print("[blast-radius] LSP callHierarchy: " .. (has_ch and "yes" or "no") .. ", symbol: " .. (symbol_name or "<none>"))

  if not symbol_name or not position then
    dlog("build_from_cursor: no symbol/position found, falling back to includes")
    vim.print("[blast-radius.graph] Falling back to includes, root_file=" .. root_file)
    local ok, inc_mod = pcall(require, "blast_radius.includes")
    vim.print("[blast-radius.graph] includes pcall: ok=" .. tostring(ok))
    if ok and inc_mod and inc_mod.build_from_file then
      vim.print("[blast-radius.graph] Calling includes.build_from_file(" .. root_file .. ")")
      dlog("build_from_cursor: calling includes.build_from_file(" .. root_file .. ")")
      inc_mod.build_from_file(root_file, opts, callback)
      return
    else
      vim.print("[blast-radius.graph] includes not available - ok=" .. tostring(ok) .. (ok and " has_build_from_file=" .. tostring(inc_mod and inc_mod.build_from_file ~= nil) or ""))
    end

    utils.stats.stop("build_from_cursor")
    callback {
      files = { root_file },
      edges = {},
      root_symbol = "",
      root_file = root_file,
    }
    return
  end

  local params = {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = {
      line = position.line,
      character = position.col,
    },
  }

  M.lsp_request_async("textDocument/prepareCallHierarchy", params, {
    on_done = function(result, err)
      if err or not result or #result == 0 then
        dlog("build_from_cursor: LSP prepareCallHierarchy returned no result, err=" .. (err and err.message or "nil"))
        vim.print("[blast-radius] LSP returned no call hierarchy, falling back to includes")
        -- Fallback to includes-based detection
        local ok, includes = pcall(require, "blast_radius.includes")
        if ok and includes then
          if includes.build_from_file then
            includes.build_from_file(vim.api.nvim_buf_get_name(bufnr), opts, callback)
          elseif includes.build_from_cursor then
            includes.build_from_cursor(opts, callback)
          else
            vim.print("[blast-radius] Includes module has no build_from_file or build_from_cursor")
            utils.stats.stop("build_from_cursor")
            callback {
              files = { vim.api.nvim_buf_get_name(bufnr) },
              edges = {},
              root_symbol = symbol_name,
              root_file = vim.api.nvim_buf_get_name(bufnr),
            }
          end
        else
          vim.print("[blast-radius] Includes module failed to load")
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

      vim.print("[blast-radius] LSP call hierarchy found: " .. (result[1].name or "<anonymous>"))

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

      traverse_outgoing_calls(root_item, ctx, function()
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
