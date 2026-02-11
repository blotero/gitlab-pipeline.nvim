-- gitlab-pipeline.nvim plugin loader
-- Auto-load and register commands

-- Prevent loading twice
if vim.g.loaded_gitlab_pipeline then
  return
end
vim.g.loaded_gitlab_pipeline = true

-- Check Neovim version (requires 0.10+ for vim.system)
if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("gitlab-pipeline.nvim requires Neovim 0.10 or later", vim.log.levels.ERROR)
  return
end

-- Register the :GitlabPipeline command
vim.api.nvim_create_user_command("GitlabPipeline", function()
  require("gitlab-pipeline").open()
end, {
  desc = "Open GitLab pipeline view for current branch",
})
