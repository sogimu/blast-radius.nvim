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
    elseif arg:match("^%-%-bug%-since=") then
      opts.bug_since = arg:sub(13)
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
      "--bug-since=",
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

vim.api.nvim_create_user_command("BlastRadiusCoupling", function(info)
  local opts = parse_args(info.args or "")
  if opts.no_cache then blast_radius.clear_cache() end
  blast_radius.run_coupling(opts)
end, {
  nargs = "*",
  desc = "Show temporal coupling in the call chain",
  complete = function(arglead)
    local options = { "--depth=", "--no-cache", "--since=", "--stats" }
    local matches = {}
    for _, opt in ipairs(options) do
      if opt:find(arglead, 1, true) == 1 then table.insert(matches, opt) end
    end
    return matches
  end,
})

vim.api.nvim_create_user_command("BlastRadiusHotspots", function(info)
  local opts = parse_args(info.args or "")
  if opts.no_cache then blast_radius.clear_cache() end
  blast_radius.run_hotspots(opts)
end, {
  nargs = "*",
  desc = "Show hotspots (high churn × complexity) in the call chain",
  complete = function(arglead)
    local options = { "--depth=", "--no-cache", "--since=", "--stats" }
    local matches = {}
    for _, opt in ipairs(options) do
      if opt:find(arglead, 1, true) == 1 then table.insert(matches, opt) end
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
