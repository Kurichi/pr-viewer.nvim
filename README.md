# pr-viewer.nvim

GitHub Pull Request viewer for Neovim.
**One request to open, zero while reviewing, one to submit.**

> Status: **M3 (drafts and submit)**. `:PR open <number|url>` shows a two-pane diff with the file list and existing review threads, `,<Space>` marks files as viewed, `,c` adds draft comments to your GitHub pending review, and `,s` submits the review. Replying to and resolving existing threads come next. See [docs/DESIGN.md](docs/DESIGN.md) for goals, decisions, and the roadmap.

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
| `:PR open <number\|url>` | Open a PR: `123`, `owner/repo#123`, or a GitHub URL |
| `:PR open` | Open the PR for the current branch (M4, not yet) |
| `:PR list` | Pick a PR (M4, not yet) |
| `:PR health` | `:checkhealth pr-viewer` |

Default buffer-local keymaps (see `lua/pr-viewer/config.lua`):

| Key | Action |
|---|---|
| `,<Space>` | Toggle viewed for the current file (or the file under the cursor in the panel). Changes show instantly and sync in one batched request after `sync.debounce_ms` |
| `]f` / `[f` | Next / previous file |
| `]t` / `[t` | Next / previous review thread (across files) |
| `K` | Show the thread(s) on the cursor line |
| `,c` | Add a draft comment on the cursor line (or the visual selection) |
| `,e` / `,d` | Edit / delete the draft on the cursor line |
| `,s` | Submit the review (comment / approve / request changes) |
| `<CR>` | Open the file under the cursor (file panel) |
| `q` | Close the PR view |

The left pane is `git show <merge-base>:<path>`. The right pane is the real file from your working tree when `HEAD` matches the PR head (so LSP works), otherwise `git show <head>:<path>`.

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
