# blast-radius.nvim

**Impact analysis for Neovim.** When you see wrong output at the end of a call chain, blast-radius shows you which files in that chain changed recently — ranked by how suspicious they are.

```
🔴  src/billing/tax.cpp          2d ago   feat: new tax calculation rules
🔴  src/order/pricing.cpp        1d ago   refactor: extract pricing logic
🟡  src/order/discount.cpp       8d ago   fix: edge case in discounts [fix]
🟢  src/order/checkout.cpp      21d ago   refactor: cleanup
⚪  src/utils/math.cpp            —       no recent changes
```

## How it works

1. Place your cursor on a function where you observe incorrect behavior
2. Run `:BlastRadius`
3. The plugin traces the incoming call hierarchy (LSP) to find all files in the chain
4. For each file it looks up recent git commits and scores them by recency
5. A picker shows the results sorted by suspicion — the most recently changed files are at the top

The idea: if something broke, the most likely culprit is a file that was changed recently.

## Requirements

- Neovim ≥ 0.10
- An LSP server with `callHierarchyProvider` support (clangd, rust-analyzer, pyright, tsserver, …)
- Git repository
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) or [snacks.nvim](https://github.com/folke/snacks.nvim) for a better picker UI
- Optional: [diffview.nvim](https://github.com/sindrets/diffview.nvim) to open commit diffs directly

## Installation

### lazy.nvim

```lua
{
  "username/blast-radius.nvim",
  cmd = { "BlastRadius", "BlastRadiusClearCache", "BlastRadiusStats" },
  keys = {
    { "<leader>br", function() require("blast_radius").run() end, desc = "Blast Radius: analyze" },
    { "<leader>bc", function() require("blast_radius").clear_cache() end, desc = "Blast Radius: clear cache" },
  },
  opts = {},
}
```

### packer.nvim

```lua
use {
  "username/blast-radius.nvim",
  config = function()
    require("blast_radius").setup({})
  end,
}
```

## Configuration

`setup()` is optional — the plugin works with defaults if you skip it.

```lua
require("blast_radius").setup({
  -- UI provider: "auto" | "telescope" | "snacks" | "select"
  -- "auto" picks telescope > snacks > vim.ui.select
  ui_provider = "auto",

  -- Cache
  cache_ttl = 3600,           -- seconds before cache expires
  max_cache_size_mb = 50,

  -- Git
  git = {
    batch_size = nil,         -- nil = auto (30 on Windows, 100 on Unix)
    timeout = 30000,          -- ms
    exclude_patterns = {
      ".git/",
      "node_modules/",
      ".cache/",
    },
  },
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:BlastRadius` | Analyze the call chain from the symbol under cursor |
| `:BlastRadius --depth=5` | Limit traversal depth (default: 10) |
| `:BlastRadius --bug-since=2025-05-01` | Only flag commits after this date as suspicious |
| `:BlastRadius --since=60 days ago` | How far back to search git history (default: 30 days) |
| `:BlastRadius --no-cache` | Clear cache and re-analyze |
| `:BlastRadius --stats` | Show performance stats after analysis |
| `:BlastRadiusClearCache` | Clear all cached results |
| `:BlastRadiusStats` | Show performance statistics |

## Keybindings

No keybindings are set by default. Recommended mappings:

```lua
vim.keymap.set("n", "<leader>br", function()
  require("blast_radius").run()
end, { desc = "Blast Radius: analyze" })

vim.keymap.set("n", "<leader>bc", function()
  require("blast_radius").clear_cache()
end, { desc = "Blast Radius: clear cache" })

-- Analyze with a specific bug-introduction date
vim.keymap.set("n", "<leader>bR", function()
  vim.ui.input({ prompt = "Bug appeared after (YYYY-MM-DD): " }, function(date)
    if date and date ~= "" then
      require("blast_radius").run({ bug_since = date })
    end
  end)
end, { desc = "Blast Radius: analyze with bug date" })
```

## Suspicion levels

| Icon | Level | Last changed |
|------|-------|--------------|
| 🔴 | HIGH | 0–3 days ago |
| 🟡 | MED | 4–14 days ago |
| 🟢 | LOW | 15+ days ago |
| ⚪ | — | No changes in the lookback window |

When `--bug-since` is set, files changed only before that date are shown as ⚪ — they cannot be the source of a bug that appeared later.

## Picker actions

In the picker, pressing `<CR>` on a file:
- Opens the commit diff in **diffview.nvim** (if installed)
- Otherwise opens the file and shows commit details in a notification

## Fallback: no LSP

If the LSP server does not support call hierarchy, or the cursor is not on a recognized symbol, the plugin falls back to static include/import analysis via Treesitter. Supported languages: C, C++, Python, Rust.

## Lua API

```lua
local br = require("blast_radius")

-- Run with options
br.run({
  max_depth  = 5,                -- call chain depth
  bug_since  = "2025-05-01",    -- only count commits after this date
  since      = "60 days ago",   -- git history lookback window
  ui_provider = "telescope",
})

-- Clear cache
br.clear_cache()

-- Show performance stats
br.show_stats()
```
