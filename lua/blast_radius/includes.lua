local utils = require("blast_radius.utils")
local config = require("blast_radius.config")

local M = {}

local DEBUG_LOG = "/tmp/blast-radius-debug.log"
local function dlog(msg)
  local f = io.open(DEBUG_LOG, "a")
  if f then
    f:write(os.date("[%H:%M:%S] ") .. "[includes] " .. msg .. "\n")
    f:close()
  end
end

local LANG_QUERIES = {
  c = "includes",
  cpp = "includes",
  python = "imports",
  rust = "uses",
}

local INCLUDE_EXTENSIONS = {
  c = { "c", "h" },
  cpp = { "cpp", "cxx", "cc", "h", "hpp", "hxx" },
  python = { "py" },
  rust = { "rs" },
}

local function get_file_ext(path)
  return path:match("%.([^%.]+)$")
end

--- Parse include directives from a buffer using Treesitter
--- @param bufnr number
--- @param lang string
--- @return string[] includes List of include/import paths
function M.parse_includes(bufnr, lang)
  local query_file = LANG_QUERIES[lang]
  if not query_file then
    return {}
  end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
  if not ok_parser or not parser then
    vim.print("[blast-radius:includes] Treesitter parser unavailable for bufnr: " .. bufnr)
    return {}
  end

  local query_str
  local plugin_root = debug.getinfo(1, "S").source:sub(2):match("(.*)/lua/.*"):gsub("/blast_radius$", "")
  local query_path = plugin_root .. "/queries/" .. lang .. "/" .. query_file .. ".scm"
  dlog("plugin_root=" .. tostring(plugin_root) .. " query_path=" .. tostring(query_path))

  local f = io.open(query_path, "r")
  if f then
    query_str = f:read("*all")
    f:close()
    vim.print("[includes] Query loaded from file: " .. query_path)
  else
    vim.print("[includes] Query file NOT found: " .. query_path)
    local ok_query, ts_query = pcall(vim.treesitter.query.parse, lang, query_file)
    if ok_query and ts_query then
      local tree = parser:parse()[1]
      local includes = {}
      for id, node in ts_query:iter_captures(tree:root(), bufnr) do
        local capture = ts_query.captures[id]
        local text = vim.treesitter.get_node_text(node, bufnr)
        if capture then
          text = text:gsub('^["\'<>]', ""):gsub('["\'<>]$', "")
          text = text:gsub("^::", "")
          text = text:gsub("\n$", "")
          table.insert(includes, text)
        end
      end
      vim.print("[includes] Parsed " .. #includes .. " includes: " .. vim.inspect(includes))
      return includes
    end
    return {}
  end

  local ok_query, ts_query = pcall(vim.treesitter.query.parse, lang, query_str)
  if not ok_query or not ts_query then
    vim.print("[blast-radius:includes] Query parse failed for lang: " .. lang)
    return {}
  end

  local tree = parser:parse()[1]
  local includes = {}

  for id, node in ts_query:iter_captures(tree:root(), bufnr) do
    local text = vim.treesitter.get_node_text(node, bufnr)
    if text then
      text = text:gsub('^["\'<>]', ""):gsub('["\'<>]$', "")
      text = text:gsub("^::", "")
      text = text:gsub("\n$", "")
      table.insert(includes, text)
    end
  end

  vim.print("[includes] Parsed " .. #includes .. " includes: " .. vim.inspect(includes))

  return includes
end

--- Get git root synchronously (cached per call site)
--- @return string|nil
local function get_git_root()
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if not handle then return nil end
  local line = handle:read("*l")
  handle:close()
  if line and line ~= "" then
    return line:gsub("\r\n?$", ""):gsub("\\", "/")
  end
  return nil
end

--- Resolve an include path to an actual file.
--- Searches: beside source, common sibling dirs walking up to git root, git root itself.
--- @param include string Include path string
--- @param source_file string The file that contains the include
--- @param lang string Language
--- @param git_root string|nil Pre-computed git root (optional, avoids repeated shell calls)
--- @return string|nil resolved_path The resolved file path
function M.resolve_include_path(include, source_file, lang, git_root)
  if not include or include == "" then
    return nil
  end

  include = include:gsub("\\", "/"):gsub("[\r\n]", "")
  local source_dir = source_file:match("(.*)[/\\]") or "."

  local search_paths = {
    include,
    source_dir .. "/" .. include,
  }

  local root = git_root or get_git_root()
  if root and root ~= "" then
    table.insert(search_paths, root .. "/" .. include)

    -- Walk from source_dir up to git root, checking sibling include dirs at each level
    local siblings = { "include", "headers", "inc", "public" }
    local cur = source_dir
    for _ = 1, 8 do
      local parent = cur:match("(.*)[/\\]")
      if not parent or parent == cur then break end
      for _, sibling in ipairs(siblings) do
        table.insert(search_paths, parent .. "/" .. sibling .. "/" .. include)
      end
      if cur == root then break end
      cur = parent
    end
  end

  for _, search_path in ipairs(search_paths) do
    local stat = vim.loop.fs_stat(search_path)
    if stat and stat.type == "file" then
      return search_path
    end
  end

  return nil
end

--- Get the Treesitter language for a file
--- @param filepath string
--- @return string?
local function get_lang(filepath)
  local ext = get_file_ext(filepath)
  if not ext then
    return nil
  end
  ext = ext:lower()
  local lang_map = {
    ["c"] = "c",
    ["h"] = "c",
    ["cpp"] = "cpp",
    ["cxx"] = "cpp",
    ["cc"] = "cpp",
    ["hpp"] = "cpp",
    ["hxx"] = "cpp",
    ["py"] = "python",
    ["rs"] = "rust",
  }
  return lang_map[ext]
end

--- Recursively traverse include dependencies
--- @param file string Current file path
--- @param ctx { files: table<string, boolean>, edges: table<string, string[]>, visited: table<string, boolean>, depth: number, max_depth: number, ignore_patterns: string[], batch_size: number, git_root: string|nil, callback: function }
local function traverse_includes(file, ctx)
  dlog("traverse_includes: entering file=" .. file)
  if ctx.visited[file] then
    dlog("traverse_includes: already visited, returning")
    return
  end
  ctx.visited[file] = true

  local elapsed_sec = (vim.loop.hrtime() / 1e9) - ctx.start_time_sec
  if ctx.max_traversal_time_sec and elapsed_sec >= ctx.max_traversal_time_sec then
    dlog("traverse_includes: max_traversal_time_sec reached")
    return
  end

  if ctx.depth > ctx.max_depth then
    dlog("traverse_includes: max_depth reached (" .. ctx.max_depth .. ")")
    return
  end

  ctx.depth = ctx.depth + 1
  ctx.files[file] = true

  if not ctx.edges[file] then
    ctx.edges[file] = {}
  end

  local lang = get_lang(file)
  if not lang then
    dlog("traverse_includes: no language detected for file=" .. file)
    ctx.depth = ctx.depth - 1
    return
  end
  dlog("traverse_includes: detected lang=" .. lang .. " for file=" .. file)

  local should_ignore = false
  for _, pattern in ipairs(ctx.ignore_patterns) do
    if file:find(pattern, 1, true) then
      dlog("traverse_includes: file ignored by pattern=" .. pattern)
      should_ignore = true
      break
    end
  end
  if should_ignore then
    ctx.depth = ctx.depth - 1
    return
  end

  ---@diagnostic disable-next-line: param-type-mismatch
  local bufnr = vim.fn.bufnr(file)
  local opened_buf = false
  if bufnr == -1 then
    ---@diagnostic disable-next-line: param-type-mismatch
    bufnr = vim.fn.bufadd(file)
    ---@diagnostic disable-next-line: param-type-mismatch
    vim.fn.bufload(bufnr)
    -- Treesitter needs filetype to know which parser to use
    local ft_map = { c = "c", cpp = "cpp", python = "python", rust = "rust" }
    vim.api.nvim_set_option_value("filetype", ft_map[lang] or "", { buf = bufnr })
    opened_buf = true
  end
  dlog("traverse_includes: bufnr=" .. bufnr .. " opened_buf=" .. tostring(opened_buf))

  local ok, includes = pcall(M.parse_includes, bufnr, lang)
  dlog("traverse_includes: parse_includes result - ok=" .. tostring(ok) .. " count=" .. (includes and #includes or 0))
  if not ok or not includes then
    dlog("traverse_includes: parse_includes failed, ok=" .. tostring(ok))
    if opened_buf then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
    ctx.depth = ctx.depth - 1
    return
  end

  if opened_buf then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end

  local resolved_list = {}
  local resolved_count = 0
  local total = #includes
  local resolved_paths = {}

  for _, inc in ipairs(includes) do
    local resolved = M.resolve_include_path(inc, file, lang, ctx.git_root)
    if resolved then
      table.insert(resolved_paths, resolved)
      ctx.files[resolved] = true
      table.insert(ctx.edges[file], resolved)
      resolved_count = resolved_count + 1
    end
  end
  dlog("traverse_includes: resolved " .. resolved_count .. "/" .. total .. " includes")

  -- Recurse into resolved includes (only unvisited to avoid infinite recursion)
  local recurse_idx = 0
  for _, resolved in ipairs(resolved_paths) do
    if not ctx.visited[resolved] then
      recurse_idx = recurse_idx + 1
      if recurse_idx <= ctx.batch_size then
        dlog("traverse_includes: recursing into " .. resolved)
        traverse_includes(resolved, ctx)
      end
    end
  end

  ctx.depth = ctx.depth - 1
end

--- Build the dependency graph from a file using include parsing
--- @param file string Starting file path
--- @param opts? { max_depth?: number, ignore_patterns?: string[], max_traversal_time_sec?: number }
--- @param callback function(graph: { files: string[], edges: table<string, string[]>, root_file: string })
function M.build_from_file(file, opts, callback)
  opts = opts or {}
  utils.stats.start("build_from_file")

  local ctx = {
    files = {},
    edges = {},
    visited = {},
    depth = 0,
    start_time_sec = vim.loop.hrtime() / 1e9,
    ignore_patterns = opts.ignore_patterns or (config.current and config.current.git.exclude_patterns) or {},
    max_depth = opts.max_depth or 10,
    max_traversal_time_sec = opts.max_traversal_time_sec or 30,
    batch_size = (config.current and config.current.git.batch_size) or 100,
    git_root = get_git_root(),
    callback = callback,
  }

  dlog("build_from_file: file=" .. file)
  dlog("build_from_file: max_depth=" .. (opts.max_depth or 10) .. " batch_size=" .. (config.current and config.current.git.batch_size or 100))
  dlog("build_from_file: ignore_patterns=" .. vim.inspect(opts.ignore_patterns or (config.current and config.current.git.exclude_patterns) or {}))

  vim.defer_fn(function()
    dlog("build_from_file: starting traverse_includes")
    traverse_includes(file, ctx)
    dlog("build_from_file: traverse_includes completed, files count=" .. vim.tbl_count(ctx.files))

    local files = {}
    for path in pairs(ctx.files) do
      table.insert(files, path)
    end
    table.sort(files)

    dlog("build_from_file: final files=" .. vim.inspect(files))
    utils.stats.stop("build_from_file")
    callback({
      files = files,
      edges = ctx.edges,
      root_file = file,
    })
  end, 10)
end

--- Build the dependency graph from the current cursor position
--- @param opts? { max_depth?: number, ignore_patterns?: string[], max_traversal_time_sec?: number }
--- @param callback function(graph: { files: string[], edges: table<string, string[]>, root_file: string })
function M.build_from_cursor(opts, callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  M.build_from_file(file, opts, callback)
end

return M
