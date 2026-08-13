-- Configuration management for gitlab-ide.nvim
local M = {}

-- Default configuration
local defaults = {
	remote = "origin",
	gitlab_url = nil, -- Auto-detect from remote URL
	review = {
		strategy = "checkout", -- "checkout" | "worktree" (not implemented yet)
		view = "auto", -- "auto" | "diffview" | "quickfix" | "none"
		auto_fetch = true, -- Fetch the source and target branches before checking out
	},
}

-- Current configuration
M.options = vim.deepcopy(defaults)

--- Setup configuration with user options
---@param opts table|nil User configuration options
function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

--- Get the GitLab API token
--- Resolution order: GITLAB_TOKEN env → GITLAB_PAT env → config.token
---@return string|nil token The resolved token or nil if not found
function M.get_token()
	local token = vim.env.GITLAB_TOKEN
	if token and token ~= "" then
		return token
	end

	token = vim.env.GITLAB_PAT
	if token and token ~= "" then
		return token
	end

	if M.options.token and M.options.token ~= "" then
		return M.options.token
	end

	return nil
end

--- Get the configured remote name
---@return string remote The remote name (default: "origin")
function M.get_remote()
	return M.options.remote or defaults.remote
end

--- Get the review mode options
---@return table review { strategy: string, view: string, auto_fetch: boolean }
function M.get_review_opts()
	return M.options.review or defaults.review
end

--- Get the configured GitLab URL or nil for auto-detection
---@return string|nil gitlab_url The GitLab URL or nil
function M.get_gitlab_url()
	return M.options.gitlab_url
end

return M
