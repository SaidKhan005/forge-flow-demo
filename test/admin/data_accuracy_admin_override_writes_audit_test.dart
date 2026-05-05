// Phase 8 spine-bridge Lane .C — acceptance item B.
//
// Tab 1 admin override writes an `audit_logs` row with the diff +
// reason note. Drives the screen click-path (Edit -> dialog -> submit)
// and asserts gateway.capturedAuditEvents captured the event.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeData,
        home: Scaffold(body: child),
      );

  group('8.spine-bridge.C — Tab 1 admin override writes audit_logs row', () {
    testWidgets('Edit -> dialog submit captures admin.data_accuracy.override',
        (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      const ref = OperatorLocationRef(
        operatorId: 'op-1',
        businessName: 'Demo Diner Co.',
        locationId: 'loc-1a',
        locationName: 'Toronto Yorkville',
      );
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[ref],
      );

      const actorUid = 'demo-super-admin';

      await tester.pumpWidget(
        wrap(
          PerLocationDataAccuracyScreen(
            gateway: gateway,
            actorUserId: actorUid,
            editingEnabled: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap the Edit button on row 1.
      final editButton = find.byKey(
        const Key('admin_data_accuracy_edit_op-1_loc-1a'),
      );
      expect(editButton, findsOneWidget);
      await tester.ensureVisible(editButton);
      await tester.pumpAndSettle();
      await tester.tap(editButton, warnIfMissed: false);
      await tester.pumpAndSettle();

      // Dialog open.
      expect(
        find.byKey(const Key('admin_data_accuracy_override_dialog')),
        findsOneWidget,
      );

      // Change covers source for lunch from `vendor` to `manual`.
      final lunchDropdown = find.byKey(
        const Key('admin_data_accuracy_lunch'),
      );
      expect(lunchDropdown, findsOneWidget);
      await tester.tap(lunchDropdown);
      await tester.pumpAndSettle();
      // Pick the `manual` option from the dropdown menu.
      await tester.tap(find.text('manual').last);
      await tester.pumpAndSettle();

      // Set wage source to `manual_mix`.
      final wageDropdown = find.byKey(
        const Key('admin_data_accuracy_wage_source'),
      );
      expect(wageDropdown, findsOneWidget);
      await tester.tap(wageDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('manual_mix').last);
      await tester.pumpAndSettle();

      // Type a reason note.
      await tester.enterText(
        find.byKey(const Key('admin_data_accuracy_reason_note')),
        'Walkthrough audit reason',
      );
      await tester.pump();

      // Submit.
      await tester.tap(
        find.byKey(const Key('admin_data_accuracy_override_submit')),
      );
      await tester.pumpAndSettle();

      // Assert: exactly one audit event captured with the expected
      // shape.
      expect(gateway.capturedAuditEvents, hasLength(1));
      final event = gateway.capturedAuditEvents.single;
      expect(event.eventType, equals('admin.data_accuracy.override'));
      expect(event.actorUserId, equals(actorUid));
      // Contract: every Lane .C audit row carries
      // `actor_kind = 'forge_admin'`. Assert symmetrically with the
      // tier-assignment audit test so both write paths are pinned.
      expect(event.actorKind, equals('forge_admin'));
      expect(event.operatorId, equals('op-1'));
      expect(event.locationId, equals('loc-1a'));
      expect(event.diff.containsKey('covers_source_lunch'), isTrue);
      expect(event.diff.containsKey('wage_source'), isTrue);
      expect(event.reasonNote, isNotNull);
      expect(event.reasonNote!.isNotEmpty, isTrue);

      // The diff payload's `to` value matches what we picked.
      final lunchDiff = event.diff['covers_source_lunch']! as Map;
      expect(lunchDiff['to'], equals(CoversSource.manual.wire));
      final wageDiff = event.diff['wage_source']! as Map;
      expect(wageDiff['to'], equals(WageSource.manualMix.wire));
    });
  });
}
