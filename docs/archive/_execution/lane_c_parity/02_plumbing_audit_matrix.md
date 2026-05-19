# 02 - Plumbing Audit Matrix (Lane C - Parity)

Status: Read-only audit. No code mutated.
Citations are absolute or repo-relative file paths with line numbers. Lines verified at audit time; may drift.
Authority: `c_email_notification_scenario_inventory.md` (which is the source of truth per addendum C3) is the primary upstream; this matrix narrows it to actionable gaps.

## Coverage Summary

Lane C touches four surfaces (Emails / Admin / OpsWeb / Mobile) and the wire between them. The matrix below names every gap a slice in `03_execution_slices.md` will close.

Notation:
- `[WIRED]` — production path is end-to-end live.
- `[TEMPLATE-ONLY]` — Markdown / catalog entry / placeholder exists, no emitter / consumer.
- `[HOOK-ONLY]` — fanout helper exists, trigger site not calling it (or downstream missing).
- `[MISSING]` — nothing exists.
- `[STALE]` — the c_email_notification_scenario_inventory entry is now out-of-date because B3 already shipped.

## C-Emails — Email pipeline gaps

### E1. SendGrid Event Webhook receiver

| Field | Value |
|---|---|
| Status | [MISSING] |
| Where it should land | `tool/advisor_proxy/main.dart` mounts a new `SendGridEventWebhookRouter` at `POST /v1/webhooks/sendgrid/events`. Existing schema `db/migrations/202605040200_phase_9_8_email_provider.sql` already includes `email_event` table — only the route is absent. |
| Evidence of absence | `Grep "/v1/webhooks/sendgrid|sendgrid/events" tool` returns zero matches. `Grep "email_event" tool` returns only the seam in `lib/services/email/email_provider.dart`. |
| Signature verification | Required: `X-Twilio-Email-Event-Webhook-Signature` (ECDSA over body + timestamp). Public key in `email_credentials` row or env var. |
| Test gap | No `test/proxy/sendgrid_events_webhook_test.dart`. |
| Why it matters | Without the webhook, we have no production-side proof that an email was actually delivered vs. accepted by SendGrid. The bell-badge unread-count math and the dispatch retry loop both depend on `email_event.event_type` updates. |

### E2. B3 silent-failure fix landed but inventory is stale

| Field | Value |
|---|---|
| Status | [STALE] — `docs/_audits/code_health/c_email_notification_scenario_inventory.md:191,208` says `backfill_complete`/`backfill_failed`/`audit_anchor_failure` are "template Markdown does NOT exist." Reality: all three `.md` files exist (`tool/advisor_proxy/email_templates/{backfill_complete,backfill_failed,audit_anchor_failure}.md`), all three template ids are in `EmailTemplateIds.all` (`lib/services/email/email_template_renderer.dart:157-170`), all three have locked subjects (`:195-200`), and the B3 fix landed at `docs/_execution/b3_email_silent_failure_fix/01_execution_slice.md`. |
| What this means for C-Emails | The B3 silent-failure fix is done. C-Emails does not re-do it. C-Emails inherits it and verifies under pressure-test. |
| Inventory action | The c_email_notification_scenario_inventory needs a follow-up edit. Flag as a contract-doc-hygiene update, not part of Lane C scope per the instructions. |

### E3. Six remaining template-only Markdown files

Per `c_email_notification_scenario_inventory.md` §3a / §4b / §4c / §4d / §8a / §2 + the renderer's `EmailTemplateIds.all` minus the 6 wired entries:

