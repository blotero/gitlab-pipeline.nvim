-- GitLab GraphQL API client for gitlab-ide.nvim
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
                id
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
		"-X",
		"POST",
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. token,
		"-d",
		body,
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

--- URL-encode a project path for REST API usage
---@param path string The project path (e.g. "group/project")
---@return string encoded The URL-encoded path
function M.url_encode_path(path)
	return path:gsub("/", "%%2F")
end

--- Extract the numeric ID from a GitLab GID string
---@param gid string The GID (e.g. "gid://gitlab/Ci::Build/12345")
---@return string|nil id The numeric ID or nil
function M.extract_numeric_id(gid)
	return gid:match("(%d+)$")
end

--- Make an async REST API request to the GitLab API
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param method string HTTP method (GET, POST, etc.)
---@param endpoint string The REST API endpoint (e.g. "/api/v4/projects/...")
---@param callback function Callback function(err, data)
---@param opts table|nil Options: { raw = true } to return plain text instead of JSON
function M.rest_request(gitlab_url, token, method, endpoint, callback, opts)
	opts = opts or {}
	local url = gitlab_url .. endpoint

	local stdout_data = {}
	local stderr_data = {}

	vim.system({
		"curl",
		"-s",
		"-X",
		method,
		"-H",
		"PRIVATE-TOKEN: " .. token,
		url,
	}, {
		text = true,
		stdout = function(_, data)
			if data then
				table.insert(stdout_data, data)
			end
		end,
		stderr = function(_, data)
			if data then
				table.insert(stderr_data, data)
			end
		end,
	}, function(result)
		vim.schedule(function()
			if result.code ~= 0 then
				local stderr = table.concat(stderr_data, "")
				callback("REST request failed: " .. stderr, nil)
				return
			end

			local response_text = table.concat(stdout_data, "")
			if response_text == "" then
				callback("Empty response from GitLab API", nil)
				return
			end

			if opts.raw then
				callback(nil, response_text)
				return
			end

			local ok, response = pcall(vim.json.decode, response_text)
			if not ok then
				callback("Failed to parse API response: " .. response_text, nil)
				return
			end

			if response.message then
				callback("API error: " .. vim.inspect(response.message), nil)
				return
			end

			callback(nil, response)
		end)
	end)
end

--- Cancel a job
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param job_gid string The job GID
---@param callback function Callback function(err, data)
function M.cancel_job(gitlab_url, token, project_path, job_gid, callback)
	local job_id = M.extract_numeric_id(job_gid)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/jobs/%s/cancel", encoded_path, job_id)
	M.rest_request(gitlab_url, token, "POST", endpoint, callback)
end

--- Retry a job
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param job_gid string The job GID
---@param callback function Callback function(err, data)
function M.retry_job(gitlab_url, token, project_path, job_gid, callback)
	local job_id = M.extract_numeric_id(job_gid)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/jobs/%s/retry", encoded_path, job_id)
	M.rest_request(gitlab_url, token, "POST", endpoint, callback)
end

--- Cancel a pipeline
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param pipeline_gid string The pipeline GID
---@param callback function Callback function(err, data)
function M.cancel_pipeline(gitlab_url, token, project_path, pipeline_gid, callback)
	local pipeline_id = M.extract_numeric_id(pipeline_gid)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/pipelines/%s/cancel", encoded_path, pipeline_id)
	M.rest_request(gitlab_url, token, "POST", endpoint, callback)
end

--- Retry a pipeline
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param pipeline_gid string The pipeline GID
---@param callback function Callback function(err, data)
function M.retry_pipeline(gitlab_url, token, project_path, pipeline_gid, callback)
	local pipeline_id = M.extract_numeric_id(pipeline_gid)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/pipelines/%s/retry", encoded_path, pipeline_id)
	M.rest_request(gitlab_url, token, "POST", endpoint, callback)
end

--- Fetch job log (trace)
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param job_gid string The job GID
---@param callback function Callback function(err, log_text)
function M.fetch_job_log(gitlab_url, token, project_path, job_gid, callback)
	local job_id = M.extract_numeric_id(job_gid)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/jobs/%s/trace", encoded_path, job_id)
	M.rest_request(gitlab_url, token, "GET", endpoint, callback, { raw = true })
end

return M
