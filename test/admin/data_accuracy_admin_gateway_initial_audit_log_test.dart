// Phase 2 walkthrough V1.1 admin follow-up — RP-15-FU-admin-demo-override-fixture.
//
// The demo `_defaultDataAccuracyDemoGateway` in `lib/admin/admin_routes.dart`
// seeds one historical admin override on Demo Diner Co. → Toronto Yorkville
// so the per-location Data Accuracy audit panel shows a real audit row
// instead of the "0 events / No admin overrides recorded yet." empty state.
//
// That seed flows through a new `initialAuditLog` constructor parameter on
// `InMemoryDataAccuracyAdminGateway`. This test pins that contract:
//
//   * Seeded events surface verbatim through `listAuditHistory()` (the
//     reader path the per-location screen subscribes to).
//   * Operator/location filters keep working over the seeded buffer.
//   * Subsequent `overrideDataAccuracy()` calls append to the same buffer
//     without colliding event IDs (the seed uses a `demo-audit-…` prefix;
//     the gateway generates `audit-N` IDs from `_auditLog.length + 1`).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';

void main() {
  group(
    'InMemoryDataAccuracyAdminGateway.initialAuditLog '
    '(RP-15-FU-admin-demo-override-fixture)',
    () {
      test(
        'seeded events surface through listAuditHistory and survive '
        'subsequent overrideDataAccuracy writes',
        () async {
          const operatorId = 'op-rp15';
          const locationId = 'loc-rp15';
          final seededAt = DateTime.utc(2026, 5, 10, 14, 17);

          final gateway = InMemoryDataAccuracyAdminGateway(
            operatorLocations: const <OperatorLocationRef>[
              OperatorLocationRef(
                operatorId: operatorId,
                businessName: 'RP-15 Demo Co.',
                locationId: locationId,
                locationName: 'Test Location',
              ),
            ],
            initialAuditLog: <DataAccuracyAdminAuditEvent>[
              DataAccuracyAdminAuditEvent(
                eventId: 'demo-audit-rp15-1',
                eventType: 'admin.data_accuracy.override',
                occurredAt: seededAt,
                actorUserId: 'support@example.com',
                operatorId: operatorId,
                locationId: locationId,
                diff: const <String, Object?>{
                  'covers_source_lunch': <String, Object?>{
                    'from': 'vendor',
                    'to': 'manual',
                  },
                },
                reasonNote: 'Vendor drift; switching to manual.',
                actorDisplayName: 'F&F Support',
                actorRole: 'Forge & Flow admin',
                actorEmail: 'support@example.com',
              ),
            ],
          );

          // Reader-path assertion: the seed surfaces through the same
          // path the per-location screen subscribes to.
          final seeded = await gateway.listAuditHistory();
          expect(seeded, hasLength(1));
          expect(seeded.single.eventId, 'demo-audit-rp15-1');
          expect(seeded.single.eventType, 'admin.data_accuracy.override');
          expect(seeded.single.operatorId, operatorId);
          expect(seeded.single.locationId, locationId);
          expect(seeded.single.actorDisplayName, 'F&F Support');

          // The operator/location filters keep working over the seeded
          // rows (the per-location screen sometimes scopes by location).
          final scoped = await gateway.listAuditHistory(
            operatorId: operatorId,
            locationId: locationId,
          );
          expect(scoped, hasLength(1));
          expect(scoped.single.eventId, 'demo-audit-rp15-1');

          final mismatch = await gateway.listAuditHistory(
            operatorId: 'op-other',
          );
          expect(mismatch, isEmpty);

          // Subsequent writes append to the same buffer and use a
          // generated `audit-N` ID; the seed survives.
          await gateway.overrideDataAccuracy(
            operatorId: operatorId,
            locationId: locationId,
            wageSource: WageSource.manualMix,
            actorUserId: 'support@example.com',
            actorIsForgeAdmin: true,
            reasonNote: 'Subsequent override (admin-undo of the seed).',
          );

          final afterWrite = await gateway.listAuditHistory();
          expect(afterWrite, hasLength(2));
          // Seed survives.
          expect(
            afterWrite.map((e) => e.eventId),
            containsAll(<String>['demo-audit-rp15-1', 'audit-2']),
          );
        },
      );
    },
  );
}
