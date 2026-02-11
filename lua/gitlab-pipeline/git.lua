-- Git operations for gitlab-pipeline.nvim
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
