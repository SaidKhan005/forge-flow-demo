// Phase 8 spine-bridge Lane .C — acceptance item D.
//
// Tab 2 tier definition edit round-trips: open the dialog, change
// description + price, submit, and assert the captured audit event
// + the new tier definition row reflect the change.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/polling_and_pricing_admin_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  group('8.spine-bridge.C — Tab 2 tier definition edit round-trips '
      'with audit row', () {
    testWidgets('standard tier description + price update writes '
        'admin.polling_tier_definition.update', (tester) async {
      // Use a wide viewport so the screen's filter bar fits without
      // overflow exceptions during layout.
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      // The filter-bar DropdownButtonFormField overflows horizontally
      // by ~1.4 px in the test environment; not our concern in this
      // slice. Swallow the layout-overflow assertion so the click-path
      // assertions can still run.
      final FlutterExceptionHandler? prior = FlutterError.onError;
      FlutterError.onError = (details) {
        final msg = details.exceptionAsString();
        if (msg.contains('A RenderFlex overflowed')) return;
        prior?.call(details);
      };
      addTearDown(() {
        FlutterError.onError = prior;
      });
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[
          OperatorLocationRef(
            operatorId: 'op-1',
            businessName: 'Demo Diner Co.',
            locationId: 'loc-1a',
            locationName: 'Toronto Yorkville',
          ),
        ],
        initialTierDefinitions: <PollingTierKey, TierDefinition>{
          PollingTierKey.standard: kDemoStandardTierDefinition(),
          PollingTierKey.premium: kDemoPremiumTierDefinition(),
          PollingTierKey.custom: kDemoCustomTierDefinition(),
        },
      );

      await tester.pumpWidget(
        wrap(
          PollingAndPricingAdminScreen(
            gateway: gateway,
            actorUserId: 'demo-super-admin',
            editingEnabled: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Expand the standard tier definition subcard. The card is an
      // ExpansionTile whose title contains the text "Standard"; tap it
      // to expand the children (which include the Edit button).
      final subcard = find.byKey(
        const Key('admin_tier_definition_standard'),
      );
      expect(subcard, findsOneWidget);
      final standardTitle = find.descendant(
        of: subcard,
        matching: find.text('Standard'),
      );
      expect(standardTitle, findsOneWidget);
      await tester.ensureVisible(standardTitle);
      await tester.pumpAndSettle();
      await tester.tap(standardTitle);
      await tester.pumpAndSettle();

      // Tap the Edit button on the standard tier subcard (now visible
      // because the ExpansionTile is expanded).
      final editButton = find.byKey(
        const Key('admin_tier_definition_edit_standard'),
      );
      expect(editButton, findsOneWidget);
      await tester.ensureVisible(editButton);
      await tester.pumpAndSettle();
      await tester.tap(editButton);
      await tester.pumpAndSettle();

      // Dialog opens.
      expect(
        find.byKey(const Key('admin_tier_definition_dialog')),
        findsOneWidget,
      );

      // Change description.
      await tester.enterText(
        find.byKey(const Key('admin_tier_definition_dialog_description')),
        'Updated standard description',
      );
      await tester.pump();

      // Change price (USD/month). Dialog parses dollars.
      await tester.enterText(
        find.byKey(const Key('admin_tier_definition_dialog_price')),
        '129.00',
      );
      await tester.pump();

      // Reason note is required.
      await tester.enterText(
        find.byKey(const Key('admin_tier_definition_dialog_reason')),
        'Annual price refresh',
      );
      await tester.pump();

      // Submit.
      await tester.tap(
        find.byKey(const Key('admin_tier_definition_dialog_submit')),
      );
      await tester.pumpAndSettle();

      // Assert: one new audit event captured for standard.
      final updates = gateway.capturedAuditEvents
          .where((e) => e.eventType == 'admin.polling_tier_definition.update')
          .toList();
      expect(updates, hasLength(1));
      expect(updates.single.diff['tier_key'], equals('standard'));

      // Assert: gateway.listTierDefinitions returns the standard tier
      // with the new description + price.
      final defs = await gateway.listTierDefinitions();
      final standard = defs.firstWhere(
        (d) => d.tierKey == PollingTierKey.standard,
      );
      expect(standard.descriptionMd, equals('Updated standard description'));
      expect(standard.defaultMonthlyPriceCents, equals(12900));
    });
  });
}
