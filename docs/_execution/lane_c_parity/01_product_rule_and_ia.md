# 01 - Product Rule And Information Architecture (Lane C - Parity)

Status: Planning. No code, no tracker writes.
Lane: C - Cross-Surface Parity (C-Emails + C-Admin + C-OpsWeb + C-Mobile).
Authority: `CLAUDE.md` HP #2 + HP #10 + HP #11 ; `post_codex_wave_decisions_2026-05-12.md` (decisions #5, #6, #7) ; `post_codex_wave_decisions_addendum_2026-05-12.md` (A1, B3, B4, C3, C4) ; `docs/contracts/demo_mode_contract.md`.

## Plain-English Product Rule

Forge & Flow ships through four operator-facing surfaces:

1. **Mobile app** (`lib/main_forgeflow.dart`) — daily shift / variance / plan / settings, read-mostly for management.
2. **Operator Web Console** (`app.forgeflow.app`, `lib/main_operator_web.dart`) — management surface (members, roles, hierarchy, sessions, audit, security, vendors, data accuracy, wage authority, notification preferences).
3. **F&F Admin Console** (`lib/main_admin.dart`) — cross-operator support workspace for F&F staff.
4. **Email + push + in-app inbox** — the asynchronous channel that lets operators learn about events while the app is closed (vendor became available, backfill completed, audit anchor failed, TOS updated, password reset, invite).

Every operator-visible capability has an **ownership map** that names which of the four surfaces is allowed to expose it. The map is canonical. Adding a feature requires picking a row.

### Ownership map (V1)

| Capability family | Mobile | Operator Web | F&F Admin | Email/Push/Inbox |
|---|---|---|---|---|
| Sign-in / password / MFA enrollment | Read-only mirror + pointer | **Edit (canonical)** | Reset for one user only | Firebase action-link email + MFA inbox |
| Profile (name, phone) | Pointer to web | **Edit (canonical)** | Read for support | (none) |
| Business settings (name, logo, currency, locale, week-start) | Pointer to web | **Edit (canonical)** | Read for support | (none) |
| Hierarchy + locations | (none) | **Edit (canonical)** | View + scope-handoff | (none) |
| Members + invites + role grants | Read-only mirror | **Edit (canonical)** | Cross-operator edit for support | Firebase invite email |
| Roles + permission editor | (none) | **Edit (canonical)** | View | (none) |
| Active sessions | Read + revoke own | **Edit (canonical)** | View + force-logout for support | (none) |
| Audit log | Pointer to web | **View (canonical)** | View across operators | Audit anchor failure email + push |
| Security (login history, recovery codes) | Pointer to web | **Edit (canonical)** | Reset MFA / password as support action | MFA factor change email |
| Vendor connections | View status, "Notify me when ready" | **Connect / disconnect (canonical)** | Test connection, lifecycle promotion | Vendor now-available email + push, vendor sync error (template-only today), vendor webhook signature alert (template-only), vendor auto-disabled (template-only) |
| Backfill lifecycle | View progress | View progress | View across operators | Backfill complete email + push, backfill failed email + push |
| Data accuracy, wage authority | Read-only mirror | **Edit (canonical)** | View + edit for support | (none) |
| Notification preferences | (none) | **Edit (canonical)** | View | (none) |
| Demo→Live mode | **One master switch (canonical)** | (none — visible in banner) | (none — `demo_mode_state` is per-operator) | (none) |
| Cost / advisor metrics | (none) | (none) | **View (canonical, F&F staff)** | (none) |
| TOS acceptance | Pointer to web | **Edit (canonical)** | View | TOS-updated notice (template-only today) |

Every row maps to either an existing screen, an existing email template, or a documented "intentional gap" (e.g., why a row is read-only on mobile). New work that does not fit one of these rows is out of scope until the ownership map is amended.

## Hard Promise Restatement (operationalized)

### HP #2 — Demo mode is a writer-side switch (binding constraint on C-Mobile master switch)

The mobile **Demo→Live master switch** (decision #6) MUST NOT branch reader paths. It is a UX shortcut that:

1. Reads `demo_mode_state` rows for the current operator across all locations and categories.
2. Renders a single switch in mobile Settings → Integrations whose state is "Demo" if any `(operator, location, category)` row still has `is_demo = true`, "Live" otherwise.
3. On flip Demo→Live: fans out a proxy call that flips every `(operator_id, location_id, category)` row's `is_demo` to false. Auto-flip-on-first-backfill (today's behavior) remains the safety net for connected vendors and is NOT disabled by the master switch — the master is a manual override forward, not a freeze.
4. On flip Live→Demo: refused with operator-readable copy ("Live data has already arrived. Disconnect the vendor in 'Vendor connections' if you want to stop the live feed."). Demo is only the **initial** state per HP #2 + the demo contract.
5. The switch's underlying state is the existing per-(operator, location, category) `demo_mode_state` rows. There is **no new SQLite table, no new Postgres table, no new flag**. It is a UI fold over what is already there.

