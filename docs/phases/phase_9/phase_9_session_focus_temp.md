# Phase 9 Session Focus Temporary Note

Date: 2026-04-29
Status: Temporary working note for this session

## Purpose

This note captures the current Phase 9 closeout focus before moving into the next phase. It is not the canonical backlog; it is a short working checklist for the current session.

## Closeout Position

Phase 9 can be treated as handoff-ready, not production-launch complete.

Excluding deferred and live-launch gates, the remaining item that needs a conscious decision before mentally closing the phase is the email action UX: Firebase email template hygiene, post-action routing, and whether the current Firebase-hosted browser flow is acceptable for Phase 9 closure.

## Questions Being Resolved

1. Are there non-deferred backlogs that must be addressed before closing Phase 9?
2. Is there any UX debugging that should happen now?
3. Should Firebase email templates be handled now?
4. What should happen after a user completes an email action?
5. Are all Phase 9-relevant items in production, and are there naming or UX polish details to fix?

## Current Answers

### 1. Backlog

No hidden Phase 9 blocker was found beyond already-known deferred, launch, or next-phase items.

Important open items remain tracked elsewhere:

- B41 and B46 are locally complete but still need live apply before later phases depend on them.
- B44, B45, and B47 have helper or runbook work landed, but producer/UI wiring remains future work.
- Cloud Armor enforcement, physical iOS QA, launch load tests, and cutover gates remain deferred or launch items.

Close Phase 9 only as accepted for next-phase handoff.

### 2. UX Debug

Do a focused staging UX pass now:

- Invite user flow from email to first login.
- Forgot/reset password flow.
- Login/logout/session expiry.
- Settings > Team invite, revoke, role change, and reset password.
- Permission-denied states.
- MFA/recovery copy if visible.
- Mobile and narrow viewport checks.
- Loading, empty, expired-link, and failed-action messages.

Watch for raw terms such as operator_id, RLS, Firebase, B17, UUIDs, permission keys, or HTTP-status-style errors in user-facing UI.

### 3. Firebase Email Templates

Do minimum hygiene now, not a deep template project.

Before external users see invites or resets, confirm the Firebase sender/display name, subject lines, and visible copy do not look like default Firebase project email.

Suggested copy:

- Sender: Forge & Flow
- Invite subject: Set up your Forge & Flow account
- Reset subject: Reset your Forge & Flow password
- Button: Set password or Reset password

Avoid exposing project IDs or Firebase wording.

### 4. Routing Back To App

The backend supports a configured Firebase email action continue URL through FIREBASE_EMAIL_ACTION_CONTINUE_URL, but no app-side deep-link or action-code route was found for mode, oobCode, reset password, or verify email.

Safe current statement:

- Firebase/web email action flow has staging smoke evidence.
- Polished return-to-app behavior is not fully implemented as an app route.
- Phase 9 closure is acceptable only if the product accepts that the user completes the email action in a browser, then manually opens Forge & Flow and logs in.
- A branded post-action landing page or native deep-link handler should be added before a professional external pilot.

### 5. Production, Testing, And Naming

Production1 has the DB schema through 202604280013 applied and verified. Runtime, Firebase, and user flows were staging-smoked, not fully Production1-smoked.

Test staging with production-like URLs before closeout.

Polish labels and copy:

- Role names: Owner, Manager, Supervisor, Staff.
- Invite states: Invited, Active, Expired, Revoked.
- Reset copy: human and calm, with no backend jargon.
- Permission errors: user-friendly copy, not raw permission keys.
- Expired link page: clear next step.
- Team screen buttons: Invite, Resend, Change role, Remove access, Reset password.
- Email sender and subject lines.
- No project IDs, Firebase names, raw UUIDs, migration names, or debug labels in user-facing UI.

## Working Recommendation

Do one focused staging UX and email-action pass, record app-return/deep-link work as either an accepted Phase 9 limitation or a next backlog item, then close Phase 9 as handoff-ready with deferred launch gates tracked.

## Backend vs UI Exposure Audit - 2026-04-29

This pass checked the current code against Phase 9 auth docs and archived smoke notes. The backend/proxy is ahead of the visible UI.

### Visible And Wired In-App

