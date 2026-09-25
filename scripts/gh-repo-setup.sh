#!/usr/bin/env bash
# GitHub 側のリポジトリ設定を宣言的に適用する（冪等）。
#
#   scripts/gh-repo-setup.sh            # 説明・トピック・機能・マージ方式・ラベル
#   scripts/gh-repo-setup.sh --ruleset  # 上記に加え main ブランチのルールセット（main に push 済みが前提）
#
# 手で GitHub の設定画面を触ったら、このスクリプトも合わせて更新する。
set -euo pipefail

REPO="${REPO:-Kurichi/pr-viewer.nvim}"
CI_CHECKS=("lint" "test (v0.11.0)" "test (stable)")

echo "==> repository settings"
gh api -X PATCH "repos/${REPO}" --silent \
  -f description="GitHub Pull Request viewer for Neovim: one request to open, zero while reviewing, one to submit" \
  -F has_wiki=false \
  -F has_projects=false \
  -F has_issues=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F allow_squash_merge=true \
  -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=PR_BODY \
  -F delete_branch_on_merge=true \
  -F allow_update_branch=true

echo "==> topics"
gh api -X PUT "repos/${REPO}/topics" --silent \
  --input - <<'JSON'
{"names":["neovim","neovim-plugin","lua","github","pull-requests","code-review"]}
JSON

echo "==> labels"
ensure_label() {
  local name="$1" color="$2" desc="$3"
  if gh api "repos/${REPO}/labels/$(printf '%s' "$name" | sed 's/ /%20/g')" --silent 2>/dev/null; then
    gh api -X PATCH "repos/${REPO}/labels/$(printf '%s' "$name" | sed 's/ /%20/g')" --silent \
      -f color="$color" -f description="$desc"
  else
    gh api -X POST "repos/${REPO}/labels" --silent -f name="$name" -f color="$color" -f description="$desc"
  fi
}
ensure_label "ux"           "1d76db" "Review experience: keymaps, layout, navigation"
ensure_label "performance"  "d93f0b" "API call count / latency / startup time"
ensure_label "dependencies" "0366d6" "Dependency updates (Renovate)"
ensure_label "roadmap"      "5319e7" "Milestone tracking (docs/DESIGN.md)"

if [[ "${1:-}" == "--ruleset" ]]; then
  echo "==> ruleset: protect main"
  checks_json=$(printf '%s\n' "${CI_CHECKS[@]}" | jq -R '{context: .}' | jq -s .)
  payload=$(jq -n --argjson checks "$checks_json" '{
    name: "protect main",
    target: "branch",
    enforcement: "active",
    conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
    rules: [
      { type: "deletion" },
      { type: "non_fast_forward" },
      { type: "required_linear_history" },
      { type: "pull_request", parameters: {
          required_approving_review_count: 0,
          dismiss_stale_reviews_on_push: false,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: true,
          allowed_merge_methods: ["squash"] } },
      { type: "required_status_checks", parameters: {
          strict_required_status_checks_policy: false,
          required_status_checks: $checks } }
    ]
  }')
  existing=$(gh api "repos/${REPO}/rulesets" --jq '.[] | select(.name=="protect main") | .id')
  if [[ -n "$existing" ]]; then
    gh api -X PUT "repos/${REPO}/rulesets/${existing}" --silent --input - <<<"$payload"
    echo "updated ruleset ${existing}"
  else
    gh api -X POST "repos/${REPO}/rulesets" --silent --input - <<<"$payload"
    echo "created ruleset"
  fi
fi
echo "done"
