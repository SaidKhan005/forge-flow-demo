// Phase 9.0 - Frozen permission key catalog.
//
// This file is constants only. No runtime wiring lives here. Phase 9.7
// adds the runtime PermissionContext + cache + Flutter gates that read
// these constants.
//
// The catalog is mirrored across three locations and they MUST stay in
// sync:
//
//   1. db/migrations/202604250008_auth_schema_foundation.sql
//      (the seed inserted into public.permission_keys at apply time)
//   2. lib/auth/permission_keys.dart (this file)
//   3. docs/contracts/auth_permission_key_catalog.md
//
// Adding a new key:
//   - Add the constant here under the right category.
//   - Add the key to PermissionKeys.all.
//   - Add the row to the migration's `insert into permission_keys`
//     block.
//   - Add the row to the catalog contract doc.
//   - Re-seed by re-applying the migration.
//
// Removing a key is a breaking change and should pass through Phase 9.6
// migration review with audit-trail consequences considered.
//
// Categories follow the plan:
//   - product.*       (2 keys)  product-access gates
//   - forgeflow.*     (20 keys) Forge & Flow surfaces and actions
//   - barrio.*        (12 keys) Barrio destinations and actions
//   - admin.*         (27 keys) admin actions
//   - team.*          (13 keys) operator-self-service team management
//                                (added 9.0a; consumed by 9.10 operator-
//                                facing Settings → Team UX)
//   - billing.*       (5 keys)  billing-related actions
//   - integration.*   (9 keys)  integration management
//   - workflow.*      (8 keys)  Phase 12 workflow capabilities (placeholder)
//
// Total: 96 keys (81 baseline + 13 team.* keys + 2 later admin
// later admin keys added in 9.0Σ.h2/B41). Some keys are flagged
// MFA-required via PermissionKeys.requiresMfa; the migration mirrors
// that in the permission_keys.requires_mfa column.

/// Frozen permission key catalog. See file header for invariants.
class PermissionKeys {
  PermissionKeys._();

  // ─── product.* (2) ────────────────────────────────────────────────
  static const String productForgeflowAccess = 'product.forgeflow.access';
  static const String productBarrioAccess = 'product.barrio.access';

  // ─── forgeflow.* (20) ─────────────────────────────────────────────
  static const String forgeflowShiftView = 'forgeflow.shift.view';
  static const String forgeflowShiftEdit = 'forgeflow.shift.edit';
  static const String forgeflowVarianceView = 'forgeflow.variance.view';
  static const String forgeflowVarianceEdit = 'forgeflow.variance.edit';
  static const String forgeflowScheduleView = 'forgeflow.schedule.view';
  static const String forgeflowScheduleEdit = 'forgeflow.schedule.edit';
  static const String forgeflowBaselineView = 'forgeflow.baseline.view';
  static const String forgeflowBaselineOverride = 'forgeflow.baseline.override';
  static const String forgeflowHistoryView = 'forgeflow.history.view';
  static const String forgeflowBenchmarkView = 'forgeflow.benchmark.view';
  static const String forgeflowBenchmarkEdit = 'forgeflow.benchmark.edit';
  static const String forgeflowTargetProfileView =
      'forgeflow.target_profile.view';
  static const String forgeflowTargetProfileManage =
      'forgeflow.target_profile.manage';
  static const String forgeflowTargetCycleView = 'forgeflow.target_cycle.view';
  static const String forgeflowTargetCycleUnlock =
      'forgeflow.target_cycle.unlock';
  static const String forgeflowTargetCycleReplace =
      'forgeflow.target_cycle.replace';
  static const String forgeflowWeeklyPlanView = 'forgeflow.weekly_plan.view';
  static const String forgeflowWeeklyPlanLock = 'forgeflow.weekly_plan.lock';
  static const String forgeflowSettingsView = 'forgeflow.settings.view';
  static const String forgeflowSettingsManage = 'forgeflow.settings.manage';

  // ─── barrio.* (12) ────────────────────────────────────────────────
  static const String barrioHandbookView = 'barrio.handbook.view';
  static const String barrioInterviewPlaybookView =
      'barrio.interview_playbook.view';
  static const String barrioJimTaylorView = 'barrio.jim_taylor.view';
  static const String barrioPrestonLeeView = 'barrio.preston_lee.view';
  static const String barrioSupervisorContentView =
      'barrio.supervisor_content.view';
  static const String barrioElPodioView = 'barrio.el_podio.view';
  static const String barrioHandbookEdit = 'barrio.handbook.edit';
  static const String barrioInterviewPlaybookEdit =
      'barrio.interview_playbook.edit';
  static const String barrioPrestonLeeEdit = 'barrio.preston_lee.edit';
  static const String barrioSupervisorContentEdit =
      'barrio.supervisor_content.edit';
  static const String barrioLearningCompleteUnit =
      'barrio.learning.complete_unit';
  static const String barrioStreakView = 'barrio.streak.view';

