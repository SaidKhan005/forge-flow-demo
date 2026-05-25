import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/default_role_catalog_admin_gateway.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';

void main() {
  group('default role catalog starter payload', () {
    test('carries exactly the active baseline role keys', () {
      final roles = starterRolesByKey();

      expect(roles.keys.toSet(), equals(PermissionKeys.baselineRoleKeys));
      expect(roles, hasLength(10));
    });

    test('each default role mirrors its seeded permission grants', () {
      final actual = <String, Set<String>>{
        for (final roleKey in PermissionKeys.baselineRoleKeys)
          roleKey: permissionKeysForRole(roleKey),
      };

      expect(actual, equals(_expectedPermissionsByRole));
    });

    test('role permission rows are allow-only and not duplicated', () {
      for (final role in starterRolesByKey().values) {
        final roleKey = role['role_key'] as String;
        final permissions = (role['permissions'] as List?) ?? const <Object?>[];
        final seen = <String>{};
        for (final entry in permissions) {
          expect(entry, isA<Map<Object?, Object?>>());
          final map = (entry as Map).cast<String, Object?>();
          expect(map['effect'], 'allow', reason: roleKey);
          expect(seen.add(map['permission_key'] as String), isTrue);
        }
      }
    });
  });
}

const Set<String> _supportPermissions = <String>{
  PermissionKeys.productForgeflowAccess,
  PermissionKeys.productBarrioAccess,
  PermissionKeys.forgeflowShiftView,
  PermissionKeys.forgeflowVarianceView,
  PermissionKeys.forgeflowScheduleView,
  PermissionKeys.forgeflowBaselineView,
  PermissionKeys.forgeflowHistoryView,
  PermissionKeys.forgeflowBenchmarkView,
  PermissionKeys.forgeflowTargetProfileView,
  PermissionKeys.forgeflowTargetCycleView,
  PermissionKeys.forgeflowWeeklyPlanView,
  PermissionKeys.forgeflowSettingsView,
  PermissionKeys.barrioHandbookView,
  PermissionKeys.barrioInterviewPlaybookView,
  PermissionKeys.barrioJimTaylorView,
  PermissionKeys.barrioPrestonLeeView,
  PermissionKeys.barrioSupervisorContentView,
  PermissionKeys.barrioElPodioView,
  PermissionKeys.adminUsersView,
  PermissionKeys.adminAuditLogView,
  PermissionKeys.adminAuditLogExport,
  PermissionKeys.adminDebugConsoleView,
  PermissionKeys.adminFeatureFlagView,
  PermissionKeys.adminPricingTierView,
  PermissionKeys.adminRolesView,
  PermissionKeys.adminUsersResetMfaFactors,
  PermissionKeys.adminAuditPrivacyRead,
  PermissionKeys.adminHierarchyCreate,
  PermissionKeys.adminHierarchyMove,
  PermissionKeys.adminHierarchyRename,
  PermissionKeys.adminHierarchySuspend,
  PermissionKeys.adminHierarchyDelete,
  PermissionKeys.teamRolesDefaultCatalogView,
  PermissionKeys.billingInvoiceView,
  PermissionKeys.billingUsageView,
  PermissionKeys.integrationToastView,
  PermissionKeys.integration7shiftsView,
  PermissionKeys.integrationOpentableView,
};

const Set<String> _operationsPermissions = <String>{
  PermissionKeys.productForgeflowAccess,
  PermissionKeys.productBarrioAccess,
  PermissionKeys.forgeflowShiftView,
  PermissionKeys.forgeflowShiftEdit,
  PermissionKeys.forgeflowVarianceView,
  PermissionKeys.forgeflowVarianceEdit,
  PermissionKeys.forgeflowScheduleView,
  PermissionKeys.forgeflowScheduleEdit,
  PermissionKeys.forgeflowBaselineView,
  PermissionKeys.forgeflowBaselineOverride,
  PermissionKeys.forgeflowHistoryView,
  PermissionKeys.forgeflowBenchmarkView,
  PermissionKeys.forgeflowBenchmarkEdit,
  PermissionKeys.forgeflowTargetProfileView,
  PermissionKeys.forgeflowTargetProfileManage,
  PermissionKeys.forgeflowTargetCycleView,
  PermissionKeys.forgeflowTargetCycleUnlock,
  PermissionKeys.forgeflowTargetCycleReplace,
  PermissionKeys.forgeflowWeeklyPlanView,
  PermissionKeys.forgeflowWeeklyPlanLock,
  PermissionKeys.forgeflowSettingsView,
  PermissionKeys.forgeflowSettingsManage,
  PermissionKeys.barrioHandbookView,
  PermissionKeys.barrioInterviewPlaybookView,
  PermissionKeys.barrioJimTaylorView,
  PermissionKeys.barrioPrestonLeeView,
  PermissionKeys.barrioSupervisorContentView,
  PermissionKeys.barrioSupervisorContentEdit,
  PermissionKeys.barrioElPodioView,
  PermissionKeys.barrioStreakView,
  PermissionKeys.teamUsersView,
  PermissionKeys.teamUsersInvite,
  PermissionKeys.teamUsersDeactivate,
  PermissionKeys.teamUsersReactivate,
  PermissionKeys.teamUsersResetPassword,
  PermissionKeys.teamUsersResetMfa,
  PermissionKeys.teamUsersSelfUpdate,
  PermissionKeys.teamRolesView,
  PermissionKeys.teamRolesAssign,
  PermissionKeys.teamRolesRevoke,
  PermissionKeys.teamAuditLogView,
  PermissionKeys.adminUsersView,
  PermissionKeys.adminAuditLogView,
  PermissionKeys.workflowCatalogView,
  PermissionKeys.workflowRun,
  PermissionKeys.workflowHistoryView,
};

