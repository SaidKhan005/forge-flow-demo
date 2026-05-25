import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_service_period_setting.dart';
import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';

void main() {
  group('DataAccuracyAdminGateway operator-web parity foundation', () {
    const ref = OperatorLocationRef(
      operatorId: 'op-1',
      businessName: 'Demo Diner Co.',
      locationId: 'loc-1',
      locationName: 'Downtown',
    );

    InMemoryDataAccuracyAdminGateway buildGateway() {
      return InMemoryDataAccuracyAdminGateway(
        operatorLocations: const <OperatorLocationRef>[ref],
        initialAssignments: <String, ForgeFlowPollingTierAssignment>{
          'op-1/loc-1': ForgeFlowPollingTierAssignment(
            assignmentId: 'assignment-1',
            operatorId: 'op-1',
            locationId: 'loc-1',
            tierKey: PollingTierKey.premium,
            pollingCadencePerVendorSeconds: const <String, int>{
              'quickbooks_time': 60,
            },
            monthlyPriceCents: 19900,
            vendorApiCostEstimateCentsMonthly: 4800,
            effectiveAt: DateTime.utc(2026, 5, 1),
            createdAt: DateTime.utc(2026, 5, 1),
            assignedByAdminUserId: 'admin-1',
          ),
        },
        clock: () => DateTime.utc(2026, 6, 1, 12),
      );
    }

    test(
      'loads one row, saves full settings, manual covers, reset, and tier',
      () async {
        final gateway = buildGateway();

        final selected = await gateway.loadDataAccuracyRow(
          operatorId: 'op-1',
          locationId: 'loc-1',
        );
        expect(selected, isNotNull);
        expect(selected!.operatorRef.locationName, 'Downtown');

        final saved = await gateway.saveSettings(
          settings: DataAccuracySettings(
            settingId: 'setting-1',
            operatorId: 'op-1',
            locationId: 'loc-1',
            coversSourcePerServicePeriod: const <String, CoversSource>{
              'breakfast': CoversSource.manual,
              'dinner': CoversSource.forecast,
            },
            coversManualEntries: const <String, Map<String, int>>{
              '2026-06-02': <String, int>{'lunch': 12},
            },
            wageSource: WageSource.manualMix,
            walkInHandlingMode:
                DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately,
            walkInManualEntries: const <String, int>{'2026-06-02|breakfast': 7},
            createdAt: DateTime.utc(2026, 6, 1),
            updatedAt: DateTime.utc(2026, 6, 1),
          ),
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          reasonNote: 'Parity foundation save',
        );

        expect(saved.coversSourceFor('breakfast'), CoversSource.manual);
        expect(saved.coversSourceFor('dinner'), CoversSource.forecast);
        expect(saved.manualCoversFor('2026-06-02', 'lunch'), 12);
        expect(saved.wageSource, WageSource.manualMix);
        expect(
          saved.walkInHandlingMode,
          DataAccuracyWalkInHandlingMode.walkInsTrackedSeparately,
        );
        expect(
          saved.walkInCountFor('2026-06-02', servicePeriodId: 'breakfast'),
          7,
        );

        final afterManualSave = await gateway.saveManualCovers(
          const DataAccuracyManualCoversSaveCommand(
            target: DataAccuracyManualCoversTarget(
              operatorId: 'op-1',
              locationId: 'loc-1',
              businessDateIso: '2026-06-02',
              servicePeriodKey: 'dinner',
            ),
            covers: 44,
            actorUserId: 'admin-1',
            actorIsForgeAdmin: true,
            reasonNote: 'Set dinner covers',
          ),
        );
        expect(afterManualSave.manualCoversFor('2026-06-02', 'lunch'), 12);
        expect(afterManualSave.manualCoversFor('2026-06-02', 'dinner'), 44);

        final afterManualClear = await gateway.clearManualCovers(
          operatorId: 'op-1',
          locationId: 'loc-1',
          businessDateIso: '2026-06-02',
          servicePeriodKey: 'lunch',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          reasonNote: 'Clear lunch covers',
        );
        expect(afterManualClear.manualCoversFor('2026-06-02', 'lunch'), isNull);
        expect(afterManualClear.manualCoversFor('2026-06-02', 'dinner'), 44);

        await gateway.overrideDataAccuracyServicePeriod(
          operatorId: 'op-1',
          locationId: 'loc-1',
          servicePeriodKey: 'breakfast',
          coversSource: ServicePeriodCoversSource.reservationPlusWalkin,
          wageSource: ServicePeriodWageSource.targetSubstitution,
          effectiveAtBusinessDateIso: '2026-06-03',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          reasonNote: 'Temporary breakfast override',
        );
        expect(
          (await gateway.loadSettings(
            operatorId: 'op-1',
            locationId: 'loc-1',
          ))!.coversSourceFor('breakfast'),
          CoversSource.reservationPlusWalkin,
        );

        await gateway.resetServicePeriodSetting(
          operatorId: 'op-1',
          locationId: 'loc-1',
          servicePeriodKey: 'breakfast',
          actorUserId: 'admin-1',
          actorIsForgeAdmin: true,
          reasonNote: 'Reset breakfast override',
        );
        expect(
          (await gateway.loadSettings(
            operatorId: 'op-1',
            locationId: 'loc-1',
          ))!.coversSourceFor('breakfast'),
          CoversSource.vendor,
        );

        final tier = await gateway.loadPollingTierAssignment(
          operatorId: 'op-1',
          locationId: 'loc-1',
        );
        expect(tier, isNotNull);
        expect(tier!.tierKey, PollingTierKey.premium);
        expect(tier.pollingCadencePerVendorSeconds['quickbooks_time'], 60);

        expect(
          gateway.capturedAuditEvents.map((event) => event.eventType),
          containsAll(<String>[
            'admin.data_accuracy.settings.save',
            'admin.data_accuracy.manual_covers.save',
            'admin.data_accuracy.manual_covers.clear',
            'admin.data_accuracy.service_period_clear',
          ]),
        );
      },
    );
  });
}