  // ─── admin.* (27) ─────────────────────────────────────────────────
  static const String adminUsersView = 'admin.users.view';
  static const String adminUsersCreate = 'admin.users.create';
  static const String adminUsersDeactivate = 'admin.users.deactivate';
  static const String adminUsersReactivate = 'admin.users.reactivate';
  static const String adminUsersSoftDelete = 'admin.users.soft_delete';
  static const String adminUsersErasePii = 'admin.users.erase_pii'; // MFA
  static const String adminUsersResetPassword = 'admin.users.reset_password';
  static const String adminInvitesCreate = 'admin.invites.create';
  static const String adminInvitesRevoke = 'admin.invites.revoke';
  static const String adminRolesView = 'admin.roles.view';
  static const String adminRolesEditSeeded = 'admin.roles.edit_seeded'; // MFA
  static const String adminRolesCreateCustom = 'admin.roles.create_custom';
  static const String adminRolesDeleteCustom = 'admin.roles.delete_custom';
  static const String adminRolesAssign = 'admin.roles.assign';
  static const String adminRolesRevoke = 'admin.roles.revoke';
  static const String adminAuditLogView = 'admin.audit_log.view';
  static const String adminAuditLogExport = 'admin.audit_log.export';
  static const String adminTargetCycleUnlock = 'admin.target_cycle.unlock';
  static const String adminPricingTierView = 'admin.pricing_tier.view';
  static const String adminPricingTierEdit = 'admin.pricing_tier.edit'; // MFA
  static const String adminFeatureFlagView = 'admin.feature_flag.view';
  static const String adminFeatureFlagToggle = 'admin.feature_flag.toggle';
  static const String adminStatusPagePublish = 'admin.status_page.publish';
  static const String adminDebugConsoleView = 'admin.debug_console.view';
  static const String adminSessionForceLogout = 'admin.session.force_logout';
  static const String adminServicePrincipalIssueToken =
      'admin.service_principal.issue_token'; // MFA
  // Added 9.0Σ.h2 (2026-04-28). Gates the audit-privacy read path on
  // `advisor_conversation_log` (raw encrypted columns). MFA required.
  // Default-granted to `super_admin` and `ff_support` only; operator-
  // tier roles do NOT receive this key by default — raw advisor-
  // conversation content is F&F-internal at launch.
  static const String adminAuditPrivacyRead = 'admin.audit_privacy.read'; // MFA

  // ─── team.* (13) ──────────────────────────────────────────────────
  // Added 9.0a (2026-04-27). Operator-self-service team management;
  // consumed by 9.10 Settings → Team UX. Distinct from admin.* which
  // gates F&F-side admin paths.
  static const String teamUsersView = 'team.users.view';
  static const String teamUsersInvite = 'team.users.invite';
  static const String teamUsersDeactivate = 'team.users.deactivate';
  static const String teamUsersReactivate = 'team.users.reactivate';
  static const String teamUsersSoftDelete = 'team.users.soft_delete';
  static const String teamUsersResetPassword = 'team.users.reset_password';
  static const String teamUsersResetMfa = 'team.users.reset_mfa';
  static const String teamRolesView = 'team.roles.view';
  static const String teamRolesCreateCustom = 'team.roles.create_custom';
  static const String teamRolesAssign = 'team.roles.assign';
  static const String teamRolesRevoke = 'team.roles.revoke';
  static const String teamAuditLogView = 'team.audit_log.view';
  static const String teamSessionForceLogout = 'team.session.force_logout';

  // ─── billing.* (5) ────────────────────────────────────────────────
  static const String billingInvoiceView = 'billing.invoice.view';
  static const String billingSubscriptionManage =
      'billing.subscription.manage'; // MFA
  static const String billingPaymentMethodManage =
      'billing.payment_method.manage'; // MFA
  static const String billingUsageView = 'billing.usage.view';
  static const String billingUsageCapsEdit = 'billing.usage_caps.edit'; // MFA

  // ─── integration.* (9) ────────────────────────────────────────────
  static const String integrationToastConnect = 'integration.toast.connect';
  static const String integrationToastView = 'integration.toast.view';
  static const String integration7shiftsConnect = 'integration.7shifts.connect';
  static const String integration7shiftsView = 'integration.7shifts.view';
  static const String integrationOpentableConnect =
      'integration.opentable.connect';
  static const String integrationOpentableView = 'integration.opentable.view';
  static const String integrationQboConnect = 'integration.qbo.connect';
  static const String integrationXeroConnect = 'integration.xero.connect';
  static const String integrationKeyRotate = 'integration.key_rotate'; // MFA

