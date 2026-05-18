#!/usr/bin/env bash
# repo_janitor.sh — automated, SAFE repo hygiene so interactive budget isn't
# burned re-cleaning the same sprawl. Designed to run unattended (cron / git
# hook / scheduled task).
#
# Honors CLAUDE.md "Shared Checkout Safety": it RESCUES dirty WIP before
# touching anything, and only prunes worktrees that are provably landed AND
# clean. It NEVER force-discards uncommitted work.
#
# Usage:
#   tool/repo_janitor.sh              # DRY RUN — report only, change nothing
#   tool/repo_janitor.sh --apply      # actually rescue + prune
#
# What it does (in order):
#   1. RESCUE: every worktree with uncommitted tracked changes is snapshotted
#      (non-destructively, `git stash create`) to a pushed branch
#      rescue/janitor/<base>-<utc>. Working tree is left untouched.
#   2. PRUNE WORKTREES: remove only worktrees whose HEAD is an ancestor of
#      origin/master (work already landed) AND have no uncommitted tracked
#      changes. The main checkout + a NEVER-prune keep-list are skipped.
#   3. PRUNE REFS: delete local branches merged into origin/master
#      (skips master, backup/*, rescue/*, and the keep-list).
#
# Conservative by design: anything unmerged, dirty, or unknown is KEPT and
# reported, never deleted.
set -u

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1
MODE=$([ "$APPLY" = 1 ] && echo "APPLY" || echo "DRY-RUN")

# Worktree basenames that must NEVER be pruned even if they look landed.
# Add long-lived lanes here (e.g. parked work).
KEEP_WORKTREES="${REPO_JANITOR_KEEP:-}"
# Branch globs never deleted.
KEEP_BRANCHES_RE='^(master|backup/|rescue/)'

command -v git >/dev/null 2>&1 || { echo "ERROR: git missing"; exit 4; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: not a git repo"; exit 4; }

echo "==> repo_janitor [$MODE]  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git fetch origin --quiet 2>/dev/null || { echo "ERROR: git fetch failed"; exit 4; }
OM=$(git rev-parse origin/master 2>/dev/null) || { echo "ERROR: no origin/master"; exit 4; }
MAIN=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}')
UTC=$(date -u +%Y%m%d-%H%M%S)
resc=0; pruned=0; kept=0; brdel=0

# ---- parse worktrees ----
git worktree list --porcelain 2>/dev/null | awk '
/^worktree /{p=substr($0,10)} /^branch /{b=substr($0,8)} /^detached/{b="(detached)"}
/^$/{if(p)print p"\t"b; p="";b=""} END{if(p)print p"\t"b}' > /tmp/_jw.tsv

while IFS=$'\t' read -r path branch; do
  [ -z "$path" ] && continue
  base=$(basename "$path"); br=$(echo "$branch" | sed 's#refs/heads/##')

  # 1. RESCUE dirty tracked WIP (any worktree, including main)
  dirty=$(git -C "$path" status --porcelain --untracked-files=no 2>/dev/null | grep -c .)
  if [ "$dirty" -gt 0 ]; then
    rb="rescue/janitor/${base}-${UTC}"
    if [ "$APPLY" = 1 ]; then
      ss=$(git -C "$path" stash create "repo_janitor auto-rescue $base @ $UTC" 2>/dev/null)
      if [ -n "$ss" ]; then
        git branch -f "$rb" "$ss" >/dev/null 2>&1
        git push origin "$rb" >/dev/null 2>&1 && echo "  RESCUED  $base ($dirty files) -> origin/$rb" && resc=$((resc+1))
      fi
    else
      echo "  would RESCUE  $base ($dirty dirty files) -> origin/$rb"; resc=$((resc+1))
    fi
  fi

  # never prune main checkout or keep-list
  if [ "$path" = "$MAIN" ]; then continue; fi
  case " $KEEP_WORKTREES " in *" $base "*) echo "  KEEP(keeplist) $base"; kept=$((kept+1)); continue;; esac
  # SAFETY (Shared Checkout Safety, binding): only one-shot `agent-*` dispatch
  # worktrees are ever auto-pruned. Session/loop worktrees (any other basename,
  # including the current session's own) are human/loop-driven and may sit
  # idle landed+clean between turns -- never auto-remove them.
  case "$base" in agent-*) ;; *) echo "  KEEP(session)  $base"; kept=$((kept+1)); continue;; esac

  sha=$(git -C "$path" rev-parse HEAD 2>/dev/null)
  if [ "$dirty" -gt 0 ]; then echo "  KEEP(dirty)    $base [$br]"; kept=$((kept+1)); continue; fi
  if git merge-base --is-ancestor "$sha" "$OM" 2>/dev/null; then
    # 2. landed + clean -> prune
    if [ "$APPLY" = 1 ]; then
      git worktree unlock "$path" >/dev/null 2>&1
      git worktree remove --force --force "$path" >/dev/null 2>&1
      [ -d "$path" ] && rm -rf "$path" 2>/dev/null
      [ ! -d "$path" ] && { echo "  PRUNED   $base [$br]"; pruned=$((pruned+1)); }
    else
      echo "  would PRUNE  $base [$br] (landed+clean)"; pruned=$((pruned+1))
    fi
  else
    echo "  KEEP(unmerged) $base [$br]"; kept=$((kept+1))
  fi
done < /tmp/_jw.tsv
[ "$APPLY" = 1 ] && git worktree prune 2>/dev/null

# 3. merged local branch refs
for b in $(git branch --merged origin/master --format='%(refname:short)' 2>/dev/null); do
  echo "$b" | grep -qE "$KEEP_BRANCHES_RE" && continue
  if [ "$APPLY" = 1 ]; then git branch -D "$b" >/dev/null 2>&1 && brdel=$((brdel+1));
  else brdel=$((brdel+1)); fi
done

echo "----"
echo "[$MODE] rescued=$resc  worktrees_pruned=$pruned  kept=$kept  merged_branch_refs=$brdel"
[ "$APPLY" = 0 ] && echo "(dry run — re-run with --apply to act)"
exit 0
