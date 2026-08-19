-- GitLab GraphQL API client for gitlab-ide.nvim
local M = {}

-- Shared job selection: used both for the top-level pipeline and for any
-- pipeline fetched by id (drill-in into a downstream/child pipeline).
-- downstreamPipeline is a cheap stub (no nested stages) so bridge jobs carry
-- their child pipeline's id up front without inflating query complexity;
-- the full child stages/jobs are only fetched on demand via fetch_pipeline_by_id.
local JOB_FIELDS = [[
                id
                name
                status
                kind
                webPath
                downstreamPipeline {
                  id
                  iid
                  status
                  path
                }
]]

-- GraphQL query for fetching pipeline data
local PIPELINE_QUERY = string.format(
	[[
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
%s
              }
            }
          }
        }
      }
    }
  }
}
]],
	JOB_FIELDS
)

-- GraphQL query for fetching a single pipeline by its iid (used to drill
-- into a downstream/child pipeline, and to refresh whatever depth is
-- currently active in the UI). Project.pipeline(id: CiPipelineID) returns
-- null when passed the full "gid://..." string on gitlab.com, so iid is
-- used instead - it's already carried by the downstreamPipeline stub.
local PIPELINE_BY_ID_QUERY = string.format(
	[[
query($fullPath: ID!, $iid: ID!) {
  project(fullPath: $fullPath) {
    pipeline(iid: $iid) {
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
%s
            }
          }
        }
      }
    }
  }
}
]],
	JOB_FIELDS
)

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

