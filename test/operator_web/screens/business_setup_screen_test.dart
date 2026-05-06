import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/business_setup_screen.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  testWidgets('renders inherited effective timing demo data for owners', (
    tester,
  ) async {
    await sizeViewport(tester);

    await tester.pumpWidget(
      wrap(
        const BusinessSetupScreen(
          session: kDemoOperatorWebSession,
          locationId: 'demo-location',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_business_setup_screen')),
      findsOneWidget,
    );
    expect(find.text('Business setup'), findsOneWidget);
    expect(
      find.byKey(const Key('operator_web_business_timing_inheritance_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_effective_card')),
      findsOneWidget,
    );
    expect(find.text('Inherited from Operator default'), findsWidgets);
    expect(find.text('Lunch'), findsOneWidget);
    expect(find.text('Late night'), findsOneWidget);
    expect(
      find.byKey(const Key('operator_web_business_timing_edit_controls')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('operator_web_business_timing_edit_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_business_timing_safe_dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('No timing change was written'), findsOneWidget);
  });

  testWidgets('location managers get read-only effective timing', (
    tester,
  ) async {
    await sizeViewport(tester);

    await tester.pumpWidget(
      wrap(
        const BusinessSetupScreen(
          session: kDemoOperatorWebLocationManagerSession,
          locationId: 'demo-location',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_business_setup_screen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_readonly_banner')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_edit_controls')),
      findsNothing,
    );
  });
}
