#!/usr/bin/env bash
# pre_merge_gate.sh — cheap pre-merge safety net while CI is dark
# (ci.yml gated to workflow_dispatch until 2026-06-01). Catches the class of
# regression that currently slips silently (e.g. the permission_explainer
# missing-map-entry bug that shipped because nothing checked the PR).
#
# NOT a full CI. A fast (~minutes) GO / NO-GO on a PR's own diff:
#   - the PR branch actually merges cleanly onto current origin/master
#   - `dart analyze` is clean for the changed Dart files
#   - every changed/added *_test.dart file passes
#
# Usage:
#   tool/pre_merge_gate.sh <PR_NUMBER>
#
# Exit: 0 = GO (clean)  | 1 = NO-GO (analyze or tests failed / conflicts)
#       4 = usage / prerequisite error
#
# Runs in a throwaway worktree so it never touches the shared checkout
# (CLAUDE.md Shared Checkout Safety).
set -u
PR="${1:-}"
[ -z "$PR" ] && { echo "usage: tool/pre_merge_gate.sh <PR_NUMBER>" >&2; exit 4; }
command -v gh  >/dev/null 2>&1 || { echo "ERROR: gh missing"  >&2; exit 4; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git missing" >&2; exit 4; }
command -v flutter >/dev/null 2>&1 || { echo "ERROR: flutter missing" >&2; exit 4; }

git fetch origin --quiet || { echo "ERROR: fetch failed" >&2; exit 4; }
HEADREF=$(gh pr view "$PR" --json headRefName -q .headRefName 2>/dev/null)
BASE=$(   gh pr view "$PR" --json baseRefName -q .baseRefName 2>/dev/null)
[ -z "$HEADREF" ] && { echo "ERROR: PR #$PR not found" >&2; exit 4; }
echo "==> pre_merge_gate PR #$PR  head=$HEADREF base=$BASE"
[ "$BASE" != "master" ] && echo "WARNING: base is '$BASE', not master"

WT=".git/_premerge_pr${PR}"
git worktree remove --force "$WT" >/dev/null 2>&1
git worktree add --quiet --detach "$WT" "origin/master" 2>/dev/null || { echo "ERROR: worktree add failed" >&2; exit 4; }
cleanup(){ git worktree remove --force "$WT" >/dev/null 2>&1; }
trap cleanup EXIT

cd "$WT" || { echo "ERROR: cd failed" >&2; exit 4; }
git fetch origin --quiet "$HEADREF" 2>/dev/null

# 1. merges cleanly onto current master?
if ! git merge --no-commit --no-ff FETCH_HEAD >/dev/null 2>&1; then
  git merge --abort >/dev/null 2>&1
  echo "[1/3] merge onto current origin/master: CONFLICTS  ✗"
  echo "RESULT: NO-GO — rebase the PR onto current master first."
  exit 1
fi
echo "[1/3] merges cleanly onto current origin/master  ✓"

# changed files (PR head vs merge-base with master)
MB=$(git merge-base origin/master FETCH_HEAD)
mapfile -t CHANGED < <(git diff --name-only "$MB" FETCH_HEAD -- '*.dart' 2>/dev/null)
DARTS=(); TESTS=()
for f in "${CHANGED[@]}"; do
  [ -f "$f" ] || continue
  DARTS+=("$f")
  case "$f" in test/*_test.dart|test/**/*_test.dart) TESTS+=("$f");; esac
done
echo "      changed Dart files: ${#DARTS[@]}  (test files: ${#TESTS[@]})"

# 2. analyze changed Dart files
if [ "${#DARTS[@]}" -gt 0 ]; then
  flutter pub get >/dev/null 2>&1
  dart analyze "${DARTS[@]}" 2>&1 | tee /tmp/_pmg_an.txt
  ANALYZE_STATUS=${PIPESTATUS[0]}
  if grep -qE '^\s*error ' /tmp/_pmg_an.txt; then
    echo "[2/3] dart analyze: ERRORS  ✗"; grep -E '^\s*error ' /tmp/_pmg_an.txt | head -10
    echo "RESULT: NO-GO — analyzer errors in changed files."; exit 1
  fi
  if [ "$ANALYZE_STATUS" -ne 0 ]; then
    echo "[2/3] dart analyze: FAILED  ✗"
    echo "RESULT: NO-GO — analyzer exited with status $ANALYZE_STATUS."; exit 1
  fi
  echo "[2/3] dart analyze on changed files: clean  ✓"
else
  echo "[2/3] no changed Dart files — analyze skipped"
fi

# 3. run changed test files
if [ "${#TESTS[@]}" -gt 0 ]; then
  flutter test "${TESTS[@]}" --reporter expanded 2>&1 | tee /tmp/_pmg_t.txt
  TEST_STATUS=${PIPESTATUS[0]}
  tail -3 /tmp/_pmg_t.txt
  if [ "$TEST_STATUS" -eq 0 ]; then
    echo "[3/3] changed test files: PASS  ✓"
  else
    echo "[3/3] changed test files: FAIL  ✗"
    echo "RESULT: NO-GO — changed tests failing."; exit 1
  fi
else
  echo "[3/3] no changed test files — test run skipped"
fi

echo "----"
echo "RESULT: GO — clean merge, analyzer clean, changed tests pass. (Not full CI; broader suite still applies once CI returns.)"
exit 0
