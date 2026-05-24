// Admin-web UX parity — PerLocationDataAccuracyScreen widget tests.
//
// Coverage focuses on the contract that makes admin's Data accuracy
// screen a faithful, scope-driven replica of the operator-web
// data-SOURCE controls:
//   (a) a LOCATION scope renders the web-style covers/wage source
//       controls (reused operator-web cards) as the PRIMARY surface and
//       still renders the SECONDARY admin multi-location table + audit
//       history panel below.
//   (b) changing a source control for super_admin opens the
//       admin_reason dialog; confirming a reason drives an
//       overrideDataAccuracy write (captured as an audit event carrying
//       the reason + the per-period source diff).
//   (c) a BUSINESS / ORG-UNIT scope shows the friendly "pick a location"
//       surface for the primary section (data accuracy is per-location),
//       while the secondary table still renders.
//   (d) ff_support (editingEnabled == false) is read-only: no write
//       affordance fires, the gateway override is never called, the
//       read-only banner shows, and the table/audit still render.
//   (e) no operator-facing literal contains an em dash.
//
// Mirrors the style of admin_timing_setup_screen_test.dart (in-memory
// gateway, wide viewport, pumpAndSettle settling). Uses the production
// InMemoryDataAccuracyAdminGateway as the fake (it buffers audit events
// so the override assertion needs no bespoke mock).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  const refs = <OperatorLocationRef>[
    OperatorLocationRef(
      operatorId: 'op-1',
      businessName: 'Demo Diner Co.',
      locationId: 'loc-1a',
      locationName: 'Toronto Yorkville',
    ),
    OperatorLocationRef(
      operatorId: 'op-1',
      businessName: 'Demo Diner Co.',
      locationId: 'loc-1b',
      locationName: 'Vancouver Robson',
    ),
  ];

  const locationScope = AdminHierarchyScopeIntent.location(
    operatorId: 'op-1',
    locationId: 'loc-1a',
    operatorName: 'Demo Diner Co.',
    locationName: 'Toronto Yorkville',
  );

  const businessScope = AdminHierarchyScopeIntent.business(
    operatorId: 'op-1',
    operatorName: 'Demo Diner Co.',
  );

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  void wideViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  InMemoryDataAccuracyAdminGateway buildGateway() =>
      InMemoryDataAccuracyAdminGateway(operatorLocations: refs);

  PerLocationDataAccuracyScreen buildScreen({
    required InMemoryDataAccuracyAdminGateway gateway,
    required AdminHierarchyScopeIntent scope,
    bool editingEnabled = true,
  }) {
    return PerLocationDataAccuracyScreen(
      gateway: gateway,
      actorUserId: 'demo-super-admin',
      editingEnabled: editingEnabled,
      initialHierarchyScope: scope,
      // Mount-config parity with the admin route builder.
      showPageHeader: false,
      showScopeControls: false,
    );
  }

  List<DataAccuracyAdminAuditEvent> overrideEvents(
    InMemoryDataAccuracyAdminGateway gateway,
  ) => gateway.capturedAuditEvents
      .where((e) => e.eventType == 'admin.data_accuracy.override')
      .toList(growable: false);

  group('location scope — web-style primary surface + secondary extras', () {
    testWidgets(
      'renders the reused web covers + wage source cards and the secondary '
      'table + audit panel',
      (tester) async {
        wideViewport(tester);
        final gateway = buildGateway();
        await tester.pumpWidget(
          wrap(buildScreen(gateway: gateway, scope: locationScope)),
        );
        await tester.pumpAndSettle();

        // Own header (replaces the workspace header, like the timing screen).
        expect(
          find.byKey(const Key('admin_data_accuracy_screen')),
          findsOneWidget,
        );
        expect(find.text('Data accuracy'), findsOneWidget);

        // PRIMARY web-style source controls (reused operator-web cards).
        expect(
          find.byKey(const Key('admin_data_accuracy_primary_section')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_covers_source_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_wage_source_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('data_accuracy_walk_in_handling_card')),
          findsOneWidget,
        );
        // One covers picker row per configured (demo) service period.
        expect(
          find.byKey(const Key('covers_source_daypart_lunch')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('covers_source_daypart_dinner')),
          findsOneWidget,
        );

        // Pick-a-location is NOT shown at a location scope.
        expect(
          find.byKey(const Key('admin_data_accuracy_pick_location')),
          findsNothing,
        );

        // SECONDARY admin extras still render below.
        expect(
          find.byKey(const Key('admin_data_accuracy_extras_heading')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_data_accuracy_table')),
          findsOneWidget,
        );
        // The audit-history panel renders (default title).
        expect(find.text('Audit history'), findsOneWidget);
      },
    );

    testWidgets(
      'changing the covers source opens the reason dialog; confirming a '
      'reason drives an overrideDataAccuracy write with the per-period diff',
      (tester) async {
        wideViewport(tester);
        final gateway = buildGateway();
        await tester.pumpWidget(
          wrap(buildScreen(gateway: gateway, scope: locationScope)),
        );
        await tester.pumpAndSettle();

        expect(overrideEvents(gateway), isEmpty);

        // Flip lunch covers source from the vendor default to forecast.
        final forecastChip = find.byKey(
          const Key('covers_source_chip_lunch_forecast'),
        );
        await tester.ensureVisible(forecastChip);
        await tester.tap(forecastChip);
        await tester.pumpAndSettle();

        // Reason dialog mounts; nothing written until a reason is confirmed.
        expect(
          find.byKey(const Key('admin_data_accuracy_reason_dialog')),
          findsOneWidget,
        );
        expect(overrideEvents(gateway), isEmpty);

        await tester.enterText(
          find.byKey(const Key('admin_data_accuracy_reason_field')),
          'lunch covers come from forecast for launch week',
        );
        await tester.tap(
          find.byKey(const Key('admin_data_accuracy_reason_submit')),
        );
        await tester.pumpAndSettle();

        // The override landed with the reason + the lunch->forecast diff.
        final events = overrideEvents(gateway);
        expect(events, hasLength(1));
        final event = events.single;
        expect(event.locationId, 'loc-1a');
        expect(
          event.reasonNote,
          'lunch covers come from forecast for launch week',
        );
        final keyedDiff =
            event.diff['covers_source_per_service_period']
                as Map<String, Object?>?;
        expect(keyedDiff, isNotNull);
        expect(keyedDiff!.keys, contains('lunch'));
      },
    );

    testWidgets(
      'changing the wage source drives an overrideDataAccuracy write '
      'carrying the wage diff',
      (tester) async {
        wideViewport(tester);
        final gateway = buildGateway();
        await tester.pumpWidget(
          wrap(buildScreen(gateway: gateway, scope: locationScope)),
        );
        await tester.pumpAndSettle();

        final manualRadio = find.byKey(
          const Key('wage_source_radio_manual_mix'),
        );
        await tester.ensureVisible(manualRadio);
        await tester.tap(manualRadio);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('admin_data_accuracy_reason_field')),
          'switch to manual wage mix',
        );
        await tester.tap(
          find.byKey(const Key('admin_data_accuracy_reason_submit')),
        );
        await tester.pumpAndSettle();

        final events = overrideEvents(gateway);
        expect(events, hasLength(1));
        expect(events.single.diff['wage_source'], isNotNull);
      },
    );

    testWidgets('cancelling the reason dialog writes nothing', (tester) async {
      wideViewport(tester);
      final gateway = buildGateway();
      await tester.pumpWidget(
        wrap(buildScreen(gateway: gateway, scope: locationScope)),
      );
      await tester.pumpAndSettle();

      final forecastChip = find.byKey(
        const Key('covers_source_chip_lunch_forecast'),
      );
      await tester.ensureVisible(forecastChip);
      await tester.tap(forecastChip);
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('admin_data_accuracy_reason_cancel')),
      );
      await tester.pumpAndSettle();

      expect(overrideEvents(gateway), isEmpty);
    });
  });

  group('non-location scope — pick a location for the primary section', () {
    testWidgets(
      'business scope shows pick-a-location, hides the source controls, but '
      'still renders the secondary table',
      (tester) async {
        wideViewport(tester);
        final gateway = buildGateway();
        await tester.pumpWidget(
          wrap(buildScreen(gateway: gateway, scope: businessScope)),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('admin_data_accuracy_pick_location')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_data_accuracy_primary_section')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('data_accuracy_covers_source_card')),
          findsNothing,
        );

        // Secondary table still renders at a business scope.
        expect(
          find.byKey(const Key('admin_data_accuracy_table')),
          findsOneWidget,
        );
      },
    );
  });

  group('ff_support read-only posture', () {
    testWidgets(
      'editing disabled shows the read-only banner, fires no write, and '
      'still renders the table',
      (tester) async {
        wideViewport(tester);
        final gateway = buildGateway();
        await tester.pumpWidget(
          wrap(
            buildScreen(
              gateway: gateway,
              scope: locationScope,
              editingEnabled: false,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('admin_data_accuracy_readonly_banner')),
          findsOneWidget,
        );
        // The web cards still render (read-only), and the table is present.
        expect(
          find.byKey(const Key('data_accuracy_covers_source_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('admin_data_accuracy_table')),
          findsOneWidget,
        );

        // Tapping a source chip must not open the reason dialog or write
        // anything (the primary surface is wrapped in an AbsorbPointer for
        // ff_support).
        await tester.tap(
          find.byKey(const Key('covers_source_chip_lunch_forecast')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('admin_data_accuracy_reason_dialog')),
          findsNothing,
        );
        expect(overrideEvents(gateway), isEmpty);
      },
    );
  });

  group('zero em dashes in operator-facing literals', () {
    testWidgets('rendered text never contains an em dash (location scope)', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildGateway();
      await tester.pumpWidget(
        wrap(buildScreen(gateway: gateway, scope: locationScope)),
      );
      await tester.pumpAndSettle();

      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final t in texts) {
        final data = t.data;
        if (data == null) continue;
        expect(data.contains('—'), isFalse, reason: data);
      }
    });

    testWidgets('rendered text never contains an em dash (business scope)', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildGateway();
      await tester.pumpWidget(
        wrap(buildScreen(gateway: gateway, scope: businessScope)),
      );
      await tester.pumpAndSettle();

      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final t in texts) {
        final data = t.data;
        if (data == null) continue;
        expect(data.contains('—'), isFalse, reason: data);
      }
    });
  });
}
