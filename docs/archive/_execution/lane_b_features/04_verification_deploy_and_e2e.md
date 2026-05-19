# 04 — Verification, Deploy, and End-to-End (Lane B — Features)

Status: planning draft, 2026-05-12.
Authority: `docs/contracts/slice_runtime_acceptance_contract.md`,
`runbooks/browser_use_codex_acceptance_workflow.md`,
`docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` Lens 12.

## Verification Philosophy

Each B slice produces three layers of evidence:

1. **Code-level tests** — `dart analyze` clean + the smallest targeted test
   suite that exercises the new seam (per CLAUDE.md "Testing" rule).
2. **Browser walkthrough** — Claude Preview MCP-driven click path against the
   demo flavour (`flutter run --release -t lib/main_admin.dart` for admin
   surfaces; `lib/main_operator_web.dart` for operator-web; mobile uses
   `lib/main_forgeflow.dart`). Captures named widgets + named values per the
   click-path bar set by `docs/_walkthroughs/7.58.UX.5.md`.
3. **Audit/runtime integrity** — proof that hash-chain integrity, RLS, and
   idempotency are not violated.

No B slice ships without all three.

## Per-Slice Verification

### B1.a — Inheritance notice propagation

- **Tests:** Widget tests for Data Accuracy + Polling tile under business scope
  with N=1 covered location and N=2 covered locations. Assert
  `admin_timing_scope_inheritance_notice` key present in N=1, suppressed in N=2.
- **Browser:** Drive admin demo → Business accounts → Demo Diner Co. → Data
  Accuracy → expect notice at business scope with 1 covered location. Capture
  screenshot key.
- **Migration:** none.

### B1.b — Admin audit actor fix

- **Tests:** Regression test inserts an operator-location admin fan-out write;
  assert `audit_logs.actor_kind = 'forge_admin'` (not `'team_member'`). Snapshot
  the hash-chain before + after; assert `prev_row_hash` continuity.
- **Browser:** N/A (server-side).
- **Audit:** Confirm by the chain verifier that the new row's hash links
  cleanly. No re-bake of existing rows.

### B2.1 — Default Role catalog schema + publish endpoint

- **Tests:** Repository tests for INSERT new version, GET latest, GET pinned.
  Proxy route test for `POST /v1/admin/auth/role-catalogs/publish` (auth gate,
  idempotency, audit row emission with SHA-256). Resolver test confirms
  operator with NULL pointer gets latest payload.
- **Browser:** N/A this slice (admin surface in B2.2).
- **Audit:** Publish emits `default_role_catalog.publish` event; verify
  payload SHA-256 and blast-radius count.
- **Migration:** `tool/migration_drift_scanner.dart --strict-docs` after.

### B2.2 — Default Role catalog admin editor surface

- **Tests:** Widget tests on the editor: blast-radius preview math, publish
  confirmation dialog requires typing role name for high-blast. Operator-web
  badge + "Updated by F&F on <date>" annotation when catalog version changes.
- **Browser (admin):** Driven via Claude Preview MCP at port `8090`:
  1. Sign in as `super.admin@forgeflow.test`.
  2. Navigate Admin → Default Roles tile.
  3. Edit operator_manager → add permission → click Publish.
  4. Confirm blast-radius preview names X businesses + Y locations.
  5. Confirm typing the role name unlocks Publish CTA.
  6. After publish, switch to operator-web flavour, navigate Roles screen,
     observe "Default" badge on operator_manager + "Updated by F&F on
     2026-05-12" annotation.
- **Audit:** Publish row emitted; SHA-256 verifiable.

### B3 — Role-key hybrid identifier sweep

- **Tests:** Unit tests on `RolesRepository.findById(role_id)` and
  `RolesRepository.findBySeededKey(role_key)`. Mutation routes only accept
  `role_id`. Rename custom role display name; assert zero new audit rows in
  `role_audit_log` other than the rename itself, and zero `user_roles` writes.
- **Browser:** Operator-web role editor — rename a custom role; observe
  display change reflected; no impact on grant list.

