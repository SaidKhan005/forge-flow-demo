// Timing-editable parity — AdminTimingSetupScreen widget tests.
//
// Coverage focuses on the editor contract that makes admin's Timing
// screen a faithful, scope-driven replica of the operator-web timing
// editor:
//   (a) super_admin sees the editable controls and can Save — the Save
//       button opens the admin_reason dialog, and confirming a reason
//       drives a CREATE on the profiles gateway carrying that
//       admin_reason + the selected scope (operator scope here).
//   (b) ff_support (editingEnabled == false) sees the read-only banner
//       with NO Save affordance and a disabled Save button.
//   (c) Save with an empty reason is blocked by the dialog guard — no
//       write reaches the gateway.
//   (d) create-vs-patch: a second Save against the just-created profile
//       PATCHes it instead of creating a duplicate.
//   (e) scope mapping: an org_unit scope creates with scopeKind
//       'org_unit' + scopeId = orgUnitId.
//   (f) no operator-facing literal contains an em dash.
//
// Mirrors the style of audited_support_actions_admin_screen_test.dart
// (in-memory gateway, wide viewport, pumpEventually settling).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/admin_timing_setup_screen.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_profiles_gateway.dart';
import 'package:forge_and_flow/admin/services/operator_location_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

import '../../_test_helpers/widget_pump_helpers.dart';

