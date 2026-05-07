-- Configuration module for blast-radius.nvim

local M = {}

--- Default configuration values
M.defaults = {
  -- Enable/disable the plugin
  enabled = true,

  -- Git operation settings
  git = {
    -- Maximum number of git commands to run in parallel
    batch_size = nil, -- Auto-detected based on platform

    -- Timeout for git commands in milliseconds
    timeout = 30000,

    -- Paths to exclude from git operations
    exclude_patterns = {
      ".git/",
      "node_modules/",
      ".cache/",
    },
  },

  -- Visual display settings
  display = {
    -- Show virtual text overrides
    show_virtual_text = true,

    -- Priority for virtual text
    virtual_text_priority = 100,

    -- Namespace for highlights
    namespace = "blast_radius",
  },

  -- Override virtual text per specific patterns
  -- Format: { [pattern] = { text = "...", hl_group = "..." } }
  virtual_overrides = {},

  -- UI provider: "auto", "telescope", "snacks", "select"
  ui_provider = "auto",

  -- Logging level: "off", "error", "warn", "info", "debug"
  log_level = "warn",

  -- Cache directory (resolved in setup)
  cache_dir = nil,

  -- Cache TTL in seconds
  cache_ttl = 3600,

  -- Maximum cache directory size in megabytes
  max_cache_size_mb = 50,
}

--- Holds the current (merged) configuration
M.current = nil

--- Validate a configuration table
--- @param cfg table
--- @return boolean valid
--- @return string? error_message
function M.validate(cfg)
  local ok, err = pcall(function()
    vim.validate {
      enabled = { cfg.enabled, "boolean" },
      git = { cfg.git, "table" },
      display = { cfg.display, "table" },
      virtual_overrides = { cfg.virtual_overrides, "table" },
      log_level = { cfg.log_level, "string" },
    }

    -- Validate nested git table
    vim.validate {
      batch_size = { cfg.git.batch_size, { "number", "nil" } },
      timeout = { cfg.git.timeout, "number" },
      exclude_patterns = { cfg.git.exclude_patterns, "table" },
    }

    -- Validate nested display table
    vim.validate {
      show_virtual_text = { cfg.display.show_virtual_text, "boolean" },
      virtual_text_priority = { cfg.display.virtual_text_priority, "number" },
      namespace = { cfg.display.namespace, "string" },
    }

    -- Validate cache settings
    vim.validate {
      cache_ttl = { cfg.cache_ttl, "number" },
      max_cache_size_mb = { cfg.max_cache_size_mb, "number" },
    }

    -- Validate ui_provider
    local valid_providers = { auto = true, telescope = true, snacks = true, select = true }
    if not valid_providers[cfg.ui_provider] then
      error(string.format("invalid ui_provider: %q", cfg.ui_provider))
    end

    -- Validate virtual_overrides entries
    for pattern, override in pairs(cfg.virtual_overrides) do
      if type(pattern) ~= "string" then
        error(string.format("virtual_overrides key must be string, got %s", type(pattern)))
      end
      if type(override) ~= "table" then
        error(string.format("virtual_overrides[%q] must be table, got %s", pattern, type(override)))
      end
      vim.validate {
        text = { override.text, "string" },
        hl_group = { override.hl_group, "string" },
      }
    end

    -- Validate log_level values
    local valid_levels = { off = true, error = true, warn = true, info = true, debug = true }
    if not valid_levels[cfg.log_level] then
      error(string.format("invalid log_level: %q", cfg.log_level))
    end
  end)

  if not ok then
    return false, err
  end
  return true
end

--- Initialize configuration with user-provided options
--- @param user_config? table
--- @return table merged_config
function M.setup(user_config)
  local cfg = vim.deepcopy(M.defaults)

  if user_config then
    -- Deep merge user config into defaults
    cfg = vim.tbl_deep_extend("force", cfg, user_config)

    -- Auto-detect platform-specific batch_size if not provided
    if cfg.git.batch_size == nil then
      local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
      cfg.git.batch_size = is_windows and 30 or 100
    end
  end

  -- Resolve cache directory if not explicitly set
  if not cfg.cache_dir then
    cfg.cache_dir = vim.fn.stdpath("cache") .. "/blast-radius"
  end

  local valid, err = M.validate(cfg)
  if not valid then
    vim.notify("[blast-radius] Invalid configuration: " .. err, vim.log.levels.ERROR)
    return M.defaults
  end

  M.current = cfg
  return cfg
end

return M
