-- Configuration management for gitlab-ide.nvim
local M = {}

-- Default configuration
local defaults = {
	remote = "origin",
	gitlab_url = nil, -- Auto-detect from remote URL
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

--- Get the configured GitLab URL or nil for auto-detection
---@return string|nil gitlab_url The GitLab URL or nil
function M.get_gitlab_url()
	return M.options.gitlab_url
end

return M
