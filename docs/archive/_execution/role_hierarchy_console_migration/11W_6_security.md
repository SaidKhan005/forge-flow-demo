# Codex Execution Prompt — `11W.6` Security

## Block 1 — Human Context

Plain English: Migrate the mobile Settings → Security (MFA + password change + login history) into the Operator Web Console at `/security`. Each user manages their own MFA factors, changes their password, and views their last 90 days of login history. Cross-team MFA reset stays on `11W.1` Members or escalates through `11A.14`.

Lane: `11W.6` — worktree `.claude/worktrees/<assigned-by-runbook>` on branch `claude/11W-6-security` off master @ HEAD.

Authority:
- `docs/contracts/team_roles_hierarchy_console_parity_contract.md` (binding parity contract)
- `docs/phases/phase_11W/phase_11W_operator_web_console_plan.md` § `11W.6` Security
- `docs/contracts/auth_permission_key_catalog.md` (MFA-required key list)

Current issue:
- Operators have no web surface for self-managed MFA + password + login history. Mobile has it; web parity needed for desktop convenience.

Human prerequisites:
- Setup/access needed: none — Phase 9 backend routes (`/v1/auth/mfa/*`, `/v1/auth/password/*`) live.
- Decision needed: none.

## Block 2 — Claude Paste

Task: Implementation slice. Build `11W.6` Security surface end-to-end.

Files to modify:
- `lib/operator_web/services/web_security_gateway.dart` — NEW. `package:http`-backed gateway: list MFA factors, begin TOTP enrollment, confirm TOTP enrollment, revoke factor (24h delayed), cancel pending removal, request recovery, change password (with current-password reverification), fetch login history (audit-log subset filtered to `auth.session.*` / `auth.password.*` / `auth.mfa.*`, last 90 days).
- `lib/operator_web/services/demo_web_security_gateway.dart` — NEW. Backed by `demo_team_fixtures.dart`.
- `lib/operator_web/screens/security_screen.dart` — NEW. Three-section layout: top = MFA factors list with per-factor status chip (`active` / `pending_enrollment` / `pending_removal` / `removed`) + per-row action buttons; middle = `Change password` button opening dialog; bottom = login history list (last 90 days, paginated 50/page).
- `lib/operator_web/screens/mfa_factor_dialog.dart` — NEW. Post-onboarding manage-MFA modal. NOT to be confused with the onboarding `MfaEnrollmentScreen` which lives in the onboarding click path. Idempotency key per enroll/revoke/cancel.
- `lib/operator_web/screens/change_password_dialog.dart` — NEW. Form: current password + new password + confirm new password. Validation copy verbatim from parity contract § Security.
- `lib/operator_web/router/operator_web_router.dart` — EDIT. Add `kOperatorWebNavSecurity` constant + nav item.
- `lib/main_operator_web.dart` — EDIT. Add `_resolveSecurityGateway` resolver.
- `test/operator_web/security_screen_test.dart` — NEW. Widget tests covering: factor list with all 4 status chips, MFA enroll click-path, cancel pending removal, password change validation copy verbatim, login history filtered + paginated.
- `test/operator_web/web_security_gateway_test.dart` — NEW. Unit tests for HTTP shapes + error mappings (`mfa_code_invalid`, `password_too_weak`, `password_history_match`, `current_password_incorrect`).
- `docs/_walkthroughs/11W.6.md` — NEW.

Files to leave alone:
- `lib/screens/settings/settings_mfa_section.dart` — mobile reference.
- `lib/operator_web/screens/mfa_enrollment_screen.dart` — onboarding click-path screen. Do NOT replace; the post-onboarding manage flow is a separate dialog.
- `tool/advisor_proxy/advisor_proxy.dart` — backend route handlers exist.

Hard constraints:
- Standard set.
- Do NOT bypass the current-password reverification on password change — the proxy enforces it; client must surface it.
- 24-hour delayed-removal flow for MFA factor revoke is server-side; client surfaces the pending state + cancel affordance.
- Validation copy verbatim from parity contract § Security.
- For live work, name-only preflight first.

Implementation tasks:
1. Read `lib/screens/settings/settings_mfa_section.dart` to extract factor-card render rules, status-chip mapping, delayed-removal UX.
2. Read backend route handlers for `authMfaFactorsListPath`, `authMfaFactorsRevokePath`, `authMfaFactorsRemovalCancelPath`, `authMfaTotpBeginPath`, `authMfaTotpConfirmPath`, `authMfaRecoveryRequestPath`, `authPasswordChangePath`. Confirm shapes.
3. Read `lib/services/auth/password_change_gateway.dart` abstract interface — reuse if surface fits.
4. Build gateway + demo gateway.
5. Build screen + dialogs.
6. Wire nav + resolver.
7. Tests + walkthrough.
8. Local web build.

Required tests:
- `flutter analyze --fatal-infos <touched paths>`
- `flutter test test/operator_web/security_screen_test.dart test/operator_web/web_security_gateway_test.dart`
- `flutter build web -t lib/main_operator_web.dart --dart-define=OPERATOR_WEB_DEMO_AUTH=true --pwa-strategy=none`

Acceptance criteria:
- [ ] Parity contract § Security: MFA factor list with 4 status chips, delayed-removal cancel affordance, password change with current-password reverification, login history filtered to last 90 days of `auth.*` events.
- [ ] Validation copy verbatim from parity contract.
- [ ] Idempotency keys minted in dialog state.
- [ ] No `dart:io` / `sqflite`; web build succeeds.
- [ ] `11W.6` walkthrough at `docs/_walkthroughs/11W.6.md`.
- [ ] No tracker changes, no commits, no scope drift into onboarding `MfaEnrollmentScreen`.
- [ ] Pair with `11A.14` Actions panel — both must hit ACCEPT before either merges.

Report using the standard execution report.
