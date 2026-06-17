-- gitlab-ide.nvim - GitLab CI/CD pipeline status in Neovim
-- Entry point module
local M = {}

local config = require("gitlab-ide.config")
local git = require("gitlab-ide.git")
local api = require("gitlab-ide.api")
local ui = require("gitlab-ide.ui")
local picker = require("gitlab-ide.picker")

--- Setup the plugin with user configuration
---@param opts table|nil User configuration options
function M.setup(opts)
	config.setup(opts)
end

--- Show an error message to the user
---@param msg string Error message
local function show_error(msg)
	vim.notify("gitlab-ide: " .. msg, vim.log.levels.ERROR)
end

--- Build the API context from git/config resolution chain
---@param callback function Callback function(api_context) where api_context = { gitlab_url, token, project_path }
local function build_api_context(callback)
	-- Get remote URL
	local remote = config.get_remote()
	local remote_url, remote_err = git.get_remote_url(remote)
	if not remote_url then
		show_error(remote_err or "Could not get remote URL")
		return
	end

	-- Parse project path
	local project_path, path_err = git.get_project_path(remote_url)
	if not project_path then
		show_error(path_err or "Could not parse project path from remote URL")
		return
	end

	-- Get GitLab URL
	local gitlab_url, url_err = git.get_gitlab_url(remote_url, config.get_gitlab_url())
	if not gitlab_url then
		show_error(url_err or "Could not determine GitLab URL")
		return
	end

	-- Get token
	local token = config.get_token()
	if not token then
		show_error(
			"No GitLab token found. Set GITLAB_TOKEN or GITLAB_PAT environment variable, or configure token in setup()"
		)
		return
	end

	callback({
		gitlab_url = gitlab_url,
		token = token,
		project_path = project_path,
	})
end

-- Forward declarations for mutual references
local open_pipeline_for_branch
local make_switch_branch_cb

--- Build an on_switch_branch callback for a given API context
---@param api_context table API context { gitlab_url, token, project_path }
---@return function on_switch_branch Callback that shows branch picker and reloads pipeline
make_switch_branch_cb = function(api_context)
	return function()
		api.fetch_branches(api_context.gitlab_url, api_context.token, api_context.project_path, function(err, branches)
			if err then
				show_error(err)
				return
			end
			if not branches or #branches == 0 then
				vim.notify("gitlab-ide: No branches found", vim.log.levels.WARN)
				return
			end
			local current_branch = git.get_current_branch()
			picker.open({
				items = branches,
				prompt = "Branch",
				current_item = current_branch,
				on_select = function(chosen)
					if not chosen then
						return
					end
					open_pipeline_for_branch(api_context, chosen)
				end,
			})
		end)
	end
end

--- Open the pipeline view for a given branch and API context
---@param api_context table API context { gitlab_url, token, project_path }
---@param branch string The branch name
open_pipeline_for_branch = function(api_context, branch)
	vim.notify("Fetching pipeline for " .. api_context.project_path .. " @ " .. branch .. "...", vim.log.levels.INFO)

	local function refresh()
		api.fetch_pipeline(api_context.gitlab_url, api_context.token, api_context.project_path, branch, function(err, pipeline)
			if err then
				show_error(err)
				return
			end
			ui.refresh(pipeline)
		end)
	end

	api.fetch_pipeline(api_context.gitlab_url, api_context.token, api_context.project_path, branch, function(err, pipeline)
		if err then
			show_error(err)
			return
		end
		ui.open(pipeline, refresh, api_context, make_switch_branch_cb(api_context))
	end)
end

--- Open the pipeline view for the current repository and branch
function M.open()
	local branch, branch_err = git.get_current_branch()
	if not branch then
		show_error(branch_err or "Could not determine current branch")
		return
	end

	build_api_context(function(api_context)
		open_pipeline_for_branch(api_context, branch)
	end)
end

--- Open a branch picker, then show the pipeline for the selected branch
function M.open_branch_select()
	build_api_context(function(api_context)
		make_switch_branch_cb(api_context)()
	end)
end

--- Close the pipeline view
function M.close()
	ui.close()
end

--- Open the merge requests list view
function M.open_merge_requests()
	build_api_context(function(api_context)
		vim.notify("Fetching merge requests for " .. api_context.project_path .. "...", vim.log.levels.INFO)

		local mr = require("gitlab-ide.mr")

		-- Fetch current user so the "mine" filter knows the username
		api.fetch_current_user(api_context.gitlab_url, api_context.token, function(user_err, username)
			if not user_err and username then
				api_context.username = username
			end

			api.fetch_merge_requests(
				api_context.gitlab_url,
				api_context.token,
				api_context.project_path,
				function(err, merge_requests, page_info)
					if err then
						show_error(err)
						return
					end
					mr.open_list(merge_requests, api_context, page_info)
				end
			)
		end)
	end)
end

--- Open the issues list view (assigned to current user, current project)
function M.open_issues()
	build_api_context(function(api_context)
		vim.notify("Fetching issues for " .. api_context.project_path .. "...", vim.log.levels.INFO)

		local issues = require("gitlab-ide.issues")

		local function refresh()
			api.fetch_issues(
				api_context.gitlab_url,
				api_context.token,
				api_context.project_path,
				function(err, result)
					if err then
						show_error(err)
						return
					end
					issues.open_list(result, refresh, api_context)
				end
			)
		end

		api.fetch_issues(
			api_context.gitlab_url,
			api_context.token,
			api_context.project_path,
			function(err, result)
				if err then
					show_error(err)
					return
				end
				issues.open_list(result, refresh, api_context)
			end
		)
	end)
end

--- Open the current file at the cursor position in the GitLab web UI
---@param range_start number|nil Start line (for visual selection)
---@param range_end number|nil End line (for visual selection)
function M.open_in_browser(range_start, range_end)
	-- Get current file
	local file = vim.fn.expand("%:p")
	if file == "" then
		show_error("No file open")
		return
	end

	-- Get repo root to compute relative path
	local root, root_err = git.get_repo_root()
	if not root then
		show_error(root_err or "Could not determine repository root")
		return
	end

	-- Compute relative path
	local rel_path = file:sub(#root + 2) -- +2 to skip the trailing slash
	if rel_path == "" then
		show_error("Could not determine relative file path")
		return
	end

	-- Get current branch
	local branch, branch_err = git.get_current_branch()
	if not branch then
		show_error(branch_err or "Could not determine current branch")
		return
	end

	-- Get remote URL and parse GitLab info
	local remote = config.get_remote()
	local remote_url, remote_err = git.get_remote_url(remote)
	if not remote_url then
		show_error(remote_err or "Could not get remote URL")
		return
	end

	local project_path, path_err = git.get_project_path(remote_url)
	if not project_path then
		show_error(path_err or "Could not parse project path")
		return
	end

	local gitlab_url, url_err = git.get_gitlab_url(remote_url, config.get_gitlab_url())
	if not gitlab_url then
		show_error(url_err or "Could not determine GitLab URL")
		return
	end

	-- Build the URL
	local line_anchor
	if range_start and range_end and range_start ~= range_end then
		line_anchor = "#L" .. range_start .. "-" .. range_end
	else
		line_anchor = "#L" .. (range_start or vim.fn.line("."))
	end

	local url = string.format("%s/%s/-/blob/%s/%s%s", gitlab_url, project_path, branch, rel_path, line_anchor)

	vim.ui.open(url)
end

return M
