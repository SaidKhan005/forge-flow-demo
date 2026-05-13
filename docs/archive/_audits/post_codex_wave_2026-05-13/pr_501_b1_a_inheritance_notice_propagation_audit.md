# PR #501 Audit — B1.a Inheritance Notice Propagation

**Slice:** B1.a (Lane B — features)
**Owner:** Claude lane executor
**Branch:** `claude/b1a-inheritance-notice-propagation`
**Base:** `master` (no drift)
**Gate:** `auto` per ledger — **BUT** worker self-flagged a planning ambiguity that elevates this to **operator decision**.
**Size:** 391 additions / 0 deletions / 3 files (Data Accuracy screen + Polling & Pricing screen + test file)
**Chunking:** light variant

## Pattern B compliance

Both audit tables present in PR body ✓. Worker self-audit + executor independent audit both ran; worker honestly surfaced a real ambiguity rather than silently picking a side.

## Verdict

**operator-decision-required** — the implementation is faithful to the literal slice doc, but the slice doc's gate (`coveredCount == 1`) is logically inconsistent with the cited copy from PR #485 ("Other locations under this scope may have local overrides — review each location individually for accuracy"). That copy is nonsensical when there are no other locations.

Two cited resolutions, both defensible (per worker's planning-ambiguity block in PR body):

1. **Trust the slice-doc gate** (worker's current implementation): keep `== 1`, rewrite copy. Suggested: *"This scope only covers $location. Adjusting at this scope is equivalent to a per-location override — there are no other locations under this scope to inherit it."*
2. **Trust the cited pattern source** (PR #485): flip gate to `coveredCount > 1`, keep copy verbatim. Mirrors `admin_timing_setup_screen.dart:164-166` exactly.

## Executor spot-checks

| Check | Outcome |
|---|---|
| `_singleCoveredLocationName` mirrors PR #485 gate logic | ✓ — `per_location_data_accuracy_screen.dart:348-365` and `polling_and_pricing_admin_screen.dart:310-336` |
| Polling uses scope-level `_assignments` (not user-filtered `_filteredAssignments`) | ✓ — worker correctly notes this prevents user filters silently flipping the notice |
| Notice placed below scope banner / restriction-copy notice, above scoped-action card | ✓ — matches PR #485 placement |
| 8 new widget tests cover business/org-unit single-covered + multi-covered + location-scope | ✓ — `test/admin/data_accuracy_polling_hierarchy_scope_screen_test.dart:386-664` |
| `admin_<tile>_scope_inheritance_notice` key naming convention | ✓ |
| Frozen-surface untouched | ✓ |
| Demo carve-out untouched | ✓ |
| No `audit_logs` write | ✓ — UX-only |
| No schema / proxy / auth touch | ✓ |

## Authority anchors verified

- PR #485 `lib/admin/screens/admin_timing_setup_screen.dart:164-182` — pattern source.
- CLAUDE.md HP #11 — hierarchy-scoped settings honesty; surfacing single-location-degenerate case at "broader" scope is the honesty intent.
- `docs/_execution/lane_b_features/03_execution_slices.md` B1.a — slice doc.

## Findings

**Planning ambiguity (worker-surfaced, executor-confirmed)**: slice doc gate + cited copy form a logical contradiction. This isn't a worker mistake — it's a slice-spec defect the worker correctly flagged before opening the PR.

## Recommendation to operator

**Recommended: Option 1** — keep `coveredCount == 1` gate, rewrite copy for single-location case. Rationale: HP #11's intent ("hierarchy honesty") is precisely to make the admin aware that "business scope" is degenerate when only one location exists. The existing `AdminHierarchyScopeNotice` already handles the multi-location broad-scope case via `restrictionCopy`, so flipping to `> 1` would just duplicate that.

If operator picks Option 1: orchestrator can fix copy inline (single-string edit per file) on a `claude/pr-501-fix-copy` branch and open a follow-up PR per orchestrator-fix-by-default doctrine. Sub-agent does not need to re-spin.

If operator picks Option 2: send back to executor for gate flip.

## Next action

Escalate to operator with recommendation. Do NOT auto-merge despite `Gate = auto` — the planning ambiguity is operator-decision-class.
