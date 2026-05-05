// Phase 8 spine-bridge Lane .C — acceptance item G.
//
// Tab 2 tier change request approval transitions the ticket state and
// captures an audit row with the from/to status diff.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';

void main() {
  group('8.spine-bridge.C — Tab 2 tier change request approval transitions '
      'ticket state + writes audit row', () {
    test('resolveTierChangeRequest pending -> approved updates the row '
        'and writes admin.polling_tier_change_request.resolve', () async {
      const ref = OperatorLocationRef(
        operatorId: 'op-1',
        businessName: 'Demo Diner Co.',
        locationId: 'loc-1a',
        locationName: 'Toronto Yorkville',
      );
      final pending = TierChangeRequest(
        requestId: 'req-1',
        operatorRef: ref,
        currentTier: PollingTierKey.standard,
        requestedTier: PollingTierKey.premium,
        operatorNote: 'We want premium.',
        submittedAt: DateTime.utc(2026, 5, 4, 14, 30),
        status: TierChangeRequestStatus.pending,
      );
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[ref],
        initialChangeRequests: <TierChangeRequest>[pending],
      );

      // Sanity check: starts pending.
      var requests = await gateway.listTierChangeRequests();
      expect(requests, hasLength(1));
      expect(requests.single.status, equals(TierChangeRequestStatus.pending));

      // Approve.
      final resolved = await gateway.resolveTierChangeRequest(
        requestId: 'req-1',
        newStatus: TierChangeRequestStatus.approved,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'Approved per partnership review',
      );
      expect(resolved.status, equals(TierChangeRequestStatus.approved));

      // List reflects the change.
      requests = await gateway.listTierChangeRequests();
      expect(requests, hasLength(1));
      expect(requests.single.status, equals(TierChangeRequestStatus.approved));

      // Audit event captured.
      final resolves = gateway.capturedAuditEvents
          .where((e) =>
              e.eventType == 'admin.polling_tier_change_request.resolve')
          .toList();
      expect(resolves, hasLength(1));
      final statusDiff = resolves.single.diff['status']! as Map;
      expect(statusDiff['from'], equals('pending'));
      expect(statusDiff['to'], equals('approved'));
    });
  });
}
