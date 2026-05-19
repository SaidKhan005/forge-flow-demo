# Deeper Gap Audit Execution Plan

Branch: `codex/deeper-gap-audit-pass`
Started: 2026-05-19
Base: `origin/master` after PR #1018 landed and was verified.

## Plain English Summary

- PR #1018 landed the role-gate cleanup.
- The next audit used the updated graph and fresh `origin/master`.
- Provenance labels are now closed because the server exposes winning-source metadata and the UI reads it.
- Admin Members and Admin demo role fixtures still show retired v1 role names.
- Mobile Covers writes the right server route, but its copy promises a one-off vendor-cover override the server does not do.
- One auth catalog test is stale and still expects the phantom `operator_admin` wording.
- The role hierarchy contract and a few code comments still mention retired role names, which can mislead future work.

## Role Split

- Orchestrator:
  - Owns merge baseline, final integration, plan doc, stale auth test, verification, commit, push, and PR.
  - Reviews worker output before committing.
- Worker A:
  - Owns Admin Members and Admin demo role cleanup.
  - Files: `lib/admin/services/members_admin_gateway.dart`, `lib/admin/services/demo_members_admin_gateway.dart`, `lib/admin/services/demo_roles_hierarchy_sessions_admin_gateway.dart`, `lib/admin/services/roles_hierarchy_sessions_admin_gateway.dart`, and focused admin tests.
- Worker B:
  - Owns Mobile Covers copy cleanup.
  - Files: `lib/screens/settings/settings_covers_setup_section.dart` and focused mobile settings/covers tests.

## Fix Plan

1. Admin role cleanup:
   - Replace Admin Members seeded picker roles with current v2 roles:
     `operator_owner`, `operator_general_manager`, `location_manager`, `supervisor`.
   - Update role labels so returned v2 rows render human names instead of raw keys.
   - Update demo Members and demo Roles fixtures so walkthroughs show v2 roles.
   - Keep custom role fixtures unchanged.

2. Mobile Covers copy cleanup:
   - Stop saying "manual override" for POS vendors that already send covers.
   - Explain that manual covers are used when a location's covers source is manual or when the POS does not send covers.
   - Remove the promise that typing one number overrides a specific vendor-provided shift.
   - Do not add a new server behavior in this patch.

3. Auth catalog test cleanup:
   - Update `permission_catalog_b5b_test` to expect the active v2 contract.
   - Keep historical migration text intact unless a later migration change is explicitly required.

4. Contract/comment cleanup:
   - Update the live role hierarchy contract to name current v2 seeded roles.
   - Update comments that still describe `operator_admin`, `operator_manager`, `operator_supervisor`, or `operator_staff` as active roles.
   - Leave historical migrations, generated migration summaries, and archive material alone unless a later slice explicitly rewrites them.

## Deferred Or Already Closed

- Provenance labels: closed on current baseline. No fix needed.
- True one-off mobile override over vendor-provided covers: deferred because it needs a product decision and would need to write both manual covers and service-period source semantics.
- Historical migrations and archived docs may still mention v1 role names. Do not rewrite history in this patch.

## Verification

- Focused admin tests touched by v2 role cleanup.
- Focused mobile Covers tests.
- `flutter test test/auth/permission_catalog_b5b_test.dart`
- `dart analyze --fatal-infos` on changed files.
- `dart run tool/ux_em_dash_lint.dart`
- `git diff --check`
