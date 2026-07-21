-- Shared status icons and highlights for gitlab-ide.nvim
local M = {}

-- Status icons mapping
M.icons = {
	SUCCESS = "✓",
	FAILED = "✗",
	RUNNING = "●",
	PENDING = "○",
	SKIPPED = "⊘",
	CANCELED = "⊘",
	MANUAL = "▶",
	CREATED = "○",
	WAITING_FOR_RESOURCE = "○",
	PREPARING = "○",
	SCHEDULED = "◷",
}

-- Highlight groups mapping
M.highlights = {
	SUCCESS = "DiagnosticOk",
	FAILED = "DiagnosticError",
	RUNNING = "DiagnosticInfo",
	PENDING = "Comment",
	SKIPPED = "Comment",
	CANCELED = "DiagnosticWarn",
	MANUAL = "DiagnosticHint",
	CREATED = "Comment",
	WAITING_FOR_RESOURCE = "Comment",
	PREPARING = "DiagnosticInfo",
	SCHEDULED = "DiagnosticHint",
}

--- Get the icon for a status
---@param status string The job/stage status (job statuses are upper-case
---enums, e.g. "SUCCESS"; CiStage.status comes back lower-case, e.g.
---"success" - normalize so both hit the same table)
---@return string icon The status icon
function M.get_icon(status)
	return M.icons[status and status:upper() or status] or "?"
end

--- Get the highlight group for a status
---@param status string The job/stage status
---@return string highlight The highlight group name
function M.get_highlight(status)
	return M.highlights[status and status:upper() or status] or "Normal"
end

-- Marker appended to bridge (trigger) job lines to signal a drillable
-- downstream/child pipeline
M.bridge_marker = "⤷"

--- Check whether a job is a bridge (trigger) job that spawns a downstream pipeline
---@param job table Job data
---@return boolean is_bridge
function M.is_bridge(job)
	return job ~= nil and job.kind == "BRIDGE"
end

return M
