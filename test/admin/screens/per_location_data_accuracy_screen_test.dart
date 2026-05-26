// Admin Data Accuracy parity mount tests.
//
// The admin screen now mounts the real Operator Web DataAccuracyScreen for a
// selected location. These tests keep the old admin drift from coming back:
// no secondary table, no audit-history panel, no admin reason dialog, and no
// in-page pick-location surface.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_gateway.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_projection.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/vendor_applicability_admin_gateway.dart';
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

  // The mounted operator Data Accuracy screen now shows one area at a
  // time behind a segmented tab bar. Labor is the default; Covers and
  // Data-freshness controls live on their own tabs. These helpers move
  // to the relevant tab before the admin test exercises a control.
  Future<void> openCoversTab(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('data_accuracy_tab_covers')));
    await tester.pumpAndSettle();
  }

  Future<void> openFreshnessTab(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('data_accuracy_tab_freshness')));
    await tester.pumpAndSettle();
  }

  InMemoryDataAccuracyAdminGateway buildGateway() =>
      InMemoryDataAccuracyAdminGateway(operatorLocations: refs);

  InMemoryAdminBusinessTimingResolutionGateway timingGateway({
    bool includeLocation = true,
  }) {
    final seed = <String, AdminBusinessTimingResolution>{};
    if (includeLocation) {
      seed[InMemoryAdminBusinessTimingResolutionGateway.keyFor(
        'op-1',
        'loc-1a',
      )] = const AdminBusinessTimingResolution(
        operatorId: 'op-1',
        locationId: 'loc-1a',
        businessDate: '2026-05-24',
        ianaTimezone: 'America/Toronto',
        candidates: <AdminResolutionCandidate>[
          AdminResolutionCandidate(
            profileId: 'timing-op-1',
            scopeType: 'operator_default',
            scopeId: 'op-1',
            scopeLabel: 'Demo Diner Co.',
            scopeDepthRank: 0,
            ianaTimezone: 'America/Toronto',
            effectiveAtBusinessDate: '2026-01-01',
            weekStartDay: 'monday',
            businessDayStartLocal: '04:00',
            servicePeriods: <AdminResolutionServicePeriod>[
              AdminResolutionServicePeriod(
                key: 'lunch',
                label: 'Lunch',
                shortLabel: 'Lunch',
                startLocal: '11:00',
                endLocal: '15:00',
                rollsPastMidnight: false,
                sortOrder: 0,
                applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
              ),
              AdminResolutionServicePeriod(
                key: 'dinner',
                label: 'Dinner',
                shortLabel: 'Dinner',
                startLocal: '17:00',
                endLocal: '22:00',
                rollsPastMidnight: false,
                sortOrder: 1,
                applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
              ),
            ],
          ),
        ],
      );
    }
    return InMemoryAdminBusinessTimingResolutionGateway(seed: seed);
  }

  PerLocationDataAccuracyScreen buildScreen({
    required InMemoryDataAccuracyAdminGateway gateway,
    required AdminHierarchyScopeIntent scope,
    AdminBusinessTimingResolutionGateway? timing,
    bool editingEnabled = true,
    VoidCallback? onOpenPollingSetup,
  }) {
    return PerLocationDataAccuracyScreen(
      gateway: gateway,
      actorUserId: 'demo-super-admin',
      timingResolutionGateway: timing ?? timingGateway(),
      vendorApplicabilityGateway: const _EmptyVendorApplicabilityAdminGateway(),
      editingEnabled: editingEnabled,
      initialHierarchyScope: scope,
      onOpenPollingSetup: onOpenPollingSetup,
      nowUtc: () => DateTime.utc(2026, 5, 24, 15),
      showPageHeader: false,
      showScopeControls: false,
    );
  }

  List<DataAccuracyAdminAuditEvent> settingsSaveEvents(
    InMemoryDataAccuracyAdminGateway gateway,
  ) => gateway.capturedAuditEvents
      .where((e) => e.eventType == 'admin.data_accuracy.settings.save')
      .toList(growable: false);

  group('operator screen mount', () {
    testWidgets(
      'location scope renders the real operator Data Accuracy surface only',
      (tester) async {
        wideViewport(tester);
        final gateway = buildGateway();
        await tester.pumpWidget(
          wrap(buildScreen(gateway: gateway, scope: locationScope)),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('admin_data_accuracy_screen')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('operator_web_data_accuracy_screen')),
          findsOneWidget,
        );
        expect(find.text('Data accuracy'), findsOneWidget);
        // Wage card + embedded wage authority sit on the default (Labor)
        // tab.
        expect(
          find.byKey(const Key('data_accuracy_wage_source_card')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const Key('operator_web_data_accuracy_wage_authority_section'),
          ),
          findsOneWidget,
        );
        // The covers card lives on the Covers tab.
        await openCoversTab(tester);
        expect(
          find.byKey(const Key('data_accuracy_covers_source_card')),
          findsOneWidget,
        );

        expect(
          find.byKey(const Key('admin_data_accuracy_table')),
          findsNothing,
        );
        expect(find.text('Audit history'), findsNothing);
        expect(
          find.byKey(const Key('admin_data_accuracy_pick_location')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('admin_data_accuracy_reason_dialog')),
          findsNothing,
        );
      },
    );

    testWidgets('covers source edits save through the admin adapter', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildGateway();
      await tester.pumpWidget(
        wrap(buildScreen(gateway: gateway, scope: locationScope)),
      );
      await tester.pumpAndSettle();
      await openCoversTab(tester);

      expect(settingsSaveEvents(gateway), isEmpty);

      final forecastChip = find.byKey(
        const Key('covers_source_chip_lunch_forecast'),
      );
      await tester.ensureVisible(forecastChip);
      await tester.tap(forecastChip);
      await tester.pumpAndSettle();

      final events = settingsSaveEvents(gateway);
      expect(events, hasLength(1));
      expect(events.single.locationId, 'loc-1a');
      expect(events.single.reasonNote, 'Admin Data Accuracy parity edit.');
      expect(events.single.diff['covers_source_per_service_period'], isNotNull);
    });

    testWidgets('wage source edits save through the admin adapter', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildGateway();
      await tester.pumpWidget(
        wrap(buildScreen(gateway: gateway, scope: locationScope)),
      );
      await tester.pumpAndSettle();

      final manualRadio = find.byKey(const Key('wage_source_radio_manual_mix'));
      await tester.ensureVisible(manualRadio);
      await tester.tap(manualRadio);
      await tester.pumpAndSettle();

      final events = settingsSaveEvents(gateway);
      expect(events, hasLength(1));
      expect(events.single.diff['wage_source'], isNotNull);
    });
  });

  group('scope and timing posture', () {
    testWidgets('non-location scope leaves selection to the left picker', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildGateway();
      await tester.pumpWidget(
        wrap(buildScreen(gateway: gateway, scope: businessScope)),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_data_accuracy_waiting_for_location_scope')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_location_required_banner')),
        findsOneWidget,
      );
      expect(
        find.text('Select a location to edit data accuracy'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_pick_location')),
        findsNothing,
      );
      expect(find.byKey(const Key('admin_data_accuracy_table')), findsNothing);
    });

    testWidgets('admin freshness action redirects to Polling Setup', (
      tester,
    ) async {
      wideViewport(tester);
      var openedPollingSetup = 0;
      final gateway = buildGateway();
      await tester.pumpWidget(
        wrap(
          buildScreen(
            gateway: gateway,
            scope: locationScope,
            onOpenPollingSetup: () {
              openedPollingSetup += 1;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await openFreshnessTab(tester);

      expect(find.text('Open Polling Setup'), findsOneWidget);
      expect(find.text('Request faster data freshness'), findsNothing);

      final action = find.byKey(
        const Key('polling_tier_request_change_button'),
      );
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();

      expect(openedPollingSetup, 1);
    });

    testWidgets('missing timing resolution shows the ops-style error posture', (
      tester,
    ) async {
      wideViewport(tester);
      final gateway = buildGateway();
      await tester.pumpWidget(
        wrap(
          buildScreen(
            gateway: gateway,
            scope: locationScope,
            timing: timingGateway(includeLocation: false),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(
          const Key('operator_web_data_accuracy_business_timing_error'),
        ),
        findsOneWidget,
      );
      expect(find.text('Data accuracy needs Business Timing'), findsOneWidget);
      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsNothing,
      );
    });
  });

  testWidgets('rendered text never contains an em dash', (tester) async {
    wideViewport(tester);
    final gateway = buildGateway();
    await tester.pumpWidget(
      wrap(buildScreen(gateway: gateway, scope: locationScope)),
    );
    await tester.pumpAndSettle();

    // The mounted screen shows one area at a time; sweep all three tabs
    // so the em-dash check covers covers + data-freshness copy too.
    void sweepForEmDash() {
      final texts = tester.widgetList<Text>(find.byType(Text));
      for (final text in texts) {
        final data = text.data;
        if (data == null) continue;
        expect(data.contains('\u2014'), isFalse, reason: data);
      }
    }

    sweepForEmDash();
    await openCoversTab(tester);
    sweepForEmDash();
    await openFreshnessTab(tester);
    sweepForEmDash();
  });
}

class _EmptyVendorApplicabilityAdminGateway
    implements VendorApplicabilityAdminGateway {
  const _EmptyVendorApplicabilityAdminGateway();

  @override
  Future<List<VendorApplicabilityAdminRow>> list({
    VendorApplicabilityAdminFilter filter =
        const VendorApplicabilityAdminFilter(),
  }) async {
    return const <VendorApplicabilityAdminRow>[];
  }

  @override
  Future<VendorApplicabilityAdminRow> upsert(
    VendorApplicabilityUpsertCommand command,
  ) {
    throw UnsupportedError('not used by Data Accuracy mount tests');
  }

  @override
  Future<VendorApplicabilityAdminRow?> end(
    VendorApplicabilityEndCommand command,
  ) {
    throw UnsupportedError('not used by Data Accuracy mount tests');
  }
}
