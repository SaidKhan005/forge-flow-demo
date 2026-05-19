// Phase 8 spine-bridge Lane .C - acceptance item B.
//
// Tab 1 admin override writes an `audit_logs` row with the diff +
// reason note. Drives the screen click-path (Edit -> dialog -> submit)
// and asserts gateway.capturedAuditEvents captured the event.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/screens/per_location_data_accuracy_screen.dart';
import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  group('8.spine-bridge.C - Tab 1 admin override writes audit_logs row', () {
    testWidgets('Edit -> dialog submit captures admin.data_accuracy.override', (
      tester,
    ) async {
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
      final lunchDropdown = find.byKey(const Key('admin_data_accuracy_lunch'));
      expect(lunchDropdown, findsOneWidget);
      await tester.tap(lunchDropdown);
      await tester.pumpAndSettle();
      // Pick the manual covers option from the dropdown menu.
      await tester.tap(find.text('Manual entry').last);
      await tester.pumpAndSettle();

      // Set wage source to manual mix.
      final wageDropdown = find.byKey(
        const Key('admin_data_accuracy_wage_source'),
      );
      expect(wageDropdown, findsOneWidget);
      await tester.tap(wageDropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manual mix').last);
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

  // Doc 1 keyed-data-accuracy-write — Tab 1 admin keyed service-period
  // override goes through the same gateway audit path with
  // `actor_kind = 'forge_admin'` and a required reason note.
  group(
    'doc1.keyed-data-accuracy-write — Tab 1 service-period override audit',
    () {
      testWidgets('Service period button -> dialog submit captures '
          'admin.data_accuracy.service_period_override', (tester) async {
        tester.view.physicalSize = const Size(1600, 1400);
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

        final servicePeriodButton = find.byKey(
          const Key('admin_data_accuracy_service_period_op-1_loc-1a'),
        );
        expect(servicePeriodButton, findsOneWidget);
        await tester.ensureVisible(servicePeriodButton);
        await tester.pumpAndSettle();
        await tester.tap(servicePeriodButton, warnIfMissed: false);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('admin_data_accuracy_service_period_dialog')),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('admin_data_accuracy_service_period_key')),
          'breakfast',
        );
        await tester.enterText(
          find.byKey(
            const Key('admin_data_accuracy_service_period_effective_date'),
          ),
          '2026-06-01',
        );

        // Pick covers source = reservation_plus_walkin.
        await tester.tap(
          find.byKey(
            const Key('admin_data_accuracy_service_period_covers_source'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Reservations + walk-ins').last);
        await tester.pumpAndSettle();

        // Pick wage source = target_substitution.
        await tester.tap(
          find.byKey(
            const Key('admin_data_accuracy_service_period_wage_source'),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Target substitution').last);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(
            const Key('admin_data_accuracy_service_period_reason_note'),
          ),
          'Operator added breakfast service for summer hours',
        );
        await tester.pump();

        await tester.tap(
          find.byKey(const Key('admin_data_accuracy_service_period_submit')),
        );
        await tester.pumpAndSettle();

        expect(gateway.capturedAuditEvents, hasLength(1));
        final event = gateway.capturedAuditEvents.single;
        expect(
          event.eventType,
          equals('admin.data_accuracy.service_period_override'),
        );
        expect(event.actorUserId, equals(actorUid));
        expect(event.actorKind, equals('forge_admin'));
        expect(event.operatorId, equals('op-1'));
        expect(event.locationId, equals('loc-1a'));
        expect(event.diff['service_period_key'], equals('breakfast'));
        expect(event.diff['effective_at_business_date'], equals('2026-06-01'));
        final coversDiff = event.diff['covers_source']! as Map;
        expect(
          coversDiff['to'],
          equals(ServicePeriodCoversSource.reservationPlusWalkin.wire),
        );
        final wageDiff = event.diff['wage_source']! as Map;
        expect(
          wageDiff['to'],
          equals(ServicePeriodWageSource.targetSubstitution.wire),
        );
        expect(event.reasonNote, isNotNull);
        expect(event.reasonNote!.isNotEmpty, isTrue);

        // Listing the service-period rows back returns the row we
        // just wrote, sorted by (service_period_key,
        // effective_at_business_date desc).
        final rows = await gateway.listDataAccuracyServicePeriodRows(
          operatorId: 'op-1',
          locationId: 'loc-1a',
        );
        expect(rows, hasLength(1));
        expect(rows.single.servicePeriodKey, equals('breakfast'));
        expect(
          rows.single.coversSource,
          equals(ServicePeriodCoversSource.reservationPlusWalkin),
        );
        expect(
          rows.single.wageSource,
          equals(ServicePeriodWageSource.targetSubstitution),
        );
        expect(rows.single.effectiveAtBusinessDate, equals('2026-06-01'));
        expect(rows.single.updatedBy, equals(actorUid));
      });

      test(
        'gateway rejects service-period override missing reason note',
        () async {
          // Defence-in-depth: the dialog already requires a non-empty
          // reason note. The gateway must also reject the same shape so
          // a future caller (CLI / scripted tooling) cannot bypass the
          // audit requirement.
          final gateway = InMemoryDataAccuracyAdminGateway(
            operatorLocations: const <OperatorLocationRef>[
              OperatorLocationRef(
                operatorId: 'op-1',
                businessName: 'Demo Diner Co.',
                locationId: 'loc-1a',
                locationName: 'Toronto Yorkville',
              ),
            ],
          );

          await expectLater(
            () => gateway.overrideDataAccuracyServicePeriod(
              operatorId: 'op-1',
              locationId: 'loc-1a',
              servicePeriodKey: 'breakfast',
              coversSource: ServicePeriodCoversSource.vendor,
              wageSource: ServicePeriodWageSource.vendorPerEmployee,
              effectiveAtBusinessDateIso: '2026-06-01',
              actorUserId: 'demo-super-admin',
              actorIsForgeAdmin: true,
              reasonNote: '   ',
            ),
            throwsA(isA<DataAccuracyAdminGatewayError>()),
          );
          expect(gateway.capturedAuditEvents, isEmpty);
        },
      );

      test(
        'gateway throws DataAccuracyAdminForbiddenException for non-admin',
        () async {
          final gateway = InMemoryDataAccuracyAdminGateway(
            operatorLocations: const <OperatorLocationRef>[
              OperatorLocationRef(
                operatorId: 'op-1',
                businessName: 'Demo Diner Co.',
                locationId: 'loc-1a',
                locationName: 'Toronto Yorkville',
              ),
            ],
          );

          await expectLater(
            () => gateway.overrideDataAccuracyServicePeriod(
              operatorId: 'op-1',
              locationId: 'loc-1a',
              servicePeriodKey: 'breakfast',
              coversSource: ServicePeriodCoversSource.vendor,
              wageSource: ServicePeriodWageSource.vendorPerEmployee,
              effectiveAtBusinessDateIso: '2026-06-01',
              actorUserId: 'demo-support',
              actorIsForgeAdmin: false,
              reasonNote: 'attempted by support',
            ),
            throwsA(isA<DataAccuracyAdminForbiddenException>()),
          );
          expect(gateway.capturedAuditEvents, isEmpty);
        },
      );
    },
  );
}
