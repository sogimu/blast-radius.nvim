local M = {}

M.defaults = {
  depth = 3,
  cache_ttl = 3600,
  cache_dir = vim.fn.stdpath("cache") .. "/blast_radius",
  ignore_patterns = {
    "/usr/",
    "/usr/include",
    "/opt/",
    "boost/",
    "third_party/",
    "generated/",
    "build/",
  },
  virtual_overrides = {},
  fallback_no_lsp = true,
  ui_provider = "telescope",
  git_since_days = 14,
  batch_size = 50,
}

function M.validate(opts)
  if not opts then
    return
  end

  local expected_types = {
    depth = "number",
    cache_ttl = "number",
    cache_dir = "string",
    ignore_patterns = "table",
    virtual_overrides = "table",
    fallback_no_lsp = "boolean",
    ui_provider = "string",
    git_since_days = "number",
    batch_size = "number",
  }

  for key, type_name in pairs(expected_types) do
    if opts[key] ~= nil and type(opts[key]) ~= type_name then
      vim.notify(
        string.format(
          "blast-radius.nvim: invalid type for '%s', expected %s got %s",
          key,
          type_name,
          type(opts[key])
        ),
        vim.log.levels.ERROR
      )
    end
  end

  if opts.ui_provider and not vim.tbl_contains({ "telescope", "snacks", "vim_select" }, opts.ui_provider) then
    vim.notify(
      "blast-radius.nvim: invalid ui_provider, must be 'telescope', 'snacks', or 'vim_select'",
      vim.log.levels.ERROR
    )
    opts.ui_provider = M.defaults.ui_provider
  end
end

return M
