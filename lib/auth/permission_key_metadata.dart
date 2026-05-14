// Wave 2 R-1L - Roles schema rewrite (product label + category +
// scope kind + implies) — Dart-side metadata mirror.
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

/// R-1L per-permission-key metadata. Mirrors the four columns added
/// to `public.permission_keys` by migration
/// `202605142100_phase_R_1L_roles_schema_rewrite.sql`.
class PermissionKeyMetadata {
  const PermissionKeyMetadata({
    required this.productLabel,
    required this.categoryLabel,
    required this.scopeKind,
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
        ),
        PermissionKeys.productBarrioAccess: PermissionKeyMetadata(
          productLabel: 'product',
          categoryLabel: 'Product access',
          scopeKind: PermissionScopeKind.either,
        ),

        // ─── forgeflow.* ────────────────────────────────────────────
        PermissionKeys.forgeflowShiftView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowShiftEdit: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowShiftView],
        ),
        PermissionKeys.forgeflowVarianceView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowVarianceEdit: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowVarianceView],
        ),
        PermissionKeys.forgeflowScheduleView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowScheduleEdit: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowScheduleView],
        ),
        PermissionKeys.forgeflowBaselineView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowBaselineOverride: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowBaselineView],
        ),
        PermissionKeys.forgeflowHistoryView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowBenchmarkView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowBenchmarkEdit: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowBenchmarkView],
        ),
        PermissionKeys.forgeflowTargetProfileView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowTargetProfileManage: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowTargetProfileView],
        ),
        PermissionKeys.forgeflowTargetCycleView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowTargetCycleUnlock: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowTargetCycleView],
        ),
        PermissionKeys.forgeflowTargetCycleReplace: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowTargetCycleView],
        ),
        PermissionKeys.forgeflowWeeklyPlanView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowWeeklyPlanLock: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowWeeklyPlanView],
        ),
        PermissionKeys.forgeflowSettingsView: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.forgeflowSettingsManage: PermissionKeyMetadata(
          productLabel: 'forgeflow',
          categoryLabel: 'Forge & Flow surfaces',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.forgeflowSettingsView],
        ),

        // ─── barrio.* ───────────────────────────────────────────────
        PermissionKeys.barrioHandbookView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.barrioInterviewPlaybookView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.barrioJimTaylorView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.barrioPrestonLeeView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.barrioSupervisorContentView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.barrioElPodioView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.barrioHandbookEdit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.barrioHandbookView],
        ),
        PermissionKeys.barrioInterviewPlaybookEdit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.barrioInterviewPlaybookView],
        ),
        PermissionKeys.barrioPrestonLeeEdit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.barrioPrestonLeeView],
        ),
        PermissionKeys.barrioSupervisorContentEdit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.barrioSupervisorContentView],
        ),
        PermissionKeys.barrioLearningCompleteUnit: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.barrioStreakView: PermissionKeyMetadata(
          productLabel: 'barrio',
          categoryLabel: 'Barrio learning',
          scopeKind: PermissionScopeKind.either,
        ),

        // ─── admin.* ────────────────────────────────────────────────
        PermissionKeys.adminUsersView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.adminUsersCreate: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
        ),
        PermissionKeys.adminUsersDeactivate: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
        ),
        PermissionKeys.adminUsersReactivate: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
        ),
        PermissionKeys.adminUsersSoftDelete: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
        ),
        PermissionKeys.adminUsersErasePii: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
        ),
        PermissionKeys.adminUsersResetPassword: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
        ),
        PermissionKeys.adminUsersResetMfaFactors: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminUsersView],
        ),
        PermissionKeys.adminInvitesCreate: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.adminInvitesRevoke: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.adminRolesView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.adminRolesEditSeeded: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          implies: <String>[PermissionKeys.adminRolesView],
        ),
        PermissionKeys.adminRolesCreateCustom: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminRolesView],
        ),
        PermissionKeys.adminRolesDeleteCustom: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminRolesView],
        ),
        PermissionKeys.adminRolesAssign: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminRolesView],
        ),
        PermissionKeys.adminRolesRevoke: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminRolesView],
        ),
        PermissionKeys.adminAuditLogView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.adminAuditLogExport: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.adminAuditLogView],
        ),
        PermissionKeys.adminTargetCycleUnlock: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.adminPricingTierView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.adminPricingTierEdit: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          implies: <String>[PermissionKeys.adminPricingTierView],
        ),
        PermissionKeys.adminFeatureFlagView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.adminFeatureFlagToggle: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
          implies: <String>[PermissionKeys.adminFeatureFlagView],
        ),
        PermissionKeys.adminStatusPagePublish: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.adminDebugConsoleView: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.adminSessionForceLogout: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.adminServicePrincipalIssueToken: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.adminAuditPrivacyRead: PermissionKeyMetadata(
          productLabel: 'admin',
          categoryLabel: 'F&F admin actions',
          scopeKind: PermissionScopeKind.orgWide,
        ),

        // ─── team.* ─────────────────────────────────────────────────
        PermissionKeys.teamUsersView: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.teamUsersInvite: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
        ),
        PermissionKeys.teamUsersDeactivate: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
        ),
        PermissionKeys.teamUsersReactivate: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
        ),
        PermissionKeys.teamUsersSoftDelete: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
        ),
        PermissionKeys.teamUsersResetPassword: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
        ),
        PermissionKeys.teamUsersResetMfa: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
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
        ),
        PermissionKeys.teamRolesView: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.teamRolesCreateCustom: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamRolesView],
        ),
        PermissionKeys.teamRolesAssign: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamRolesView],
        ),
        PermissionKeys.teamRolesRevoke: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamRolesView],
        ),
        PermissionKeys.teamHierarchySuspend: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.teamHierarchyDelete: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.teamAuditLogView: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.teamAuditLogExport: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamAuditLogView],
        ),
        PermissionKeys.teamSessionForceLogout: PermissionKeyMetadata(
          productLabel: 'team',
          categoryLabel: 'Team management',
          scopeKind: PermissionScopeKind.either,
          implies: <String>[PermissionKeys.teamUsersView],
        ),

        // ─── account.* / business_timing.* ─────────────────────────
        PermissionKeys.accountConfigure: PermissionKeyMetadata(
          productLabel: 'account',
          categoryLabel: 'Account settings',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.businessTimingConfigure: PermissionKeyMetadata(
          productLabel: 'business_timing',
          categoryLabel: 'Business timing',
          scopeKind: PermissionScopeKind.orgWide,
        ),

        // ─── billing.* ──────────────────────────────────────────────
        PermissionKeys.billingInvoiceView: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.billingSubscriptionManage: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.billingPaymentMethodManage: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.billingUsageView: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.billingUsageCapsEdit: PermissionKeyMetadata(
          productLabel: 'billing',
          categoryLabel: 'Billing',
          scopeKind: PermissionScopeKind.orgWide,
        ),

        // ─── integration.* ──────────────────────────────────────────
        PermissionKeys.integrationToastConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.integrationToastView: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.integration7shiftsConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.integration7shiftsView: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.integrationOpentableConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.integrationOpentableView: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.integrationQboConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.integrationXeroConnect: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.integrationKeyRotate: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
        ),
        PermissionKeys.integrationsConfigure: PermissionKeyMetadata(
          productLabel: 'integration',
          categoryLabel: 'Vendor integrations',
          scopeKind: PermissionScopeKind.orgWide,
        ),

        // ─── workflow.* ─────────────────────────────────────────────
        PermissionKeys.workflowCatalogView: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.workflowRun: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.workflowApprove: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.workflowReject: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.workflowCreate: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.workflowDelete: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.workflowHistoryView: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
        ),
        PermissionKeys.workflowToolInvoke: PermissionKeyMetadata(
          productLabel: 'workflow',
          categoryLabel: 'Workflows',
          scopeKind: PermissionScopeKind.either,
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
