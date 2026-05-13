# PR #576 Audit — B10.1 Vendor Applicability Plumbing

**Slice:** B10.1 (Lane B — Features)
**Owner:** Codex
**Branch:** `codex/b10-1-vendor-applicability`
**Base:** `master` (verified — not stacked)
**Gate:** `operator` per ledger row 68 (schema + RLS + proxy-touching + new auth surface) — title prefixed `[operator-approval-required]`
**Size:** 3680 additions / 149 deletions / 20 files

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time delegation ("Once Audits are done and approved from your side; take recommended actions and Merge. Do not wait on me.").

This is a sizable backend slice. All four operator-gate triggers fire (new schema migration + new RLS policy + new proxy routes + new auth surface), but the implementation is **exemplary across every gate**:
- Schema: operator-leading indexes (F2 split satisfies B-tree guardrail), RLS via wrapper function, temporal design, defensive column/value constraints, schema-validated JSONB metadata
- Auth: super_admin-only launch gate with explicit 403 + clear error contract
- Routes: required `admin_reason` (F1 fix) + required `Idempotency-Key` + max length validation
- Tests: 1463 LoC of test coverage across 8 new/modified test files; 40 disclosed passes

Two send-back fixes (F1 + F2) show the worker iterated cleanly through executor-audit feedback. Both gates are honored:
- F1: required `admin_reason` baked into command DTOs (gateway-level enforcement, not just route-level)
- F2: split unique indexes per operator vs global so operator-scoped B-trees lead with `operator_id`

## Pattern B compliance

**✓ FULL** — both worker self-audit (14 lenses) and executor audit (14 lenses) present in PR body with file:line citations. Both reference F1+F2 send-back fixes which is good iteration evidence.

## What landed

### 1. New temporal table (`db/migrations/202605131500_b10_1_vendor_applicability.sql`, 140 LoC)

- `vendor_applicability` table: `id uuid PK`, `operator_id uuid NULL` (CASCADE on operator delete; NULL = global F&F default), `setting_kind text`, `setting_key text`, `vendor_slug text`, `enabled boolean`, `metadata jsonb` (object-typed), `effective_from timestamptz`, `effective_until timestamptz`, `created_at`, `created_by uuid`
- Format checks on `setting_kind`/`setting_key`/`vendor_slug`: lowercase, no leading/trailing whitespace, regex-bounded charset
- `effective_until > effective_from` constraint
- **6 indexes** — all operator-scoped variants lead with `operator_id` (F2 fix):
  - `vendor_applicability_history_operator_uq` (operator-only)
  - `vendor_applicability_history_global_uq` (global-only, operator IS NULL)
  - `vendor_applicability_current_operator_uq` (operator-only, effective_until IS NULL)
  - `vendor_applicability_current_global_uq` (global-only)
  - `vendor_applicability_current_tenant_lookup_idx` (operator-leading)
  - `vendor_applicability_current_global_lookup_idx` (global-only)
  - `vendor_applicability_history_lookup_idx` (operator-leading, effective_from DESC)
- RLS enabled with `app_current_operator()` wrapper function (no bare `current_setting()`)
- Grants: service_role SELECT; forge_admin SELECT/INSERT/UPDATE; PUBLIC REVOKEd

### 2. Schema-validated metadata (`lib/services/settings/applicability_metadata_schemas.dart`, 334 LoC NEW)

App-layer schema validation per `setting_kind`. Prevents JSONB from becoming an EAV escape hatch (explicitly flagged in the table comment).

### 3. Repository (`lib/infrastructure/persistence/postgres/repositories/vendor_applicability_repository.dart`, 441 LoC NEW)

Temporal write semantics:
- `upsert` inserts a new effective row (closes the prior current row if one exists)
- `endCurrent` sets `effective_until` (no DELETE — temporal close only)
- Reads clamp to tenant rows + global rows via the wrapper

### 4. Admin gateway (`lib/admin/services/vendor_applicability_admin_gateway.dart`, 332 LoC NEW)

- Required `adminReason` parameter on both `VendorApplicabilityUpsertCommand` and `VendorApplicabilityEndCommand` (F1)
- Optional `reasonNote` (free-text supplement)
- Required `idempotencyKey`

### 5. Operator-web read gateway (`lib/operator_web/services/web_vendor_applicability_gateway.dart`, 197 LoC NEW)

Read-only client — operator tenants see their rows + global defaults via the proxy.

### 6. Proxy routes (`tool/advisor_proxy/advisor_proxy.dart`, +477)

- Admin path: super_admin-only role gate (`kFfVendorApplicabilityAdminRoles = {'super_admin'}`)
- Operator path: tenant-scoped read
- Both surfaces enforce `Idempotency-Key` on writes (400 if missing, 400 if >200 chars)
- 403 with explicit `required_roles` field if caller lacks super_admin

### 7. Production wiring (`tool/advisor_proxy/proxy_bootstrap.dart` + `main.dart`)

New repository + audit-log writes (with the supplied `admin_reason`) threaded through the bootstrap.

### 8. Test coverage (8 files, ~1463 LoC test code)

