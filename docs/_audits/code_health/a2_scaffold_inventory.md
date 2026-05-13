# A2 — Scaffold Inventory (Deep Code-Health Audit)

Created 2026-05-12 as Step 4 of the post-Codex wave plan. Source-of-truth
inventory for every scaffolded-but-not-fully-wired surface in the
Forge & Flow codebase, with per-surface wire-or-delete recommendation.
This audit complements Lane A's parallel lens-audit (A1/A3/A4/A5/A6/A7/A8/A9/A10/A11)
by going DEEP on scaffolds specifically per decision C4 in
`docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md`.

**Original read-only audit. No code paths were modified during Step 4.**

A2.1 execution note (2026-05-12): the original inventory remains the
baseline audit. This addendum records the narrow A2.1 implementation
verdicts and caller proof before the two delete-only widget files were
removed on branch `codex/a2-1-dead-placeholder-sweep`.

## A2.1 Execution Matrix

| Surface | Evidence checked | A2.1 verdict | Action |
|---|---|---|---|
| `DeferredAdminScreenPlaceholder` | `rg "DeferredAdminScreenPlaceholder\|deferred_admin_screen_placeholder" lib test` matched only `lib/admin/widgets/deferred_admin_screen_placeholder.dart`; admin route sweep found no `placeholder: true` production route in `lib/admin/admin_routes.dart`. | Delete. Dead deferred-route widget with no callers. | Removed `lib/admin/widgets/deferred_admin_screen_placeholder.dart`. |
| `DeferredScreenPlaceholder` | `rg "DeferredScreenPlaceholder\|deferred_screen_placeholder" lib test` matched only `lib/operator_web/widgets/deferred_screen_placeholder.dart`; operator-web nav sweep found no `placeholder: true` production nav item in `lib/operator_web/router/operator_web_router.dart`. | Delete. Dead deferred-route widget with no callers. | Removed `lib/operator_web/widgets/deferred_screen_placeholder.dart`. |
| Tests exclusively covering the deleted widgets | `rg --files test \| rg "deferred|placeholder|admin|operator_web"` plus symbol search found no test importing either deleted widget. | Keep test tree unchanged. | No exclusive tests existed to delete. |
| `MetricCardNotYetAvailable` | `lib/widgets/metric_card_not_yet_available.dart:26`, `test/widgets/metric_card_not_yet_available_test.dart:8`, and live provenance references in `lib/domain/models/metric_provenance.dart:45` / `lib/screens/shift_dashboard.dart:540`. | Keep. Honest unavailable-metric state per Metric Honesty Doctrine, not dead placeholder plumbing. | No code edit. |
| `PrestonLeeModelComingSoonScreen` | `lib/internal/barrio/screens/preston_lee_model_coming_soon_screen.dart:12`, routed by `lib/internal/barrio/routes/barrio_route_map.dart:59`, and covered by `test/barrio_shell_widget_test.dart:83`. | Keep. Barrio is paused, and this screen stays inside the internal Barrio boundary. | No code edit. |
| Admin route placeholder plumbing | `lib/admin/admin_routes.dart:121`, `lib/admin/admin_shell.dart:277`, `:803`, `:853`; `rg "placeholder:\s*true" lib/admin lib/operator_web test` found only test fixture uses in `test/admin/data_accuracy_ux_framework_polish_test.dart`. | Follow-up. Dead-looking route plumbing is outside A2.1's explicit delete-only files. | Flagged for later A2 cleanup; not edited. |
| Operator-web nav placeholder plumbing | `lib/operator_web/widgets/web_app_shell.dart:25`, `:32`, `:640`; no production `OperatorWebNavItem` sets `placeholder: true`. | Follow-up. Dead-looking nav chip plumbing is outside A2.1's explicit delete-only files. | Flagged for later A2 cleanup; not edited. |