This is the **fourth HP #2 carve-out** to document in `docs/contracts/demo_mode_contract.md` — same documentation pattern as the three existing reader-side carve-outs (login screen demo button, data-status badge, settings demo affordances).

### HP #10 — Every backend phase ships operator-facing UX (binding constraint on C-Emails wire-or-delete)

Every email template that ships as a `.md` file in `tool/advisor_proxy/email_templates/` MUST be one of:

1. **Wired** — enqueuer + dispatcher live in production paths.
2. **Deleted** — file removed, `EmailTemplateIds.all` entry removed, walkthroughs / docs updated.
3. **Explicitly documented as deferred** with an open follow-up phase doc, a non-NULL "deferred reason" string in the renderer doc-string (today's pattern in `email_template_renderer.dart:96-110` for `vendor_connection_auto_disabled`), AND a corresponding admin UI affordance that surfaces the operator-relevant state to keep the operator informed despite no email (today's pattern: `error` chip on the Connected services card replaces the auto-disabled email).

"Template-only" without an admin UI affordance is a violation. The 5 V1 template-only entries (`mfa_factor_changed_notice`, `vendor_sync_error_alert`, `vendor_webhook_signature_alert`, `vendor_connection_auto_disabled`, `tos_version_updated_notice`, `operator_admin_invite` / `operator_invite_first_admin` SendGrid copies) need to be re-classified per the wire-or-delete decision per addendum C3.

### HP #11 — Hierarchy-scoped settings (binding constraint on C-Admin parity)

Every settings tile in admin and operator web must show: selected scope, inherited source, effective value, allowed actions, disabled/gated states, and mutation requirements. Carve-outs (today: integrations are location-bound) must be documented in the relevant contract AND surfaced in UI copy. The C-Admin sub-lane validates that admin tiles either honor this or document why they don't.

## Sub-lane scope statements

### C-Emails — Email pipeline lane (per addendum C3)

Goal: every email scenario in `c_email_notification_scenario_inventory.md` is either wired end-to-end or explicitly deleted with operator sign-off. No silent failures. SendGrid event webhook receiver is wired. Dual invite path resolved per B4.

Concrete deliverables:

1. **Wire-or-delete decision per template**: the 6 V1 template-only Markdown files get an operator decision per file: wire (build the enqueuer) or delete (remove the .md and the `EmailTemplateIds` entry). Operator-by-operator decision per addendum C3.
2. **Silent failure fix is already landed** (per `docs/_execution/b3_email_silent_failure_fix/01_execution_slice.md`). C-Emails verifies and inherits this fix — it is no longer in scope to re-do.
3. **SendGrid Event Webhook receiver** — proxy route at `POST /v1/webhooks/sendgrid/events` that verifies the `X-Twilio-Email-Event-Webhook-Signature` ECDSA header and writes events to the existing `email_event` table. (R4 Pattern 5A; the migration already shipped, the route did not.)
4. **Dual invite path resolution** (per addendum B4 — explicitly deferred to this wave). Decision: keep Firebase password-reset-email-as-invite-bootstrap and **delete** the unwired `operator_admin_invite.md` + `operator_invite_first_admin.md` SendGrid templates; OR wire the SendGrid templates and stop using the Firebase password-reset email for invite. The decision is operator-led; this lane drafts both options.
5. **Pressure-test every scenario in the inventory** at preview against the patterns in R4 (Pattern 2A action-link harness, Pattern 5B Mailosaur ephemeral inbox capture, Pattern 7A Playwright loopback).

### C-Admin — Admin console parity sweep

Goal: every admin tile either matches operator-web equivalent behavior for the same capability OR documents the gap. Where admin exposes a capability operator-web does not (e.g., "Reset MFA for a member as a support action"), the gap is intentional and rationaled in UI copy.

Concrete deliverables:

1. **Tile-by-tile parity matrix** — every tile in `kAdminRoutes` (`lib/admin/admin_routes.dart:255-424`) audited against its operator-web counterpart (where one exists) or the ownership-map row above.
2. **Confirm admin-only surfaces** are documented and never imply operator self-service:
   - Pricing (Plans and limits) — F&F-only by design.
   - Knowledge base (Corpus) — F&F-only by design.
   - AI Metrics (Observability) — F&F-only by design.
   - Launch controls (Feature Flags) — F&F-only by design.
   - System health, Support logs — F&F-only by design.
   - Audited support actions — F&F-only, surface for F&F staff to act on behalf of an operator.
