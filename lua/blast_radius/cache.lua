local config = require("blast_radius.config")
local utils = require("blast_radius.utils")

local M = {}

--- Generate a safe filename from type and data
--- @param type_str string
--- @param data table
--- @return string key
function M.make_key(type_str, data)
  local encoded = vim.json.encode(data)
  local safe = encoded:gsub("[^%w_.%-]", "_"):gsub("_+", "_")
  return string.format("%s_%s", type_str, safe)
end

--- Get the full path to a cache file
--- @param key string
--- @return string
local function cache_path(key)
  local cache_dir = config.current and config.current.cache_dir or vim.fn.stdpath("cache") .. "/blast-radius"
  return string.format("%s/%s.json", cache_dir, key)
end

--- Ensure cache directory exists
local function ensure_cache_dir()
  local cache_dir = config.current and config.current.cache_dir or vim.fn.stdpath("cache") .. "/blast-radius"
  utils.ensure_dir(cache_dir)
  return cache_dir
end

--- Calculate the current cache directory size in bytes
--- @return number size_bytes
local function cache_dir_size()
  local cache_dir = ensure_cache_dir()
  local total = 0

  local handle = vim.loop.fs_scandir(cache_dir)
  if not handle then
    return 0
  end

  local name = vim.loop.fs_scandir_next(handle)
  while name do
    local path = string.format("%s/%s", cache_dir, name)
    local stat = vim.loop.fs_stat(path)
    if stat and stat.type == "file" then
      total = total + stat.size
    end
    name = vim.loop.fs_scandir_next(handle)
  end

  return total
end

--- Read and validate a single cache entry
--- @param file_path string
--- @return table? entry
local function read_cache_entry(file_path)
  local fd = vim.loop.fs_open(file_path, "r", 444)
  if not fd then
    return nil
  end

  local stat = vim.loop.fs_fstat(fd)
  if not stat then
    vim.loop.fs_close(fd)
    return nil
  end

  local content, _ = vim.loop.fs_read(fd, stat.size, 0)
  vim.loop.fs_close(fd)

  local ok, entry = pcall(vim.json.decode, content)
  if not ok or not entry then
    return nil
  end

  return entry
end

--- Check if a cache entry is still valid
--- @param entry table
--- @return boolean valid
local function is_entry_valid(entry)
  local now = math.floor(vim.loop.hrtime() / 1e9) -- unix timestamp in seconds
  local ttl = config.current and config.current.cache_ttl or 3600

  -- Check TTL
  if now - entry.timestamp > ttl then
    return false
  end

  return true
end

--- Get cached data by key
--- @param key string
--- @return table? data
function M.get(key)
  utils.stats.start("cache_get")

  local path = cache_path(key)
  local entry = read_cache_entry(path)

  if not entry then
    utils.stats.stop("cache_get")
    return nil
  end

  if not is_entry_valid(entry) then
    vim.loop.fs_unlink(path)
    utils.stats.stop("cache_get")
    return nil
  end

  utils.stats.stop("cache_get")
  return entry.data
end

--- Save data to cache
--- @param key string
--- @param data any
--- @param files string[] List of files this cache entry depends on
function M.set(key, data, files)
  utils.stats.start("cache_set")

  local cache_dir = ensure_cache_dir()
  local path = cache_path(key)

  local now = math.floor(vim.loop.hrtime() / 1e9)
  local file_mtimes = {}

  -- Record mtime of all tracked files
  for _, file in ipairs(files) do
    local stat = vim.loop.fs_stat(file)
    if stat then
      file_mtimes[file] = stat.mtime.sec
    end
  end

  local entry = {
    timestamp = now,
    data = data,
    files = file_mtimes,
    version = 1,
  }

  local ok, encoded = pcall(vim.json.encode, entry)
  if not ok then
    utils.stats.stop("cache_set")
    return false
  end

  local fd = vim.loop.fs_open(path, "w", 438) -- 0666
  if not fd then
    utils.stats.stop("cache_set")
    return false
  end

  vim.loop.fs_write(fd, encoded, 0)
  vim.loop.fs_close(fd)

  -- Check if pruning is needed
  M.prune_if_needed()

  utils.stats.stop("cache_set")
  return true
end

--- Invalidate all cache entries that depend on a specific file
--- @param file string
--- @return number count Number of invalidated entries
function M.invalidate_file(file)
  utils.stats.start("cache_invalidate_file")

  local cache_dir = ensure_cache_dir()
  local count = 0

  local handle = vim.loop.fs_scandir(cache_dir)
  if not handle then
    utils.stats.stop("cache_invalidate_file")
    return 0
  end

  local file_stat = vim.loop.fs_stat(file)
  local current_mtime = file_stat and file_stat.mtime.sec or nil

  local name = vim.loop.fs_scandir_next(handle)
  while name do
    local path = string.format("%s/%s", cache_dir, name)
    local cache_entry = read_cache_entry(path)

    if cache_entry and cache_entry.files then
      local should_delete = false

      if not current_mtime and cache_entry.files[file] then
        should_delete = true
      end

      if current_mtime and cache_entry.files[file] and cache_entry.files[file] < current_mtime then
        should_delete = true
      end

      if should_delete then
        vim.loop.fs_unlink(path)
        count = count + 1
      end
    end

    name = vim.loop.fs_scandir_next(handle)
  end

  utils.stats.stop("cache_invalidate_file")
  return count
end

--- Remove old cache entries if directory size exceeds limit
function M.prune_if_needed()
  local max_bytes = ((config.current and config.current.max_cache_size_mb) or 50) * 1024 * 1024
  local current_size = cache_dir_size()

  if current_size <= max_bytes then
    return
  end

  utils.stats.start("cache_prune")

  local cache_dir = ensure_cache_dir()
  local files_info = {}

  -- Collect all cache files with their timestamps
  local handle = vim.loop.fs_scandir(cache_dir)
  if not handle then
    utils.stats.stop("cache_prune")
    return
  end

  local name = vim.loop.fs_scandir_next(handle)
  while name do
    local path = string.format("%s/%s", cache_dir, name)
    local stat = vim.loop.fs_stat(path)
    if stat and stat.type == "file" and name:match("%.json$") then
      local cache_entry = read_cache_entry(path)
      table.insert(files_info, {
        path = path,
        size = stat.size,
        timestamp = cache_entry and cache_entry.timestamp or 0,
      })
    end
    name = vim.loop.fs_scandir_next(handle)
  end

  -- Sort by timestamp (oldest first)
  table.sort(files_info, function(a, b)
    return a.timestamp < b.timestamp
  end)

  -- Remove oldest files until under limit
  for _, info in ipairs(files_info) do
    if current_size <= max_bytes then
      break
    end
    vim.loop.fs_unlink(info.path)
    current_size = current_size - info.size
  end

  utils.stats.stop("cache_prune")
end

--- Clear the entire cache directory
--- @return boolean success
function M.clear_all()
  utils.stats.start("cache_clear_all")

  local cache_dir = ensure_cache_dir()
  local success = true

  local handle = vim.loop.fs_scandir(cache_dir)
  if not handle then
    utils.stats.stop("cache_clear_all")
    return true
  end

  local name = vim.loop.fs_scandir_next(handle)
  while name do
    local path = string.format("%s/%s", cache_dir, name)
    local ok = vim.loop.fs_unlink(path)
    if not ok then
      success = false
    end
    name = vim.loop.fs_scandir_next(handle)
  end

  vim.loop.fs_rmdir(cache_dir)

  utils.stats.stop("cache_clear_all")
  return success
end

return M
