# pr-viewer.nvim 設計ドキュメント

最終更新: 2026-09-28（M4 実装時点）

## 1. ゴール

**GitHub の Pull Request を、ブラウザや octo.nvim より速く・迷わず Neovim 内でレビューできること。**

「速い」は体感ではなく、API 呼び出し回数で定義する。

| 場面 | 目標 | octo.nvim（参考） |
|---|---|---|
| PR を開く | GraphQL 1 回 + ローカル git。1 秒以内に diff が見える | 4〜5 回を逐次 |
| レビュー中（viewed、コメント追加、移動） | **0 回**（viewed は裏で非同期同期） | 操作ごとに 1 回以上 |
| レビュー送信 | mutation 1 回（全コメントをまとめて） | 1 回 |

### 1.1 なぜ回数なのか（計測結果）

`gh` を curl や libuv に置き換えても、1 往復あたり 100ms 程度しか縮まらない。

| 区間 | 時間 |
|---|---|
| gh プロセス起動 | 約 90ms |
| TCP + TLS 確立 | 約 75〜160ms |
| リクエスト送信 → 初回バイト（API 処理） | 約 300〜350ms |
| 1 リクエスト合計（新規接続） | 約 400〜500ms |
| 接続再利用時の 2 リクエスト目 | 約 345ms |

接続を使い回しても 1 往復 350ms を切れない。速くなるのは **API を呼ぶ回数と、呼ぶタイミングを設計で変える**ときだけ。

### 1.2 非ゴール（v1）

- Issue / Discussion / Projects の閲覧・操作
- PR の作成・編集・マージ（`gh pr create` 等で十分）
- リアクション、ラベル・レビュアー編集
- octo.nvim の完全な代替。レビューに関係ない機能は追わない

## 2. 決定事項

### D1. 土台は新規リポジトリ。review.nvim からは「移植」し、依存はしない

ユーザー判断で `pr-viewer.nvim` を新規に切った。review.nvim を調査した結果もこれを支持する。

- 再利用できる: `comment.create`（純粋ファクトリ）、`diff.parse_diff`、`signs.lua`（extmark）、`storage.read_json/write_json`（tmp + rename のアトミック書き込み）、`ui.open_float`、`export.format_default`（submit 本文の下地）、`plugin` の `parse_flags`
- そのまま使えない: `session.current` の**グローバル単一セッション**（PR ごとの並行状態が持てない）、**作業ツリー行番号だけの位置モデル**（GitHub は `commit_id + path + line + side` を要求し、削除行にもコメントできる）、**同期 `vim.fn.system` の git 呼び出し**、平らなコメント配列（スレッド・返信の概念なし）、グローバルキーマップ

review.nvim 側を壊さずに済み、pr-viewer は PR 専用のデータモデルを最初から持てる。

### D2. 通信層は `gh api` 子プロセス（v1）。インターフェースの裏に隠す

- 認証・GHES・プロキシ・トークンスコープを `gh` に任せられる。`gh auth token` + curl 案は 1 往復 100ms 程度の改善に対して、TLS・エラー処理・再認証を自前で持つコストが見合わない
- `lua/pr-viewer/gh/transport.lua` の公開 API は `graphql(query, variables, cb)` と `rest(method, path, body, cb)` の 2 つだけ。呼び出し側は gh の存在を知らない
- 将来、接続再利用が欲しくなったら同じインターフェースで libuv バックエンドを足す（M5 候補）
- 実行は `vim.system` で常に非同期。`:wait()` は `checkhealth` 以外で使わない

### D3. Neovim >= 0.11、ランタイム依存なし

- `vim.system`、`vim.json`、`vim.validate`（新シグネチャ）、`vim.fs` に依存
- plenary / nui / telescope を必須にしない。picker は `vim.ui.select` を既定にし、telescope / snacks は任意連携（M5）
- テストの plenary は開発時依存（`make deps`、コミット固定）

### D4. diff はローカル git。左ペイン = `git show <base>:<path>`、右ペイン = 実ファイル

- base / head のコミットが手元に無ければ、最初に 1 回だけ `git fetch origin <baseRefOid> <headRefOid>`（PR head は `refs/pull/N/head` でも取れる）
- 比較基準は merge-base（3-dot）。`git merge-base <base> <head>` をローカルで計算する
- 右ペインは常に実ファイル（LSP・gd が効く）。`HEAD` が PR head なら作業ツリー、違えば `stdpath("cache")/pr-viewer/worktrees/<owner>/<repo>/<N>` に PR head を detached でチェックアウトした worktree を使う（ユーザーのブランチには触れない。2 回目以降は使い回す）。`use_local_fs = false` なら `git show <head>:<path>` の scratch バッファ
- 両ペインを `diffthis` で並べる。GitHub 側の diff テキストは使わない（表示差異の原因になり、API も増える）

