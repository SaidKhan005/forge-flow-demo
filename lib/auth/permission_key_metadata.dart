// Wave 2 R-1L / R-2L - Roles schema rewrite (product label + category +
// scope kind + implies + human label) — Dart-side metadata mirror.
//
// The frozen catalog at `lib/auth/permission_keys.dart` declares every
// permission key the runtime knows about. This sibling file carries
// the metadata the R-2L (new Roles editor UI) and S-3 (Roles screen
// simplification) UX slices need:
//
//   * `productLabel`   — product grouping the editor renders.
//   * `categoryLabel`  — UI-grouping label inside the product.
//   * `scopeKind`      — `org_wide` / `location_scoped` / `either`.
//                        Mirrors `permission_keys.scope_kind` schema
//                        check from migration
//                        `202605142100_phase_R_1L_roles_schema_rewrite.sql`.
//   * `implies`        — recursive auto-grant list. When a role grants
//                        this key with effect=allow, the resolver also
//                        grants every key listed here (transitively).
//                        Deny is NEVER propagated through implies.
//   * `humanLabel`     — Wave 2 R-2L per-key UX label. Title Case English,
//                        no underscores, no engineering jargon (per
//                        memory/project_ux_writing_standard.md). Mirrors
//                        `permission_keys.human_label` schema column added
//                        by migration
//                        `202605150000_phase_r2l_default_role_catalog_v2.sql`.
//
// Mirror discipline (same shape as `PermissionKeys.all`):
//   1. `db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql`
//      (the schema columns + backfill).
//   2. `lib/auth/permission_key_metadata.dart` (this file).
//   3. `docs/contracts/auth_permission_key_catalog.md` (catalog prose;
//      Wave 2 R-1L scope only enforces machine mirror at the Dart +
//      migration layer; the contract doc's per-row metadata columns
//      can be expanded in R-2L when the editor needs them
//      operator-facing).
//
// CI enforcement: `tool/permission_key_lint.dart` fails when a key in
// `PermissionKeys.all` is missing from `PermissionKeyMetadata.byKey`
// or carries empty `productLabel` / `categoryLabel`.
//
// The validator's existing const tables (`kOrgWidePermissionKeys`,
// `kViewRequiredForWrite`, `kTeamUsersWriteKeys`) are NOT removed —
// they are unit-test fixtures the Q-4 advisory editor reads directly.
// This file is the schema-side mirror; the validator continues to
// import the dotted-key constants from `permission_keys.dart` and the
// validator tests continue to pass.

import 'permission_keys.dart';

/// R-1L / R-2L per-permission-key metadata. Mirrors the columns added
/// to `public.permission_keys` by migrations
/// `202605142100_phase_R_1L_roles_schema_rewrite.sql` (product_label,
/// category_label, scope_kind, implies) and
/// `202605150000_phase_r2l_default_role_catalog_v2.sql` (human_label).
class PermissionKeyMetadata {
  const PermissionKeyMetadata({
    required this.productLabel,
    required this.categoryLabel,
    required this.scopeKind,
    required this.humanLabel,
    this.implies = const <String>[],
  });

  /// Product grouping for the R-2L editor (e.g. `'forgeflow'`,
  /// `'team'`, `'integration'`). Operator-facing copy lives in
  /// `categoryLabel`; this is the stable machine key the editor
  /// groups by.
  final String productLabel;

  /// UI grouping label rendered above the permission-key list inside
  /// the editor. Plain-English per the UX writing standard.
  final String categoryLabel;

  /// Grantable scope. One of [PermissionScopeKind] values.
  final PermissionScopeKind scopeKind;

  /// Recursive auto-grant list. When a role grants the owning key
  /// with effect=allow, the resolver recursively also grants every
  /// key listed here. Deny is NEVER propagated through implies.
  ///
  /// Wave 2 R-1L scope covers view-required-for-write pairs and
  /// member-management chains; the runtime resolver in
  /// `lib/auth/permission_resolution.dart` walks the imply graph
  /// recursively.
  final List<String> implies;

  /// Wave 2 R-2L per-key UX label. Title Case English, no underscores,
  /// no engineering jargon (per memory/project_ux_writing_standard.md).
  /// Rendered in the role editor + permission explainer surfaces in
  /// place of the raw dotted key. NOT-NULL-at-source via
  /// `tool/permission_key_lint.dart`'s HUMAN_LABEL_INVALID pass; the
  /// matching schema column is nullable per the R-1L expand-contract
  /// precedent (NOT NULL flip parked alongside R-1L-FU).
  final String humanLabel;
}

/// Mirrors the `permission_keys.scope_kind` CHECK constraint values.
enum PermissionScopeKind {
  /// Grantable only at business / org scope. Examples: billing.*,
  /// pricing tier edits, vendor credential rotations.
  orgWide,