  // ─── workflow.* (8 placeholder) ───────────────────────────────────
  static const String workflowCatalogView = 'workflow.catalog.view';
  static const String workflowRun = 'workflow.run';
  static const String workflowApprove = 'workflow.approve';
  static const String workflowReject = 'workflow.reject';
  static const String workflowCreate = 'workflow.create';
  static const String workflowDelete = 'workflow.delete';
  static const String workflowHistoryView = 'workflow.history.view';
  static const String workflowToolInvoke = 'workflow.tool.invoke';

  /// Every permission key defined above. Mirrors the seeded rows in
  /// public.permission_keys (~80 rows). Tests assert the migration
  /// includes every key in this set.
  static const Set<String> all = <String>{
    productForgeflowAccess,
    productBarrioAccess,
    forgeflowShiftView,
    forgeflowShiftEdit,
    forgeflowVarianceView,
    forgeflowVarianceEdit,
    forgeflowScheduleView,
    forgeflowScheduleEdit,
    forgeflowBaselineView,
    forgeflowBaselineOverride,
    forgeflowHistoryView,
    forgeflowBenchmarkView,
    forgeflowBenchmarkEdit,
    forgeflowTargetProfileView,
    forgeflowTargetProfileManage,
    forgeflowTargetCycleView,
    forgeflowTargetCycleUnlock,
    forgeflowTargetCycleReplace,
    forgeflowWeeklyPlanView,
    forgeflowWeeklyPlanLock,
    forgeflowSettingsView,
    forgeflowSettingsManage,
    barrioHandbookView,
    barrioInterviewPlaybookView,
    barrioJimTaylorView,
    barrioPrestonLeeView,
    barrioSupervisorContentView,
    barrioElPodioView,
    barrioHandbookEdit,
    barrioInterviewPlaybookEdit,
    barrioPrestonLeeEdit,
    barrioSupervisorContentEdit,
    barrioLearningCompleteUnit,
    barrioStreakView,
    adminUsersView,
    adminUsersCreate,
    adminUsersDeactivate,
    adminUsersReactivate,
    adminUsersSoftDelete,
    adminUsersErasePii,
    adminUsersResetPassword,
    adminInvitesCreate,
    adminInvitesRevoke,
    adminRolesView,
    adminRolesEditSeeded,
    adminRolesCreateCustom,
    adminRolesDeleteCustom,
    adminRolesAssign,
    adminRolesRevoke,
    adminAuditLogView,
    adminAuditLogExport,
    adminTargetCycleUnlock,
    adminPricingTierView,
    adminPricingTierEdit,
    adminFeatureFlagView,
    adminFeatureFlagToggle,
    adminStatusPagePublish,
    adminDebugConsoleView,
    adminSessionForceLogout,
    adminServicePrincipalIssueToken,
    adminAuditPrivacyRead,
    teamUsersView,
    teamUsersInvite,
    teamUsersDeactivate,
    teamUsersReactivate,
    teamUsersSoftDelete,
    teamUsersResetPassword,
    teamUsersResetMfa,
    teamRolesView,
    teamRolesCreateCustom,
    teamRolesAssign,
    teamRolesRevoke,
    teamAuditLogView,
    teamSessionForceLogout,
    billingInvoiceView,
    billingSubscriptionManage,
    billingPaymentMethodManage,
    billingUsageView,
    billingUsageCapsEdit,
    integrationToastConnect,
    integrationToastView,
    integration7shiftsConnect,
    integration7shiftsView,
    integrationOpentableConnect,
    integrationOpentableView,
    integrationQboConnect,
    integrationXeroConnect,
    integrationKeyRotate,
    workflowCatalogView,
    workflowRun,
    workflowApprove,
    workflowReject,
    workflowCreate,
    workflowDelete,
    workflowHistoryView,
    workflowToolInvoke,
  };

  /// Keys that require a fresh `auth_time` MFA assertion to use.
  /// Mirrored in the migration's `requires_mfa = true` rows.
  static const Set<String> requiresMfa = <String>{
    adminUsersErasePii,
    adminRolesEditSeeded,
    adminPricingTierEdit,
    adminServicePrincipalIssueToken,
    adminAuditPrivacyRead,
    billingSubscriptionManage,
    billingPaymentMethodManage,
    billingUsageCapsEdit,
    integrationKeyRotate,
  };

  /// Frozen role keys for the six baseline roles seeded by 9.0. Custom
  /// operator-scoped roles created at runtime via 9.6 are NOT listed
  /// here.
  static const String roleSuperAdmin = 'super_admin';
  static const String roleFfSupport = 'ff_support';
  static const String roleOperatorOwner = 'operator_owner';
  static const String roleOperatorManager = 'operator_manager';
  static const String roleOperatorSupervisor = 'operator_supervisor';
  static const String roleOperatorStaff = 'operator_staff';

  /// Set of all baseline role keys.
  static const Set<String> baselineRoleKeys = <String>{
    roleSuperAdmin,
    roleFfSupport,
    roleOperatorOwner,
    roleOperatorManager,
    roleOperatorSupervisor,
    roleOperatorStaff,
  };
}
