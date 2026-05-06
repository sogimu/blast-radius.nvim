# blast-radius.nvim

Visualize what files are affected by changes around your cursor position, combining LSP call hierarchy with git history.

## Features

- LSP-aware dependency graph via `callHierarchy`
- Treesitter fallback when LSP unavailable
- Git history correlation — find recent changes in affected files
- JSON cache with TTL for instant repeat queries
- Telescope / Snacks / vim.select UI backends
- Async operations — zero UI blocking
- C/C++ `#include` parsing via Treesitter
- Virtual override mapping for polymorphic code

## Requirements

- Neovim ≥ 0.10
- `nvim-lspconfig` (clangd for C/C++)
- `telescope.nvim` (optional — falls back to `vim.ui.select`)
- `compile_commands.json` in your project root (for clangd)

## Installation

#### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "sogimu/blast-radius.nvim",
  cmd = { "BlastRadius", "BlastRadiusClearCache" },
  opts = {
    depth = 3,
    cache_ttl = 3600,
    ui_provider = "telescope",
  },
}
```

#### Manual

```
git clone https://github.com/sogimu/blast-radius.nvim.git ~/.local/share/nvim/site/pack/blast-radius/start/blast-radius.nvim
```

## Configuration

```lua
require("blast_radius").setup {
  depth = 3,
  cache_ttl = 3600,               -- seconds (1 hour)
  ignore_patterns = {
    "/usr/", "/usr/include", "/opt/",
    "boost/", "third_party/",
    "generated/", "build/",
  },
  virtual_overrides = {},           -- { ["Base::exec"] = {"DerivedA::exec"} }
  fallback_no_lsp = true,           -- use Treesitter + #include when no LSP
  ui_provider = "telescope",        -- "telescope" | "snacks" | "vim_select"
  git_since_days = 14,
  batch_size = 50,
}
```

## Usage

Place your cursor on a symbol (function, class, method) and run:

```
:BlastRadius
```

Or use the default keymap:

```
<leader>br
```

This will:
1. Resolve the symbol under cursor
2. Build a dependency graph (LSP call hierarchy → Treesitter includes)
3. Query git history for all affected files
4. Show results in a Telescope picker

### Clear cache

```
:BlastRadiusClearCache
```

Keymap: `<leader>brc`

### Flow

```
Cursor position
  → LSP prepareCallHierarchy + outgoingCalls (or Treesitter fallback)
    → Build dependency graph (depth-limited)
      → git log --since for each file
        → Dedupe, tag, format, render in picker
```

## Keymaps

| Key        | Action                                      |
| ---------- | ------------------------------------------- |
| `<leader>br`  | Run blast-radius on symbol under cursor     |
| `<leader>brc` | Clear all cached results                    |
| `<CR>` (in picker) | Open file or view diff of commit   |

## Output format

The picker displays results as a tree:

```
📁 src/core/network.cpp
  ├─ 🔄 abc1234 | 2026-04-28 | Alex | Fix timeout race [fix]
  └─ 🔄 def5678 | 2026-05-01 | Maria | Refactor buffer flush [refactor]
📁 include/network.h
  └─ 🔄 9ab0123 | 2026-05-02 | Ivan | Add JIRA-456 endpoint [JIRA-456]
```

Tags are auto-detected from commit messages: `fix`, `workaround`, `refactor`, JIRA keys (`PROJ-123`), GitHub issues (`#42`).

## Cache

- Located at `~/.cache/nvim/blast_radius/`
- Cached by `(filename + cursor position)` hash for graph results
- Cached by file list hash for git results
- TTL-based expiry (default: 1 hour)
- Automatically invalidated on `BufWritePost` (mtime check per file)

## License

MIT
