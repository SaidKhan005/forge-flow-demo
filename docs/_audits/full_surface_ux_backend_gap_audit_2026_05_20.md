# Full Surface UX and Backend Gap Audit - 2026-05-20

## Run Context

- Workspace: `.codex_worktrees/full-surface-audit`
- Branch: `codex/full-surface-audit`
- Base audited: `origin/master` at `474e95ce`
- Main checkout: left on `master`
- Method: static code audit across Operator Web, Admin Web, mobile Settings, proxy routes, repositories, migrations, and existing tests.
- Graph: not refreshed in this pass. The repo instruction says Graphify is manual-only unless explicitly requested in the current turn.
- Verification: no tests were run for this audit doc. The checks below come from source and test inspection.

## Execution Closeout Added After Fix Pass

- Fixed in this branch: Gaps 1, 2, 3, 5, and 6.
- Partially fixed in this branch: Gap 4 copy now uses scope-neutral timing wording; exact timing-timezone source labels remain a future polish item because the timing profile read does not yet consume account-source metadata.
- Cleaned in this branch: stale live-code comments that described account org-unit writes or Audit Log hierarchy filtering as future-only.
- Still follow-up: Gap 7 route catalog/classification for hidden or support-only routes.
- Verification after implementation:
  - `dart analyze`
  - Focused `flutter test` suite across Operator Web account/timing/audit, Admin Data Accuracy, proxy routes, and Postgres account repositories.

## Product Scope Assumptions Used

- Mobile remains the simple usage layer. Full setup lives in Operator Web or Admin Web.
- Data Accuracy remains location-oriented for operator workflows.
- Vendor integrations remain location-oriented.
- Business account settings should be editable at Business, Brand, Region, District, Location Group, and Location where the setting is meaningful.
- Logo and business name stay business-level unless the product later wants local branding.
- Every hierarchy-sensitive setting should show selected scope, source/inherited-from, and effective value, or explicitly explain why it cannot.

## Hierarchy Model

- Business: whole restaurant group.
- Brand: real org-unit layer, not just a label.
- Region: org-unit layer under business/brand.
- District: org-unit layer under region/brand.
- Location Group: org-unit layer used for grouped locations.
- Location: individual operating location.

## Surface Map

- Operator Web - Plan: location-scoped operational planning.
- Operator Web - Business account: business identity, logo, contact, currency, locale, timezone.
- Operator Web - Business setup: timing profile, week start, business day start, service periods.
- Operator Web - Locations: hierarchy management.
- Operator Web - My account: signed-in user's profile, security, sessions.
- Operator Web - Team members and Roles: people and access.
- Operator Web - Active sessions and Audit log: access/audit review.
- Operator Web - Vendor integrations: location-only setup and health.
- Operator Web - Data accuracy: location-only covers/wage/walk-in settings, with Wage authority embedded.
- Operator Web - Notifications: signed-in user's notification preferences.
- Admin Web - Business accounts: F&F support entry point into operator, location, hierarchy, data, timing, team, audit, and integrations.
- Admin Web - Data accuracy: support/admin override surface.
- Admin Web - Vendor integrations: support/admin actions for location vendor connections.
- Admin Web - Timing: support/admin repair and effective timing review.
- Admin Web - People/access/roles/sessions/audit: support/admin review and repair.
- Mobile Settings - Setup/Data/Account: simple usage mirror and narrow mobile controls.

## Findings And Status

### Gap 1 - Account timezone source wording is incomplete below Business

- Priority: P1.
- Status: fixed in this branch.
- Area: Operator Web, Business account.
- Evidence:
  - `lib/operator_web/screens/account_screen.dart` computes `timezoneInheritedLabel` only for unsaved drafts.
  - Saved timezone rows call `_sourceLabel(timezoneInheritedLabel)`, so saved lower-scope values fall back to "Set here. Does not inherit from a higher scope."
  - Tests cover Business timezone source wording and Brand/District route usage, but do not prove saved lower-scope timezone source wording.
- App example:
  - You select East Region.
  - The timezone is inherited from Business or a parent Brand.
  - The Account summary can still read like the Region set the timezone itself.
- Why it matters:
  - It breaks the hierarchy promise: selected scope, inherited source, effective value.
  - It is exactly the kind of issue seen in the screenshot where saved values did not update the source wording.
- Fix direction:
  - Use the loaded override envelope for timezone the same way contact/currency/locale do.
  - If `override.ianaTimezone` is present, show "Set here at East Region."
  - If it is absent, show "Inherits from the nearest parent: America/Toronto."
  - Add tests for Brand/Region/District/Location saved timezone source wording.

### Gap 2 - Backend does not return precise account-setting source metadata

