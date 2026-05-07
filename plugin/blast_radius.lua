if vim.g.loaded_blast_radius then
  return
end
vim.g.loaded_blast_radius = true

local blast_radius = require("blast_radius")

local function parse_args(args)
  local opts = {}

  for arg in vim.gsplit(args, "%s+", { trimempty = true }) do
    if arg:match("^%-%-depth=") then
      opts.max_depth = tonumber(arg:sub(9)) or 10
    elseif arg == "--no-cache" then
      opts.no_cache = true
    elseif arg:match("^%-%-since=") then
      opts.since = arg:sub(9)
    elseif arg == "--stats" then
      opts.enable_stats = true
    end
  end

  return opts
end

vim.api.nvim_create_user_command("BlastRadius", function(info)
  local opts = parse_args(info.args or "")

  if opts.no_cache then
    blast_radius.clear_cache()
  end

  blast_radius.run(opts)
end, {
  nargs = "*",
  desc = "Analyze call hierarchy and show git blast radius",
  complete = function(arglead)
    local options = {
      "--depth=",
      "--no-cache",
      "--since=",
      "--stats",
    }
    local matches = {}
    for _, opt in ipairs(options) do
      if opt:find(arglead, 1, true) == 1 then
        table.insert(matches, opt)
      end
    end
    return matches
  end,
})

vim.api.nvim_create_user_command("BlastRadiusClearCache", function()
  blast_radius.clear_cache()
end, {
  nargs = 0,
  desc = "Clear all blast-radius caches",
})

vim.api.nvim_create_user_command("BlastRadiusStats", function()
  blast_radius.show_stats()
end, {
  nargs = 0,
  desc = "Show blast-radius performance statistics",
})

local keymaps = {
  { "<leader>br", "<cmd>BlastRadius<CR>", { desc = "Run Blast Radius analysis" } },
  { "<leader>bc", "<cmd>BlastRadiusClearCache<CR>", { desc = "Clear Blast Radius cache" } },
}

vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  callback = function()
    for _, km in ipairs(keymaps) do
      vim.keymap.set("n", km[1], km[2], km[3])
    end
  end,
  desc = "Set up Blast Radius keymaps",
})
