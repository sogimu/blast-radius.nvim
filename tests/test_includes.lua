#!/usr/bin/env nvim --headless
-- Tests include parsing

vim.opt.rtp:prepend("/home/as-lizin/.local/share/nvim/lazy/blast-radius.nvim")

-- Setup config first
config = require("blast_radius.config")
config.setup({
  git = { batch_size = 50, exclude_patterns = {} },
  display = { ui_provider = "select" },
  cache_ttl = 3600,
})

-- Create test file
local tmp_cpp = "/tmp/test_parse_includes.cpp"
local f = io.open(tmp_cpp, "w")
f:write([[
#include <vector>
#include <memory>
#include "my_header.h"
#include "../utils/helper.hpp"
int main() {
}
]])
f:close()

vim.cmd("edit " .. tmp_cpp)
local bufnr = vim.api.nvim_get_current_buf()
print("Buffer: " .. bufnr)
print("Filetype: " .. vim.api.nvim_get_option_value("filetype", { buf = bufnr }))

includes = require("blast_radius.includes")
print("Includes module loaded")

-- Test parsing
local result = includes.parse_includes(bufnr, "cpp")
print("Parsed " .. #result .. " includes:")
for i, inc in ipairs(result) do
  print("  " .. i .. ": " .. inc)
end

vim.cmd("qall!")
