import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/screens/integration_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/vendor_applicability_admin_screen.dart';
import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/integration_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  const dataAccuracySupportCopy =
      'Support can review effective covers, wages, and walk-ins by location. Normal operator edits stay in Operator Web; location repair actions are hidden for this role.';
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
        contains('super admins can connect, test, disconnect'),
      );
      expect(
        routeById(kAdminTimingSetupRouteId).subtitle,
        contains('super admin repair routes are server-side'),
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
        // Lane B B2.2 — Default Role catalog admin editor is an
        // ecosystem-only surface; same admin-only ownership contract.
        kAdminDefaultRoleCatalogRouteId,
      ]) {
        final route = routeById(routeId);
        // Route-level nav badges were removed across the admin console as
        // clutter: in an all-admin surface they added noise, not signal.
        // Ownership stays honest via the subtitle copy asserted below.
        expect(route.badge, isNull, reason: routeId);
        expect(route.subtitle, contains(adminOnlyCopy), reason: routeId);
      }
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

    testWidgets('data accuracy read-only mode names Operator Web ownership', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyScreen(
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
        find.byKey(const Key('admin_data_accuracy_readonly_banner')),
        findsOneWidget,
      );
      expect(find.text(dataAccuracySupportCopy), findsOneWidget);
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
            hierarchyScope: const AdminHierarchyScopeIntent.orgUnit(
              operatorId: 'op-1',
              orgUnitId: 'ou-1',
              operatorName: 'Demo Diner Co.',
              orgUnitName: 'Downtown',
            ),
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
        findsOneWidget,
      );
      expect(find.text('Where this applies'), findsNothing);
      expect(
        find.byKey(const Key('admin_integration_scope_notice')),
        findsNothing,
      );
    });
  });
}
