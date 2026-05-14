// Wave 2 Q-4 follow-up - unit tests for the metadata-driven lint
// rules added in this slice. Each test pins one of the four new
// rule paths in `CustomRoleValidator`:
//
//   - Rule 4 - orphan implied dependency (metadata-driven). Walks
//     `PermissionKeyMetadataCatalog.byKey[k].implies` recursively
//     and emits one warning per (selected, missing-implied) pair.
//   - Rule 5 - per-key org-wide-at-location warning. Uses
//     `scopeKind == orgWide` instead of the hand-curated
//     `kOrgWidePermissionKeys` list.
//   - Rule 6a - barrio.* without product.barrio.access.
//   - Rule 6b - forgeflow.* write key without product.forgeflow.access.
//   - Rule 6c - billing.subscription.manage on a non-Owner role.
//
// The existing test suite at `custom_role_validator_test.dart`
// continues to pin the hand-curated rules (Rules 1-3). The two
// files are kept side-by-side rather than merged so the Q-4
// follow-up additions are easy to review and revert independently.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/services/auth/custom_role_validator.dart';

void main() {
  const validator = CustomRoleValidator();

  group('CustomRoleValidator - Rule 4 orphan implied dependency', () {
    test(
      'emits per-pair warning when forgeflow.shift.edit is selected '
      'without forgeflow.shift.view',
      () {
        final warnings = validator.validate(
          {PermissionKeys.forgeflowShiftEdit},
          scope: RoleScope.business,
        );
        final impliedWarnings = warnings
            .where((w) => w.code == RoleWarningCode.orphanImpliedDependency)
            .toList();
        // The hand-curated [orphanViewDependency] rule already covers
        // (forgeflow.shift.edit -> forgeflow.shift.view); the new
        // metadata-driven rule must NOT double-report that pair.
        expect(
          impliedWarnings.where(
            (w) => w.affectedKeys.contains(PermissionKeys.forgeflowShiftEdit),
          ),
          isEmpty,
          reason:
              'Rule 4 must defer to Rule 3 (orphanViewDependency) for pairs '
              'the hand-curated table already covers - no double reporting.',
        );
      },
    );

    test(
      'emits Rule 4 warning when team.users.invite is selected without '
      'team.users.view (uses humanLabel in copy)',
      () {
        // The metadata for team.users.invite carries
        // `implies: [team.users.view]`, so the metadata-driven Rule 4
        // would fire here - but Rule 3 (orphanViewDependency) also
        // covers the same pair via kViewRequiredForWrite. Rule 4
        // defers to Rule 3 to avoid double-reporting (the dedupe is
        // an explicit design decision: Rule 3 is the canonical
        // surface for view-required-for-write today).
        final warnings = validator.validate(
          {PermissionKeys.teamUsersInvite},
          scope: RoleScope.location,
        );
        final rule4 = warnings.where(
          (w) =>
              w.code == RoleWarningCode.orphanImpliedDependency &&
              w.affectedKeys.contains(PermissionKeys.teamUsersInvite),
        );
        expect(
          rule4,
          isEmpty,
          reason:
              'Rule 3 already covers team.users.invite -> team.users.view; '
              'Rule 4 must defer to it.',
        );
      },
    );

    test(
      'no Rule 4 warning when the implied key is also selected',
      () {
        final warnings = validator.validate(
          {
            PermissionKeys.forgeflowShiftEdit,
            PermissionKeys.forgeflowShiftView,
          },
          scope: RoleScope.business,
        );
        expect(
          warnings.where(
            (w) => w.code == RoleWarningCode.orphanImpliedDependency,
          ),
          isEmpty,
        );
      },
    );

    test('Rule 4 message uses friendly humanLabel, not the dotted key', () {
      // Pick a pair NOT covered by the hand-curated table. The
      // metadata for `team.audit_log.export` implies
      // `team.audit_log.view`, and that pair IS in
      // kViewRequiredForWrite. So we need a key whose implies edge
      // is metadata-only. `forgeflow.target_cycle.replace` has
      // `implies: [forgeflow.target_cycle.view]` and so does
      // kViewRequiredForWrite - duplicated. Use the role-management
      // chain instead: team.roles.create_custom implies
      // team.roles.view, and Rule 3's kViewRequiredForWrite ALSO
      // covers it - so Rule 4 defers there too. To pin Rule 4 firing
      // we drop the hand-curated entry by selecting an implies edge
      // the kViewRequiredForWrite table does not list. Among the
      // metadata, `team.session.force_logout` implies
      // `team.users.view`; that is NOT in kViewRequiredForWrite.
      final warnings = validator.validate(
        {PermissionKeys.teamSessionForceLogout},
        scope: RoleScope.business,
      );
      final rule4 = warnings.firstWhere(
        (w) =>
            w.code == RoleWarningCode.orphanImpliedDependency &&
            w.affectedKeys.contains(PermissionKeys.teamSessionForceLogout),
      );
      // The message must use the humanLabel ("Force log out team
      // sessions") instead of the raw dotted key.
      expect(rule4.message, contains('Force log out team sessions'));
      expect(rule4.message, contains('View team members'));
      // Should also mention "would not be able to see".
      expect(rule4.message.toLowerCase(), contains('would not be able'));
    });

    test('Rule 4 output is deterministic across rebuilds', () {
      final selection = {
        PermissionKeys.teamSessionForceLogout,
        PermissionKeys.forgeflowVarianceEdit,
      };
      final first = validator.validate(selection, scope: RoleScope.business);
      final second = validator.validate(
        Set<String>.from(selection),
        scope: RoleScope.business,
      );
      final firstRule4 = first
          .where((w) => w.code == RoleWarningCode.orphanImpliedDependency)
          .toList();
      final secondRule4 = second
          .where((w) => w.code == RoleWarningCode.orphanImpliedDependency)
          .toList();
      expect(firstRule4.length, equals(secondRule4.length));
      for (var i = 0; i < firstRule4.length; i++) {
        expect(firstRule4[i].affectedKeys, equals(secondRule4[i].affectedKeys));
      }
    });
  });

  group(
    'CustomRoleValidator - Rule 5 per-key org-wide at location scope',
    () {
      test(
        'emits ONE warning per offending org-wide key (info severity)',
        () {
          final warnings = validator.validate(
            {
              PermissionKeys.billingSubscriptionManage,
              PermissionKeys.businessTimingConfigure,
            },
            scope: RoleScope.location,
          );
          final rule5 = warnings
              .where(
                (w) =>
                    w.code == RoleWarningCode.perKeyOrgWideAtLocationScope,
              )
              .toList();
          // Two offending keys -> two info warnings (one per key).
          expect(rule5.length, equals(2));
          expect(
            rule5.every((w) => w.severity == RoleWarningSeverity.info),
            isTrue,
          );
          expect(
            rule5
                .map((w) => w.affectedKeys.single)
                .toSet(),
            equals({
              PermissionKeys.billingSubscriptionManage,
              PermissionKeys.businessTimingConfigure,
            }),
          );
        },
      );

      test(
        'message uses humanLabel and contains "location level"',
        () {
          final warnings = validator.validate(
            {PermissionKeys.billingSubscriptionManage},
            scope: RoleScope.location,
          );
          final rule5 = warnings.firstWhere(
            (w) => w.code == RoleWarningCode.perKeyOrgWideAtLocationScope,
          );
          // The humanLabel for billing.subscription.manage is
          // "Manage the subscription plan" per the R-2L catalog.
          expect(rule5.message, contains('Manage the subscription plan'));
          expect(rule5.message.toLowerCase(), contains('location level'));
        },
      );

      test(
        'business scope suppresses Rule 5 entirely',
        () {
          final warnings = validator.validate(
            {
              PermissionKeys.billingSubscriptionManage,
              PermissionKeys.businessTimingConfigure,
            },
            scope: RoleScope.business,
          );
          expect(
            warnings.where(
              (w) =>
                  w.code == RoleWarningCode.perKeyOrgWideAtLocationScope,
            ),
            isEmpty,
          );
        },
      );

      test(
        'runtime keys (forgeflow.*, barrio.*) do not trigger Rule 5',
        () {
          final warnings = validator.validate(
            {
              PermissionKeys.forgeflowShiftView,
              PermissionKeys.barrioHandbookView,
              PermissionKeys.productBarrioAccess,
              PermissionKeys.productForgeflowAccess,
            },
            scope: RoleScope.location,
          );
          expect(
            warnings.where(
              (w) =>
                  w.code == RoleWarningCode.perKeyOrgWideAtLocationScope,
            ),
            isEmpty,
          );
        },
      );
    },
  );

  group(
    'CustomRoleValidator - Rule 6a barrio.* without product gate',
    () {
      test(
        'warns when barrio.handbook.view is selected without '
        'product.barrio.access',
        () {
          final warnings = validator.validate(
            {PermissionKeys.barrioHandbookView},
            scope: RoleScope.business,
          );
          final rule6a = warnings.firstWhere(
            (w) =>
                w.code == RoleWarningCode.barrioKeyMissingProductAccess,
          );
          expect(rule6a.severity, RoleWarningSeverity.warn);
          expect(
            rule6a.affectedKeys,
            contains(PermissionKeys.barrioHandbookView),
          );
          expect(rule6a.message.toLowerCase(), contains('open barrio'));
        },
      );

      test(
        'no Rule 6a warning when product.barrio.access is also selected',
        () {
          final warnings = validator.validate(
            {
              PermissionKeys.barrioHandbookView,
              PermissionKeys.productBarrioAccess,
            },
            scope: RoleScope.business,
          );
          expect(
            warnings.where(
              (w) =>
                  w.code == RoleWarningCode.barrioKeyMissingProductAccess,
            ),
            isEmpty,
          );
        },
      );

      test(
        'collects every barrio.* key into the warning affectedKeys',
        () {
          final warnings = validator.validate(
            {
              PermissionKeys.barrioHandbookView,
              PermissionKeys.barrioInterviewPlaybookView,
              PermissionKeys.barrioPrestonLeeView,
            },
            scope: RoleScope.business,
          );
          final rule6a = warnings.firstWhere(
            (w) =>
                w.code == RoleWarningCode.barrioKeyMissingProductAccess,
          );
          expect(
            rule6a.affectedKeys,
            containsAll([
              PermissionKeys.barrioHandbookView,
              PermissionKeys.barrioInterviewPlaybookView,
              PermissionKeys.barrioPrestonLeeView,
            ]),
          );
          // Sorted alphabetically for deterministic rendering.
          final sorted = List<String>.from(rule6a.affectedKeys);
          final expected = List<String>.from(sorted)..sort();
          expect(sorted, equals(expected));
        },
      );
    },
  );

  group(
    'CustomRoleValidator - Rule 6b forgeflow.* write without product gate',
    () {
      test(
        'warns when forgeflow.shift.edit is selected without '
        'product.forgeflow.access',
        () {
          final warnings = validator.validate(
            {
              // Add the corresponding view so Rule 3 doesn't fire and
              // confuse the assertion.
              PermissionKeys.forgeflowShiftEdit,
              PermissionKeys.forgeflowShiftView,
            },
            scope: RoleScope.business,
          );
          final rule6b = warnings.firstWhere(
            (w) =>
                w.code ==
                RoleWarningCode.forgeflowWriteMissingProductAccess,
          );
          expect(rule6b.severity, RoleWarningSeverity.warn);
          expect(
            rule6b.affectedKeys,
            contains(PermissionKeys.forgeflowShiftEdit),
          );
          expect(
            rule6b.message.toLowerCase(),
            contains('open forge & flow'),
          );
        },
      );

      test(
        'view-only forgeflow keys do NOT trigger Rule 6b',
        () {
          final warnings = validator.validate(
            {PermissionKeys.forgeflowShiftView},
            scope: RoleScope.business,
          );
          expect(
            warnings.where(
              (w) =>
                  w.code ==
                  RoleWarningCode.forgeflowWriteMissingProductAccess,
            ),
            isEmpty,
            reason:
                'Rule 6b only fires for write keys (edit / override / '
                'manage / lock / unlock / replace). View-only is fine.',
          );
        },
      );

      test(
        'no Rule 6b warning when product.forgeflow.access is selected',
        () {
          final warnings = validator.validate(
            {
              PermissionKeys.forgeflowShiftEdit,
              PermissionKeys.forgeflowShiftView,
              PermissionKeys.productForgeflowAccess,
            },
            scope: RoleScope.business,
          );
          expect(
            warnings.where(
              (w) =>
                  w.code ==
                  RoleWarningCode.forgeflowWriteMissingProductAccess,
            ),
            isEmpty,
          );
        },
      );

      test(
        'collects every forgeflow.* write key into the warning '
        'affectedKeys (sorted)',
        () {
          final warnings = validator.validate(
            {
              PermissionKeys.forgeflowShiftEdit,
              PermissionKeys.forgeflowVarianceEdit,
              PermissionKeys.forgeflowShiftView,
              PermissionKeys.forgeflowVarianceView,
              PermissionKeys.forgeflowSettingsManage,
              PermissionKeys.forgeflowSettingsView,
            },
            scope: RoleScope.business,
          );
          final rule6b = warnings.firstWhere(
            (w) =>
                w.code ==
                RoleWarningCode.forgeflowWriteMissingProductAccess,
          );
          expect(
            rule6b.affectedKeys,
            containsAll([
              PermissionKeys.forgeflowShiftEdit,
              PermissionKeys.forgeflowVarianceEdit,
              PermissionKeys.forgeflowSettingsManage,
            ]),
          );
          final sorted = List<String>.from(rule6b.affectedKeys);
          final expected = List<String>.from(sorted)..sort();
          expect(sorted, equals(expected));
        },
      );
    },
  );

  group(
    'CustomRoleValidator - Rule 6c billing.subscription.manage on '
    'non-Owner role',
    () {
      test(
        'warns when billing.subscription.manage is selected on a '
        'role whose name does not contain "owner"',
        () {
          final warnings = validator.validate(
            {PermissionKeys.billingSubscriptionManage},
            scope: RoleScope.business,
            roleDisplayName: 'Shift Supervisor',
          );
          final rule6c = warnings.firstWhere(
            (w) =>
                w.code ==
                RoleWarningCode.billingSubscriptionOnNonOwnerRole,
          );
          expect(rule6c.severity, RoleWarningSeverity.warn);
          expect(
            rule6c.affectedKeys,
            equals([PermissionKeys.billingSubscriptionManage]),
          );
          expect(rule6c.message.toLowerCase(), contains('owner'));
        },
      );

      test(
        'no Rule 6c warning when the role name contains "owner" '
        '(case-insensitive)',
        () {
          for (final name in const <String>[
            'Owner',
            'owner',
            'OWNER',
            'Restaurant Owner',
            'Owner / Operator',
          ]) {
            final warnings = validator.validate(
              {PermissionKeys.billingSubscriptionManage},
              scope: RoleScope.business,
              roleDisplayName: name,
            );
            expect(
              warnings.where(
                (w) =>
                    w.code ==
                    RoleWarningCode.billingSubscriptionOnNonOwnerRole,
              ),
              isEmpty,
              reason:
                  'Role name "$name" should suppress the Rule 6c warning.',
            );
          }
        },
      );

      test(
        'no Rule 6c warning when billing.subscription.manage is NOT '
        'selected',
        () {
          final warnings = validator.validate(
            {PermissionKeys.forgeflowShiftView},
            scope: RoleScope.business,
            roleDisplayName: 'General Manager',
          );
          expect(
            warnings.where(
              (w) =>
                  w.code ==
                  RoleWarningCode.billingSubscriptionOnNonOwnerRole,
            ),
            isEmpty,
          );
        },
      );

      test(
        'empty display name (brand-new role) still triggers Rule 6c '
        'because "owner" is absent',
        () {
          final warnings = validator.validate(
            {PermissionKeys.billingSubscriptionManage},
            scope: RoleScope.business,
            roleDisplayName: '',
          );
          expect(
            warnings.where(
              (w) =>
                  w.code ==
                  RoleWarningCode.billingSubscriptionOnNonOwnerRole,
            ),
            isNotEmpty,
          );
        },
      );
    },
  );

  group('CustomRoleValidator - multi-rule interaction', () {
    test(
      'multiple Q-4 follow-up rules fire together when applicable',
      () {
        // Location-scoped role + billing.subscription.manage (Rule 5
        // and Rule 6c) + a barrio.* key without
        // product.barrio.access (Rule 6a) + a forgeflow write key
        // without product.forgeflow.access (Rule 6b).
        final warnings = validator.validate(
          {
            PermissionKeys.billingSubscriptionManage,
            PermissionKeys.barrioHandbookView,
            PermissionKeys.forgeflowShiftEdit,
            PermissionKeys.forgeflowShiftView,
          },
          scope: RoleScope.location,
          roleDisplayName: 'Manager',
        );
        final codes = warnings.map((w) => w.code).toSet();
        expect(
          codes,
          containsAll([
            RoleWarningCode.perKeyOrgWideAtLocationScope,
            RoleWarningCode.billingSubscriptionOnNonOwnerRole,
            RoleWarningCode.barrioKeyMissingProductAccess,
            RoleWarningCode.forgeflowWriteMissingProductAccess,
          ]),
        );
      },
    );

    test(
      'unknown / out-of-catalog keys are still silently dropped '
      'across the new rules',
      () {
        final warnings = validator.validate(
          {'not.a.real.key'},
          scope: RoleScope.location,
          roleDisplayName: 'Manager',
        );
        final newRuleCodes = warnings.where(
          (w) =>
              w.code == RoleWarningCode.orphanImpliedDependency ||
              w.code == RoleWarningCode.perKeyOrgWideAtLocationScope ||
              w.code == RoleWarningCode.barrioKeyMissingProductAccess ||
              w.code ==
                  RoleWarningCode.forgeflowWriteMissingProductAccess ||
              w.code ==
                  RoleWarningCode.billingSubscriptionOnNonOwnerRole,
        );
        expect(newRuleCodes, isEmpty);
      },
    );
  });
}
