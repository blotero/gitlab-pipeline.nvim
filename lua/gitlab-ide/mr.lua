-- Merge Request UI for gitlab-ide.nvim
local M = {}
local api = require("gitlab-ide.api")
local git = require("gitlab-ide.git")
local pipeline_icons = require("gitlab-ide.ui.icons")

-- MR state icons
local mr_icons = {
	opened = " ",
	merged = " ",
	closed = " ",
	draft = " ",
}

-- MR state highlights
local mr_highlights = {
	opened = "DiagnosticInfo",
	merged = "DiagnosticOk",
	closed = "DiagnosticError",
	draft = "DiagnosticWarn",
}

-- Filter state cycle order
local MR_STATE_CYCLE = { "opened", "closed", "merged", "all" }

-- MR UI state (separate from pipeline UI state)
local state = {
	list_window = nil,
	list_buffer = nil,
	detail_window = nil,
	detail_buffer = nil,
	create_window = nil,
	create_buffer = nil,
	merge_requests = {},
	api_context = nil,
	current_mr = nil,
	has_next_page = false,
	next_page_cursor = nil,
	filters = { mr_state = "opened", author_username = nil },
	current_username = nil,
}

--- Get the MR state/display key (accounts for draft)
---@param mr table The merge request data
---@return string key The state key for icons/highlights
local function get_mr_display_state(mr)
	if mr.draft then
		return "draft"
	end
	return mr.state or "opened"
end

--- Get icon for MR state
---@param mr table The merge request data
---@return string icon
local function get_mr_icon(mr)
	local key = get_mr_display_state(mr)
	return mr_icons[key] or "?"
end

--- Get highlight for MR state
---@param mr table The merge request data
---@return string highlight
local function get_mr_highlight(mr)
	local key = get_mr_display_state(mr)
	return mr_highlights[key] or "Normal"
end

--- Humanize a branch name into a title
---@param branch string The branch name
---@return string title The humanized title
local function humanize_branch(branch)
	local title = branch:gsub("[-_/]", " ")
	-- Remove common prefixes like "feature ", "fix ", etc. that are redundant
	title = title:gsub("^(%w)", function(c)
		return c:upper()
	end)
	return title
end

--- Close the create view
local function close_create_view()
	if state.create_window and vim.api.nvim_win_is_valid(state.create_window) then
		vim.api.nvim_win_close(state.create_window, true)
	end
	if state.create_buffer and vim.api.nvim_buf_is_valid(state.create_buffer) then
		vim.api.nvim_buf_delete(state.create_buffer, { force = true })
	end
	state.create_window = nil
	state.create_buffer = nil
end

--- Close the detail view
local function close_detail_view()
	if state.detail_window and vim.api.nvim_win_is_valid(state.detail_window) then
		vim.api.nvim_win_close(state.detail_window, true)
	end
	if state.detail_buffer and vim.api.nvim_buf_is_valid(state.detail_buffer) then
		vim.api.nvim_buf_delete(state.detail_buffer, { force = true })
	end
	state.detail_window = nil
	state.detail_buffer = nil
	state.current_mr = nil
end

--- Close the list view
local function close_list_view()
	if state.list_window and vim.api.nvim_win_is_valid(state.list_window) then
		vim.api.nvim_win_close(state.list_window, true)
	end
	if state.list_buffer and vim.api.nvim_buf_is_valid(state.list_buffer) then
		vim.api.nvim_buf_delete(state.list_buffer, { force = true })
	end
	state.list_window = nil
	state.list_buffer = nil
end

--- Close all MR views
local function close_all()
	close_detail_view()
	close_list_view()
	state.merge_requests = {}
	state.api_context = nil
	state.filters = { mr_state = "opened", author_username = nil }
	state.current_username = nil
end

--- Build the window title reflecting current filters
local function get_window_title()
	local parts = { state.filters.mr_state }
	if state.filters.author_username then
		table.insert(parts, "mine")
	end
	return " Merge Requests · " .. table.concat(parts, " | ") .. " "
end

--- Update the list window title to reflect current filters
local function update_window_title()
	if state.list_window and vim.api.nvim_win_is_valid(state.list_window) then
		vim.api.nvim_win_set_config(state.list_window, { title = get_window_title(), title_pos = "center" })
	end
