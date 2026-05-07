import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/vendor_connections/vendor_connections_admin_mount.dart';
import 'package:forge_and_flow/integrations/ui/vendor_connections/in_memory_vendor_connections_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: child,
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
}
