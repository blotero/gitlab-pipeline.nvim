-- Multi-window UI for gitlab-ide.nvim
local M = {}
local api = require("gitlab-ide.api")

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
	windows = {}, -- List of window IDs
	buffers = {}, -- List of buffer IDs
	current_stage = 1, -- Currently focused stage index
	pipeline = nil, -- Current pipeline data
	refresh_fn = nil, -- Function to refresh data
	api_context = nil, -- { gitlab_url, token, project_path }
	view = "pipeline", -- "pipeline" or "log"
	log_state = nil, -- { window, buffer, job, timer }
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

--- Strip ANSI escape codes from text
---@param text string Text with potential ANSI codes
---@return string cleaned Text without ANSI codes
local function strip_ansi(text)
	return text:gsub("\27%[[%d;]*[A-Za-z]", "")
end

--- Get the job under the cursor in the current stage window
---@return table|nil job The job data, or nil if cursor is not on a job
---@return number|nil stage_index The stage index
local function get_job_under_cursor()
	local win = vim.api.nvim_get_current_win()

	-- Find which stage this window belongs to
	local stage_index = nil
	for i, w in ipairs(state.windows) do
		if w == win then
			stage_index = i
			break
		end
	end

	if not stage_index then
		return nil, nil
	end

	local cursor_row = vim.api.nvim_win_get_cursor(win)[1]
	-- Row 1: header, Row 2: separator, Rows 3+: jobs
	local job_index = cursor_row - 2

	if job_index < 1 then
		return nil, nil
	end

	local stages = state.pipeline and state.pipeline.stages and state.pipeline.stages.nodes or {}
	local stage = stages[stage_index]
	if not stage or not stage.jobs or not stage.jobs.nodes then
		return nil, nil
	end

	local job = stage.jobs.nodes[job_index]
	if not job then
		return nil, nil
	end

	return job, stage_index
end

-- Forward declarations
local close_log_view
local open_log_view
local setup_log_keymaps

--- Close all pipeline stage windows and buffers (not log view)
local function close_pipeline_windows()
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
end

--- Close all UI windows and clean up
function M.close()
	-- Clean up log state if active
	if state.log_state then
		if state.log_state.timer then
			state.log_state.timer:stop()
			state.log_state.timer:close()
			state.log_state.timer = nil
		end
		if state.log_state.window and vim.api.nvim_win_is_valid(state.log_state.window) then
			vim.api.nvim_win_close(state.log_state.window, true)
		end
		if state.log_state.buffer and vim.api.nvim_buf_is_valid(state.log_state.buffer) then
			vim.api.nvim_buf_delete(state.log_state.buffer, { force = true })
		end
		state.log_state = nil
	end

	close_pipeline_windows()

	state.current_stage = 1
	state.pipeline = nil
	state.view = "pipeline"
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

