-- Git operations for gitlab-ide.nvim
local M = {}

--- Get the current git branch
---@return string|nil branch The current branch name or nil on error
---@return string|nil error Error message if failed
function M.get_current_branch()
	local result = vim.fn.systemlist({ "git", "rev-parse", "--abbrev-ref", "HEAD" })
	if vim.v.shell_error ~= 0 then
		return nil, "Not a git repository or git command failed"
	end
	if result[1] then
		return result[1], nil
	end
	return nil, "Could not determine current branch"
end

--- Get the URL for a git remote
---@param remote string The remote name (e.g., "origin")
---@return string|nil url The remote URL or nil on error
---@return string|nil error Error message if failed
function M.get_remote_url(remote)
	local result = vim.fn.systemlist({ "git", "remote", "get-url", remote })
	if vim.v.shell_error ~= 0 then
		return nil, string.format("Remote '%s' not found", remote)
	end
	if result[1] then
		return result[1], nil
	end
	return nil, "Could not get remote URL"
end

--- Get info about the first (oldest) commit on HEAD not reachable from default_branch
---@param default_branch string The project default branch (e.g. "main")
---@return table|nil info Table with `title` (string) and `full` (string), or nil if no commits
function M.get_first_commit_info(default_branch)
	local shas = vim.fn.systemlist({
		"git",
		"log",
		"origin/" .. default_branch .. "..HEAD",
		"--reverse",
		"--format=%H",
	})
	if vim.v.shell_error ~= 0 or #shas == 0 then
		return nil
	end
	local msg_lines = vim.fn.systemlist({ "git", "show", "-s", "--format=%B", shas[1] })
	if vim.v.shell_error ~= 0 or #msg_lines == 0 then
		return nil
	end
	while #msg_lines > 0 and msg_lines[#msg_lines] == "" do
		table.remove(msg_lines)
	end
	return {
		title = msg_lines[1],
		full = table.concat(msg_lines, "\n"),
	}
end

--- Parse a GitLab remote URL to extract the project path
--- Handles both SSH and HTTPS URLs:
---   git@gitlab.com:group/project.git -> group/project
---   https://gitlab.com/group/project.git -> group/project
---   https://gitlab.com/group/subgroup/project.git -> group/subgroup/project
---@param url string The remote URL
---@return string|nil path The project path (group/project) or nil
---@return string|nil error Error message if failed
function M.get_project_path(url)
	if not url or url == "" then
		return nil, "Empty URL"
	end

	local path

	-- SSH format: git@gitlab.com:group/project.git
	path = url:match("^git@[^:]+:(.+)$")
	if path then
		-- Remove .git suffix if present
		path = path:gsub("%.git$", "")
		return path, nil
	end

	-- HTTPS format: https://gitlab.com/group/project.git
	path = url:match("^https?://[^/]+/(.+)$")
	if path then
		-- Remove .git suffix if present
		path = path:gsub("%.git$", "")
		return path, nil
	end

	return nil, "Could not parse GitLab project path from URL: " .. url
end

--- Detect the GitLab host from a remote URL
---@param url string The remote URL
---@return string|nil host The GitLab host (e.g., "gitlab.com") or nil
---@return string|nil error Error message if failed
function M.detect_gitlab_host(url)
	if not url or url == "" then
		return nil, "Empty URL"
	end

	local host

	-- SSH format: git@gitlab.com:group/project.git
	host = url:match("^git@([^:]+):")
	if host then
		return host, nil
	end

	-- HTTPS format: https://gitlab.com/group/project.git
	host = url:match("^https?://([^/]+)/")
	if host then
		return host, nil
	end

	return nil, "Could not detect GitLab host from URL: " .. url
end

--- Get the repository root directory
---@return string|nil root The absolute path to the repo root or nil on error
---@return string|nil error Error message if failed
function M.get_repo_root()
	local result = vim.fn.systemlist({ "git", "rev-parse", "--show-toplevel" })
	if vim.v.shell_error ~= 0 then
		return nil, "Not a git repository"
	end
	if result[1] then
		return result[1], nil
	end
	return nil, "Could not determine repository root"
end

--- Check whether a revision exists in the local repository
---@param rev string The revision to verify (e.g. "origin/master", "refs/heads/foo")
---@return boolean exists
function M.rev_exists(rev)
	vim.fn.systemlist({ "git", "rev-parse", "--verify", "--quiet", rev })
	return vim.v.shell_error == 0
end

--- Check whether one revision is an ancestor of another
---@param ancestor string The candidate ancestor revision
---@param descendant string The candidate descendant revision
---@return boolean is_ancestor
function M.is_ancestor(ancestor, descendant)
	vim.fn.system({ "git", "merge-base", "--is-ancestor", ancestor, descendant })
	return vim.v.shell_error == 0
end