### D5. 状態はメモリ上の 1 テーブル（PR ごと）。ディスクに残すのは送信に失敗した下書きだけ

- `Session = { pr, files[], threads[], anchors[], sync = queue }`。下書きも `threads[]` の要素（`pending = true`）として扱う
- 下書きの正本は GitHub の pending review（D7）。送信に失敗したものだけ `stdpath("state")/pr-viewer/<owner>/<repo>/<number>.json` に退避する。書き込みは review.nvim の tmp + rename 方式を移植
- サーバ状態のキャッシュはしない（次に開くとき 1 回取り直す方が単純で、整合性の問題を持ち込まない）

### D6. 起動時に 1 クエリで全部取る

`lua/pr-viewer/gh/graphql.lua` の `pull_request` クエリで、PR 本体・変更ファイル（`viewerViewedState` 込み）・既存 `reviewThreads`（コメント込み）を 1 回で取る。

- `files(first: 100)` / `reviewThreads(first: 100)` を超える PR は、初回描画後に `endCursor` から追加取得する（レビューを止めない）
- `headRefOid` を保持し、後の mutation / 位置計算はすべてこの oid 基準にする（レビュー中に push されてもズレない）

### D7. 書き込みは楽観的更新 + 裏同期。下書きは GitHub の pending review に置く

- **viewed トグル**: 即座にローカル状態と表示を変え、`sync.debounce_ms`（既定 500ms）でまとめて `markFileAsViewed` / `unmarkFileAsViewed` mutation を裏で投げる。同じファイルの連打は最後の状態だけ送る。失敗時だけ通知して表示を戻す
- **コメント（下書き）**: 置き場所は GitHub の **pending review**（他のクライアントからも見え、Neovim を落としても残る）。`,c` は即座にローカルにスレッドを作って表示し、裏で `addPullRequestReview`（pending review の作成、初回のみ・直列化）→ `addPullRequestReviewThread` を送る。ネットワーク等の一時的な失敗なら `stdpath("state")/pr-viewer/<owner>/<repo>/<number>.json` に退避し、次回 open 時と submit 前に再送する。GitHub が拒否した（位置が diff 外など）恒久的な失敗は再送しても無駄なので、通知して下書きを消す
- **submit**: `submitPullRequestReview` 1 回（下書きが無ければ `addPullRequestReview` に event を付けて 1 回）。ローカル退避分が残っていれば送信を中止する
- **返信 / resolve**: 既存スレッドへの操作は対象が明確なので個別 mutation。同じく楽観的更新（返信は末尾に即追加、失敗で取り消し。resolve は即トグル、失敗で戻す）。返信は会話を待たせないため pending review に入れず即公開する

## 3. アーキテクチャ

```
lua/pr-viewer/
  init.lua          setup() / open() / list()       公開 API（薄い）
  command.lua       :PR <sub> のディスパッチと補完   表駆動
  config.lua        既定値・検証・取得
  health.lua        :checkhealth pr-viewer
  gh/
    transport.lua   graphql() / rest()               D2。vim.system 非同期、JSON 正規化
    graphql.lua     クエリ・mutation 文字列          D6。データのみ
    sync.lua        debounce 付き裏同期キュー（alias で複数 mutation を 1 リクエストに）D7。失敗時は confirmed 値へ rollback
  async.lua         coroutine で callback API を直列に書く helper（await / must / run）
  model/
    pr.lua          PR / File / Thread / Comment の型と GraphQL からの変換。下書きも Thread（pending = true）
    position.lua    (path, side, line) <-> バッファ行 の対応
  session.lua       PR ごとの状態、parse_target、ページング追加取得   D5
  git.lua           show / fetch / merge-base / rev-parse   D4。vim.system 非同期
  ui/
    layout.lua      ファイル一覧 + 2 ペイン diff のタブページ、close/cleanup
    files.lua       ファイル一覧パネル（viewed ✓、A/D、+/-、スレッド数）
    diff.lua        diffthis 両ペイン、base/head バッファのキャッシュ
    actions.lua     キーマップから呼ぶ操作（toggle_viewed, next/prev file, next/prev thread, show_thread, close）
    keymaps.lua     バッファローカルキーマップの attach / detach
    thread.lua      スレッド float（表示 + 本文入力）
    （picker は vim.ui.select 直接。telescope / snacks 連携は M5 で picker.lua に切り出す）
  drafts.lua        下書きのライフサイクル（add / edit / delete / resend / submit）D7
  threads.lua       既存スレッドへの返信（即公開）と resolve / unresolve（楽観的更新）
  signs.lua         extmark sign / virt_text（review.nvim から移植）
  storage.lua       送信失敗した下書きの退避 JSON（review.nvim から移植）
plugin/pr-viewer.lua   :PR コマンド定義のみ（require は遅延）
```