- Signed-out login with Firebase email/password.
- Forgot-password request from the login screen with enumeration-safe confirmation copy.
- Auth gate for loading, unauthenticated, MFA challenge, and authenticated states.
- Session rehydrate rejects expired persisted sessions and returns to sign-in.
- Signed-in Settings > Account tab with Change Password, Sign Out, and Sign Out Everywhere.
- Account password-change dialog owns its controllers safely and fits phone width.
- Sign Out now revokes the stored `auth_sessions` row before local Firebase sign-out.
- Sign Out Everywhere now calls the auth-session revoke-all path and the new proxy refresh-token revoke-all path when the updated proxy is running.
- Settings > Team tab appears only from the live permission snapshot.
- Team role dropdown can hydrate from the proxy role catalog.
- Team invite form can submit to the proxy invite endpoint when the gateway is configured.
- MFA challenge screen is visible when Firebase sign-in returns MFA-required, with authenticator-code entry only. Recovery-code login/reset is not a launch UX or proxy route.
- Permission-denied navigation mostly fails closed by hiding unavailable surfaces.

### Backend/Proxy Wired But Not Fully Exposed In UI

- `DELETE /v1/admin/auth/invites/{invite_id}` exists through `ProxyAuthOperationsGateway.revokeInvite`, but the Team UI has no pending-invites list or revoke button.
- `POST /v1/admin/auth/users/{user_id}/suspend`, `reactivate`, `soft-delete`, and `reset-password` exist through the proxy gateway, but the Team UI has no per-user action menu for suspend/reactivate/remove access/reset password.
- `POST /v1/admin/auth/role-grants` and `DELETE /v1/admin/auth/role-grants/{user_role_id}` exist, but the Team UI has no user-detail role grants table, add-role form, or revoke-role control.
- Role catalog create/patch/delete exists in the app-side gateway and proxy, but no custom-role UI is surfaced.
- The Team UI has filters and an injected user table model, but the live app does not yet load users into `SettingsScreen`; current production-like app settings can show an empty Team list even though backend user operations exist.
- Backend docs mention invite list and user role-grant detail endpoints; current proxy code does not expose `GET /v1/admin/auth/invites`, `GET /v1/admin/auth/users`, or `GET /v1/admin/auth/users/{user_id}/role-grants`.
- MFA enrollment endpoints exist through `/v1/auth/mfa/totp/begin` and `/confirm`; recovery-code consume routes are removed from the live proxy surface for launch.
- Permission-denied proxy responses include raw fields such as `permission_key`; normal UI hides gated actions, but any future visible failed-action surface must translate these to customer copy.
- Firebase email actions are still browser/action-link flows. The app does not handle `mode`, `oobCode`, invite acceptance, reset completion, expired-link, or failed-action routing as native screens.

### Current UX Gaps Against The Requested Checklist

- Invite user flow from email to first login: staging smoke passed, but the professional return path remains browser-complete/manual-open-app. No native expired-link or accepted-invite screen.
- Forgot/reset password flow: in-app request is visible; email action works through Firebase/browser; no native reset-complete route.
- Login/logout/session expiry: login/logout visible; persisted expired sessions are rejected on rehydrate. A visible in-session expiry/reauth message is not present.
- Settings > Team invite, revoke, role change, and reset password: invite is exposed; revoke, role change, per-user reset password, suspend/reactivate, and soft-delete are not exposed.
- Permission-denied states: nav/actions are mostly hidden; explicit friendly denied/needs-fresh-auth states are not broadly surfaced.
- MFA/recovery copy: authenticator challenge and admin-contact recovery copy are visible; recovery-code save/regenerate/entry copy is not a launch surface.
- Mobile/narrow viewport: account password dialog, footer, data timestamp row, and settings action rows now have phone-width safeguards; Team rows and invite panel still need a real-device/narrow pass with long emails and location names.
- Loading, empty, expired-link, failed-action messages: login/loading, Team empty, invite validation, and account errors exist. Expired-link/failed-email-action messages do not exist inside the app. Team live-user loading/error states are not implemented because live user list loading is not wired.

## Session Wiring Update

Implemented in this session:

- ForgeFlow auth builds now require `FORGE_FLOW_USE_FIREBASE_AUTH=true` to show the Phase 9 auth shell.
- ForgeFlow auth builds now pass proxy-backed permission, team/auth-operations, password-change, and MFA gateways into the app shell when `FORGE_FLOW_PROXY_BASE_URI` is supplied.
- The login screen exposes `Forgot password?` and uses enumeration-safe confirmation copy.
- Settings exposes signed-in account actions: Change Password, Sign Out, and Sign Out Everywhere.
- Sign Out Everywhere now has a proxy-backed Firebase refresh-token revoke-all bridge. This requires the updated proxy route to be running; rebuilding only the phone app is not enough for that path.
- Settings > Team is now driven from the live permission snapshot and proxy role catalog instead of only test/dev injection.
- Team invite submission is connected to the proxy invite gateway when available and shows a friendly failure snackbar if the request fails.
- Barrio auth startup wraps the signed-in home with the permission snapshot bridge when auth is enabled.
- Settings > Account was moved to its own tab for signed-in users.
- Fixed phone-width settings footer overflow and added truncation safeguards to Settings action rows.
- Fixed the password-change dialog controller lifecycle so password reset/change interactions do not dispose live text controllers.

