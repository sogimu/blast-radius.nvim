local M = {}

local function group_by_file(changes)
  local grouped = {}
  for _, entry in ipairs(changes) do
    if not grouped[entry.file] then
      grouped[entry.file] = {}
    end
    table.insert(grouped[entry.file], entry)
  end
  return grouped
end

local function format_tree(changes, files)
  local lines = {}
  local grouped = group_by_file(changes)

  for _, file in ipairs(files) do
    local short_name = vim.fn.fnamemodify(file, ":.")
    table.insert(lines, { display = "📁 " .. short_name, file = file })

    local file_changes = grouped[file]
    if file_changes then
      for i, entry in ipairs(file_changes) do
        local prefix = "  └─"
        if i < #file_changes then
          prefix = "  ├─"
        end
        local detail = string.format(
          "%s 🔄 %s | %s | %s | %s%s",
          prefix,
          entry.hash,
          entry.date,
          entry.author,
          entry.msg or "",
          (#entry.tags > 0 and (" [" .. table.concat(entry.tags, ", ") .. "]") or "")
        )
        table.insert(lines, { display = detail, file = file, hash = entry.hash, entry = entry })
      end
    end
  end

  if vim.tbl_isempty(changes) then
    table.insert(lines, { display = "No recent changes found", file = nil })
  end

  return lines
end

local function open_item(item)
  if not item then return end
  if item.hash and item.file then
    vim.cmd("DiffviewFileHistory " .. item.file)
  elseif item.file then
    vim.cmd("edit " .. item.file)
  end
end

local function with_telescope(changes, files, opts)
  local ok = pcall(require, "telescope.pickers")
  if not ok then
    with_vim_select(changes, files, opts)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local tree = format_tree(changes, files)

  pickers.new({}, {
    prompt_title = "Blast Radius",
    finder = finders.new_table({
      results = tree,
      entry_maker = function(entry)
        return {
          value = entry,
          display = entry.display,
          ordinal = entry.display,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        open_item(selection and selection.value)
      end)
      return true
    end,
  }):find()
end

local function with_snacks(changes, files, opts)
  local ok = pcall(require, "snacks.picker")
  if not ok then
    with_vim_select(changes, files, opts)
    return
  end

  local snacks = require("snacks.picker")
  local tree = format_tree(changes, files)

  snacks.select({
    title = "Blast Radius",
    items = tree,
    format = function(item)
      return item.display
    end,
    confirm = function(item)
      open_item(item)
    end,
  })
end

local function with_vim_select(changes, files, opts)
  local tree = format_tree(changes, files)

  vim.ui.select(
    tree,
    {
      format_item = function(item)
        return item.display
      end,
    },
    function(item)
      open_item(item)
    end
  )
end

function M.render(changes, files, opts)
  opts = opts or {}
  local provider = opts.ui_provider or "telescope"

  vim.schedule(function()
    if provider == "telescope" then
      with_telescope(changes, files, opts)
    elseif provider == "snacks" then
      with_snacks(changes, files, opts)
    else
      with_vim_select(changes, files, opts)
    end
  end)
end

return M
