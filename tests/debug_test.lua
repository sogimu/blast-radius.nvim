#!/usr/bin/env nvim --headless
-- Standalone test: runs blast-radius plugin with file path argument
-- Usage: nvim --headless -l test_br.lua /path/to/file.cpp

-- Add plugin to rtp  
plugin_path = vim.fn.stdpath("data") .. "/lazy/blast-radius.nvim"
vim.opt.rtp:prepend(plugin_path)
ts_path = vim.fn.stdpath("data") .. "/lazy/nvim-treesitter" 
vim.opt.rtp:prepend(ts_path)
plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
vim.opt.rtp:prepend(plenary_path)

test_file = vim.v.argv[5] or "/home/as-lizin/projects/blast-radius.nvim/lua/blast_radius/init.lua"
print("[test] Testing file: " .. test_file)

-- Setup blast-radius
br = require("blast_radius")
br.setup({
  display = { ui_provider = "select" },
  cache_ttl = 3600,
})

-- Edit the file
vim.cmd("edit " .. test_file)

-- Test get_symbol_at_cursor
graph = require("blast_radius.graph")
local symbol, pos = graph.get_symbol_at_cursor(0)
print("[test] get_symbol_at_cursor symbol=" .. tostring(symbol) .. " has_pos=" .. tostring(pos ~= nil))

-- Check LSP
local has_ch = graph.has_call_hierarchy_support(0)
print("[test] has_call_hierarchy_support=" .. tostring(has_ch))
local clients = vim.lsp.get_clients({bufnr = 0})
print("[test] LSP clients: " .. #clients)

-- Test includes directly
local includes = require("blast_radius.includes")
print("[test] includes module loaded")

-- Test parse_includes on the current buffer
local ext = test_file:match("%.([^.]+)$")
local lang_map = {cpp="cpp", c="c", h="c", hpp="cpp", py="python", rs="rust"}
local lang = lang_map[ext] or "lua"
print("[test] Detected lang: " .. lang .. " for ext: " .. tostring(ext))

local parsed = includes.parse_includes(0, lang)
print("[test] Parsed includes count: " .. #parsed)
for i, inc in ipairs(parsed) do
  print("  " .. i .. ": " .. inc)
end

vim.cmd("qall!")