3. **Confirm cross-surface surfaces** match operator-web for the same operator:
   - Business accounts → Account profile = operator-web's `AccountScreen`.
   - People, access & roles = operator-web's `MembersScreen` + `RolesScreen` + scope picker.
   - Security & audit = operator-web's `SecurityScreen` + `SessionsScreen` + `AuditLogScreen`.
   - Vendor integrations = operator-web's `VendorConnectionsScreen`.
   - Timing = operator-web's `BusinessTimingEditorScreen`.
   - Data accuracy = operator-web's `DataAccuracyScreen`.

### C-OpsWeb — Operator web parity sweep

Goal: `app.forgeflow.app` is the canonical edit surface for every operator capability, and its IA implements decisions #7 (sign-in-security → My Account redirect), A1 (deep-link redemption code landing), and the shared Inheritance Tree component (decision C2).

Concrete deliverables:

1. **Sign-in-security → My Account redirect** (decision #7) — the `kOperatorWebNavSecurity` nav item (`operator_web_router.dart:90,727`) is converted from a stand-alone screen into a redirect to the MFA + Password sections of `MyAccountScreen`. Existing inbound email links and deep-links to `/security` continue to work via a 301-style web redirect. The login history section moves into the Security tile of My Account.
2. **Deep-link redemption-code landing handler** (decision A1) — `app.forgeflow.app/handoff?code=<opaque>` is a new entry point that calls the proxy's redemption-code endpoint (Lane B B11 — Lane C consumes), receives a fresh operator-web session JWT in exchange for the code, and routes to the target nav (`my_account`, `wage_authority`, etc.) carried in the redemption response. RFC 9470 step-up challenge is the second-stage gate for sensitive targets.
3. **Adaptive 2FA button consumer** (R1 pattern, decision C1 "Trust & Account Control" UX track) — the My Account → MFA section's Enroll / Manage button text adapts to the operator's current state.
4. **Shared Inheritance Tree component consumer** — wherever operator-web displays inheritance (Members scope picker, Hierarchy screen, blended wage mix table, role inheritance display), the shared Lane A component is consumed.
5. **Notification preferences screen completeness** — operator-web's `SettingsNotificationsScreen` should expose every catalog event from `notification_event_catalog.dart`, including the 5 events flagged in the inventory as future or hook-only-no-fanout (`notif.plan.updated` push, `notif.shift.stale`, `notif.star.override`).

### C-Mobile — Mobile parity sweep

Goal: mobile is a read-mostly mirror with a "Manage on Operator Web" pointer that opens a deep link redeeming through the redemption-code flow (decision A1) and a single master Demo→Live switch (decision #6).

Concrete deliverables:

1. **"Manage Timing on Ops Web", "Manage Wage on Ops Web", "Manage Account on Ops Web" buttons** (decision #5 + A1) — replace today's clipboard-copy `SettingsPointerRow` (`lib/screens/settings/settings_pointer_row.dart`) with a real deep-link button that requests a redemption code from the proxy (Lane B B11), opens `https://app.forgeflow.app/handoff?code=...&nav=...` in the platform browser, and falls back to clipboard copy on offline / no-redeem-endpoint.
2. **Master Demo→Live switch** (decision #6) — single switch in mobile Settings → Integrations (next to the existing `DemoModeBanner` consumer) that fans out across `demo_mode_state` rows per the rule documented above. Auto-flip-on-first-backfill stays as the safety net.
3. **Push notification preferences mirror** — mobile Settings → Notifications shows the same catalog events as operator-web's `SettingsNotificationsScreen` (read-mostly; edit lives on operator-web per the ownership map). Per the mobile push notifications plan, the read-side mirror is what mobile needs; edit-on-web is the canonical surface.
4. **In-app notifications screen completeness** — `lib/screens/notifications_screen.dart` already reads from `app_notifications`; verify it renders every catalog event the fanout writes, not only the three currently emitted by `AppNotificationService.emitMfa* / emitNewWeekSnapshot / emitCycleRollover / emitPushDelivery`.

## UX consistency rules

- One ownership map row per capability. New capabilities cannot ship until they fit a row.
- "Pointer to web" rows on mobile must do the deep-link redemption-code dance, not clipboard-copy.
- Every email scenario in the inventory has a wire status (Wired / Template-only / Hook-only / Future) that the inventory pressure-test verifies.
- Demo carve-outs are documented in the contract and reflected in UI copy where the operator sees them.
- Sign-in-security is not a standalone surface in V1; it lives inside My Account.
- Admin surfaces that exist for F&F support only have UI copy that says so ("This is for F&F support staff" / "Available to F&F admins managing this business").
