-- MR review mode for gitlab-ide.nvim
--
-- After checking out an MR branch the working tree is clean, so gitsigns and
-- friends show nothing: they diff against HEAD, and HEAD *is* the MR. Review
-- mode repoints the gitsigns base at merge-base(target, HEAD) so the gutter,
-- ]c/[c and the file list all describe the MR's own changes, while the buffers
-- stay real files with a live LSP.
--
-- The base is the merge-base rather than the target branch itself; using the
-- target directly would surface its own drift as if it were part of the MR.
local M = {}
local config = require("gitlab-ide.config")
local git = require("gitlab-ide.git")

---@class ReviewState
---@field active boolean
---@field base string|nil Resolved merge-base SHA
---@field target_ref string|nil Ref the base was computed against
---@field branch string|nil Branch under review, nil when HEAD is detached
---@field view string|nil View layer opened by start ("diffview" | "quickfix" | "none")
local state = { active = false }

--- Notify the user with the plugin prefix
---@param msg string The message
---@param level number|nil Log level (default: INFO)
local function notify(msg, level)
	vim.notify("gitlab-ide: " .. msg, level or vim.log.levels.INFO)
end

--- Point gitsigns at a diff base for every buffer
---@param base string|nil Revision to diff against, or nil to restore HEAD
---@return boolean ok False when gitsigns is not installed
local function set_gitsigns_base(base)
	local ok, gitsigns = pcall(require, "gitsigns")
	if not ok then
		return false
	end
	gitsigns.change_base(base, true)
	return true
end

--- Open the configured view layer for the review
---@param base string The merge-base the review is anchored at
---@return string view The view actually opened ("diffview" | "quickfix" | "none")
local function open_view(base)
	local requested = config.get_review_opts().view or "auto"
	if requested == "none" then
		return "none"
	end

	if requested == "auto" or requested == "diffview" then
		if pcall(require, "diffview") and pcall(vim.cmd, "DiffviewOpen " .. base .. "..HEAD") then
			return "diffview"
		end
		if requested == "diffview" then
			notify("diffview.nvim is not available, falling back to the quickfix list", vim.log.levels.WARN)
		end
	end

	local ok, gitsigns = pcall(require, "gitsigns")
	if ok then
		gitsigns.setqflist("all", { open = true })
		return "quickfix"
	end

	notify("Neither diffview.nvim nor gitsigns.nvim is available, no file list opened", vim.log.levels.WARN)
	return "none"
end

--- Enter review mode against target_ref, using merge-base(target_ref, HEAD)
--- Idempotent: calling it again recomputes and replaces the base.
---@param target_ref string The ref the MR targets (e.g. "origin/master")
---@return string|nil base The resolved merge-base SHA, or nil on failure
function M.start(target_ref)
	if not target_ref or target_ref == "" then
		notify("No target ref given for review mode", vim.log.levels.ERROR)
		return nil
	end

	if not git.rev_exists(target_ref) then
		notify(string.format("Ref '%s' does not exist locally, fetch it first", target_ref), vim.log.levels.ERROR)
		return nil
	end

	local base, base_err = git.get_merge_base(target_ref, "HEAD")
	if not base then
		notify(base_err or "Could not resolve the merge-base", vim.log.levels.ERROR)
		return nil
	end

	if not set_gitsigns_base(base) then
		notify("gitsigns.nvim not found, gutter signs will not reflect the MR diff", vim.log.levels.WARN)
	end

	-- On a detached HEAD get_current_branch reports "HEAD", which is not a branch
	local branch = git.get_current_branch()
	if branch == "HEAD" then
		branch = nil
	end

	state.active = true
	state.base = base
	state.target_ref = target_ref
	state.branch = branch
	state.view = open_view(base)

	notify(
		string.format(
			"Review mode: %s vs %s (merge-base %s). Stop with :GitlabIdeReviewStop",
			branch or "detached HEAD",
			target_ref,
			base:sub(1, 8)
		)
	)

	return base
end

--- Leave review mode: reset the gitsigns base to HEAD
--- The MR branch stays checked out, so reading can continue afterwards.
function M.stop()
	if not state.active then
		notify("Review mode is not active")
		return
	end

	set_gitsigns_base(nil)
	if state.view == "diffview" then
		pcall(vim.cmd, "DiffviewClose")
	end

	state.active = false
	state.base = nil
	state.target_ref = nil
	state.branch = nil
	state.view = nil

	notify("Review mode stopped, diff base is back to HEAD")
end

---@return boolean active
function M.is_active()
	return state.active
end

--- Enter review mode for a merge request: check out its source branch, then
--- diff against the merge-base with its target branch
---@param mr table MR detail, needs iid, sourceBranch, targetBranch and the project fields
---@param on_ready function|nil Called once the checkout succeeds, before the base is set
function M.start_from_mr(mr, on_ready)
	local opts = config.get_review_opts()
	if opts.strategy ~= "checkout" then
		notify(
			string.format("Review strategy '%s' is not implemented yet", tostring(opts.strategy)),
			vim.log.levels.ERROR
		)
		return
	end

	local source, target = mr.sourceBranch, mr.targetBranch
	if not source or not target then
		notify("This MR has no source/target branch information", vim.log.levels.ERROR)
		return
	end

	-- A fork's source branch lives in another project, so there is nothing to
	-- fetch from our own remote
	local source_project = mr.sourceProject and mr.sourceProject.fullPath
	local target_project = mr.targetProject and mr.targetProject.fullPath
	if not source_project then
		notify(
			string.format("The source project of MR !%s no longer exists", tostring(mr.iid)),
			vim.log.levels.ERROR
		)
		return
	end
	if target_project and source_project ~= target_project then
		notify(
			string.format(
				"MR !%s comes from the fork '%s'; forks are not supported yet",
				tostring(mr.iid),
				source_project
			),
			vim.log.levels.ERROR
		)
		return
	end

	-- Checkout would overwrite uncommitted work, so bail out before fetching
	local clean, dirty = git.is_worktree_clean()
	if not clean then
		notify(
			string.format("Working tree is not clean (%s), commit or stash before entering review mode", dirty or "?"),
			vim.log.levels.ERROR
		)
		return
	end

	local remote = config.get_remote()

	local function checkout_and_start()
		git.checkout(remote, source, function(err)
			if err then
				notify(err, vim.log.levels.ERROR)
				return
			end

			-- Checkout rewrote files on disk while nvim held them in memory
			vim.cmd("checktime")

			-- Close the MR floats first, so the reviewer lands in the code and
			-- any notification below is not hidden behind them
			if on_ready then
				on_ready()
			end

			M.start(remote .. "/" .. target)
		end)
	end

	if opts.auto_fetch then
		-- Both refs matter: a stale target ref yields a stale merge-base
		notify(string.format("Fetching %s and %s from %s...", source, target, remote))
		git.fetch(remote, { source, target }, function(err)
			if err then
				notify("Fetch failed: " .. err, vim.log.levels.ERROR)
				return
			end
			checkout_and_start()
		end)
	else
		checkout_and_start()
	end
end

return M
