-- gitlab-ide.nvim plugin loader
-- Auto-load and register commands

-- Prevent loading twice
if vim.g.loaded_gitlab_ide then
	return
end
vim.g.loaded_gitlab_ide = true

-- Check Neovim version (requires 0.10+ for vim.system)
if vim.fn.has("nvim-0.10") ~= 1 then
	vim.notify("gitlab-ide.nvim requires Neovim 0.10 or later", vim.log.levels.ERROR)
	return
end

-- Register the :GitlabIdePipeline command
vim.api.nvim_create_user_command("GitlabIdePipeline", function()
	require("gitlab-ide").open()
end, {
	desc = "Open GitLab IDE pipeline view for current branch",
})

-- Register the :GitlabIdePipelineBranch command
vim.api.nvim_create_user_command("GitlabIdePipelineBranch", function()
	require("gitlab-ide").open_branch_select()
end, {
	desc = "Open GitLab IDE pipeline view with branch selector",
})

-- Register the :GitlabIdeMergeRequests command
vim.api.nvim_create_user_command("GitlabIdeMergeRequests", function()
	require("gitlab-ide").open_merge_requests()
end, {
	desc = "Open GitLab IDE merge requests list",
})

-- Register the :GitlabIdeBrowse command
vim.api.nvim_create_user_command("GitlabIdeBrowse", function(opts)
	if opts.range == 2 then
		require("gitlab-ide").open_in_browser(opts.line1, opts.line2)
	else
		require("gitlab-ide").open_in_browser()
	end
end, {
	desc = "Open current file at cursor position in GitLab web UI",
	range = true,
})

-- Register the :GitlabIdeIssues command
vim.api.nvim_create_user_command("GitlabIdeIssues", function()
	require("gitlab-ide").open_issues()
end, {
	desc = "Open GitLab IDE issues assigned to current user",
})

-- Register the :GitlabIdeReview command
vim.api.nvim_create_user_command("GitlabIdeReview", function(opts)
	require("gitlab-ide").review_start(opts.args ~= "" and opts.args or nil)
end, {
	desc = "Enter review mode: diff the current checkout against a target ref",
	nargs = "?",
	complete = function(arg_lead)
		local refs = vim.fn.systemlist({
			"git",
			"for-each-ref",
			"--format=%(refname:short)",
			"refs/remotes",
			"refs/heads",
		})
		if vim.v.shell_error ~= 0 then
			return {}
		end
		return vim.tbl_filter(function(ref)
			return ref:find(arg_lead, 1, true) == 1
		end, refs)
	end,
})

-- Register the :GitlabIdeReviewStop command
vim.api.nvim_create_user_command("GitlabIdeReviewStop", function()
	require("gitlab-ide").review_stop()
end, {
	desc = "Leave review mode and reset the diff base to HEAD",
})
