# blast-radius.nvim

**Impact analysis for Neovim.** When you see wrong output at the end of a call chain, blast-radius shows you which files in that chain changed recently — ranked by how suspicious they are.

```
🔴  src/billing/tax.cpp          2d ago   feat: new tax calculation rules
🔴  src/order/pricing.cpp        1d ago   refactor: extract pricing logic
🟡  src/order/discount.cpp       8d ago   fix: edge case in discounts [fix]
🟢  src/order/checkout.cpp      21d ago   refactor: cleanup
⚪  src/utils/math.cpp            —       no recent changes
```

## Features

### Suspicion analysis (`:BlastRadius`)

Helps answer: *something is broken, which file is most likely the cause?*

1. Traces the incoming call hierarchy from the symbol under cursor (LSP)
2. Fetches git history for all files in the chain
3. Ranks files by how recently they changed — the most recently changed files are most suspicious

```
🔴  src/billing/tax.cpp          2d ago   feat: new tax calculation rules
🔴  src/order/pricing.cpp        1d ago   refactor: extract pricing logic
🟡  src/order/discount.cpp       8d ago   fix: edge case in discounts [fix]
🟢  src/order/checkout.cpp      21d ago   refactor: cleanup
⚪  src/utils/math.cpp            —       no recent changes
```

### Temporal coupling (`:BlastRadiusCoupling`)

Helps answer: *which files always change together? What are the hidden dependencies?*

Scans git history and finds pairs of files in the call chain that are frequently committed together. High coupling means a change to one file usually requires a change to the other — even if the code doesn't show an explicit dependency.

```
 95%  src/billing/tax.cpp  ↔  src/order/pricing.cpp     (19 commits together)
 80%  src/billing/tax.cpp  ↔  src/billing/invoice.cpp   (16 commits together)
 60%  src/order/discount.cpp  ↔  src/order/checkout.cpp (12 commits together)
```

### Hotspots (`:BlastRadiusHotspots`)

Helps answer: *which files in this chain are the riskiest to touch?*

Combines two signals: **churn** (how often a file changes) × **complexity** (lines of code). Files that are both large and change frequently are the most dangerous — they're hard to understand and are modified often.

```
🔥🔥🔥  src/billing/tax.cpp       churn:24  loc:890
🔥🔥    src/order/pricing.cpp      churn:18  loc:450
🔥      src/order/discount.cpp     churn:8   loc:320
        src/utils/math.cpp         churn:1   loc:45
```

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
| `:BlastRadius` | Suspicion analysis: files ranked by recency of change |
| `:BlastRadius --bug-since=2025-05-01` | Only flag commits after this date as suspicious |
| `:BlastRadius --depth=5` | Limit call chain traversal depth (default: 10) |
| `:BlastRadius --since=60 days ago` | Git history lookback window (default: 30 days) |
| `:BlastRadius --no-cache` | Clear cache and re-analyze |
| `:BlastRadius --stats` | Show performance stats after analysis |
| `:BlastRadiusCoupling` | Temporal coupling: file pairs that change together |
| `:BlastRadiusCoupling --depth=5` | Same depth/since args as `:BlastRadius` |
| `:BlastRadiusHotspots` | Hotspots: high churn × high complexity |
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

vim.keymap.set("n", "<leader>bC", function()
  require("blast_radius").run_coupling()
end, { desc = "Blast Radius: temporal coupling" })

vim.keymap.set("n", "<leader>bh", function()
  require("blast_radius").run_hotspots()
end, { desc = "Blast Radius: hotspots" })

-- Suspicion analysis with a specific bug-introduction date
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

-- Suspicion analysis
br.run({
  max_depth   = 5,
  bug_since   = "2025-05-01",   -- only count commits after this date
  since       = "60 days ago",
  ui_provider = "telescope",
})

-- Temporal coupling
br.run_coupling({ depth = 5, since = "90 days ago" })

-- Hotspots
br.run_hotspots({ depth = 5 })

-- Clear cache
br.clear_cache()

-- Show performance stats
br.show_stats()
```