  /// Grantable only at a single location. Reserved for future
  /// location-only-by-design keys; no catalog keys carry this scope
  /// at R-1L.
  locationScoped,

  /// Grantable at any scope (business or location). Operational keys
  /// (forgeflow.*, barrio.*, day-to-day team management) default to
  /// this.
  either;

  /// SQL string the migration writes to `scope_kind`.
  String get sqlValue {
    switch (this) {
      case PermissionScopeKind.orgWide:
        return 'org_wide';
      case PermissionScopeKind.locationScoped:
        return 'location_scoped';
      case PermissionScopeKind.either:
        return 'either';
    }
  }
}

/// R-1L metadata catalog. One entry per key in `PermissionKeys.all`.
///
/// Adding a new key requires:
///   1. Add the constant to `PermissionKeys` + `PermissionKeys.all`.
///   2. Add the metadata row here.
///   3. Add the row to the migration seed (foundation or follow-up).
///   4. Add the row to `docs/contracts/auth_permission_key_catalog.md`.
/// `tool/permission_key_lint.dart` fails CI if step 2 is missing.
class PermissionKeyMetadataCatalog {
  PermissionKeyMetadataCatalog._();

  /// Lookup table keyed by dotted permission key.
  static const Map<String, PermissionKeyMetadata> byKey =
      <String, PermissionKeyMetadata>{
        // ─── product.* ──────────────────────────────────────────────
        PermissionKeys.productForgeflowAccess: PermissionKeyMetadata(
          productLabel: 'product',
          categoryLabel: 'Product access',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Open Forge & Flow',
        ),
        PermissionKeys.productBarrioAccess: PermissionKeyMetadata(
          productLabel: 'product',
          categoryLabel: 'Product access',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Open Barrio',
        ),

        // ─── forgeflow.* ────────────────────────────────────────────
        PermissionKeys.forgeflowShiftView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View shift details',
        ),
        PermissionKeys.forgeflowShiftEdit: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowShiftView],
          humanLabel: 'Edit shift details',
        ),
        PermissionKeys.forgeflowVarianceView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View variance results',
        ),
        PermissionKeys.forgeflowVarianceEdit: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowVarianceView],
          humanLabel: 'Adjust variance results',
        ),
        PermissionKeys.forgeflowScheduleView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View schedules',
        ),
        PermissionKeys.forgeflowScheduleEdit: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowScheduleView],
          humanLabel: 'Edit schedules',
        ),
        PermissionKeys.forgeflowBaselineView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View baseline targets',
        ),
        PermissionKeys.forgeflowBaselineOverride: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowBaselineView],
          humanLabel: 'Override baseline targets',
        ),
        PermissionKeys.forgeflowHistoryView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View historical results',
        ),
        PermissionKeys.forgeflowBenchmarkView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View benchmarks',
        ),
        PermissionKeys.forgeflowBenchmarkEdit: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowBenchmarkView],
          humanLabel: 'Edit benchmarks',
        ),
        PermissionKeys.forgeflowTargetProfileView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View target profiles',
        ),
        PermissionKeys.forgeflowTargetProfileManage: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowTargetProfileView],
          humanLabel: 'Manage target profiles',
        ),
        PermissionKeys.forgeflowTargetCycleView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View target cycles',
        ),
        PermissionKeys.forgeflowTargetCycleUnlock: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowTargetCycleView],
          humanLabel: 'Unlock target cycles',
        ),
        PermissionKeys.forgeflowTargetCycleReplace: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowTargetCycleView],
          humanLabel: 'Replace target cycles',
        ),
        PermissionKeys.forgeflowWeeklyPlanView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View weekly plans',
        ),
        PermissionKeys.forgeflowWeeklyPlanLock: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowWeeklyPlanView],
          humanLabel: 'Lock weekly plans',
        ),
        PermissionKeys.forgeflowSettingsView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View Forge & Flow settings',
        ),
        PermissionKeys.forgeflowSettingsManage: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowSettingsView],
          humanLabel: 'Manage Forge & Flow settings',
        ),

        // ─── barrio.* ───────────────────────────────────────────────
        PermissionKeys.barrioHandbookView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View the Barrio handbook',
        ),
        PermissionKeys.barrioInterviewPlaybookView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View the interview playbook',
        ),
        PermissionKeys.barrioJimTaylorView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View the Jim Taylor course',
        ),
        PermissionKeys.barrioPrestonLeeView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View the Preston Lee course',
        ),
        PermissionKeys.barrioSupervisorContentView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View supervisor content',
        ),
        PermissionKeys.barrioElPodioView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View the El Podio course',
        ),
        PermissionKeys.barrioHandbookEdit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.barrioHandbookView],
          humanLabel: 'Edit the Barrio handbook',
        ),
        PermissionKeys.barrioInterviewPlaybookEdit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.barrioInterviewPlaybookView],
          humanLabel: 'Edit the interview playbook',
        ),
        PermissionKeys.barrioPrestonLeeEdit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.barrioPrestonLeeView],
          humanLabel: 'Edit the Preston Lee course',
        ),
        PermissionKeys.barrioSupervisorContentEdit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.barrioSupervisorContentView],
          humanLabel: 'Edit supervisor content',
        ),
        PermissionKeys.barrioLearningCompleteUnit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Mark learning units complete',
        ),
        PermissionKeys.barrioStreakView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View learning streaks',
        ),

        // ─── admin.* ────────────────────────────────────────────────
        PermissionKeys.adminUsersView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View users',
        ),
        PermissionKeys.adminUsersCreate: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
          humanLabel: 'Create users',
        ),
        PermissionKeys.adminUsersDeactivate: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
          humanLabel: 'Deactivate users',
        ),
        PermissionKeys.adminUsersReactivate: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
          humanLabel: 'Reactivate users',
        ),
        PermissionKeys.adminUsersSoftDelete: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
          humanLabel: 'Soft delete users',
        ),
        PermissionKeys.adminUsersErasePii: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
          humanLabel: 'Erase user personal information',
        ),
        PermissionKeys.adminUsersResetPassword: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
          humanLabel: 'Reset user passwords',
        ),
        PermissionKeys.adminUsersResetMfaFactors: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
          humanLabel: 'Reset user MFA factors',
        ),
        PermissionKeys.adminInvitesCreate: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Send invitations',
        ),
        PermissionKeys.adminInvitesRevoke: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Revoke invitations',
        ),
        PermissionKeys.adminRolesView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View roles',
        ),
        PermissionKeys.adminRolesEditSeeded: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          implies: <String>[PermissionKeys.adminRolesView],
          humanLabel: 'Edit seeded roles',
        ),
        PermissionKeys.adminRolesCreateCustom: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminRolesView],
          humanLabel: 'Create custom roles',
        ),
        PermissionKeys.adminRolesDeleteCustom: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminRolesView],
          humanLabel: 'Delete custom roles',
        ),
        PermissionKeys.adminRolesAssign: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminRolesView],
          humanLabel: 'Assign roles',
        ),
        PermissionKeys.adminRolesRevoke: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminRolesView],
          humanLabel: 'Revoke roles',
        ),
        PermissionKeys.adminAuditLogView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View the audit log',
        ),
        PermissionKeys.adminAuditLogExport: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminAuditLogView],
          humanLabel: 'Export the audit log',
        ),
        PermissionKeys.adminTargetCycleUnlock: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Unlock locked target cycles',
        ),
        PermissionKeys.adminPricingTierView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'View pricing tiers',
        ),
        PermissionKeys.adminPricingTierEdit: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          implies: <String>[PermissionKeys.adminPricingTierView],
          humanLabel: 'Edit pricing tiers',
        ),
        PermissionKeys.adminFeatureFlagView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'View feature flags',
        ),
        PermissionKeys.adminFeatureFlagToggle: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          implies: <String>[PermissionKeys.adminFeatureFlagView],
          humanLabel: 'Toggle feature flags',
        ),
        PermissionKeys.adminStatusPagePublish: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Publish status page updates',
        ),
        PermissionKeys.adminDebugConsoleView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'View the debug console',
        ),
        PermissionKeys.adminSessionForceLogout: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Force log out sessions',
        ),
        PermissionKeys.adminServicePrincipalIssueToken: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Issue service principal tokens',
        ),
        PermissionKeys.adminAuditPrivacyRead: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Read sensitive audit details',
        ),

        // ─── team.* ─────────────────────────────────────────────────
        PermissionKeys.teamUsersView: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View team members',
        ),
        PermissionKeys.teamUsersInvite: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
          humanLabel: 'Invite team members',
        ),
        PermissionKeys.teamUsersDeactivate: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
          humanLabel: 'Deactivate team members',
        ),
        PermissionKeys.teamUsersReactivate: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
          humanLabel: 'Reactivate team members',
        ),
        PermissionKeys.teamUsersSoftDelete: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
          humanLabel: 'Soft delete team members',
        ),
        PermissionKeys.teamUsersResetPassword: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
          humanLabel: "Reset a team member's password",
        ),
        PermissionKeys.teamUsersResetMfa: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
          humanLabel: "Reset another user's MFA",
        ),
        // Wave 2 W-3 (2026-05-14). Self-service profile editing — the
        // actor edits their own display name + email. Distinct from
        // `team.users.invite` (admin-edits-someone-else). Does NOT
        // imply `team.users.view` because editing yourself does not
        // require seeing the team list. Granted to every signed-in
        // operator role by default.
        PermissionKeys.teamUsersSelfUpdate: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Update your own profile',
        ),
        PermissionKeys.teamRolesView: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View team roles',
        ),
        PermissionKeys.teamRolesCreateCustom: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamRolesView],
          humanLabel: 'Create custom team roles',
        ),
        PermissionKeys.teamRolesAssign: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamRolesView],
          humanLabel: 'Assign team roles',
        ),
        PermissionKeys.teamRolesRevoke: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamRolesView],
          humanLabel: 'Revoke team roles',
        ),
        PermissionKeys.teamHierarchySuspend: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Suspend hierarchy nodes',
        ),
        PermissionKeys.teamHierarchyDelete: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Delete hierarchy nodes',
        ),
        PermissionKeys.teamAuditLogView: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View the team audit log',
        ),
        PermissionKeys.teamAuditLogExport: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamAuditLogView],
          humanLabel: 'Export the team audit log',
        ),
        PermissionKeys.teamSessionForceLogout: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
          humanLabel: 'Force log out team sessions',
        ),

        // ─── account.* / business_timing.* ─────────────────────────
        PermissionKeys.accountConfigure: PermissionKeyMetadata(
          productLabel: 'account',
          categoryLabel: 'Account settings',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Configure account settings',
        ),
        PermissionKeys.businessTimingConfigure: PermissionKeyMetadata(
          productLabel: 'business_timing',
          categoryLabel: 'Business timing',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Configure business timing',
        ),

        // ─── billing.* ──────────────────────────────────────────────
        PermissionKeys.billingInvoiceView: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'View invoices',
        ),
        PermissionKeys.billingSubscriptionManage: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Manage the subscription plan',
        ),
        PermissionKeys.billingPaymentMethodManage: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Manage payment methods',
        ),
        PermissionKeys.billingUsageView: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'View usage and costs',
        ),
        PermissionKeys.billingUsageCapsEdit: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Adjust usage caps',
        ),

        // ─── integration.* ──────────────────────────────────────────
        PermissionKeys.integrationToastConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Connect Toast POS',
        ),
        PermissionKeys.integrationToastView: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View Toast POS data',
        ),
        PermissionKeys.integration7shiftsConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Connect 7shifts labor',
        ),
        PermissionKeys.integration7shiftsView: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View 7shifts labor data',
        ),
        PermissionKeys.integrationOpentableConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Connect OpenTable reservations',
        ),
        PermissionKeys.integrationOpentableView: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View OpenTable reservation data',
        ),
        PermissionKeys.integrationQboConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Connect QuickBooks Online',
        ),
        PermissionKeys.integrationXeroConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Connect Xero',
        ),
        PermissionKeys.integrationKeyRotate: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Rotate integration keys',
        ),
        PermissionKeys.integrationsConfigure: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
          humanLabel: 'Configure vendor connections',
        ),

        // ─── workflow.* ─────────────────────────────────────────────
        PermissionKeys.workflowCatalogView: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View the workflow catalog',
        ),
        PermissionKeys.workflowRun: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Run workflows',
        ),
        PermissionKeys.workflowApprove: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Approve workflow steps',
        ),
        PermissionKeys.workflowReject: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Reject workflow steps',
        ),
        PermissionKeys.workflowCreate: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Create workflows',
        ),
        PermissionKeys.workflowDelete: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Delete workflows',
        ),
        PermissionKeys.workflowHistoryView: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'View workflow run history',
        ),
        PermissionKeys.workflowToolInvoke: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
          humanLabel: 'Invoke a workflow tool directly',
        ),
      };

  /// Recursive imply walk. Given a starting set of keys granted with
  /// effect=allow, returns the expanded set with every transitively
  /// implied key included. Pure function; the resolver calls this
  /// after collecting the (allow) rules for a user's active grants.
  ///
  /// Cycle-safe — the walk maintains a visited set so a cycle in the
  /// metadata (which should not happen but is enforced at the lint
  /// layer, not at compile time) terminates instead of looping.
  ///
  /// Unknown keys (not in [byKey]) are passed through unchanged — the
  /// resolver is expected to filter them upstream via
  /// `PermissionKeys.all`.
  static Set<String> expandImplies(Iterable<String> startingAllowKeys) {
    final result = <String>{};
    final stack = <String>[...startingAllowKeys];
    while (stack.isNotEmpty) {
      final key = stack.removeLast();
      if (!result.add(key)) continue;
      final meta = byKey[key];
      if (meta == null) continue;
      for (final implied in meta.implies) {
        if (!result.contains(implied)) stack.add(implied);
      }
    }
    return result;
  }
}