void main() {
  const operatorId = '00000000-0000-4000-8000-000000000001';
  const orgUnitId = '00000000-0000-4000-8000-0000000000aa';

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  // The editor uses operator data only to seed starter timezone/day-start
  // when no timing profile exists. Empty data falls back to the starter
  // profile, which keeps the editor assertions focused.
  OperatorLocationAdminGateway emptyOperatorGateway() =>
      InMemoryOperatorLocationAdminGateway();

  AdminTimingSetupScreen buildScreen({
    required InMemoryAdminBusinessTimingProfilesGateway profilesGateway,
    bool editingEnabled = true,
    AdminHierarchyScopeIntent? scope,
  }) {
    return AdminTimingSetupScreen(
      operatorGateway: emptyOperatorGateway(),
      selectedScope:
          scope ??
          const AdminHierarchyScopeIntent.business(
            operatorId: operatorId,
            operatorName: 'Demo Diner Co.',
          ),
      scopeLocationIds: const <String>{},
      editingEnabled: editingEnabled,
      timingProfilesGateway: profilesGateway,
      // Deterministic idempotency key keeps the test free of clock noise.
      idempotencyKeyFactory: () => 'idem-test',
    );
  }

  group('super_admin editable + Save create path', () {
    testWidgets('renders editable controls and a Save button', (tester) async {
      wideViewport(tester);
      final gateway = InMemoryAdminBusinessTimingProfilesGateway();
      await tester.pumpWidget(wrap(buildScreen(profilesGateway: gateway)));
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_timing_setup_screen')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('admin_timing_editor_panel')), findsNothing);
      // No read-only banner for super_admin.
      expect(
        find.byKey(const Key('admin_timing_readonly_banner')),
        findsNothing,
      );
      // Core editor controls are present and the Save button is enabled.
      expect(
        find.byKey(const Key('admin_timing_editor_timezone_dropdown')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_timing_editor_business_day_start')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_timing_editor_week_start')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_timing_editor_periods')),
        findsOneWidget,
      );

      final save = tester.widget<FilledButton>(
        find.byKey(const Key('admin_timing_editor_save')),
      );
      expect(save.onPressed, isNotNull);
    });

    testWidgets(
      'Save opens the reason dialog; confirming a reason CREATEs with '
      'admin_reason + the selected (operator) scope',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryAdminBusinessTimingProfilesGateway();
        await tester.pumpWidget(wrap(buildScreen(profilesGateway: gateway)));
        await pumpEventually(tester);

        await tester.ensureVisible(
          find.byKey(const Key('admin_timing_editor_save')),
        );
        await tester.tap(find.byKey(const Key('admin_timing_editor_save')));
        await pumpEventually(tester);

        // Reason dialog mounts; nothing written yet.
        expect(
          find.byKey(const Key('admin_timing_reason_dialog')),
          findsOneWidget,
        );
        expect(gateway.capturedCreates, isEmpty);

        await tester.enterText(
          find.byKey(const Key('admin_timing_reason_field')),
          'shift start repair',
        );
        await tester.tap(find.byKey(const Key('admin_timing_reason_submit')));
        await pumpEventually(tester);

        // CREATE captured (no existing profile) with reason + scope.
        expect(gateway.capturedCreates, hasLength(1));
        expect(gateway.capturedPatches, isEmpty);
        expect(
          gateway.capturedAdminReasons,
          equals(<String>['shift start repair']),
        );
        final create = gateway.capturedCreates.single;
        expect(create.scopeKind, 'operator');
        expect(create.scopeId, operatorId);
        // Starter periods carried through (lunch + dinner).
        expect(create.servicePeriods, hasLength(2));
        expect(create.servicePeriods.first.applicableDays, <int>[
          1,
          2,
          3,
          4,
          5,
          6,
          7,
        ]);
        expect(create.servicePeriods.first.shortLabel, isNotNull);
        expect(create.servicePeriods.first.sortOrder, isNonNegative);
        // Success banner renders.
        expect(
          find.byKey(const Key('admin_timing_editor_success')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a second Save against the just-created profile PATCHes (no duplicate '
      'create)',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryAdminBusinessTimingProfilesGateway();
        await tester.pumpWidget(wrap(buildScreen(profilesGateway: gateway)));
        await pumpEventually(tester);

        Future<void> saveWithReason(String reason) async {
          await tester.ensureVisible(
            find.byKey(const Key('admin_timing_editor_save')),
          );
          await tester.tap(find.byKey(const Key('admin_timing_editor_save')));
          await pumpEventually(tester);
          await tester.enterText(
            find.byKey(const Key('admin_timing_reason_field')),
            reason,
          );
          await tester.tap(find.byKey(const Key('admin_timing_reason_submit')));
          await pumpEventually(tester);
        }

        await saveWithReason('first save');
        await saveWithReason('second save');

        expect(gateway.capturedCreates, hasLength(1));
        expect(gateway.capturedPatches, hasLength(1));
        expect(
          gateway.capturedAdminReasons,
          equals(<String>['first save', 'second save']),
        );
        // Exactly one stored profile for the operator (no duplicate), and
        // the patch targeted that same stored record's id.
        final stored = await gateway.listProfiles(operatorId: operatorId);
        expect(stored, hasLength(1));
        expect(
          gateway.capturedPatches.single.profileId,
          stored.single.profileId,
        );
        final patch = gateway.capturedPatches.single.patch;
        expect(patch.scopeKind, 'operator');
        expect(patch.scopeId, operatorId);
      },
    );

    testWidgets(
      'org_unit scope CREATEs with scopeKind org_unit + scopeId = orgUnitId',
      (tester) async {
        wideViewport(tester);
        final gateway = InMemoryAdminBusinessTimingProfilesGateway();
        await tester.pumpWidget(
          wrap(
            buildScreen(
              profilesGateway: gateway,
              scope: const AdminHierarchyScopeIntent.orgUnit(
                operatorId: operatorId,
                orgUnitId: orgUnitId,
                operatorName: 'Demo Diner Co.',
                orgUnitName: 'North Region',
              ),
            ),
          ),
        );
        await pumpEventually(tester);

        await tester.ensureVisible(
          find.byKey(const Key('admin_timing_editor_save')),
        );
        await tester.tap(find.byKey(const Key('admin_timing_editor_save')));
        await pumpEventually(tester);
        await tester.enterText(
          find.byKey(const Key('admin_timing_reason_field')),
          'org unit timing',
        );
        await tester.tap(find.byKey(const Key('admin_timing_reason_submit')));
        await pumpEventually(tester);

        expect(gateway.capturedCreates, hasLength(1));
        final create = gateway.capturedCreates.single;
        expect(create.scopeKind, 'org_unit');
        expect(create.scopeId, orgUnitId);
      },
    );
  });

  group('ff_support read-only posture', () {
    testWidgets('editing disabled shows read-only banner + disabled Save', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryAdminBusinessTimingProfilesGateway();
      await tester.pumpWidget(
        wrap(buildScreen(profilesGateway: gateway, editingEnabled: false)),
      );
      await pumpEventually(tester);

      expect(
        find.byKey(const Key('admin_timing_readonly_banner')),
        findsOneWidget,
      );
      final save = tester.widget<FilledButton>(
        find.byKey(const Key('admin_timing_editor_save')),
      );
      expect(save.onPressed, isNull);
      // Ops only shows Reset when an inherited/existing profile exists.
      expect(find.byKey(const Key('admin_timing_editor_reset')), findsNothing);
    });

    testWidgets('read-only Save never writes even if tapped', (tester) async {
      wideViewport(tester);
      final gateway = InMemoryAdminBusinessTimingProfilesGateway();
      await tester.pumpWidget(
        wrap(buildScreen(profilesGateway: gateway, editingEnabled: false)),
      );
      await pumpEventually(tester);

      await tester.tap(
        find.byKey(const Key('admin_timing_editor_save')),
        warnIfMissed: false,
      );
      await pumpEventually(tester);

      expect(find.byKey(const Key('admin_timing_reason_dialog')), findsNothing);
      expect(gateway.capturedCreates, isEmpty);
      expect(gateway.capturedPatches, isEmpty);
    });
  });

  group('admin_reason required on Save', () {
    testWidgets('empty reason is blocked; no write reaches the gateway', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = InMemoryAdminBusinessTimingProfilesGateway();
      await tester.pumpWidget(wrap(buildScreen(profilesGateway: gateway)));
      await pumpEventually(tester);

      await tester.ensureVisible(
        find.byKey(const Key('admin_timing_editor_save')),
      );
      await tester.tap(find.byKey(const Key('admin_timing_editor_save')));
      await pumpEventually(tester);

      // Submit empty: the guard surfaces and the dialog stays open.
      await tester.tap(find.byKey(const Key('admin_timing_reason_submit')));
      await pumpEventually(tester);
      expect(find.text('Add a reason before continuing.'), findsOneWidget);
      expect(
        find.byKey(const Key('admin_timing_reason_dialog')),
        findsOneWidget,
      );
      expect(gateway.capturedCreates, isEmpty);
      expect(gateway.capturedAdminReasons, isEmpty);

      // Cancelling writes nothing either.
      await tester.tap(find.byKey(const Key('admin_timing_reason_cancel')));
      await pumpEventually(tester);
      expect(gateway.capturedCreates, isEmpty);
    });
  });

  group('zero em dashes in operator-facing literals', () {
    testWidgets('rendered text never contains an em dash', (tester) async {
      wideViewport(tester);
      final gateway = InMemoryAdminBusinessTimingProfilesGateway();
      await tester.pumpWidget(
        wrap(buildScreen(profilesGateway: gateway, editingEnabled: false)),
      );
      await pumpEventually(tester);

      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final t in texts) {
        final data = t.data;
        if (data == null) continue;
        expect(data.contains('—'), isFalse, reason: data);
      }
    });
  });
}
