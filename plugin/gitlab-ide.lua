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
