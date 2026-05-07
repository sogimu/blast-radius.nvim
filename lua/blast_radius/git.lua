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
  vim.system({ "git", "rev-parse", "--git-dir" }, { text = true }, function(result)
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

    local function process_batch(offset)
      if offset > #files then
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

      local batch_end = math.min(offset + batch_size - 1, #files)
      local batch = {}
      for i = offset, batch_end do
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

      vim.system(args, { text = true, cwd = git_root }, function(result)
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

    process_batch(1)
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
    }, { text = true, cwd = git_root }, function(result)
      vim.schedule(function()
        if result.code == 0 and result.stdout then
          for line in result.stdout:gmatch("[^\r\n]+") do
            if line ~= "" then
              local abs_path = git_root .. "/" .. line:gsub("\\", "/")
              if file_set[abs_path] then
                table.insert(enriched_change.files, abs_path)
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

--- Score files in the call chain by suspicion (how recently they changed)
--- @param enriched table[] Enriched changes from map_changes_to_files
--- @param all_files string[] All files in the call chain
--- @param bug_since? string ISO date string "YYYY-MM-DD" — only count commits after this date
--- @return table[] Scored entries sorted by suspicion (high first)
function M.score_files(enriched, all_files, bug_since)
  local now_sec = os.time()

  -- Build per-file most recent commit
  local file_last_change = {}
  for _, change in ipairs(enriched) do
    for _, f in ipairs(change.files or {}) do
      if not file_last_change[f] or change.date > file_last_change[f].date then
        file_last_change[f] = change
      end
    end
  end

  local seen = {}
  local result = {}

  for _, f in ipairs(all_files) do
    if not seen[f] then
      seen[f] = true
      local last = file_last_change[f]
      local days_ago
      local suspicion = "none"

      if last then
        local y, mo, d = last.date:match("^(%d+)-(%d+)-(%d+)")
        if y then
          local commit_time = os.time({
            year = tonumber(y), month = tonumber(mo), day = tonumber(d),
            hour = 12, min = 0, sec = 0,
          })
          days_ago = math.floor((now_sec - commit_time) / 86400)
        end

        -- If bug_since provided: commits before that date can't be the culprit
        if bug_since and last.date < bug_since then
          suspicion = "none"
          days_ago = nil
        elseif days_ago then
          if days_ago <= 3 then
            suspicion = "high"
          elseif days_ago <= 14 then
            suspicion = "medium"
          else
            suspicion = "low"
          end
        end
      end

      table.insert(result, {
        file = f,
        last_commit = last,
        days_ago = days_ago,
        suspicion = suspicion,
      })
    end
  end

  local order = { high = 0, medium = 1, low = 2, none = 3 }
  table.sort(result, function(a, b)
    local oa = order[a.suspicion] or 3
    local ob = order[b.suspicion] or 3
    if oa ~= ob then return oa < ob end
    if a.days_ago and b.days_ago then return a.days_ago < b.days_ago end
    return a.days_ago ~= nil
  end)

  return result
end

--- Compute temporal coupling: pairs of files that frequently change together
--- Useful for discovering hidden dependencies in the call chain.
--- @param enriched table[] Enriched changes from map_changes_to_files
--- @param all_files string[] All files in the call chain
--- @return table[] Pairs sorted by coupling score descending
function M.temporal_coupling(enriched, all_files)
  local churn = {}    -- file -> number of commits
  local cochange = {} -- canonical_key -> number of co-commits

  for _, change in ipairs(enriched) do
    local files = change.files or {}
    for _, f in ipairs(files) do
      churn[f] = (churn[f] or 0) + 1
    end
    for i = 1, #files do
      for j = i + 1, #files do
        local a, b = files[i], files[j]
        if a > b then a, b = b, a end
        local key = a .. "\0" .. b
        cochange[key] = (cochange[key] or 0) + 1
      end
    end
  end

  local result = {}
  for key, count in pairs(cochange) do
    if count >= 2 then
      local sep = key:find("\0", 1, true)
      local a = key:sub(1, sep - 1)
      local b = key:sub(sep + 1)
      local union = (churn[a] or 0) + (churn[b] or 0) - count
      local score = union > 0 and (count / union) or 0
      if score >= 0.3 then
        table.insert(result, {
          file_a = a,
          file_b = b,
          shared_commits = count,
          churn_a = churn[a] or 0,
          churn_b = churn[b] or 0,
          score = score,
        })
      end
    end
  end

  table.sort(result, function(a, b) return a.score > b.score end)
  return result
end

--- Compute hotspot score: files with both high churn and high complexity (LOC).
--- High churn + large file = risky area that changes often and is hard to understand.
--- @param enriched table[] Enriched changes from map_changes_to_files
--- @param all_files string[] All files in the call chain
--- @return table[] Files sorted by hotspot score descending
function M.hotspots(enriched, all_files)
  local churn = {}
  for _, change in ipairs(enriched) do
    for _, f in ipairs(change.files or {}) do
      churn[f] = (churn[f] or 0) + 1
    end
  end

  local seen = {}
  local result = {}
  local max_churn = 0
  local max_loc = 0

  for _, f in ipairs(all_files) do
    if not seen[f] then
      seen[f] = true
      local c = churn[f] or 0
      local ok, lines = pcall(vim.fn.readfile, f)
      local loc = ok and #lines or 0
      if c > max_churn then max_churn = c end
      if loc > max_loc then max_loc = loc end
      table.insert(result, { file = f, churn = c, loc = loc })
    end
  end

  for _, entry in ipairs(result) do
    local nc = max_churn > 0 and (entry.churn / max_churn) or 0
    local nl = max_loc > 0 and (entry.loc / max_loc) or 0
    entry.score = nc * nl
    if entry.score >= 0.5 then
      entry.heat = "high"
    elseif entry.score >= 0.15 then
      entry.heat = "medium"
    elseif entry.score > 0 then
      entry.heat = "low"
    else
      entry.heat = "none"
    end
  end

  table.sort(result, function(a, b) return a.score > b.score end)
  return result
end

return M
