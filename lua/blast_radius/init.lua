local config = require("blast_radius.config")
local cache = require("blast_radius.cache")
local graph = require("blast_radius.graph")
local git = require("blast_radius.git")
local ui = require("blast_radius.ui")
local utils = require("blast_radius.utils")

local M = {}

local GROUP_NAME = "blast_radius"
local AUGROUP = nil
local LOG_FILE = "/tmp/blast-radius.log"

local function log(msg)
  local f = io.open(LOG_FILE, "a")
  if f then
    f:write(os.date("[%H:%M:%S] ") .. msg .. "\n")
    f:close()
  end
end

--- Setup the plugin
--- @param opts? table
function M.setup(opts)
  opts = opts or {}
  config.setup(opts)

  AUGROUP = vim.api.nvim_create_augroup(GROUP_NAME, { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = AUGROUP,
    callback = function(args)
      local file = vim.api.nvim_buf_get_name(args.buf)
      if file and file ~= "" then
        cache.invalidate_file(file)
      end
    end,
    desc = "Invalidate cache when a file is written",
  })
end

--- Format stats into a readable view
--- @param stats table
--- @return string
local function format_stats(stats)
  local lines = { "⚡ Blast Radius Performance Stats", "" }

  local names = stats.list_names() or {}
  table.sort(names)

  for _, name in ipairs(names) do
    local metric = stats.get(name)
    if metric then
      table.insert(lines, string.format("  %-30s calls: %d | avg: %.1fms | min: %.1fms | max: %.1fms",
        name,
        metric.count,
        metric.avg_ms,
        metric.min_ms,
        metric.max_ms
      ))
    end
  end

  if #names == 0 then
    table.insert(lines, "  (no stats recorded)")
  end

  return table.concat(lines, "\n")
end

--- Get the symbol under cursor for display purposes
--- @param bufnr number?
--- @return string symbol
local function get_cursor_symbol(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ok, node = pcall(function()
    local win = vim.api.nvim_get_current_win()
    local cursor = vim.api.nvim_win_get_cursor(win)
    return vim.treesitter.get_node({ pos = { cursor[1] - 1, cursor[2] }, bufnr = bufnr })
  end)
  if ok and node then
    return table.concat(vim.treesitter.get_node_text(node, bufnr) or {}, " ")
  end
  return "<unknown>"
end

--- Full analysis run with caching
--- @param opts? { max_depth?: number, since?: string, max_commits?: number, ui_provider?: string, enable_stats?: boolean }
function M.run(opts)
  opts = opts or {}
  utils.stats.start("run")

  local bufnr = vim.api.nvim_get_current_buf()
  local current_file = vim.api.nvim_buf_get_name(bufnr)

  local graph_cache_key = cache.make_key("graph", { file = current_file, depth = opts.max_depth })
  local graph_result = cache.get(graph_cache_key)

  local function proceed_with_graph(gr)
    local change_cache_key = cache.make_key("git", {
      files = gr.files or {},
      since = opts.since or "30 days ago",
      max_commits = opts.max_commits or 500,
    })
    local changes = cache.get(change_cache_key)

    if changes then
      git.map_changes_to_files(changes, gr.files or {}, function(enriched)
        ui.render(enriched, gr, opts)

        if opts.enable_stats then
          vim.notify(format_stats(utils.stats), vim.log.levels.INFO, { title = "blast-radius" })
        end

        utils.stats.stop("run")
      end)
    else
      git.get_recent_changes(gr.files or {}, {
        since = opts.since or "30 days ago",
        max_commits = opts.max_commits or 500,
      }, function(new_changes)
        cache.set(change_cache_key, new_changes, gr.files or {})

        git.map_changes_to_files(new_changes, gr.files or {}, function(enriched)
          ui.render(enriched, gr, opts)

          if opts.enable_stats then
            vim.notify(format_stats(utils.stats), vim.log.levels.INFO, { title = "blast-radius" })
          end

          utils.stats.stop("run")
        end)
      end)
    end
  end

  if graph_result then
    vim.print("[blast-radius] Using cached graph (" .. #graph_result.files .. " files)...")
    proceed_with_graph(graph_result)
  else
    vim.print("[blast-radius] Analyzing dependencies for: " .. current_file)

    graph.build_from_cursor({
      max_depth = opts.max_depth or 10,
    }, function(gr)
      local file_count = gr.files and #gr.files or 0
      vim.print("[blast-radius] Graph result: " .. file_count .. " file(s)")
      if gr.files then
        for i, f in ipairs(gr.files) do
          vim.print("  -> " .. i .. ": " .. f)
        end
      end
      vim.print("[blast-radius] Changes from git:")

      cache.set(graph_cache_key, gr, gr.files or {})

      if file_count == 0 then
        vim.print("[blast-radius] No related files. Check:")
        vim.print("  :lua vim.print(vim.lsp.get_clients())")
        vim.print("  :checkhealth nvim-treesitter")
        utils.stats.stop("run")
        return
      end

      proceed_with_graph(gr)
    end)
  end
end

--- Clear all cache
function M.clear_cache()
  cache.clear_all()
  utils.stats.clear()
  vim.notify("Cache cleared.", vim.log.levels.INFO, { title = "blast-radius" })
end

--- Show performance statistics
function M.show_stats()
  vim.notify(format_stats(utils.stats), vim.log.levels.INFO, { title = "blast-radius" })
end

return M
