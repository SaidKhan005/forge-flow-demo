# C — Email + Notification Scenario Inventory

Created 2026-05-12 as the test-plan catalog for the upcoming post-codex-wave
pressure-test pass. The initial 2026-05-12 pass was a **read-only audit**
where no code paths were modified. A2.2 updated this inventory to reflect
implementation decisions: two superseded Markdown templates and renderer ids
were deleted, and B3-shipped fanout templates were reclassified as wired.
C-2-Del (2026-05-13) deleted two more — `vendor_webhook_signature_alert`
(Draft E) and `tos_version_updated_notice` (Draft G) — per the C-2 operator
picks (Cloud Logging covers signature failures; in-app accept-screen gate
covers TOS updates).

Scope: every email and every in-app / push / inbox notification site
in the Forge & Flow codebase, plus the F&F admin / proxy paths that
fan them out. Includes both **wired** scenarios (fully routed end-to-
end today) and **template-only** scenarios (Markdown ships, no
enqueuer wired yet — flagged inline so the pressure test does not chase
a stub).

Categories below:

1. Auth (password reset, sign-in oracle, action-page deep link)
2. Invite (admin / first-admin / operator-owner bootstrap)
3. MFA (factor changed, recovery, admin reset)
4. Vendor lifecycle (now-available, sync error, webhook signature, auto-disabled)
5. Backfill lifecycle (first-connect complete / failed)
6. Audit (chain-anchor failure)
7. Operator support / Admin (admin "Test connection", admin-initiated password reset)
8. TOS / Account (TOS-updated notice, account changes)
9. Schedule / In-app (weekly plan snapshot, cycle rollover, MFA inbox)
10. Push runtime plumbing (token register / revoke / refresh, self-test, foreground / background / terminated delivery)
11. UI surfaces only (snackbar, peer-edit toast, bell badge, push permission card)

Wire-status legend used in the tables:

- **Wired** — enqueuer + dispatcher + template all live in production paths.
- **Template-only** — Markdown template + subject locked, no enqueuer in the codebase yet (Phase 8 lean cut + 9.8 follow-up deferred per `lib/services/email/email_template_renderer.dart` doc strings).
- **Hook-only** — fanout helper shipped in `notification_event_hooks.dart`; trigger site not yet calling it (or template file missing).

File paths are absolute under
`C:\Git Local Repos\forge_flow_demo\.claude\worktrees\nifty-clarke-d3ec25\`.
Line numbers verified at audit time and may drift as code changes.

---

## 1. Auth — Password Reset (self-serve + Firebase action-link)

| Field | Value |
| --- | --- |
| Category | Auth |
| Trigger | Operator taps "Forgot password?" on the login screen (mobile or web) OR posts `POST /v1/auth/password/reset/request` directly. |
| Sender code path (request) | `lib\services\auth\password_reset_request_gateway.dart:122` (`RepositoryPasswordResetRequestGateway.requestReset` → calls `firebaseAdmin.sendPasswordResetEmail` at line 148). Proxy route registered via `tool\advisor_proxy\advisor_proxy.dart` (path `/v1/auth/password/reset/request`). Client gateway: `lib\services\auth\proxy_password_reset_gateway.dart`. |
| Sender code path (confirm) | `lib\services\auth\password_reset_confirm_gateway.dart` + `lib\services\auth\proxy_password_reset_gateway.dart` (`POST /v1/auth/password/reset/confirm`). |
| Recipient | Operator-owned email; **always** called (whether the email matches an active account or not — privacy-preserving silent-succeed when Firebase returns `EMAIL_NOT_FOUND`). |
| Payload / template | **Firebase Identity Platform action-link template** (HTML rendered by Firebase, NOT a SendGrid send through `email_outbox`). Subject is the Firebase project's configured "Password reset" template; see `runbooks\firebase_auth_email_templates_production1.md` + `scripts\configure_firebase_auth_email_action_url.ps1`. A2.2 deleted the repo-owned `password_reset_request.md` Markdown copy because the Firebase template is the only password-reset email path. |
| Target action / URL | Action-link `https://forgeflow.app/auth/action?mode=resetPassword&oobCode=…&apiKey=…&continueUrl=…` (lives in `scripts\configure_firebase_auth_email_action_url.ps1`). |
| Loopback | `web\auth\action\index.html` handles both `verifyEmail` and `resetPassword`. On mobile UA detection, it builds the deep-link `forgeflow://reset-password?mode=resetPassword&oobCode=...` and bounces to the app (`web\auth\action\index.html:443-446`). The Flutter side intercepts via `lib\services\auth\password_reset_deep_link_source.dart` → `lib\screens\auth\password_reset_deep_link_handler.dart` → `lib\screens\auth\password_reset_confirm_screen.dart`, then submits the new password through `proxy_password_reset_gateway.confirmReset`. Web users complete the form in `index.html` directly. |
| Test coverage | `test\services\auth\password_reset_request_gateway_test.dart`; `test\services\auth\password_reset_confirm_gateway_test.dart`; `test\services\auth\password_reset_end_to_end_test.dart`; `test\services\auth\proxy_password_reset_gateway_test.dart`; `test\screens\auth\password_reset_request_screen_test.dart`; `test\screens\auth\password_reset_confirm_screen_test.dart`; `test\screens\auth\password_reset_deep_link_handler_test.dart`; `test\web_auth_action_page_test.dart`. Throttling: `test\services\auth\magic_link_rate_limit_test.dart`; lockout integration: `test\proxy\auth_lockout_routes_test.dart`. |
| Notes | A2.2 delete decision: the internal `password_reset_request` Markdown template and `EmailTemplateIds.passwordResetRequest` entry were removed. All real password-reset emails come from the Firebase Identity Platform template. Subject + body wording for the wire-template are in the Firebase project config, not in repo Markdown. Pressure scenarios that exercise the deep-link bounce and the privacy-preserving "always-call-Firebase" path are the priority. |

