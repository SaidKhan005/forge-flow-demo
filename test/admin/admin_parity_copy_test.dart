import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/screens/integration_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/vendor_applicability_admin_screen.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_gateway.dart';
import 'package:forge_and_flow/admin/services/admin_business_timing_resolution_projection.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/integration_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/vendor_applicability_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  const adminOnlyCopy =
      'This surface is for F&F admins only. Operators cannot see it.';

  AdminRoute routeById(String id) {
    return kAdminRoutes.singleWhere((route) => route.id == id);
  }

  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  const operatorLocations = <OperatorLocationRef>[
    OperatorLocationRef(
      operatorId: 'op-1',
      businessName: 'Demo Diner Co.',
      locationId: 'loc-1',
      locationName: 'Toronto Yorkville',
    ),
  ];

  const locationScope = AdminHierarchyScopeIntent.location(
    operatorId: 'op-1',
    locationId: 'loc-1',
    operatorName: 'Demo Diner Co.',
    locationName: 'Toronto Yorkville',
  );

  InMemoryAdminBusinessTimingResolutionGateway timingGateway() {
    return InMemoryAdminBusinessTimingResolutionGateway(
      seed: <String, AdminBusinessTimingResolution>{
        InMemoryAdminBusinessTimingResolutionGateway.keyFor(
          'op-1',
          'loc-1',
        ): const AdminBusinessTimingResolution(
          operatorId: 'op-1',
          locationId: 'loc-1',
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
              ],
            ),
          ],
        ),
      },
    );
  }

  group('C-10 admin parity ownership copy', () {
    test('route labels support actions honestly', () {
      // Route-level nav badges were all removed as clutter (see loop note
      // below). Ownership intent now lives in the subtitle copy, asserted
      // throughout this test.
      expect(routeById(kAdminDataAccuracyRouteId).badge, isNull);
      expect(
        routeById(kAdminDataAccuracyRouteId).subtitle,
        contains('super admins can apply audited location repairs'),
      );
      expect(routeById(kAdminVendorApplicabilityRouteId).badge, isNull);
      expect(
        routeById(kAdminVendorApplicabilityRouteId).path,
        '/vendor-applicability',
      );
      expect(
        routeById(kAdminVendorApplicabilityRouteId).subtitle,
        contains('choose which vendors can power wage, covers, and polling'),
      );
      expect(routeById(kAdminVendorIntegrationsRouteId).badge, isNull);
      expect(
        routeById(kAdminVendorIntegrationsRouteId).subtitle,
        contains('super admins can connect, test, and disconnect vendors'),
      );
      expect(
        routeById(kAdminTimingSetupRouteId).subtitle,
        contains('service periods for the selected scope'),
      );

      expect(routeById(kAdminIntegrationsRouteId).badge, isNull);
      expect(
        routeById(kAdminIntegrationsRouteId).subtitle,
        contains('global provider health'),
      );
      expect(
        routeById(kAdminIntegrationsRouteId).subtitle,
        contains('operator edits live on Operator Web'),
      );

      for (final routeId in <String>[
        kAdminPricingRouteId,
        kAdminCorpusRouteId,
        kAdminPollingPricingRouteId,
        kAdminHealthRouteId,
        kAdminFeatureFlagsRouteId,
        kAdminDebugConsoleRouteId,
        kAdminObservabilityRouteId,
      ]) {
        final route = routeById(routeId);
        // Route-level nav badges were removed across the admin console as
        // clutter: in an all-admin surface they added noise, not signal.
        // Ownership stays honest via the subtitle copy asserted below.
        expect(route.badge, isNull, reason: routeId);
        expect(route.subtitle, contains(adminOnlyCopy), reason: routeId);
      }

      final defaultRolesRoute = routeById(kAdminDefaultRoleCatalogRouteId);
      expect(defaultRolesRoute.badge, isNull);
      expect(defaultRolesRoute.title, 'Default roles');
      expect(
        defaultRolesRoute.subtitle,
        contains('starter roles every new business receives'),
      );
    });

    testWidgets('vendor applicability route builds reachable admin page', (
      tester,
    ) async {
      final route = routeById(kAdminVendorApplicabilityRouteId);

      expect(route.visibleInNav, isTrue);
      expect(route.section, AdminRouteSection.operations);

      await tester.pumpWidget(wrap(Builder(builder: route.builder)));
      await tester.pumpAndSettle();

      expect(find.byType(VendorApplicabilityAdminScreen), findsOneWidget);
      expect(find.text('Vendor Applicability'), findsWidgets);
    });

    testWidgets('data accuracy read-only mode keeps the Operator Web surface', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyScreen(
            gateway: InMemoryDataAccuracyAdminGateway(
              operatorLocations: operatorLocations,
            ),
            actorUserId: 'support-user',
            timingResolutionGateway: timingGateway(),
            vendorApplicabilityGateway:
                const _EmptyVendorApplicabilityAdminGateway(),
            editingEnabled: false,
            initialHierarchyScope: locationScope,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('operator_web_data_accuracy_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_data_accuracy_readonly_banner')),
        findsNothing,
      );
    });

    testWidgets('polling setup read-only mode names F&F-only ownership', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PollingAndPricingAdminScreen(
            gateway: InMemoryDataAccuracyAdminGateway(
              operatorLocations: operatorLocations,
            ),
            actorUserId: 'support-user',
            editingEnabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_polling_pricing_readonly_banner')),
        findsOneWidget,
      );
      expect(find.text(adminOnlyCopy), findsOneWidget);
    });

    testWidgets('connected services copy names global health intent', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          IntegrationAdminScreen(
            gateway: InMemoryIntegrationAdminGateway(),
            editingEnabled: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Review global provider health and platform keys'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Global provider health stays here'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Operator edits live on Operator Web; this view is for F&F support.',
        ),
        findsNWidgets(2),
      );
      expect(
        find.byKey(const Key('admin_integrations_scope_note')),
        findsNothing,
      );
      expect(find.text('Where this applies'), findsNothing);
      expect(
        find.byKey(const Key('admin_integration_scope_notice')),
        findsNothing,
      );
    });
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
    throw UnsupportedError('not used by admin parity copy tests');
  }

  @override
  Future<VendorApplicabilityAdminRow?> end(
    VendorApplicabilityEndCommand command,
  ) {
    throw UnsupportedError('not used by admin parity copy tests');
  }
}