- Priority: P1.
- Status: fixed in this branch.
- Area: proxy/repository contract for account overrides.
- Evidence:
  - `LocationAccountOverridesEnvelope` only carries `effective`, `override`, and `businessDefault`.
  - `OrgUnitAccountOverridesRepository.loadEffective` returns nearest parent values for contact/currency/locale/timezone, but does not return which parent supplied the value.
  - For org-unit timezone, fallback is only parent org-unit timezone. It does not name or clearly model a business/location fallback in the same way location timing resolution does.
- App example:
  - You select District.
  - Currency might come from Business, timezone might come from Region, and contact might be set at the District.
  - The frontend can show the values, but it cannot honestly say which specific layer each value came from.
- Why it matters:
  - The UI can only guess source labels.
  - Any future visual audit will keep finding wording drift until the server returns winning source metadata.
- Fix direction:
  - Extend account override responses with per-field source metadata: source type, source id, source display name, and whether the value is set here or inherited.
  - Align location and org-unit account override responses so the frontend does not need special-case source guessing.
  - Keep response compatibility by adding optional fields rather than replacing the existing triple.

### Gap 3 - Business Timing editor does not show the full real hierarchy path

- Priority: P2.
- Status: fixed in this branch.
- Area: Operator Web, Business setup.
- Evidence:
  - `BusinessTimingEditorScreen._buildEditorHierarchyNodes` builds a best-effort tree from business, selected org-unit, and location.
  - The file still has a TODO saying full hierarchy is not wired into this editor.
- App example:
  - The real path might be Business -> Brand -> East Region -> Metro District -> Downtown.
  - When editing East Region timing, the editor shows Business -> East Region -> Location, skipping Brand/District context.
- Why it matters:
  - Brand is supposed to be a real layer.
  - Timing changes are high-impact, so the user needs to see exactly where the profile lands.
- Fix direction:
  - Pass the selected management scope's full hierarchy path into `BusinessTimingEditorScreen`.
  - Render every ancestor in order with the current edit scope highlighted.
  - Keep the scope dropdown, but make the tree a true preview of the write target.

### Gap 4 - Business Timing timezone context is too location-worded for org-unit edits

- Priority: P2.
- Status: partially fixed in this branch. The visible wording is now scope-neutral. Exact source labels remain a future polish item.
- Area: Operator Web, Business setup and Account handoff.
- Evidence:
  - `BusinessTimingEditorScreen._effectiveTimezone` uses the existing timing profile timezone, then `session.primaryLocationTimezone`, then `UTC`.
  - The field label is "Location timezone" and helper text says "Change this in Account or the location record."
- App example:
  - You select East Region and open timing.
  - The editor can show a primary-location timezone even though the edit target is the Region.
  - The user is left wondering whether changing Region timezone in Account will affect this timing profile.
- Why it matters:
  - Account now allows org-unit timezone edits, so Timing should speak the same hierarchy language.
- Fix direction:
  - Rename the read-only field to "Timezone used for this timing profile" or similar.
  - Resolve the timezone for the selected timing scope, not only the primary location fallback.
  - Link the source wording to the same account source metadata from Gap 2.

### Gap 5 - Audit Log has real rows/CSV, but live hierarchy-filter wiring is still deferred

- Priority: P2.
- Status: fixed in this branch.
- Area: Operator Web, Audit log.
- Evidence:
  - `AuditLogScreen` is mounted from the Operator Web nav and CSV export uses the live audit-log gateway.
  - `HttpWebAuditLogHierarchyGateway` exists for `/v1/auth/audit-log/hierarchy`.
  - `FirebaseOperatorWebAuthSource` does not implement `OperatorWebAuditLogHierarchyGatewayProvider`.
  - Router comments document the current fallback to `InMemoryWebAuditLogHierarchyGateway`.
- App example:
  - You open Audit log and export CSV. That path is real.
  - But hierarchy filtering can still be backed by the in-memory fallback instead of the live hierarchy route.
- Why it matters:
  - The screen is visually reachable, but one layer of the audit UX can disagree with the backend route that already exists.
- Fix direction:
  - Wire `HttpWebAuditLogHierarchyGateway` into `FirebaseOperatorWebAuthSource`.
  - Keep demo using the in-memory gateway.
  - Add a router/source test proving live Firebase source uses the HTTP hierarchy gateway.

### Gap 6 - Admin Data Accuracy still presents broad scoped override language

- Priority: P2 product alignment.
- Status: fixed in this branch.
- Area: Admin Web, Data Accuracy.
- Evidence:
  - `per_location_data_accuracy_screen.dart` has an "Apply to selected business/org unit" action card.
  - `admin_hierarchy_settings_scope_policy.dart` says business/org-unit edits create inherited overrides.
  - The product decision in this thread says Data Accuracy and integrations remain location-focused.
