local M = {}

local function detect_tags(msg)
  local tags = {}
  if not msg then return tags end

  local lower_msg = msg:lower()

  if lower_msg:find("fix") or lower_msg:find("bug") or lower_msg:find("crash") or lower_msg:find("race") then
    table.insert(tags, "fix")
  end

  if lower_msg:find("hack") or lower_msg:find("workaround") or lower_msg:find("temp") then
    table.insert(tags, "workaround")
  end

  if lower_msg:find("refactor") or lower_msg:find("clean") then
    table.insert(tags, "refactor")
  end

  local jira = msg:match("([A-Z]+%-%d+)")
  if jira then table.insert(tags, jira) end

  local github_issue = msg:match("#(%d+)")
  if github_issue then table.insert(tags, "#" .. github_issue) end

  return tags
end

local function batch_files(files, batch_size)
  local batches = {}
  for i = 1, #files, batch_size do
    table.insert(batches, {})
    for j = i, math.min(i + batch_size - 1, #files) do
      table.insert(batches[#batches], files[j])
    end
  end
  return batches
end

local function make_file_lookup(rel_files)
  local lookup = {}
  for _, f in ipairs(rel_files) do
    lookup[f] = true
  end
  return lookup
end

function M.get_recent_changes(files, opts, callback)
  vim.notify("blast-radius.nvim: git.get_recent_changes CALLED with " .. #files .. " files", vim.log.levels.INFO)
  for i, f in ipairs(files) do
    vim.notify("  file " .. i .. ": " .. f, vim.log.levels.INFO)
  end

  opts = opts or {}
  local since_days = opts.git_since_days or 14
  local batch_size = opts.batch_size or 50

  if vim.tbl_isempty(files) then
    vim.schedule(function() callback({}) end)
    return
  end

  local since_str = string.format("%d days ago", since_days)
  local git_root = vim.fn.system({ "git", "rev-parse", "--show-toplevel" }):gsub("%s+", "")

  if git_root == "" then
    vim.notify("blast-radius.nvim: not in a git repo", vim.log.levels.WARN)
    vim.schedule(function() callback({}) end)
    return
  end

  local rel_files = {}
  for _, f in ipairs(files) do
    local abs = vim.fn.fnamemodify(f, ":p")
    if abs:sub(1, #git_root) == git_root then
      local rel = abs:sub(#git_root + 2)
      table.insert(rel_files, rel)
    end
  end

  if vim.tbl_isempty(rel_files) then
    vim.notify("blast-radius.nvim: no files are inside git repo", vim.log.levels.WARN)
    vim.schedule(function() callback({}) end)
    return
  end

  local all_changes = {}
  local batches = batch_files(rel_files, batch_size)
  local pending = #batches
  local file_lookup = make_file_lookup(rel_files)

  local function on_batch_done(err, batch_changes)
    if err then
      vim.notify("blast-radius.nvim: git log error: " .. err, vim.log.levels.ERROR)
    elseif batch_changes then
      for _, entry in ipairs(batch_changes) do
        table.insert(all_changes, entry)
      end
    end

    pending = pending - 1
    if pending == 0 then
      local seen = {}
      local deduped = {}
      for _, c in ipairs(all_changes) do
        local key = c.hash .. "|" .. c.file
        if not seen[key] then
          seen[key] = true
          table.insert(deduped, c)
        end
      end
      table.sort(deduped, function(a, b) return a.date > b.date end)
      vim.schedule(function() callback(deduped) end)
    end
  end

  for _, batch in ipairs(batches) do
    local cmd = {
      "git",
      "log",
      "--since=" .. since_str,
      "--pretty=format:%h|%ad|%an|%s",
      "--date=short",
      "--name-status",
      "--",
    }
    for _, f in ipairs(batch) do
      table.insert(cmd, f)
    end

    vim.system(cmd, { cwd = git_root }, function(result)
      if result.code ~= 0 then
        on_batch_done(result.stderr, nil)
        return
      end

      local batch_changes = {}
      if result.stdout and result.stdout ~= "" then
        vim.notify("blast-radius.nvim: git stdout length: " .. #result.stdout, vim.log.levels.INFO)
        local current_hash = nil
        local current_date = nil
        local current_author = nil
        local current_msg = nil

        for line in result.stdout:gmatch("[^\r\n]+") do
          local h, d, a, m = line:match("^([0-9a-f]+)|([^|]+)|([^|]+)|(.+)$")
          if h then
            current_hash = h
            current_date = d
            current_author = a
            current_msg = m
            vim.notify("blast-radius.nvim: Found commit: " .. h .. " " .. (m or ""), vim.log.levels.INFO)
          elseif current_hash and line:match("^[AMDCR]\t") then
            local changed_file = line:match("^[AMDCR]\t(.+)$")
            if changed_file and file_lookup[changed_file] then
              vim.notify("blast-radius.nvim: Matched: " .. changed_file, vim.log.levels.INFO)
              table.insert(batch_changes, {
                file = changed_file,
                hash = current_hash,
                date = current_date,
                author = current_author,
                msg = current_msg or "",
                tags = detect_tags(current_msg),
              })
            end
          end
        end
        vim.notify("blast-radius.nvim: batch_changes=" .. #batch_changes, vim.log.levels.INFO)
      end

      on_batch_done(nil, batch_changes)
    end)
  end
end

return M
