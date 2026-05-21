// Wave 2 Q-4 follow-up - widget tests for the Custom Role editor
// warning panel surface. The validator's pure-Dart behaviour is
// already pinned in `test/services/auth/custom_role_validator_test.dart`
// (hand-curated rules) and `test/services/auth/custom_role_orphan_lint_test.dart`
// (metadata-driven follow-up rules). This file pins three editor-level
// behaviours:
//
//   1. The warning banner renders when the validator emits one or
//      more warnings, including the new metadata-driven codes.
//   2. The "Don't show this for this role" dismissal hides the row,
//      and the dismissal persists across rebuilds via the injected
//      `RoleWarningDismissalStore`.
//   3. Multiple warnings render simultaneously and each can be
//      dismissed independently.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/permission_keys.dart';
import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/custom_role_editor_screen.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_fixtures.dart';
import 'package:forge_and_flow/operator_web/services/demo_team_roles_gateway.dart';
import 'package:forge_and_flow/services/auth/auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/custom_role_validator.dart';
import 'package:forge_and_flow/services/auth/role_warning_dismissal_store.dart';
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/widgets/role_permission_picker.dart';

void main() {
  Widget wrapBare(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  Future<void> sizeViewport(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession session() => OperatorWebSession(
    uid: 'session-operator-owner',
    email: 'owner@demobistro.test',
    displayName: 'Sam Patel',
    operatorId: kDemoOperatorIdFixture,
    businessName: kDemoOperatorBusinessNameFixture,
    primaryLocationId: 'demo-loc-downtown',
    primaryLocationName: 'Downtown',
    roles: const <String>['operator_owner'],
    permissions: const <String>{},
  );

  /// Build an existing custom role pre-seeded with permissions that
  /// trigger one or more advisory warnings. We render the editor in
  /// "edit existing role" mode so the validator runs immediately on
  /// first paint without needing the test to toggle checkboxes.
  TeamRoleCatalogEntry roleWith(
    List<String> permissionKeys, {
    String displayName = 'Floor Supervisor',
  }) => TeamRoleCatalogEntry(
    roleId: 'role-floor-supervisor',
    roleKey: 'role_floor_supervisor',
    displayName: displayName,
    description: 'Test fixture for Q-4 follow-up warning surface.',
    isSeeded: false,
    isEditable: true,
    operatorId: kDemoOperatorIdFixture,
    permissions: <TeamRolePermissionRule>[
      for (final key in permissionKeys)
        TeamRolePermissionRule(permissionKey: key, effect: 'allow'),
    ],
  );

  group('CustomRoleEditorScreen - warning panel surface', () {
    testWidgets(
      'renders the warning banner when a metadata-driven rule fires',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1600));
        await tester.pumpWidget(
          wrapBare(
            CustomRoleEditorScreen(
              session: session(),
              gateway: DemoWebTeamRolesGateway(),
              roleScope: RoleScope.business,
              existing: roleWith(<String>[
                // Triggers Rule 6a (barrio.* without product gate)
                // and Rule 6b (forgeflow.* write without product
                // gate; the matching view is supplied to avoid
                // double-firing on Rule 3).
                PermissionKeys.barrioHandbookView,
                PermissionKeys.forgeflowShiftEdit,
                PermissionKeys.forgeflowShiftView,
              ], displayName: 'Floor Supervisor'),
              dismissalStore: MemoryRoleWarningDismissalStore(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('operator_web_custom_role_editor_warnings')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            Key(
              'operator_web_custom_role_editor_warning_'
              '${RoleWarningCode.barrioKeyMissingProductAccess.name}',
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            Key(
              'operator_web_custom_role_editor_warning_'
              '${RoleWarningCode.forgeflowWriteMissingProductAccess.name}',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets("Dismissing a warning hides its row and the dismissal is "
        "remembered by the injected store", (tester) async {
      await sizeViewport(tester, const Size(1280, 1600));
      final store = MemoryRoleWarningDismissalStore();
      final existing = roleWith(<String>[
        PermissionKeys.barrioHandbookView,
        PermissionKeys.productForgeflowAccess,
      ]);
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: session(),
            gateway: DemoWebTeamRolesGateway(),
            roleScope: RoleScope.business,
            existing: existing,
            dismissalStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final warningRow = find.byKey(
        Key(
          'operator_web_custom_role_editor_warning_'
          '${RoleWarningCode.barrioKeyMissingProductAccess.name}',
        ),
      );
      expect(warningRow, findsOneWidget);

      // Dismiss the row. ensureVisible scrolls the button into
      // view because the editor's scroll-view is taller than the
      // test viewport.
      final dismissButton = find.byKey(
        Key(
          'operator_web_custom_role_editor_warning_dismiss_'
          '${RoleWarningCode.barrioKeyMissingProductAccess.name}',
        ),
      );
      await tester.ensureVisible(dismissButton);
      await tester.pumpAndSettle();
      await tester.tap(dismissButton);
      await tester.pumpAndSettle();

      // The row should be gone.
      expect(warningRow, findsNothing);
      // The entire panel should disappear because that was the
      // only outstanding warning for this role.
      expect(
        find.byKey(const Key('operator_web_custom_role_editor_warnings')),
        findsNothing,
      );

      // The store should have remembered the dismissal under the
      // role id.
      expect(store.debugFingerprintsFor(existing.roleId), isNotEmpty);
    });

    testWidgets('two warnings render simultaneously and each can be dismissed '
        'independently', (tester) async {
      await sizeViewport(tester, const Size(1280, 1800));
      final store = MemoryRoleWarningDismissalStore();
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: session(),
            gateway: DemoWebTeamRolesGateway(),
            roleScope: RoleScope.business,
            existing: roleWith(<String>[
              // Rule 6a (Barrio) and Rule 6b (Forge & Flow write)
              // both fire here. Rule 6c is suppressed because the
              // role name does not include billing.subscription.manage.
              PermissionKeys.barrioHandbookView,
              PermissionKeys.forgeflowShiftEdit,
              PermissionKeys.forgeflowShiftView,
            ]),
            dismissalStore: store,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Both rows present.
      expect(
        find.byKey(
          Key(
            'operator_web_custom_role_editor_warning_'
            '${RoleWarningCode.barrioKeyMissingProductAccess.name}',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          Key(
            'operator_web_custom_role_editor_warning_'
            '${RoleWarningCode.forgeflowWriteMissingProductAccess.name}',
          ),
        ),
        findsOneWidget,
      );

      // Dismiss only the Barrio row.
      final barrioDismiss = find.byKey(
        Key(
          'operator_web_custom_role_editor_warning_dismiss_'
          '${RoleWarningCode.barrioKeyMissingProductAccess.name}',
        ),
      );
      await tester.ensureVisible(barrioDismiss);
      await tester.pumpAndSettle();
      await tester.tap(barrioDismiss);
      await tester.pumpAndSettle();

      // Barrio row is gone; Forge & Flow row remains.
      expect(
        find.byKey(
          Key(
            'operator_web_custom_role_editor_warning_'
            '${RoleWarningCode.barrioKeyMissingProductAccess.name}',
          ),
        ),
        findsNothing,
      );
      expect(
        find.byKey(
          Key(
            'operator_web_custom_role_editor_warning_'
            '${RoleWarningCode.forgeflowWriteMissingProductAccess.name}',
          ),
        ),
        findsOneWidget,
      );
      // Panel still visible because at least one warning is left.
      expect(
        find.byKey(const Key('operator_web_custom_role_editor_warnings')),
        findsOneWidget,
      );
    });

    testWidgets("Save button stays enabled regardless of warning count "
        '(warnings are advisory, not blockers)', (tester) async {
      await sizeViewport(tester, const Size(1280, 1800));
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: session(),
            gateway: DemoWebTeamRolesGateway(),
            roleScope: RoleScope.business,
            existing: roleWith(<String>[
              PermissionKeys.barrioHandbookView,
              PermissionKeys.forgeflowShiftEdit,
              PermissionKeys.forgeflowShiftView,
            ]),
            dismissalStore: MemoryRoleWarningDismissalStore(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_custom_role_editor_warnings')),
        findsOneWidget,
      );

      final saveButton = tester.widget<FilledButton>(
        find.byKey(const Key('operator_web_custom_role_editor_save')),
      );
      expect(
        saveButton.onPressed,
        isNotNull,
        reason: 'Warnings must not gate the save button - they are advisory.',
      );
    });

    testWidgets(
      'pre-dismissed warnings (from the store) do not render on first paint',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 1600));
        final store = MemoryRoleWarningDismissalStore();
        final existing = roleWith(<String>[PermissionKeys.barrioHandbookView]);

        // Manually pre-seed the dismissal store for this role.
        await store.dismiss(
          roleId: existing.roleId,
          warning: RoleWarning(
            severity: RoleWarningSeverity.warn,
            code: RoleWarningCode.barrioKeyMissingProductAccess,
            affectedKeys: const <String>[PermissionKeys.barrioHandbookView],
            message: 'pre-dismissed',
          ),
        );

        await tester.pumpWidget(
          wrapBare(
            CustomRoleEditorScreen(
              session: session(),
              gateway: DemoWebTeamRolesGateway(),
              roleScope: RoleScope.business,
              existing: existing,
              dismissalStore: store,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Should NOT render the dismissed row.
        expect(
          find.byKey(
            Key(
              'operator_web_custom_role_editor_warning_'
              '${RoleWarningCode.barrioKeyMissingProductAccess.name}',
            ),
          ),
          findsNothing,
        );
        // And since this was the only warning, the panel disappears.
        expect(
          find.byKey(const Key('operator_web_custom_role_editor_warnings')),
          findsNothing,
        );
      },
    );
  });

  // ============================================================
  // Wave 2 S-3 (RP-14 + Q3) - product / category permission picker.
  //
  // Pins the new product → category permission picker contract:
  //   * The picker groups permissions by `productLabel` →
  //     `categoryLabel`.
  //   * Ticking a key with `implies[]` auto-checks the transitive
  //     closure; the implied child renders disabled with a tooltip
  //     naming the parent.
  //   * Search/filter narrows the visible list by humanLabel.
  //   * Location-scoped roles hide `org_wide` keys and surface a
  //     "What's hidden?" expander.
  // ============================================================

  OperatorWebSession ownerSession() => OperatorWebSession(
    uid: 'session-operator-owner-picker',
    email: 'sam.owner@demobistro.test',
    displayName: 'Sam Patel',
    operatorId: kDemoOperatorIdFixture,
    businessName: kDemoOperatorBusinessNameFixture,
    primaryLocationId: 'demo-loc-downtown',
    primaryLocationName: 'Downtown',
    roles: const <String>['operator_owner'],
    permissions: const <String>{},
  );

  group('RP-14: product → category grouping + search', () {
    testWidgets('defaults to business scope so org-wide keys are visible', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 4000));
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: ownerSession(),
            gateway: DemoWebTeamRolesGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('operator_web_custom_role_editor_perm_account.configure'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders product sections + category sections + a search box', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 4000));
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: ownerSession(),
            gateway: DemoWebTeamRolesGateway(),
            roleScope: RoleScope.business,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_custom_role_editor_permissions')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key('operator_web_custom_role_editor_product_forgeflow'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_custom_role_editor_product_team')),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key(
            'operator_web_custom_role_editor_category_'
            'forgeflow_Forge & Flow surfaces',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_custom_role_editor_search')),
        findsOneWidget,
      );
    });

    testWidgets('search filters rows by humanLabel substring', (tester) async {
      await sizeViewport(tester, const Size(1280, 4000));
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: ownerSession(),
            gateway: DemoWebTeamRolesGateway(),
            roleScope: RoleScope.business,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key(
            'operator_web_custom_role_editor_perm_forgeflow.benchmark.view',
          ),
        ),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('operator_web_custom_role_editor_search')),
        'benchmark',
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key(
            'operator_web_custom_role_editor_perm_forgeflow.benchmark.view',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          const Key(
            'operator_web_custom_role_editor_perm_forgeflow.shift.view',
          ),
        ),
        findsNothing,
      );
    });
  });

  group('RP-14: implies auto-select + uncheck-guard', () {
    testWidgets(
      'picking forgeflow.shift.edit auto-checks forgeflow.shift.view',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 4000));
        await tester.pumpWidget(
          wrapBare(
            CustomRoleEditorScreen(
              session: ownerSession(),
              gateway: DemoWebTeamRolesGateway(),
              roleScope: RoleScope.business,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final editRow = find.byKey(
          const Key(
            'operator_web_custom_role_editor_perm_forgeflow.shift.edit',
          ),
        );
        await tester.ensureVisible(editRow);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(of: editRow, matching: find.byType(Checkbox)),
        );
        await tester.pumpAndSettle();

        final viewRow = find.byKey(
          const Key(
            'operator_web_custom_role_editor_perm_forgeflow.shift.view',
          ),
        );
        final viewCheckbox = tester.widget<Checkbox>(
          find.descendant(of: viewRow, matching: find.byType(Checkbox)),
        );
        expect(viewCheckbox.value, isTrue);
        expect(
          viewCheckbox.onChanged,
          isNull,
          reason: 'Required (implied) keys cannot be unchecked directly.',
        );
        expect(
          find.byKey(
            const Key(
              'operator_web_custom_role_editor_perm_'
              'forgeflow.shift.view_required_chip',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('unchecking the parent drops the implied child', (
      tester,
    ) async {
      await sizeViewport(tester, const Size(1280, 4000));
      await tester.pumpWidget(
        wrapBare(
          CustomRoleEditorScreen(
            session: ownerSession(),
            gateway: DemoWebTeamRolesGateway(),
            roleScope: RoleScope.business,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final editRow = find.byKey(
        const Key('operator_web_custom_role_editor_perm_forgeflow.shift.edit'),
      );
      await tester.ensureVisible(editRow);
      await tester.tap(
        find.descendant(of: editRow, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();

      // Unticking edit also drops the auto-added view.
      await tester.tap(
        find.descendant(of: editRow, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      final viewRow = find.byKey(
        const Key('operator_web_custom_role_editor_perm_forgeflow.shift.view'),
      );
      final viewCheckbox = tester.widget<Checkbox>(
        find.descendant(of: viewRow, matching: find.byType(Checkbox)),
      );
      expect(viewCheckbox.value, isFalse);
      expect(viewCheckbox.onChanged, isNotNull);
    });

    test('rolePermissionPickerRequiredBy names the explicit ancestor', () {
      final pullers = rolePermissionPickerRequiredBy(
        'forgeflow.shift.view',
        <String>{'forgeflow.shift.edit'},
      );
      expect(pullers, contains('forgeflow.shift.edit'));
    });
  });

  group('RP-14 + Q3: location-scoped picker filters org_wide keys', () {
    testWidgets(
      'location-scoped role hides org_wide keys + renders scope notice',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 4000));
        await tester.pumpWidget(
          wrapBare(
            CustomRoleEditorScreen(
              session: ownerSession(),
              gateway: DemoWebTeamRolesGateway(),
              roleScope: RoleScope.location,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_custom_role_editor_scope_notice')),
          findsOneWidget,
        );
        // billing.invoice.view is `org_wide` per the catalog metadata
        // → it must not render as a pickable row.
        expect(
          find.byKey(
            const Key(
              'operator_web_custom_role_editor_perm_billing.invoice.view',
            ),
          ),
          findsNothing,
        );

        // Tapping "What's hidden?" expands the dropped keys list.
        await tester.tap(
          find.byKey(
            const Key('operator_web_custom_role_editor_scope_notice_toggle'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            const Key(
              'operator_web_custom_role_editor_scope_hidden_'
              'billing.invoice.view',
            ),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'org-unit-scoped role also hides org_wide keys',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 4000));
        await tester.pumpWidget(
          wrapBare(
            CustomRoleEditorScreen(
              session: ownerSession(),
              gateway: DemoWebTeamRolesGateway(),
              roleScope: RoleScope.orgUnit,
              scopeLabel: 'East Region',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(
            const Key('operator_web_custom_role_editor_scope_context'),
          ),
          findsOneWidget,
        );
        expect(find.text('Scope: East Region'), findsOneWidget);
        expect(
          find.byKey(const Key('operator_web_custom_role_editor_scope_notice')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key(
              'operator_web_custom_role_editor_perm_billing.invoice.view',
            ),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'business-scoped role exposes org_wide keys (no scope notice)',
      (tester) async {
        await sizeViewport(tester, const Size(1280, 4000));
        await tester.pumpWidget(
          wrapBare(
            CustomRoleEditorScreen(
              session: ownerSession(),
              gateway: DemoWebTeamRolesGateway(),
              roleScope: RoleScope.business,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('operator_web_custom_role_editor_scope_notice')),
          findsNothing,
        );
        expect(
          find.byKey(
            const Key(
              'operator_web_custom_role_editor_perm_billing.invoice.view',
            ),
          ),
          findsOneWidget,
        );
      },
    );
  });
}
