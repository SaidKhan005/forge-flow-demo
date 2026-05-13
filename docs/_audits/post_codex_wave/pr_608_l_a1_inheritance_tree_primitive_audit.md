# PR #608 Audit — L_A1 Inheritance Tree Primitive

**Slice:** L_A1 (Lane L — critical-path unblocker for B6, B8, C-6, B2.4 family)
**Owner:** Claude lane parallel executor
**Branch:** `claude/l-a1-inheritance-tree-primitive`
**Base:** `master` @ `0a6311cb`
**Gate:** `operator` per ledger row 48 — title prefixed `[operator-approval-required]`
**Risk:** **Low-Medium** — foundation primitive; read-only repository extension + shared visualization widget + value class; no auth/RLS/permission-key surface change
**Size:** 1,901 additions / 0 deletions / 5 files (light variant audit — <20 files, <5K LoC)

## Verdict

**approve-for-merge with operator approval (received 2026-05-13)** — operator picked Option 1 ("approve + merge as-is, no migration needed") after orchestrator surfaced the worker/executor-flagged no-migration question. Pattern B exemplary (worker 14L + executor 14L + 3 EXEC+ lenses on selector-vs-visualization discipline / depth-math reconciliation / soft-deleted-ancestor predicate consistency). Foundation primitive unblocks B6, B8, C-6 immediately.

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables present in PR body with file:line citations; executor adds 3 executor-only lenses focused on the visualization-not-selector boundary, depth-math reconciliation between two code paths, and consistent soft-deleted-ancestor predicates across new + existing methods.

## Operator decision — no-migration framing

**Resolved 2026-05-13 by operator pick of Option 1.**

Ledger row 48 phrased L_A1 as "setting up the `descendant_path` denormalization that L_A2 will cache" with "migration is additive expand." PR ships **no migration**.

**Worker's verified rationale** (executor confirmed independently):
- L_A2 will cache `(operator_id, scope_id) → descendant_location_ids[]`.
- That set is computable today from existing schema: `SELECT location_id FROM locations WHERE org_unit_path <@ (SELECT path FROM org_units WHERE id = $scope_id)`.
- The `locations_org_unit_path_gist_idx` GIST index from `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql` makes that lookup a single-index scan.
- L_A2 is therefore a **performance denormalization** (materialized view / trigger-fed table / app-level memoization) projecting off the same ltree shape — a storage-shape choice that doesn't require L_A1 to lay structural groundwork.

**Operator's read:** the ledger's "denormalization" was shorthand for the existing ltree+GIST shape — already paid for by Phase 9. L_A2 can cache off that without L_A1 needing to add a column.

**Trailing risk (acknowledged):** if L_A2's worker later determines a precomputed table or counter column is required for performance reasons, L_A1b would be queued at that point. No live data + no benchmark gap today means this is the lower-risk path.

## What landed

| File | LoC | Kind |
|---|---|---|
| `lib/domain/models/inheritance_tree_node.dart` | +189 | NEW value class (pure Dart — no Flutter, no `package:postgres`) |
| `lib/widgets/inheritance_tree.dart` | +320 | NEW shared visualization widget (caller-supplied `annotationBuilder`; **visualization, not selector**) |
| `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart` | +380 | EXTEND — 3 new read methods + `_assembleTree` static helper + `InheritanceTreeLocationRef` projection class |
| `test/widgets/inheritance_tree_test.dart` | +347 | NEW — 10 widget cases |
| `test/infrastructure/persistence/postgres/repositories/inheritance_tree_repository_test.dart` | +665 | NEW — 15 repository cases |

