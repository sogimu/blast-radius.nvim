local M = {}

local cache_dir = nil

local function ensure_cache_dir()
  if not cache_dir then
    local config = require("blast_radius.config")
    cache_dir = config.defaults.cache_dir
  end

  local stat = vim.uv.fs_stat(cache_dir)
  if not stat then
    vim.fn.mkdir(cache_dir, "p")
  end
end

local function file_path(key)
  ensure_cache_dir()
  return cache_dir .. "/" .. key:gsub("[^%w%-_]", "_") .. ".json"
end

local function get_mtimes(files)
  local mtimes = {}
  for _, file in ipairs(files) do
    local stat = vim.uv.fs_stat(file)
    if stat then
      mtimes[file] = stat.mtime.sec
    end
  end
  return mtimes
end

local function are_files_fresh(mtimes)
  for file, old_mtime in pairs(mtimes) do
    local stat = vim.uv.fs_stat(file)
    if not stat or stat.mtime.sec ~= old_mtime then
      return false
    end
  end
  return true
end

function M.get(key)
  local path = file_path(key)
  local ok, content = pcall(vim.fn.readfile, path)
  if not ok or not content then
    return nil
  end

  local json = table.concat(content, "\n")
  local ok_data, entry = pcall(vim.json.decode, json)
  if not ok_data or not entry then
    return nil
  end

  if not entry.created_at or not entry.ttl then
    return nil
  end

  local now = vim.uv.now() / 1000
  if now - entry.created_at > entry.ttl then
    M.remove(key)
    return nil
  end

  if entry.file_mtimes and not are_files_fresh(entry.file_mtimes) then
    M.remove(key)
    return nil
  end

  return entry.data
end

function M.set(key, data, ttl, files)
  if not ttl then
    local config = require("blast_radius.config")
    ttl = config.defaults.cache_ttl
  end

  local entry = {
    data = data,
    created_at = vim.uv.now() / 1000,
    ttl = ttl,
    file_mtimes = files and get_mtimes(files) or {},
  }

  local path = file_path(key)
  local json = vim.json.encode(entry)
  local content = {}
  for line in json:gmatch("([^\n]*)\n?") do
    table.insert(content, line)
  end
  vim.fn.writefile(content, path)
end

function M.remove(key)
  local path = file_path(key)
  vim.fn.delete(path)
end

function M.invalidate(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if bufname == "" then
    return
  end

  ensure_cache_dir()

  local files = vim.uv.fs_readdir(vim.uv.fs_opendir(cache_dir))
  if not files then
    return
  end

  for _, entry in ipairs(files) do
    if entry.name:match("%.json$") then
      local full_path = cache_dir .. "/" .. entry.name
      local ok, content = pcall(vim.fn.readfile, full_path)
      if ok and content then
        local json = table.concat(content, "\n")
        local ok_data, cache_entry = pcall(vim.json.decode, json)
        if ok_data and cache_entry and cache_entry.file_mtimes and cache_entry.file_mtimes[bufname] then
          vim.fn.delete(full_path)
        end
      end
    end
  end
end

function M.clear()
  ensure_cache_dir()
  vim.fn.system({ "rm", "-rf", cache_dir })
  vim.fn.mkdir(cache_dir, "p")
  vim.notify("blast-radius.nvim: cache cleared", vim.log.levels.INFO)
end

return M
