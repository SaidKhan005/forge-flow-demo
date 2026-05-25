// Phase 8 spine-bridge Lane .C - acceptance item B.
//
// The Admin Data Accuracy screen now mounts the Operator Web Data Accuracy
// surface. Admin-specific audit semantics live in the admin gateway adapter,
// so these tests pin the gateway audit rows directly.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';

void main() {
  const ref = OperatorLocationRef(
    operatorId: 'op-1',
    businessName: 'Demo Diner Co.',
    locationId: 'loc-1a',
    locationName: 'Toronto Yorkville',
  );

  InMemoryDataAccuracyAdminGateway buildGateway() {
    return InMemoryDataAccuracyAdminGateway(
      operatorLocations: const <OperatorLocationRef>[ref],
    );
  }

  group('8.spine-bridge.C - Tab 1 admin override writes audit_logs row', () {
    test('gateway override captures admin.data_accuracy.override', () async {
      final gateway = buildGateway();
      const actorUid = 'demo-super-admin';

      await gateway.overrideDataAccuracy(
        operatorId: 'op-1',
        locationId: 'loc-1a',
        coversSourcePerServicePeriod: const <String, CoversSource>{
          'lunch': CoversSource.manual,
        },
        wageSource: WageSource.manualMix,
        actorUserId: actorUid,
        actorIsForgeAdmin: true,
        reasonNote: 'Walkthrough audit reason',
      );

      expect(gateway.capturedAuditEvents, hasLength(1));
      final event = gateway.capturedAuditEvents.single;
      expect(event.eventType, equals('admin.data_accuracy.override'));
      expect(event.actorUserId, equals(actorUid));
      expect(event.actorKind, equals('forge_admin'));
      expect(event.operatorId, equals('op-1'));
      expect(event.locationId, equals('loc-1a'));
      expect(
        event.diff.containsKey('covers_source_per_service_period'),
        isTrue,
      );
      expect(event.diff.containsKey('covers_source_lunch'), isFalse);
      expect(event.diff.containsKey('wage_source'), isTrue);
      expect(event.reasonNote, equals('Walkthrough audit reason'));

      final keyedDiff = event.diff['covers_source_per_service_period']! as Map;
      final lunchDiff = keyedDiff['lunch']! as Map;
      expect(lunchDiff['to'], equals(CoversSource.manual.wire));
      final wageDiff = event.diff['wage_source']! as Map;
      expect(wageDiff['to'], equals(WageSource.manualMix.wire));
    });
  });

  group('doc1.keyed-data-accuracy-write service-period override audit', () {
    test('gateway service-period override captures '
        'admin.data_accuracy.service_period_override', () async {
      final gateway = buildGateway();
      const actorUid = 'demo-super-admin';

      await gateway.overrideDataAccuracyServicePeriod(
        operatorId: 'op-1',
        locationId: 'loc-1a',
        servicePeriodKey: 'breakfast',
        coversSource: ServicePeriodCoversSource.reservationPlusWalkin,
        wageSource: ServicePeriodWageSource.targetSubstitution,
        effectiveAtBusinessDateIso: '2026-06-01',
        actorUserId: actorUid,
        actorIsForgeAdmin: true,
        reasonNote: 'Operator added breakfast service for summer hours',
      );

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
        final gateway = buildGateway();

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
      () {
        final gateway = buildGateway();

        expectLater(
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
  });
}
