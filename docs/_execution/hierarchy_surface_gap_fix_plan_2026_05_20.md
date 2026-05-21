# Hierarchy Surface Gap Fix Plan - 2026-05-20

## Goal

Fix the five remaining hierarchy and UX parity gaps found in the full surface audit:

- Account timezone source wording must stop guessing below Business.
- Account override read responses must include exact winning-source metadata.
- Business Timing must show the full Business -> Brand -> Region -> District -> Location path when available.
- Operator Web Audit Log hierarchy filtering must use the live gateway in Firebase-backed builds.
- Admin Data Accuracy must stop presenting broad scoped override UX when product intent is location-focused.

## Guardrails

- Work happens only in `.codex_worktrees/full-surface-audit`.
- Shared checkout stays on `master`.
- No database migration unless unavoidable. These fixes should use existing hierarchy/account tables and additive response fields.
- Keep existing response fields (`effective`, `override`, `businessDefault`) for compatibility.
- Add optional metadata and UI behavior on top.
- Keep mobile as simple usage and leave vendor integrations location-only.

## Fix Plan

1. Backend account source metadata
   - Add a reusable per-field source object to account override resolved records.
   - Return source type, source id, source label, and whether the value is set at the selected scope.
   - Compute sources for location account overrides.
   - Compute sources for org-unit account overrides.
   - Add source metadata to both operator account override route JSON shapes.

2. Operator Web Account source wording
   - Parse the new `sources` object in `WebAccountGateway`.
   - Use source metadata for timezone, contact, currency/locale, and business-week summary labels.
   - Preserve old fallback behavior when a server does not return `sources`.
   - Add tests for saved lower-scope timezone source labels.

3. Business Timing full hierarchy path
   - Build the full path from the management scope options already loaded by the router.
   - Pass the path into `BusinessTimingEditorScreen`.
   - Render Brand, Region, District, Location Group, and Location rungs.
   - Highlight the actual selected write scope when the dropdown changes.

4. Audit Log live hierarchy gateway
   - Wire `HttpWebAuditLogHierarchyGateway` into `FirebaseOperatorWebAuthSource`.
   - Keep demo and tests on the in-memory fallback when no live provider exists.
   - Add/adjust tests so live source/router can prove the provider is present.

5. Admin Data Accuracy location-only posture
   - Remove the broad "Apply to selected business/org unit" edit affordance.
   - Update the selected-scope notice to say edits are made at location level.
   - Keep broad scopes useful for filtering and review.
   - Update policy/copy tests.

## Execution Result

- Done: account override read responses now include per-field source metadata.
- Done: Operator Web Account uses that metadata for honest source wording after saves, including lower-scope timezone saves.
- Done: Business Timing editor receives and renders the full Business -> Brand -> Region -> District -> Location path when the router has it.
- Done: Business Timing timezone copy is scope-neutral instead of saying "Location timezone" on Region/District edits.
- Done: Firebase-backed Operator Web now wires the live Audit Log hierarchy filter gateway; live builds fail loud if that gateway is missing.
- Done: Admin Data Accuracy now uses broad scopes for review/filtering and keeps repair/editing at the location row.
- Follow-up documented: hidden server-only routes still need a route catalog decision, but none of the five requested gaps depend on that.

## Verification

- `flutter test test/operator_web/screens/account_screen_test.dart`
- `flutter test test/operator_web/services/web_account_gateway_test.dart`
- `flutter test test/proxy/operator_location_account_overrides_routes_test.dart`
- `flutter test test/proxy/operator_account_scope_overrides_routes_test.dart`
- `flutter test test/operator_web/operator_web_router_test.dart`
- `flutter test test/operator_web/auth/firebase_operator_web_auth_source_test.dart`
- `flutter test test/admin/admin_hierarchy_settings_scope_policy_test.dart`
- `flutter test test/admin/admin_parity_copy_test.dart`
- `dart analyze`

