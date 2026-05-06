local M = {}

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

  if vim.tbl_isempty(files) then
    vim.schedule(function()
      callback({})
    end)
    return
  end

  local since_str = string.format("%d days ago", since_days)

  local git_root = vim.fn.system({ "git", "rev-parse", "--show-toplevel" }):gsub("%s+", "")
  if git_root == "" then
    vim.schedule(function()
      callback({})
    end)
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
    vim.schedule(function()
      callback({})
    end)
    return
  end

  local all_changes = {}
  local pending = #rel_files
  local completed = false
  local lock = {}

  local function on_file_done(rel_path, file_changes)
    if lock[rel_path] then return end
    lock[rel_path] = true

    for _, entry in ipairs(file_changes or {}) do
      table.insert(all_changes, entry)
    end

    pending = pending - 1
    if pending == 0 then
      if completed then return end
      completed = true
      local seen = {}
      local deduped = {}
      for _, c in ipairs(all_changes) do
        local key = c.hash .. "|" .. c.file
        if not seen[key] then
          seen[key] = true
          table.insert(deduped, c)
        end
      end
      table.sort(deduped, function(a, b)
        return a.date > b.date
      end)
      vim.schedule(function()
        callback(deduped)
      end)
    end
  end

   for _, rel in ipairs(rel_files) do
    local cmd = {
      "git",
      "log",
      "--since=" .. since_str,
      "--pretty=format:%h|%ad|%an|%s",
      "--date=short",
      "--",
      rel,
    }

    vim.system(cmd, { cwd = git_root }, function(result)
      if result.code ~= 0 then
        on_file_done(rel, {})
        return
      end

      local file_changes = {}
      if result.stdout and result.stdout ~= "" then
        for line in result.stdout:gmatch("[^\r\n]+") do
          local hash, date, author, msg = line:match("^([^|]+)|([^|]+)|([^|]+)|(.+)$")
          if hash then
            table.insert(file_changes, {
              file = rel,
              hash = hash,
              date = date,
              author = author,
              msg = msg or "",
              tags = detect_tags(msg),
            })
          end
        end
      end

      on_file_done(rel, file_changes)
    end)
  end
end

      if not result.stdout or result.stdout == "" then
        on_file_done(rel, {})
        return
      end

      local file_changes = {}
      local current_hash = nil
      local current_date = nil
      local current_author = nil
      local current_msg = nil

      for line in result.stdout:gmatch("[^\r\n]+") do
        if line:match("^commit ") then
          local hash, date, author, msg = line:match("^commit (%w+)|([^|]+)|([^|]+)|(.+)$")
          if hash then
            current_hash = hash
            current_date = date
            current_author = author
            current_msg = msg
          end
        elseif line:match("^[AMDCR]") then
          local _action, changed_file = line:match("^([AMDCR])\t(.+)$")
          if changed_file == rel and current_hash then
            table.insert(file_changes, {
              file = rel,
              hash = current_hash:sub(1, 7),
              date = current_date,
              author = current_author,
              msg = current_msg or "",
              tags = detect_tags(current_msg),
            })
          end
        end
      end

      on_file_done(rel, file_changes)
    end)
  end
end

return M
