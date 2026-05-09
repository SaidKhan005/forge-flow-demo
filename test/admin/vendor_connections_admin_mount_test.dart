import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/vendor_connections/vendor_connections_admin_mount.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
  );

  const businessScope = AdminHierarchyScopeIntent.business(
    operatorId: 'op-1',
    operatorName: 'Harbour Group',
    valueState: AdminHierarchyScopeValueState.setAtScope,
    allowedActionsLabel: 'Location required',
  );

  const orgUnitScope = AdminHierarchyScopeIntent.orgUnit(
    operatorId: 'op-1',
    orgUnitId: 'ou-downtown',
    operatorName: 'Harbour Group',
    orgUnitName: 'Downtown',
    valueState: AdminHierarchyScopeValueState.inheritedFromBusiness,
    inheritedFromLabel: 'business',
    allowedActionsLabel: 'Location required',
  );

  const locationScope = AdminHierarchyScopeIntent.location(
    operatorId: 'op-1',
    orgUnitId: 'ou-downtown',
    orgUnitName: 'Downtown',
    locationId: 'loc-1',
    locationName: 'Harbour',
    valueState: AdminHierarchyScopeValueState.locationOnly,
    allowedActionsLabel: 'Can edit',
  );

  testWidgets('does not fall back to demo vendor data without a gateway', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const VendorConnectionsAdminMount(
          operatorId: 'op-1',
          locationId: 'loc-1',
          locationName: 'Harbour',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_vendor_connections_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_vendor_connections_not_wired')),
      findsOneWidget,
    );
    expect(
      find.textContaining('Lifecycle actions are not live'),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('vendor_connections_section_pos')),
      findsNothing,
    );
  });

  testWidgets('uses the shared vendor widget when a gateway is injected', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        VendorConnectionsAdminMount(
          operatorId: 'op-1',
          locationId: 'loc-1',
          locationName: 'Harbour',
          gateway: InMemoryVendorConnectionsGateway(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_vendor_connections_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_vendor_connections_not_wired')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('vendor_connections_section_pos')),
      findsOneWidget,
    );
  });

  testWidgets(
    'business scope shows selected context and location-required copy',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          VendorConnectionsAdminMount(
            operatorId: 'op-1',
            selectedScope: businessScope,
            scopeOptions: const <AdminHierarchyScopeIntent>[
              businessScope,
              orgUnitScope,
              locationScope,
            ],
            gateway: InMemoryVendorConnectionsGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_vendor_connections_scope_context')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_vendor_connections_selected_scope')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_hierarchy_scope_prompt')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_vendor_connections_location_required')),
        findsOneWidget,
      );
      expect(find.text('Location required'), findsWidgets);
      expect(
        find.textContaining('vendor setup remains location-only'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('vendor_connections_section_pos')),
        findsNothing,
      );
    },
  );

  testWidgets('location scope enables the shared vendor widget', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        VendorConnectionsAdminMount(
          operatorId: 'op-1',
          selectedScope: locationScope,
          scopeOptions: const <AdminHierarchyScopeIntent>[
            businessScope,
            orgUnitScope,
            locationScope,
          ],
          gateway: InMemoryVendorConnectionsGateway(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('admin_hierarchy_scope_prompt')), findsNothing);
    expect(
      find.byKey(const Key('admin_vendor_connections_location_required')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('vendor_connections_section_pos')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_vendor_connections_selected_scope')),
      findsOneWidget,
    );
    expect(find.text('Selected location scope'), findsOneWidget);
  });
}