const Set<String> _ownerPermissions = <String>{
  ..._operationsPermissions,
  PermissionKeys.barrioHandbookEdit,
  PermissionKeys.barrioInterviewPlaybookEdit,
  PermissionKeys.barrioPrestonLeeEdit,
  PermissionKeys.barrioLearningCompleteUnit,
  PermissionKeys.teamUsersSoftDelete,
  PermissionKeys.teamRolesCreateCustom,
  PermissionKeys.teamHierarchySuspend,
  PermissionKeys.teamHierarchyDelete,
  PermissionKeys.teamAuditLogExport,
  PermissionKeys.teamSessionForceLogout,
  PermissionKeys.billingInvoiceView,
  PermissionKeys.billingUsageView,
  PermissionKeys.billingUsageCapsEdit,
  PermissionKeys.billingSubscriptionManage,
  PermissionKeys.billingPaymentMethodManage,
  PermissionKeys.accountConfigure,
  PermissionKeys.businessTimingConfigure,
  PermissionKeys.integrationToastConnect,
  PermissionKeys.integrationToastView,
  PermissionKeys.integration7shiftsConnect,
  PermissionKeys.integration7shiftsView,
  PermissionKeys.integrationOpentableConnect,
  PermissionKeys.integrationOpentableView,
  PermissionKeys.integrationQboConnect,
  PermissionKeys.integrationXeroConnect,
  PermissionKeys.integrationKeyRotate,
  PermissionKeys.integrationsConfigure,
  PermissionKeys.adminUsersCreate,
  PermissionKeys.adminUsersDeactivate,
  PermissionKeys.adminUsersReactivate,
  PermissionKeys.adminUsersResetPassword,
  PermissionKeys.adminUsersResetMfaFactors,
  PermissionKeys.adminInvitesCreate,
  PermissionKeys.adminInvitesRevoke,
  PermissionKeys.adminRolesView,
  PermissionKeys.adminRolesCreateCustom,
  PermissionKeys.adminRolesDeleteCustom,
  PermissionKeys.adminRolesAssign,
  PermissionKeys.adminRolesRevoke,
  PermissionKeys.adminAuditLogExport,
  PermissionKeys.adminTargetCycleUnlock,
  PermissionKeys.adminPricingTierView,
  PermissionKeys.adminFeatureFlagView,
  PermissionKeys.adminFeatureFlagToggle,
  PermissionKeys.adminSessionForceLogout,
  PermissionKeys.adminAuditPrivacyRead,
};

const Set<String> _locationManagerPermissions = <String>{
  PermissionKeys.productForgeflowAccess,
  PermissionKeys.productBarrioAccess,
  PermissionKeys.forgeflowShiftView,
  PermissionKeys.forgeflowShiftEdit,
  PermissionKeys.forgeflowVarianceView,
  PermissionKeys.forgeflowScheduleView,
  PermissionKeys.forgeflowScheduleEdit,
  PermissionKeys.forgeflowBaselineView,
  PermissionKeys.forgeflowHistoryView,
  PermissionKeys.forgeflowBenchmarkView,
  PermissionKeys.forgeflowTargetProfileView,
  PermissionKeys.forgeflowTargetCycleView,
  PermissionKeys.forgeflowWeeklyPlanView,
  PermissionKeys.forgeflowSettingsView,
  PermissionKeys.barrioHandbookView,
  PermissionKeys.barrioInterviewPlaybookView,
  PermissionKeys.barrioJimTaylorView,
  PermissionKeys.barrioPrestonLeeView,
  PermissionKeys.barrioSupervisorContentView,
  PermissionKeys.barrioElPodioView,
  PermissionKeys.barrioStreakView,
  PermissionKeys.teamUsersView,
  PermissionKeys.teamUsersInvite,
  PermissionKeys.teamUsersDeactivate,
  PermissionKeys.teamUsersSelfUpdate,
  PermissionKeys.teamRolesView,
  PermissionKeys.teamRolesAssign,
  PermissionKeys.workflowCatalogView,
};

