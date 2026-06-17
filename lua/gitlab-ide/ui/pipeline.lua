-- Pipeline stage view for gitlab-ide.nvim
local M = {}
local api = require("gitlab-ide.api")
local icons = require("gitlab-ide.ui.icons")

--- Get the job under the cursor in the current stage window
---@param state table UI state reference
---@return table|nil job The job data, or nil if cursor is not on a job
---@return number|nil stage_index The stage index
function M.get_job_under_cursor(state)
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

--- Close all pipeline stage windows and buffers (not log view)
---@param state table UI state reference
function M.close_windows(state)
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

--- Move focus to a different stage column
---@param state table UI state reference
---@param direction number Direction to move (-1 for left, 1 for right)
function M.move_stage(state, direction)
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

--- Render a stage buffer with jobs
---@param buf number Buffer ID
---@param stage table Stage data
function M.render_stage(buf, stage)
	local lines = {}
	local highlights_to_apply = {}

	-- Stage header
	local stage_icon = icons.get_icon(stage.status)
	local header = string.format(" %s %s ", stage_icon, stage.name)
	table.insert(lines, header)
	table.insert(lines, string.rep("─", 30))

	-- Add highlight for header
	table.insert(highlights_to_apply, {
		line = 0,
		col_start = 1,
		col_end = #stage_icon + 1,
		hl_group = icons.get_highlight(stage.status),
	})

	-- Jobs
	if stage.jobs and stage.jobs.nodes then
		for _, job in ipairs(stage.jobs.nodes) do
			local job_icon = icons.get_icon(job.status)
			local job_line = string.format("  %s %s", job_icon, job.name)
			table.insert(lines, job_line)

			-- Add highlight for job icon
			table.insert(highlights_to_apply, {
				line = #lines - 1,
				col_start = 2,
				col_end = 2 + #job_icon,
				hl_group = icons.get_highlight(job.status),
			})
		end
	end

	-- Keybinding hints
	table.insert(lines, "")
	local hint = " ⏎:log o:open O:pipeline b:branch c:cancel x:retry C/X:pipeline m:MR"
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

--- Set up keybindings for a pipeline stage buffer
---@param buf number Buffer ID
---@param state table UI state reference
---@param callbacks table { close, open_log }
local function setup_keymaps(buf, state, callbacks)
	local opts = { noremap = true, silent = true, buffer = buf }

	-- Navigation between stages
	vim.keymap.set("n", "h", function()
		M.move_stage(state, -1)
	end, opts)
	vim.keymap.set("n", "l", function()
		M.move_stage(state, 1)
	end, opts)

	-- Close window
	vim.keymap.set("n", "q", function()
		callbacks.close()
	end, opts)
	vim.keymap.set("n", "<Esc>", function()
		callbacks.close()
	end, opts)

	-- Refresh
	vim.keymap.set("n", "r", function()
		if state.refresh_fn then
			state.refresh_fn()
		end
	end, opts)

	-- Cancel job under cursor
	vim.keymap.set("n", "c", function()
		local job = M.get_job_under_cursor(state)
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
		local job = M.get_job_under_cursor(state)
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
		local job = M.get_job_under_cursor(state)
		if not job then
			vim.notify("No job under cursor", vim.log.levels.WARN)
			return
		end
		callbacks.open_log(job)
	end, opts)

	-- Open job URL in browser
	vim.keymap.set("n", "o", function()
		local job = M.get_job_under_cursor(state)
		if not job then
			vim.notify("No job under cursor", vim.log.levels.WARN)
			return
		end
		if not state.api_context or not job.webPath then
			vim.notify("Job URL not available", vim.log.levels.ERROR)
			return
		end
		vim.ui.open(state.api_context.gitlab_url .. job.webPath)
	end, opts)

	-- Open pipeline URL in browser
	vim.keymap.set("n", "O", function()
		if not state.api_context or not state.pipeline or not state.pipeline.id then
			vim.notify("Pipeline URL not available", vim.log.levels.ERROR)
			return
		end
		local pipeline_id = state.pipeline.id:match("/(%d+)$")
		if not pipeline_id then
			vim.notify("Could not parse pipeline ID", vim.log.levels.ERROR)
			return
		end
		local url = state.api_context.gitlab_url
			.. "/"
			.. state.api_context.project_path
			.. "/-/pipelines/"
			.. pipeline_id
		vim.ui.open(url)
	end, opts)

	-- Switch branch
	vim.keymap.set("n", "b", function()
		if state.on_switch_branch then
			state.on_switch_branch()
		end
	end, opts)

	-- Create merge request
	vim.keymap.set("n", "m", function()
		if not state.api_context then
			vim.notify("API context not available", vim.log.levels.ERROR)
			return
		end
		require("gitlab-ide.mr").open_create_view(state.api_context)
	end, opts)
end

--- Create a floating window for a stage
---@param stage table Stage data
---@param col number Column position
---@param width number Window width
---@param height number Window height
---@param row number Row position
---@param state table UI state reference
---@param callbacks table { close, open_log }
---@return number win Window ID
---@return number buf Buffer ID
function M.create_stage_window(stage, col, width, height, row, state, callbacks)
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
	M.render_stage(buf, stage)

	-- Set up keymaps
	setup_keymaps(buf, state, callbacks)

	return win, buf
end

return M
