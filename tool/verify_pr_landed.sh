#!/usr/bin/env bash
# verify_pr_landed.sh — confirm a merged PR's content is actually on origin/master,
# nothing was dropped during squash, and it has not since regressed.
#
# WHY: in this repo "MERGED" on GitHub means almost nothing — PRs are squash-merged
# (branch tip is NOT an ancestor of master), the shared main checkout is frequently
# `reset --hard origin/master`, and 20+ worktrees churn master constantly. The only
# trustworthy signal is CONTENT on origin/master, not PR/branch status.
#
# Usage:
#   tool/verify_pr_landed.sh <PR_NUMBER> [symbol1 symbol2 ...]
#
#   <PR_NUMBER>   the PR to verify
#   [symbols]     optional: distinctive strings/identifiers the PR introduced.
#                 Each is grepped on origin/master (must be PRESENT) — the strongest
#                 "did it land AND not regress" signal.
#
# Exit codes: 0 = verified landed & no drop & symbols present
#             1 = merge commit not on origin/master (NOT landed)
#             2 = files proposed but not landed (squash dropped part of the PR)
#             3 = a required symbol is missing from origin/master (regressed/never landed)
#             4 = usage / prerequisite error
set -u

PR="${1:-}"
shift || true
SYMBOLS=("$@")

if [ -z "$PR" ]; then
  echo "usage: tool/verify_pr_landed.sh <PR_NUMBER> [symbol ...]" >&2
  exit 4
fi
command -v gh  >/dev/null 2>&1 || { echo "ERROR: gh CLI not found" >&2; exit 4; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git not found"    >&2; exit 4; }

echo "==> Fetching origin ..."
git fetch origin --quiet || { echo "ERROR: git fetch failed" >&2; exit 4; }

STATE=$(gh pr view "$PR" --json state         -q .state         2>/dev/null)
MC=$(   gh pr view "$PR" --json mergeCommit    -q .mergeCommit.oid 2>/dev/null)
BASE=$( gh pr view "$PR" --json baseRefName    -q .baseRefName   2>/dev/null)
TITLE=$(gh pr view "$PR" --json title          -q .title         2>/dev/null)

echo "PR #$PR  state=$STATE  base=$BASE"
echo "  title: $TITLE"
echo "  mergeCommit: ${MC:-<none>}"

if [ "$BASE" != "master" ]; then
  echo "WARNING: PR base is '$BASE', not master — a MERGED status here does NOT mean it is on master."
fi
if [ -z "$MC" ] || [ "$MC" = "null" ]; then
  echo "RESULT: NOT LANDED — PR has no merge commit (not merged, or closed)."
  exit 1
fi

# 1. Is the merge/squash commit actually on origin/master?
if git branch -r --contains "$MC" 2>/dev/null | grep -qx '  origin/master'; then
  echo "[1/3] merge commit $MC IS on origin/master  ✓"
else
  echo "[1/3] merge commit $MC is NOT on origin/master  ✗"
  echo "RESULT: NOT LANDED."
  exit 1
fi

# 2. Proposed vs landed file set — catches "a reduced version got squashed".
PROPOSED=$(mktemp); LANDED=$(mktemp)
gh pr diff "$PR" --name-only 2>/dev/null | sed '/^$/d' | sort -u > "$PROPOSED"
git show --name-only --format= "$MC" 2>/dev/null | sed '/^$/d' | sort -u > "$LANDED"
DROPPED=$(comm -23 "$PROPOSED" "$LANDED")
EXTRA=$(  comm -13 "$PROPOSED" "$LANDED")
echo "[2/3] proposed files: $(wc -l < "$PROPOSED" | tr -d ' ')   landed files: $(wc -l < "$LANDED" | tr -d ' ')"
if [ -n "$DROPPED" ]; then
  echo "  ✗ FILES PROPOSED BUT NOT LANDED (dropped during squash/review):"
  echo "$DROPPED" | sed 's/^/      - /'
fi
[ -n "$EXTRA" ] && { echo "  note: files in merge commit beyond the PR diff (rebase/squash context):"; echo "$EXTRA" | sed 's/^/      + /'; }

# 3. Regression surface — what touched the PR's files AFTER it merged.
echo "[3/3] post-merge commits touching this PR's files (review for regression):"
ANY_POST=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  LOG=$(git log --oneline "$MC"..origin/master -- "$f" 2>/dev/null)
  if [ -n "$LOG" ]; then
    ANY_POST=1
    echo "  ~ $f"
    echo "$LOG" | sed 's/^/      /'
  fi
done < "$LANDED"
[ "$ANY_POST" = 0 ] && echo "  (none — no commit has touched these files since the merge)"

# Optional: required symbols must still be present on origin/master.
SYM_FAIL=0
if [ "${#SYMBOLS[@]}" -gt 0 ]; then
  echo "[symbols] presence on origin/master:"
  for s in "${SYMBOLS[@]}"; do
    if git grep -n -F -- "$s" origin/master >/dev/null 2>&1; then
      echo "  ✓ present: $s"
    else
      echo "  ✗ MISSING (regressed or never landed): $s"
      SYM_FAIL=1
    fi
  done
fi

rm -f "$PROPOSED" "$LANDED"
echo "----"
if [ -n "$DROPPED" ]; then echo "RESULT: PARTIAL — part of the PR did not land. Investigate dropped files."; exit 2; fi
if [ "$SYM_FAIL" = 1 ]; then echo "RESULT: REGRESSED — a required symbol is gone from origin/master."; exit 3; fi
echo "RESULT: VERIFIED — full file set landed on origin/master; review the post-merge list above for behavioural regressions."
exit 0