--- Fetch a single pipeline by its iid (used for drilling into a
--- downstream/child pipeline, and for refreshing whatever depth is active)
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path (group/project) that owns the pipeline
---@param pipeline_iid string|number The pipeline's iid within project_path
---@param callback function Callback function(err, pipeline_data)
function M.fetch_pipeline_by_id(gitlab_url, token, project_path, pipeline_iid, callback)
	local variables = {
		fullPath = project_path,
		iid = tostring(pipeline_iid),
	}

	M.request(gitlab_url, token, PIPELINE_BY_ID_QUERY, variables, function(err, data)
		if err then
			callback(err, nil)
			return
		end

		if not data or not data.project or not data.project.pipeline then
			callback("Pipeline not found: iid " .. tostring(pipeline_iid), nil)
			return
		end

		callback(nil, data.project.pipeline)
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

	local curl_args = {
		"curl",
		"-s",
		"-X",
		method,
		"-H",
		"PRIVATE-TOKEN: " .. token,
	}

	if opts.body then
		local json_body = vim.json.encode(opts.body)
		table.insert(curl_args, "-H")
		table.insert(curl_args, "Content-Type: application/json")
		table.insert(curl_args, "-d")
		table.insert(curl_args, json_body)
	end

	table.insert(curl_args, url)

	vim.system(curl_args, {
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

			if response.message and not response.id and not response.iid then
				callback("API error: " .. vim.inspect(response.message), nil)
				return
			end

			if response.error then
				if response.error == "insufficient_scope" then
					callback(
						"Insufficient token scope. This action requires the 'api' scope — "
							.. "regenerate your token with write access. "
							.. "(current scopes: " .. (response.scope or "unknown") .. ")",
						nil
					)
				else
					local desc = response.error_description or response.error
					callback("Auth error: " .. desc, nil)
				end
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

-- GraphQL query for fetching branch names
local BRANCHES_QUERY = [[
query($fullPath: ID!, $searchPattern: String!) {
  project(fullPath: $fullPath) {
    repository {
      branchNames(searchPattern: $searchPattern, offset: 0, limit: 50)
    }
  }
}
]]

--- Fetch branch names for a project
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param callback function Callback function(err, branches)
function M.fetch_branches(gitlab_url, token, project_path, callback)
	M.request(gitlab_url, token, BRANCHES_QUERY, { fullPath = project_path, searchPattern = "*" }, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		if not data or not data.project or not data.project.repository then
			callback("Could not fetch branches for: " .. project_path, nil)
			return
		end
		local branches = data.project.repository.branchNames or {}
		callback(nil, branches)
	end)
end


-- GraphQL query for fetching merge requests (paginated, filterable).
-- `in` is left out of the mergeRequests call on purpose: GitLab defaults it to
-- [TITLE, DESCRIPTION], which is the scope $search should cover.
local MR_LIST_QUERY = [[
query($fullPath: ID!, $after: String, $state: MergeRequestState, $authorUsername: String, $search: String) {
  project(fullPath: $fullPath) {
    mergeRequests(state: $state, sort: UPDATED_DESC, first: 10, after: $after, authorUsername: $authorUsername, search: $search) {
      pageInfo {
        hasNextPage
        endCursor
      }
      nodes {
        iid
        title
        state
        draft
        webUrl
        createdAt
        updatedAt
        author {
          name
          username
        }
        sourceBranch
        targetBranch
      }
    }
  }
}
]]

-- GraphQL query for fetching a single merge request with full detail
local MR_DETAIL_QUERY = [[
query($fullPath: ID!, $iid: String!) {
  project(fullPath: $fullPath) {
    mergeRequest(iid: $iid) {
      iid
      title
      state
      draft
      webUrl
      description
      createdAt
      updatedAt
      author {
        name
        username
      }
      sourceBranch
      targetBranch
      sourceProject {
        fullPath
      }
      targetProject {
        fullPath
      }
      labels {
        nodes {
          title
          color
        }
      }
      assignees {
        nodes {
          name
          username
        }
      }
      reviewers {
        nodes {
          name
          username
        }
      }
      approved
      approvalsRequired
      approvalsLeft
      headPipeline {
        status
      }
    }
  }
}
]]

-- GraphQL query for fetching the default branch
local DEFAULT_BRANCH_QUERY = [[
query($fullPath: ID!) {
  project(fullPath: $fullPath) {
    repository {
      rootRef
    }
  }
}
]]

--- Fetch the username of the currently authenticated user via REST /api/v4/user
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param callback function Callback function(err, username)
function M.fetch_current_user(gitlab_url, token, callback)
	M.rest_request(gitlab_url, token, "GET", "/api/v4/user", function(err, data)
		if err then
			callback(err, nil)
			return
		end
		if not data or not data.username then
			callback("Could not fetch current user", nil)
			return
		end
		callback(nil, data.username)
	end)
end

--- Fetch merge requests for a project
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param callback function Callback function(err, merge_requests, page_info)
---@param after string|nil Cursor for pagination (nil for first page)
---@param filters table|nil { mr_state: string, author_username: string|nil, search: string|nil }
function M.fetch_merge_requests(gitlab_url, token, project_path, callback, after, filters)
	filters = filters or {}
	local mr_state = filters.mr_state or "opened"
	local search = filters.search
	if search == "" then
		search = nil
	end
	local vars = {
		fullPath = project_path,
		after = after or vim.NIL,
		state = (mr_state == "all") and vim.NIL or mr_state,
		authorUsername = filters.author_username or vim.NIL,
		search = search or vim.NIL,
	}
	M.request(gitlab_url, token, MR_LIST_QUERY, vars, function(err, data)
		if err then
			callback(err, nil, nil)
			return
		end
		if not data or not data.project then
			callback("Project not found: " .. project_path, nil, nil)
			return
		end
		local conn = data.project.mergeRequests or {}
		local mrs = conn.nodes or {}
		local page_info = conn.pageInfo or { hasNextPage = false, endCursor = nil }
		callback(nil, mrs, page_info)
	end)
end

--- Fetch full detail for a single merge request
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param iid string|number The merge request IID
---@param callback function Callback function(err, merge_request)
function M.fetch_merge_request_detail(gitlab_url, token, project_path, iid, callback)
	M.request(gitlab_url, token, MR_DETAIL_QUERY, { fullPath = project_path, iid = tostring(iid) }, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		if not data or not data.project or not data.project.mergeRequest then
			callback("Merge request not found: !" .. tostring(iid), nil)
			return
		end
		callback(nil, data.project.mergeRequest)
	end)
end

--- Fetch the default branch for a project
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param callback function Callback function(err, default_branch)
function M.fetch_project_default_branch(gitlab_url, token, project_path, callback)
	M.request(gitlab_url, token, DEFAULT_BRANCH_QUERY, { fullPath = project_path }, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		if not data or not data.project or not data.project.repository then
			callback("Could not fetch default branch for: " .. project_path, nil)
			return
		end
		callback(nil, data.project.repository.rootRef)
	end)
end

--- Fetch available MR templates for a project
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param callback function Callback function(err, templates)
function M.fetch_mr_templates(gitlab_url, token, project_path, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/templates/merge_requests", encoded_path)
	M.rest_request(gitlab_url, token, "GET", endpoint, function(err, data)
		if err then
			-- 404 means no templates, return empty list
			callback(nil, {})
			return
		end
		if type(data) ~= "table" then
			callback(nil, {})
			return
		end
		callback(nil, data)
	end)
end

--- Fetch the content of a specific MR template
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param name string The template name
---@param callback function Callback function(err, content)
function M.fetch_mr_template_content(gitlab_url, token, project_path, name, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/templates/merge_requests/%s", encoded_path, name)
	M.rest_request(gitlab_url, token, "GET", endpoint, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		callback(nil, data.content or "")
	end)
end

--- Create a merge request
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param params table MR parameters: { source_branch, target_branch, title, description }
---@param callback function Callback function(err, merge_request)
function M.create_merge_request(gitlab_url, token, project_path, params, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/merge_requests", encoded_path)
	M.rest_request(gitlab_url, token, "POST", endpoint, callback, { body = params })
end

--- Approve a merge request
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param iid string|number The merge request IID
---@param callback function Callback function(err, data)
function M.approve_merge_request(gitlab_url, token, project_path, iid, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/merge_requests/%s/approve", encoded_path, tostring(iid))
	M.rest_request(gitlab_url, token, "POST", endpoint, callback)
end

--- Fetch notes/comments for a merge request
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param iid string|number The merge request IID
---@param callback function Callback function(err, notes)
function M.fetch_mr_notes(gitlab_url, token, project_path, iid, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/merge_requests/%s/notes?sort=asc", encoded_path, tostring(iid))
	M.rest_request(gitlab_url, token, "GET", endpoint, callback)
end

-- GraphQL query for fetching diff stats only (used as a separate lazy call)
local MR_DIFF_STATS_QUERY = [[
query($fullPath: ID!, $iid: String!) {
  project(fullPath: $fullPath) {
    mergeRequest(iid: $iid) {
      diffStats {
        path
        additions
        deletions
      }
    }
  }
}
]]

--- Fetch diff stats for a merge request (separate query to avoid complexity timeout on detail load)
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param iid string|number The merge request IID
---@param callback function Callback function(err, diff_stats)
function M.fetch_mr_diff_stats(gitlab_url, token, project_path, iid, callback)
	M.request(gitlab_url, token, MR_DIFF_STATS_QUERY, { fullPath = project_path, iid = tostring(iid) }, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		if not data or not data.project or not data.project.mergeRequest then
			callback("Merge request not found: !" .. tostring(iid), nil)
			return
		end
		callback(nil, data.project.mergeRequest.diffStats or {})
	end)
end

--- Fetch discussion threads for a merge request
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param iid string|number The merge request IID
---@param callback function Callback function(err, discussions)
function M.fetch_mr_discussions(gitlab_url, token, project_path, iid, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format(
		"/api/v4/projects/%s/merge_requests/%s/discussions?per_page=100",
		encoded_path,
		tostring(iid)
	)
	M.rest_request(gitlab_url, token, "GET", endpoint, function(err, data)
		if err then
			callback(err, nil)
			return
		end
		if type(data) == "table" and #data == 100 then
			vim.notify(
				"gitlab-ide: discussion list hit 100-item cap; older threads may be truncated",
				vim.log.levels.WARN
			)
		end
		callback(nil, data or {})
	end)
end

--- Create a new top-level note on a merge request
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param iid string|number The merge request IID
---@param body string The note body
---@param callback function Callback function(err, note)
function M.create_mr_note(gitlab_url, token, project_path, iid, body, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/merge_requests/%s/notes", encoded_path, tostring(iid))
	M.rest_request(gitlab_url, token, "POST", endpoint, callback, { body = { body = body } })
end

--- Reply to an existing discussion on a merge request
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param iid string|number The merge request IID
---@param discussion_id string The discussion ID
---@param body string The reply body
---@param callback function Callback function(err, note)
function M.reply_to_discussion(gitlab_url, token, project_path, iid, discussion_id, body, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format(
		"/api/v4/projects/%s/merge_requests/%s/discussions/%s/notes",
		encoded_path,
		tostring(iid),
		discussion_id
	)
	M.rest_request(gitlab_url, token, "POST", endpoint, callback, { body = { body = body } })
end

--- Resolve or unresolve a discussion on a merge request
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param iid string|number The merge request IID
---@param discussion_id string The discussion ID
---@param resolved boolean True to resolve, false to unresolve
---@param callback function Callback function(err, discussion)
function M.resolve_discussion(gitlab_url, token, project_path, iid, discussion_id, resolved, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format(
		"/api/v4/projects/%s/merge_requests/%s/discussions/%s?resolved=%s",
		encoded_path,
		tostring(iid),
		discussion_id,
		tostring(resolved and true or false)
	)
	M.rest_request(gitlab_url, token, "PUT", endpoint, callback)
end

--- Fetch issues assigned to the current user in a project
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param callback function Callback function(err, issues)
function M.fetch_issues(gitlab_url, token, project_path, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format(
		"/api/v4/projects/%s/issues?scope=assigned_to_me&state=opened&per_page=50",
		encoded_path
	)
	M.rest_request(gitlab_url, token, "GET", endpoint, callback)
end

--- Fetch a single issue with full detail
---@param gitlab_url string The GitLab base URL
---@param token string The GitLab API token
---@param project_path string The project path
---@param iid string|number The issue IID
---@param callback function Callback function(err, issue)
function M.fetch_issue_detail(gitlab_url, token, project_path, iid, callback)
	local encoded_path = M.url_encode_path(project_path)
	local endpoint = string.format("/api/v4/projects/%s/issues/%s", encoded_path, tostring(iid))
	M.rest_request(gitlab_url, token, "GET", endpoint, callback)
end

return M