Verified commands:

```powershell
flutter analyze lib\forge_flow_app.dart lib\main.dart lib\main_forgeflow.dart lib\main_barrio.dart lib\barrio_app.dart lib\state\auth_session_notifier.dart lib\screens\auth\auth_permission_context_bridge.dart lib\screens\auth\login_screen.dart lib\screens\settings_screen.dart lib\screens\settings\settings_data_sections.dart lib\screens\team\team_settings_section.dart test\widget_test.dart test\settings_screen_widget_test.dart test\auth_session_test.dart
flutter test test\widget_test.dart test\auth_session_test.dart test\settings_screen_widget_test.dart test\team_ux_kernel_test.dart --reporter compact
flutter build apk --debug --flavor forgeflow -t lib\main_forgeflow.dart --dart-define=FORGE_FLOW_USE_FIREBASE_AUTH=true --dart-define=FORGE_FLOW_PROXY_BASE_URI=http://127.0.0.1:8080
flutter test test\settings_screen_widget_test.dart --reporter compact
flutter test test\auth_session_test.dart --plain-name "signOutThisSession revokes" --reporter compact
flutter test test\auth_session_test.dart --plain-name "signOutAllSessions revokes" --reporter compact
flutter test test\advisor_proxy_test.dart --plain-name "refresh-tokens" --reporter compact
flutter test test\proxy_auth_session_ledger_writer_test.dart --plain-name "ProxyRefreshTokenRevoker" --reporter compact
flutter test test\firebase_admin_auth_client_test.dart --reporter compact
flutter analyze lib\services\auth\password_change_gateway.dart lib\services\auth\repository_password_change_gateway.dart tool\advisor_proxy\advisor_proxy.dart test\proxy_auth_operations_route_test.dart test\firebase_admin_auth_client_test.dart
flutter test test\proxy_auth_operations_route_test.dart --plain-name "POST password change" --reporter compact
flutter test test\proxy_password_change_gateway_test.dart --reporter compact
```

Live staging password-change correction, 2026-04-29:

- Symptom: Settings > Account > Change Password could appear to accept a
  current/new password sequence, but the new password did not reliably become
  the password used by Firebase login/logout.
- Root cause found on staging: the signed-in Firebase token subject for the
  smoke/admin account differed from the legacy seeded `users.firebase_uid`
  value. The password-change gateway used the database `firebase_uid` as the
  Firebase update target, while the Android app logged in with the token
  subject.
- Fix: the proxy now passes the verified Firebase token subject into
  `PasswordChangeCommand`, and `RepositoryPasswordChangeGateway` uses that UID
  for Firebase verify/update while continuing to record history/audit against
  the app `user_id`.
- Staging deploy: `forge-flow-staging-proxy-00020-wk6` is serving 100% of
  traffic. `https://staging-api.feflow.org/readyz` returned 200, and no-token
  probes for `/v1/auth/password/change` and
  `/v1/auth/refresh-tokens/revoke-all` returned 401 rather than 404.
- Additional staging config correction: created and rotated the missing
  `forge-flow-staging-service-principal-jwt-secret` Secret Manager value before
  trusting the deployed revision.
- Follow-up UX latency fix: both sign-out paths now start the auth-session
  ledger revoke in the background instead of waiting for that proxy write before
  returning to signed-out UI. Sign Out Everywhere still waits for the Firebase
  refresh-token revoke because that is the security action promised by the
  button.

Remaining UX/debug work before mentally closing Phase 9:

- Run the staging device walkthrough below with the real staging proxy URL.
- Confirm Firebase sender, subjects, and email action copy in the Firebase console.
- Decide whether browser-complete/manual-return after email actions is acceptable for Phase 9 closure, or track a branded return/deep-link route as the next email-action UX backlog.
- Team invite-only UI is no longer the current local state. The Team settings surface now exposes live user loading, pending invite revoke, and per-user suspend/reactivate/remove access/reset password/role-change actions when the actor has the relevant permissions. Remaining UX decisions are email-action return/deep-link polish, Firebase email template hygiene, MFA enrollment/recovery management, and a real-device narrow-layout pass with staging data.

## Team/Auth UX Exposure Update - 2026-04-29

