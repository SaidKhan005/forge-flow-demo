// Admin Data Accuracy smoke render.
//
// The tab now mounts the Operator Web Data Accuracy surface for the selected
// admin location. The old multi-location table is intentionally gone from this
// screen.

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
  const locationScope = AdminHierarchyScopeIntent.location(
    operatorId: 'op-1',
    locationId: 'loc-1a',
    operatorName: 'Demo Diner Co.',
    locationName: 'Toronto Yorkville',
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

  InMemoryDataAccuracyAdminGateway gateway() {
    return InMemoryDataAccuracyAdminGateway(
      operatorLocations: const <OperatorLocationRef>[
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
      ],
    );
  }

  InMemoryAdminBusinessTimingResolutionGateway timingGateway() {
    return InMemoryAdminBusinessTimingResolutionGateway(
      seed: <String, AdminBusinessTimingResolution>{
        InMemoryAdminBusinessTimingResolutionGateway.keyFor(
          'op-1',
          'loc-1a',
        ): const AdminBusinessTimingResolution(
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
        ),
      },
    );
  }

  testWidgets('renders the selected location Operator Web surface only', (
    tester,
  ) async {
    wideViewport(tester);

    await tester.pumpWidget(
      wrap(
        PerLocationDataAccuracyScreen(
          gateway: gateway(),
          actorUserId: 'demo-super-admin',
          timingResolutionGateway: timingGateway(),
          vendorApplicabilityGateway:
              const _EmptyVendorApplicabilityAdminGateway(),
          initialHierarchyScope: locationScope,
          nowUtc: () => DateTime.utc(2026, 5, 24, 15),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_data_accuracy_screen')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('data_accuracy_tab_labor')), findsOneWidget);
    expect(find.byKey(const Key('data_accuracy_tab_covers')), findsOneWidget);
    expect(
      find.byKey(const Key('data_accuracy_tab_freshness')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('data_accuracy_wage_source_card')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('data_accuracy_explainer_card')), findsNothing);

    await tester.tap(find.byKey(const Key('data_accuracy_tab_covers')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('data_accuracy_covers_source_card')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('admin_data_accuracy_table')), findsNothing);
    expect(find.text('Vancouver Robson'), findsNothing);
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
    throw UnsupportedError('not used by Data Accuracy render tests');
  }

  @override
  Future<VendorApplicabilityAdminRow?> end(
    VendorApplicabilityEndCommand command,
  ) {
    throw UnsupportedError('not used by Data Accuracy render tests');
  }
}
