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

  testWidgets('renders inherited timing demo data for owners', (tester) async {
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
    // Wave 2 U-FU-hp11-account — nav title carries the active
    // location-scope hint per HP #11.
    expect(
      find.byKey(const Key('operator_web_business_setup_nav_title')),
      findsOneWidget,
    );
    expect(find.text('Business setup • Demo Main Street'), findsOneWidget);
    expect(
      find.byKey(const Key('operator_web_business_timing_inheritance_card')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_effective_card')),
      findsOneWidget,
    );
    // Wave 2 H-2: visual hierarchy tree mounts above the existing
    // text inheritance card.
    expect(
      find.byKey(const Key('operator_web_business_setup_hierarchy_tree')),
      findsOneWidget,
    );
    // The location is the current scope on the business setup
    // screen, so it should be highlighted with the "You are here"
    // badge.
    expect(
      find.byKey(
        const Key(
          'operator_web_business_setup_hierarchy_tree_node_location_current_badge',
        ),
      ),
      findsOneWidget,
    );
    // Header pill names the current scope in plain English.
    expect(find.textContaining('Editing Location'), findsOneWidget);
    expect(
      find.byKey(
        const Key(
          'operator_web_business_setup_hierarchy_tree_currently_editing_pill',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('Inherited from Operator default'), findsWidgets);
    expect(find.text('Lunch'), findsOneWidget);
    expect(find.text('Late night'), findsOneWidget);
    expect(find.text('Source: Operator default'), findsWidgets);
    expect(find.text('Shift close authority'), findsNothing);
    expect(
      find.byKey(const Key('operator_web_business_timing_edit_controls')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('operator_web_business_timing_reset_button')),
      findsNothing,
    );
    expect(find.text('Where this location sits'), findsOneWidget);
    expect(find.text('Where timing comes from'), findsOneWidget);
    expect(find.text('Timing in use'), findsOneWidget);
    expect(find.text('Edit time settings'), findsOneWidget);
    expect(find.text('Schedule future timing'), findsOneWidget);
    expect(find.text('Live editor'), findsNothing);
    expect(find.text('Read-only preview'), findsNothing);

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

  testWidgets('location managers can view location timing', (tester) async {
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
    expect(find.textContaining('view effective timing'), findsNothing);
  });

  testWidgets('schedule timing uses the router callback when available', (
    tester,
  ) async {
    await sizeViewport(tester);
    var openedScheduleTiming = false;

    await tester.pumpWidget(
      wrap(
        BusinessSetupScreen(
          session: kDemoOperatorWebSession,
          locationId: 'demo-location',
          onScheduleTiming: () => openedScheduleTiming = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('operator_web_business_timing_schedule_button')),
    );
    await tester.pumpAndSettle();

    expect(openedScheduleTiming, isTrue);
    expect(
      find.byKey(const Key('operator_web_business_timing_safe_dialog')),
      findsNothing,
    );
  });
}