**3 new operator-scoped read methods** on the existing `OrgUnitsRepository` (which already `extends OperatorScopedRepository`):
- `getOrgUnitTreeForOperator` — full hierarchy as a single assembled `InheritanceTreeNode?` (2 `withTenant` reads in one transaction → O(N+M) Dart stitch)
- `getDescendantLocations` — single ltree predicate `org_unit_path <@ scope.path` backed by existing GIST index
- `getNodeForLocation` — single-leaf shortcut

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| No migration | diff scope | Zero `db/migrations/**` files in diff — operator-resolved no-migration question above |
| No new permission key | diff scope | Zero `lib/auth/**` files in diff — gate-blind primitive |
| Frozen `lib/auth/**` untouched | diff scope | Zero changes |
| Operator-scoped repo extension routes through `withTenant` | new methods | Each new method wrapped in `withTenant<...>(ctx, (exec) async { ... })` — no bare `current_setting`; no `withSystem` introduced by new code |
| Visualization-not-selector discipline | `lib/widgets/inheritance_tree.dart` | No selection state, no mutate buttons, no checkboxes. Annotation slot is read-only `Widget Function(BuildContext, InheritanceTreeNode)`. Existing selector at `lib/operator_web/widgets/org_unit_tree_view.dart` UNCHANGED |
| `advisor_proxy.dart` untouched | size lint | Bleed-stop reports 19,805 / 19,900 (headroom 95) — identical to pre-PR |
| `postgres_import_lint` clean | tool output | Widget imports only `flutter/material.dart`, value class, `app_theme.dart`. No layer-boundary violations |
| All new SQL is read-only | repository extension | `select` only; `audit_logs_update_lint` clean |
| Depth math reconciles between paths | `_buildOrgUnitNode` (depth=parent_depth+1 from depth=0 root) and `getNodeForLocation` (depth=`nlevel(org_unit_path)`) | Verified by executor: root nlevel=1 and root tree-depth=0, so leaf at parent nlevel=k has tree-depth=k in both paths. No off-by-one |
| Soft-deleted-ancestor predicate consistency | `getOrgUnitTreeForOperator`, `getDescendantLocations`, pre-existing `listLocationsForTenant` | All use the same `NOT EXISTS` deleted-ancestor predicate |
| Value class metadata slot is forward-compatible | `inheritance_tree_node.dart` | Open `metadata` slot so L_A2 can stash cache projections, B6/B8 can stash effective-value fields without forcing a value-class break |
| 25/25 new tests pass | test files | `flutter test test/widgets/inheritance_tree_test.dart test/infrastructure/persistence/postgres/repositories/inheritance_tree_repository_test.dart` → 25/25 |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `0a6311cb` | ✓ — `baseRefOid` confirms; MERGEABLE CLEAN |
| Pattern B both tables present + 3 executor-only lenses | ✓ — worker 14L + executor 14L + 3 EXEC+ lenses |
| Operator approval received | ✓ — operator picked Option 1 (no-migration interpretation accepted) |
| `dart analyze --fatal-infos` clean | ✓ disclosed ("No issues found!") |
| `postgres_import_lint` clean | ✓ disclosed |
| `audit_logs_update_lint` clean | ✓ disclosed |
| `advisor_proxy_size_lint` unchanged | ✓ — 19,805 / 19,900 (headroom 95) |
| No tracker / ledger / lane-index touches | ✓ — diff scope confirms |
| No `--no-verify` traces | ✓ |
| No Codex-owned conflict | ✓ — Claude lane L-territory |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ⚠ RESOLVED — operator-pick Option 1 closes the no-migration question. L_A1b queued conditionally based on L_A2 worker's cache-design needs |
| Worker disclosure operator should know | ⚠ RESOLVED — operator was surfaced the no-migration question + picked Option 1 |
| Stacked PR | ❌ — base is master |

**Decision**: operator-approved merge per Option 1 pick. Trailing risk acknowledged + documented; L_A1b will queue only if L_A2's worker finds the existing ltree+GIST insufficient.

## Cross-lane notes

- **Unblocks B6, B8, C-6** — all three were paused/escalated by Codex's idle report this morning pending L_A1 + L_A2 merges. L_A1 merging here unblocks the L_A2 spawn.
- **L_A2 brief should reflect** "cache off existing ltree" rather than "cache off L_A1's new column" — orchestrator note for the next prompt.
- **B2.4 (PR #609) already merged this morning** — disjoint surface; no overlap with L_A1.
- **No Codex-owned files touched** — L territory is Claude lane.

## Findings

None blocking. The no-migration question was operator-resolved by Option 1 pick.

**Orchestrator note for L_A2 brief:** when spawning the L_A2 worker, the brief should anchor on the existing `locations.org_unit_path` GIST shape from `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql` and frame L_A2's caching choice as a performance-driven projection off that shape, not a structural prerequisite.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 48 — L_A1 ledger row (operator gate)
- `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql` — existing GIST index L_A2 will cache off
- `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart` (pre-existing) — `extends OperatorScopedRepository`; this PR extends it
- CLAUDE.md "RLS-Ready Schema" — operator-scoped reads via `withTenant`
- CLAUDE.md HP #11 — hierarchy-scoped settings (L_A1 is the visualization primitive Hard Promise #11 needs)
- Operator's 2026-05-13 break-time pick — Option 1 (approve + merge as-is)

## Status

**Merging now** per operator approval. L_A2 next in queue with no-migration framing.
