local utils = require("blast_radius.utils")
local config = require("blast_radius.config")

local M = {}

--- Format a single change entry for display
--- @param change table
--- @param file string
--- @return string
local function format_entry(change, file)
  local tags_str = ""
  if change.tags and #change.tags > 0 then
    tags_str = " [" .. table.concat(change.tags, ", ") .. "]"
  end
  local short_date = change.date and change.date:sub(1, 10) or ""
  return string.format("🔄 %s | %s | %s | %s%s",
    change.hash,
    short_date,
    change.author or "",
    change.msg or "",
    tags_str
  )
end

--- Build a tree structure from changes grouped by files
--- @param changes table[] Flat list of changes with .files
--- @param graph_result { files: string[] }
--- @return table tree
function M.build_tree(changes, graph_result)
  local file_map = {}

  for _, change in ipairs(changes) do
    for _, fname in ipairs(change.files) do
      if not file_map[fname] then
        file_map[fname] = { file = fname, changes = {} }
      end
      table.insert(file_map[fname].changes, change)
    end
  end

  if not graph_result or not graph_result.files then
    return file_map
  end

  for _, fname in ipairs(graph_result.files) do
    if not file_map[fname] then
      file_map[fname] = { file = fname, changes = {} }
    end
  end

  return file_map
end

--- Create action to handle selection (diffview or edit)
--- @param entry table Selected entry
--- @return function action
local function make_select_action(entry)
  return function()
    local has_diffview = package.loaded["diffview"] ~= nil or
      vim.fn.globpath(&rtp, "plugin/diffview.vim") ~= ""

    if has_diffview and entry.change and entry.change.hash then
      vim.cmd("DiffviewOpen " .. entry.change.hash .. "^!")
    elseif entry.file then
      vim.cmd("edit " .. vim.fn.fnameescape(entry.file))

      if entry.change then
        local info = string.format("Commit: %s\nAuthor: %s\nDate: %s\n%s",
          entry.change.hash or "",
          entry.change.author or "",
          entry.change.date and entry.change.date:sub(1, 10) or "",
          entry.change.msg or ""
        )
        vim.notify(info, vim.log.levels.INFO, { title = "blast-radius" })
      end
    end
  end
end

--- Convert tree to flat list for UI consumers
--- @param tree table Result of build_tree
--- @return table[] flat_entries
local function tree_to_flat(tree)
  local entries = {}

  -- Collect files from tree
  local file_entries = {}
  for _, node in pairs(tree) do
    table.insert(file_entries, node)
  end

  -- Sort by filename
  table.sort(file_entries, function(a, b)
    return a.file < b.file
  end)

  for _, node in ipairs(file_entries) do
    if #node.changes > 0 then
      for _, change in ipairs(node.changes) do
        table.insert(entries, {
          display = format_entry(change, node.file),
          value = format_entry(change, node.file),
          file = node.file,
          change = change,
          ordinal = string.format("%s %s %s %s",
            node.file,
            change.hash,
            change.msg or "",
            change.author or ""
          ),
        })
      end
    else
      table.insert(entries, {
        display = "📁 " .. node.file .. " (no changes)",
        value = node.file,
        file = node.file,
        change = nil,
        ordinal = node.file,
      })
    end
  end

  return entries
end

--- Render UI with Telescope picker
--- @param entries table[]
--- @param opts table Additional options
function M.render_telescope(entries, opts)
  opts = opts or {}
  utils.stats.start("render_telescope")

  local ok, pickers = pcall(require, "telescope.pickers")
  if not ok then
    M.render_select(entries, opts)
    return
  end

  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"

  local finder = finders.new_table {
    results = entries,
    entry_maker = function(entry)
      return {
        value = entry,
        display = entry.display,
        ordinal = entry.ordinal,
      }
    end,
  }

  local prompt_title = "🎯 Blast Radius"

  pickers.new(opts, {
    prompt_title = prompt_title,
    finder = finder,
    sorter = conf.generic_sorter(opts),
    attach_mappings = function(prompt_bufnr, _map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection and selection.value then
          make_select_action(selection.value)()
        end
      end)
      return true
    end,
  }):find()

  utils.stats.stop("render_telescope")
end

--- Render UI with Snacks picker
--- @param entries table[]
--- @param opts table Additional options
function M.render_snacks(entries, opts)
  opts = opts or {}
  utils.stats.start("render_snacks")

  local ok, snacks = pcall(require, "snacks.picker")
  if not ok then
    M.render_select(entries, opts)
    return
  end

  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, {
      text = entry.display,
      value = entry,
    })
  end

  snacks.select({
    title = "🎯 Blast Radius",
    items = items,
    confirm = function(item)
      if item and item.value then
        make_select_action(item.value)()
      end
    end,
  })

  utils.stats.stop("render_snacks")
end

--- Render UI with vim.select fallback
--- @param entries table[]
--- @param opts table Additional options
function M.render_select(entries, opts)
  opts = opts or {}
  utils.stats.start("render_select")

  if #entries == 0 then
    vim.notify("No changes found.", vim.log.levels.WARN, { title = "blast-radius" })
    utils.stats.stop("render_select")
    return
  end

  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, entry.display)
  end

  vim.ui.select(items, {
    prompt = "🎯 Blast Radius: ",
    format_item = function(item_str)
      return item_str
    end,
  }, function(choice_idx)
    if choice_idx and entries[choice_idx] then
      make_select_action(entries[choice_idx])()
    end
    utils.stats.stop("render_select")
  end)
end

--- Determine the best render provider and display changes
--- @param changes table[]
--- @param graph_result { files: string[] }
--- @param user_config? table
function M.render(changes, graph_result, user_config)
  local tree = M.build_tree(changes, graph_result)
  local entries = tree_to_flat(tree)

  local cfg = user_config or (config.current and config.current.display) or {}
  local provider = cfg.ui_provider or "auto"

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
    M.render_telescope(entries, cfg)
  elseif provider == "snacks" then
    M.render_snacks(entries, cfg)
  else
    M.render_select(entries, cfg)
  end
end

return M
