-- Utility module for blast-radius.nvim

local M = {}

--- Detect the current operating system
--- @return "windows" | "mac" | "linux"
function M.get_platform()
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "windows"
  elseif vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1 then
    return "mac"
  else
    return "linux"
  end
end

--- Check if running on Windows
--- @return boolean
function M.is_windows()
  return M.get_platform() == "windows"
end

--- Get the appropriate git batch size based on platform
--- @param user_size? number
--- @return number
function M.get_git_batch_size(user_size)
  if user_size then
    return user_size
  end

  if M.is_windows() then
    return 30
  else
    return 100
  end
end

--- Debounce a function call using vim.defer_fn
--- @param fn function
--- @param ms number Delay in milliseconds
--- @return function debounced_fn
function M.debounce(fn, ms)
  local timer = nil
  local pending_args = nil

  return function(...)
    pending_args = { ... }
    if timer then
      timer:stop()
      timer:close()
    end

    timer = vim.loop.new_timer()
    timer:start(ms, 0, function()
      vim.schedule_wrap(fn)(table.unpack(pending_args))
      timer:stop()
      timer:close()
      timer = nil
    end)
  end
end

--- Normalize a path to a relative form
--- Handles Windows backslashes, trailing separators, etc.
--- @param path string
--- @param base? string Base path to make relative to (defaults to cwd)
--- @return string
function M.normalize_path(path, base)
  -- Convert backslashes to forward slashes (Windows)
  local normalized = path:gsub("\\", "/")

  -- Remove trailing slashes (except for root)
  normalized = normalized:gsub("/+$", "")

  -- If no base provided, use cwd
  local base_path = base or vim.fn.getcwd()
  base_path = base_path:gsub("\\", "/"):gsub("/+$", "")

  -- Make relative if possible
  if normalized:find(base_path, 1, true) == 1 then
    normalized = normalized:sub(base_path:len() + 2)
  end

  return normalized
end

--- Ensure a directory exists, creating it if necessary
--- @param dir_path string
--- @return boolean success
--- @return string? error_message
function M.ensure_dir(dir_path)
  -- Check if directory already exists
  local stat = vim.loop.fs_stat(dir_path)
  if stat and stat.type == "directory" then
    return true
  end

  -- Create directory recursively
  local success, err = vim.loop.fs_mkdir(dir_path, 511) -- 0777 permissions
  if success then
    return true
  end

  -- If mkdir fails, try creating parent directories first
  local parent = dir_path:match("(.+)[/\\]")
  if parent and parent ~= dir_path then
    local parent_success = M.ensure_dir(parent)
    if parent_success then
      return vim.loop.fs_mkdir(dir_path, 511)
    end
  end

  return false, err
end

--- Performance metrics tracker
M.stats = {
  _timers = {},

  --- Start timing an operation
  --- @param name string
  --- @return number timer_id
  --- @return function stop_fn
  start = function(name)
    local start_time = vim.loop.hrtime()
    M.stats._timers[name] = start_time
    return start_time, function()
      return M.stats.stop(name, start_time)
    end
  end,

  --- Stop timing and record elapsed time
  --- @param name string
  --- @param start_time? number Optional: use specific start time
  --- @return number elapsed_ms
  stop = function(name, start_time)
    start_time = start_time or M.stats._timers[name]
    if not start_time then
      return 0
    end

    local elapsed_ns = vim.loop.hrtime() - start_time
    local elapsed_ms = elapsed_ns / 1e6

    -- Store result
    if not M.stats._results[name] then
      M.stats._results[name] = {}
    end
    table.insert(M.stats._results[name], elapsed_ms)

    M.stats._timers[name] = nil
    return elapsed_ms
  end,

  --- Get all recorded metrics for an operation
  --- @param name string
  --- @return table? metrics { count, total_ms, avg_ms, min_ms, max_ms }
  get = function(name)
    local results = M.stats._results[name]
    if not results or #results == 0 then
      return nil
    end

    local total = 0
    local min_val = results[1]
    local max_val = results[1]

    for _, v in ipairs(results) do
      total = total + v
      if v < min_val then
        min_val = v
      end
      if v > max_val then
        max_val = v
      end
    end

    return {
      count = #results,
      total_ms = total,
      avg_ms = total / #results,
      min_ms = min_val,
      max_ms = max_val,
    }
  end,

  --- Get all tracked metric names
  --- @return string[]
  list_names = function()
    local names = {}
    for name, _ in pairs(M.stats._results) do
      table.insert(names, name)
    end
    return names
  end,

  --- Reset all statistics
  clear = function()
    M.stats._results = {}
    M.stats._timers = {}
  end,

  --- Storage for recorded metrics
  _results = {},
}

return M
