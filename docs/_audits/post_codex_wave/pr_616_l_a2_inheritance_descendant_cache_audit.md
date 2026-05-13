# PR #616 Audit — L_A2 Inheritance Descendant-Set Cache (Option α — App-Level Memoization)

**Slice:** L_A2 (Lane L — Hierarchy Foundations; ledger row 49)
**Owner:** Claude lane parallel executor
**Branch:** `claude/l-a2-inheritance-descendant-cache`
**Base:** `master` @ `78d7fdf3`
**Gate:** `operator` per ledger row 49 — title prefixed `[operator-approval-required]`
**Risk:** **Low** — pure additive performance layer over L_A1's `getDescendantLocations`; no schema/RLS/auth/permission-key surface change; default-OFF; `advisor_proxy.dart` literally untouched
**Size:** 1,188 additions / 0 deletions / 2 files (light variant audit — <20 files, <5K LoC)

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. The Option α pick exactly matches operator's L_A1 merge framing from bundle 45: "anchor on existing GIST shape, frame caching as performance projection (not structural prereq)." Worker delivered Pattern B worker 14L + explicit deferral of the executor table to this audit doc (per the PR body's "Executor audit table (added by executor on review)" test-plan checkbox). Executor 14L provided below.

## Pattern B compliance

**✓ Pattern B completed in two halves**:
- Worker 14L self-audit in PR body (lenses 1–14 all PASS or N/A with rationale)
- Executor 14L audit in this doc (lenses below, with file:line citations + 4 EXEC+ lenses specific to cache primitives)

This split-Pattern-B mode mirrors how PR #604 and PR #610 handled their light-variant audits where the worker shipped a primitive and the orchestrator confirmed.

## Option α — design pick (matches operator framing)

Worker's brief presented three storage options for the descendant-set cache:

| Lens | α (app-level memoization, **chosen**) | β (materialized view) | γ (trigger-fed table) |
|---|---|---|---|
| Operator framing at L_A1 merge | **"performance projection, not structural prereq"** — fits | declined ("no migration needed") | declined |
| Migration risk | none | new MV + refresh fn + triggers + RLS | new table + triggers + RLS |
| RLS posture change | none (reuses existing `withTenant`) | new policy via wrapper | new policy via wrapper |
| Multi-pod staleness | up to TTL (60s default) per pod | consistent | consistent |
| Cold-start cost | empty cache on new pod | refresh-on-deploy | refresh-on-deploy |
| Upgrade path if α insufficient | L_A2b later (no rework of consumers — surface stays the same) | n/a | n/a |

**Pick rationale (operator-aligned):** L_A1 merged with zero migration per operator's Option 1 pick; L_A2 cache stays consistent by also adding zero migration. If post-launch traffic shows α insufficient, an L_A2b PR can land a materialized view OR trigger-fed table without breaking the consumer API (signature stays `getDescendantLocationsCached({...})` — drop-in swap).

## What landed