end

--- Get the MR under cursor in the list view
---@return table|nil mr The merge request data, or nil if cursor is not on an MR
local function get_mr_under_cursor()
	if not state.list_window or not vim.api.nvim_win_is_valid(state.list_window) then
		return nil
	end
	local cursor_row = vim.api.nvim_win_get_cursor(state.list_window)[1]
	-- Row 1: header, Row 2: separator, Rows 3+: MRs
	local mr_index = cursor_row - 2
	if mr_index < 1 or mr_index > #state.merge_requests then
		return nil
	end
	return state.merge_requests[mr_index]
end

-- Forward declaration
local open_detail_view

--- Render the MR list buffer
---@param buf number Buffer ID
local function render_list(buf)
	local lines = {}
	local highlights_to_apply = {}

	-- Header
	local header = string.format("  %-6s │ %-50s │ %-15s │ %s", "IID", "Title", "Author", "Status")
	table.insert(lines, header)
	table.insert(lines, string.rep("─", #header + 10))

	-- MR rows
	for _, mr in ipairs(state.merge_requests) do
		local icon = get_mr_icon(mr)
		local author = mr.author and mr.author.name or "unknown"
		local display_state = get_mr_display_state(mr)
		local title = mr.title or ""
		if #title > 50 then
			title = title:sub(1, 47) .. "..."
		end
		local line = string.format("  !%-5s │ %s %-48s │ %-15s │ %s", mr.iid, icon, title, author, display_state)
		table.insert(lines, line)

		-- Highlight the icon
		table.insert(highlights_to_apply, {
			line = #lines - 1,
			col_start = 10,
			col_end = 10 + #icon,
			hl_group = get_mr_highlight(mr),
		})
	end

	if #state.merge_requests == 0 then
		table.insert(lines, "")
		local empty_msg = "  No merge requests found"
		if state.filters.author_username then
			empty_msg = empty_msg .. " (mine)"
		end
		empty_msg = empty_msg .. " for state: " .. state.filters.mr_state
		table.insert(lines, empty_msg)
	end

	-- Load-more row
	if state.has_next_page then
		table.insert(lines, "")
		local more_line = "  ↓  m:load more"
		table.insert(lines, more_line)
		table.insert(highlights_to_apply, {
			line = #lines - 1,
			col_start = 0,
			col_end = #more_line,
			hl_group = "DiagnosticInfo",
		})
	end

	-- Footer hint
	table.insert(lines, "")
	local hint = " ⏎:detail  s:state  u:mine  a:approve  o:browser  c:copy  m:more  r:refresh  q:close"
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
	local ns_id = vim.api.nvim_create_namespace("gitlab_ide_mr")
	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
	for _, hl in ipairs(highlights_to_apply) do
		vim.api.nvim_buf_add_highlight(buf, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
	end
end

--- Re-fetch MRs from the start using current filters and re-render the list
local function refresh_list_with_filters()
	if not state.api_context then
		return
	end
	local ctx = state.api_context
	state.merge_requests = {}
	state.has_next_page = false
	state.next_page_cursor = nil
	vim.notify("Fetching merge requests…", vim.log.levels.INFO)
	api.fetch_merge_requests(
		ctx.gitlab_url,
		ctx.token,
		ctx.project_path,
		function(err, mrs, page_info)
			if err then
				vim.notify("gitlab-ide: " .. err, vim.log.levels.ERROR)
				return
			end
			state.merge_requests = mrs
			state.has_next_page = page_info and page_info.hasNextPage or false
			state.next_page_cursor = page_info and page_info.endCursor or nil
			update_window_title()
			if state.list_buffer and vim.api.nvim_buf_is_valid(state.list_buffer) then
				render_list(state.list_buffer)
			end
		end,
		nil,
		state.filters
	)
end

--- Set up keymaps for the MR list view
---@param buf number Buffer ID
local function setup_list_keymaps(buf)
	local opts = { noremap = true, silent = true, buffer = buf }

	-- Close
	vim.keymap.set("n", "q", close_all, opts)
	vim.keymap.set("n", "<Esc>", close_all, opts)

	-- Refresh with current filters
	vim.keymap.set("n", "r", refresh_list_with_filters, opts)

	-- Cycle MR state filter: opened → closed → merged → all → opened
	vim.keymap.set("n", "s", function()
		local current = state.filters.mr_state
		local next_state = MR_STATE_CYCLE[1]
		for i, v in ipairs(MR_STATE_CYCLE) do
			if v == current then
				next_state = MR_STATE_CYCLE[(i % #MR_STATE_CYCLE) + 1]
				break
			end
		end
		state.filters.mr_state = next_state
		refresh_list_with_filters()
	end, opts)

	-- Toggle "mine" filter (own MRs only)
	vim.keymap.set("n", "u", function()
		if state.filters.author_username then
			state.filters.author_username = nil
		else
			if not state.current_username then
				vim.notify("gitlab-ide: could not determine current user", vim.log.levels.WARN)
				return
			end
			state.filters.author_username = state.current_username
		end
		refresh_list_with_filters()
	end, opts)

	-- Drill down to detail
	vim.keymap.set("n", "<CR>", function()
		local mr = get_mr_under_cursor()
		if not mr then
			vim.notify("No MR under cursor", vim.log.levels.WARN)
			return
		end
		open_detail_view(mr)
	end, opts)

	-- Approve MR
	vim.keymap.set("n", "a", function()
		local mr = get_mr_under_cursor()
		if not mr or not state.api_context then
			vim.notify("No MR under cursor", vim.log.levels.WARN)
			return
		end
		vim.ui.select({ "Yes", "No" }, {
			prompt = string.format("Approve MR !%s '%s'?", mr.iid, mr.title),
		}, function(choice)
			if choice ~= "Yes" then
				return
			end
			local ctx = state.api_context
			api.approve_merge_request(ctx.gitlab_url, ctx.token, ctx.project_path, mr.iid, function(err)
				if err then
					vim.notify("Approve failed: " .. err, vim.log.levels.ERROR)
					return
				end
				vim.notify("MR !" .. mr.iid .. " approved", vim.log.levels.INFO)
				refresh_list_with_filters()
			end)
		end)
	end, opts)

	-- Open in browser
	vim.keymap.set("n", "o", function()
		local mr = get_mr_under_cursor()
		if not mr or not mr.webUrl then
			vim.notify("No MR under cursor", vim.log.levels.WARN)
			return
		end
		vim.ui.open(mr.webUrl)
	end, opts)

	-- Copy URL to clipboard
	vim.keymap.set("n", "c", function()
		local mr = get_mr_under_cursor()
		if not mr or not mr.webUrl then
			vim.notify("No MR under cursor", vim.log.levels.WARN)
			return
		end
		vim.fn.setreg("+", mr.webUrl)
		vim.notify("Copied: " .. mr.webUrl)
	end, opts)

	-- Load next page
	vim.keymap.set("n", "m", function()
		if not state.has_next_page then
			vim.notify("No more merge requests", vim.log.levels.INFO)
			return
		end
		if not state.api_context then
			return
		end
		local ctx = state.api_context
		vim.notify("Loading more merge requests…", vim.log.levels.INFO)
		api.fetch_merge_requests(
			ctx.gitlab_url,
			ctx.token,
			ctx.project_path,
			function(err, more_mrs, page_info)
				if err then
					vim.notify("Load more failed: " .. err, vim.log.levels.ERROR)
					return
				end
				for _, mr in ipairs(more_mrs) do
					table.insert(state.merge_requests, mr)
				end
				state.has_next_page = page_info and page_info.hasNextPage or false
				state.next_page_cursor = page_info and page_info.endCursor or nil
				if state.list_buffer and vim.api.nvim_buf_is_valid(state.list_buffer) then
					render_list(state.list_buffer)
				end
			end,
			state.next_page_cursor,
			state.filters
		)
	end, opts)
end

--- Open the MR list view
---@param merge_requests table List of merge request data
---@param api_context table API context { gitlab_url, token, project_path, username? }
---@param page_info table|nil { hasNextPage, endCursor } from the initial fetch
---@param initial_filters table|nil { mr_state, author_username }
function M.open_list(merge_requests, api_context, page_info, initial_filters)
	-- Close any existing MR views
	close_all()

	state.merge_requests = merge_requests
	state.api_context = api_context
	state.current_username = api_context.username
	state.filters = initial_filters or { mr_state = "opened", author_username = nil }
	state.has_next_page = page_info and page_info.hasNextPage or false
	state.next_page_cursor = page_info and page_info.endCursor or nil

	-- Calculate dimensions (70% x 60%)
	local editor_width = vim.o.columns
	local editor_height = vim.o.lines
	local width = math.floor(editor_width * 0.7)
	local height = math.floor(editor_height * 0.6)
	local col = math.floor((editor_width - width) / 2)
	local row = math.floor((editor_height - height) / 2)

	-- Create buffer
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "swapfile", false)

	-- Create window
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "rounded",
		title = get_window_title(),
		title_pos = "center",
		footer = " s:state  u:mine  ⏎:detail  a:approve  o:browser  m:more  r:refresh  q:close ",
		footer_pos = "center",
	})

	vim.api.nvim_win_set_option(win, "cursorline", true)
	vim.api.nvim_win_set_option(win, "wrap", false)

	state.list_window = win
	state.list_buffer = buf

	-- Render and set up keymaps
	render_list(buf)
	setup_list_keymaps(buf)

	-- Position cursor on first MR
	if #merge_requests > 0 then
		vim.api.nvim_win_set_cursor(win, { 3, 0 })
	end
end

--- Render the MR detail buffer
---@param buf number Buffer ID
---@param mr table Full merge request data
local function render_detail(buf, mr)
	local lines = {}
	local highlights_to_apply = {}
	local ns_id = vim.api.nvim_create_namespace("gitlab_ide_mr_detail")

	-- Title line
	local icon = get_mr_icon(mr)
	local display_state = get_mr_display_state(mr)
	local title_line = string.format("  %s !%s  %s  [%s]", icon, mr.iid, mr.title or "", display_state)
	table.insert(lines, title_line)
	table.insert(highlights_to_apply, {
		line = 0,
		col_start = 2,
		col_end = 2 + #icon,
		hl_group = get_mr_highlight(mr),
	})
	table.insert(lines, string.rep("═", 80))

	-- Metadata section
	table.insert(lines, "")

	-- Author
	local author = mr.author and string.format("%s (@%s)", mr.author.name, mr.author.username) or "unknown"
	table.insert(lines, "  Author:     " .. author)

	-- Branches
	local branches = string.format("%s → %s", mr.sourceBranch or "?", mr.targetBranch or "?")
	table.insert(lines, "  Branches:   " .. branches)

	-- Pipeline status
	local pipeline_status = "none"
	if mr.headPipeline and mr.headPipeline.status then
		local pip_icon = pipeline_icons.get_icon(mr.headPipeline.status)
		pipeline_status = pip_icon .. " " .. mr.headPipeline.status
	end
	table.insert(lines, "  Pipeline:   " .. pipeline_status)

	-- Labels
	local labels = mr.labels and mr.labels.nodes or {}
	if #labels > 0 then
		local label_names = {}
		for _, label in ipairs(labels) do
			table.insert(label_names, label.title)
		end
		table.insert(lines, "  Labels:     " .. table.concat(label_names, ", "))
	end

	-- Assignees
	local assignees = mr.assignees and mr.assignees.nodes or {}
	if #assignees > 0 then
		local names = {}
		for _, a in ipairs(assignees) do
			table.insert(names, a.name)
		end
		table.insert(lines, "  Assignees:  " .. table.concat(names, ", "))
	end

	-- Reviewers
	local reviewers = mr.reviewers and mr.reviewers.nodes or {}
	if #reviewers > 0 then
		local names = {}
		for _, r in ipairs(reviewers) do
			table.insert(names, r.name)
		end
		table.insert(lines, "  Reviewers:  " .. table.concat(names, ", "))
	end

	-- Approvals
	local approval_text = mr.approved and "Yes" or "No"
	if mr.approvalsRequired then
		local given = mr.approvalsRequired - (mr.approvalsLeft or 0)
		approval_text = string.format("%s (%d/%d)", approval_text, given, mr.approvalsRequired)
	end
	table.insert(lines, "  Approved:   " .. approval_text)

	-- Dates
	local created = mr.createdAt and mr.createdAt:match("^[^T]+") or "unknown"
	local updated = mr.updatedAt and mr.updatedAt:match("^[^T]+") or "unknown"
	table.insert(lines, "  Created:    " .. created)
	table.insert(lines, "  Updated:    " .. updated)

	-- Description
	table.insert(lines, "")
	table.insert(lines, string.rep("─", 80))
	table.insert(lines, "  Description:")
	table.insert(lines, string.rep("─", 80))
	table.insert(lines, "")

	local description = mr.description or "(no description)"
	for _, line in ipairs(vim.split(description, "\n", { trimempty = false })) do
		table.insert(lines, "  " .. line)
	end

	-- Diff stats (loaded on demand with `d`)
	local diff_stats = mr.diffStats or {}
	table.insert(lines, "")
	table.insert(lines, string.rep("─", 80))
	if #diff_stats > 0 then
		local total_add, total_del = 0, 0
		for _, stat in ipairs(diff_stats) do
			total_add = total_add + (stat.additions or 0)
			total_del = total_del + (stat.deletions or 0)
		end
		table.insert(
			lines,
			string.format("  Diff Stats: %d files changed, +%d -%d", #diff_stats, total_add, total_del)
		)
		table.insert(lines, string.rep("─", 80))
		table.insert(lines, "")

		for _, stat in ipairs(diff_stats) do
			local diff_line = string.format("  %-60s +%-5d -%d", stat.path, stat.additions or 0, stat.deletions or 0)
			table.insert(lines, diff_line)

			local line_idx = #lines - 1
			local add_start = #diff_line - #string.format("%-5d -%d", stat.additions or 0, stat.deletions or 0) - 1
			table.insert(highlights_to_apply, {
				line = line_idx,
				col_start = add_start,
				col_end = add_start + #string.format("+%d", stat.additions or 0),
				hl_group = "DiagnosticOk",
			})
			local del_str = string.format("-%d", stat.deletions or 0)
			local del_start = #diff_line - #del_str
			table.insert(highlights_to_apply, {
				line = line_idx,
				col_start = del_start,
				col_end = del_start + #del_str,
				hl_group = "DiagnosticError",
			})
		end
	else
		local placeholder = "  Diff Stats: press d to load"
		table.insert(lines, placeholder)
		table.insert(highlights_to_apply, {
			line = #lines - 1,
			col_start = 0,
			col_end = #placeholder,
			hl_group = "Comment",
		})
	end

	-- Set buffer content
	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	-- Apply highlights
	vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)
	for _, hl in ipairs(highlights_to_apply) do
		vim.api.nvim_buf_add_highlight(buf, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
	end
end

--- Set up keymaps for the MR detail view
---@param buf number Buffer ID
local function setup_detail_keymaps(buf)
	local opts = { noremap = true, silent = true, buffer = buf }

	-- Back to list
	vim.keymap.set("n", "q", function()
		close_detail_view()
		-- Re-show list if it exists
		if state.list_buffer and vim.api.nvim_buf_is_valid(state.list_buffer) then
			if state.list_window and vim.api.nvim_win_is_valid(state.list_window) then
				vim.api.nvim_set_current_win(state.list_window)
			end
		end
	end, opts)
	vim.keymap.set("n", "<BS>", function()
		close_detail_view()
		if state.list_buffer and vim.api.nvim_buf_is_valid(state.list_buffer) then
			if state.list_window and vim.api.nvim_win_is_valid(state.list_window) then
				vim.api.nvim_set_current_win(state.list_window)
			end
		end
	end, opts)

	-- Close all
	vim.keymap.set("n", "<Esc>", close_all, opts)

	-- Approve
	vim.keymap.set("n", "a", function()
		local mr = state.current_mr
		if not mr or not state.api_context then
			return
		end
		vim.ui.select({ "Yes", "No" }, {
			prompt = string.format("Approve MR !%s '%s'?", mr.iid, mr.title),
		}, function(choice)
			if choice ~= "Yes" then
				return
			end
			local ctx = state.api_context
			api.approve_merge_request(ctx.gitlab_url, ctx.token, ctx.project_path, mr.iid, function(err)
				if err then
					vim.notify("Approve failed: " .. err, vim.log.levels.ERROR)
					return
				end
				vim.notify("MR !" .. mr.iid .. " approved", vim.log.levels.INFO)
			end)
		end)
	end, opts)

	-- Open in browser
	vim.keymap.set("n", "o", function()
		local mr = state.current_mr
		if mr and mr.webUrl then
			vim.ui.open(mr.webUrl)
		end
	end, opts)

	-- Copy URL to clipboard
	vim.keymap.set("n", "c", function()
		local mr = state.current_mr
		if mr and mr.webUrl then
			vim.fn.setreg("+", mr.webUrl)
			vim.notify("Copied: " .. mr.webUrl)
		end
	end, opts)

	-- Refresh detail
	vim.keymap.set("n", "r", function()
		local mr = state.current_mr
		if not mr or not state.api_context then
			return
		end
		local ctx = state.api_context
		api.fetch_merge_request_detail(ctx.gitlab_url, ctx.token, ctx.project_path, mr.iid, function(err, detail)
			if err then
				vim.notify("Refresh failed: " .. err, vim.log.levels.ERROR)
				return
			end
			state.current_mr = detail
			if state.detail_buffer and vim.api.nvim_buf_is_valid(state.detail_buffer) then
				render_detail(state.detail_buffer, detail)
			end
		end)
	end, opts)

	-- Load diff stats on demand
	vim.keymap.set("n", "d", function()
		local mr = state.current_mr
		if not mr or not state.api_context then
			return
		end
		if mr.diffStats and #mr.diffStats > 0 then
			vim.notify("Diff stats already loaded", vim.log.levels.INFO)
			return
		end
		vim.notify("Loading diff stats...", vim.log.levels.INFO)
		local ctx = state.api_context
		api.fetch_mr_diff_stats(ctx.gitlab_url, ctx.token, ctx.project_path, mr.iid, function(err, stats)
			if err then
				vim.notify("Failed to load diff stats: " .. err, vim.log.levels.ERROR)
				return
			end
			mr.diffStats = stats
			state.current_mr = mr
			if state.detail_buffer and vim.api.nvim_buf_is_valid(state.detail_buffer) then
				render_detail(state.detail_buffer, mr)
			end
		end)
	end, opts)

	-- Open discussion threads
	vim.keymap.set("n", "t", function()
		if not state.current_mr or not state.api_context then
			return
		end
		require("gitlab-ide.mr_threads").open(state.current_mr, state.api_context, state.detail_window)
	end, opts)

	-- Enter review mode: check out the MR branch and diff it against its target
	vim.keymap.set("n", "C", function()
		local mr = state.current_mr
		if not mr then
			return
		end
		require("gitlab-ide.review").start_from_mr(mr, close_all)
	end, opts)
end

--- Open the detail view for a merge request
---@param mr table The merge request data (from list, may be partial)
open_detail_view = function(mr)
	if not state.api_context then
		vim.notify("API context not available", vim.log.levels.ERROR)
		return
	end

	-- Fetch full detail
	local ctx = state.api_context
	api.fetch_merge_request_detail(ctx.gitlab_url, ctx.token, ctx.project_path, mr.iid, function(err, detail)
		if err then
			vim.notify("Failed to fetch MR detail: " .. err, vim.log.levels.ERROR)
			return
		end

		state.current_mr = detail

		-- Calculate dimensions (85% x 85%)
		local editor_width = vim.o.columns
		local editor_height = vim.o.lines
		local width = math.floor(editor_width * 0.85)
		local height = math.floor(editor_height * 0.85)
		local col = math.floor((editor_width - width) / 2)
		local row = math.floor((editor_height - height) / 2)

		-- Create buffer
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
		vim.api.nvim_buf_set_option(buf, "swapfile", false)

		-- Create window
		local icon = get_mr_icon(detail)
		local title = string.format(" %s !%s %s ", icon, detail.iid, detail.title or "")
		if #title > width - 4 then
			title = title:sub(1, width - 7) .. "... "
		end
		local footer = " q/⌫:back a:approve o:browser c:copy d:diff r:refresh t:threads C:review Esc:close "
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

		state.detail_window = win
		state.detail_buffer = buf

		render_detail(buf, detail)
		setup_detail_keymaps(buf)
	end)
end

--- Open the MR create view from pipeline context
---@param api_context table API context { gitlab_url, token, project_path }
function M.open_create_view(api_context)
	-- Get current branch
	local branch, branch_err = git.get_current_branch()
	if not branch then
		vim.notify("gitlab-ide: " .. (branch_err or "Could not determine branch"), vim.log.levels.ERROR)
		return
	end

	local ctx = api_context

	-- Fetch default branch
	api.fetch_project_default_branch(ctx.gitlab_url, ctx.token, ctx.project_path, function(err, default_branch)
		if err then
			vim.notify("Could not fetch default branch: " .. err, vim.log.levels.ERROR)
			return
		end

		-- Resolve first-commit info for placeholder substitution (synchronous)
		local first_commit = git.get_first_commit_info(default_branch)

		-- Fetch MR templates
		api.fetch_mr_templates(ctx.gitlab_url, ctx.token, ctx.project_path, function(_, templates)
			templates = templates or {}

			local function open_form(template_content)
				-- Calculate dimensions (60% x 50%)
				local editor_width = vim.o.columns
				local editor_height = vim.o.lines
				local width = math.floor(editor_width * 0.6)
				local height = math.floor(editor_height * 0.5)
				local col = math.floor((editor_width - width) / 2)
				local row = math.floor((editor_height - height) / 2)

				-- Create buffer
				local buf = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
				vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
				vim.api.nvim_buf_set_option(buf, "swapfile", false)

				-- Create window
				local title = string.format(" Create MR: %s → %s ", branch, default_branch)
				if #title > width - 4 then
					title = title:sub(1, width - 7) .. "... "
				end
				local footer = " C-s:submit Esc:cancel "
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

				state.create_window = win
				state.create_buffer = buf

				-- Resolve %{first_multiline_commit} placeholder
				if first_commit and template_content and template_content ~= "" then
					template_content = template_content:gsub("%%{first_multiline_commit}", function()
						return first_commit.full
					end)
				end

				-- Pre-fill buffer: line 1 = commit subject (or humanized branch), rest = template
				local initial_lines = { (first_commit and first_commit.title) or humanize_branch(branch) }
				if template_content and template_content ~= "" then
					table.insert(initial_lines, "")
					for _, line in ipairs(vim.split(template_content, "\n", { trimempty = false })) do
						table.insert(initial_lines, line)
					end
				end

				vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)

				-- Set up keymaps
				local km_opts = { noremap = true, silent = true, buffer = buf }

				-- Cancel
				vim.keymap.set("n", "<Esc>", close_create_view, km_opts)

				-- Submit with C-s
				vim.keymap.set({ "n", "i" }, "<C-s>", function()
					local buf_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
					if #buf_lines == 0 or buf_lines[1] == "" then
						vim.notify("Title cannot be empty (first line)", vim.log.levels.WARN)
						return
					end

					local mr_title = buf_lines[1]
					local mr_description = table.concat(vim.list_slice(buf_lines, 2), "\n")

					local params = {
						source_branch = branch,
						target_branch = default_branch,
						title = mr_title,
						description = mr_description,
					}

					vim.notify("Creating merge request...", vim.log.levels.INFO)
					api.create_merge_request(
						ctx.gitlab_url,
						ctx.token,
						ctx.project_path,
						params,
						function(create_err, result)
							if create_err then
								vim.notify("MR creation failed: " .. create_err, vim.log.levels.ERROR)
								return
							end
							close_create_view()
							local url = result and result.web_url or "unknown"
							vim.notify("MR created: " .. url, vim.log.levels.INFO)
						end
					)
				end, km_opts)
			end

			-- Check if "Default" template exists (case-insensitive)
			local default_template_name = nil
			for _, tmpl in ipairs(templates) do
				if tmpl.name:lower() == "default" then
					default_template_name = tmpl.name
					break
				end
			end

			if default_template_name then
				api.fetch_mr_template_content(
					ctx.gitlab_url,
					ctx.token,
					ctx.project_path,
					default_template_name,
					function(_, content)
						open_form(content or "")
					end
				)
			else
				open_form("")
			end
		end)
	end)
end

return M
