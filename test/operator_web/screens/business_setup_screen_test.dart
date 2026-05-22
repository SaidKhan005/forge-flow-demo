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

  testWidgets('owner sees the Service periods read view with demo timing', (
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
    // Page heading, the nav label, the edit button, and the periods card
    // title all read "Service periods" now (one consistent label).
    final navTitle = tester.widget<Text>(
      find.byKey(const Key('operator_web_business_setup_nav_title')),
    );
    expect(navTitle.data, 'Service periods');

    expect(
      find.byKey(const Key('operator_web_business_timing_effective_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_periods_card')),
      findsOneWidget,
    );
    expect(find.text('Timing defaults'), findsOneWidget);

    // The page-level hierarchy clutter stays gone (top scope picker owns it).
    expect(
      find.byKey(const Key('operator_web_business_setup_hierarchy_tree')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_inheritance_card')),
      findsNothing,
    );

    // Inheritance now shows a single "Inherited" pill, not the old verbose
    // "Source: ..." / "Inherited from ..." copy.
    expect(find.text('Inherited'), findsWidgets);
    expect(find.text('Inherited from Operator default'), findsNothing);
    expect(find.text('Source: Operator default'), findsNothing);

    expect(find.text('Lunch'), findsOneWidget);
    expect(find.text('Late night'), findsOneWidget);

    // Edit control is present, sized, and labelled "Edit service periods".
    // No reset button on the demo read view (router wires reset semantics).
    expect(
      find.byKey(const Key('operator_web_business_timing_edit_controls')),
      findsOneWidget,
    );
    expect(find.text('Edit service periods'), findsOneWidget);
    expect(
      find.byKey(const Key('operator_web_business_timing_reset_button')),
      findsNothing,
    );

    // With no live write gateway wired, Edit opens the safe (non-mutating)
    // demo dialog.
    await tester.tap(
      find.byKey(const Key('operator_web_business_timing_edit_button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('operator_web_business_timing_safe_dialog')),
      findsOneWidget,
    );
    expect(find.text('Timing changes are unavailable here'), findsOneWidget);
    expect(
      find.textContaining('disabled in this demo preview'),
      findsOneWidget,
    );
    expect(find.textContaining('Nothing was changed'), findsOneWidget);
  });

  testWidgets('location managers see a read-only timing view', (tester) async {
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
    expect(find.textContaining('view this location\'s timing'), findsOneWidget);
  });

  testWidgets('Edit uses the router callback when a live editor is wired', (
    tester,
  ) async {
    await sizeViewport(tester);
    var openedEditor = false;

    await tester.pumpWidget(
      wrap(
        BusinessSetupScreen(
          session: kDemoOperatorWebSession,
          locationId: 'demo-location',
          onEditTiming: () => openedEditor = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('operator_web_business_timing_edit_button')),
    );
    await tester.pumpAndSettle();

    // The callback fires and the safe demo dialog does NOT appear, because a
    // real editor is now responsible for the edit.
    expect(openedEditor, isTrue);
    expect(
      find.byKey(const Key('operator_web_business_timing_safe_dialog')),
      findsNothing,
    );
  });
}