## 1.b Auth — Email Verification action link

| Field | Value |
| --- | --- |
| Category | Auth |
| Trigger | Firebase auto-generated when a user signs up / changes email (web SDK or Admin SDK). No first-party code call site found in the repo today. |
| Sender code path | Firebase-managed (`mode=verifyEmail` branch handled at `web\auth\action\index.html:392-407`). |
| Recipient | User who triggered the email change. |
| Payload / template | Firebase Identity Platform's verifyEmail template. |
| Target action | Web action page applies the code via `applyActionCode(auth, oobCode)` and shows confirmation. |
| Loopback | Web-only; sends user back to login screen on success. |
| Test coverage | `test\web_auth_action_page_test.dart` (covers the verifyEmail branch alongside resetPassword). |
| Notes | No first-party trigger today — handled if Firebase emits the email; no `sendEmailVerification` call site exists in `lib/`. Listed for completeness. |

---

## 2. Invite — Admin / First-admin / Operator-owner bootstrap

| Field | Value |
| --- | --- |
| Category | Invite |
| Trigger | F&F admin or operator owner submits `POST /v1/admin/auth/invites` (operator-owner bootstrap) or `POST /v1/auth/operators/.../users/invite` (operator-admin invite) via Operator Web Members screen or Admin Members screen. |
| Sender code path | `lib\services\auth\repository_auth_operations_gateway.dart:364-485` (`createInvite`). At line **463** it calls `firebaseAdmin.sendPasswordResetEmail(email: command.email)` after `usersRepository.insertInvitedUser` + `authInvitesRepository.insertInvite`. Proxy callers: `tool\advisor_proxy\proxy_bootstrap.dart:3374` (operator-owner bootstrap) and `tool\advisor_proxy\advisor_proxy.dart:10839` (admin members invite). |
| Recipient | The invited team member's email (operator-owner, operator-admin, location-manager, etc., depending on `roleId`). |
| Payload / template | **Same Firebase password-reset action-link template** as Auth #1 above. A2.2 deleted the unwired `operator_admin_invite.md` SendGrid copy and its `EmailTemplateIds.operatorAdminInvite` entry. The repo still carries `operator_invite_first_admin.md` because the admin email test route uses it as a direct SendGrid connectivity fixture; it is not the production invite path. |
| Target action / URL | Same action-link as Auth #1 → `web\auth\action\index.html` → either form-fill on web or deep-link `forgeflow://reset-password?...` on mobile. |
| Loopback | Invited user picks a password, signs in. `lib\infrastructure\persistence\postgres\repositories\invited_user_activation_repository.dart:45-153` (`acceptPendingInviteAfterLogin`) flips `users.status = 'active'`, marks `auth_invites.accepted_at`, writes `auth.invite_accepted` audit row. |
| Test coverage | `test\infrastructure\persistence\postgres\repositories\auth_invites_repository_test.dart`; `test\proxy_auth_operations_route_test.dart`; `test\proxy_auth_operations_route_grants_test.dart`; `test\admin\services\members_admin_gateway_test.dart`; `test\admin\screens\members_admin_screen_test.dart`; `test\operator_web\screens\members_screen_test.dart`; `test\user_lifecycle_test.dart`; `test\operator_web\screens\permission_explainer_screen_test.dart`. **No test** asserts the "invite-via-reset-email" path through `firebaseAdmin.sendPasswordResetEmail` end-to-end (it is mocked at the boundary). |
| Notes | Invites carry 7-day TTL (`lib\services\auth\user_invite_service.dart:71`). Pressure scenarios to plan: retry of `createInvite` after Firebase send (idempotency via `proxy_requests` UNIQUE), partial failure where Firebase succeeds but Postgres rolls back, expired invite acceptance, double-accept race. A2.2 resolves the `operator_admin_invite` dual-path scaffold by keeping Firebase as the production invite email and deleting the unused SendGrid Markdown/id. |

---

## 3. MFA — Factor Changed Notice (template-only) + Authenticator Removed (in-app inbox)

### 3.a MFA factor changed (email)

| Field | Value |
| --- | --- |
| Category | MFA |
| Trigger | MFA factor enrolled / removed / replaced. Intended emitter not yet wired. |
| Sender code path | **No enqueuer in the codebase.** Template-only. Template file: `tool\advisor_proxy\email_templates\mfa_factor_changed_notice.md`. Subject locked at `email_template_renderer.dart:149` → `"Your Forge & Flow MFA has been updated"`. |
| Recipient | Account owner. |
| Payload / template | Template variables: `recipientName`, `occurredAtHumanReadable`, `changeDescription`, `accountSecurityUrl`. |
| Target action | `accountSecurityUrl` (no fixed value in the repo — populated by the unwired emitter). |
| Loopback | None today. |
| Test coverage | Renderer-only: `test\services\email\email_template_renderer_test.dart` iterates `EmailTemplateIds.all` and renders each with sample data. No end-to-end test because no emitter exists. |
| Notes | Pressure plan: defer until enqueuer ships. Treat as **template-only**. |

### 3.b MFA authenticator removed (in-app inbox)

| Field | Value |
| --- | --- |
| Category | MFA |
| Trigger | The MFA removal worker (`lib\mfa\mfa_removal_worker`) completes a removal request the operator-authored. The Settings MFA section observes the worker and fires the inbox emit. |
| Sender code path | `lib\screens\settings\settings_mfa_section.dart:582` (`AppNotificationService.instance.emitMfaAuthenticatorRemoved`). Implementation: `lib\services\app_notification_service.dart:114-134`. |
| Recipient | The user whose factor was removed (in-app inbox under the active restaurant scope; bell-badge ticks). |
| Payload | Title: `"Authenticator App Removed"`. Body: `"Two-factor authentication was removed. Add a new authenticator app if this was unexpected."`. Persists into `app_notifications` with `event_key = "mfa_authenticator_removed_${userId}_${requestId}"`. |
| Target action | Open Settings → MFA section. |
| Loopback | Operator opens the in-app notifications screen (`lib\screens\notifications_screen.dart`), tile mark-as-read decrements badge via `unreadCountNotifier`. |
| Test coverage | `test\settings_mfa_section_test.dart`; `test\app_notification_service_test.dart`; `test\screens\notifications_screen_mark_read_test.dart`. |
| Notes | Dedupe via SQLite UNIQUE `(restaurant_id, event_key)`. |