Line numbers verified at audit time and may drift as code changes. All
paths are absolute under
`C:\Git Local Repos\forge_flow_demo\.claude\worktrees\nifty-clarke-d3ec25\`
unless noted. Email-pipeline entries cross-reference
`docs/_audits/code_health/c_email_notification_scenario_inventory.md`
(the "C" inventory, hereafter "the email inventory") which was the first
shape precedent and is the source of truth for that lane.

---

## Section 1 — Methodology + Scope

### What counts as "scaffold"

A surface is scaffolded when one or more of these are true:

1. **UI without backend.** A widget or button exists in `lib/` but the
   gateway method it calls throws `UnimplementedError` /
   `UnsupportedError`, returns a hardcoded fixture, or routes to a
   no-op.
2. **Backend without UI.** A proxy route handler exists in
   `tool/advisor_proxy/**` (path constant declared and tested) but
   nothing in `lib/` ever forms a request against the path. Deployment
   smoke probes (`/healthz`, `/readyz`, `/v1/scope`,
   `/v1/usage-smoke`, `/v1/advisor-smoke`) do NOT count — those are
   intentionally called by Cloud Run / runbook curl, not by app
   code.
3. **Template without enqueuer.** A Markdown email template file ships
   under `tool/advisor_proxy/email_templates/` but no production path
   calls the renderer with that template id. The email inventory
   already enumerates these; this audit pulls them into the unified
   wire-or-delete table.
4. **Schema without app reads/writes.** A column or table created by a
   migration under `db/migrations/**` that no `lib/` or `tool/` code
   references.
5. **TODO/FIXME/stub markers** that have outlived their original phase
   and never closed.
6. **Feature flags / dart-define gates** protecting unfinished code
   paths that have no fallback or are bound only to demo mode.
7. **Catalog entries without fanout.** Notification event_keys
   admitted by `notification_event_catalog.dart` but no trigger site
   calls `NotificationEventFanout.fanOut` for them.
8. **Phantom widget classes / unused constructor params.** Public
   classes declared and exported but referenced nowhere outside their
   own file or sibling test.
9. **Provider abstractions that ship one impl with no future-use
   anchor.** Per HP #8 multiple AI infra abstractions ARE deliberate;
   this audit flags only single-impl abstractions WITHOUT a phase-doc
   anchor that justifies the seam.

### What does NOT count

The following deliberately stay off this list to keep it focused on
scaffolds the team should act on (wire or delete) within the post-Codex
wave:

- **Hard Promise #8 AI infrastructure abstractions** (`LLMProvider`,
  `EmbeddingProvider`, `RerankProvider`, `DataSourceProvider`,
  `IntegrationProvider`) — Phase 12 reuses them. Anchored at CLAUDE.md
  HP #8.
- **`kDemoMode` reader-side carve-outs** explicitly documented in
  CLAUDE.md's Demo Mode block (operator login button at
  `lib/screens/auth/login_screen.dart:27-29`; `DEMO` vs `CURRENT`
  badge at `lib/services/app_data_status_service.dart:33`; demo-only
  settings sections at `lib/screens/settings_screen.dart:39`).
- **Frozen `lib/data/` legacy** — delete-only per CLAUDE.md
  "Service-Layer Split"; not in scope for this wave.
- **`lib/internal/barrio/**` + `lib/main_barrio.dart`** — paused per
  `project_barrio_paused.md` (2026-05-03). "Coming Soon" tags inside
  Barrio destination screens are inside the freeze.
- **AI-paused surfaces (Phase 11b / 12 / 11A.3.x / 11A.11 / 9.8
  advisor / 10b)** — paused per
  `project_phase_pause_2026_05_03.md`. The
  `graph_candidates_not_configured` /
  `graph_candidates_unavailable` 503 scaffolding at
  `tool/advisor_proxy/advisor_proxy.dart:13628-13635` and `:13705-13707`
  is explicitly an operator-blessed paused scaffold (see
  `PROJECT_TRACKER.md:132-139`).
- **`ScaffoldFailing*` / `ScaffoldRejecting*` default bindings in the
  proxy and `lib/forge_flow_bootstrap.dart`** — these are deliberate
  fail-closed defaults that ensure misconfigured deploys surface a
  clear error rather than silently allow. They WORK as intended and
  are not the target of the C4 directive.
- **Deployment smoke routes** (`/v1/scope`, `/v1/usage-smoke`,
  `/v1/advisor-smoke`) — called by Cloud Run + runbook curl;
  documented in `docs/contracts/hardening_production_wiring_contract.md`.
- **Future-phase plumbing with an explicit phase-doc anchor**
  (e.g. `FailureKind.costBreach` reserved for circuit-breaker E.2b
  per Lock 7 `docs/phases/phase_11a/phase_11a_decision_register.md:938-972`).
  Reserved enum values with a doc anchor are kept; reserved values
  with no anchor are flagged.

### How I investigated

Aggressive rg sweeps for: `TODO|FIXME|stub|scaffold|coming soon|not
yet wired|not wired|deferred|placeholder|UnimplementedError|
UnsupportedError|throw .*not_implemented` across `lib/` and `tool/`.
Cross-referenced each hit against:

- The email inventory (`c_email_notification_scenario_inventory.md`).
- `PROJECT_TRACKER.md` "Paused" + recently archived lists.
- `docs/POST_HARDENING_FOLLOWUPS.md` P0/P1/P2/P3 sections.
- Caller-walk: for every "scaffold" candidate, grep for callers in
  `lib/` and `tool/` to confirm zero production wiring.

Token-budgeted: I did NOT exhaustively walk every column of every
table in `db/migrations/**` (116 migrations). Instead I spot-checked
column names that appeared in scaffold-adjacent migrations. A
follow-up A5 lens may surface additional dormant columns.

---

## Section 2 — Inventory by Surface Family

### 2.1 Email / notification templates

Diffed against the email inventory's "Quick wire-status rollup" table.
Status updates since that inventory was written: the three "Hook-only
(email template missing)" rows (`backfill_complete`, `backfill_failed`,
`audit_anchor_failure`) shipped per addendum B3. Markdown files now
exist under `tool/advisor_proxy/email_templates/` (verified) AND the
ids are now registered in `EmailTemplateIds.all` at
`lib/services/email/email_template_renderer.dart:157-170` (lines 132-152
document the wire). One stale FOLLOW-UP comment remains in the hook
file pointing at the now-shipped templates.

| Surface | Location (file:line) | Type | Wire-or-delete recommendation | Owner | Effort |
|---|---|---|---|---|---|
| `operator_admin_invite.md` template | `tool/advisor_proxy/email_templates/operator_admin_invite.md` + `lib/services/email/email_template_renderer.dart:89` (id) + `:180` (subject) | Template-only — active invite path reuses Firebase password-reset email; no enqueuer wires this SendGrid template | **Delete in `code_health.email_scaffold_sweep`** (per addendum B4 the dual-invite path question is the relevant decision; if the operator chooses Firebase-only, delete this template + the id; if SendGrid-side invite, wire an enqueuer). C3 lane owns the decision. | C3 email lane | S |
| `operator_invite_first_admin.md` template | `tool/advisor_proxy/email_templates/operator_invite_first_admin.md` + `lib/services/email/email_template_renderer.dart:87-88` (id) + `:177-178` (subject) | Template-only on the invite side; also reused (with fixture data) by the `/v1/admin/integrations/email/test` admin smoke path at `tool/advisor_proxy/admin_email_routes.dart:59-64` | **Keep — anchored to admin-test send.** Used by the admin "Test connection" path; do NOT delete. Mark the doc comment to make this clear (template is reused as the smoke fixture, not unwired). | C3 email lane | XS |
| `password_reset_request.md` template | `tool/advisor_proxy/email_templates/password_reset_request.md` + `lib/services/email/email_template_renderer.dart:90` (id) + `:181-182` (subject) | Template-only — all real password-reset emails come from Firebase Identity Platform action-link template, NOT this SendGrid Markdown | **Delete in `code_health.email_scaffold_sweep`.** The Firebase email is the wire-template; this Markdown has no enqueuer and never will. Removing it also drops the misleading "Reset your Forge & Flow password" subject from `_subjectByTemplate`. | C3 email lane | XS |
| `mfa_factor_changed_notice.md` template | `tool/advisor_proxy/email_templates/mfa_factor_changed_notice.md` + `lib/services/email/email_template_renderer.dart:91` (id) + `:183-184` (subject) | Template-only — no enqueuer in the codebase; phase 9.8 deferred per V1 lean cut | **Wire by `mfa.factor_changed.notify` slice or delete in `code_health.email_scaffold_sweep`.** MFA factor changes are a security-sensitive event (today: only in-app inbox at `lib/services/app_notification_service.dart:114-134`); not emailing the account owner when MFA changes is a real gap. Recommend WIRE: emit from `lib/screens/settings/settings_mfa_section.dart:582` site through a new fanout hook. | C3 email lane | M |
| `vendor_sync_error_alert.md` template | `tool/advisor_proxy/email_templates/vendor_sync_error_alert.md` + `lib/services/email/email_template_renderer.dart:92` (id) + `:185-186` (subject) | Template-only — Phase 8 lean cut deferred this; OAuth-refresh-cron at `lib/services/integration/oauth_refresh_cron.dart` flips `error` but no enqueue | **Wire by `phase_8.email_alert.sync_error` slice or delete in `code_health.email_scaffold_sweep`.** Operators only learn about sustained vendor sync failure by visiting Connected services. Recommend WIRE — this is the "no scaffold" doctrine's strongest case (operator-visible gap with the template already drafted). | C3 email lane | M |
| `vendor_webhook_signature_alert.md` template | `tool/advisor_proxy/email_templates/vendor_webhook_signature_alert.md` + `lib/services/email/email_template_renderer.dart:93-94` (id) + `:187-188` (subject) | Template-only — no observation-window detector in inbound webhook handler; pressure test exercises verifier but not alert | **Wire by `phase_8.email_alert.webhook_signature` slice or delete.** Same call as `vendor_sync_error_alert`. WIRE recommended — security alert is high-value. | C3 email lane | M |
| `vendor_connection_auto_disabled.md` template | `tool/advisor_proxy/email_templates/vendor_connection_auto_disabled.md` + `lib/services/email/email_template_renderer.dart:108-109` (id) + `:189-190` (subject) | Template-only — `OAuthRefreshCron` flips `connection.status = 'error'` after 3 consecutive failures but does not enqueue; explicitly deferred at renderer line 96-107 + project_v1_lean_cut_2_2026_05_03.md round 2 | **Wire by `phase_8.email_alert.auto_disabled` slice or delete.** The deferral was explicit (V1 lean cut round 2). Recommend WIRE — auto-disabling a vendor without notifying the operator is exactly the silent-failure shape addendum B3 hot-fixed. | C3 email lane | M |
| `tos_version_updated_notice.md` template | `tool/advisor_proxy/email_templates/tos_version_updated_notice.md` + `lib/services/email/email_template_renderer.dart:110` (id) + `:191-192` (subject) | Template-only — TOS schema (`db/migrations/202605040100_phase_9_8_tos_versions.sql`) + accept gate (`lib/operator_web/screens/tos_accept_screen.dart`) ship but no published-notice email | **Wire by `phase_9_8.tos.published_email` slice OR keep — anchored to deferred-by-design** per `docs/contracts/operator_self_served_tos_contract.md`. Operator decision: TOS-on-sign-in gate IS the notification today. If the deferral stands, mark the template id with a doc anchor analogous to the `vendorConnectionAutoDisabled` renderer block (lines 96-107). | C3 email lane | XS (anchor) or M (wire) |
| Stale FOLLOW-UP comment in hooks | `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart:59-64` | TODO comment says "FOLLOW-UP: ship the template; until it lands the email channel silently no-ops on render failure" — but the three templates shipped per addendum B3 | **Delete in `code_health.email_scaffold_sweep` (XS).** Stale comment misrepresents current state; remove the FOLLOW-UP block to reduce future-reader confusion. | C3 email lane | XS |

### 2.2 Admin console tiles + screens (`lib/admin/**`)

The admin console route catalog lives at `lib/admin/admin_routes.dart`.
Inventory of placeholder plumbing follows.

| Surface | Location (file:line) | Type | Wire-or-delete recommendation | Owner | Effort |
|---|---|---|---|---|---|
| `AdminRoute.placeholder` field | `lib/admin/admin_routes.dart:121, 150-154` + `lib/admin/admin_shell.dart:277-284, 803, 853, 860-` (`_PlaceholderBody`) | Plumbing — `AdminRoute` constructor accepts `placeholder: false` default and the shell has a full `_PlaceholderBody` widget that renders a branded "coming soon" panel; but ZERO entries in `kAdminRoutes` set `placeholder: true` today (verified by rg) | **Delete in `code_health.admin_route_placeholder_cleanup`.** All 17 admin routes are live. Removing the `placeholder` field + `_PlaceholderBody` + the chevron-clock decorator in side-nav drops ~80 LoC of dead plumbing. POST_HARDENING_FOLLOWUPS.md:459-464 already flags this as P3. | A2-lane | S |
| `DeferredAdminScreenPlaceholder` widget | `lib/admin/widgets/deferred_admin_screen_placeholder.dart` (full file, 90 LoC) | Phase 11A deferred-route placeholder widget — declared, exported, NEVER imported anywhere in `lib/` (verified by rg: only its own file matches) | **Delete in `code_health.admin_route_placeholder_cleanup`.** Pure dead code. Companion to the `AdminRoute.placeholder` field above. | A2-lane | XS |
| `rotateWebhookSigningSecret` gateway method | `lib/services/integration/repository_integration_routes_gateway.dart:861-880` + the rest of the method | Backend method exists with full audit + idempotency wiring + tests; admin UI "Provision A Vendor Webhook Signing Secret" follow-up never landed. TODO marker at line 861 names the missing slice. Operators provision via runbook today. | **Wire by `phase_8.ops_debt.webhook_signing_secret_ui` slice OR delete the method.** The runbook path works; the gateway method has been on master for weeks with no UI caller. Recommend WIRE — webhook signing secret rotation is a real-world operator need and the gateway plumbing is the hard part. UI tile in `integration_admin_screen.dart` is the missing seam. | A2-lane | M |
| `service-principals` admin UI | `lib/services/auth/proxy_service_principal_issuance_gateway.dart` (full file) + proxy `/v1/admin/service-principals` at `tool/advisor_proxy/advisor_proxy.dart:7003-7011` (route constants) | Client-side gateway class ships (full HTTP plumbing, idempotency, error type, tests at `test/proxy_service_principal_issuance_test.dart`) but ZERO callers in `lib/` (verified by rg for `ProxyServicePrincipalIssuanceGateway`). Proxy route handler exists. Phase 9 B41 dropped this for service-principal JWT issuance. | **Wire by `phase_11a.service_principals_admin_ui` slice OR delete the client gateway.** Service principals (`sp:`-prefixed JWTs) ARE used by non-human actors (e.g., backfill worker), so the issuance path is real — but those tokens are minted server-side without going through this client gateway. Recommend DELETE the Flutter-side gateway; service principals don't need a UI tile today. The proxy route stays (it's exercised by tests + the worker bootstrap), but the unused client gateway is dead. | A2-lane | S |
| "Work in progress" badge — Data Accuracy | `lib/admin/admin_routes.dart:342-354` (`AdminRoute` for `kAdminDataAccuracyRouteId`) | Route ships fully functional but carries `badge: 'Work in progress'`. Builds and tests pass; the route is wired through `data_accuracy_admin_gateway.dart`. | **Keep — but remove the badge in `code_health.admin_badge_cleanup`.** The route is live; the "Work in progress" copy is stale scaffolding from an earlier 11A.5 slice. Operators see a "work in progress" label on a route that fully works — confusing. | A2-lane | XS |
| "Work in progress" badge — Polling Setup | `lib/admin/admin_routes.dart:355-366` (`AdminRoute` for `kAdminPollingPricingRouteId`) | Same shape as Data Accuracy. Route is live + tested. | **Keep — but remove the badge.** Same fix as above. | A2-lane | XS |

### 2.3 Operator Web Console (`lib/operator_web/**`)

| Surface | Location (file:line) | Type | Wire-or-delete recommendation | Owner | Effort |
|---|---|---|---|---|---|
| `OperatorWebNavItem.placeholder` field | `lib/operator_web/widgets/web_app_shell.dart:25, 32` + `:640-649` (renders "Soon" chip with tooltip) | Plumbing — `OperatorWebNavItem` constructor admits `placeholder: false` default; shell renders a `Tooltip("This page is a placeholder for V1. The real screen ships in a later slice.")` + "Soon" chip when true; but ZERO entries in the nav-item list (`lib/operator_web/router/operator_web_router.dart:683-768`) set `placeholder: true` today (verified by rg) | **Delete in `code_health.opweb_nav_placeholder_cleanup`.** All 14 operator-web nav items are live routes. Drop the field + the shell's tooltip branch. ~25 LoC. | A2-lane | XS |
| `DeferredScreenPlaceholder` widget | `lib/operator_web/widgets/deferred_screen_placeholder.dart` (full file, 90 LoC) | Phase 11W deferred-route placeholder widget — declared but NEVER imported anywhere in `lib/` (verified by rg) | **Delete in `code_health.opweb_nav_placeholder_cleanup`.** Pure dead code, parallel to the admin variant above. | A2-lane | XS |
| `FirebaseOperatorWebAuthSource.acceptTos` | `lib/operator_web/auth/firebase_operator_web_auth_source.dart:594-598` (throws `UnsupportedError('live TOS acceptance is not exposed by the proxy yet')`) | The TOS-accept flow IS wired in the demo source at `lib/operator_web/auth/operator_web_auth_source.dart:741-` and called from the router at `lib/operator_web/router/operator_web_router.dart:650`; the LIVE source explicitly punts. Proxy carries no `/v1/auth/tos/accept` route (verified by rg in `tool/advisor_proxy/advisor_proxy.dart`). | **Wire by `phase_9_8.live_tos_accept` slice.** This is a P0-shape gap: production operators sign in and the TOS gate's "I accept" button silently throws on live builds. Pair with the `tos_version_updated_notice` template above. | C3 email lane (joint) | M |
| `FirebaseOperatorWebAuthSource.submitPassword` | `lib/operator_web/auth/firebase_operator_web_auth_source.dart:568-575` (throws `UnsupportedError('live password setup is handled by Firebase action links')`) | The demo source implements this for the magic-link onboarding click-path; the live source punts to Firebase action links. The contract IS honored (live operators DO go through Firebase action-link), but the method-shape mismatch is a code-comprehension foot-gun. | **Keep — anchored to Firebase action-link flow.** Document the deliberate divergence with a sharper doc comment that names the live alternative (`web/auth/action/index.html`). | A2-lane | XS |
| `FirebaseOperatorWebAuthSource.beginMfaEnrollment` / `confirmMfaEnrollment` | `lib/operator_web/auth/firebase_operator_web_auth_source.dart:577-591` (both throw `UnsupportedError('live onboarding MFA is handled after sign-in')`) | Same shape as `submitPassword` — onboarding-stage MFA is handled by the post-sign-in `MfaEnrollmentScreen` rather than during onboarding. | **Keep — anchored to post-sign-in MFA enroll flow.** Same doc-comment improvement recommended. | A2-lane | XS |
| Vendor connections backfill `Retry` button | `lib/operator_web/widgets/vendor_connections_backfill_progress_panel.dart:351-369` — disabled `ElevatedButton` with Tooltip `"Retry is not wired yet. Contact Forge & Flow support to requeue this connection."` | UI ships a disabled button that an operator can see and not press. The proxy DOES have backfill machinery (`tool/integration_sync_worker/`, `tool/first_connect_backfill_worker/`) but no `/v1/operators/.../backfill/retry` route surface. | **Wire by `phase_8.backfill_retry_route` slice OR delete the button.** Pattern of "shipping disabled UI with honest copy" is more operator-confusing than removing the button entirely; the support-contact instruction can move to a quieter doc-link affordance below the failure summary. Recommend WIRE — operators hitting a failed backfill almost always want self-serve retry. | A2-lane | M |
| Wage Authority pointer "(coming soon)" | `lib/screens/settings_screen.dart:346-357` (`SettingsPointerRow` with `opWebPath: ''`) | Mobile Settings → Authority tab shows a card "Manage wage setup on Operator Web (coming soon)" — the empty `opWebPath` makes the row render the hourglass icon + non-tappable | Wage authority editor exists on operator-web at `lib/operator_web/screens/wage_authority_screen.dart` (verified). The pointer just needs `opWebPath: 'wage_authority'`. **Wire by `code_health.settings_pointer_wage_authority` slice (XS).** | A2-lane | XS |
| Mobile→OpsWeb handoff via clipboard | `lib/screens/settings/settings_pointer_row.dart:101-120` (`_onTap` copies URL to clipboard + shows SnackBar) | Per addendum A1, the locked handoff mechanism is **redemption-code with RFC 9470 fresh-MFA challenge** — NOT URL-copy-paste. Current behaviour predates A1. | **Wire by `phase_11a.opweb_handoff_redemption_code` slice.** Three settings rows already use this — the live operator can't click through to OpsWeb today; they have to copy and paste manually. A1's redemption-code endpoint is ~1 day of proxy work + the client-side replacement of `_onTap`. | A1/C1 lane (joint) | M |

### 2.4 Mobile screens (`lib/screens/**`)

| Surface | Location (file:line) | Type | Wire-or-delete recommendation | Owner | Effort |
|---|---|---|---|---|---|
| Five `SettingsPointerRow` instances | `lib/screens/settings_screen.dart:244, 263, 290, 330, 349` | Five "Manage X on Operator Web" pointer rows. Four have real `opWebPath` values; one (wage authority, line 349) is empty (already in 2.3 above). | (See 2.3 rows above.) | A2-lane | included |
| `_provenanceLabelFor` TODO | `lib/screens/shift_dashboard.dart:506-519` (`TODO(11W.metric-pill): replace with a proper vendor-display-name lookup table once Phase 8 connector metadata exposes display names.`) | Inline TODO; vendor display labels currently derived by stripping `vendor_` prefix + title-casing. Phase 8 connector metadata HAS shipped (Wave B docs + `phase_8_engineer_all_17_doctrine.md`) — the TODO is actionable now. | **Wire by `code_health.vendor_display_label_lookup` slice (S).** Connector metadata exists; the lookup table is ~30 LoC. | A2-lane | S |

### 2.5 Proxy routes (`tool/advisor_proxy/**`)

Methodology: ripgrepped the 127 `/v1/` path constants in
`advisor_proxy.dart` against `lib/` callers. The smoke / health probe
routes are excluded (deployment-only). Findings:

| Surface | Location (file:line) | Type | Wire-or-delete recommendation | Owner | Effort |
|---|---|---|---|---|---|
| `POST /v1/admin/service-principals` route | `tool/advisor_proxy/advisor_proxy.dart:7003-7011` (route constant + handler) | Route handler is wired and tested at `test/proxy_service_principal_issuance_test.dart`; client gateway exists in `lib/` (`proxy_service_principal_issuance_gateway.dart`) but has no UI caller. Service principals are actually minted server-side at worker bootstrap, not from the Flutter client. | **Keep — anchored to worker bootstrap.** The route IS used (by the worker / proxy bootstrap path); just not from `lib/`. The DELETE recommendation in 2.2 above targets the unused FLUTTER-SIDE gateway, not this proxy route. | — | — |
| `graphify-candidates` 503 scaffold | `tool/advisor_proxy/advisor_proxy.dart:13623-13644` (graph candidates block; 503 `graph_candidates_not_configured`) and `:13705-13713` (`graph_candidates_unavailable`) | Intentional scaffold per PROJECT_TRACKER.md:132-139 — phases 11b / 11A.3.x are AI-paused; route 503s without a hand-staged bundle | **Keep — anchored to AI freeze.** Operator-blessed (PROJECT_TRACKER.md:137: "do not build the bundle staging automation during the freeze"). | — | — |
| `advisor tool definitions placeholder` string | `tool/advisor_proxy/advisor_proxy.dart:9326-9327` (`methodologyContext: 'launch methodology context placeholder'`, `toolDefinitions: 'advisor tool definitions placeholder'`) | Advisor prompt-building site uses literal placeholder strings for methodology + tool definitions. Tracked at `docs/POST_HARDENING_FOLLOWUPS.md:337` as **deferred (AI freeze)** to phase_11b freeze-thaw checklist. | **Keep — anchored to AI freeze + freeze-thaw checklist.** Will be wired when 11b unpauses. | — | — |
| `tool/vector_index_health/main.dart` placeholder snapshot | `tool/vector_index_health/main.dart:55-79` (`placeholderSnapshot` with `activeVectors: 0`, notes string `'CLI placeholder snapshot — no live DB query was issued.'`) | Already flagged as P3 in `POST_HARDENING_FOLLOWUPS.md:246-254`. CLI helper that ships a deterministic placeholder; the production reader at `tool/advisor_proxy/health_producers/vector_producers.dart` queries Postgres correctly. | **Delete in `code_health.vector_index_health_cli_purge`** OR **wire by `phase_11a_5.vector_health_cli` slice.** P3-priority but offends the "no scaffold" directive cleanly; the CLI either becomes a real Postgres-backed query or it goes. Recommend DELETE — the production reader already does this; the CLI duplicates a now-unused path. | A2-lane | XS (delete) or M (wire) |

### 2.6 Database columns / tables

Methodology: I did NOT exhaustively walk every column. Spot-checked
migrations under `db/migrations/**` that the email + admin scaffold
findings hinted at. Findings (Section 6 calls out the limit).

| Surface | Location (file:line) | Type | Wire-or-delete recommendation | Owner | Effort |
|---|---|---|---|---|---|
| `tos_versions` + `tos_acceptances` tables | `db/migrations/202605040100_phase_9_8_tos_versions.sql` | Schema ships, gate-on-sign-in works (see 2.3 `acceptTos` row). The published-notice email side is template-only. | **Keep — schema is consumed.** Pair with the live `acceptTos` wire-up (2.3) and the `tos_version_updated_notice` email decision (2.1). | C3 email lane (joint) | — |
| `user_pii_erasure_requests` table | `db/migrations/202605082000_user_pii_erasure_requests.sql` | Wired end-to-end: route, worker (`PiiErasureWorker`), repository, admin UI. Verified at 33 file matches across `lib/`, `tool/`, `test/`, `runbooks/`. | **Keep — fully wired.** Confirmed clean. | — | — |
| Worker bootstrap `worker_startup_wiring.dart` PII paths | `tool/advisor_proxy/worker_startup_wiring.dart` | Wired (33-file rg match includes the worker). | **Keep.** | — | — |

### 2.7 Feature flags + dart-define gates

Methodology: ripgrep `bool.fromEnvironment(` / `String.fromEnvironment(`
across `lib/`. Categorized by whether the flag has a real production
non-default path.

| Surface | Location (file:line) | Type | Wire-or-delete recommendation | Owner | Effort |
|---|---|---|---|---|---|
| `kDemoMode` reader-side carve-outs (3) | `lib/screens/auth/login_screen.dart:27-29`, `lib/services/app_data_status_service.dart:33`, `lib/screens/settings_screen.dart:39` | Three documented carve-outs in CLAUDE.md Demo Mode block | **Keep — already audited 2026-05-08, operator-signed-off.** | — | — |
| `FORGE_FLOW_DEMO_MODE` (Barrio flavor alias) | `lib/screens/auth/login_screen.dart:29` | OR-ed with `kDemoMode` so the Barrio flavor's existing flag enables the demo sign-in button | **Keep — Barrio flavor compatibility.** | — | — |
| `kMobilePushNotificationsEnabled` | `lib/services/auth/firebase_auth_runtime_bindings.dart:103, 117` | `MOBILE_PUSH_NOTIFICATIONS_ENABLED` dart-define; when false binds `NoopMobilePushTokenGateway`. Per the email inventory, this is the production gate for FCM register/revoke. | **Keep — production gate, intentional default-off until per-flavor rollout.** | — | — |
| `_kAdminDemoAuth` (`ADMIN_DEMO_AUTH`) | `lib/main_admin.dart:62`, `lib/admin/admin_routes.dart:2395` | Demo gate for the admin console; production deploys never set it (verified by `tool/release_build_demo_flag_lint.dart`) | **Keep — production-lint-enforced.** | — | — |
| `_kAdminSharePreview` (`ADMIN_SHARE_PREVIEW`) | `lib/main_admin.dart:68, 123, 172, 215` | Opt-in preview mode for sharing admin screenshots; bound through to `AdminConsoleApp.sharePreviewMode` → `AdminShell.sharePreviewMode` → preview-banner branch at `lib/admin/admin_shell.dart:376-389` | **Keep — share-preview is a real surface, used by operator screenshots.** | — | — |
| `FORGE_FLOW_USE_FIREBASE_AUTH` | `lib/main.dart:8`, `lib/main_forgeflow.dart:28`, `lib/main_barrio.dart:8` | Entry-point branch that decides between local-demo bootstrap and Firebase-auth bootstrap | **Keep — production entry-point gate.** | — | — |
| `_kOperatorWebDemoAuth` (`OPERATOR_WEB_DEMO_AUTH`) | `lib/main_operator_web.dart:66` | Same shape as `_kAdminDemoAuth` for the operator-web flavor | **Keep — production-lint-enforced.** | — | — |

No off-doctrine flags found in this sweep.

### 2.8 Catalog-only notification events (no fanout call site)

| Surface | Location (file:line) | Type | Wire-or-delete recommendation | Owner | Effort |
|---|---|---|---|---|---|
| `notif.shift.stale` event | Catalog entry: `lib/domain/models/notification_event_catalog.dart:132-141`. FOLLOW-UP comment at `tool/advisor_proxy/email_dispatch/notification_event_fanout.dart:739-742`. No trigger site. | Catalog-only — Phase 10b owns the open-shift staleness detector | **Keep — anchored to Phase 10b** (paused per `project_phase_pause_2026_05_03.md`). The catalog seat is what 10b unfreeze fills; deleting it now forces 10b to re-register and re-test. | — | — |
| `notif.star.override` event | Catalog: `notification_event_catalog.dart:142-151`. FOLLOW-UP at `notification_event_fanout.dart:744-748`. No trigger site. | Catalog-only — Phase 11b advisor override surface | **Keep — anchored to Phase 11b** (AI freeze). Same reasoning as above. | — | — |
| `notif.plan.updated` event | Catalog: `notification_event_catalog.dart:152-161`. FOLLOW-UP at `notification_event_fanout.dart:749-753`. Inbox path is WIRED via `AppNotificationService.emitNewWeekSnapshot` at `lib/services/weekly_plan_snapshot_service.dart:190` (`AppNotificationService` line 68-87), but the push fanout (catalog default `push`) has no trigger. | Half-wired — inbox channel works, push channel does NOT | **Wire by `code_health.notif_plan_updated_push` slice.** The weekly-plan locker already calls into `AppNotificationService`; adding `NotificationEventFanout.fanOut` for the push channel is ~20 LoC. The catalog promises push delivery; the implementation drops it on the floor. Real silent-failure shape. | A2-lane | S |

### 2.9 Reserved enum / model values without active raise site

| Surface | Location (file:line) | Type | Wire-or-delete recommendation | Owner | Effort |
|---|---|---|---|---|---|
| `FailureKind.costBreach` | `lib/domain/services/circuit_breaker.dart:20` declared; `tool/advisor_proxy/advisor_proxy.dart:5913` reads it in a switch arm (maps to `SecondaryLlmFailureKind.permanent`); zero raise sites in `lib/` or `tool/` for circuit-breaker classification | Reserved enum value documented at file header lines 4-7 ("`FailureKind.costBreach` is reserved but never raised in v1 production") + anchored to phase 11a decision register Lock 7 (E.2b deferred follow-up) | **Keep — anchored to Lock 7 (`phase_11a_decision_register.md:938-972`).** Reserved with explicit doc anchor. | — | — |
| `MfaPolicy.requiresStaffMfa` always-false getter | `lib/auth/mfa_policy.dart:34-36` (returns `false` unconditionally), referenced only in tests | Stub for "mandatory MFA enforcement for admin-tier accounts is deferred until post-launch stability and explicit approval" per file header line 5 | **Keep — anchored to Phase 9.4 reopen note (file header).** Test coverage protects against accidental policy flip. | — | — |
| 8 `workflow.*` permission keys | `lib/auth/permission_keys.dart:196-204` (`workflowCatalogView`, `workflowRun`, `workflowApprove`, `workflowReject`, `workflowCreate`, `workflowDelete`, `workflowHistoryView`, `workflowToolInvoke`) | Phase 12 placeholder permission keys; never referenced outside their declaration (verified by rg). The frozen catalog comment explicitly calls these "placeholder" at line 37, 196. | **Keep — anchored to Phase 12** (paused). The frozen catalog contract requires keeping the seats so the migration + the permission_key_catalog doc stay in lockstep. Per CLAUDE.md "Service-Layer Split" the auth permission key catalog is FROZEN; touching it requires a contract update. | — | — |

### 2.10 Provider abstractions

Per HP #8 the AI infra abstractions (`LLMProvider`, `EmbeddingProvider`,
`RerankProvider`, `DataSourceProvider`, `IntegrationProvider`) are
deliberate and Phase 12 reuses them — explicitly excluded from this
audit. I confirmed no other single-impl abstraction lives under
`lib/services/**` that lacks an HP #8-level anchor.

---

## Section 3 — Cross-Surface Scaffolds

Things that span surfaces and would otherwise be invisible in any
single subsection.

### 3.1 Mobile Settings → Operator Web bridge is half-wired

Five `SettingsPointerRow` calls in `lib/screens/settings_screen.dart`
(lines 244, 263, 290, 330, 349) push the operator from the mobile
read-only settings tab to the operator-web editor. Three problems
that interact:

1. **One row** (`opWebPath: ''` for wage authority, line 349) renders
   "(coming soon)" even though the editor exists on operator-web. See
   2.3 / 2.4.
2. **All five rows** copy the URL to clipboard rather than using the
   addendum A1 redemption-code handoff. See 2.3 last row.
3. **No row** triggers the addendum A1 fresh-MFA RFC 9470 challenge for
   sensitive targets (account edits, MFA enroll, role mutations,
   billing). Today's clipboard-copy path doesn't expose the operator's
   JWT, so the legacy-OWASP-anti-pattern problem A1 closes is not
   live — but neither is the deep-link UX the addendum promises.

Resolution: one slice covers all five rows + the redemption-code
endpoint + the fresh-MFA gate (this is the "C1 Trust & Account
Control" track from the addendum's wave-shaping decisions).

### 3.2 Live operator-web onboarding has three "UnsupportedError" stubs

`lib/operator_web/auth/firebase_operator_web_auth_source.dart` is the
live operator-web auth source. Three methods throw
`UnsupportedError`:

- `submitPassword` (line 568-575) — anchored to Firebase action links.
- `beginMfaEnrollment` / `confirmMfaEnrollment` (line 577-591) —
  anchored to post-sign-in MFA enroll flow.
- `acceptTos` (line 594-598) — **not anchored anywhere**; no proxy
  route exists.

The first two are honest design choices that just need doc-comment
sharpening. The third is a real gap (see 2.3 + 2.6 + 2.1's
`tos_version_updated_notice`).

### 3.3 Email scaffold cluster covers 7 of 13 V1 templates

From the email inventory's quick-rollup table:
- WIRED: 7 (Firebase actions for reset / verify / invite-via-reset,
  vendor-now-available SendGrid, push runtime, in-app inbox events,
  admin test send).
- TEMPLATE-ONLY: 6 (`mfa_factor_changed_notice`,
  `vendor_sync_error_alert`, `vendor_webhook_signature_alert`,
  `vendor_connection_auto_disabled`, `tos_version_updated_notice`,
  `operator_admin_invite` reuse).
- TEMPLATE + REUSED: 1 (`operator_invite_first_admin` — used as the
  admin test fixture).

That's 6 of 13 unwired templates. Per the C3 wave-shaping decision, the
email pipeline gets its own code-health lane that resolves them all in
one pass.

### 3.4 Coordinate the "placeholder field" deletion across admin + opweb

`AdminRoute.placeholder` (2.2) and `OperatorWebNavItem.placeholder`
(2.3) are parallel constructs. Each has its own unused
`DeferredXScreenPlaceholder` widget. Recommend a single slice that
deletes all four artifacts together so the codebase grows by zero
"deferred-route placeholder" plumbing during this wave.

---

## Section 4 — Prioritization

### P0 — Actively breaks UX

| Entry | Why P0 |
|---|---|
| Live `acceptTos` throws `UnsupportedError` (Section 2.3) | Operators in production hit the TOS-accept screen at sign-in and the button silently throws. Same shape as addendum B3's silent email failures — except this one blocks sign-in completion, not a backfill notification. |
| Wage authority pointer "(coming soon)" (Section 2.3) | Operator-web wage authority editor EXISTS; the mobile pointer claims it doesn't. Operators are told the feature is missing when it's one route name away. |
| `vendor_connection_auto_disabled.md` template-only (Section 2.1) | 3-strike OAuth refresh failures flip a connection to `error` silently — operator only learns by visiting Connected services. Same operator-blind-spot shape as the B3 backfill emails. |

### P1 — Visible but inert

| Entry | Why P1 |
|---|---|
| `vendor_sync_error_alert.md` template-only (Section 2.1) | Sustained vendor sync failure is operator-visible only on the Connected services card. Template ready. |
| `vendor_webhook_signature_alert.md` template-only (Section 2.1) | Security-relevant signal; observation-window detector missing. |
| `mfa_factor_changed_notice.md` template-only (Section 2.1) | MFA-change notification today is in-app inbox only. Email would close the security-event-by-email-confirmation gap. |
| Mobile→OpsWeb clipboard handoff (Section 2.3, 3.1) | Operator sees five pointer rows that nag them to copy a URL. Addendum A1 promised a one-tap redemption-code deep link. |
| Vendor connections backfill `Retry` button disabled (Section 2.3) | Visible disabled button with honest-but-frustrating copy. Operator wants self-serve. |
| `notif.plan.updated` push silently dropped (Section 2.8) | Catalog promises push delivery on weekly-plan-locker; inbox works, push goes nowhere. |
| Mobile shift dashboard vendor display label (Section 2.4) | TODO since the slice landed; connector metadata is now available. Operator sees "Toast Pos" instead of "Toast" today. |

### P2 — Invisible scaffold

| Entry | Why P2 |
|---|---|
| `AdminRoute.placeholder` + `_PlaceholderBody` + `DeferredAdminScreenPlaceholder` (Section 2.2) | Dead code; operators never see it. ~120 LoC across the field + the body widget + the standalone placeholder widget. |
| `OperatorWebNavItem.placeholder` + `DeferredScreenPlaceholder` (Section 2.3) | Parallel dead code on the operator-web side. |
| "Work in progress" badges on live admin routes (Section 2.2) | Operator-visible but the route works — annoyance, not a bug. |
| `rotateWebhookSigningSecret` gateway method (Section 2.2) | Backend method that nobody calls; runbook path works today. |
| Flutter-side `ProxyServicePrincipalIssuanceGateway` (Section 2.2 + 2.5) | Client code that has no caller. Proxy route stays. |
| `tool/vector_index_health/main.dart` placeholder snapshot (Section 2.5) | P3 in POST_HARDENING_FOLLOWUPS; CLI; operators never see it. |
| Stale FOLLOW-UP comment in `notification_event_hooks.dart` (Section 2.1) | 6-line stale comment after B3 hot-fix. |
| `password_reset_request.md` template (Section 2.1) | Markdown file ships, no enqueuer ever. |
| `operator_admin_invite.md` template (Section 2.1) | Same shape. |
| `_kAdminSharePreview` flag — confirmed working (Section 2.7) | Listed for completeness; KEEP. |

---

## Section 5 — Suggested Slice Clustering

P0 + P1 entries grouped into 4 executable slices. Each slice fits a
1–2-week worktree-agent lane per the post-Codex wave plan.

### Slice 1 — `phase_9_8.live_tos_accept` (P0)

**Scope**: wire `acceptTos` end-to-end in operator-web live builds.

**Files touched**:
- `lib/operator_web/auth/firebase_operator_web_auth_source.dart` (~30
  lines: replace the throw with an HTTP call through a new gateway)
- `lib/operator_web/services/operator_web_proxy_client.dart` or a new
  `web_tos_acceptance_gateway.dart` (~80 lines)
- `tool/advisor_proxy/advisor_proxy.dart` (new POST
  `/v1/auth/tos/accept` route, ~120 lines including idempotency +
  fresh-MFA gate)
- `tool/advisor_proxy/admin_email_routes.dart` (optional: enqueue
  `tos_version_updated_notice` on publish — joins Slice 2)
- `test/proxy/auth_tos_acceptance_test.dart` (new)
- `test/operator_web/auth/firebase_operator_web_auth_source_test.dart`
  (extend)

**Dependencies**:
- `tos_versions` + `tos_acceptances` tables (already shipped).
- `OperatorWebTosGateway` interface already exists (used by the demo
  source).

**Size**: M (5 files, ~250 LoC delta).

### Slice 2 — `code_health.email_scaffold_sweep` (P0 + P1, joint with C3 lane)

**Scope**: wire-or-delete every template-only / hook-only email.
Decide each row per the C3 lane's per-feature audit.

**Files touched**:
- Wire path for each of the 4 vendor lifecycle alert templates:
  - `lib/services/integration/oauth_refresh_cron.dart` (emit
    auto-disabled hook)
  - `tool/integration_sync_worker/` (emit sync-error hook on N
    sustained failures)
  - `tool/advisor_proxy/` inbound webhook handler (emit signature
    alert hook on N failed verifications)
  - New `notification_event_hooks.dart` helpers per event
  - 4 new enqueuer call sites
- Wire path for `mfa_factor_changed_notice`:
  - `lib/screens/settings/settings_mfa_section.dart:582` (add email
    enqueue beside the inbox emit)
- Delete path for `password_reset_request.md`,
  `operator_admin_invite.md` if operator confirms Firebase-only:
  - `tool/advisor_proxy/email_templates/*.md` (delete 2 files)
  - `lib/services/email/email_template_renderer.dart` (remove ids +
    subjects)
- Keep `tos_version_updated_notice`: anchor renderer doc-comment to
  `operator_self_served_tos_contract.md`. OR wire alongside Slice 1.
- Delete stale FOLLOW-UP comment in
  `notification_event_hooks.dart:59-64`.

**Dependencies**:
- C3 lane's per-template decision (operator sign-off needed for the 2
  delete candidates).
- Slice 1 if `tos_version_updated_notice` joins this slice.

**Size**: L (12-15 files, ~400 LoC delta).

### Slice 3 — `phase_11a.opweb_handoff_and_settings_pointer` (P0 + P1)

**Scope**: wire addendum A1's redemption-code handoff and fix the
wage-authority pointer.

**Files touched**:
- `tool/advisor_proxy/advisor_proxy.dart` (new redemption-code
  endpoint + table, ~200 LoC with idempotency)
- New `db/migrations/<date>_opweb_handoff_redemption_codes.sql` (~60
  LoC)
- `lib/screens/settings/settings_pointer_row.dart` (replace
  clipboard-copy with redemption-code redeem + `url_launcher`, ~40
  LoC delta)
- `lib/screens/settings_screen.dart:354` (set `opWebPath:
  'wage_authority'` — 1-line fix)
- Fresh-MFA gate (RFC 9470) on sensitive landings — new middleware in
  proxy, ~80 LoC
- 5+ widget tests under `test/screens/settings/`

**Dependencies**:
- Addendum A1 lock (already in effect).
- Operator-web wage-authority screen exists (already shipped).
- Adopted `expand-contract migration convention` per addendum A7.

**Size**: L (8-10 files, ~400 LoC delta).

### Slice 4 — `code_health.dead_placeholder_plumbing_sweep` (P2)

**Scope**: delete the two `placeholder` fields + the two
`DeferredXScreenPlaceholder` widgets + the related shell branches +
the stale "Work in progress" admin badges.

**Files touched**:
- `lib/admin/admin_routes.dart` (remove `placeholder` field +
  constructor + 2 badge strings, ~20 LoC)
- `lib/admin/admin_shell.dart` (remove `_PlaceholderBody` + the three
  `route.placeholder` branches, ~60 LoC)
- `lib/admin/widgets/deferred_admin_screen_placeholder.dart` (delete
  full file, 90 LoC)
- `lib/operator_web/widgets/web_app_shell.dart` (remove `placeholder`
  field + the tooltip branch, ~20 LoC)
- `lib/operator_web/widgets/deferred_screen_placeholder.dart` (delete
  full file, 90 LoC)
- `lib/operator_web/router/operator_web_router.dart` (verify no
  `placeholder:` arg slips through — none today)
- Optional: drop POST_HARDENING_FOLLOWUPS.md P3 line 459-464.
- `tool/vector_index_health/main.dart` (delete the file or rewrite to
  query Postgres; recommend DELETE, ~120 LoC) + `tool/vector_index_health/vector_index_health.dart` review (the library is used by production producers; keep)

**Dependencies**: none (parallel-safe with all other slices).

**Size**: S (8 files, net DELETION of ~400 LoC).

### Slice 5 — `code_health.misc_scaffold_cleanup` (P1 + P2)

**Scope**: small fixes that don't fit a bigger cluster.

**Files touched**:
- `lib/screens/shift_dashboard.dart:506-519` (vendor display label
  lookup — wire to Phase 8 connector metadata)
- `lib/services/weekly_plan_snapshot_service.dart:190` (add
  `NotificationEventFanout.fanOut` call for `notif.plan.updated` push
  channel)
- `lib/operator_web/auth/firebase_operator_web_auth_source.dart`
  (sharpen the doc comments on the three deliberate `UnsupportedError`
  stubs)
- DELETE `lib/services/auth/proxy_service_principal_issuance_gateway.dart`
  + its test (no Flutter caller)
- DELETE the disabled "Retry backfill" button — replace with a quieter
  affordance pointing operators at support (OR pair with Slice for
  retry-route wiring as a P1 enhancement)

**Size**: S (5-6 files, ~120 LoC delta).

### Slice 6 — `phase_8.backfill_retry_route` (P1, optional)

**Scope**: wire the "Retry backfill" button by adding a proxy retry
route. Splits from Slice 5 because backfill state machine deserves a
small standalone audit.

**Files touched**:
- New `POST /v1/operators/{operatorId}/backfill/{jobId}/retry` route
  in `tool/advisor_proxy/advisor_proxy.dart`
- `tool/first_connect_backfill_worker/main.dart` (admit
  `markRetryRequested` shape on `RetryCappingBackfillJobStore`)
- `lib/operator_web/widgets/vendor_connections_backfill_progress_panel.dart:351-369`
  (enable the button, replace tooltip)
- Tests

**Dependencies**: backfill state-machine audit (could be A8's lane).

**Size**: M.

---

## Section 6 — What Was NOT Audited

Explicit limits so downstream lens-audits and the wave plan know where
to fill in:

1. **Performance runtime characteristics.** I did not measure latency,
   memory, or CPU. A4's runtime perf lane owns this.
2. **`lib/data/` SQLite legacy** — explicitly delete-only per
   CLAUDE.md; A9's lane is dedicated to it.
3. **Database column-by-column reachability across all 116
   migrations.** I spot-checked migrations adjacent to scaffold hits
   but did NOT enumerate every column. A5 (schema versioning) or a
   dedicated dormant-column scanner could fill the gap.
4. **`lib/internal/barrio/**` + `lib/main_barrio.dart`** — paused per
   `project_barrio_paused.md` (2026-05-03). "Coming soon" affordances
   inside Barrio screens are inside the freeze and out of scope.
5. **AI-paused surfaces** (`lib/screens/advisor*`, advisor proxy hard-
   coded prompt strings at `advisor_proxy.dart:9326-9327`,
   graphify-candidates 503 scaffolding). Phase 11b's freeze-thaw
   checklist owns these per `POST_HARDENING_FOLLOWUPS.md:337-340`.
6. **Test-only scaffolds.** I did not audit `test/**` for orphan or
   stale fixtures. The test tree has its own audit lane (A10 if not
   yet folded into A3's monolith decomp).
7. **Provider abstractions beyond HP #8.** I verified no
   single-implementation provider abstraction exists outside
   `lib/domain/services/**`. A deeper Service-Layer Split lens
   (A6-shape) could re-examine the boundary between
   `lib/domain/services` (formulas) and `lib/services` (orchestration).
8. **Cloud Run / infra side.** Smoke routes, blob-anchor cron, pg_cron
   schedules in migrations — I confirmed schema and route surfaces
   land but did not verify cron-schedule registration on production
   Cloud SQL.
9. **Walkthrough docs vs runtime.** Several `docs/_walkthroughs/*.md`
   reference UI states that might no longer match runtime. C0 docs
   refresh / A11 walkthrough-truth lens owns this.
10. **`tool/pressure/` harness coverage gaps.** The email inventory
    suggested pressure-test priorities; pressure-harness gap analysis
    sits with A11 (soak harness durable kit).

---

## File Index — Sites flagged in this audit

For downstream agent prompts, every flagged file at a glance:

- `lib/services/email/email_template_renderer.dart` — 4 template-only
  ids (mfaFactorChanged, vendorSyncError, vendorWebhookSig,
  vendorConnectionAutoDisabled, tosVersionUpdated), + 2 deletion
  candidates (passwordReset, operatorAdminInvite).
- `tool/advisor_proxy/email_templates/*.md` — 5 wire-or-delete
  Markdown files.
- `tool/advisor_proxy/email_dispatch/notification_event_hooks.dart:59-64`
  — stale FOLLOW-UP comment.
- `lib/admin/admin_routes.dart:112-173, 348, 361` — `placeholder`
  field + "Work in progress" badges.
- `lib/admin/admin_shell.dart:277-292, 803, 846-` — `_PlaceholderBody`
  + the three uses of `route.placeholder`.
- `lib/admin/widgets/deferred_admin_screen_placeholder.dart` — full
  file, dead code.
- `lib/services/integration/repository_integration_routes_gateway.dart:861-880`
  — `rotateWebhookSigningSecret` method with no UI caller.
- `lib/services/auth/proxy_service_principal_issuance_gateway.dart` —
  full file, Flutter-side gateway with no UI caller.
- `lib/operator_web/widgets/web_app_shell.dart:25, 32, 640-649` —
  `OperatorWebNavItem.placeholder` field + tooltip branch.
- `lib/operator_web/widgets/deferred_screen_placeholder.dart` — full
  file, dead code.
- `lib/operator_web/auth/firebase_operator_web_auth_source.dart:568-598`
  — three `UnsupportedError` stubs (one is a real gap; two are
  deliberate but under-documented).
- `lib/operator_web/widgets/vendor_connections_backfill_progress_panel.dart:351-369`
  — disabled Retry button with "not wired yet" copy.
- `lib/screens/settings_screen.dart:244, 263, 290, 330, 349` — five
  `SettingsPointerRow` clipboard-handoff sites + 1 "(coming soon)"
  row.
- `lib/screens/settings/settings_pointer_row.dart:101-120` — clipboard
  handoff implementation.
- `lib/screens/shift_dashboard.dart:506-519` — vendor display label
  TODO.
- `lib/services/weekly_plan_snapshot_service.dart:190` — missing
  push-channel fanout for `notif.plan.updated`.
- `tool/vector_index_health/main.dart:55-79` — CLI placeholder
  snapshot.
- `tool/advisor_proxy/advisor_proxy.dart:9326-9327` — advisor prompt
  placeholder strings (KEEP per AI freeze).
- `tool/advisor_proxy/advisor_proxy.dart:13623-13713` — graphify-
  candidates 503 scaffold (KEEP per AI freeze).
- `lib/auth/permission_keys.dart:196-204` — 8 `workflow.*` Phase 12
  placeholder keys (KEEP per frozen-catalog contract).
- `lib/domain/services/circuit_breaker.dart:20` — `FailureKind.costBreach`
  reserved (KEEP per Lock 7).
- `lib/auth/mfa_policy.dart:34-36` — `requiresStaffMfa` always-false
  stub (KEEP per Phase 9.4 reopen note).
