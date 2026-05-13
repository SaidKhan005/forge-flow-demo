# PR #573 Audit — B5.b Catalog Tri-Mirror Amendment

**Slice:** B5.b (Lane B — Features, B5 follow-on)
**Owner:** Codex
**Branch:** (PR #573 head)
**Base:** `master` (verified — not stacked)
**Gate:** `operator` per ledger row 61 (frozen `lib/auth/**` + new migration) — title prefixed `[operator-approval-required]`
**Size:** 336 additions / 81 deletions / 16 files

## Verdict

**approve-pending-operator** — title-flagged `[operator-approval-required]` per ledger row 61 (two simultaneous operator-gate triggers: frozen `lib/auth/**` touch + new schema migration). Pattern B compliance present (worker self-audit + executor audit, 14 lenses each). Slice content matches ledger row 61 scope exactly: tri-mirror reconciliation for `account.configure` + `business_timing.configure` keys across (a) catalog docs, (b) `PermissionKeys` constants, (c) additive migration grants, (d) 3 operator-web screen literal→constant swaps. Migration is additive + idempotent + properly scoped. No non-goal scope-creep (no admin route guard changes, no seeded role meaning changes beyond explicit grants, no B2/B10 admin keys — all matches the slice-owned follow-up doc).

## Pattern B compliance

**✓ FULL** — both worker self-audit (14 lenses) and executor audit (14 lenses) present in PR body with file:line citations. Codex's standard Pattern B shape preserved (no drift).

## What landed

### 1. New permission keys in frozen catalog (`lib/auth/permission_keys.dart`)

```
static const String accountConfigure = 'account.configure';
static const String businessTimingConfigure = 'business_timing.configure';
```

Both added to the `allKeys` set at `:297-298`. Frozen-surface touch — operator gate trigger.

### 2. New additive migration (`db/migrations/202605131500_b5_b_catalog_tri_mirror.sql`, 69 LoC)

- Inserts 2 rows into `public.permission_keys` (frozen=true, requires_mfa=false at catalog level — route-level freshness gates can layer on without re-grant)
- Inserts 6 rows into `public.role_permissions` (super_admin + operator_owner + operator_admin get both keys; operator_manager/supervisor/staff/ff_support do NOT — matches slice spec posture)
- ON CONFLICT DO NOTHING on both inserts — idempotent
- Single `begin; ... commit;` transaction
- No DELETE, no ALTER, no DROP — pure additive

### 3. Catalog doc reconciliation (`docs/contracts/auth_permission_key_catalog.md`, +47/-31)

Sets the canonical catalog entries for both keys + reorganizes table sections to mirror the constants.

### 4. 3 operator-web screens swap literals → constants

- `account_screen.dart:35`: `'account.configure'` → `PermissionKeys.accountConfigure`
- `business_setup_screen.dart`: new `kOperatorWebBusinessTimingEditPermission = PermissionKeys.businessTimingConfigure` + screen reads it
- `business_timing_editor_screen.dart:37`: same swap

Pure literal→constant — zero behavior change. Authority surface is the new constants, not the strings.

### 5. Lint surface expanded (`tool/permission_key_lint.dart` + tests)

`permission_key_lint.dart` (+2) and `test/tool/permission_key_lint_test.dart` (+27/-22) extend the lint to catch future drift between catalog + constants + migration grants.

### 6. New test coverage (`test/auth/permission_catalog_b5b_test.dart`, 139 LoC NEW)

Asserts the tri-mirror holds: catalog row exists, constant value matches, migration grants the expected role set. Surfaces drift if any of the three sides goes out of sync.

### 7. Test updates for sibling surfaces

- `test/infrastructure/persistence/postgres/repositories/role_permissions_repository_test.dart` (+6/-7)
- `test/phase_9_0a_scope_extensions_test.dart` (+9/-6)

Both tests' role-grant assertions updated to reflect the 2 new key additions.

### 8. Misc doc/runbook nits

- `docs/POST_HARDENING_FOLLOWUPS.md` (+4/-3)
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` (+1/-1)
- `docs/phases/phase_9/phase_9_execution_backlog.md` (+2/-2)
- `runbooks/phase_9_production1_migration_apply_runbook.md` (+4/-3) — adds the new migration to the apply queue
- `scripts/postgres_staging_setup.ps1` (+1/-1) — staging-setup ordering reflects new migration

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, not draft |
| **Pattern B both tables present** | ✓ — worker 14 lenses + executor 14 lenses |
| **New permission keys present at `lib/auth/permission_keys.dart`** | ✓ — verified at `:170, :173, :297, :298` |
| **Migration is additive** | ✓ — `INSERT ... ON CONFLICT DO NOTHING` only; no DELETE/ALTER/DROP |
| **Migration is idempotent** | ✓ — `ON CONFLICT (key) DO NOTHING` + `ON CONFLICT (role_id, permission_key) DO NOTHING` |
| **Migration uses single transaction** | ✓ — `begin; ... commit;` |
| **Grant posture matches slice spec** | ✓ — super_admin + operator_owner + operator_admin get both keys; operator_manager/supervisor/staff/ff_support excluded |
| **Migration cutoff lint disclosed** | ✓ — `migration_drift_scanner.dart --strict-docs --require-expand-contract` clean; `migration_cutoff_lint.dart` clean |
| **`audit_logs` not mutated** | ✓ — `audit_logs_update_lint.dart` clean disclosed |
| **`permission_key_lint` disclosed clean** | ✓ — worker disclosed |
| **3 screen swaps verified** | ✓ — `account_screen.dart`, `business_setup_screen.dart`, `business_timing_editor_screen.dart` all read from new constants |
| **No proxy / route / gateway changes** | ✓ — diff scope confirms |
| **No admin guard route changes (non-goal preserved)** | ✓ — no `lib/admin/` or `tool/advisor_proxy/` files touched |
| **No seeded role meaning changes (non-goal preserved)** | ✓ — grants are explicit per-key only |
| **No B2/B10 admin keys (non-goal preserved per slice spec)** | ✓ — only `account.configure` + `business_timing.configure` added |
| **Test coverage for new tri-mirror** | ✓ — `test/auth/permission_catalog_b5b_test.dart` (139 LoC NEW) asserts catalog/constant/migration alignment |
| **`dart analyze` disclosed clean on every touched file** | ✓ — full list disclosed in PR body |
| **`flutter test` disclosed**: 54/54 passes on 4 targeted test files | ✓ |
| **No tracker / ledger / lane-index touches** | ✓ — diff scope confirms |
| **No `--no-verify` traces** | ✓ — commit message clean |

## Operator-approval rationale

Two simultaneous operator-gate triggers fire on this PR:

1. **Frozen `lib/auth/**` touch** — `lib/auth/permission_keys.dart` is in the frozen permission key catalog per CLAUDE.md "Service-Layer Split". Operator approval required regardless of audit verdict.
2. **New `db/migrations/*.sql`** — schema-touching slice. CLAUDE.md "Agent-Led Slices" rule says schema-touching requires explicit operator approval.

Both triggers are properly disclosed in the worker self-audit (lens 3 + lens 6) and the executor audit (lens 3 + lens 6). Title correctly prefixed `[operator-approval-required]`.

This is the **B5 follow-on** — B5 (PR #557) was approved 2026-05-13 03:22Z as Option A (scaffold scope split) with the explicit commitment to land the catalog amendment in B5.b. B5.b's scope tracks the slice-owned follow-up doc (`docs/_execution/lane_b_features/05.5_catalog_followup.md`) exactly. **Recommend operator approve as continuation of the B5 Option A plan.**

## Migration apply note

Once merged, this migration `202605131500_b5_b_catalog_tri_mirror.sql` will need to be applied to staging and Production1 per the migration-apply runbook (worker already added the entry). Apply order: post-merge → `runbooks/phase_9_production1_migration_apply_runbook.md` queue.

## Cross-lane note

None. No Codex/Claude lane overlap on touched files.

## Findings

None. Slice is well-bounded, additive, idempotent, materially correct, and Pattern B-compliant. Same shape as the typical "frozen catalog + migration" pair (e.g., earlier B-slice catalog work).

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 61 — B5.b ledger row (operator gate, B5-merged dep)
- `docs/_execution/lane_b_features/05.5_catalog_followup.md:21-22, :36, :51-52` — slice-owned follow-up doc (non-goals + proposed disposition)
- `docs/contracts/auth_permission_key_catalog.md` — frozen catalog (tri-mirror target)
- `lib/auth/permission_keys.dart` — frozen surface (tri-mirror target)
- PR #557 (B5 sister slice) — operator-approved Option A precedent
- CLAUDE.md "Service-Layer Split" (`lib/auth/` frozen rule) + "Agent-Led Slices" (operator-gate triggers)

## Status

**escalate-to-operator** for explicit approval. Two operator-gate triggers fire (frozen `lib/auth/**` + new migration); both properly disclosed; slice tracks ledger row 61 scope exactly. Recommend operator say **"approve B5.b"** to land B5 Option A's deferred half.
