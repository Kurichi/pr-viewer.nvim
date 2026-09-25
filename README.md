# pr-viewer.nvim

GitHub Pull Request viewer for Neovim.
**One request to open, zero while reviewing, one to submit.**

> Status: **M0 (scaffolding)**. Nothing user-facing works yet. See [docs/DESIGN.md](docs/DESIGN.md) for goals, decisions, and the roadmap.

## Why another PR plugin?

[octo.nvim](https://github.com/pwntester/octo.nvim) is great, but every action costs a GitHub API round trip (350ms+ even with a warm connection). pr-viewer.nvim is built around the API call count instead:

- Opening a PR fetches everything (metadata, changed files, viewed state, review threads) in **one GraphQL query**.
- Reviewing runs **entirely on local state**: the diff comes from local git (`git show base:path` vs. your working tree, so LSP works), viewed marks are optimistic and synced in the background, comments stay local.
- Submitting sends all comments in **one `addPullRequestReview` mutation**.

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

## Usage (planned)

| Command | Description |
|---|---|
| `:PR` / `:PR open` | Open the PR for the current branch |
| `:PR open <number\|url>` | Open a specific PR |
| `:PR list` | Pick a PR |
| `:PR health` | `:checkhealth pr-viewer` |

Default buffer-local keymaps use `<localleader>` (see `lua/pr-viewer/config.lua`).

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
