# gitlab-pipeline.nvim

A Neovim plugin for viewing GitLab CI/CD pipeline status in a multi-column floating window interface.

## Requirements

- Neovim 0.10+ (for `vim.system()` support)
- `curl` command available in PATH
- GitLab personal access token with `read_api` scope

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-username/gitlab-pipeline.nvim",
  config = function()
    require("gitlab-pipeline").setup({})
  end,
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "your-username/gitlab-pipeline.nvim",
  config = function()
    require("gitlab-pipeline").setup({})
  end,
}
```

## Configuration

### GitLab Token

Set your GitLab token using one of these methods (in order of priority):

1. Environment variable `GITLAB_TOKEN`
2. Environment variable `GITLAB_PAT`
3. Configuration option `token`

```lua
require("gitlab-pipeline").setup({
  -- Optional: specify token directly (not recommended, use env vars instead)
  -- token = "your-gitlab-token",

  -- Optional: specify which git remote to use (default: "origin")
  remote = "origin",

  -- Optional: override GitLab URL (auto-detected from remote by default)
  -- gitlab_url = "https://gitlab.example.com",
})
```

## Usage

Open a GitLab repository in Neovim and run:

```vim
:GitlabPipeline
```

This opens a multi-column floating window showing the pipeline for your current branch.

### Keybindings

| Key | Action |
|-----|--------|
| `h` | Move to previous stage column |
| `l` | Move to next stage column |
| `j` / `k` | Navigate jobs within stage (native Vim motion) |
| `q` | Close pipeline view |
| `Esc` | Close pipeline view |
| `r` | Refresh pipeline data |

### Status Icons

| Status | Icon |
|--------|------|
| Success | ✓ |
| Failed | ✗ |
| Running | ● |
| Pending | ○ |
| Skipped | ⊘ |
| Canceled | ⊘ |
| Manual | ▶ |

## License

MIT