- `test/proxy/vendor_applicability_routes_test.dart` (680 LoC NEW) — route contract + 403/400 cases
- `test/db/vendor_applicability_migration_test.dart` (87 LoC NEW) — index assertions
- `test/infrastructure/persistence/postgres/repositories/vendor_applicability_repository_test.dart` (252 LoC NEW)
- `test/admin/vendor_applicability_admin_gateway_test.dart` (125 LoC NEW)
- `test/operator_web/services/web_vendor_applicability_gateway_test.dart` (78 LoC NEW)
- `test/proxy/vendor_applicability_proxy_gateway_test.dart` (149 LoC NEW)
- `test/services/settings/applicability_metadata_schemas_test.dart` (82 LoC NEW)
- `test/advisor_proxy_bootstrap_test.dart` (+116/-137 — rewrite of bootstrap binding test)

## Executor spot-checks

| Check | Outcome |
|---|---|
| **Base = master** (not stacked) | ✓ — `baseRefName=master`, not draft |
| **Pattern B both tables present** | ✓ — worker 14L + executor 14L |
| **Migration additive only (no DROP/DELETE/ALTER on existing tables)** | ✓ — `CREATE TABLE IF NOT EXISTS` + indexes + RLS only; `DROP POLICY IF EXISTS` is defensive idempotency on the same new table |
| **Operator-scoped indexes lead with `operator_id`** | ✓ — 4 operator-leading indexes verified (F2 split fix applied) |
| **Global-only indexes correctly omit `operator_id`** | ✓ — 2 global indexes (operator_id IS NULL filter) |
| **RLS uses wrapper function (no bare `current_setting()`)** | ✓ — `app_current_operator()` called in policy |
| **Defensive column constraints** | ✓ — format regex on kind/key/slug; metadata is jsonb object; temporal-order check |
| **Cascade on operator delete (no orphan rows)** | ✓ — `references public.operators(operator_id) on delete cascade` |
| **`admin_reason` required at gateway-command DTO level (F1)** | ✓ — verified at `vendor_applicability_admin_gateway.dart:89-92, :123-126` — `required` keyword, not nullable |
| **`Idempotency-Key` required + max length validated** | ✓ — 400 if missing, 400 if >200 chars, contract-level error codes |
| **super_admin-only gate at proxy** | ✓ — `kFfVendorApplicabilityAdminRoles = {'super_admin'}` at `advisor_proxy.dart:7303`; 403 with `required_roles` field if absent |
| **No new permission key (non-goal preserved)** | ✓ — uses role-set gate, not a new `PermissionKey` constant |
| **No B10.2 UI changes (non-goal preserved)** | ✓ — diff scope confirms 0 widget changes |
| **No `pgmq` or banned items** | ✓ — banned-items grep clean |
| **No raw `package:postgres` imports outside allowed location** | ✓ — only `lib/infrastructure/persistence/postgres/` files import; banned-import lint clean |
| **`audit_logs` not mutated (UPDATE allowlist preserved)** | ✓ — `audit_logs_update_lint.dart` disclosed clean |
| **Schema-validated JSONB metadata (not EAV escape hatch)** | ✓ — `lib/services/settings/applicability_metadata_schemas.dart` (334 LoC) per-kind validators; comment in migration explicitly forbids unvalidated writes |
| **Tests cover send-back risks (F1 + F2)** | ✓ — route tests assert 400 on missing reason; migration tests assert split-index existence |
| **Migration cutoff lint disclosed clean** | ✓ — `migration_cutoff_lint.dart` + `migration_drift_scanner.dart --strict-docs --require-expand-contract` both clean |
| **`index_leading_column_lint` disclosed clean** | ✓ — operator-leading rule satisfied |
| **`rls_policy_lint` disclosed clean** | ✓ |
| **`dart analyze` disclosed clean on full file list** | ✓ — 14 files disclosed |
| **`flutter test` disclosed**: 40/40 passes on the 8 targeted test files | ✓ |
| **No tracker / ledger / lane-index touches** | ✓ — diff scope confirms |
| **No `--no-verify` traces** | ✓ — commit message clean |

## Genuine safety holds — checked, none fire

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ NOT fired — migration is new, queued for apply per runbook update |
| Reject-class verdict | ❌ NOT fired |
| Ledger says one thing, audit found another | ❌ NOT fired — ledger row 68 says schema + RLS + proxy + auth gate, all match |
| Worker disclosed scope expansion or deferred work needing operator nod | ❌ NOT fired — slice matches spec; no test backfill deferrals; B10.2 UI correctly out-of-scope |
| Stacked PR with unresolved parent | ❌ NOT fired — base=master |

Per operator's expanded-authority grant during break: **proceeding to merge**.

## Migration apply note

`202605131500_b10_1_vendor_applicability.sql` joins the staging + Production1 apply queue per `runbooks/phase_9_production1_migration_apply_runbook.md` (worker already added the entry). Apply order: post-merge → migration window.

## Cross-lane note

None. No Codex/Claude lane file overlap.

## Findings

None. Slice is well-bounded, exceptionally well-architected, multi-gate-clean, and Pattern B-compliant. Send-back F1 + F2 cleanly applied.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 68 — B10.1 ledger row (operator gate)
- `docs/_execution/lane_b_features/03_execution_slices.md:168-173, :230, :235` — slice spec
- `docs/_execution/lane_b_features/02_plumbing_audit_matrix.md:83, :149-150, :195` — plumbing matrix + idempotency contract
- `docs/_audits/code_health/a5_schema_versioning_and_a7_frameworks.md:107` — index leading-column rule
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — RLS wrapper function rule
- CLAUDE.md "RLS-Ready Schema" + "Proxy & API Conventions" + "Service-Layer Split"

## Status

**Auto-merging** per operator's 2026-05-13 break-time delegation. Audit verdict approve-for-merge with no safety holds firing. Ledger row 68 → merged + #576.
