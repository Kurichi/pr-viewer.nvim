# pr-viewer.nvim

GitHub PR を Neovim でレビューするプラグイン。Lua、Neovim >= 0.11、ランタイム依存なし。

## 最初に読む

- `docs/DESIGN.md`: ゴール、決定事項 D1〜D7、モジュール構成、マイルストーン M0〜M5。**設計を変えるときはこの文書を先に更新する**
- 現在地はマイルストーン表を見る。着手中の M を README の Status にも反映する

## 守ること

- **API 呼び出し回数の原則**: 開くとき 1 回、レビュー中 0 回、送信 1 回。崩す変更は PR 本文に理由を書く
- `gh` は `lua/pr-viewer/gh/transport.lua` の `graphql()` / `rest()` 経由でのみ呼ぶ。他のモジュールで `vim.system({"gh", ...})` を書かない
- ネットワークと git は常に非同期（`vim.system` + callback）。`:wait()` は `health.lua` だけ
- 書き込みは楽観的更新。先にローカル状態と表示を変え、失敗時だけ戻す
- review.nvim（`../review.nvim`）からコードを移植するときは、`session.current` のようなグローバル状態を持ち込まない。PR ごとの `Session` を引数で渡す
- キーマップはレビュー用バッファにバッファローカルで張る。グローバルには張らない
- コメントは日本語、識別子・型注釈（`---@class` 等）は英語

## コマンド

```sh
make deps        # plenary.nvim を .deps/ に固定コミットで取得
make test        # nvim --headless で tests/ を実行（PlenaryBusted）
make lint        # luacheck
make fmt         # stylua（CI は --check）
```

テストは `tests/pr-viewer/<module>_spec.lua`。`transport._system` を差し替えて gh を偽装する（`transport_spec.lua` 参照）。

## GitHub 側

- リポジトリ設定は `scripts/gh-repo-setup.sh` で宣言的に管理する。設定画面を手で触ったらスクリプトも直す
- main は ruleset で保護（squash のみ、CI 必須、直 push 不可）。作業はブランチ + PR
- CI の必須チェック名は `lint`, `test (v0.11.0)`, `test (stable)`。ジョブ名を変えたらスクリプトの `CI_CHECKS` も変える
- GitHub Actions は SHA 固定 + タグをコメント併記（Renovate が追従する）
