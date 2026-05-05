# Codex Execution Prompt — `11A.14` Audited Support Actions

## Block 1 — Human Context

Plain English: F&F Operations Console gets a cross-operator audit-log review surface PLUS a support-actions panel for the heavy escalations: reset member MFA factors, initiate password reset, and issue paired-approval GDPR erasure. This slice adds one new permission key to the catalog (`admin.users.reset_mfa_factors`) via additive migration — the only schema change in the entire migration block.

Lane: `11A.14` — worktree `.claude/worktrees/<assigned-by-runbook>` on branch `claude/11A-14-audited-support-actions` off master @ HEAD.

Authority:
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity contract)
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` § `11A.14` Audited support actions
- `docs/contracts/auth_permission_key_catalog.md` § `admin.*` (the contract MUST be updated as part of this slice when the new key lands)

Current issue:
- F&F support has no console for audited support actions. Today MFA reset / password reset / erasure all require shell access. This slice ships the cross-operator support panel.

Human prerequisites:
- Setup/access needed: none — backend route handlers exist except the new MFA-factors-reset path which lands in this slice's migration.
- Decision needed: none.

## Block 2 — Claude Paste

Task: Implementation slice. Build `11A.14` Audited Support Actions end-to-end + ship the new permission key migration + update the catalog.

Files to modify:
- `db/migrations/<timestamp>_phase_11A_14_admin_users_reset_mfa_factors_key.sql` — NEW. Additive migration. INSERT new row into `public.permission_keys` for `admin.users.reset_mfa_factors`. Grant to `super_admin` role. NOT to `ff_support` by default — MFA reset is a senior-only action; super_admin only. Do NOT mark `requires_mfa=true` at catalog level (no MFA-required keys for `team.*` per the launch tier posture; `admin.users.reset_mfa_factors` follows the same posture but the route adds fresh-sign-in enforcement separately).
- `lib/auth/permission_keys.dart` — EDIT. Add the constant + add to `PermissionKeys.all`.
- `docs/contracts/auth_permission_key_catalog.md` — EDIT. Add the row to the `admin.*` table. Update count: "F&F admin actions. ... The 9.0Σ.h2 slice (2026-04-28) added `admin.audit_privacy.read` ... The `11A.14` slice (`<date>`) adds `admin.users.reset_mfa_factors`." Update overall key count.
- `lib/admin/services/audited_support_actions_admin_gateway.dart` — NEW. `package:http`-backed gateway: list operator audit log (filters parity with `11W.5`), CSV export (gated on `admin.audit_log.export`), reset member MFA factors (gated on the new `admin.users.reset_mfa_factors`), initiate password reset (gated on `admin.users.reset_password`), issue paired-approval erasure (gated on `admin.users.erase_pii`, MFA-required, paired-approval workflow).
- `lib/admin/services/demo_audited_support_actions_admin_gateway.dart` — NEW. In-memory backed by admin-side fixtures.
- `lib/admin/screens/audited_support_actions_admin_screen.dart` — NEW. After operator-picker, two-pane layout: left = audit log viewer (parity with `11W.5` filters + render rules), right = `Actions` panel with three buttons gated per the catalog. Each button opens a modal requiring `admin_reason` + (for paired-approval erasure) a second admin's confirmation.
- `lib/admin/screens/paired_approval_erasure_dialog.dart` — NEW. Two-step modal: step 1 = primary admin enters target user + `admin_reason`; step 2 = pending state with copyable approval token; secondary admin enters the token + their own `admin_reason` to complete. Idempotency keys per step.
- `lib/admin/admin_routes.dart` — EDIT. Add `kAdminRouteAuditedSupportActions` and wire to the screen.
- `lib/main_admin.dart` — EDIT. Add `_resolveAuditedSupportActionsAdminGateway` resolver.
- `test/admin/audited_support_actions_admin_screen_test.dart` — NEW. Widget tests covering: audit-log filter parity with `11W.5`, MFA-reset gated correctly, password-reset gated correctly, paired-approval erasure 2-step flow, `admin_reason` mandatory.
- `test/admin/audited_support_actions_admin_gateway_test.dart` — NEW. Unit tests for HTTP shapes + paired-approval token handoff + error mapping.
- `test/advisor_proxy_test.dart` — EDIT. The Phase 9.0 test group asserts the migration seeds at least the keys exposed by `PermissionKeys.all`. Adding the new constant requires the migration to ship in the same slice for this test to stay green.
- `docs/_walkthroughs/11A.14.md` — NEW.

Files to leave alone:
- `lib/admin/screens/operator_picker_screen.dart` — reused.
- Existing migrations — additive only, do not modify.
- `tool/advisor_proxy/advisor_proxy.dart` — backend route handler for the new key may need to be added IF it doesn't exist; check before adding. If a new backend route is needed, STOP and report — the parity contract says `11A.14` is the only slice in the block that may add new infrastructure, so this is the slice that legally can do it, but only with explicit documentation in the parity contract update.

Hard constraints:
- Standard set.
- After migration changes, run `dart run tool/migration_drift_scanner.dart --fix --strict-docs` then `dart run tool/migration_cutoff_lint.dart` per `slice_runtime_acceptance_contract.md` § Migration Drift Scanner.
- Catalog + migration + `permission_keys.dart` change MUST land in the same slice per the catalog keep-in-sync rule (`auth_permission_key_catalog.md` § Keep in sync).
- `admin_reason` mandatory on every mutation.
- Paired-approval erasure: two distinct admin UIDs required server-side; client surfaces the workflow correctly.
- For live work, name-only preflight first.

Implementation tasks:
1. Read `lib/screens/settings/settings_audit_log_section.dart` (mobile audit log) + `11W_5_audit_log.md` prompt to extract parity expectations for the audit-log viewer half.
2. Read backend route handler shapes for `adminAuthUsersPath` PATCH variants (existing reset_password) + the audit-log read/export routes.
3. Confirm whether a backend route exists for resetting MFA factors via admin path. If yes, bind to it. If no, the slice scope grows: add the route to `tool/advisor_proxy/advisor_proxy.dart` + tests. Document the decision in the slice execution report.
4. Write the additive migration. Use the next timestamp in sequence per `db/migrations/` ordering. INSERT into `permission_keys` + GRANT to `super_admin`.
5. Update `lib/auth/permission_keys.dart` + `docs/contracts/auth_permission_key_catalog.md` per the catalog keep-in-sync rule.
6. Run `dart run tool/migration_drift_scanner.dart --fix --strict-docs` + `dart run tool/migration_cutoff_lint.dart`.
7. Build admin gateway + demo gateway + screen + paired-approval dialog.
8. Wire route + resolver.
9. Tests + walkthrough.
10. Verify the existing `Phase 9 auth schema foundation migration (9.0)` test still passes after the catalog addition.
11. Local web build.

Required tests:
- `flutter analyze --fatal-infos <touched paths>`
- `flutter test test/admin/audited_support_actions_admin_screen_test.dart test/admin/audited_support_actions_admin_gateway_test.dart test/advisor_proxy_test.dart`
- `dart run tool/migration_drift_scanner.dart --fix --strict-docs`
- `dart run tool/migration_cutoff_lint.dart`
- `flutter build web -t lib/main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true --pwa-strategy=none`

Acceptance criteria:
- [ ] New permission key `admin.users.reset_mfa_factors` added to migration + `PermissionKeys.all` + catalog table; key counts updated; Phase 9.0 foundation test still passes.
- [ ] Migration drift scanner + cutoff lint clean.
- [ ] Parity contract § Audit Log (admin path with `?operator_id=...`).
- [ ] Parity contract § Security (admin actions panel with `admin_reason` + paired-approval erasure flow).
- [ ] Paired-approval erasure: two distinct admin UIDs required server-side; client workflow surfaces correctly.
- [ ] Admin web build succeeds.
- [ ] `11A.14` walkthrough at `docs/_walkthroughs/11A.14.md`.
- [ ] Parity contract § Surface map updated to reflect the new key (this slice may also need to update the parity contract; do so as part of acceptance).
- [ ] No tracker changes, no commits beyond what the migration needs.
- [ ] Pair with `11W.5` + `11W.6` — all three must hit ACCEPT before any merges per parity contract.

Report using the standard execution report.