### B4 — Two-product taxonomy in role editor

- **Tests:** Widget tests for the two-tab editor. Assert Barrio tab disabled
  when operator's plan excludes Barrio (or stub plan flag returns false).
- **Browser (operator-web):** Custom role editor — confirm two tabs, "Forge &
  Flow" populated with 20 permissions, "Barrio" shows 12 dormant.
- **Browser (admin):** Same shape in admin role editor for seeded roles
  (read-only) and operator custom roles (editable parity).

### B5 — Admin access-control + permission-key completeness sweep

- **Tests:** Proxy integration tests issue requests to every admin route as
  each role: super_admin (allow), ff_support (read-only allow on view routes,
  reject on mutate), operator_owner (reject on cross-operator routes), etc.
- **Browser:** N/A.
- **Doc:** `05.5_catalog_followup.md` proposal handed to catalog owner; no
  catalog mutation in this lane.

### B6 — Benchmark override

- **Tests:** Repository tests for hierarchy resolver (operator_wide ←
  org_unit ← location). Proxy route tests with idempotency-key on
  POST/PATCH. RLS test: operator A cannot read operator B's overrides.
- **Browser (operator-web):** Settings → Benchmarks tile:
  1. Set business-scope CPLH override to 12.50.
  2. Select an org_unit; observe Inheritance Tree shows "Inherited from
     business — 12.50".
  3. Set org_unit override to 13.00; observe value flips with "Set at this
     scope" badge.
  4. Select a location under that org_unit; observe "Inherited from <org_unit>
     — 13.00".
- **Audit:** `benchmark.override.set` / `benchmark.override.clear` events
  emitted with `scope_type` and old → new values in payload.

### B7.a — Invite dialog hierarchy-scope bug + Cancel CTA

- **Tests:** Widget tests for invite dialog with `scopeType =
  'operator_wide'` and `'org_unit'`; assert `primaryLocationId` is not
  required. Integration tests: `POST /v1/admin/auth/invites` with each scope
  type lands without error. Per-row Cancel emits `invite.cancel` audit event;
  the previously-emailed link returns 410 Gone.
- **Browser (admin):** Invite member dialog → pick "Whole business" scope →
  observe location dropdown disabled; submit → invite appears in Pending list.
  Click Cancel on pending row → modal restates email + role → confirm → toast
  with Undo within 10s.
- **Email:** Operator-admin invite template fires through SendGrid; subject
  `{{inviterName}} invited you to join {{businessName}}`.

### B8 — Audit log hierarchy filter

- **Tests:** Repository unit test for `listByHierarchy()`: business scope,
  org_unit scope (descendant set resolved via ltree), location scope. Proxy
  route test with all three scope_type values. Perf test asserts p95 < 500ms
  with 100 locations under one org_unit.
- **Browser (admin):** Audit Log page:
  1. Default load — business scope, all locations.
  2. Click an org_unit in scope picker → table refilters in <1s.
  3. Drill to a location → table shows only that location's rows.
  4. Verify "Mixed — N events across 3 locations" indicator on parent scope.
- **Audit chain integrity:** Repository asserts the response was assembled
  via SELECT only; no UPDATE/DELETE was ever attempted. Hash chain integrity
  unchanged before/after (run `tool/audit_anchor/audit_anchor.dart` verify
  mode against the test partition).

### B9.1 — `/sign-in-security` 301 redirect

- **Tests:** Router unit test: GET `/operator-web/sign-in-security` returns
  301 with `Location: /my-account#security`; query params and fragment
  preserved. Same for admin equivalent.
- **Browser:** Manually paste the old URL into the operator-web preview;
  observe redirect to `/my-account#security` and the Security card visible.

### B9.2 — My Account consolidation + Active Sessions

- **Tests:** Widget tests: My Account renders four cards in order Profile →
  Security → MFA → Active Sessions. Active Sessions current row carries "This
  device" label and no destructive action. "Sign out all other sessions"
  requires step-up.
