# gitlab-ide.nvim

A Neovim plugin for viewing GitLab CI/CD pipeline status in a multi-column floating window interface.

## Look and feel

See active jobs in your pipeline:

<img width="1223" height="629" alt="image" src="https://github.com/user-attachments/assets/c2eecb3a-10b7-45f5-bf9e-deadca756f7e" />

See logs from your jobs in real time:

<img width="1293" height="792" alt="image" src="https://github.com/user-attachments/assets/de103adf-4ae4-4236-910d-8308e7088e7c" />

Navigate through existing Merge Requests:

<img width="1086" height="584" alt="image" src="https://github.com/user-attachments/assets/29857e3a-9843-4cc6-b53a-e5bb6d0926f3" />

Create MRs from your pipeline buffers:

<img width="1247" height="627" alt="image" src="https://github.com/user-attachments/assets/1978a92e-ac41-4a00-a50a-02e56232883d" />


## Requirements

- Neovim 0.10+ (for `vim.system()` support)
- `curl` command available in PATH
- GitLab personal access token with `api` scope (for job actions) or `read_api` (read-only)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "your-username/gitlab-ide.nvim",
  config = function()
    require("gitlab-ide").setup({})
  end,
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "your-username/gitlab-ide.nvim",
  config = function()
    require("gitlab-ide").setup({})
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
require("gitlab-ide").setup({
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
:GitlabIdePipeline
```

This opens a multi-column floating window showing the pipeline for your current branch. Navigate to any job and press `Enter` to view its log, or use action keys to cancel/retry jobs directly from the UI.

### Pipeline View Keybindings

| Key | Action |
|-----|--------|
| `h` | Move to previous stage column |
| `l` | Move to next stage column |
| `j` / `k` | Navigate jobs within stage (native Vim motion) |
| `Enter` | Open job log (drill-down) |
| `o` | Open job page in browser |
| `c` | Cancel job under cursor (with confirmation) |
| `x` | Retry job under cursor |
| `C` | Cancel entire pipeline (with confirmation) |
| `X` | Retry failed jobs in pipeline |
| `r` | Refresh pipeline data |
| `q` / `Esc` | Close pipeline view |

### MR Detail View Keybindings

From the MR list, press `Enter` on a merge request to open its detail view.

| Key | Action |
|-----|--------|
| `q` / `Backspace` | Back to MR list |
| `Esc` | Close everything |
| `a` | Approve the MR (with confirmation) |
| `o` | Open MR in browser |
| `c` | Copy MR URL to clipboard |
| `d` | Load diff stats |
| `r` | Refresh MR detail |
| `t` | Open discussion threads view |
| `C` | Enter review mode (check out the branch, diff against target) |

### MR Review Mode

From the MR detail view, press `C` to review the MR in real buffers instead of a
diff dump: the source branch is fetched and checked out, and the diff base is
repointed at `merge-base(<remote>/<target branch>, HEAD)`.

That base matters. After a checkout the working tree is clean, so gitsigns shows
nothing — it diffs against `HEAD`, and `HEAD` is the MR. Repointing the base at
the merge-base makes the gutter, `]c` / `[c` and the file list describe the MR's
own changes, while every buffer stays a real file with a live LSP. The merge-base
is used rather than the target branch itself, so the target's own drift is not
mistaken for part of the MR.

Requires [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim) for the
gutter signs. [diffview.nvim](https://github.com/sindrets/diffview.nvim) is used
for the file list when installed, otherwise the gitsigns quickfix list is.
Neither is a hard dependency.

| Command | Action |
|---------|--------|
| `:GitlabIdeReview [ref]` | Review the current checkout against `ref` (default: the remote's default branch) |
| `:GitlabIdeReviewStop` | Reset the diff base to `HEAD` |

`:GitlabIdeReviewStop` leaves the branch checked out, so reading can continue.

Review mode refuses to start when the working tree is dirty, when a local branch
of the same name holds commits the remote does not have, or when the MR comes
from a fork (not supported yet).

```lua
require("gitlab-ide").setup({
  review = {
    strategy = "checkout", -- "checkout" | "worktree" (not implemented yet)
    view = "auto",         -- "auto" | "diffview" | "quickfix" | "none"
    auto_fetch = true,     -- Fetch source and target branches before checking out
  },
})
```

### MR Threads View Keybindings

From the MR detail view, press `t` to view discussion threads. System notes (state changes) are filtered out.

| Key | Action |
|-----|--------|
| `Enter` | Expand/collapse the thread under cursor |
| `o` | Open the anchored file at the discussion's line (positional threads only) |
| `r` | Reply to the thread under cursor |
| `R` | Resolve / unresolve the thread under cursor (with confirmation) |
| `c` | Add a new top-level comment to the MR |
| `gr` | Refresh discussions |
| `q` / `Backspace` | Back to MR detail view |
| `Esc` | Close everything |

Inside the reply / new-comment input window: `Ctrl-s` submits, `Esc` cancels.

### Log View Keybindings

| Key | Action |
|-----|--------|
| `q` / `Backspace` | Back to pipeline view |
| `Esc` | Close everything |
| `o` | Open job page in browser |
| `r` | Refresh log |
| `j` / `k` / `Ctrl-d` / `Ctrl-u` / `G` / `gg` | Scroll (native Vim motions) |

Logs for running/pending jobs auto-refresh every 5 seconds.

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
