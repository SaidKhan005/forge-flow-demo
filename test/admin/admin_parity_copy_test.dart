import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_routes.dart';
import 'package:forge_and_flow/admin/screens/integration_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/screens/vendor_applicability_admin_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/admin/services/integration_admin_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  const dataAccuracySupportCopy =
      'Support can review effective covers, wages, and walk-ins here. Normal operator edits stay in Operator Web; override actions are hidden for this role.';
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
      expect(routeById(kAdminDataAccuracyRouteId).badge, 'Support + override');
      expect(
        routeById(kAdminDataAccuracyRouteId).subtitle,
        contains('super admins can apply audited overrides'),
      );
      expect(routeById(kAdminVendorApplicabilityRouteId).badge, 'Admin only');
      expect(
        routeById(kAdminVendorApplicabilityRouteId).path,
        '/vendor-applicability',
      );
      expect(
        routeById(kAdminVendorApplicabilityRouteId).subtitle,
        contains('choose which vendors can power wage, covers, and polling'),
      );
      expect(
        routeById(kAdminVendorIntegrationsRouteId).badge,
        'Support + actions',
      );
      expect(
        routeById(kAdminVendorIntegrationsRouteId).subtitle,
        contains('super admins can connect, test, disconnect'),
      );
      expect(
        routeById(kAdminTimingSetupRouteId).subtitle,
        contains('super admin repair routes are server-side'),
      );

      expect(routeById(kAdminIntegrationsRouteId).badge, 'Global health');
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
        // ecosystem-only surface; same Admin-only badge contract.
        kAdminDefaultRoleCatalogRouteId,
      ]) {
        final route = routeById(routeId);
        expect(route.badge, 'Admin only', reason: routeId);
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
    });
  });
}
