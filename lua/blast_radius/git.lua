local M = {}

function M.batch_files(files, batch_size)
  local batches = {}
  for i = 1, #files, batch_size do
    table.insert(batches, {})
    for j = i, math.min(i + batch_size - 1, #files) do
      table.insert(batches[#batches], files[j])
    end
  end
  return batches
end

local function detect_tags(msg)
  local tags = {}
  if not msg then
    return tags
  end

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
  if jira then
    table.insert(tags, jira)
  end

  local github_issue = msg:match("#(%d+)")
  if github_issue then
    table.insert(tags, "#" .. github_issue)
  end

  return tags
end

function M.get_recent_changes(files, opts, callback)
  opts = opts or {}
  local since_days = opts.git_since_days or 14
  local batch_size = opts.batch_size or 50

  if vim.tbl_isempty(files) then
    callback({})
    return
  end

  local since_str = string.format("%d days ago", since_days)
  local changes = {}
  local batches = M.batch_files(files, batch_size)

  local pending = #batches

  local function on_batch_done(err, batch_changes)
    if err then
      vim.notify("blast-radius.nvim: git log error: " .. err, vim.log.levels.ERROR)
    elseif batch_changes then
      for _, entry in ipairs(batch_changes) do
        table.insert(changes, entry)
      end
    end

    pending = pending - 1
    if pending == 0 then
      table.sort(changes, function(a, b)
        return a.date > b.date
      end)
      callback(changes)
    end
  end

  for _, batch in ipairs(batches) do
    local cmd = {
      "git",
      "log",
      "--since=" .. since_str,
      "--pretty=format:%h|%ad|%an|%s",
      "--date=short",
      "--",
    }

    for _, f in ipairs(batch) do
      local git_relative = vim.fn.system({ "git", "rev-parse", "--show-prefix" }):gsub("%s+", "")
      if git_relative ~= "" then
        local abs = vim.fn.fnamemodify(f, ":p")
        local root = vim.fn.system({ "git", "rev-parse", "--show-toplevel" }):gsub("%s+", "")
        if abs:sub(1, #root) == root then
          f = abs:sub(#root + 2)
        end
      end
      table.insert(cmd, f)
    end

    vim.system(cmd, {}, function(result)
      if result.code ~= 0 then
        on_batch_done(result.stderr, nil)
        return
      end

      local batch_changes = {}
      if result.stdout and result.stdout ~= "" then
        for line in result.stdout:gmatch("[^\r\n]+") do
          local hash, date, author, msg = line:match("^([^|]+)|([^|]+)|([^|]+)|(.+)$")
          if hash and date and author then
            local affected_files = {}
            for _, f in ipairs(batch) do
              table.insert(affected_files, f)
            end

            table.insert(batch_changes, {
              file = affected_files[1] or "unknown",
              hash = hash,
              date = date,
              author = author,
              msg = msg or "",
              tags = detect_tags(msg),
            })
          end
        end
      end

      on_batch_done(nil, batch_changes)
    end)
  end
end

return M
