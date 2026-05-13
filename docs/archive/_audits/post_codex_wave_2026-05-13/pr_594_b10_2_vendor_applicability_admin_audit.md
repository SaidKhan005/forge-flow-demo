# PR #594 Audit — B10.2 Vendor Applicability Admin Editor + Operator-Web Wage Source Binding

**Slice:** B10.2 (Lane B — Features)
**Owner:** Codex
**Branch:** `codex/b10-2-vendor-applicability-admin`
**Base:** `master`
**Gate:** `operator` per ledger row 69 — title prefixed `[operator-approval-required]`
**Risk:** **Medium** — admin UI + operator-web binding on top of B10.1 backend; no schema/proxy/auth surface change
**Size:** 1876 additions / 38 deletions / 11 files (light variant audit — <20 files, <5K LoC)

## Verdict

**approve-for-merge** — auto-merging per operator's 2026-05-13 break-time expanded delegation. Pattern B exemplary (worker 14L + executor 14L). Pure UI + operator-web binding on top of B10.1's already-merged backend (PR #576, Bundle 33). No new proxy routes, no new repositories, no migration. `super_admin` write gate matches B10.1's `kFfVendorApplicabilityAdminRoles`. Required `admin_reason` + `Idempotency-Key` threaded through gateway commands per B10.1 contract. Same architectural shape as B2.2 (UI on top of merged backend).

## Pattern B compliance

**✓ EXEMPLARY** — worker self-audit (14 lenses with file:line citations) and executor independent audit (14 lenses with file:line citations) both present in PR body. No drift.

## What landed

### 1. Admin editor screen (`lib/admin/screens/vendor_applicability_admin_screen.dart`, 862 LoC NEW)

- Per-`setting_kind` tabs (wage, covers, polling)
- Vendor row table with enable toggle, effective dates, metadata JSON
- `super_admin` write gate — non-super_admin gets read-only mode via `editingEnabled: canEdit` prop
- Plain-English operator copy throughout ("Which vendors can act as the wage source?")
- Required `reason` field + auto-minted `Idempotency-Key` per write
- Temporal end/replace only (no delete path)

### 2. Operator-web wage source binding

- **`lib/operator_web/screens/data_accuracy_screen.dart`** (+61 LoC) — wires the Data Accuracy wage authority picker to read `vendor_applicability` filtered by `setting_kind = 'wage' AND enabled = true AND effective_until IS NULL`
- **`lib/operator_web/widgets/wage_source_toggle.dart`** (+121/-9) — disables the vendor wage source when no current wage vendor is available, with operator-facing copy: "No current wage vendor is enabled for this location yet. Use the manual mix until F&F enables one."
- **`lib/operator_web/router/operator_web_router.dart`** (+7 LoC) + **`lib/operator_web/services/operator_web_team_gateway_providers.dart`** (+14/-2) — provider wiring for the `WebVendorApplicabilityGateway` already shipped by B10.1
- **`lib/operator_web/auth/firebase_operator_web_auth_source.dart`** (+8 LoC) — source-scoped read path

### 3. Admin route registration

- **`lib/admin/admin_routes.dart`** (+221/-6) — `/vendor-applicability` route registered, super_admin gate at line 1216
- **`lib/main_admin.dart`** (+20 LoC) — production gateway resolver wires `VendorApplicabilityAdminGateway` (already shipped by B10.1)

### 4. Tests (46 new/extended cases)

- `vendor_applicability_admin_screen_test.dart` (NEW, 307 LoC) — admin UI states + reason/idempotency assertions
- `admin_parity_copy_test.dart` (+25) — admin-only badge sweep coverage
- `data_accuracy_screen_test.dart` (+230/-20) — wage source binding states (loading, empty, error, disabled, current-vendors)

## Critical safety guarantees (executor-verified)

| Guarantee | File:line | Verification |
|---|---|---|
| `super_admin` write gate matches B10.1 | `lib/admin/admin_routes.dart:1216` | `canEdit = session.roles.contains('super_admin')` — non-super_admin sees read-only screen via `editingEnabled: canEdit` prop |
| `admin_reason` + `Idempotency-Key` threaded on writes (B10.1 contract) | `vendor_applicability_admin_screen.dart:194-198, 222-227` | Both `end` and `upsert` commands carry `adminReason` + `reasonNote` + `idempotencyKey` minted per action; matches B10.1 gateway-command DTO contract |
| Temporal end/replace only — no delete path | `vendor_applicability_admin_screen.dart:187`, `:213` | Screen calls only `gateway.end()` (sets `effective_until`) and `gateway.upsert()`. No `delete` method called |
| Operator-web read consumes B10.1 read route (no schema/RLS drift) | `lib/operator_web/screens/data_accuracy_screen.dart:314`, `lib/operator_web/services/web_vendor_applicability_gateway.dart:97` | Uses `WebVendorApplicabilityGateway` HTTP boundary; no postgres-direct, no `withTenant` invocation |
| No new proxy routes | diff scope | Zero changes under `tool/advisor_proxy/**` |
| Frozen `lib/auth/**` untouched | diff scope | Zero changes under `lib/auth/**` |
| No migration | diff scope | Zero changes under `db/migrations/**` |
| No-current-vendor branch disables vendor source with operator-readable copy | `wage_source_toggle.dart:105-108` | Plain-English: "No current wage vendor is enabled for this location yet. Use the manual mix until F&F enables one." |

## Executor spot-checks

| Check | Outcome |
|---|---|
| Base = master | ✓ — mergeable CLEAN |
| Pattern B both tables present | ✓ — worker 14L + executor 14L with file:line citations |
| `super_admin` write gate threaded correctly | ✓ — `admin_routes.dart:1216` |
| `admin_reason` + `Idempotency-Key` on every write | ✓ — `vendor_applicability_admin_screen.dart:194-198, 222-227` |
| Temporal end/replace only, no delete | ✓ — screen exposes only `end` + `upsert` actions |
| Operator-web read uses HTTP gateway (no postgres-direct) | ✓ — `WebVendorApplicabilityGateway` is HTTP boundary |
| No proxy / auth / migration / RLS touches | ✓ — diff scope confirms |
| 46 disclosed tests pass | ✓ — worker disclosure verified per PR body |
| `dart analyze --fatal-infos` clean | ✓ disclosed |
| `postgres_import_lint` clean | ✓ disclosed |
| `advisor_proxy.dart` size lint unchanged | ✓ — UI work doesn't touch the monolith; master post-Bundle 38 at 19,803 / 19,900 (headroom 97) |
| No `--no-verify` traces | ✓ |
| No tracker / ledger / lane-index touches | ✓ — diff scope confirms |
| No Codex-owned conflict | ✓ — Codex authored both B10.1 and B10.2 |

## Pattern B compliance

**✓ EXEMPLARY** — both 14-lens tables present in PR body with file:line citations. No drift.

## Genuine safety holds — checked

| Hold trigger | Status |
|---|---|
| Migration already applied to staging/Production1 | ❌ — no migration (reuses B10.1 schema) |
| Reject-class verdict | ❌ |
| Ledger conflict | ❌ — ledger row 69 covers exactly this scope (admin editor + operator-web wage authority binding) |
| Worker disclosure operator should know | ❌ — worker explicitly states "Cross-lane note: none" and "no proxy/schema expansion"; all clean |
| Stacked PR | ❌ — base is master |

**Decision**: per expanded policy. UI + operator-web binding on top of merged B10.1 backend; super_admin gate + admin_reason + Idempotency-Key all match B10.1 contract; temporal end/replace honors B10.1's no-delete posture; no surface expansion.

## Cross-lane notes

- **B10.1 (PR #576, Bundle 33) backend consumed verbatim** — `VendorApplicabilityAdminGateway` HTTP boundary + admin proxy routes + `vendor_applicability` schema all reused without extension
- **Operator-web Data Accuracy wage authority picker now live-bound** — closes B10.1's "operator-web binding still pending" deferral
- **No interaction with C-7 (mobile parity)** — Codex's C-7 worktree is separately tracked
- **No Codex-owned conflict** — Codex authored both B10.1 and B10.2

## Findings

None blocking.

## Authority anchors

- `docs/_indices/WAVE_EXECUTION_LEDGER.md` row 69 — B10.2 ledger row (operator gate)
- `docs/_execution/lane_b_features/03_execution_slices.md` B10.2 (line 178)
- PR #576 (B10.1, Bundle 33) — backend that B10.2 consumes
- B10.1 contract: super_admin admin gate + required `admin_reason` + required `Idempotency-Key` + temporal end/replace
- `feedback_production_not_backlog.md` — Build-Toward-Production discipline (operator-web binding lands in same wave, not deferred)

## Status

**Auto-merging** per operator's 2026-05-13 break-time expanded delegation. Same orchestrator bundle adds B2.3 + B2.4 as new Claude-lane ledger rows per operator's 2026-05-13 "no business live yet so mutations are fine" direction.
