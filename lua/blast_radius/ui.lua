local M = {}

local ICONS = {
  high   = "🔴",
  medium = "🟡",
  low    = "🟢",
  none   = "⚪",
}

local function format_days(days_ago)
  if not days_ago then return "—" end
  if days_ago == 0 then return "today" end
  if days_ago == 1 then return "1d ago" end
  return days_ago .. "d ago"
end

local function format_entry(entry)
  local icon = ICONS[entry.suspicion] or "⚪"
  local rel = vim.fn.fnamemodify(entry.file, ":.")
  local time_str = format_days(entry.days_ago)

  if entry.last_commit then
    local msg = entry.last_commit.msg or ""
    if #msg > 45 then msg = msg:sub(1, 42) .. "..." end
    local tags = entry.last_commit.tags
    local tag_str = (tags and #tags > 0) and (" [" .. table.concat(tags, ",") .. "]") or ""
    return string.format("%s  %-45s  %-8s  %s%s",
      icon, rel, time_str, msg, tag_str)
  end

  return string.format("%s  %-45s  %s", icon, rel, time_str)
end

local function make_action(entry)
  return function()
    if not entry.file then return end
    local has_diffview = package.loaded["diffview"] ~= nil
      or vim.fn.globpath(vim.o.rtp, "plugin/diffview.vim") ~= ""

    if has_diffview and entry.last_commit then
      vim.cmd("DiffviewOpen " .. entry.last_commit.hash .. "^!")
    else
      vim.cmd("edit " .. vim.fn.fnameescape(entry.file))
      if entry.last_commit then
        local info = string.format("Last change: %s\n%s — %s\n%s",
          entry.days_ago and (entry.days_ago .. "d ago") or "unknown",
          entry.last_commit.hash,
          entry.last_commit.author or "",
          entry.last_commit.msg or "")
        vim.notify(info, vim.log.levels.INFO, { title = "blast-radius" })
      end
    end
  end
end

function M.render_telescope(scored, opts)
  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    return M.render_select(scored, opts)
  end

  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local entries = {}
  for _, entry in ipairs(scored) do
    table.insert(entries, {
      display = format_entry(entry),
      ordinal = (entry.suspicion or "none") .. tostring(entry.days_ago or 9999) .. entry.file,
      value = entry,
    })
  end

  pickers.new({}, {
    prompt_title = "Blast Radius — Suspicion",
    finder = finders.new_table({
      results = entries,
      entry_maker = function(e) return e end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel and sel.value then make_action(sel.value)() end
      end)
      return true
    end,
  }):find()
end

function M.render_snacks(scored, opts)
  local ok, snacks = pcall(require, "snacks.picker")
  if not ok then
    return M.render_select(scored, opts)
  end

  local items = {}
  for _, entry in ipairs(scored) do
    table.insert(items, { text = format_entry(entry), value = entry })
  end

  snacks.select({
    title = "Blast Radius — Suspicion",
    items = items,
    confirm = function(item)
      if item and item.value then make_action(item.value)() end
    end,
  })
end

function M.render_select(scored, opts)
  if #scored == 0 then
    vim.notify("No files found in call chain.", vim.log.levels.INFO, { title = "blast-radius" })
    return
  end

  local items = {}
  for _, entry in ipairs(scored) do
    table.insert(items, format_entry(entry))
  end

  vim.ui.select(items, { prompt = "Blast Radius — Suspicion: " }, function(_, idx)
    if idx and scored[idx] then
      make_action(scored[idx])()
    end
  end)
end

--- Render suspicion-ranked files from the call chain
--- @param scored table[] Output of git.score_files
--- @param graph_result table
--- @param user_config? table
function M.render(scored, graph_result, user_config)
  if #scored == 0 then
    vim.notify("No files found in call chain.", vim.log.levels.INFO, { title = "blast-radius" })
    return
  end

  local cfg = user_config or {}
  local provider = cfg.ui_provider

  if not provider then
    local config = require("blast_radius.config")
    provider = config.current and config.current.ui_provider or "auto"
  end

  if provider == "auto" then
    if package.loaded["telescope"] or vim.fn.globpath(vim.o.rtp, "plugin/telescope.vim") ~= "" then
      provider = "telescope"
    elseif package.loaded["snacks"] or vim.fn.globpath(vim.o.rtp, "plugin/snacks.vim") ~= "" then
      provider = "snacks"
    else
      provider = "select"
    end
  end

  if provider == "telescope" then
    M.render_telescope(scored, cfg)
  elseif provider == "snacks" then
    M.render_snacks(scored, cfg)
  else
    M.render_select(scored, cfg)
  end
end

return M
