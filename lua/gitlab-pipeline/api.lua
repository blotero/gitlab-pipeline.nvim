-- GitLab GraphQL API client for gitlab-pipeline.nvim
local M = {}

-- GraphQL query for fetching pipeline data
local PIPELINE_QUERY = [[
query($fullPath: ID!, $ref: String) {
  project(fullPath: $fullPath) {
    pipelines(ref: $ref, first: 1) {
      nodes {
        id
        iid
        status
        createdAt
        stages {
          nodes {
            name
            status
            jobs {
              nodes {
                name
                status
                webPath
              }
            }
          }
        }
      }
    }
  }
}
]]

--- Make an async GraphQL request to the GitLab API
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param query string The GraphQL query
---@param variables table The query variables
---@param callback function Callback function(err, data)
function M.request(gitlab_url, token, query, variables, callback)
  local url = gitlab_url .. "/api/graphql"
  local body = vim.json.encode({
    query = query,
    variables = variables,
  })

  local stdout_data = {}
  local stderr_data = {}

  vim.system({
    "curl",
    "-s",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-H", "Authorization: Bearer " .. token,
    "-d", body,
    url,
  }, {
    text = true,
    stdout = function(err, data)
      if data then
        table.insert(stdout_data, data)
      end
    end,
    stderr = function(err, data)
      if data then
        table.insert(stderr_data, data)
      end
    end,
  }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local stderr = table.concat(stderr_data, "")
        callback("API request failed: " .. stderr, nil)
        return
      end

      local response_text = table.concat(stdout_data, "")
      if response_text == "" then
        callback("Empty response from GitLab API", nil)
        return
      end

      local ok, response = pcall(vim.json.decode, response_text)
      if not ok then
        callback("Failed to parse API response: " .. response_text, nil)
        return
      end

      if response.errors then
        local error_messages = {}
        for _, err in ipairs(response.errors) do
          table.insert(error_messages, err.message or "Unknown error")
        end
        callback("GraphQL errors: " .. table.concat(error_messages, ", "), nil)
        return
      end

      callback(nil, response.data)
    end)
  end)
end

--- Fetch pipeline data for a project and branch
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path (group/project)
---@param branch string The branch name
---@param callback function Callback function(err, pipeline_data)
function M.fetch_pipeline(gitlab_url, token, project_path, branch, callback)
  local variables = {
    fullPath = project_path,
    ref = branch,
  }

  M.request(gitlab_url, token, PIPELINE_QUERY, variables, function(err, data)
    if err then
      callback(err, nil)
      return
    end

    if not data or not data.project then
      callback("Project not found: " .. project_path, nil)
      return
    end

    local pipelines = data.project.pipelines
    if not pipelines or not pipelines.nodes or #pipelines.nodes == 0 then
      callback("No pipelines found for branch: " .. branch, nil)
      return
    end

    local pipeline = pipelines.nodes[1]
    callback(nil, pipeline)
  end)
end

return M
