# PR #557 Audit — B5 Admin Access-Control + Permission-Key Completeness Sweep

**Slice:** B5 (Lane B — Features)
**Owner:** Codex
**Branch:** `codex/b5-admin-access-control`
**Base:** `master` (verified — not stacked)
**Gate:** `operator` per ledger row 58 — proxy-touching + auth role change
**Size:** 440 additions / 19 deletions / 4 files (medium)

## Verdict

**approve-pending-operator** — escalating per ledger. Auth-critical (business-timing write role narrowed) + proxy-touching + audit-honesty improvement. Pattern B fully compliant. Frozen `lib/auth/**` correctly NOT touched — the "permission-key completeness sweep" half delivers only a proposal doc and recommends a B5.b follow-up slice (same shape as B11.2 → B11.2.b).

## Pattern B compliance

**✓ FULL** — both worker self-audit (14 lenses with file:line citations) and executor independent audit (14 lenses with file:line citations) present in PR body. Codex Pattern B gold standard preserved.

## What landed

### 1. Business-timing route role split (`tool/advisor_proxy/advisor_proxy.dart:14517-14555`)

| Method | Before | After |
|---|---|---|
| `GET /v1/admin/operators/{id}/business-timing-profiles` | {super_admin, ff_support} | {super_admin, ff_support} (unchanged) |
| `POST/PUT/PATCH` writes | {super_admin, ff_support} | **{super_admin only}** |

403 error message + `required_roles` payload differentiate read denial vs write denial honestly.

### 2. Dispatcher route-ordering bug fix (`tool/advisor_proxy/advisor_proxy.dart:14931`)

`_isAdminOperatorOrLocationOperation(path, method)` now early-returns `false` when `AdminBusinessTimingRouter.matches(path, method)`. Prevents the broader operator/location matcher from swallowing `/v1/admin/operators/{id}/business-timing-profiles` BEFORE the business-timing dispatcher gets to handle it. Subtle but load-bearing fix — without this, the role split has no effect.

### 3. `admin_reason` on every HTTP operator/location mutation (`lib/admin/services/operator_location_admin_gateway.dart`)

7 mutation methods now route through `_withAdminReason()` helper:

| Method | Reason string |
|---|---|
| `createOperator()` | `admin.operator_location.onboard` |
| `patchOperator()` | `admin.operator_location.patch_operator` |
| `suspendOperator()` | `admin.operator_location.suspend` |
| `reactivateOperator()` | `admin.operator_location.reactivate` |
| `addLocation()` | `admin.operator_location.add_location` |
| `patchLocation()` | `admin.operator_location.patch_location` |
| `removeLocation()` | `admin.operator_location.remove_location` |

Pairs with the earlier server-side `admin_reason` enforcement migrations (`202605131000_admin_audit_log_actor_reason_contract.sql`, `202605131010_…`) — makes admin audit log honest end-to-end.

### 4. Catalog tri-mirror amendment — PROPOSED, NOT executed

`docs/_execution/lane_b_features/05.5_catalog_followup.md` (new, 52 LoC) records:
- `account.configure` — hand-typed in `account_screen.dart`; catalog amendment + grants + seed migration deferred
- `business_timing.configure` — hand-typed in 2 screens; same deferred
- `admin.roles.catalog_publish` — recommend NO new key (B2 can reuse `admin.roles.edit_seeded`)
- `admin.vendor_applicability.edit` — recommend NO new key (B10 stays super_admin-only)

