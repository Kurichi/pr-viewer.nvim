# pr-viewer.nvim

GitHub Pull Request viewer for Neovim.
**One request to open, zero while reviewing, one to submit.**

> Status: **M4 (threads and pickers)**. Open the PR for the current branch with `:PR`, pick one with `:PR list`, review with a two-pane diff, mark files viewed, add draft comments to your GitHub pending review, reply to and resolve threads, and submit. Remaining: vimdoc and optional telescope / snacks pickers (M5). See [docs/DESIGN.md](docs/DESIGN.md) for goals, decisions, and the roadmap.

## Why another PR plugin?

[octo.nvim](https://github.com/pwntester/octo.nvim) is great, but every action costs a GitHub API round trip (350ms+ even with a warm connection). pr-viewer.nvim is built around the API call count instead:

- Opening a PR fetches everything (metadata, changed files, viewed state, review threads) in **one GraphQL query**.
- Reviewing runs **entirely on local state**: the diff comes from local git (`git show base:path` vs. your working tree, so LSP works), viewed marks are optimistic and synced in the background, comments stay local.
- Draft comments go to your GitHub **pending review** in the background (so they survive restarts and show up in the browser). If a send fails, the draft is kept locally and retried later.
- Submitting is **one `submitPullRequestReview` mutation**.

## Requirements

- Neovim >= 0.11
- [GitHub CLI](https://cli.github.com/) (`gh`), authenticated (`gh auth login`)
- git

No runtime plugin dependencies.

## Installation

lazy.nvim:

```lua
{
  "Kurichi/pr-viewer.nvim",
  cmd = "PR",
  opts = {},
}
```

Run `:checkhealth pr-viewer` to verify `gh` and authentication.

## Usage

| Command | Description |
|---|---|
| `:PR` / `:PR open` | Open the PR for the current branch (one query) |
| `:PR open <number\|url>` | Open a PR: `123`, `owner/repo#123`, or a GitHub URL |
| `:PR list` | Pick an open PR (`vim.ui.select`) |
| `:PR health` | `:checkhealth pr-viewer` |

Default buffer-local keymaps (see `lua/pr-viewer/config.lua`):

| Key | Action |
|---|---|
| `,<Space>` | Toggle viewed for the current file (or the file under the cursor in the panel). Changes show instantly and sync in one batched request after `sync.debounce_ms` |
| `]f` / `[f` | Next / previous file |
| `]t` / `[t` | Next / previous review thread (across files) |
| `,v` | Show the thread(s) on the cursor line (`K` stays LSP hover) |
| `,c` | Add a draft comment on the cursor line (or the visual selection) |
| `,e` / `,d` | Edit / delete the draft on the cursor line |
| `,r` | Reply to the thread on the cursor line (published immediately) |
| `,R` | Resolve / unresolve the thread on the cursor line |
| `,l` | List threads and drafts, jump to one |
| `,s` | Submit the review (comment / approve / request changes) |
| `<CR>` | Open the file under the cursor (file panel) |
| `q` | Close the PR view |

The left pane is `git show <merge-base>:<path>`. The right pane is always a real file so LSP (`gd`, `K`, ...) works: your working tree when `HEAD` matches the PR head, otherwise a detached worktree of the PR head under `stdpath("cache")/pr-viewer/worktrees` (your branch is never touched). Set `diff.use_local_fs = false` to use `git show <head>:<path>` instead.

## Development

```sh
make deps   # fetch plenary.nvim (pinned) into .deps/
make test   # headless tests
make lint   # luacheck
make fmt    # stylua
```

`scripts/gh-repo-setup.sh` applies the GitHub repository settings (topics, merge policy, labels, and with `--ruleset` the branch ruleset) idempotently.

## License

MIT