| Template id | Markdown file | Status | Decision needed |
|---|---|---|---|
| `mfa_factor_changed_notice` | `tool/advisor_proxy/email_templates/mfa_factor_changed_notice.md` | [TEMPLATE-ONLY] — no emitter. | Wire: the MFA enrollment / removal worker emits on success. OR delete and rely on the existing in-app MFA inbox emit (`AppNotificationService.emitMfaAuthenticatorRemoved` at `lib/services/app_notification_service.dart:114-134`). |
| `vendor_sync_error_alert` | `tool/advisor_proxy/email_templates/vendor_sync_error_alert.md` | [TEMPLATE-ONLY] — no emitter. | Wire: the polling tier / OAuth refresh worker detects sustained failure → emit. OR delete and rely on the existing `error` chip on the Connected services card (today's pattern). |
| `vendor_webhook_signature_alert` | `tool/advisor_proxy/email_templates/vendor_webhook_signature_alert.md` | [TEMPLATE-ONLY] — no emitter. | Wire: the inbound webhook handler counts failed signatures within a window → emit. OR delete. |
| `vendor_connection_auto_disabled` | `tool/advisor_proxy/email_templates/vendor_connection_auto_disabled.md` | [TEMPLATE-ONLY] — explicitly deferred per `email_template_renderer.dart:96-107` doc-string. | Wire: the OAuth refresh cron auto-disable code path emits on the 3rd consecutive failure. OR explicitly re-document the deferral with a target follow-up phase number (lane C drafts both paths). |
| `tos_version_updated_notice` | `tool/advisor_proxy/email_templates/tos_version_updated_notice.md` | [TEMPLATE-ONLY] — no emitter. The runtime gate that forces re-accept is already wired (`lib/operator_web/screens/tos_accept_screen.dart`); the email side is not. | Wire: a publish step that writes a new `tos_versions` row enqueues an outbox row per active operator. OR delete and rely on the runtime gate. |
| `operator_admin_invite` (and `operator_invite_first_admin`) | Both files in `tool/advisor_proxy/email_templates/` | [TEMPLATE-ONLY] — the actual invite path reuses the Firebase password-reset email (per `c_email_notification_scenario_inventory.md` §2). | Per addendum B4 — defer was the original decision; per the current planning instructions, addendum C3 says resolve this in this wave. Either wire the SendGrid templates and stop using the Firebase reset email, OR delete the SendGrid templates. |

### E4. Notification catalog vs. fanout coverage gap

| Catalog event | Status | File | Gap |
|---|---|---|---|
| `notif.vendor.now_available` | [WIRED] | `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart:295` | None. |
| `notif.backfill.complete` | [WIRED post-B3] | `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart:71` | Trigger-site wiring at `tool/integration_sync_worker/backfill_dispatch.dart` `markSucceeded` is wired per the B3 slice doc; verify under pressure-test. |
| `notif.backfill.failed` | [WIRED post-B3] | `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart:114` | Trigger-site at `tool/first_connect_backfill_worker/main.dart` `markFailed` is wired per the B3 slice doc; verify under pressure-test. |
| `notif.audit.anchor_failure` | [WIRED post-B3] | `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart:158` | Verify push channel reaches operator + email channel reaches operator-admin email under pressure-test. |
| `notif.plan.updated` | [HOOK-ONLY] | Catalog at `lib/domain/models/notification_event_catalog.dart:153`. Inbox-side `AppNotificationService.emitNewWeekSnapshot` at `lib/services/app_notification_service.dart:190` is wired; push fanout call site is missing. | Snapshot service must call `NotificationEventFanout.fanOut` after `emitNewWeekSnapshot`. |
| `notif.shift.stale` | [TEMPLATE-ONLY] | Catalog at `notification_event_catalog.dart:134`. FOLLOW-UP comment at `notification_event_fanout.dart:667-672`. | Phase 10b backend not yet shipped — keep as catalog entry, document as gated. |
| `notif.star.override` | [TEMPLATE-ONLY] | Catalog at `notification_event_catalog.dart:144`. FOLLOW-UP comment at `notification_event_fanout.dart:672-676`. | Phase 11b advisor surface not yet shipped — keep as catalog entry, document as gated. |

## C-Admin — Admin console parity gaps

### A1. Admin route catalog completeness

| Route | File | Operator-web counterpart | Parity status |
|---|---|---|---|
| `kAdminOperatorsRouteId` "Business accounts" | `lib/admin/admin_routes.dart:256` | (operator selects the business; no counterpart) | Admin-only. OK. |
| `kAdminSupportOperatorViewRouteId` "Support workspace" | `lib/admin/admin_routes.dart:266` | (admin-only, F&F support) | Admin-only. OK. |
| `kAdminPricingRouteId` "Plans and limits" | `lib/admin/admin_routes.dart:278` | (no operator surface) | Admin-only by design. UI copy should say so. |
| `kAdminCorpusRouteId` "Knowledge base" | `lib/admin/admin_routes.dart:287` | (no operator surface) | Admin-only by design. UI copy should say so. |
| `kAdminIntegrationsRouteId` "Connected services" | `lib/admin/admin_routes.dart:296` | (operator: `vendor_connections_screen.dart`) | Cross-surface. Admin = global integration health; operator = per-business vendor connections. Document the distinction. |
| `kAdminHealthRouteId` "System health" | `lib/admin/admin_routes.dart:305` | (no operator surface) | Admin-only by design. |
| `kAdminFeatureFlagsRouteId` "Launch controls" | `lib/admin/admin_routes.dart:314` | (no operator surface) | Admin-only by design. |
| `kAdminDebugConsoleRouteId` "Support logs" | `lib/admin/admin_routes.dart:323` | (no operator surface) | Admin-only by design. |
| `kAdminObservabilityRouteId` "AI Metrics" | `lib/admin/admin_routes.dart:333` | (no operator surface) | Admin-only by design. |
| `kAdminDataAccuracyRouteId` "Covers and Wage Data Accuracy" | `lib/admin/admin_routes.dart:342` | `lib/operator_web/screens/data_accuracy_screen.dart` | Cross-surface. Admin should be view-only / scope-handoff; operator-web owns edit. Today admin badge says "Work in progress" — clarify it is read-mostly. |
| `kAdminPollingPricingRouteId` "Polling Setup" | `lib/admin/admin_routes.dart:355` | (no operator surface) | Admin-only by design. |
| `kAdminVendorIntegrationsRouteId` "Vendor integrations" | `lib/admin/admin_routes.dart:368` | `lib/operator_web/screens/vendor_connections_screen.dart` | Cross-surface. Admin is per-location vendor lifecycle for support; operator-web is the canonical connect/disconnect. |
| `kAdminTimingSetupRouteId` "Timing" | `lib/admin/admin_routes.dart:378` | `lib/operator_web/screens/business_timing_editor_screen.dart` | Cross-surface. Verify the admin gateway and operator-web gateway share the same `BusinessTimingGateway` reads. |
| `kAdminMembersRouteId` "People, access & roles" | `lib/admin/admin_routes.dart:389` | `lib/operator_web/screens/members_screen.dart` | Cross-surface. Verify route-contract parity in the admin gateway. |
| `kAdminRolesHierarchySessionsRouteId` "Access" | `lib/admin/admin_routes.dart:401` | `lib/operator_web/screens/roles_screen.dart` + `hierarchy_screen.dart` + `sessions_screen.dart` | Cross-surface. The admin gateway already exposes the three tabs in one screen; operator-web splits them across three nav items. Confirm reads agree. |
| `kAdminAuditedSupportActionsRouteId` "Security & audit" | `lib/admin/admin_routes.dart:412` | `lib/operator_web/screens/security_screen.dart` + `audit_log_screen.dart` | Cross-surface. Admin adds support actions (Reset MFA, force-logout, paired-approval erasure) operator-web does not have. Document. |

### A2. Hierarchy resolution + scope picker consistency

The admin scope picker is `AdminHierarchyScopeIntent` at `lib/admin/admin_route_handoff.dart:*`. Operator-web uses `OperatorWebManagementScopeOption` at `lib/operator_web/router/operator_web_router.dart:163-169`. Confirm both consume the same hierarchy resolver and surface the same scope labels per HP #11.

### A3. Admin "Test connection" SendGrid send

Per `c_email_notification_scenario_inventory.md` §7a, this is [WIRED] at `tool/advisor_proxy/admin_email_routes.dart:140`. Lane C verifies:
1. The admin route's `super_admin` guard is enforced under preview.
2. The placeholder `setupUrl` value (`https://app.forgeflow.app/onboarding/test`) does NOT route to a real onboarding flow.
3. The admin route's bypass of `email_outbox` is documented as intentional (synchronous feedback for admin smoke).

## C-OpsWeb — Operator web parity gaps

### O1. Sign-in-security stand-alone nav vs. decision #7 (redirect to My Account)

| Field | Value |
|---|---|
| Status | [MISSING redirect] |
| Current code | `lib/operator_web/router/operator_web_router.dart:90` declares `kOperatorWebNavSecurity = 'security'`; lines `:727-731` add it as a nav item titled "Sign-in security" under the "Access" group; line `:834` routes to `SecurityScreen` (`lib/operator_web/screens/security_screen.dart`). |
| Decision #7 says | The `/operator-web/sign-in-security` route should 301-redirect to the matching section of My Account. Existing inbound links must keep working. |
| Required change | Move the MFA section + Password section + Login history section into `MyAccountScreen` (which today owns MFA + Password without login history). The standalone `SecurityScreen` is deleted; the nav item is removed; the route serves a redirect to `/my-account#security`. |
| Risk | Existing email links and operator bookmarks. The redirect handles them. |

### O2. Deep-link redemption-code landing handler (decision A1 + Lane B B11)

| Field | Value |
|---|---|
| Status | [MISSING] |
| Where it should land | New route handler in `lib/operator_web/router/operator_web_router.dart` that recognizes `Uri.base.path == '/handoff'` + `Uri.base.queryParameters['code']`. Calls Lane B's proxy redemption endpoint, receives a fresh session JWT + nav target, and routes accordingly. |
| Lane B dependency | The redemption endpoint is Lane B B11 ("redemption-code handoff with RFC 9470 step-up challenge"). Lane C consumes; Lane B builds. Slice 03_3 in this lane is gated on Lane B's PR landing. |
| Sensitive-target list | `MyAccount` MFA enroll, `MyAccount` password change, `Roles` editor mutations, `Members` invite mutations. Non-sensitive: read-only Wage authority, read-only Timing, read-only Account profile. |

### O3. Notification preferences screen vs. catalog

| Field | Value |
|---|---|
| Status | [PARTIAL] |
| Current code | `lib/operator_web/screens/settings_notifications_screen.dart` consumes the catalog via `OperatorWebNotificationPreferencesGatewayProvider`. |
| Gap | Confirm the screen renders every entry in `lib/domain/models/notification_event_catalog.dart` including the 3 future entries (`notif.plan.updated`, `notif.shift.stale`, `notif.star.override`). Future entries can render as "Coming soon" rows or filtered out — operator-led decision per the wire-or-delete pattern. |

### O4. Inheritance Tree component consumer (decision C2)

| Field | Value |
|---|---|
| Status | [BLOCKED on Lane A] |
| Consumers | `members_screen.dart` scope picker · `hierarchy_screen.dart` · blended wage mix display (under `wage_authority_screen.dart`) · role inheritance display (under `roles_screen.dart` + `custom_role_editor_screen.dart`). |
| Plan | Once Lane A lands the shared component, Lane C swaps the four consumers in operator-web (and the matching admin consumers). |

### O5. Adaptive 2FA button (R1 pattern, decision C1)

| Field | Value |
|---|---|
| Status | [PARTIAL — exists in My Account, not adaptive] |
| Current code | `lib/operator_web/screens/my_account_screen.dart` shows an Enroll button when `session.mfaEnrolled == false` and a View backup codes button otherwise. Static text. |
| Required change | Button label adapts to operator state per R1: "Enable two-factor sign-in" (not enrolled, no factors), "Add another method" (enrolled, ≥1 factor), "View recovery codes" (enrolled, ≥1 factor, never viewed), "Manage two-factor sign-in" (everything set up). |

## C-Mobile — Mobile parity gaps

### M1. Pointer rows do clipboard, not deep-link (decisions #5 + A1)

| Field | Value |
|---|---|
| Status | [PARTIAL — clipboard fallback only] |
| Current code | `lib/screens/settings/settings_pointer_row.dart:101-120` tap-copies the URL to clipboard + shows a snackbar "URL copied — open in browser". The `onLaunch` hook (line :40) is unused in production callers. |
| Callers | `Grep "SettingsPointerRow"` finds `lib/screens/settings/settings_pointer_row.dart:21` (definition) + at least one call site (`lib/screens/settings/settings_data_sections.dart`). |
| Required change | Replace clipboard with a redemption-code request to the proxy (Lane B B11), open the resulting `https://app.forgeflow.app/handoff?code=...&nav=...` URL via `url_launcher`, fall back to clipboard on offline or proxy 5xx. Add "Manage Timing on Ops Web" / "Manage Wage on Ops Web" / "Manage Account on Ops Web" buttons to the matching mobile Settings sections. |

### M2. Master Demo→Live switch (decision #6)

| Field | Value |
|---|---|
| Status | [MISSING] |
| Current code | `lib/state/demo_mode_state_notifier.dart` already exposes `DemoModeStateSnapshot.demoCategories` and `hasDemoCategories` (line :83-105). `lib/widgets/demo_mode_banner.dart` consumes it. The proxy already exposes `SyncProxyClient.fetchDemoModeStates` and per-row flip via `DemoModeFlipPolicy.evaluateFlip` (the existing per-(operator, location, category) auto-flip on first backfill). |
| Gap | (a) A new proxy route `POST /v1/operators/.../demo-mode-master-switch` that flips every `demo_mode_state` row for the active operator. (b) A new UI switch in mobile Settings → Integrations next to `DemoModeBanner` that calls the new route. (c) UX copy that refuses Live→Demo with a plain-English explanation. |
| HP #2 compliance | The switch reads + writes through `demo_mode_state` exclusively. No `kDemoMode` branching. No new SQLite tables. Documentation pattern follows the three existing reader-side carve-outs in `docs/contracts/demo_mode_contract.md`. |

### M3. Mobile push notifications wired-but-flag-gated

| Field | Value |
|---|---|
| Status | [WIRED, FLAG-GATED] |
| Current code | `lib/services/mobile_push/mobile_push_notification_service.dart` is the client coordinator; `lib/services/mobile_push/firebase_mobile_push_runtime.dart` wires the FCM SDK; `tool/advisor_proxy/mobile_push_notifications.dart` is the proxy side. Feature-flagged via `--dart-define=MOBILE_PUSH_NOTIFICATIONS_ENABLED=true` per `c_email_notification_scenario_inventory.md` §10a. |
| Gap | Lane C verifies: (1) the flag default state for V1 launch (on / off) is documented; (2) the FCM permission denial UI (`lib/widgets/push_permission_denied_card.dart`) renders correctly on the device QA pass; (3) terminated-app deep-link routing via `getInitialMessage` works (already wired per inventory §10a, needs Patrol verification). |

### M4. In-app notifications screen renders every catalog event

| Field | Value |
|---|---|
| Status | [PARTIAL] |
| Current code | `lib/screens/notifications_screen.dart` reads from `app_notifications` via `AppNotificationRepository`. The repo is populated by `AppNotificationService.emit*` (5 emit methods: MfaAuthenticatorRemoved, NewWeekSnapshot, CycleRollover, PushDelivery, and the seam for `emitPushDelivery`). |
| Gap | The 6 wired email scenarios (vendor-now-available, backfill complete / failed, audit anchor failure, plus 2 future ones) all fan out to push + inbox per the catalog. Confirm `defaultMobilePushInboxSink` at `firebase_mobile_push_runtime.dart:73` correctly writes those inbox rows via `emitPushDelivery` so the bell badge increments. The plumbing exists per `app_notification_service_push_delivery_test.dart`; Lane C verifies under pressure-test. |

## Cross-cutting findings

### X1. Demo-mode contract carve-out documentation pattern

The demo mode contract (`docs/contracts/demo_mode_contract.md`) lists 3 reader-side carve-outs (login screen demo button, data-status badge, settings demo affordances). The master switch (M2) is a fourth carve-out:

- It is a **UX fold over runtime state**, not a build-flag branch.
- The mobile Settings UI surfaces the per-(operator, location, category) detail underneath the master switch (per decision #6: "One master switch on the mobile Integrations tab, granular underneath.").
- The `kDemoMode` build flag is NOT consulted by the master switch.

If during implementation a designer wants to gate the master switch UI on `kDemoMode` (e.g., to hide it in production), they should write a contract update first per CLAUDE.md "Rules for new demo-aware code." Lane C flags this for the contract author; Lane C does not amend the contract.

### X2. SendGrid event webhook + dispatch idempotency

The proxy already enforces per-write idempotency via `proxy_requests` UNIQUE constraint (per CLAUDE.md "Proxy & API Conventions"). The SendGrid event webhook (E1) is **inbound** — idempotency on incoming events is enforced by the `email_event.event_id` UNIQUE constraint already in the migration. Confirm no new idempotency seam is required.

### X3. Operator-web Flutter Web deploys to `app.forgeflow.app` per decision

Per the V1 launch decisions (`memory/project_v1_launch_decisions_2026_05_03.md`) the operator-web is hosted at `app.forgeflow.app`. The deploy entry is `scripts/deploy_operator_web.ps1` (referenced from `lib/main_operator_web.dart:6`). Lane C does not touch the deploy script; Lane C verifies the live web build serves the new redirect (decision #7) and the new handoff landing (decision A1) under preview.

## Must-Fix Before Live UI Claims

### F1. C-Emails: SendGrid event webhook landed before C-Emails marks "Wired"

Without E1, every email scenario's "did the operator actually receive it" signal is unobservable. Pressure tests will rely on Mailosaur ephemeral inboxes per R4 §5B, but production needs the SendGrid webhook for the `email_event` row.

### F2. C-Mobile: redemption-code endpoint (Lane B B11) before pointer rows ship

The mobile pointer-row → deep-link redemption flow depends on Lane B B11 landing its proxy endpoint. Slice 03_5 in `03_execution_slices.md` is sequenced after Lane B B11.

### F3. C-OpsWeb: sign-in-security redirect cannot break inbound email links

Decision #7 explicitly requires the redirect preserve existing email links and operator bookmarks. The redirect handler must answer `/security` AND `/sign-in-security` AND any prior route alias. Tests must cover all three.

### F4. C-Admin: data-accuracy badge "Work in progress" is operator-confusing

Today the admin "Covers and Wage Data Accuracy" tile carries badge "Work in progress" (`lib/admin/admin_routes.dart:348`). Per the parity rule, that copy should say "Read-only view — operator edits live on Operator Web" or similar; admin's data-accuracy tile is a support read surface, not a half-built editor.

## Testing Gaps To Fill

- `test/proxy/sendgrid_events_webhook_test.dart` — signature verify happy + bad-signature reject + idempotent re-delivery.
- `test/proxy/redemption_code_handoff_test.dart` — Lane C consumes from Lane B's tests, but adds its own operator-web router test for the `/handoff` parser + nav routing.
- `test/operator_web/router/sign_in_security_redirect_test.dart` — assert `/security` and `/sign-in-security` both land in My Account.
- `test/screens/settings/settings_pointer_row_test.dart` — already exists; extend to assert deep-link redemption path when `onLaunch` is wired.
- `test/operator_web/screens/master_demo_live_switch_test.dart` — new, asserts the switch reads from `demo_mode_state` rows + the Live→Demo refusal copy.
- `test/proxy/demo_mode_master_switch_test.dart` — fan-out across multiple `demo_mode_state` rows + idempotent re-flip.
- Pressure tests per R4 patterns (Mailosaur, Patrol) — see `04_verification_deploy_and_e2e.md`.