依存の向き: `ui/* -> session -> (gh/*, git, storage)`。`gh/*` と `git` は互いを知らない。`model/*` はどこにも依存しない。

### 3.1 データフロー（PR を開く）

```
:PR open 123
  -> session.open(owner, repo, 123)
     -> transport.graphql(pull_request)  ─┐ 並行
     -> git.ensure_commits(base, head)   ─┘
     -> model.from_graphql() で Session を組み立て
     -> ui.layout.open(session)
        -> ui.files.render()
        -> ui.diff.show(first_unviewed_file)   左: git show base:path / 右: 実ファイル or head:path
        -> signs で既存スレッドを表示
  -> hasNextPage なら追加取得（描画後）
```

### 3.2 キーマップ（バッファローカル、`<localleader>` 前提）

`<localleader>` は octo と同じ `,` を想定。dotfiles では `maplocalleader = ","`。

| キー | 動作 | 実装 |
|---|---|---|
| `,<Space>` | viewed トグル（octo 互換） | M2 |
| `]f` / `[f` | 次 / 前のファイル | M1 |
| `]t` / `[t` | 次 / 前のスレッド（ファイルをまたぐ） | M1 |
| `,c` | カーソル行 / 選択範囲にコメント（下書き） | M3 |
| `,e` / `,d` | カーソル行の下書きを編集 / 削除 | M3 |
| `,r` | スレッドに返信（pending review には入れず即公開） | M4 |
| `,R` | スレッドを resolve / unresolve | M4 |
| `,s` | レビュー送信（approve / request changes / comment を選ぶ） | M3 |
| `,l` | スレッド・下書き一覧（picker） | M4 |
| `q` | レビューを閉じる（下書きは保持） | M1 |
| `,v` | カーソル行のスレッドを float 表示（`K` は LSP hover に残す） | M1 |
| `,?` | バッファローカルキー一覧（dotfiles 側の既存機能で代用） | - |

## 4. マイルストーン

| # | 内容 | 完了条件 |
|---|---|---|
| M0 ✅ | 初期セットアップ・設計 | この文書、CI が緑、`:checkhealth pr-viewer` が通る |
| M1 ✅ | **読み取り専用ビュー** | `:PR open N` で 1 秒以内に 2 ペイン diff。ファイル一覧、既存スレッドの表示、`]f` `]t` 移動。API 呼び出しは 1 回（ページング除く） |
| M2 ✅ | **viewed の楽観的同期** | `,<Space>` で即座に表示が変わり、GitHub 側にも反映される。連打しても mutation はまとめて 1 回 |
| M3 ✅ | **リモート下書きと送信** | `,c` の下書きが GitHub の pending review に非同期で乗り、失敗時はローカル退避 + 再送。`,s` で `submitPullRequestReview` 1 回 |
| M4 ✅ | **既存スレッド操作・PR 一覧** | 返信・resolve（楽観的更新）、`:PR list` picker、`:PR` 引数なしでカレントブランチ（1 クエリ） |
| M5 | 仕上げ | vimdoc、telescope / snacks picker、libuv transport（任意）、大規模 PR でのページング検証 |

各マイルストーンは 1 PR 以上に分割してよいが、**「API 呼び出し回数」の原則を崩す変更は PR 本文で理由を書く**（PR テンプレートに欄あり）。

## 5. 参考

- 計測と設計原則の元になった前セッションのメモ（本文書 1.1）
- review.nvim: `/Users/s30264/repos/github.com/Kurichi/review.nvim`（移植元。D1 の対応表）
- octo.nvim: dotfiles の `config/nvim/lua/plugins/octo.lua` に現在の運用（`use_local_fs`、`,?` のキー一覧、`q` で閉じる）がある。UX の下限はこれ
- GitHub GraphQL: `PullRequest.files.viewerViewedState`、`PullRequest.reviewThreads`、`addPullRequestReview`、`markFileAsViewed`、`addPullRequestReviewThread`、`resolveReviewThread`
