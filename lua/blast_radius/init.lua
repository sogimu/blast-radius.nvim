local config = require("blast_radius.config")
local cache = require("blast_radius.cache")
local graph = require("blast_radius.graph")
local git = require("blast_radius.git")
local ui = require("blast_radius.ui")

local M = {}

M.config = nil

function M.setup(opts)
  config.validate(opts)
  M.config = vim.tbl_deep_extend("force", config.defaults, opts or {})

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("BlastRadiusCache", { clear = true }),
    callback = function(args)
      cache.invalidate(args.buf)
    end,
  })
end

function M.run(opts)
  local cfg = vim.tbl_deep_extend("force", M.config or config.defaults, opts or {})
  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)

  if bufname == "" then
    vim.notify("blast-radius.nvim: current buffer has no filename", vim.log.levels.WARN)
    return
  end

  local cursor = table.concat(vim.api.nvim_win_get_cursor(0), ",")
  local graph_cache_key = "graph:" .. vim.fn.sha256(bufname .. cursor)
  local cached_graph = cache.get(graph_cache_key)

  local function proceed_with_graph(graph_result)
    if not graph_result or #graph_result.files == 0 then
      vim.notify("blast-radius.nvim: no dependencies found", vim.log.levels.INFO)
      return
    end

    local files_str = table.concat(graph_result.files, "\n")
    local git_cache_key = "git:" .. vim.fn.sha256(files_str)
    local cached_git = cache.get(git_cache_key)

    vim.notify("blast-radius.nvim: proceed_with_graph | files=" .. #graph_result.files .. " | cached_git=" .. (cached_git and #cached_git or "nil"), vim.log.levels.INFO)

    if cached_git then
      ui.render(cached_git, graph_result.files, cfg)
    else
      git.get_recent_changes(graph_result.files, cfg, function(changes)
        cache.set(git_cache_key, changes, cfg.cache_ttl, graph_result.files)
        ui.render(changes, graph_result.files, cfg)
      end)
    end
  end

  if cached_graph then
    proceed_with_graph(cached_graph)
  else
    graph.build_from_cursor(bufnr, cfg, function(graph_result)
      if graph_result and #graph_result.files > 0 then
        cache.set(graph_cache_key, graph_result, cfg.cache_ttl, graph_result.files)
      end
      proceed_with_graph(graph_result)
    end)
  end
end

return M
