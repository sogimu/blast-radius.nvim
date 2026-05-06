vim.api.nvim_create_user_command("BlastRadius", function()
  require("blast_radius").run()
end, {})

vim.api.nvim_create_user_command("BlastRadiusClearCache", function()
  require("blast_radius.cache").clear()
end, {})
