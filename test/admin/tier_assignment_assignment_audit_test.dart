// Phase 8 spine-bridge Lane .C — acceptance item E.
//
// Tab 2 per-(operator, location) tier assignment closes prior + inserts
// new + writes audit row. Direct gateway test (no widget) — easier to
// assert state mutations + audit log shape.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';

void main() {
  group('8.spine-bridge.C — Tab 2 tier assignment closes prior + inserts new '
      '+ writes audit row', () {
    test('first assignTier inserts; second assignTier replaces + diffs '
        'tier_key from prior to next', () async {
      const ref = OperatorLocationRef(
        operatorId: 'op-1',
        businessName: 'Demo Diner Co.',
        locationId: 'loc-1a',
        locationName: 'Toronto Yorkville',
      );
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[ref],
        initialTierDefinitions: <PollingTierKey, TierDefinition>{
          PollingTierKey.standard: kDemoStandardTierDefinition(),
          PollingTierKey.premium: kDemoPremiumTierDefinition(),
          PollingTierKey.custom: kDemoCustomTierDefinition(),
        },
      );

      // listTierAssignments now returns every operator-location, so
      // the row exists before the first assignment with assignment ==
      // null. Assert that explicitly so a future regression that
      // hides un-assigned rows from the table fails this test.
      final preAssign = await gateway.listTierAssignments();
      expect(preAssign, hasLength(1));
      expect(preAssign.single.assignment, isNull);

      // First assignment -> standard.
      final firstRow = await gateway.assignTier(
        operatorId: 'op-1',
        locationId: 'loc-1a',
        tierKey: PollingTierKey.standard,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'initial assignment',
      );
      expect(firstRow.assignment, isNotNull);
      expect(firstRow.assignment!.tierKey, equals(PollingTierKey.standard));

      var assignments = await gateway.listTierAssignments();
      expect(assignments, hasLength(1));
      expect(assignments.single.assignment, isNotNull);
      expect(assignments.single.assignment!.tierKey,
          equals(PollingTierKey.standard));
      // Prior history is empty before any re-assignment.
      expect(gateway.assignmentHistoryForTesting, isEmpty);

      // Second assignment -> premium. The current map row replaces the
      // prior; the prior row archives into _assignmentHistory with
      // effectiveUntil stamped (mirrors production Postgres path).
      final secondRow = await gateway.assignTier(
        operatorId: 'op-1',
        locationId: 'loc-1a',
        tierKey: PollingTierKey.premium,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'tier upgrade',
      );
      expect(secondRow.assignment, isNotNull);
      expect(secondRow.assignment!.tierKey, equals(PollingTierKey.premium));

      assignments = await gateway.listTierAssignments();
      expect(assignments, hasLength(1));
      expect(assignments.single.assignment!.tierKey,
          equals(PollingTierKey.premium));

      // Prior assignment row preserved with effectiveUntil stamped.
      // Without this assertion the in-memory gateway could silently
      // drop history (the production Postgres repo uses
      // `update ... set effective_until = now()` to close the prior
      // row).
      final history = gateway.assignmentHistoryForTesting;
      expect(history, hasLength(1));
      expect(history.single.tierKey, equals(PollingTierKey.standard));
      expect(history.single.effectiveUntil, isNotNull);

      // Two audit events captured, both with admin.polling_tier_assignment.assign.
      final assigns = gateway.capturedAuditEvents
          .where((e) => e.eventType == 'admin.polling_tier_assignment.assign')
          .toList();
      expect(assigns, hasLength(2));
      // actor_kind is forge_admin on every Lane .C audit event.
      expect(assigns.every((e) => e.actorKind == 'forge_admin'), isTrue);

      // Second event's diff[tier_key].from == 'standard', .to == 'premium'.
      final secondEvent = assigns[1];
      final tierDiff = secondEvent.diff['tier_key']! as Map;
      expect(tierDiff['from'], equals('standard'));
      expect(tierDiff['to'], equals('premium'));
    });
  });
}
