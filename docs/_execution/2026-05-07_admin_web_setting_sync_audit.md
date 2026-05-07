# Admin / Web Setting Sync Audit

Date: 2026-05-07
Lane: `audit.admin-web-setting-sync` (W5.A in
`~/.claude/plans/which-ux-surfaces-are-eager-summit.md`).
Baseline: `master` at `984aecb1f2bdc4a3a292ea45b40b05ace05fea50`.
Change type: documentation only. No code edits.

## Authority

1. `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md`
   ("Doc 1") — section "Admin/Web Settings Spine" enumerates
   "Already partially wired" vs "Still required". This audit makes
   that table concrete with file paths + sync seams + severity.
2. `docs/_execution/2026-05-07_admin_web_setting_sync_closeout.md` —
   prior status closeout (implemented / partial / future). Compatible
   with this audit; that doc tracks status per Doc 1 area, this doc
   tracks per edit-affordance with concrete remediation seams.
3. `CLAUDE.md` Hard Promise #1 (pure transport swap) and #4 (per-
   operator isolation).
4. `~/.claude/projects/.../memory/project_two_console_framing.md` —
   mobile is view-only / status; operator-web owns configuration.

## Scope

Every operator-edit affordance in `lib/operator_web/screens/**` plus
every F&F-internal edit affordance in `lib/admin/screens/**` whose
output can affect a mobile calculation, mobile interpretation of
data, or mobile access. Operator-only mobile edit surfaces still on
the device today are also surveyed (Wage Authority section, etc.).

This audit produces a remediation backlog only. Implementation is
out of scope for this lane.

## Methodology

For each edit surface:

1. Read the screen file's docstring + form/field definitions to
   identify what value an admin or operator can change.
2. `grep` the mobile codebase
   (`lib/screens/**`, `lib/services/**`, `lib/services/sync/**`,
   `lib/infrastructure/persistence/sqlite/**`) for matching
   read sites + cache rows.
3. `grep` `tool/advisor_proxy/**` for routes that read or write the
   value.
4. Cross-reference
   `lib/services/sync/http_sync_proxy_client.dart` (the canonical
   list of mobile pull surfaces) and
   `lib/services/sync/mobile_operational_sync_runtime.dart`
   (invalidation topics + cross-tenant wipe) to confirm whether the
   value is actually pulled and invalidated.
5. Classify per the taxonomy below.

Sync-status taxonomy:

- **synced** — value flows server → mobile through a proxy GET +
  SQLite cache row + invalidation topic; cross-tenant wipe registered.
- **mobile-cached** — mobile has a local cache, but no proxy GET
  exists in `HttpSyncProxyClient`; cache is populated by mobile
  writes only (split-brain risk if the same value is also editable
  on web/admin).
- **web-only** — setting affects calculations or access but mobile
  receives no signal (push, sync, or invalidation).
- **read-only-on-mobile** — setting is intentionally not editable on
  mobile and not part of mobile calculations (e.g. role catalog
  editing); listed for completeness.
- **unknown** — code search inconclusive.

Severity (only assigned where `web-only` or `unknown`):

- **P0** — calculation drifts silently between web and mobile, or
  permission/access drifts silently; risk of operator confusion or
  data leakage.
- **P1** — calculation correct but operator can't see the latest
  setting on mobile (visibility gap).
- **P2** — cosmetic / non-calculation surface.

## Summary counts

- Total edit affordances audited: **27**.
- **synced**: 12.
- **mobile-cached** (split-brain risk surface): 1.
- **web-only**: 11 (P0: 0 active calculation drift remaining; P1: 8;
  P2: 3).
- **read-only-on-mobile** (intentional, not a sync gap): 3.
- **unknown**: 0.

The previously-flagged P0 wage-mix split-brain is **not active in
production today** because the operator-web Wage Authority parity
screen has not shipped (W3.D is still "future"); however the mobile
edit surface is also gated to view-only when the W3.A collapse
lands. The first lane to ship op-web wage parity without disabling
the mobile edit form would re-introduce the P0. Tracked under
"Latent P0" below.

## Inventory