### 3.c MFA admin-driven reset (admin support action)

| Field | Value |
| --- | --- |
| Category | MFA |
| Trigger | F&F admin clicks Reset MFA on the Audited Support Actions screen for a member. |
| Sender code path | `lib\admin\services\audited_support_actions_admin_gateway.dart:467` (`resetMemberMfa` → `POST /v1/admin/auth/users/.../reset-mfa`). The proxy clears MFA enrollments and writes an `admin_action_log` row. **No email is sent today.** Member learns next sign-in by being prompted to re-enroll. |
| Recipient | The target member (next sign-in prompt). |
| Test coverage | `test\admin\services\audited_support_actions_admin_gateway_test.dart`; `test\admin\screens\audited_support_actions_admin_screen_test.dart`. |
| Notes | Audit log only; not an email scenario. Listed because pressure plan may add one. |

---

## 4. Vendor lifecycle — Now-available (WIRED) + 3 template-only

### 4.a Vendor became available — `notif.vendor.now_available`

| Field | Value |
| --- | --- |
| Category | Vendor lifecycle |
| Trigger | Vendor lifecycle promotes to `productionCredentialed`. Admin posts `POST /v1/admin/vendors/:vendor_id/lifecycle-promotion-notification` (routes: `tool\advisor_proxy\email_dispatch\vendor_lifecycle_promotion_routes.dart`). |
| Sender code path | `tool\advisor_proxy\email_dispatch\vendor_lifecycle_notification_dispatcher.dart:295` (`dispatchForVendor`). Walks pending rows in `vendor_lifecycle_notification` (per-(operator, vendor) opt-in from the picker's "Notify me when ready" button — see `lib\operator_web\widgets\vendor_lifecycle_notify_me_dialog.dart`). For each row, enqueues an `email_outbox` row using `EmailTemplateIds.vendorNowAvailable` AND, when wired, fans out push + inbox via `NotificationEventFanout.fanOut` (see `notification_event_fanout.dart:352`). |
| Recipient | Email column on each pending `vendor_lifecycle_notification` row, plus every user in the operator whose `notification_preferences` admits the matching channel (push / email / inbox) — role gate: `any`. |
| Payload / template | Subject `{{vendorName}} is ready to connect in Forge & Flow`. Template file: `tool\advisor_proxy\email_templates\vendor_now_available.md`. Push: title `${vendorName} is now available`, body `You can connect ${vendorName} from the integrations console.` Variables: `recipientName`, `vendorName`, `businessName`, `integrationConsoleUrl`. |
| Target action / URL | `integrationConsoleUrl` — bound to the operator-web vendor-picker deeplink for the operator's home location. |
| Loopback | Operator opens **Connected services** card → vendor row → Connect. Picker entry-point at `lib\operator_web\screens\vendor_connections_screen.dart`. |
| Test coverage | `test\services\email\vendor_lifecycle_notification_dispatcher_test.dart`; `test\proxy\vendor_lifecycle_promotion_routes_test.dart`; `test\proxy\vendor_lifecycle_recently_available_routes_test.dart`; `test\operator_web\screens\vendor_connections_recently_available_test.dart`; `test\operator_web\screens\vendor_connections_screen_test.dart`. Fanout: `test\services\email\notification_event_fanout_test.dart`. |
| Notes | Idempotent on retry (filter `notified_at IS NULL` + stamp on success). Email is fanout-tolerant — fanout failures do not block the per-row email enqueue. The dispatcher walks one operator at a time so the operator-leading index stays engaged. **Wired**. |

### 4.b Vendor sync error alert (template-only)

| Field | Value |
| --- | --- |
| Category | Vendor lifecycle |
| Trigger | Sustained vendor sync failure (intended for the polling tier / OAuth refresh worker to detect). |
| Sender code path | **No enqueuer in the codebase.** Template-only. |
| Recipient | Operator owners / admins with the connection (intended). |
| Payload / template | Subject `Forge & Flow could not sync from {{vendorName}}`. Template: `tool\advisor_proxy\email_templates\vendor_sync_error_alert.md`. Variables: `recipientName`, `vendorName`, `firstFailureHumanReadable`, `errorSummary`, `integrationConsoleUrl`, `escalationWindowHumanReadable`. |
| Target action | Connected services card. |
| Test coverage | Renderer-only. |
| Notes | Deferred per Phase 8 lean cut (`lib\services\email\email_template_renderer.dart:108-110` doc). |

### 4.c Vendor webhook signature alert — **DELETED via C-2-Del (2026-05-13)**

| Field | Value |
| --- | --- |
| Category | Vendor lifecycle |
| Trigger | N failed webhook signature verifications within an observation window. |
| Sender code path | C-2-Del deleted the template (`vendor_webhook_signature_alert.md`) + `EmailTemplateIds.vendorWebhookSignatureAlert` constant + subject map entry + pressure inventory row. Per operator pick (C-2 matrix Draft E), Cloud Logging alerts cover signature failures; signature-verifier unit tests cover the verifier itself. No centralized failed-signature counter was built. |
| Payload / template | Removed. |
| Test coverage | Renderer suite no longer iterates this id; webhook-signature verification itself retains unit tests under `test\integrations\**\*_webhook_signature_verifier_test.dart`. |
| Notes | If adversarial webhook activity is observed post-launch, the operator can re-instate the template + build a centralized counter at that point. Source: `docs\_decisions\c_2_email_template_wire_or_delete_decisions.md` Draft E. |

### 4.d Vendor connection auto-disabled (template-only)

| Field | Value |
| --- | --- |
| Category | Vendor lifecycle |
| Trigger | 3 consecutive OAuth refresh failures auto-disable a vendor connection (OAuth-refresh-cron at `lib\services\integration\oauth_refresh_cron.dart`). |
| Sender code path | **No enqueuer in the codebase.** OAuth refresh cron flips connection status to `error` but does not enqueue. Documented as deferred at `lib\services\email\email_template_renderer.dart:96-107`. |
| Payload / template | Subject `{{vendorName}} connection disabled`. Template: `tool\advisor_proxy\email_templates\vendor_connection_auto_disabled.md`. Variables: `recipientName`, `vendorName`, `disabledAtHumanReadable`, `strikeCount`, `lastErrorSummary`, `integrationConsoleUrl`. |
| Test coverage | Renderer-only; refresh-cron behavior: `test\integration\oauth_refresh_cron_test.dart`. |
| Notes | Operator currently learns by seeing `error` chip on the Connected services card. |

---

## 5. Backfill lifecycle — `notif.backfill.complete` + `notif.backfill.failed`

| Field | Value |
| --- | --- |
| Category | Backfill lifecycle |
| Trigger | First-connect 60-day backfill job hits terminal state. |
| Sender code path | Hook helpers live at `tool\advisor_proxy\email_dispatch\notification_event_hooks.dart:71` (`emitBackfillComplete`) and `:114` (`emitBackfillFailed`). Trigger sites declared at the hook doc strings: `tool\integration_sync_worker\backfill_dispatch.dart` (`markSucceeded`) and `tool\first_connect_backfill_worker\main.dart` (`RetryCappingBackfillJobStore.markFailed`). Both call into `NotificationEventFanout.fanOut`. |
| Recipient | All users in the operator who satisfy role gate `any` and whose preference matrix admits the channel (push / email / inbox). Default channels: `push`, `email`. |
| Payload — push | Complete: title `Historical sync complete`, body `Your 60-day historical seed has finished and the connector is now live.` Failed: title `Historical sync needs attention`, body `Your 60-day historical seed could not finish. We will retry automatically and let you know if it needs you.` |
| Payload — email | Templates `backfill_complete` / `backfill_failed` are present in `tool\advisor_proxy\email_templates\`, registered in `EmailTemplateIds.all`, and emitted through the B3 `NotificationEventFanout` hook path. **Wired.** |
| Target action / Deeplink | Optional, supplied per call. Trigger sites pass null today. |
| Loopback | Operator opens inbox → finds backfill complete / failed entry → taps → routed to integration screen. |
| Test coverage | `test\services\email\notification_event_hooks_test.dart`; `test\services\email\notification_event_fanout_test.dart`; `test\tool\integration_sync_worker\backfill_dispatch_notification_hook_test.dart`; `test\services\backfill\backfill_dispatch_audit_emission_test.dart`. |
| Notes | A2.2 inventory reconciliation: the prior hook-only/template-missing note is stale on current master because B3 shipped the Markdown files, renderer ids, hook tests, and trigger-site tests. Pressure testing can include the email channel for these two events. |

---

## 6. Audit — `notif.audit.anchor_failure`

| Field | Value |
| --- | --- |
| Category | Audit |
| Trigger | Daily audit-anchor cron failure: `AnchorOutcome.chainHashMismatch`, `AnchorOutcome.recoveredFailed`, or Azure-Blob-unavailable catch in `tool\audit_anchor\main.dart` (`_runAnchorMode` / `_runSweepMode`). |
| Sender code path | Hook: `tool\advisor_proxy\email_dispatch\notification_event_hooks.dart:158` (`emitAuditAnchorFailure`). Trigger sites: `tool\audit_anchor\main.dart`. Fanout via `NotificationEventFanout.fanOut`. |
| Recipient | Operator owners + admins (role gate: `adminOnly`). Default channels: `push`, `email`. |
| Payload — push | Title `Audit chain anchor needs review`, body `A daily audit-log integrity anchor did not land. This never blocks operations, but the team should know.` |
| Payload — email | Template id `audit_anchor_failure` is present in `tool\advisor_proxy\email_templates\`, registered in `EmailTemplateIds.all`, and emitted through the B3 `NotificationEventFanout` hook path. **Wired.** |
| Target action | None hardcoded; operator-web admin would open the Audit log screen (`lib\operator_web\screens\audit_log_screen.dart`). |
| Test coverage | `test\services\email\notification_event_hooks_test.dart`; `test\proxy\audit_chain_anchors_routes_test.dart`; `test\infrastructure\persistence\postgres\audit_anchor_cron_schedule_test.dart`. |
| Notes | A2.2 inventory reconciliation: the prior template gap is stale on current master because B3 shipped the Markdown file, renderer id, hook test, and audit-anchor trigger-site test. Pressure testing can include the email channel. |

---

## 7. Operator support / Admin

### 7.a Admin "Test connection" send (admin-initiated SendGrid test)

| Field | Value |
| --- | --- |
| Category | Operator support / Admin |
| Trigger | F&F super_admin posts `POST /v1/admin/integrations/email/test` from the Integration Admin screen (`lib\admin\screens\integration_admin_screen.dart`). |
| Sender code path | `tool\advisor_proxy\admin_email_routes.dart:140` (`AdminEmailRouter.tryHandle`). Renders `EmailTemplateIds.operatorInviteFirstAdmin` with sample data (`_testTemplateData` at line 59-64) and calls `EmailProvider.send` directly (NOT via `email_outbox`). |
| Recipient | Either the body's `recipient_email` (if present) or `EMAIL_TEST_RECIPIENT` env var. |
| Payload / template | Subject `Welcome to Forge & Flow — set up your account` (rendered with `recipientName='F&F Test Admin'`, `businessName='Forge & Flow Demo'`, `setupUrl='https://app.forgeflow.app/onboarding/test'`, `linkExpiryHumanReadable='in 24 hours'`). |
| Target action / URL | The placeholder `setupUrl` is non-functional (it's a smoke test). |
| Loopback | None — admin verifies SendGrid 2xx + receives the test email. |
| Test coverage | `test\proxy\auth_lockout_routes_test.dart` (touches the route's auth gate); `test\services\email\sendgrid_email_provider_test.dart`; `test\services\email\email_provider_test.dart`. **No dedicated test for the route handler itself** (handler lives in `admin_email_routes.dart`; the marked region in `tool\advisor_proxy\main.dart:814` mounts it). |
| Notes | Auth: `super_admin` only. Idempotency: respected via `AdminRequestIdempotencyStore`. Bypasses `email_outbox` so the admin sees synchronous feedback. |

### 7.b Admin-initiated password reset

| Field | Value |
| --- | --- |
| Category | Operator support / Admin |
| Trigger | F&F admin clicks **Initiate password reset** on the Audited Support Actions screen (`lib\admin\screens\audited_support_actions_admin_screen.dart`). |
| Sender code path | `lib\admin\services\audited_support_actions_admin_gateway.dart:685` (`HttpAuditedSupportActionsAdminGateway.initiatePasswordReset`) → `POST /v1/admin/auth/users/{user_id}/password-reset`. Proxy route resolves the email and calls `firebaseAdmin.sendPasswordResetEmail` (same wire-template as Auth #1). |
| Recipient | The target user's email. |
| Payload / template | Same Firebase action-link template as Auth #1. |
| Target action / URL | Same action-link → `web\auth\action\index.html`. |
| Loopback | Same as Auth #1 (user resets password). |
| Test coverage | `test\admin\services\audited_support_actions_admin_gateway_test.dart`; `test\admin\screens\audited_support_actions_admin_screen_test.dart`. Demo path: `lib\admin\services\demo_audited_support_actions_admin_gateway.dart`. |
| Notes | The runbook `runbooks\proxy_redeploy_reset_confirm_account_info_runbook.md` covers the deploy path. Always writes an `admin_action_log` row. |

---

## 8. TOS / Account — `tos_version_updated_notice` — **DELETED via C-2-Del (2026-05-13)**

### 8.a TOS version published

| Field | Value |
| --- | --- |
| Category | TOS / Account |
| Trigger | F&F admin publishes a new TOS version row in `tos_versions` (migration `db\migrations\202605040100_phase_9_8_tos_versions.sql`). |
| Sender code path | C-2-Del deleted the template (`tos_version_updated_notice.md`) + `EmailTemplateIds.tosVersionUpdatedNotice` constant + subject map entry + pressure inventory row. Per operator pick (C-2 matrix Draft G), the runtime gate at `lib\operator_web\screens\tos_accept_screen.dart` is the sole TOS-update operator signal — operators are required to accept the new version the next time they sign in. The email channel is removed. |
| Payload / template | Removed. |
| Target action | Operators sign in next time and hit the TOS-accept screen. |
| Loopback | TOS-accept screen lives at `lib\operator_web\screens\tos_accept_screen.dart`; acceptance is gated by the operator-web auth source `OperatorWebTosGateway`. |
| Test coverage | Acceptance gate: `test\operator_web\operator_web_router_test.dart`; `test\operator_web\onboarding_screens_test.dart`. Renderer suite no longer iterates this id. |
| Notes | If a TOS publish workflow ships later, the template can be re-added alongside it. Source: `docs\_decisions\c_2_email_template_wire_or_delete_decisions.md` Draft G. |

---

## 9. Schedule / In-app inbox (passive notifications)

### 9.a New weekly plan snapshot locked

| Field | Value |
| --- | --- |
| Category | Schedule |
| Trigger | A new `WeeklyPlanSnapshot` row is locked (`lib\services\weekly_plan_snapshot_service.dart`). |
| Sender code path | `lib\services\weekly_plan_snapshot_service.dart:190` (`AppNotificationService.instance.emitNewWeekSnapshot`). Implementation: `lib\services\app_notification_service.dart:68-87`. |
| Recipient | Current active restaurant scope (in-app inbox). |
| Payload | Title `New Weekly Plan Locked`. Body `Weekly operating plan for {weekStart} to {weekEnd} is now active.` Event key dedupes on `(restaurantId, weekStart, weekEnd)`. |
| Target action | Open notifications screen → tile leads to dashboard / weekly plan. |
| Loopback | In-app only; bell badge + mark-read. |
| Test coverage | `test\app_notification_service_test.dart`; `test\screens\notifications_screen_mark_read_test.dart`. |
| Notes | Catalog event `notif.plan.updated` exists (`lib\domain\models\notification_event_catalog.dart:153`) with `managerOnly` gate + default `push`, but no Postgres-side trigger calls `NotificationEventFanout.fanOut` from the snapshot service today. **Hook-only** for push side; inbox WIRED. |

### 9.b 60-day target cycle rollover

| Field | Value |
| --- | --- |
| Category | Schedule |
| Trigger | `TargetCycleService` rolls a new 60-day cycle into effect (`lib\services\target_cycle_service.dart:110`). |
| Sender code path | `AppNotificationService.instance.emitCycleRollover` → `lib\services\app_notification_service.dart:93-112`. |
| Payload | Title `Target Cycle Refreshed`. Body `A new 60-day target cycle starting {cycleEffectiveStart} is now active.` |
| Target action | Open dashboard. |
| Test coverage | `test\app_notification_service_test.dart`. |
| Notes | In-app inbox only. No catalog event registered. |

### 9.c Open-shift staleness — `notif.shift.stale`

| Field | Value |
| --- | --- |
| Category | Schedule (live shift) |
| Trigger | Phase 10b open-shift live snapshot exceeds staleness threshold (not shipped yet). |
| Sender code path | **Not wired.** Catalog entry at `lib\domain\models\notification_event_catalog.dart:134` (managerOnly, default push). FOLLOW-UP listed at `tool\advisor_proxy\email_dispatch\notification_event_fanout.dart:667-672`. |
| Test coverage | None. |
| Notes | Future event; flag for pressure-test plan only. |

### 9.d Manager override applied — `notif.star.override`

| Field | Value |
| --- | --- |
| Category | Schedule (live shift) |
| Trigger | An operator commits a manager override on a Star recommendation (Phase 11b advisor surface). |
| Sender code path | **Not wired.** Catalog entry: `notification_event_catalog.dart:144` (any, default push). FOLLOW-UP at `notification_event_fanout.dart:672-676`. |
| Test coverage | None. |
| Notes | Future event. |

---

## 10. Push runtime plumbing (FCM)

### 10.a Mobile push token register / refresh / revoke

| Field | Value |
| --- | --- |
| Category | Push runtime |
| Trigger | App start (or context change) → FCM yields a token → mobile client POSTs it; cold sign-out → revoke; FCM `onTokenRefresh` → update. |
| Sender code path | Client: `lib\services\mobile_push\mobile_push_notification_service.dart` (`MobilePushNotificationCoordinator._syncRegistration` line 676; `_handleTokenRefresh` line 648; `_deleteRegisteredToken` line 694). HTTP gateway: `ProxyMobilePushTokenGateway` lines 301-384 → `POST /v1/auth/mobile/push-token/register` and `POST /v1/auth/mobile/push-token/revoke`. Proxy side: `tool\advisor_proxy\mobile_push_notifications.dart` (`RepositoryMobilePushTokenGateway`). |
| Recipient | n/a — token persisted in `mobile_push_tokens` table. |
| Payload | Body: `{ token, platform, provider, app_variant, app_environment, installation_id, client_info: { source, location_id } }`. |
| Test coverage | `test\mobile_push_notification_service_test.dart`; `test\services\mobile_push_sender_test.dart`; `test\services\mobile_push\cold_start_persistence_test.dart`; `test\services\auth\firebase_auth_runtime_bindings_mobile_push_gating_test.dart`; `test\proxy\mobile_push_routes_test.dart`; `test\db\mobile_push_repositories_test.dart`; `test\db\mobile_push_notifications_migration_test.dart`. |
| Notes | Feature-flagged via `--dart-define=MOBILE_PUSH_NOTIFICATIONS_ENABLED=true` (`firebase_auth_runtime_bindings.dart:117`). Returns `NoopMobilePushTokenGateway` when disabled. |

### 10.b Mobile push self-test send

| Field | Value |
| --- | --- |
| Category | Push runtime |
| Trigger | Operator (in the app) requests a phone-popup self-test from Settings. |
| Sender code path | Proxy: `tool\advisor_proxy\mobile_push_notifications.dart:128` (`RepositoryMobilePushSelfTestGateway.sendSelfTest`) → calls `FcmHttpV1MobilePushSender.send` directly to `fcm.googleapis.com/v1/projects/.../messages:send`. |
| Recipient | The signed-in user's tokens (all matching `app_variant` + `app_environment`). |
| Payload | Title `Forge & Flow notification test` (default), body `Your phone popup path is connected.` Data: `{ notification_id: 'mobile_push_self_test', source_topic: 'mobile_push.self_test' }`. Deeplink: `forgeflow://notifications`. |
| Target action / Loopback | Tap → mobile FCM handler routes intent → opens Notifications screen. |
| Test coverage | `test\services\mobile_push_sender_test.dart`; `test\proxy\mobile_push_routes_test.dart`; `test\mobile_push_notification_service_test.dart`. |
| Notes | Bypasses the `mobile_push_outbox` pipeline (synchronous send). |

### 10.c Production outbox dispatch (FCM HTTP v1)

| Field | Value |
| --- | --- |
| Category | Push runtime |
| Trigger | `pg_cron` ticks `mobile_push_outbox`; dispatcher walks pending rows. |
| Sender code path | `tool\advisor_proxy\mobile_push_notifications.dart:299` (`MobilePushDispatcher.dispatch`) → enumerates sendable tokens via `MobilePushTokensRepository.listSendableTokensForUser`, calls `FcmHttpV1MobilePushSender.send` per token, marks outbox row via `markResult`. |
| Recipient | Per-user tokens. |
| Payload | Whatever the upstream emitter wrote into the outbox row (`title`, `body`, `data`, `deeplink`, `message_id`, `dedupe_key`, optional `source_topic`). |
| Loopback | Foreground delivery → in-app banner via `flutter_local_notifications`; background tap → opens app at notifications screen; terminated tap → `getInitialMessage` is read at startup and routed. |
| Test coverage | `test\services\mobile_push_sender_test.dart`; `test\proxy\mobile_push_routes_test.dart`; `test\db\mobile_push_repositories_test.dart`. Foreground / cold-start: `test\services\mobile_push\cold_start_persistence_test.dart`. Inbox-sink mirror: `test\services\app_notification_service_push_delivery_test.dart`. |
| Notes | Dedupe via `mobile_push_outbox` UNIQUE `(operator_id, dedupe_key)`. Failure-spike alert: `infrastructure\monitoring\alerts\fcm_delivery_failure_spike.yaml`. |

### 10.d FCM foreground / background / terminated delivery

| Field | Value |
| --- | --- |
| Category | Push runtime |
| Trigger | Phone receives an FCM message while app is foreground / background / terminated. |
| Sender code path | `lib\services\mobile_push\firebase_mobile_push_runtime.dart` — `forgeFlowFirebaseMessagingBackgroundHandler` (line 18); `defaultMobilePushInboxSink` (line 73) lands the message into `app_notifications` via `AppNotificationService.instance.emitPushDelivery`. Coordinator: `lib\services\mobile_push\mobile_push_notification_service.dart` — `_showForegroundNotification` (line 713), `_handleMessageOpen` (line 741), `start` → `getInitialMessage` (line 614). |
| Target action / Deeplink | `data['deeplink']` (if present) routes the operator within the app. Fallback: notifications screen. |
| Loopback | Inbox row created via `emitPushDelivery`, badge ticks via `AppNotificationService.unreadCountNotifier`. Bell badge subscribers: `lib\forge_flow_app.dart:1342-1409`. |
| Test coverage | `test\services\app_notification_service_push_delivery_test.dart`; `test\services\mobile_push\cold_start_persistence_test.dart`; `test\mobile_push_notification_service_test.dart`. |

---

## 11. UI surfaces only (no email / no push)

### 11.a Peer-edit toast (10a.UX.1 — SnackBar on realtime cross-edit frame)

| Field | Value |
| --- | --- |
| Category | Other (UI) |
| Trigger | Realtime subscription emits a `shared_state.<operator_id>.<table>` frame; the shell-level `PeerEditToast` widget surfaces a transient SnackBar. |
| Sender code path | `lib\widgets\peer_edit_toast.dart` (subscribes to `RealtimeEvent` stream from `lib\state\realtime_event_bus.dart`). |
| Loopback | None — visual only. |
| Test coverage | `test\widget\peer_edit_toast_test.dart`; `test\widget\peer_edit_toast_provider_integration_test.dart`; `test\widget\realtime_producer_wiring_test.dart`. |
| Notes | 2-second SnackBar; no deeplink. Pressure test: race between SnackBar lifecycle and route transitions. |

### 11.b Bell badge unread-count notifier

| Field | Value |
| --- | --- |
| Category | Other (UI) |
| Trigger | Any `emitNewWeekSnapshot` / `emitCycleRollover` / `emitMfaAuthenticatorRemoved` / `emitPushDelivery` invocation refreshes `AppNotificationService.unreadCountNotifier`. |
| Sender code path | `lib\services\app_notification_service.dart:29` (`unreadCountNotifier`). Consumers: `lib\forge_flow_app.dart:1344` + `:1408` (bell icon ValueListenableBuilder). |
| Loopback | Tap bell → navigate to `NotificationsScreen` → tile / Mark-all-read decrements. |
| Test coverage | `test\screens\notifications_screen_mark_read_test.dart`; `test\app_notification_service_test.dart`. |

### 11.c Push-permission-denied banner

| Field | Value |
| --- | --- |
| Category | Other (UI) |
| Trigger | iOS / Android user denies notification permission; app surfaces a card prompting them to enable in Settings. |
| Sender code path | `lib\widgets\push_permission_denied_card.dart`; permission state: `lib\services\mobile_push\push_permission_state.dart`. |
| Loopback | Card CTA opens platform Settings via plugin. |
| Test coverage | None found. |

### 11.d Operator-web SnackBars (form action confirmations)

| Field | Value |
| --- | --- |
| Category | Other (UI) |
| Trigger | Inline confirmation after a member invite / role change / hierarchy edit / security toggle / pricing save / wage-authority change / session revoke. |
| Sender code path (top sites) | `lib\operator_web\screens\members_screen.dart`, `roles_screen.dart`, `custom_role_editor_screen.dart`, `hierarchy_screen.dart`, `sessions_screen.dart`, `security_screen.dart`, `my_account_screen.dart`, `audit_log_screen.dart`, `wage_authority_screen.dart`, `settings_notifications_screen.dart`. Admin screens: `lib\admin\screens\operator_location_admin_screen.dart`, `corpus_admin_screen.dart`, `polling_and_pricing_admin_screen.dart`. Mobile settings: `lib\screens\settings\settings_data_sections.dart`, `settings_pointer_row.dart`, `settings_active_sessions_section.dart`. Vendor connect flow: `lib\integrations\ui\vendor_connections\vendor_connections_widget.dart`. |
| Loopback | None — visual confirmations only. |
| Test coverage | Screen-level widget tests under `test\operator_web\screens\**`, `test\admin\screens\**`. |
| Notes | These are not separate "notification scenarios" but pressure-test plans for stateful screens should pin the SnackBar copy + lifecycle. |

---

## Quick wire-status rollup

| Scenario | Wire status | Email | Push | Inbox |
| --- | --- | --- | --- | --- |
| Password reset (self-serve) | Wired | Firebase action-link | – | – |
| Email verification | Firebase-only | Firebase action-link | – | – |
| Operator-admin invite | Wired (reuses reset link) | Firebase action-link | – | – |
| `operator_admin_invite.md` SendGrid copy | Deleted in A2.2 | removed; Firebase invite email remains authoritative | – | – |
| `operator_invite_first_admin.md` SendGrid copy | Wired (admin test route only) | direct SendGrid test fixture | – | – |
| `mfa_factor_changed_notice` | **Template-only** | locked Markdown | – | – |
| MFA authenticator removed | Wired | – | – | inbox |
| `notif.vendor.now_available` | **Wired** | SendGrid via outbox | fanout | fanout |
| `vendor_sync_error_alert` | **Template-only** | locked Markdown | – | – |
| `vendor_webhook_signature_alert` | Deleted in C-2-Del | removed; Cloud Logging alerts cover signature failures | – | – |
| `vendor_connection_auto_disabled` | **Template-only** | locked Markdown | – | – |
| `notif.backfill.complete` / `.failed` | **Wired** | SendGrid via fanout | wired | wired |
| `notif.audit.anchor_failure` | **Wired** | SendGrid via fanout | wired | wired |
| Admin "Test connection" SendGrid send | Wired | direct send (no outbox) | – | – |
| Admin-initiated password reset | Wired | Firebase action-link | – | – |
| `tos_version_updated_notice` | Deleted in C-2-Del | removed; in-app accept-screen gate covers TOS updates | – | – |
| New weekly plan snapshot (inbox) | Wired | – | – | inbox |
| 60-day cycle rollover (inbox) | Wired | – | – | inbox |
| `notif.shift.stale` | Catalog-only (future) | – | – | – |
| `notif.star.override` | Catalog-only (future) | – | – | – |
| `notif.plan.updated` (push fanout) | Catalog-only (no fanout call site) | – | – | – |
| Mobile push token register / revoke | Wired (flag-gated) | – | – | – |
| Mobile push self-test | Wired | – | direct FCM | – |
| Mobile push outbox dispatch | Wired | – | FCM HTTP v1 | – |
| FCM foreground / background / terminated | Wired | – | platform | mirrors via `emitPushDelivery` |

---

## Pressure-test priorities (suggested)

Use this to scope the upcoming wave — informational only; not a binding plan.

1. **Wired SendGrid path** (vendor-now-available): outbox claim race, 3-strike retry exhaustion, render-time `MissingTemplateVariableError`, fanout-vs-email idempotency on retry.
2. **Firebase action-link paths** (password reset, invites, admin reset): privacy-preserving latency floor (`350ms` in `password_reset_request_gateway.dart:116`), action-page web-vs-mobile branching, oobCode single-use semantics, repeated submit of the same `idempotencyKey`.
3. **Push runtime**: token register failure when feature flag is on but migration not applied, FCM 5xx storm, cold-start `getInitialMessage` vs. mounted-too-late race (the `MobilePushIntentDiskStore` flow at `mobile_push_notification_service.dart:53-110`).
4. **B3 fanout events** (backfill, audit anchor): include email-channel pressure now that A2.2 reconciled the inventory to the shipped Markdown templates + renderer ids.
5. **Inbox bell**: badge math under rapid `emitPushDelivery` + `markAsRead` + dedupe collision; concurrent restaurant-scope switch.
6. **Template-only stack**: add a CI assertion that every `EmailTemplateIds.all` entry round-trips through `_subjectByTemplate` + the renderer with sample data (already in `test\services\email\email_template_renderer_test.dart`, but worth pinning each variable map). Surface the un-enqueued templates so they don't drift.

---

## File index (jump table)

Senders / dispatchers:

- `lib\services\email\email_outbox_dispatcher.dart` — outbox drain loop.
- `lib\services\email\sendgrid_email_provider.dart` — SendGrid HTTP client.
- `lib\services\email\email_template_renderer.dart` — locked subjects + template ids.
- `lib\services\email\postgres_email_outbox_repository.dart` — Postgres claim / record.
- `tool\advisor_proxy\admin_email_routes.dart` — admin test send.
- `tool\advisor_proxy\email_dispatch\vendor_lifecycle_notification_dispatcher.dart` — vendor-now-available fan-out.
- `tool\advisor_proxy\email_dispatch\notification_event_fanout.dart` — multi-channel fanout.
- `tool\advisor_proxy\email_dispatch\notification_event_hooks.dart` — per-event hook helpers.
- `tool\advisor_proxy\mobile_push_notifications.dart` — FCM send + outbox dispatcher.
- `lib\services\mobile_push\mobile_push_notification_service.dart` — client coordinator.
- `lib\services\mobile_push\firebase_mobile_push_runtime.dart` — FCM SDK wiring + inbox sink.
- `lib\services\app_notification_service.dart` — in-app inbox emit + bell-badge notifier.
- `lib\services\auth\password_reset_request_gateway.dart` — privacy-preserving reset issue.
- `lib\services\auth\repository_auth_operations_gateway.dart` (`createInvite` at line 364) — invite path.
- `lib\services\auth\firebase_admin_auth_client.dart` — Firebase Admin SDK shim (`sendPasswordResetEmail`).

Catalog / templates:

- `lib\domain\models\notification_event_catalog.dart` — event registry.
- `tool\advisor_proxy\email_templates\` — 8 repo-owned Markdown templates + `_brand_wrapper.html` (C-2-Del removed `vendor_webhook_signature_alert.md` + `tos_version_updated_notice.md` on 2026-05-13).

Persistence:

- `db\migrations\202605040200_phase_9_8_email_provider.sql` — `email_outbox`, `email_credentials`, cron tick function.
- `db\migrations\202605040100_phase_9_8_tos_versions.sql` — TOS rows.
- `db\migrations\202605060000_mobile_push_notifications.sql` — `mobile_push_tokens`, `mobile_push_outbox`.
- `db\migrations\202605070400_phase_8_notification_preferences.sql` — preference table for fanout.

UI surfaces:

- `lib\screens\notifications_screen.dart` — inbox list.
- `lib\forge_flow_app.dart:1342-1409` — bell badge.
- `lib\widgets\peer_edit_toast.dart` — realtime SnackBar.
- `lib\widgets\push_permission_denied_card.dart` — permission CTA.
- `lib\operator_web\screens\settings_notifications_screen.dart` — operator preference editor.
- `lib\operator_web\widgets\vendor_lifecycle_notify_me_dialog.dart` — picker opt-in (writes to `vendor_lifecycle_notification`).
- `web\auth\action\index.html` — Firebase action-link landing page.

Tests (entry points):

- `test\services\email\` (5 files) — provider / renderer / outbox / fanout / hooks / vendor lifecycle.
- `test\services\auth\password_reset_*` (4 files).
- `test\services\mobile_push_*` + `test\mobile_push_notification_service_test.dart` + `test\db\mobile_push_*`.
- `test\proxy\` — route-level coverage for auth, mobile push, vendor lifecycle promotion, recently available.
- `test\screens\auth\` — login + reset screens.
- `test\app_notification_service_test.dart` + `test\screens\notifications_screen_mark_read_test.dart` + `test\services\app_notification_service_push_delivery_test.dart`.
- `test\admin\` — admin gateways + screens including audited support actions.
