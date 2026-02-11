-- Multi-window UI for gitlab-pipeline.nvim
local M = {}

-- Status icons mapping
local icons = {
  SUCCESS = "✓",
  FAILED = "✗",
  RUNNING = "●",
  PENDING = "○",
  SKIPPED = "⊘",
  CANCELED = "⊘",
  MANUAL = "▶",
  CREATED = "○",
  WAITING_FOR_RESOURCE = "○",
  PREPARING = "○",
  SCHEDULED = "◷",
}

-- Highlight groups mapping
local highlights = {
  SUCCESS = "DiagnosticOk",
  FAILED = "DiagnosticError",
  RUNNING = "DiagnosticInfo",
  PENDING = "Comment",
  SKIPPED = "Comment",
  CANCELED = "DiagnosticWarn",
  MANUAL = "DiagnosticHint",
  CREATED = "Comment",
  WAITING_FOR_RESOURCE = "Comment",
  PREPARING = "DiagnosticInfo",
  SCHEDULED = "DiagnosticHint",
}

-- UI state
local state = {
  windows = {},      -- List of window IDs
  buffers = {},      -- List of buffer IDs
  current_stage = 1, -- Currently focused stage index
  pipeline = nil,    -- Current pipeline data
  refresh_fn = nil,  -- Function to refresh data
}

--- Get the icon for a status
---@param status string The job/stage status
---@return string icon The status icon
local function get_icon(status)
  return icons[status] or "?"
end

--- Get the highlight group for a status
---@param status string The job/stage status
---@return string highlight The highlight group name
local function get_highlight(status)
  return highlights[status] or "Normal"
end

--- Close all UI windows and clean up
function M.close()
  for _, win in ipairs(state.windows) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  for _, buf in ipairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  state.windows = {}
  state.buffers = {}
  state.current_stage = 1
  state.pipeline = nil
end

--- Move focus to a different stage column
---@param direction number Direction to move (-1 for left, 1 for right)
local function move_stage(direction)
  local num_stages = #state.windows
  if num_stages == 0 then
    return
  end

  local new_stage = state.current_stage + direction
  if new_stage < 1 then
    new_stage = num_stages
  elseif new_stage > num_stages then
    new_stage = 1
  end

  state.current_stage = new_stage
  local win = state.windows[new_stage]
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

--- Set up keybindings for a buffer
---@param buf number Buffer ID
local function setup_keymaps(buf)
  local opts = { noremap = true, silent = true, buffer = buf }

  -- Navigation between stages
  vim.keymap.set("n", "h", function()
    move_stage(-1)
  end, opts)
  vim.keymap.set("n", "l", function()
    move_stage(1)
  end, opts)

  -- Close window
  vim.keymap.set("n", "q", function()
    M.close()
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    M.close()
  end, opts)

  -- Refresh
  vim.keymap.set("n", "r", function()
    if state.refresh_fn then
      state.refresh_fn()
    end
  end, opts)
end

--- Render a stage buffer with jobs
---@param buf number Buffer ID
---@param stage table Stage data
local function render_stage(buf, stage)
  local lines = {}
  local highlights_to_apply = {}

  -- Stage header
  local stage_icon = get_icon(stage.status)
  local header = string.format(" %s %s ", stage_icon, stage.name)
  table.insert(lines, header)
  table.insert(lines, string.rep("─", 30))

  -- Add highlight for header
  table.insert(highlights_to_apply, {
    line = 0,
    col_start = 1,
    col_end = #stage_icon + 1,
    hl_group = get_highlight(stage.status),
  })

  -- Jobs
  if stage.jobs and stage.jobs.nodes then
    for _, job in ipairs(stage.jobs.nodes) do
      local job_icon = get_icon(job.status)
      local job_line = string.format("  %s %s", job_icon, job.name)
      table.insert(lines, job_line)

      -- Add highlight for job icon
      table.insert(highlights_to_apply, {
        line = #lines - 1,
        col_start = 2,
        col_end = 2 + #job_icon,
        hl_group = get_highlight(job.status),
      })
    end
  end

  -- Set buffer content
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  -- Apply highlights
  local ns_id = vim.api.nvim_create_namespace("gitlab_pipeline")
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
  for _, hl in ipairs(highlights_to_apply) do
    vim.api.nvim_buf_add_highlight(buf, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
  end
end

--- Create a floating window for a stage
---@param stage table Stage data
---@param col number Column position
---@param width number Window width
---@param height number Window height
---@param row number Row position
---@return number win Window ID
---@return number buf Buffer ID
local function create_stage_window(stage, col, width, height, row)
  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)

  -- Create window
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = "rounded",
    title = " " .. stage.name .. " ",
    title_pos = "center",
  })

  -- Set window options
  vim.api.nvim_win_set_option(win, "cursorline", true)
  vim.api.nvim_win_set_option(win, "wrap", false)

  -- Render content
  render_stage(buf, stage)

  -- Set up keymaps
  setup_keymaps(buf)

  return win, buf
end

--- Open the pipeline UI
---@param pipeline table Pipeline data from API
---@param refresh_fn function|nil Optional function to refresh data
function M.open(pipeline, refresh_fn)
  -- Close any existing UI
  M.close()

  state.pipeline = pipeline
  state.refresh_fn = refresh_fn

  local stages = pipeline.stages and pipeline.stages.nodes or {}
  if #stages == 0 then
    vim.notify("No stages found in pipeline", vim.log.levels.WARN)
    return
  end

  -- Calculate dimensions
  local editor_width = vim.o.columns
  local editor_height = vim.o.lines

  local total_width = math.floor(editor_width * 0.8)
  local total_height = math.floor(editor_height * 0.7)

  local num_stages = #stages
  local stage_width = math.floor((total_width - (num_stages - 1) * 2) / num_stages)
  local stage_height = total_height - 2

  -- Calculate starting position (centered)
  local start_col = math.floor((editor_width - total_width) / 2)
  local start_row = math.floor((editor_height - total_height) / 2)

  -- Create windows for each stage
  for i, stage in ipairs(stages) do
    local col = start_col + (i - 1) * (stage_width + 2)
    local win, buf = create_stage_window(stage, col, stage_width, stage_height, start_row)
    table.insert(state.windows, win)
    table.insert(state.buffers, buf)
  end

  -- Focus first stage
  state.current_stage = 1
  if state.windows[1] and vim.api.nvim_win_is_valid(state.windows[1]) then
    vim.api.nvim_set_current_win(state.windows[1])
  end

  -- Show pipeline info in statusline area
  local status_icon = get_icon(pipeline.status)
  local created = pipeline.createdAt and pipeline.createdAt:match("^[^T]+") or "unknown"
  vim.notify(
    string.format("Pipeline #%s %s %s (created: %s)", pipeline.iid, status_icon, pipeline.status, created),
    vim.log.levels.INFO
  )
end

--- Refresh the UI with new pipeline data
---@param pipeline table Pipeline data from API
function M.refresh(pipeline)
  if #state.windows == 0 then
    M.open(pipeline, state.refresh_fn)
    return
  end

  state.pipeline = pipeline
  local stages = pipeline.stages and pipeline.stages.nodes or {}

  -- Re-render existing buffers
  for i, buf in ipairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(buf) and stages[i] then
      render_stage(buf, stages[i])
    end
  end

  -- Show updated status
  local status_icon = get_icon(pipeline.status)
  vim.notify(string.format("Pipeline #%s %s %s (refreshed)", pipeline.iid, status_icon, pipeline.status), vim.log.levels.INFO)
end

return M
