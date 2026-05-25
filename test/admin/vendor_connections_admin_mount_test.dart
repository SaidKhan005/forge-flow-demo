import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_route_handoff.dart';
import 'package:forge_and_flow/admin/screens/vendor_connections/vendor_connections_admin_mount.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/vendor_connections_widget.dart';
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
    final widget = tester.widget<VendorConnectionsWidget>(
      find.byType(VendorConnectionsWidget),
    );
    expect(widget.onConnectFlowStarted, isNotNull);
  });

  testWidgets('business scope shows the location-required copy', (
    tester,
  ) async {
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

    expect(find.byKey(const Key('admin_hierarchy_scope_prompt')), findsNothing);
    expect(
      find.byKey(const Key('admin_vendor_connections_location_required')),
      findsOneWidget,
    );
    expect(find.text('Location required'), findsWidgets);
    expect(
      find.textContaining(
        'Choose a location to show connect, test, disconnect',
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('vendor_connections_section_pos')),
      findsNothing,
    );
  });

  testWidgets(
    'org-unit scope shows location-required state without old scope popup',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          VendorConnectionsAdminMount(
            operatorId: 'op-1',
            selectedScope: orgUnitScope,
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
        find.byKey(const Key('admin_hierarchy_scope_prompt')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_vendor_connections_location_required')),
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
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

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

    final posTop = tester
        .getTopLeft(find.byKey(const Key('vendor_connections_section_pos')))
        .dy;
    final laborTop = tester
        .getTopLeft(find.byKey(const Key('vendor_connections_section_labor')))
        .dy;
    final reservationTop = tester
        .getTopLeft(
          find.byKey(const Key('vendor_connections_section_reservation')),
        )
        .dy;
    expect(posTop, lessThan(laborTop));
    expect(laborTop, lessThan(reservationTop));
  });

  testWidgets(
    'embedded location scope mounts the shared widget in the web body '
    'without the in-body scope-context box',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        wrap(
          VendorConnectionsAdminMount(
            operatorId: 'op-1',
            selectedScope: locationScope,
            gateway: InMemoryVendorConnectionsGateway(),
            embedded: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_vendor_connections_screen')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_vendor_connections_screen_body')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_vendor_connections_widget_host')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('vendor_connections_section_pos')),
        findsOneWidget,
      );
      // The workspace header owns scope display in the embedded path, so
      // the legacy in-body scope-context box is intentionally dropped.
      expect(
        find.byKey(const Key('admin_vendor_connections_scope_context')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('admin_vendor_connections_location_required')),
        findsNothing,
      );
    },
  );

  testWidgets('embedded location scope without a gateway shows the web-style '
      'not-wired panel', (tester) async {
    await tester.pumpWidget(
      wrap(
        const VendorConnectionsAdminMount(
          operatorId: 'op-1',
          selectedScope: locationScope,
          embedded: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('admin_vendor_connections_screen_body')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('admin_vendor_connections_not_wired')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('vendor_connections_section_pos')),
      findsNothing,
    );
  });

  testWidgets(
    'embedded business scope shows the web-style location-required panel',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          VendorConnectionsAdminMount(
            operatorId: 'op-1',
            selectedScope: businessScope,
            gateway: InMemoryVendorConnectionsGateway(),
            embedded: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('admin_vendor_connections_screen_body')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_vendor_connections_location_required')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('admin_vendor_connections_scope_context')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('vendor_connections_section_pos')),
        findsNothing,
      );
    },
  );
}