- **Browser (operator-web):** Sign in on two devices (open two browser tabs);
  observe both sessions in Active Sessions; click "Sign out all other
  sessions" → step-up MFA → only current session remains; the other tab gets
  signed out on next request.

### B9.3 — Adaptive 2FA button (4 states)

- **Tests:** State-machine unit test:
  NotEnrolled → enroll → Enrolled →
  request removal → RemovalRequested(timer=24h) →
  countdown expires → Removable →
  Turn off + step-up → NotEnrolled.
  Also: cancel during grace → step-up → Enrolled.
- **Browser (operator-web):** My Account → MFA card:
  1. Enroll TOTP authenticator; observe "Two-step verification is on".
  2. Click "Manage methods" → "Turn off" → modal asks for confirmation +
     step-up.
  3. After confirm, MFA card shifts to "Two-step verification turns off in
     23h 59m" with Cancel CTA more prominent than Turn off.
  4. Cancel → step-up → Enrolled.
  5. Repeat request → wait 24h (fast-forward demo timer) → Removable state →
     Turn off + step-up → NotEnrolled.
- **Audit:** `mfa.removal_request`, `mfa.removal_cancel`, and the eventual
  `mfa.factors.revoke` events emit with consistent actor + reason.

### B10.1 — `vendor_applicability` table + routes

- **Tests:** Repository tests: insert global default, insert per-operator
  override, end-row by setting `effective_until`, current-state read returns
  active rows only, RLS test (operator A sees own rows + global defaults
  only).
- **Browser:** N/A this slice (admin surface in B10.2).
- **Audit:** Each upsert emits `vendor_applicability.upsert` event.
- **Migration:** Run drift scanner; assert RLS policy applies wrapper
  functions (`app_current_operator()`).

### B10.2 — Vendor applicability admin editor + operator-web binding

- **Tests:** Widget tests: admin tabs render per setting_kind; toggle persists;
  effective_until edit creates a new row. Operator-web Data Accuracy wage
  authority picker filters its dropdown by `vendor_applicability`.
- **Browser (admin):** Vendor Applicability page → Wage tab → enable Gusto for
  global default → save → assert audit row + history view. Operator-web Data
  Accuracy: wage source dropdown now includes Gusto.

### B11.1 — `handoff_codes` table + endpoints

- **Tests:** Repository tests: atomic consume (concurrent redeem yields one
  success, one 410 Gone); expired code → 410; wrong operator → 403. Rate
  limit test: 10 mints/hour cap.
- **Browser:** N/A this slice (mobile + web client wiring in B11.2 + B11.3 if
  split).
- **Audit:** `auth.handoff.code_created` + `auth.handoff.redeemed` emit.
- **Migration:** Drift scanner; confirm `handoff_codes` is operator-scoped
  with `operator_id` indexed.
- **Approval gate (CLAUDE.md "agent-led slices"):** Explicit operator
  approval required before merge.

### B11.2 — RFC 9470 step-up on sensitive routes

- **Tests:** Per sensitive route: with stale auth_time, expect 401 + the
  `WWW-Authenticate` header content per RFC 9470. With fresh auth_time, expect
  200. After step-up + retry with fresh `auth_time`, expect 200.
- **Browser:** Operator-web:
  1. Sign in; wait >5min (or fast-forward).
  2. Attempt to publish a Default Role catalog change (or any sensitive
     action).
  3. Observe step-up MFA prompt; complete TOTP; observe action completes.
- **Mobile cross-flavour:** Same flow from the mobile deep-link emitter →
  web redeem → sensitive landing → step-up → completed action.
- **Approval gate:** Explicit operator approval required before merge.

## Deploy Modes

