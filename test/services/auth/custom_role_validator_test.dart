// Wave 2 Q-4 - Custom role editor advisory validator unit tests.
//
// Pin the three categories called out in debug.md:78-80 (AC-2):
//
//   1. Member-management chain (team.users.* writes without
//      team.users.view; role-management writes without
//      team.roles.view; session force-logout without
//      team.users.view; hierarchy edits without
//      team.audit_log.view).
//   2. Location-scoped role attempting org-wide actions.
//   3. Orphan view-required-for-edit pairs (e.g.
//      forgeflow.shift.edit without forgeflow.shift.view;
//      team.users.invite without team.users.view).
//
// Plus seam checks:
//   - Unknown / out-of-catalog keys are silently dropped (the editor
//     surfaces those via kCustomRoleEditorUnknownKeyMessage).
//   - Business scope suppresses the org-wide warning category.
//   - Warning output is deterministic across rebuilds.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/services/auth/custom_role_validator.dart';

void main() {
  const validator = CustomRoleValidator();

  group('CustomRoleValidator - member management chain', () {
    test(
      'warns when team.users.invite is selected without team.users.view',
      () {
        final warnings = validator.validate(
          {PermissionKeys.teamUsersInvite},
          scope: RoleScope.location,
        );
        final memberWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.memberManagementMissingUsersView,
        );
        expect(memberWarning.severity, RoleWarningSeverity.warn);
        expect(
          memberWarning.affectedKeys,
          contains(PermissionKeys.teamUsersInvite),
        );
        expect(memberWarning.message, contains('team.users.view'));
      },
    );

    test(
      'no member-management warning when team.users.view is present',
      () {
        final warnings = validator.validate(
          {
            PermissionKeys.teamUsersInvite,
            PermissionKeys.teamUsersDeactivate,
            PermissionKeys.teamUsersView,
          },
          scope: RoleScope.location,
        );
        expect(
          warnings.where(
            (w) =>
                w.code == RoleWarningCode.memberManagementMissingUsersView,
          ),
          isEmpty,
        );
      },
    );

    test(
      'covers every team.users.* write key in a single warning when '
      'team.users.view is missing',
      () {
        final selection = {
          PermissionKeys.teamUsersInvite,
          PermissionKeys.teamUsersDeactivate,
          PermissionKeys.teamUsersReactivate,
          PermissionKeys.teamUsersSoftDelete,
          PermissionKeys.teamUsersResetPassword,
          PermissionKeys.teamUsersResetMfa,
        };
        final warnings = validator.validate(
          selection,
          scope: RoleScope.location,
        );
        final memberWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.memberManagementMissingUsersView,
        );
        expect(memberWarning.affectedKeys, containsAll(selection));
      },
    );

    test(
      'warns when role-management writes are selected without '
      'team.roles.view',
      () {
        final warnings = validator.validate(
          {
            PermissionKeys.teamRolesCreateCustom,
            PermissionKeys.teamRolesAssign,
          },
          scope: RoleScope.location,
        );
        final roleWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.roleManagementMissingRolesView,
        );
        expect(roleWarning.severity, RoleWarningSeverity.warn);
        expect(
          roleWarning.affectedKeys,
          containsAll([
            PermissionKeys.teamRolesCreateCustom,
            PermissionKeys.teamRolesAssign,
          ]),
        );
      },
    );

    test(
      'warns when team.session.force_logout selected without '
      'team.users.view',
      () {
        final warnings = validator.validate(
          {PermissionKeys.teamSessionForceLogout},
          scope: RoleScope.location,
        );
        final sessionWarning = warnings.firstWhere(
          (w) =>
              w.code == RoleWarningCode.sessionForceLogoutMissingUsersView,
        );
        expect(sessionWarning.severity, RoleWarningSeverity.warn);
        expect(
          sessionWarning.affectedKeys,
          equals([PermissionKeys.teamSessionForceLogout]),
        );
      },
    );

    test(
      'info-level warning when hierarchy edits selected without '
      'team.audit_log.view',
      () {
        final warnings = validator.validate(
          {PermissionKeys.teamHierarchyDelete},
          scope: RoleScope.location,
        );
        final hierarchyWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.hierarchyMissingAuditView,
        );
        expect(hierarchyWarning.severity, RoleWarningSeverity.info);
        expect(
          hierarchyWarning.affectedKeys,
          equals([PermissionKeys.teamHierarchyDelete]),
        );
      },
    );
  });

  group('CustomRoleValidator - location-scope org-wide actions', () {
    test(
      'warns when location-scoped role selects business_timing.configure',
      () {
        final warnings = validator.validate(
          {PermissionKeys.businessTimingConfigure},
          scope: RoleScope.location,
        );
        final orgWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.locationScopeOrgWideKey,
        );
        expect(orgWarning.severity, RoleWarningSeverity.warn);
        expect(
          orgWarning.affectedKeys,
          contains(PermissionKeys.businessTimingConfigure),
        );
        expect(
          orgWarning.message.toLowerCase(),
          contains('location'),
        );
      },
    );

    test(
      'warns on billing.* + integrations.configure at location scope',
      () {
        final warnings = validator.validate(
          {
            PermissionKeys.billingSubscriptionManage,
            PermissionKeys.integrationsConfigure,
          },
          scope: RoleScope.location,
        );
        final orgWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.locationScopeOrgWideKey,
        );
        expect(
          orgWarning.affectedKeys,
          containsAll([
            PermissionKeys.billingSubscriptionManage,
            PermissionKeys.integrationsConfigure,
          ]),
        );
      },
    );

    test(
      'business scope suppresses the org-wide warning',
      () {
        final warnings = validator.validate(
          {PermissionKeys.businessTimingConfigure},
          scope: RoleScope.business,
        );
        expect(
          warnings.where(
            (w) => w.code == RoleWarningCode.locationScopeOrgWideKey,
          ),
          isEmpty,
        );
      },
    );

    test(
      'forgeflow.* and barrio.* runtime keys are not flagged as '
      'org-wide at location scope',
      () {
        final warnings = validator.validate(
          {
            PermissionKeys.forgeflowShiftView,
            PermissionKeys.forgeflowVarianceView,
            PermissionKeys.barrioHandbookView,
          },
          scope: RoleScope.location,
        );
        expect(
          warnings.where(
            (w) => w.code == RoleWarningCode.locationScopeOrgWideKey,
          ),
          isEmpty,
        );
      },
    );
  });

  group('CustomRoleValidator - orphan view-required-for-edit', () {
    test(
      'warns when forgeflow.shift.edit is selected without '
      'forgeflow.shift.view',
      () {
        final warnings = validator.validate(
          {PermissionKeys.forgeflowShiftEdit},
          scope: RoleScope.business,
        );
        final orphanWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.orphanViewDependency,
        );
        expect(orphanWarning.severity, RoleWarningSeverity.warn);
        expect(
          orphanWarning.affectedKeys,
          contains(PermissionKeys.forgeflowShiftEdit),
        );
      },
    );

    test(
      'covers wage-authority-style stems via forgeflow.target_profile.manage '
      'without forgeflow.target_profile.view',
      () {
        final warnings = validator.validate(
          {PermissionKeys.forgeflowTargetProfileManage},
          scope: RoleScope.business,
        );
        final orphanWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.orphanViewDependency,
        );
        expect(
          orphanWarning.affectedKeys,
          contains(PermissionKeys.forgeflowTargetProfileManage),
        );
      },
    );

    test(
      'no orphan warning when the matching *.view is present',
      () {
        final warnings = validator.validate(
          {
            PermissionKeys.forgeflowShiftView,
            PermissionKeys.forgeflowShiftEdit,
            PermissionKeys.forgeflowVarianceView,
            PermissionKeys.forgeflowVarianceEdit,
          },
          scope: RoleScope.business,
        );
        expect(
          warnings.where(
            (w) => w.code == RoleWarningCode.orphanViewDependency,
          ),
          isEmpty,
        );
      },
    );

    test(
      'collects multiple orphans into a single warning with sorted '
      'affected keys',
      () {
        final warnings = validator.validate(
          {
            PermissionKeys.forgeflowVarianceEdit,
            PermissionKeys.forgeflowShiftEdit,
            PermissionKeys.barrioHandbookEdit,
          },
          scope: RoleScope.business,
        );
        final orphanWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.orphanViewDependency,
        );
        // Sorted alphabetically for deterministic rendering.
        final sorted = List<String>.from(orphanWarning.affectedKeys);
        final expected = List<String>.from(sorted)..sort();
        expect(sorted, equals(expected));
        expect(
          orphanWarning.affectedKeys,
          containsAll([
            PermissionKeys.barrioHandbookEdit,
            PermissionKeys.forgeflowShiftEdit,
            PermissionKeys.forgeflowVarianceEdit,
          ]),
        );
      },
    );

    test(
      'admin.users.create without admin.users.view triggers the orphan '
      'warning',
      () {
        final warnings = validator.validate(
          {PermissionKeys.adminUsersCreate},
          scope: RoleScope.business,
        );
        final orphanWarning = warnings.firstWhere(
          (w) => w.code == RoleWarningCode.orphanViewDependency,
        );
        expect(
          orphanWarning.affectedKeys,
          contains(PermissionKeys.adminUsersCreate),
        );
      },
    );
  });

  group('CustomRoleValidator - seam + determinism', () {
    test('empty selection produces no warnings', () {
      expect(
        validator.validate(
          <String>{},
          scope: RoleScope.location,
        ),
        isEmpty,
      );
      expect(
        validator.validate(
          <String>{},
          scope: RoleScope.business,
        ),
        isEmpty,
      );
    });

    test('unknown / out-of-catalog keys are silently dropped', () {
      // Pure unknown key alone -> no warnings.
      final warningsOnlyUnknown = validator.validate(
        {'not.a.real.key', 'still.invented'},
        scope: RoleScope.location,
      );
      expect(warningsOnlyUnknown, isEmpty);

      // Unknown alongside a known orphan -> known still fires.
      final warningsMixed = validator.validate(
        {'not.a.real.key', PermissionKeys.forgeflowShiftEdit},
        scope: RoleScope.business,
      );
      final orphanWarning = warningsMixed.firstWhere(
        (w) => w.code == RoleWarningCode.orphanViewDependency,
      );
      expect(
        orphanWarning.affectedKeys,
        equals([PermissionKeys.forgeflowShiftEdit]),
      );
    });

    test('validator output is deterministic across rebuilds', () {
      final selection = {
        PermissionKeys.teamUsersInvite,
        PermissionKeys.teamUsersDeactivate,
        PermissionKeys.businessTimingConfigure,
        PermissionKeys.forgeflowShiftEdit,
      };
      final first = validator.validate(
        selection,
        scope: RoleScope.location,
      );
      final second = validator.validate(
        Set<String>.from(selection),
        scope: RoleScope.location,
      );
      expect(first.length, equals(second.length));
      for (var i = 0; i < first.length; i++) {
        expect(first[i].code, equals(second[i].code));
        expect(first[i].affectedKeys, equals(second[i].affectedKeys));
      }
    });

    test('validator returns an unmodifiable list', () {
      final warnings = validator.validate(
        {PermissionKeys.teamUsersInvite},
        scope: RoleScope.location,
      );
      expect(
        () => warnings.add(
          const RoleWarning(
            severity: RoleWarningSeverity.info,
            code: RoleWarningCode.orphanViewDependency,
            affectedKeys: <String>[],
            message: 'mutation should fail',
          ),
        ),
        throwsUnsupportedError,
      );
    });
  });
}