Implemented after the backend-vs-UI audit:

- Settings > Team now hydrates live users and pending invites from the auth operations gateway.
- The staging proxy now exposes `GET /v1/admin/auth/users` and `GET /v1/admin/auth/invites` for that UI.
- Pending invites can be revoked from the Team tab.
- User rows have a structured action menu for role change, reset password, suspend, reactivate, revoke role, and remove access.
- Role change uses a dialog with role and scope controls instead of raw role-grant ids.
- Invite submission adds the pending invite immediately and then refreshes live Team data.
- Permission-locked Team actions show an access notice instead of raw permission keys.
- The Team section uses bounded scrolling so narrow/mobile Settings layouts do not overflow when the user list or pending invite list is long.

Verified commands:

```powershell
flutter analyze lib\screens\team\team_settings_section.dart lib\screens\settings_screen.dart lib\forge_flow_app.dart lib\services\auth\auth_operations_gateway.dart lib\services\auth\proxy_auth_operations_gateway.dart lib\services\auth\repository_auth_operations_gateway.dart lib\infrastructure\persistence\postgres\repositories\users_repository.dart lib\infrastructure\persistence\postgres\repositories\auth_invites_repository.dart tool\advisor_proxy\advisor_proxy.dart test\team_ux_kernel_test.dart test\proxy_auth_operations_gateway_test.dart test\proxy_auth_operations_route_test.dart
flutter test test\team_ux_kernel_test.dart --plain-name "TeamSettingsSection widget" --reporter compact
flutter test test\proxy_auth_operations_gateway_test.dart --reporter compact
flutter test test\proxy_auth_operations_route_test.dart --plain-name "auth-operation proxy routes" --reporter compact
```

Staging proxy deploy:

- Revision `forge-flow-staging-proxy-00021-bqd` is serving 100% of traffic.
- `https://staging-api.feflow.org/readyz` returned 200 with `{"status":"ok"}`.
- No-token probes for `GET /v1/admin/auth/users` and `GET /v1/admin/auth/invites` returned 401 rather than 404, confirming the routes are live and gated.

## Item 2 Full UX Debug Walkthrough

Goal: validate the Phase 9 auth/team experience as a user-facing staging flow, not just as a backend smoke. This pass should be staging-only and should not touch Production1 users or Firebase state.

### Preparation

1. Use staging only.
2. Confirm the app points at the staging proxy, preferably `https://staging-api.feflow.org`.
3. Use non-repo secrets from `$HOME/.forge_flow/forge_flow.secrets.ps1`; do not paste passwords, tokens, database URLs, or Firebase UIDs into notes.
4. Have at least two staging test users:
   - An admin/owner user who can reach Settings > Team.
   - A disposable invite recipient email account.
5. Keep a small evidence log with columns: flow, account type, device, expected result, actual result, UX notes, screenshot path if useful, pass/fail.

Useful commands:

```powershell
Invoke-WebRequest https://staging-api.feflow.org/readyz
scripts/run_flutter_dev.ps1 -App forgeflow -UseFirebaseAuth -Device <device-id>
scripts/run_flutter_dev.ps1 -App forgeflow -UseFirebaseAuth -PrintCommandOnly
```

Run `flutter devices` first if the device id is unknown. Android or a real mobile viewport is preferred for the primary pass. Chrome is acceptable for fast layout inspection, but the previous Phase 9 smoke evidence used Android debug.

### Flow A: Signed-Out Login Screen

Check before entering credentials:

- Login screen loads without a crash or blank state.
- Title, fields, and button are calm and professional.
- Email keyboard/autofill behavior is sane.
- Password field hides input.
- Empty submit either gives visible guidance or is clearly disabled.
- Error banner space does not jump awkwardly.
- No Firebase, project id, token, proxy, or permission text is visible.

Current code inspection note, updated 2026-04-29: `LoginScreen` exposes email/password/sign-in and a visible `Forgot password?` action. The request path is wired through `AuthSessionNotifier.requestPasswordReset`.

### Flow B: Invalid Login

Try a bad password and a malformed email.

Expected:

- User sees a human message such as `Email or password is incorrect.`
- No raw Firebase code appears.
- No stack trace, HTTP status, permission key, or UID appears.
- User can correct input without restarting the app.

### Flow C: Happy Login

Sign in with the staging smoke/admin user.

Expected:

- Spinner appears while submitting.
- Button cannot double-submit.
- App reaches the authenticated shell.
- No broad MFA prompt unless the account actually requires MFA.
- Session context loads without surfacing raw permission snapshot text.
- Settings can be opened.

