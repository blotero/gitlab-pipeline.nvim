-- gitlab-ide.nvim - GitLab CI/CD pipeline status in Neovim
-- Entry point module
local M = {}

local config = require("gitlab-ide.config")
local git = require("gitlab-ide.git")
local api = require("gitlab-ide.api")
local ui = require("gitlab-ide.ui")

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

--- Open the pipeline view for the current repository and branch
function M.open()
	-- Get current branch
	local branch, branch_err = git.get_current_branch()
	if not branch then
		show_error(branch_err or "Could not determine current branch")
		return
	end

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

	-- Build API context for UI actions
	local api_context = {
		gitlab_url = gitlab_url,
		token = token,
		project_path = project_path,
	}

	-- Show loading message
	vim.notify("Fetching pipeline for " .. project_path .. " @ " .. branch .. "...", vim.log.levels.INFO)

	-- Create refresh function
	local function refresh()
		api.fetch_pipeline(gitlab_url, token, project_path, branch, function(err, pipeline)
			if err then
				show_error(err)
				return
			end
			ui.refresh(pipeline)
		end)
	end

	-- Fetch pipeline data
	api.fetch_pipeline(gitlab_url, token, project_path, branch, function(err, pipeline)
		if err then
			show_error(err)
			return
		end

		-- Open UI with pipeline data
		ui.open(pipeline, refresh, api_context)
	end)
end

--- Close the pipeline view
function M.close()
	ui.close()
end

return M