--- Set up keybindings for a pipeline stage buffer
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

	-- Cancel job under cursor
	vim.keymap.set("n", "c", function()
		local job = get_job_under_cursor()
		if not job then
			vim.notify("No job under cursor", vim.log.levels.WARN)
			return
		end
		if not state.api_context then
			vim.notify("API context not available", vim.log.levels.ERROR)
			return
		end
		vim.ui.select({ "Yes", "No" }, {
			prompt = string.format("Cancel job '%s'?", job.name),
		}, function(choice)
			if choice ~= "Yes" then
				return
			end
			local ctx = state.api_context
			api.cancel_job(ctx.gitlab_url, ctx.token, ctx.project_path, job.id, function(err)
				if err then
					vim.notify("Cancel failed: " .. err, vim.log.levels.ERROR)
					return
				end
				vim.notify("Job '" .. job.name .. "' canceled", vim.log.levels.INFO)
				if state.refresh_fn then
					state.refresh_fn()
				end
			end)
		end)
	end, opts)

	-- Retry job under cursor
	vim.keymap.set("n", "x", function()
		local job = get_job_under_cursor()
		if not job then
			vim.notify("No job under cursor", vim.log.levels.WARN)
			return
		end
		if not state.api_context then
			vim.notify("API context not available", vim.log.levels.ERROR)
			return
		end
		local ctx = state.api_context
		api.retry_job(ctx.gitlab_url, ctx.token, ctx.project_path, job.id, function(err)
			if err then
				vim.notify("Retry failed: " .. err, vim.log.levels.ERROR)
				return
			end
			vim.notify("Job '" .. job.name .. "' retried", vim.log.levels.INFO)
			if state.refresh_fn then
				state.refresh_fn()
			end
		end)
	end, opts)

	-- Cancel entire pipeline
	vim.keymap.set("n", "C", function()
		if not state.pipeline or not state.api_context then
			vim.notify("No pipeline or API context", vim.log.levels.WARN)
			return
		end
		vim.ui.select({ "Yes", "No" }, {
			prompt = string.format("Cancel pipeline #%s?", state.pipeline.iid),
		}, function(choice)
			if choice ~= "Yes" then
				return
			end
			local ctx = state.api_context
			api.cancel_pipeline(ctx.gitlab_url, ctx.token, ctx.project_path, state.pipeline.id, function(err)
				if err then
					vim.notify("Cancel pipeline failed: " .. err, vim.log.levels.ERROR)
					return
				end
				vim.notify("Pipeline #" .. state.pipeline.iid .. " canceled", vim.log.levels.INFO)
				if state.refresh_fn then
					state.refresh_fn()
				end
			end)
		end)
	end, opts)

	-- Retry failed jobs in pipeline
	vim.keymap.set("n", "X", function()
		if not state.pipeline or not state.api_context then
			vim.notify("No pipeline or API context", vim.log.levels.WARN)
			return
		end
		local ctx = state.api_context
		api.retry_pipeline(ctx.gitlab_url, ctx.token, ctx.project_path, state.pipeline.id, function(err)
			if err then
				vim.notify("Retry pipeline failed: " .. err, vim.log.levels.ERROR)
				return
			end
			vim.notify("Pipeline #" .. state.pipeline.iid .. " retried", vim.log.levels.INFO)
			if state.refresh_fn then
				state.refresh_fn()
			end
		end)
	end, opts)

	-- Open job log (drill-down)
	vim.keymap.set("n", "<CR>", function()
		local job = get_job_under_cursor()
		if not job then
			vim.notify("No job under cursor", vim.log.levels.WARN)
			return
		end
		open_log_view(job)
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

	-- Keybinding hints
	table.insert(lines, "")
	local hint = " ⏎:log c:cancel x:retry C/X:pipeline"
	table.insert(lines, hint)
	table.insert(highlights_to_apply, {
		line = #lines - 1,
		col_start = 0,
		col_end = #hint,
		hl_group = "Comment",
	})

	-- Set buffer content
	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	-- Apply highlights
	local ns_id = vim.api.nvim_create_namespace("gitlab_ide")
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

--- Open the log view for a job (drill-down from pipeline view)
---@param job table Job data from the pipeline
open_log_view = function(job)
	if not state.api_context then
		vim.notify("API context not available", vim.log.levels.ERROR)
		return
	end

	-- Close pipeline windows
	close_pipeline_windows()

	state.view = "log"

	-- Calculate dimensions (~85% of editor)
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local width = math.floor(editor_width * 0.85)
	local height = math.floor(editor_height * 0.85)
	local col = math.floor((editor_width - width) / 2)
	local row = math.floor((editor_height - height) / 2)

	-- Create log buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "swapfile", false)

	-- Create log window
	local job_icon = get_icon(job.status)
	local title = string.format(" %s %s [%s] ", job_icon, job.name, job.status)
	local footer = " q:back r:refresh Esc:close "
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "rounded",
		title = title,
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
	})

	vim.api.nvim_win_set_option(win, "wrap", true)

	state.log_state = {
		window = win,
		buffer = buf,
		job = job,
		timer = nil,
	}

	-- Show loading placeholder
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading job log..." })

	-- Set up log keymaps
	setup_log_keymaps(buf)

	-- Fetch and display log
	local function fetch_and_display_log()
		local ctx = state.api_context
		api.fetch_job_log(ctx.gitlab_url, ctx.token, ctx.project_path, job.id, function(err, log_text)
			if not state.log_state or state.log_state.buffer ~= buf then
				return -- View was closed while fetching
			end
			if err then
				if vim.api.nvim_buf_is_valid(buf) then
					vim.api.nvim_buf_set_option(buf, "modifiable", true)
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Error fetching log: " .. err })
					vim.api.nvim_buf_set_option(buf, "modifiable", false)
				end
				return
			end

			local cleaned = strip_ansi(log_text)
			local lines = vim.split(cleaned, "\n", { trimempty = false })

			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_set_option(buf, "modifiable", true)
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
				vim.api.nvim_buf_set_option(buf, "modifiable", false)

				-- Scroll to bottom
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_set_cursor(win, { math.max(1, #lines), 0 })
				end
			end
		end)
	end

	fetch_and_display_log()

	-- Auto-refresh for running/pending jobs
	if job.status == "RUNNING" or job.status == "PENDING" then
		local timer = vim.uv.new_timer()
		state.log_state.timer = timer
		timer:start(
			5000,
			5000,
			vim.schedule_wrap(function()
				if not state.log_state or state.log_state.buffer ~= buf then
					timer:stop()
					timer:close()
					return
				end
				fetch_and_display_log()
			end)
		)
	end
end

--- Close the log view and return to the pipeline view
close_log_view = function()
	if state.log_state then
		if state.log_state.timer then
			state.log_state.timer:stop()
			state.log_state.timer:close()
			state.log_state.timer = nil
		end
		if state.log_state.window and vim.api.nvim_win_is_valid(state.log_state.window) then
			vim.api.nvim_win_close(state.log_state.window, true)
		end
		if state.log_state.buffer and vim.api.nvim_buf_is_valid(state.log_state.buffer) then
			vim.api.nvim_buf_delete(state.log_state.buffer, { force = true })
		end
		state.log_state = nil
	end

	state.view = "pipeline"

	-- Reopen pipeline view
	if state.pipeline then
		M.open(state.pipeline, state.refresh_fn, state.api_context)
	end
end

--- Set up keybindings for the log view buffer
---@param buf number Buffer ID
setup_log_keymaps = function(buf)
	local opts = { noremap = true, silent = true, buffer = buf }

	-- Back to pipeline view
	vim.keymap.set("n", "q", function()
		close_log_view()
	end, opts)
	vim.keymap.set("n", "<BS>", function()
		close_log_view()
	end, opts)

	-- Full close (exit everything)
	vim.keymap.set("n", "<Esc>", function()
		M.close()
	end, opts)

	-- Manual log refresh
	vim.keymap.set("n", "r", function()
		if not state.log_state or not state.api_context then
			return
		end
		local job = state.log_state.job
		local log_buf = state.log_state.buffer
		local log_win = state.log_state.window
		local ctx = state.api_context
		api.fetch_job_log(ctx.gitlab_url, ctx.token, ctx.project_path, job.id, function(err, log_text)
			if not state.log_state or state.log_state.buffer ~= log_buf then
				return
			end
			if err then
				vim.notify("Log refresh failed: " .. err, vim.log.levels.ERROR)
				return
			end
			local cleaned = strip_ansi(log_text)
			local lines = vim.split(cleaned, "\n", { trimempty = false })
			if vim.api.nvim_buf_is_valid(log_buf) then
				vim.api.nvim_buf_set_option(log_buf, "modifiable", true)
				vim.api.nvim_buf_set_lines(log_buf, 0, -1, false, lines)
				vim.api.nvim_buf_set_option(log_buf, "modifiable", false)
				if vim.api.nvim_win_is_valid(log_win) then
					vim.api.nvim_win_set_cursor(log_win, { math.max(1, #lines), 0 })
				end
			end
		end)
	end, opts)
end

--- Open the pipeline UI
---@param pipeline table Pipeline data from API
---@param refresh_fn function|nil Optional function to refresh data
---@param api_context table|nil API context { gitlab_url, token, project_path }
function M.open(pipeline, refresh_fn, api_context)
	-- Close any existing UI
	M.close()

	state.pipeline = pipeline
	state.refresh_fn = refresh_fn
	state.api_context = api_context or state.api_context
	state.view = "pipeline"

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
		M.open(pipeline, state.refresh_fn, state.api_context)
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
	vim.notify(
		string.format("Pipeline #%s %s %s (refreshed)", pipeline.iid, status_icon, pipeline.status),
		vim.log.levels.INFO
	)
end

return M