### Flow D: Session Persistence

Close and relaunch the app.

Expected:

- User remains signed in.
- App does not flash sensitive internal screens while loading.
- If session rehydration fails, user returns cleanly to sign-in with professional copy.

### Flow E: Logout

Use Settings > Account > Sign out.

Expected:

- Sign out is easy to find.
- The app returns to signed-out state.
- Reopening the app stays signed out.
- No stale authenticated UI remains visible.
- Copy says `Sign out`, not `revoke session`, `auth ledger`, or similar.

### Flow F: Forgot Password / Password Reset

Verify whether a normal signed-out user can request a reset from the UI.

Expected product behavior:

- A visible `Forgot password?` action exists on the login screen.
- The user can enter email and request reset.
- Confirmation copy does not reveal whether the email exists.
- Firebase email arrives with acceptable sender, subject, and copy.
- Reset action completes.
- After reset, user has a clear path back to Forge & Flow.

Current risk:

- The visible signed-out reset request exists and previous staging smoke completed reset, but polished post-email return to the native app is still not implemented as an app route.

### Flow G: Invite Recipient First Password

From an owner/admin staging account, create an invite for a disposable email, then complete it from the recipient side.

Expected:

- Invite action is discoverable in Settings > Team.
- Role labels are human-readable: Owner, Manager, Supervisor, Staff.
- Scope labels are human-readable: Operator, Location.
- Email arrives with professional sender, subject, and button text.
- Recipient can set first password.
- Recipient can sign into the app.
- Recipient lands in the correct permission scope.
- The app does not expose invite ids, Firebase UIDs, auth_invites, or role keys.

### Flow H: Settings > Team Surface

As an owner/admin user:

- Open Settings.
- Verify Team tab is visible only for users with team view permission.
- Search users.
- Filter by status, role, and location.
- Clear filters.
- Check empty state.
- Invite with missing email, malformed email, missing role, missing scope, and missing location for a location-scoped invite.
- Submit a valid invite.

Expected:

- Validation copy is short and understandable.
- Buttons do not resize awkwardly during loading.
- Status labels look professional.
- Raw statuses such as `operator_wide`, `operator_staff`, `role_key`, `location_id`, or UUIDs do not appear.
- `VISIBLE` / `INVITES` chips should be reviewed for tone; they are accurate but may feel more debug/admin than customer-polished.

### Flow I: Permission-Denied And Lower-Role Experience

Sign in as a lower-permission user if available.

Expected:

- Team tab is hidden if the user cannot view Team.
- Forbidden actions are hidden or disabled with helpful copy.
- No blank awkward area appears where the Team section would be.
- No 401/403, permission key, or policy name is shown to the user.

### Flow J: MFA / Recovery

Use an MFA-enabled disposable staging user if available.

Expected:

- MFA challenge screen appears only when needed.
- Copy says `Two-factor verification`.
- Authenticator code entry works; no recovery-code toggle is exposed.
- Invalid/expired code gives human copy.
- Cancel signs out cleanly.
- Admin-contact recovery copy fits on small screens.

### Flow K: Mobile And Narrow Layout

Check at least:

- Android device or emulator.
- Narrow width around 360 px.
- Tablet/desktop-ish width if Chrome is used.

Focus areas:

- Login form width.
- Error banners.
- Settings tabs.
- Team filters and invite panel wrapping.
- Team table row overflow, especially long emails.
- Buttons and segmented controls.

### Flow L: Copy And Naming Sweep

Search the visible UI for:

- `Firebase`
- `RLS`
- `operator_id`
- `location_id`
- `role_key`
- `operator_owner`
- `operator_manager`
- `operator_supervisor`
- `operator_staff`
- `B17`, `B42`, or migration names
- raw UUIDs
- HTTP 401/403 style messages

Acceptable user-facing labels:

- Owner
- Manager
- Supervisor
- Staff
- Invited
- Active
- Suspended
- Expired
- Revoked
- Operator
- Location
- Sign in
- Sign out
- Send invite
- Reset password

### Closeout Criteria

Mark Item 2 complete when:

- Login happy path passes.
- Invalid login copy is user-friendly.
- Session persistence and logout pass.
- Invite recipient first-password flow passes.
- Settings > Team is usable on staging.
- Lower-permission behavior is clean.
- No raw internal terminology appears in normal user flows.
- Mobile/narrow layout has no broken text or controls.
- Forgot-password visibility is either fixed now or explicitly recorded as a Phase 9 accepted limitation.
- Post-email return behavior is either accepted as browser-complete/manual-return or recorded as the next email-action UX backlog.