- App example:
  - In Admin, select a Region and open Covers and Wage Data Accuracy.
  - The UI can imply one Region-level data accuracy override, even though the desired product rule is location-level setup.
- Why it matters:
  - This may be a support escape hatch, but the product wording now says location.
- Fix direction:
  - Decide whether this is an intentional F&F support-only override.
  - If not intentional, hide the broad scope edit action and keep row/location edits only.
  - If intentional, relabel it as "Support override" and explain that normal operator setup remains location-only.

### Gap 7 - Some route/gateway surfaces exist without active UX mounting

- Priority: P3.
- Status: documented follow-up.
- Area: hidden server routes and dead/near-dead UI seams.
- Evidence:
  - `GET /v1/operator/audit-chain-anchors/latest` has a gateway/provider, but no active Operator Web UI consumer was found in this pass.
  - `OperatorWebConnectorBackfillJobsGateway` and `VendorConnectionsBackfillProgressPanel` exist, while the current Vendor Connections screen relies on the shared `VendorConnectionsWidget` first-backfill indicators instead.
- App example:
  - The backend can answer "latest audit chain anchor", but the operator does not see an integrity badge or status row.
  - There is a separate backfill progress panel available in code, but the mounted screen does not use that panel directly.
- Why it matters:
  - Hidden routes are not automatically bugs, but they should be classified as internal-only, future UX, or wired UX.
- Fix direction:
  - Add a small route catalog note for each hidden route.
  - Either mount a useful UX, or document that the route is internal/support-only.

### Gap 8 - Stale comments/docs still describe fixed account/timing work as future work

- Priority: P3 docs/code hygiene.
- Status: live-code comments cleaned in this branch; older historical docs remain archival context.
- Area: Operator Web comments and older execution docs.
- Evidence:
  - Account comments still say org-unit scopes are disabled until a future slice, while the current code enables Brand/Region/District/Location Group writes through `WebAccountScopeOverridesGateway`.
  - `web_account_gateway.dart` comments still describe some backend handlers as future lanes even though current source has corresponding route implementations.
- App example:
  - A future worker reading the comments could avoid using the org-unit route because the comment says it is not live.
- Why it matters:
  - Stale comments create implementation drift and increase the chance of duplicate fixes.
- Fix direction:
  - Update comments to match the current route status.
  - Keep the historical notes only in execution docs if they still matter.

## Closed Or Accepted Items Rechecked

- README/demo Operator Web now wires timing edit, schedule timing, and PNG logo upload through demo gateways.
- Audit Log no longer routes back to Business Account on the audited branch.
- Audit Log CSV export calls the real export route and triggers browser download wiring.
- Brand/Region/District account settings have real org-unit override routes for contact, currency, locale, and timezone.
- Business name and logo are still business-level only, matching the current product direction.
- Business Timing can write business, org-unit, and location profiles.
- Mobile Covers Setup is intentionally simple usage, not full setup.
- Mobile Wage Setup is intentionally read-only from Settings.
- Vendor integrations remain location-only in Operator Web and Admin Web.
- Data Accuracy remains location-oriented in Operator Web.
- Legacy covers source scalar write keys fail closed with HTTP 410.
- Old hidden benchmark override write paths are retired/fail-closed.
- Per-daypart Learn, Baseline preview, and Shift daypart scaffolding are materially wired in current code.
- Star target fallback behavior is intentionally left as a warning/reminder, per product direction.
- The admin email test route is surfaced through the admin integration/testing documentation and integration admin flow, not an unowned route.

## Suggested Fix Order

1. Fix Account timezone source wording in the frontend using current override data.
2. Extend backend account override responses with per-field source metadata.
3. Revisit Account source labels once the server returns exact winning-source metadata.
4. Wire live Audit Log hierarchy filtering into `FirebaseOperatorWebAuthSource`.
5. Upgrade Business Timing editor hierarchy preview to the full path.
6. Align Business Timing timezone wording/source with Account.
7. Decide Admin Data Accuracy broad override posture: remove, hide, or label as support-only.
8. Classify hidden routes and stale comments as docs/cleanup.

## Test Plan For The Fix Pass

- `flutter test test/operator_web/screens/account_screen_test.dart`
- `flutter test test/operator_web/operator_web_router_test.dart`
- `flutter test test/operator_web/services/web_audit_log_hierarchy_gateway_test.dart`
- `flutter test test/proxy/operator_web_audit_log_hierarchy_routes_test.dart`
- `flutter test test/operator_web/screens/audit_log_screen_test.dart`
- Targeted backend repository tests for account override source metadata once added.
- Targeted widget tests for Business Timing hierarchy path once the editor receives full path data.