| Slice | Demo mode? | Preview deploy? | Live deploy gate |
|---|---|---|---|
| B1.a, B1.b | ✅ demo | ✅ preview | Standard runtime acceptance |
| B2.1, B2.2 | ✅ demo (catalog version pointer used in seed) | ✅ preview | Operator approval required (catalog touches blast radius) |
| B3, B4 | ✅ demo | ✅ preview | Standard |
| B5 | demo not applicable (read-only audit) | ✅ preview | Standard |
| B6 | ✅ demo (seed example overrides) | ✅ preview | Standard |
| B7.a | ✅ demo (use fixtures) | ✅ preview | Email delivery requires SendGrid sandbox key |
| B8 | ✅ demo | ✅ preview | Audit chain verifier MUST pass before live promote |
| B9.1, B9.2, B9.3 | ✅ demo | ✅ preview | Standard |
| B10.1, B10.2 | ✅ demo (seed global defaults) | ✅ preview | Operator approval required (RLS + new schema) |
| B11.1, B11.2 | ✅ demo (mint/redeem codes against local DB) | ✅ preview | Operator approval required + security review (auth-critical) |

Every preview deploy uses the operator-web + admin demo flavours, NOT live
production credentials, per CLAUDE.md "live work, run name-only preflight
first" rule. Live deploys for B2/B10/B11 wait on operator sign-off.

## Browser Walkthrough Standard

Every UX-exposing slice produces a click-path doc at
`docs/_walkthroughs/<slice-id>.md` per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md` "Walkthrough Specificity". Each:

- Demo-mode start condition (date 2026-05-12, business "Demo Diner Co.",
  appropriate seeded user).
- Numbered steps naming user action.
- Expected visual state per step with named widgets (e.g.,
  `MfaCardController.state == RemovalRequested`).
- Named value expectations (e.g., `Active sessions row 1 label = "This
  device"`, `blast-radius preview = "47 businesses, 312 locations"`).

Codex returns `FOLLOW-UP NEEDED` if a walkthrough is vague.

## Hash-Chain Integrity Confirmation (B8 + B1.b)

After every B8 slice merge and the B1.b actor fix:

1. Run `tool/audit_anchor/audit_anchor.dart verify --since=<prev-anchor>`.
2. Confirm hash chain has no `prev_row_hash` mismatches.
3. Confirm no `UPDATE audit_logs` rows in `tool/migration_drift_scanner.dart`
   output for the merged migration set (CI lint per addendum A7).
4. Confirm daily Azure Blob anchor commit succeeded (post-merge cron run).

For B8 specifically: the read path uses SELECT only. The repository code
exposes a `--lint-no-updates` mode that asserts the only SQL emitted in test
runs is SELECT.

## RLS Test Plan

Every new schema (B2.1 `default_role_catalog_versions`, B6
`benchmark_overrides`, B10.1 `vendor_applicability`, B11.1 `handoff_codes`)
goes through the standard RLS smoke test:

1. Operator A inserts a row.
2. Switch `SET LOCAL app.current_operator = '<operator B>'`.
3. Assert operator A's row is NOT visible.
4. Operator B inserts a different row; switch back to A; assert A sees A's
   row only.

For B2.1 the catalog is global (no `operator_id`); RLS bypass via
`forge_admin` role is the only write path. For B11.1 the table is per-user;
the operator scope check happens at the proxy layer (verify user_id matches
the redeeming session).

Per `docs/contracts/hardening_rls_and_repository_pattern_contract.md`, RLS is
the *backup* defense; the `OperatorScopedRepository<T>` wrapper is primary.
All new repositories extend it.

## Test Command Cheatsheet

```bash
# Per slice:
dart analyze
dart test test/<slice_targeted_test>.dart

# After any db/migrations/*.sql change:
dart run tool/migration_drift_scanner.dart --fix --strict-docs
dart run tool/migration_cutoff_lint.dart

# Audit chain integrity (after B8 or B1.b):
dart run tool/audit_anchor/audit_anchor.dart verify --since=<anchor>

# RLS smoke (per new schema):
dart test test/infrastructure/persistence/postgres/repositories/<repo>_test.dart
```

## Out of Scope for Lane B Verification

- Mobile app full end-to-end (cross-flavour parity) — Lane C.
- Email delivery in production — Lane C email pipeline owns the SendGrid
  pressure test.
- Proxy decomposition perf benchmarks — Lane A's soak harness.
- Live production cutover gates — orchestrator + operator sign-off after
  preview-verified merge.
