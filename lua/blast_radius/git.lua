local utils = require("blast_radius.utils")
local config = require("blast_radius.config")

local M = {}

--- Extract highlight tags from a commit message
--- @param msg string
--- @return string[] tags
local function extract_tags(msg)
  if not msg then
    return {}
  end

  local tags = {}
  local patterns = {
    "%f[%w]fix%f[^%w]",
    "%f[%w]bug%f[^%w]",
    "%f[%w]feat%f[^%w]",
    "#%d+",
    "%u+%-+%d+",
  }

  for _, pattern in ipairs(patterns) do
    for tag in msg:gmatch(pattern) do
      table.insert(tags, tag)
    end
  end

  return tags
end

--- Check if current directory is inside a git repository
--- @param callback function(is_git_repo: boolean)
local function is_git_repo(callback)
  vim.system({ "git", "rev-parse", "--git-dir" }, { capture = true }, function(result)
    vim.schedule(function()
      callback(result.code == 0)
    end)
  end)
end

--- Parse git log output into change entries
--- @param output string
--- @return table[] changes
local function parse_log_output(output)
  local changes = {}

  for line in output:gmatch("[^\r\n]+") do
    if line ~= "" then
      local hash, date, author, msg = line:match("([^|]+)|([^|]+)|([^|]+)|(.*)")
      if hash and date and author then
        local tags = extract_tags(msg)
        table.insert(changes, {
          hash = hash,
          date = date,
          author = author,
          msg = msg or "",
          tags = tags,
          files = {},
        })
      end
    end
  end

  return changes
end

--- Get the git root directory
--- @return string?
local function get_git_root()
  local result = vim.fn.system("git rev-parse --show-toplevel")
  if result and result ~= "" and not result:find("^fatal:") then
    return result:gsub("\r?\n$", "")
  end
  return nil
end

--- Get recent changes for a list of files, async with batching
--- @param files string[] List of file paths
--- @param opts? { since?: string, max_commits?: number }
--- @param callback function(changes: table[])
function M.get_recent_changes(files, opts, callback)
  opts = opts or {}
  utils.stats.start("git_get_recent_changes")

  is_git_repo(function(repo_exists)
    if not repo_exists then
      utils.stats.stop("git_get_recent_changes")
      callback({})
      return
    end

    local since = opts.since or "30 days ago"
    local max_commits = opts.max_commits or 500
    local git_root = get_git_root()

    if not git_root then
      utils.stats.stop("git_get_recent_changes")
      callback({})
      return
    end

    local batch_size = config.current and config.current.git.batch_size or 100
    local all_changes = {}
    local seen_hashes = {}

    local process_batch = function(offset)
      if offset >= #files then
        utils.stats.stop("git_get_recent_changes")

        local deduped = {}
        for _, change in ipairs(all_changes) do
          if not seen_hashes[change.hash] then
            seen_hashes[change.hash] = true
            table.insert(deduped, change)
          end
        end

        table.sort(deduped, function(a, b)
          return a.date > b.date
        end)

        callback(deduped)
        return
      end

      local batch_end = math.min(offset + batch_size, #files)
      local batch = {}
      for i = offset, batch_end - 1 do
        table.insert(batch, files[i])
      end

      local args = {
        "git",
        "log",
        "--since=" .. since,
        "--pretty=format:%h|%ad|%an|%s",
        "--date=iso",
        "--max-count=" .. max_commits,
        "--",
      }

      for _, f in ipairs(batch) do
        table.insert(args, f)
      end

      vim.system(args, { capture = true, cwd = git_root }, function(result)
        vim.schedule(function()
          if result.code == 0 and result.stdout and result.stdout ~= "" then
            local changes = parse_log_output(result.stdout)
            for _, change in ipairs(changes) do
              table.insert(all_changes, change)
            end
          end

          process_batch(offset + batch_size)
        end)
      end)
    end

    process_batch(0)
  end)
end

--- Map changes to specific files from the list
--- @param changes table[] List of changes (with hash)
--- @param files string[] List of files to check
--- @param callback function(changes: table[])
function M.map_changes_to_files(changes, files, callback)
  if not changes or #changes == 0 then
    vim.schedule(function()
      callback({})
    end)
    return
  end

  utils.stats.start("git_map_changes_to_files")

  local git_root = get_git_root()
  if not git_root then
    utils.stats.stop("git_map_changes_to_files")
    callback(changes)
    return
  end

  local file_set = {}
  for _, f in ipairs(files) do
    local normalized = f:gsub("\\", "/")
    file_set[normalized] = true
  end

  local processed = 0
  local total = #changes
  local enriched = {}

  if total == 0 then
    utils.stats.stop("git_map_changes_to_files")
    callback({})
    return
  end

  local function process_change(idx)
    local change = changes[idx]
    if not change then
      utils.stats.stop("git_map_changes_to_files")
      table.sort(enriched, function(a, b)
        return a.date > b.date
      end)
      callback(enriched)
      return
    end

    local enriched_change = vim.deepcopy(change)

    vim.system({
      "git",
      "diff-tree",
      "--name-only",
      "-r",
      "--root",
      change.hash,
    }, { capture = true, cwd = git_root }, function(result)
      vim.schedule(function()
        if result.code == 0 and result.stdout then
          for line in result.stdout:gmatch("[^\r\n]+") do
            if line ~= "" then
              local normalized = line:gsub("\\", "/")
              if file_set[normalized] then
                table.insert(enriched_change.files, normalized)
              end
            end
          end
        end

        table.insert(enriched, enriched_change)
        processed = processed + 1

        process_change(idx + 1)
      end)
    end)
  end

  process_change(1)
end

return M
