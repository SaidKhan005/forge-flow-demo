import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/admin_app.dart';
import 'package:forge_and_flow/admin/admin_auth_gate.dart';

import '../_test_helpers/widget_pump_helpers.dart';

void main() {
  testWidgets('admin app applies the readable console text floor', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final source = DemoAdminAuthSource.signedInAsSuperAdmin();
    addTearDown(source.dispose);

    await tester.pumpWidget(
      AdminConsoleApp(authSource: source, sharePreviewMode: true),
    );
    await pumpEventually(tester);

    final shellContext = tester.element(
      find.byKey(const Key('admin_shell_scaffold')),
    );
    expect(
      MediaQuery.of(shellContext).textScaler.scale(100),
      closeTo(116, 0.01),
    );
    expect(find.byKey(const Key('admin_header_bar')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