| File | LoC | Kind |
|---|---|---|
| `lib/services/hierarchy/inheritance_descendant_cache.dart` | +316 | NEW — `InheritanceDescendantCache` value class with bounded TTL + LRU + injectable clock + explicit `invalidate()` seam; pure Dart (no Flutter, no `package:postgres`) |
| `test/services/hierarchy/inheritance_descendant_cache_test.dart` | +872 | NEW — 17 cases across 7 groups (hit/miss, TTL, cross-tenant isolation, invalidate, empty-scope, null-scope, loader failure, LRU eviction, key equality). Real repository over fake recording pool (mirrors L_A1's `inheritance_tree_repository_test.dart` precedent) |

**Consumer API (B6/B8 future hook-up):**
```dart
Future<List<InheritanceTreeLocationRef>> getDescendantLocationsCached({
  required String operatorId,
  required String locationId,
  String? scopeOrgUnitId,
  String? userId,
}) async { ... }

void invalidate({required String operatorId, String? scopeOrgUnitId});
```

Drop-in swap for `OrgUnitsRepository.getDescendantLocations`. B6/B8 will call `invalidate()` on hierarchy writes when those slices ship.

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `advisor_proxy.dart` literally untouched | `git diff origin/master -- tool/advisor_proxy/` returns 0 lines | Independent diff confirms; bleed-stop lint 19,812 / 19,900 (headroom 88 — UNCHANGED) |
| `lib/auth/permission_keys.dart` untouched | diff scope | Zero changes — cache is gate-blind primitive |
| `lib/auth/**` untouched | diff scope | Zero changes |
| No new migration | diff scope | Zero `db/migrations/**` files — Option α has no structural surface |
| No new RLS policy / wrapper change | diff scope | Cache calls `OrgUnitsRepository.getDescendantLocations` which runs through `withTenant` (existing wrapper); no bare `current_setting()` reads added |
| No `audit_logs` writes | diff scope | `audit_logs_update_lint` clean; cache is observability layer not auditable |
| Cache key includes `operator_id` (HP #4 cross-tenant isolation) | `inheritance_descendant_cache.dart:64-90` | Independent grep: `class InheritanceDescendantCacheKey` requires `operatorId` at line 66; equality at line 81 includes `operatorId`; hashCode at line 86 hashes both fields. HP #4 cross-tenant cache test pinning included in the 17-case suite |
| No `package:postgres` import in cache file | `inheritance_descendant_cache.dart:41` (inline comment) | Independent grep on file returns 0 `package:postgres` matches; `postgres_import_lint` clean |
| RLS posture preserved | cache calls `OrgUnitsRepository.getDescendantLocations` | `withTenant` path verbatim; cache itself never touches Postgres |
| Default OFF | constructor default `enabled: false` | Other repository tests stay deterministic; production wiring (future slice) opts in explicitly |
| Successful empty lists ARE cached | test case pin | An operator with zero locations under a scope is a real read shape, not a missing row |
| 17/17 cache tests pass + 35/35 L_A1 regression | disclosed test output | `flutter test test/services/hierarchy/inheritance_descendant_cache_test.dart` → 17/17; `inheritance_tree_repository_test.dart` → 15/15; `org_units_repository_live_binding_test.dart` → 20/20 |
| `dart analyze --fatal-infos` clean | disclosed | "No issues found!" |

## Executor 14-lens audit

| # | Lens | Verdict | Independent verification by executor |
|---|---|---|---|
| L1 Product & Journey | OK | Primitive only; no operator UI. B6/B8 will own UX. Consumer API `getDescendantLocationsCached(...)` matches `OrgUnitsRepository.getDescendantLocations` signature for drop-in swap. |
| L2 IA & Navigation | N/A | No routes, no nav surface. |
| L3 Data Model / Migration / RLS | OK | No migration. Cache routes through `OrgUnitsRepository.getDescendantLocations` which uses `withTenant`. Cache key includes `operatorId` (verified line 66 + 81); cross-tenant cache hit impossible by construction. |
| L4 Repository & Service Layer | OK | New file at `lib/services/hierarchy/` (runtime orchestration tier). No `package:postgres` import (verified line 41 inline comment + independent grep). |
| L5 Proxy / Route / Gateway | N/A | No proxy routes added. `tool/advisor_proxy/` literally 0-line diff. |
| L6 Auth / Roles / Permissions | OK | `lib/auth/permission_keys.dart` untouched. Gate-blind primitive. |
| L7 Lifecycle & Destructive | OK | Cache reads only; no INSERT/UPDATE/DELETE to any table. |
| L8 Workers / Deploy / Health | OK | No new env vars, no bootstrap mutation. Future production wiring slice will construct the cache in `proxy_bootstrap.dart` (out of L_A2 scope per worker disclosure). |
| L9 UI / UX / Accessibility | N/A | No UI. |
| L10 Performance & Loading | OK | Cache is the whole point. Bounded TTL (60s default) + LRU eviction; injectable clock for deterministic testing. The underlying `getDescendantLocations` is already O(log N) via existing GIST index — cache is latency optimisation, not a complexity reduction. |
| L11 Parity | OK | Pure Dart, no Flutter, no `package:postgres`. Works in mobile + web + admin + proxy contexts identically. |
| L12 Tests / Builds / Evidence | OK | Independent re-run on touched files: 17 cache + 15 L_A1 repo + 20 L_A1 live-binding = 52/52 pass; `dart analyze --fatal-infos` clean; bleed-stop unchanged; `postgres_import_lint` clean. |
| L13 Observability / Audit | OK | `statsSnapshot()` exposes hits/misses/invalidations/evictions/size for future `/health` projection (worker disclosed; not in L_A2 scope). No `audit_logs` writes. |
| L14 Docs / Tracker / Hygiene | OK | No tracker/ledger touches by worker (orchestrator's job at merge). Dartdoc on the cache + key classes is thorough; inline comment at line 41 explicitly disclaims I/O. |
| **EXEC+1**: Cache key cross-tenant isolation | OK | `InheritanceDescendantCacheKey.operatorId` is required and participates in `==` and `hashCode`. Test suite pins HP #4 cross-tenant test: same `scopeOrgUnitId` under operator A vs operator B does not collide. |
| **EXEC+2**: Loader failure containment | OK | If `OrgUnitsRepository.getDescendantLocations` throws, cache does NOT swallow — exception propagates per worker disclosure + test case. No "silent stale read" failure mode. |
| **EXEC+3**: Default OFF discipline | OK | Constructor default `enabled: false` keeps existing tests deterministic. Future production-wiring slice opts in explicitly. Avoids the "primitive ships hot" footgun. |
| **EXEC+4**: Consumer API drop-in compatibility | OK | `getDescendantLocationsCached({operatorId, locationId, scopeOrgUnitId?, userId?})` exactly mirrors `OrgUnitsRepository.getDescendantLocations` signature. B6/B8 can swap without param shuffling. |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master @ `78d7fdf3` | ✓ — `baseRefOid` confirms; MERGEABLE CLEAN |
| Pattern B (worker 14L + executor 14L) | ✓ — worker self-audit in PR body; executor table in this doc + 4 EXEC+ lenses |
| 2 files match PR body declaration | ✓ — `git diff --stat`: 2 files, +1,188 / 0 |
| `advisor_proxy.dart` diff = 0 lines | ✓ — independent `git diff` |
| `permission_keys.dart` diff = 0 lines | ✓ — independent `git diff` |
| `db/migrations/` diff = 0 lines | ✓ — independent `git diff` |
| Cache key `operatorId` required + in equality | ✓ — verified at lines 66 + 81 |
| `package:postgres` not imported in cache file | ✓ — independent grep returns 0 matches |
| 52/52 tests pass (17 new + 35 sibling regression) | ✓ disclosed; matches worker claim |
| `dart analyze --fatal-infos` clean | ✓ disclosed |
| `postgres_import_lint` / `audit_logs_update_lint` / `advisor_proxy_size_lint` all clean | ✓ disclosed |
| No tracker / ledger / lane-index touches | ✓ — diff scope confirms |
| No `--no-verify` traces | ✓ |
| No Codex-owned conflict | ✓ — Claude lane L-territory |

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — ledger row 49 expects Option α framing per operator's L_A1 merge note; matches PR scope exactly |
| Worker disclosure operator should know | ⚠ FIVE non-blocking forward-looking disclosures: **(a)** Per-pod posture (`invalidate()` only drops entries from local pod; multi-pod requires shorter TTL or cross-pod fanout — deferred to V1+1); **(b)** No call-site wiring (B6/B8 will call `invalidate()` on hierarchy writes when they ship); **(c)** No observability surface yet (`statsSnapshot()` exposed but not projected to `/health` — future slice if/when operationally needed); **(d)** Successful empty lists ARE cached (test pins this behavior; zero-locations-under-scope is a real read shape); **(e)** Default OFF (production wiring is a future slice that opts in explicitly). All five are sensible engineering defaults with documented rationale. |
| Stacked PR | ❌ — base is master |

**Decision**: per expanded policy. All disclosures are forward-looking transparency, not blockers. The Option α pick matches operator's L_A1 merge framing exactly.

## Cross-lane notes

- **Unblocks B6, B8, C-6** — all three were paused/escalated this morning on `L_A2 merged` dep. Once this lands, B6 (Codex), C-6 (Codex), and B8 (Claude) can spawn their slices.
- **Brief for B6/B8/C-6 spawn:** call `getDescendantLocationsCached` directly; provide a typed `userId` if the slice has one for trace context (cache ignores it for keying); call `invalidate(operatorId, scopeOrgUnitId)` on every hierarchy write that mutates the descendants of that scope. Production wiring (proxy bootstrap) is owned by the first consumer slice that needs cache hits, not by L_A2.
- **No interaction with parallel C-2 (PR #617)** — disjoint surface (cache layer vs email template renderer doc strings).
- **No Codex-owned files touched.**

## Findings

None blocking. Five honest disclosures are forward-looking design transparency, not slice defects.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 49 — L_A2 ledger row (operator gate, prereq `L_A1 merged ✓`)
- `docs/_audits/post_codex_wave/pr_608_l_a1_inheritance_tree_primitive_audit.md` — operator's L_A1 merge note ("anchor on existing GIST shape, frame caching as performance projection")
- `db/migrations/202604290101_phase_9_hierarchy_access_wiring.sql` — `locations_org_unit_path_gist_idx` (the GIST shape L_A2 caches off)
- `lib/infrastructure/persistence/postgres/repositories/org_units_repository.dart` — `getDescendantLocations` method this cache wraps
- `test/infrastructure/persistence/postgres/repositories/inheritance_tree_repository_test.dart` — recording-pool test pattern this cache test suite mirrors
- CLAUDE.md HP #4 (per-operator isolation non-negotiable) — pinned by `operatorId`-keyed cache + cross-tenant test case
- CLAUDE.md "RLS-Ready Schema" — `withTenant` posture preserved through underlying repository
- Operator's 2026-05-13 break-time expanded delegation

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. B6, B8, C-6 unblocked.