The "Allowed files" section in the proposal doc constrains the future B5.b slice to: `docs/contracts/auth_permission_key_catalog.md` + `lib/auth/permission_keys.dart` + new additive migration + 3 screens.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, `mergeable=MERGEABLE`, `mergeStateStatus=CLEAN` |
| **Role split: GET admits super_admin+ff_support, writes super_admin-only** | ✓ — `tool/advisor_proxy/advisor_proxy.dart:14535-14555` `isReadOnly ? kAdminBusinessTimingRoles : const <String>{'super_admin'}` |
| **Dispatcher exclusion fix prevents fall-through** | ✓ — `tool/advisor_proxy/advisor_proxy.dart:14931` `if (AdminBusinessTimingRouter.matches(path, method)) return false;` |
| **Three test cases cover the role matrix** | ✓ — `test/advisor_proxy_test.dart:5991` (ff_support GET 200), `:6022` (ff_support POST 403), `:6055` (super_admin POST 201) |
| **403 error payload reports the actual gate** | ✓ — `required_roles` returns `<'super_admin'>` for writes vs the broader set for reads |
| **`admin_reason` flows through to audit sink** | ✓ — `test/advisor_proxy_test.dart:6082` `RecordingAdminBusinessTimingAuditSink` asserts the value lands in audit payload |
| **`_withAdminReason` helper is mechanical, no behavior change beyond payload key** | ✓ — diff confirms it merges `{...body, 'admin_reason': adminReason}` |
| **Frozen `lib/auth/**` NOT touched** | ✓ — diff scope: 4 files, none in `lib/auth/` |
| **No schema/migration touched** | ✓ — no `db/migrations/**` in diff |
| **No RLS policies touched** | ✓ — no policy files in diff |
| **Catalog amendment deferred to proposal doc** | ✓ — `docs/_execution/lane_b_features/05.5_catalog_followup.md` is the only doc-change; existing catalog files unchanged |
| **Pattern B both tables present** | ✓ — worker + executor 14 lenses each |
| **Worker disclosed local test runs** | ✓ — `dart analyze` clean; `flutter test --name "B5 admin business-timing"` 3/3; `admin_business_timing_routes_test.dart` 10/10; `operator_location_admin_gateway_test.dart` 29/29; `--name "11A.1"` regression 21/21. Total 63 disclosed test runs. |
| **CI-dark-window discipline** | ✓ — high-risk surface (`tool/advisor_proxy/**`); worker disclosed targeted + regression test runs on adjacent dispatcher routes (11A.1) to verify the dispatcher-exclusion fix doesn't break neighbors |
| **Cross-lane impact (B2, B10)** | ✓ — proposal doc explicitly says "prefer no new key for launch" for both, so no cross-lane blocker |
| **Baseline-snapshot doctrine** | N/A — no pre-existing master test failures invoked |
| **No tracker / ledger / lane-index touches** | ✓ — only `docs/_execution/lane_b_features/05.5_catalog_followup.md` (slice-owned) |
| **No `--no-verify` traces** | ✓ — commit message clean |

## What operator should confirm

1. **Business-timing write role narrowed**: Today, both `super_admin` and `ff_support` could mutate business-timing profiles via the admin override route. After this change, only `super_admin` can mutate; `ff_support` keeps read access for support inspection. This matches the slice's stated B5 posture ("super_admin writes, ff_support read-only"). Low risk — the admin override route is rarely used, and `ff_support` retains read.

2. **Dispatcher-ordering fix is load-bearing**: Without it, the broader operator/location matcher at `:14928-14933` would intercept `/v1/admin/operators/{id}/business-timing-profiles` before the business-timing dispatcher gets to apply the role gate. Codex caught and fixed this; the dispatcher tests at `:6055` verify the new ordering.

3. **`admin_reason` on every mutation**: paired with earlier server-side migrations, the audit log now records *why* every admin action happened, not just *who*. Operator-facing impact: clearer audit trail; no rate-limit or auth-flow change.

4. **Catalog amendment deferred (not skipped)**: B5's stated scope includes "permission-key completeness sweep" but the actual catalog amendment requires touching frozen `lib/auth/**` files. Codex correctly proposes a B5.b follow-up slice rather than touching the frozen surface in this PR. Recommend operator open the B5.b ledger row on approval (same shape as B11.2.b yesterday).

## Recommendation

**approve B5 as-is + add B5.b ledger row.**

The slice ships its concrete access-control + audit-honesty deliverables clean. The catalog half is deferred to a separately-scoped slice with explicit "Allowed files" + "Non-goals" already documented. Same pattern as B11.2/B11.2.b yesterday. Discipline preserved per CLAUDE.md L11 frozen-catalog rule.

If approved:
1. Merge PR #557.
2. Update ledger B5 → merged.
3. Add new B5.b row pointing at `docs/_execution/lane_b_features/05.5_catalog_followup.md` as the slice spec. Owner: Codex (continuation). Size: Small-Medium. Risk: Low (additive catalog + screen string-literal swap). Gate: operator (frozen `lib/auth/**` touch). Dep: B5 merged.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md:58` — B5 row, Gate=operator
- `docs/_indices/CODEX_LANE_INDEX.md:34` — Codex assignment
- `docs/_execution/lane_b_features/03_execution_slices.md:98-106` — slice spec
- `docs/_execution/lane_b_features/01_product_rule_and_ia.md:99-106` — admin posture rule
- `CLAUDE.md:41-55` — frozen `lib/auth/**` + service-layer split rules (both honored)

## Status

Awaiting operator approval.
