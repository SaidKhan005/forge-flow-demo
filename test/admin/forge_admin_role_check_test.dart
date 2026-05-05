// Phase 8 spine-bridge Lane .C — acceptance item H.
//
// forge_admin role check across all writes. Each writeable gateway
// method throws DataAccuracyAdminForbiddenException when invoked with
// actorIsForgeAdmin: false. The five successful (true) calls each
// succeed without throwing.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';

InMemoryDataAccuracyAdminGateway _seededGateway() {
  const ref = OperatorLocationRef(
    operatorId: 'op-1',
    businessName: 'Demo Diner Co.',
    locationId: 'loc-1a',
    locationName: 'Toronto Yorkville',
  );
  return InMemoryDataAccuracyAdminGateway(
    operatorLocations: const <OperatorLocationRef>[ref],
    initialTierDefinitions: <PollingTierKey, TierDefinition>{
      PollingTierKey.standard: kDemoStandardTierDefinition(),
      PollingTierKey.premium: kDemoPremiumTierDefinition(),
      PollingTierKey.custom: kDemoCustomTierDefinition(),
    },
    initialChangeRequests: <TierChangeRequest>[
      TierChangeRequest(
        requestId: 'req-1',
        operatorRef: ref,
        currentTier: PollingTierKey.standard,
        requestedTier: PollingTierKey.premium,
        operatorNote: 'demo',
        submittedAt: DateTime.utc(2026, 5, 4, 14, 30),
        status: TierChangeRequestStatus.pending,
      ),
    ],
  );
}

void main() {
  group('8.spine-bridge.C — forge_admin role check across all writes', () {
    test('overrideDataAccuracy(actorIsForgeAdmin: false) throws', () async {
      final gateway = _seededGateway();
      expect(
        () => gateway.overrideDataAccuracy(
          operatorId: 'op-1',
          locationId: 'loc-1a',
          actorUserId: 'support@forgeflow.test',
          actorIsForgeAdmin: false,
        ),
        throwsA(isA<DataAccuracyAdminForbiddenException>()),
      );
    });

    test('updateTierDefinition(actorIsForgeAdmin: false) throws', () async {
      final gateway = _seededGateway();
      expect(
        () => gateway.updateTierDefinition(
          tierKey: PollingTierKey.standard,
          descriptionMd: 'denied',
          actorUserId: 'support@forgeflow.test',
          actorIsForgeAdmin: false,
        ),
        throwsA(isA<DataAccuracyAdminForbiddenException>()),
      );
    });

    test('assignTier(actorIsForgeAdmin: false) throws', () async {
      final gateway = _seededGateway();
      expect(
        () => gateway.assignTier(
          operatorId: 'op-1',
          locationId: 'loc-1a',
          tierKey: PollingTierKey.standard,
          actorUserId: 'support@forgeflow.test',
          actorIsForgeAdmin: false,
        ),
        throwsA(isA<DataAccuracyAdminForbiddenException>()),
      );
    });

    test('resolveTierChangeRequest(actorIsForgeAdmin: false) throws',
        () async {
      final gateway = _seededGateway();
      expect(
        () => gateway.resolveTierChangeRequest(
          requestId: 'req-1',
          newStatus: TierChangeRequestStatus.approved,
          actorUserId: 'support@forgeflow.test',
          actorIsForgeAdmin: false,
        ),
        throwsA(isA<DataAccuracyAdminForbiddenException>()),
      );
    });

    test('exportMarginRollupCsv(actorIsForgeAdmin: false) throws', () async {
      final gateway = _seededGateway();
      expect(
        () => gateway.exportMarginRollupCsv(
          actorUserId: 'support@forgeflow.test',
          actorIsForgeAdmin: false,
        ),
        throwsA(isA<DataAccuracyAdminForbiddenException>()),
      );
    });

    test('all 5 writes succeed when actorIsForgeAdmin: true', () async {
      final gateway = _seededGateway();
      // overrideDataAccuracy
      await gateway.overrideDataAccuracy(
        operatorId: 'op-1',
        locationId: 'loc-1a',
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'forge admin allowed',
      );
      // updateTierDefinition
      await gateway.updateTierDefinition(
        tierKey: PollingTierKey.standard,
        descriptionMd: 'forge admin allowed',
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'forge admin allowed',
      );
      // assignTier
      await gateway.assignTier(
        operatorId: 'op-1',
        locationId: 'loc-1a',
        tierKey: PollingTierKey.standard,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'forge admin allowed',
      );
      // resolveTierChangeRequest
      await gateway.resolveTierChangeRequest(
        requestId: 'req-1',
        newStatus: TierChangeRequestStatus.approved,
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
        reasonNote: 'forge admin allowed',
      );
      // exportMarginRollupCsv
      final csv = await gateway.exportMarginRollupCsv(
        actorUserId: 'demo-super-admin',
        actorIsForgeAdmin: true,
      );
      expect(csv, isNotEmpty);
    });
  });
}