--- Get the merge-base (common ancestor) of two revisions
---@param ref_a string First revision
---@param ref_b string Second revision
---@return string|nil sha The merge-base commit SHA or nil on error
---@return string|nil error Error message if failed
function M.get_merge_base(ref_a, ref_b)
	local result = vim.fn.systemlist({ "git", "merge-base", ref_a, ref_b })
	if vim.v.shell_error ~= 0 or not result[1] then
		return nil, string.format("Could not resolve the merge-base of %s and %s", ref_a, ref_b)
	end
	return result[1], nil
end

--- Check whether the working tree has no staged or unstaged changes
--- Untracked files are ignored: they do not block a checkout, so treating them
--- as dirty would refuse review mode over a stray build artifact. In the rare
--- case where the target branch does carry a file at the same path, git itself
--- fails the checkout and `M.checkout` surfaces that error.
---@return boolean clean True when there is nothing to commit
---@return string|nil error Summary of the pending changes when not clean
function M.is_worktree_clean()
	local result = vim.fn.systemlist({ "git", "status", "--porcelain", "--untracked-files=no" })
	if vim.v.shell_error ~= 0 then
		return false, "Not a git repository or git command failed"
	end
	if #result == 0 then
		return true, nil
	end
	return false, string.format("%d file(s) with uncommitted changes", #result)
end

-- Branch names to try when a remote has no symbolic HEAD, in order
local DEFAULT_BRANCH_CANDIDATES = { "main", "master", "develop" }

--- Get the default branch of a remote, without touching the network
--- Prefers refs/remotes/<remote>/HEAD, which many clones lack (it is only set up
--- by the default clone flow, or by `git remote set-head`), then falls back to
--- the conventional branch names.
---@param remote string The remote name (e.g. "origin")
---@return string|nil branch The default branch name, without the remote prefix
---@return string|nil error Error message if failed
function M.get_remote_default_branch(remote)
	local ref = "refs/remotes/" .. remote .. "/HEAD"
	local result = vim.fn.systemlist({ "git", "symbolic-ref", "--short", ref })
	if vim.v.shell_error == 0 and result[1] then
		return (result[1]:gsub("^" .. vim.pesc(remote) .. "/", "")), nil
	end

	for _, candidate in ipairs(DEFAULT_BRANCH_CANDIDATES) do
		if M.rev_exists(remote .. "/" .. candidate) then
			return candidate, nil
		end
	end

	return nil, string.format("Could not determine the default branch of '%s'", remote)
end

--- Fetch branches from a remote (async: this one hits the network)
--- Uses explicit refspecs so the remote-tracking refs are always updated.
---@param remote string The remote name (e.g. "origin")
---@param branches string[] Branch names to fetch
---@param callback function Callback function(err), called on the main loop
function M.fetch(remote, branches, callback)
	local cmd = { "git", "fetch", remote }
	for _, branch in ipairs(branches or {}) do
		table.insert(cmd, string.format("+refs/heads/%s:refs/remotes/%s/%s", branch, remote, branch))
	end

	vim.system(cmd, { text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				local stderr = vim.trim(result.stderr or "")
				callback(stderr ~= "" and stderr or string.format("git fetch %s failed", remote))
				return
			end
			callback(nil)
		end)
	end)
end

--- Check out a local branch tracking <remote>/<branch>, creating it if absent
--- Refuses to move a local branch that holds commits the remote does not have,
--- so existing local work is never silently discarded.
---@param remote string The remote name (e.g. "origin")
---@param branch string The branch name
---@param callback function Callback function(err), called on the main loop
function M.checkout(remote, branch, callback)
	local remote_ref = remote .. "/" .. branch
	if not M.rev_exists(remote_ref) then
		callback(string.format("Remote branch '%s' not found locally, fetch it first", remote_ref))
		return
	end

	local local_ref = "refs/heads/" .. branch
	local cmd
	if M.rev_exists(local_ref) then
		if not M.is_ancestor(local_ref, remote_ref) then
			callback(
				string.format(
					"Local branch '%s' has commits that are not on %s. "
						.. "Check it out and reconcile it manually before entering review mode.",
					branch,
					remote_ref
				)
			)
			return
		end
		-- Local branch is behind or equal, so fast-forwarding it loses nothing
		cmd = { "git", "checkout", "-B", branch, remote_ref }
	else
		cmd = { "git", "checkout", "-b", branch, "--track", remote_ref }
	end

	vim.system(cmd, { text = true }, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				local stderr = vim.trim(result.stderr or "")
				callback(stderr ~= "" and stderr or string.format("Could not check out '%s'", branch))
				return
			end
			callback(nil)
		end)
	end)
end

--- Get the full GitLab API base URL from a remote URL
---@param url string The remote URL
---@param override string|nil Optional override for the GitLab URL
---@return string|nil gitlab_url The GitLab API base URL or nil
---@return string|nil error Error message if failed
function M.get_gitlab_url(url, override)
	if override then
		-- Remove trailing slash if present
		return override:gsub("/$", ""), nil
	end

	local host, err = M.detect_gitlab_host(url)
	if not host then
		return nil, err
	end

	return "https://" .. host, nil
end

return M
