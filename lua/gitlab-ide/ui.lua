-- Multi-window UI orchestrator for gitlab-ide.nvim
local M = {}
local api = require("gitlab-ide.api")
local icons = require("gitlab-ide.ui.icons")
local log = require("gitlab-ide.ui.log")
local pipeline = require("gitlab-ide.ui.pipeline")

-- UI state
local state = {
	windows = {}, -- List of window IDs
	buffers = {}, -- List of buffer IDs
	current_stage = 1, -- Currently focused stage index
	pipeline = nil, -- Currently displayed pipeline data (root or drilled-into)
	pipeline_stack = {}, -- Stack of { pipeline, label } for pipelines above the current one
	refresh_fn = nil, -- Function to refresh the root pipeline (by branch)
	api_context = nil, -- { gitlab_url, token, project_path }
	on_switch_branch = nil, -- callback to open branch picker
	view = "pipeline", -- "pipeline" or "log"
	log_state = nil, -- { window, buffer, job, timer }
}

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

	pipeline.close_windows(state)

	state.current_stage = 1
	state.pipeline = nil
	state.pipeline_stack = {}
	state.view = "pipeline"
end

--- Render column windows for a pipeline (root, drilled-in, or drilled-out-to).
--- Does not touch state.pipeline_stack - callers push/pop before calling this.
---@param pipeline_data table Pipeline data from API
local function render_pipeline(pipeline_data)
	pipeline.close_windows(state)
	state.pipeline = pipeline_data
	state.view = "pipeline"

	local stages = pipeline_data.stages and pipeline_data.stages.nodes or {}
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

	-- Callbacks for sub-modules
	local callbacks = {
		close = function()
			M.close()
		end,
		open_log = function(job)
			log.open(job, state, function()
				pipeline.close_windows(state)
			end, function()
				M.close()
			end, function()
				if state.pipeline then
					render_pipeline(state.pipeline)
				end
			end)
		end,
		drill_in = function(job)
			M.drill_in(job)
		end,
		drill_out = function()
			M.drill_out()
		end,
		refresh = function()
			M.refresh_current()
		end,
	}

	-- Create windows for each stage
	for i, stage in ipairs(stages) do
		local col = start_col + (i - 1) * (stage_width + 2)
		local win, buf = pipeline.create_stage_window(stage, col, stage_width, stage_height, start_row, state, callbacks)
		table.insert(state.windows, win)
		table.insert(state.buffers, buf)
	end

	-- Focus first stage
	state.current_stage = 1
	if state.windows[1] and vim.api.nvim_win_is_valid(state.windows[1]) then
		vim.api.nvim_set_current_win(state.windows[1])
	end

	-- Show pipeline info in statusline area
	local status_icon = icons.get_icon(pipeline_data.status)
	local created = pipeline_data.createdAt and pipeline_data.createdAt:match("^[^T]+") or "unknown"
	local breadcrumb = ""
	if #state.pipeline_stack > 0 then
		local labels = {}
		for _, entry in ipairs(state.pipeline_stack) do
			table.insert(labels, entry.label)
		end
		breadcrumb = " (" .. table.concat(labels, " › ") .. ")"
	end
	vim.notify(
		string.format(
			"Pipeline #%s%s %s %s (created: %s)",
			pipeline_data.iid,
			breadcrumb,
			status_icon,
			pipeline_data.status,
			created
		),
		vim.log.levels.INFO
	)
end

--- Open the pipeline UI
---@param pipeline_data table Pipeline data from API
---@param refresh_fn function|nil Optional function to refresh the root pipeline
---@param api_context table|nil API context { gitlab_url, token, project_path }
---@param on_switch_branch function|nil Callback to open branch picker
function M.open(pipeline_data, refresh_fn, api_context, on_switch_branch)
	-- Close any existing UI
	M.close()

	state.refresh_fn = refresh_fn
	state.api_context = api_context or state.api_context
	state.on_switch_branch = on_switch_branch or state.on_switch_branch

	render_pipeline(pipeline_data)
end

--- Drill into a bridge (trigger) job's downstream pipeline
---@param job table Job data (must have kind == "BRIDGE" and a downstreamPipeline stub)
function M.drill_in(job)
	if not job then
		return
	end

	local downstream = job.downstreamPipeline
	if not downstream or not downstream.iid then
		vim.notify("No downstream pipeline for job '" .. job.name .. "'", vim.log.levels.WARN)
		return
	end

	if not state.api_context then
		vim.notify("API context not available", vim.log.levels.ERROR)
		return
	end

	local ctx = state.api_context
	vim.notify("Fetching downstream pipeline for '" .. job.name .. "'...", vim.log.levels.INFO)
	api.fetch_pipeline_by_id(ctx.gitlab_url, ctx.token, ctx.project_path, downstream.iid, function(err, downstream_pipeline)
		if err then
			vim.notify("Drill-in failed: " .. err, vim.log.levels.ERROR)
			return
		end

		table.insert(state.pipeline_stack, { pipeline = state.pipeline, label = job.name })
		render_pipeline(downstream_pipeline)
	end)
end

--- Drill back out to the parent pipeline
function M.drill_out()
	if #state.pipeline_stack == 0 then
		vim.notify("Already at the top-level pipeline", vim.log.levels.INFO)
		return
	end

	local parent = table.remove(state.pipeline_stack)
	render_pipeline(parent.pipeline)
end

--- Refresh whichever pipeline (root or drilled-into) is currently displayed
function M.refresh_current()
	if #state.pipeline_stack == 0 then
		if state.refresh_fn then
			state.refresh_fn()
		end
		return
	end

	if not state.api_context or not state.pipeline or not state.pipeline.iid then
		vim.notify("Cannot refresh: missing pipeline context", vim.log.levels.ERROR)
		return
	end

	local ctx = state.api_context
	api.fetch_pipeline_by_id(ctx.gitlab_url, ctx.token, ctx.project_path, state.pipeline.iid, function(err, pipeline_data)
		if err then
			vim.notify("Refresh failed: " .. err, vim.log.levels.ERROR)
			return
		end
		M.refresh(pipeline_data)
	end)
end

--- Refresh the UI with new pipeline data (re-renders in place, preserving drill-in depth)
---@param pipeline_data table Pipeline data from API
function M.refresh(pipeline_data)
	if #state.windows == 0 then
		render_pipeline(pipeline_data)
		return
	end

	state.pipeline = pipeline_data
	local stages = pipeline_data.stages and pipeline_data.stages.nodes or {}
	local has_parent = #state.pipeline_stack > 0

	-- Re-render existing buffers
	for i, buf in ipairs(state.buffers) do
		if vim.api.nvim_buf_is_valid(buf) and stages[i] then
			pipeline.render_stage(buf, stages[i], has_parent)
		end
	end

	-- Show updated status
	local status_icon = icons.get_icon(pipeline_data.status)
	vim.notify(
		string.format("Pipeline #%s %s %s (refreshed)", pipeline_data.iid, status_icon, pipeline_data.status),
		vim.log.levels.INFO
	)
end

return M