const Set<String> _supervisorPermissions = <String>{
  PermissionKeys.productForgeflowAccess,
  PermissionKeys.productBarrioAccess,
  PermissionKeys.forgeflowShiftView,
  PermissionKeys.forgeflowShiftEdit,
  PermissionKeys.forgeflowVarianceView,
  PermissionKeys.forgeflowScheduleView,
  PermissionKeys.forgeflowHistoryView,
  PermissionKeys.forgeflowWeeklyPlanView,
  PermissionKeys.barrioHandbookView,
  PermissionKeys.barrioInterviewPlaybookView,
  PermissionKeys.barrioJimTaylorView,
  PermissionKeys.barrioPrestonLeeView,
  PermissionKeys.barrioSupervisorContentView,
  PermissionKeys.barrioElPodioView,
  PermissionKeys.barrioLearningCompleteUnit,
  PermissionKeys.barrioStreakView,
  PermissionKeys.teamUsersSelfUpdate,
};

const Set<String> _financeAnalystPermissions = <String>{
  PermissionKeys.billingInvoiceView,
  PermissionKeys.billingUsageView,
  PermissionKeys.billingUsageCapsEdit,
  PermissionKeys.adminAuditLogView,
  PermissionKeys.teamUsersSelfUpdate,
};

const Set<String> _auditorCompliancePermissions = <String>{
  PermissionKeys.adminAuditLogView,
  PermissionKeys.adminAuditLogExport,
  PermissionKeys.adminUsersView,
  PermissionKeys.adminAuditPrivacyRead,
  PermissionKeys.teamAuditLogView,
  PermissionKeys.teamAuditLogExport,
  PermissionKeys.teamUsersSelfUpdate,
};

const Set<String> _trainingLeadPermissions = <String>{
  PermissionKeys.productBarrioAccess,
  PermissionKeys.barrioHandbookView,
  PermissionKeys.barrioInterviewPlaybookView,
  PermissionKeys.barrioInterviewPlaybookEdit,
  PermissionKeys.barrioJimTaylorView,
  PermissionKeys.barrioPrestonLeeView,
  PermissionKeys.barrioSupervisorContentView,
  PermissionKeys.barrioSupervisorContentEdit,
  PermissionKeys.barrioElPodioView,
  PermissionKeys.barrioStreakView,
  PermissionKeys.teamUsersSelfUpdate,
};

const Set<String> _teamAdminPermissions = <String>{
  PermissionKeys.teamUsersView,
  PermissionKeys.teamUsersInvite,
  PermissionKeys.teamUsersDeactivate,
  PermissionKeys.teamUsersReactivate,
  PermissionKeys.teamUsersResetPassword,
  PermissionKeys.teamUsersResetMfa,
  PermissionKeys.teamUsersSelfUpdate,
  PermissionKeys.teamRolesView,
  PermissionKeys.teamRolesAssign,
  PermissionKeys.teamRolesRevoke,
  PermissionKeys.teamAuditLogView,
  PermissionKeys.teamSessionForceLogout,
  PermissionKeys.adminUsersView,
};

const Map<String, Set<String>> _expectedPermissionsByRole =
    <String, Set<String>>{
      PermissionKeys.roleSuperAdmin: PermissionKeys.all,
      PermissionKeys.roleFfSupport: _supportPermissions,
      PermissionKeys.roleOperatorOwner: _ownerPermissions,
      PermissionKeys.roleOperatorGeneralManager: _operationsPermissions,
      PermissionKeys.roleLocationManager: _locationManagerPermissions,
      PermissionKeys.roleSupervisor: _supervisorPermissions,
      PermissionKeys.roleFinanceAnalyst: _financeAnalystPermissions,
      PermissionKeys.roleAuditorCompliance: _auditorCompliancePermissions,
      PermissionKeys.roleTrainingLead: _trainingLeadPermissions,
      PermissionKeys.roleTeamAdmin: _teamAdminPermissions,
    };

Map<String, Map<String, Object?>> starterRolesByKey() {
  return <String, Map<String, Object?>>{
    for (final role
        in defaultRoleCatalogStarterPayload().whereType<Map<String, Object?>>())
      role['role_key'] as String: role,
  };
}

Set<String> permissionKeysForRole(String roleKey) {
  final role = starterRolesByKey()[roleKey]!;
  final permissions = (role['permissions'] as List?) ?? const <Object?>[];
  return <String>{
    for (final entry in permissions)
      if (entry is Map &&
          entry['permission_key'] is String &&
          entry['effect'] == 'allow')
        entry['permission_key'] as String,
  };
}