| # | Setting | Edit surface | Affects mobile calc? | Mobile sync status | Concrete seam | Severity |
|---|---|---|---|---|---|---|
| 1 | Operator account: business name, locale, currency, week-start day, business-day rollover hour, logo | `lib/operator_web/screens/account_screen.dart` (operator-web Account) and `lib/admin/screens/operator_location_admin_screen.dart` (F&F admin) — write through `WebAccountGateway.patchAccount` → `PATCH /v1/operator/account` | partial — `week_start_day` + `business_day_start_local` are part of resolved timing config (mobile uses for week boundaries); business name + locale + logo are display-only | partial | week-start + rollover hour ride the resolved timing config sync (`HttpSyncProxyClient.fetchResolvedTimingConfig` → `/v1/operators/:op/locations/:loc/timing/resolved` → `SqliteRestaurantTimingConfigRepository`); business name + currency + locale + logo have no mobile cache | P1 (visibility — name/locale/currency change on web, mobile shows stale display until next sign-in) |
| 2 | My Account: phone, MFA enrollment, password, T&C acceptance | `lib/operator_web/screens/my_account_screen.dart`, `lib/operator_web/screens/security_screen.dart`, `lib/operator_web/screens/mfa_enrollment_screen.dart`, `lib/operator_web/screens/change_password_dialog.dart` | no — does not affect calculations | n/a | MFA factors and sessions are read by mobile only via auth `/v1/auth/mfa/factors/list`; no mobile cache for T&C acceptance | read-only-on-mobile (W3.A collapses these to view-only with pointer rows) |
| 3 | Business timing profiles + service periods (operator scope) | `lib/operator_web/screens/business_timing_editor_screen.dart` → `WebBusinessTimingGateway` → `POST /v1/operator/business-timing-profiles` + `PATCH /v1/operator/business-timing-profiles/:id` + `POST/PATCH /service-periods` | yes — defines `service_period_key`, week-start, business-day rollover; closed-row daypart resolution depends on it | synced (resolved view only) | mobile reads the resolved bundle via `fetchResolvedTimingConfig` (`/v1/operators/:op/locations/:loc/timing/resolved`) into `SqliteRestaurantTimingConfigRepository`; invalidation topic `business_timing` + `restaurant_timing_configs` is wired in `mobile_operational_sync_runtime.dart` | none (synced); `partial` per closeout doc only because op-web read hydration is demo-fallback |
| 4 | Business timing profiles (location override) | same screen, `_scopeKind == 'location'` | yes (per location daypart resolution) | synced via resolved timing config (per-location resolution server-side) | same as #3 | none |
| 5 | Data accuracy: wage source toggle (per location) | `lib/operator_web/widgets/wage_source_toggle.dart` mounted in `lib/operator_web/screens/data_accuracy_screen.dart` → `OperatorWebDataAccuracyGateway` → server `data_accuracy_settings` | yes — drives labor cost provenance (`labor_wage_source_class.dart`) and which payroll bucket fills `wage_role_rows` | synced | `HttpSyncProxyClient.fetchDataAccuracySettings` → `/v1/operators/:op/locations/:loc/data_accuracy_settings`; mobile keeps the snapshot in process via the orchestrator (no SQLite table — see `postgres_shift_record_to_mobile_sync.dart` line 14-21 docstring); invalidation topic `data_accuracy` wired | none |
| 6 | Data accuracy: covers source per service period (lunch / dinner / late_night) | `lib/operator_web/widgets/covers_source_toggle.dart` + `lib/operator_web/widgets/covers_manual_entry_card.dart` | yes — drives forecast demand source + closed-row covers attribution | synced | `HttpSyncProxyClient.fetchDataAccuracyServicePeriodSettings` → `/v1/operators/:op/locations/:loc/data_accuracy_service_period_settings`; invalidation topic `data_accuracy` + table `data_accuracy_service_period_settings` wired | none — keyed write surface remains operator-blocked per closeout doc remediation #2 |
| 7 | Data accuracy: walk-in handling mode | `lib/operator_web/widgets/walk_in_handling_card.dart` | yes — switches whether reservation walk-ins or POS walk-ins fill the bucket | synced — included in `data_accuracy_settings` snapshot (column `walk_in_handling_mode`) | same seam as #5 | none |
| 8 | Data accuracy: 60-day historical covers seed | `lib/operator_web/widgets/covers_historical_seed_card.dart` | yes — backfills covers when POS does not expose them | partial | upload UX exists on operator-web; mobile reads downstream effects via the same `data_accuracy_settings` + closed-row sync; no per-row seed cache on mobile | P2 (no mobile-side display of seed status; closed rows surface the data) |
| 9 | Polling tier (display-only on operator-web; F&F admin owns the actual write) | `lib/operator_web/widgets/polling_tier_status_card.dart` (display) — write surface is `lib/admin/screens/polling_and_pricing_admin_screen.dart` → `DataAccuracyAdminGateway` | yes — drives expected freshness + sync cadence | synced | `HttpSyncProxyClient.fetchForgeFlowPollingTierAssignment` → `/v1/operators/:op/locations/:loc/polling_tier_assignment`; invalidation topic `polling_tier` + table `forge_flow_polling_tier_assignment` wired | none |
| 10 | Polling tier change requests | F&F admin only — `polling_and_pricing_admin_screen.dart` "Tier change requests" card | yes (after F&F approval flips the tier) | synced — see #9 | n/a | none |
| 11 | Pricing tier (subscription tier on `operators.subscription_tier`) + per-class `usage_caps` | `lib/admin/screens/pricing_tier_admin_screen.dart` → `PricingTierAdminGateway` → `/v1/admin/pricing/operators` + `/v1/admin/pricing/usage-caps` | no on the pure operations surfaces; yes on AI surfaces (caps gate Advisor calls — paused per `memory/project_phase_pause_2026_05_03.md`) | web-only | no mobile pull route; mobile does not call AI today (paused). Caps + tier remain F&F-internal | P2 (paused AI surfaces will need this when 11b unblocks) |
| 12 | Vendor connections: connect / disconnect / OAuth + connect-key + test-connection | `lib/operator_web/screens/vendor_connections_screen.dart` (operator) + `lib/admin/screens/operator_location_admin_screen.dart` "Vendor connections" sub-route (F&F) → `/v1/admin/integrations/{vendor}/connect-key`, `/v1/admin/integrations/{vendor}/disconnect`, `/v1/admin/integrations/oauth/{vendor}/start` | yes — first connect kicks off backfill, ongoing connect-state gates whether mobile shows live data | partial | first-backfill status is synced via `fetchFirstBackfillStatus` (`/v1/operators/:op/locations/:loc/first_backfill_status` → `app_data_status_service.dart`); raw `connector_connection` row + per-vendor enabled flag are NOT pulled to mobile | P1 (mobile cannot tell operator "vendor X is disconnected" without re-deriving from backfill status / data freshness) |
| 13 | Vendor lifecycle "notify me" subscriptions | `lib/operator_web/widgets/vendor_lifecycle_notify_me_dialog.dart` (per W2.D plan, partially wired) | no — email + push delivery only | n/a | server `vendor_lifecycle_notification` table; outbound only (email today, push under W2.C) | n/a |
| 14 | Wage role rows (FOH / BOH / management mix) | `lib/operator_web/screens/wage_authority_screen.dart` — **does not exist yet** (W3.D); current edit surface is mobile-only `lib/screens/settings/settings_wage_authority_section.dart` calling `SqliteWageRoleRowRepository.upsertRow` directly | yes — drives `WageStandardContextService` + `ActiveTargetProfile` projection | mobile-cached + read-synced | mobile READ: `HttpSyncProxyClient.fetchWageRoleRows` → `/v1/operators/:op/locations/:loc/wage_role_rows` → `SqliteWageRoleRowRepository`; invalidation topic `wage_role` wired. mobile WRITE: local SQLite via `upsertRow` with NO proxy POST/PATCH route. Server-truth migration `db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql` exists per closeout doc | **Latent P0** (active write split-brain — see "Latent P0" below) |
| 15 | Members + invites (team) | `lib/operator_web/screens/members_screen.dart`, `lib/operator_web/screens/invite_member_dialog.dart` → `WebTeamUsersGateway` → `/v1/auth/team/users/*` + `/v1/auth/team/invites` | yes — controls who can sign in + their role + visible scopes | web-only on mobile | no mobile cache or pull route; mobile relies on `auth_session` permission claims at sign-in. Mobile Team tab is being unmounted (W3.A) | P1 (visibility — operator-side member changes do not appear on mobile until re-sign-in; permission changes propagate via `roles_version` JWT bump on next refresh) |
| 16 | Roles catalog (custom roles + permission grants on seeded roles) | `lib/operator_web/screens/roles_screen.dart` + `lib/operator_web/screens/custom_role_editor_screen.dart` → `WebTeamRolesGateway` → `/v1/auth/team/roles` + `/v1/auth/team/role-grants` | yes — `roles_version` JWT field gates permission checks on subsequent calls | web-only on mobile | no mobile cache; permissions propagate via JWT `roles` + `roles_version` claim and the proxy snapshot at `/v1/auth/permissions/snapshot`. Mobile Settings → Roles is being unmounted (W3.A) | P1 (visibility only; calculation correctness rides on JWT) |
| 17 | Org hierarchy moves (org_units + location reparenting) | `lib/operator_web/screens/hierarchy_screen.dart` → `WebTeamHierarchyGateway` → `/v1/auth/team/org-units` + `/v1/auth/team/locations/*` | yes — drives accessible business scopes | partial | server reflects moves into `business_scopes` which mobile DOES pull via `fetchAccessibleBusinessScopes` (`/v1/users/:uid/business_scopes` → `SqliteActiveScopeRepository`); invalidation via `business_scope` topic wired in `mobile_operational_sync_runtime.dart`. Hierarchy itself (org_unit tree shape) is NOT cached on mobile — only the resolved scope list | P1 (visibility; mobile drawer only ever shows leaf locations, which is correct per the rollup-truth deferral; org-tree visualization is op-web-only by design) |
| 18 | Active sessions revoke + force-logout | `lib/operator_web/screens/sessions_screen.dart` → `WebTeamSessionsGateway` → `/v1/auth/sessions` + `/v1/auth/session/revoke` + `/v1/auth/session/revoke-all` | no — revoke kills the session, JWT enforces; no mobile-side calc | web-only on mobile | mobile shows its own sessions list via `auth_sessions` reads but the revoke/force-logout buttons are being removed in W3.A; revoked sessions cause the next refresh-token call to 401 and force re-sign-in (already wired in `firebase_auth_runtime_bindings.dart`) | P2 (cosmetic — mobile already handles session death correctly) |
| 19 | Audit log filters + CSV export | `lib/operator_web/screens/audit_log_screen.dart` → `WebTeamAuditLogGateway` → `/v1/auth/audit-log` | no — read-only ledger | n/a | no mobile cache; mobile `SettingsAuditLogSection` is being dropped (W3.A). Op-web-owned per 11W.5 | read-only-on-mobile |
| 20 | Security: per-user MFA factor management + recovery requests | `lib/operator_web/screens/security_screen.dart` + `lib/operator_web/screens/mfa_factor_dialog.dart` → `WebSecurityGateway` → `/v1/auth/mfa/*` | no — auth-side only | web-only on mobile | mobile MFA section is going view-only (W3.A) | P2 (visibility — mobile shows enrolled factors via `/v1/auth/mfa/factors/list` already, so this is fine) |
| 21 | Operator + location CRUD (F&F admin) — onboarding new operator, suspending, reactivating, adding locations with IANA timezone + rollover hour | `lib/admin/screens/operator_location_admin_screen.dart` → `OperatorLocationAdminGateway` → `/v1/admin/operators` + `/v1/admin/locations` | yes — locations and rollover-hour drive resolved timing + accessible scopes | partial | locations propagate to mobile via `business_scopes` pull (#17); rollover hour propagates via resolved timing config (#3); operator-suspended state has no mobile signal (mobile relies on JWT denial) | P1 (visibility — admin suspends an operator and mobile still shows last cached data until token refresh fails) |
| 22 | Per-location data accuracy override (F&F admin) | `lib/admin/screens/per_location_data_accuracy_screen.dart` → `DataAccuracyAdminGateway` → `/v1/admin/data-accuracy/rows` + `/v1/admin/data-accuracy/settings` + `/v1/admin/data-accuracy/audit-history` | yes — same fields as #5/#6 but cross-operator | synced (rides #5/#6 read paths server-side; admin write writes the same `data_accuracy_settings` rows) | mobile pull seams unchanged (#5 + #6) | none |
| 23 | Polling tier definitions + assignments + cadence (F&F admin) | `lib/admin/screens/polling_and_pricing_admin_screen.dart` → `/v1/admin/polling-pricing/tier-definitions` + `/v1/admin/polling-pricing/assignments` + `/v1/admin/polling-pricing/change-requests` | yes — drives expected freshness + cadence | synced — assignment flips reach mobile via #9 | n/a | none |
| 24 | Integration provider keys rotation (Anthropic / Voyage / Azure DB / Gemini / SendGrid) | `lib/admin/screens/integration_admin_screen.dart` → `IntegrationAdminGateway` → `/v1/admin/integrations/rotate-*` | no — server-side calls only | n/a | proxy holds keys; mobile never sees them per HP #7 | n/a |
| 25 | Feature flags toggle | `lib/admin/screens/feature_flags_admin_screen.dart` → `FeatureFlagsAdminGateway` → `/v1/admin/feature-flags/toggle` | yes (some flags affect mobile behavior — e.g. `audit_logs_cutover_enabled`, KMS rollout lanes) | web-only | no mobile flag fetch route; mobile has compile-time `kDemoMode` only | P2 (V1 flags affect server only; only post-V1 flags would expand mobile-side gating) |
| 26 | Corpus admin (advisor knowledge base) | `lib/admin/screens/corpus_admin_screen.dart` → `CorpusAdminGateway` | no — paused (Advisor) | n/a | n/a (paused) | n/a |
| 27 | Notification preferences (per-event, per-channel, per-scope) — **not yet built** | NEW `lib/operator_web/screens/settings_notifications_screen.dart` per W2.B | yes — gates whether push events reach mobile | partial (in flight) | new table `notification_preferences` per W2.B; new proxy GET/PUT/DELETE routes; mobile `app_notifications` SQLite cache is already wired (Phase 7.55p.4d) | tracked in W2.B; not a regression in this audit |

## Latent P0 — Wage role rows write split-brain

The mobile `WageAuthoritySection` writes wage rows directly to
SQLite via `SqliteWageRoleRowRepository.upsertRow` with no proxy
POST. Today this is benign because:

1. The operator-web Wage Authority parity screen (W3.D) has not
   shipped, so admins cannot edit wage on web.
2. The W3.A mobile-collapse plan flips this section to view-only
   (`viewOnly: true` param + edit-form hidden + pointer row).

The split-brain becomes a real **P0** the moment EITHER:

- W3.D op-web wage authority parity ships before W3.A mobile-collapse
  reaches production (an operator could edit on op-web; mobile would
  still hold its locally-edited values and overwrite with stale row
  upserts on next mount), OR
- a future lane re-introduces an edit form on mobile after the
  collapse without first wiring a proxy write route.

**Remediation hypothesis**: before W3.D ships, add a proxy
`POST /v1/operators/:op/locations/:loc/wage_role_rows` write route
mirroring the existing GET; refactor mobile and op-web to write
through that route; remove the direct SQLite `upsertRow` call from
mobile. Server-truth migration
`db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql`
already exists per the closeout doc — the missing piece is the proxy
write route + client refactor.

## P0 findings (active calculation drift)

None active in production today. The latent P0 above is the only
calculation-drift candidate; it is gated on lane sequencing
(W3.A vs W3.D), not on an existing seam.

## P1 findings (visibility gaps)

1. **Operator account display drift (#1)** — business name / locale /
   currency / logo are edited via op-web `/v1/operator/account` but
   not pulled by `HttpSyncProxyClient`. Mobile shows the
   sign-in-time snapshot until next sign-in.
2. **Vendor connection state (#12)** — mobile reads first-backfill
   status but not the per-vendor connect/disconnect signal. A
   disconnected vendor surfaces only as data-staleness on the
   freshness chrome.
3. **Members + invites change (#15)** — mobile relies on
   `roles_version` JWT bump on next refresh; an operator-web admin
   suspending a teammate sees the change immediately on op-web but
   the suspended user's mobile session keeps reading cached SQLite
   data until refresh-token call 401s.
4. **Roles catalog change (#16)** — same JWT-bump pattern as #15.
5. **Org hierarchy reparenting (#17)** — mobile gets the resolved
   accessible-scope list but no tree shape; operator who reparents
   a location sees the new tree on op-web only.
6. **Operator suspended (#21)** — admin-side suspension propagates
   to mobile only via JWT denial on next refresh; mobile shows last
   cached data until then.
7. **Active sessions revoke (#18)** — adjacent to #15/#21; mobile
   detects revocation only via the next refresh-token attempt.
8. **MFA factor inventory (#20)** — mobile MFA section is going
   view-only and reads `/v1/auth/mfa/factors/list` already; visibility
   is OK, listed for completeness.

All of #1, #12, #15, #21 share the same remediation shape: a
realtime invalidation topic + a small mobile pull route +
(optional) a snackbar / inbox notification. None require server
schema changes.

## P2 findings (cosmetic / non-calculation)

- Historical-covers seed status on mobile (#8) — informational only.
- Pricing tier on AI surfaces (#11) — paused.
- Feature flags (#25) — server-side flags don't affect mobile in V1.

## Recommended remediation backlog

Ordered by sequencing dependency.

1. **W5.A.1 — wage_role_rows server-write seam.** Add proxy
   `POST /v1/operators/:op/locations/:loc/wage_role_rows` write
   route + refactor mobile `SettingsWageAuthoritySection` to call it
   instead of local `upsertRow`. Lights up before W3.D op-web wage
   authority parity ships. Files: `tool/advisor_proxy/operator_routes.dart`,
   `lib/services/wage_standard_context_service.dart`,
   `lib/screens/settings/settings_wage_authority_section.dart`,
   `lib/services/sync/http_sync_proxy_client.dart`,
   `lib/services/sync/sync_proxy_client.dart`. Tests:
   `test/proxy/operator_routes_test.dart`,
   `test/services/sync/http_sync_proxy_client_test.dart`,
   `test/services/wage_standard_context_service_test.dart`.

2. **W5.A.2 — operator account snapshot pull.** Add
   `fetchOperatorAccountSnapshot` (business name, locale, currency,
   week-start day cached, logo URL) to `HttpSyncProxyClient` +
   small SQLite cache + invalidation topic `operator_account`. Files:
   `lib/services/sync/http_sync_proxy_client.dart`,
   `lib/services/sync/sync_proxy_client.dart`,
   `lib/services/sync/mobile_operational_sync_runtime.dart`,
   new `lib/infrastructure/persistence/sqlite/repositories/sqlite_operator_account_repository.dart`,
   `tool/advisor_proxy/operator_routes.dart`. Tests in
   `test/proxy/`, `test/services/sync/`,
   `test/infrastructure/persistence/sqlite/`.

3. **W5.A.3 — vendor connection state pull.** Add
   `fetchVendorConnections` (per-location connect-state ledger) to
   `HttpSyncProxyClient` so mobile freshness chrome can distinguish
   "not connected" from "connected but stale". The seam mirrors
   `fetchForgeFlowPollingTierAssignment`. Push event hookup
   piggybacks on W2.C.

4. **W5.A.4 — operator suspension push.** Push event
   `notif.account.suspended` via the W2.C fan-out. No new sync
   route; existing mobile auth refresh handles the actual session
   kill.

5. **W5.A.5 — members/roles/hierarchy change push.** Push event
   `notif.team.changed` to the affected user's mobile session,
   including a `reload_permission_snapshot` payload that the mobile
   client uses to refetch `/v1/auth/permissions/snapshot` without
   waiting for the next refresh-token call. Lights up after W2.C.

6. **W5.A.6 — wage authority parity sequencing gate.** Before W3.D
   merges, check W5.A.1 has shipped. Document this as a sequencing
   dependency in the W3.D prompt so the latent P0 cannot escape.

## Out of scope

Settings that are intentionally web-only because they don't affect
mobile calculations and don't need mobile visibility:

- F&F-internal feature flag toggles (server-side gating only).
- Integration provider keys rotation (server-side only per HP #7).
- Corpus admin (advisor — paused).
- Pricing tier + usage caps (paused AI surfaces).
- Email-template-only notification rules.
- Audit log row inspection (op-web-owned read).
- Active session "Sign out everywhere" UX (W3.A removes from
  mobile; op-web owns).

## Tracker impact

This audit replaces the open `audit.admin-web-setting-sync` lane in
the tracker with the six narrow remediation slices above
(W5.A.1–W5.A.6). The closeout doc
(`2026-05-07_admin_web_setting_sync_closeout.md`) and this audit
together fully describe Doc 1's "Admin/Web Settings Spine"
remaining work.
