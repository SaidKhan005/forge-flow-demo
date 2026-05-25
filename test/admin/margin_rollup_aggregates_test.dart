// Phase 8 spine-bridge Lane .C — acceptance item F.
//
// Tab 2 margin rollup aggregates across 5+ operators with mixed tiers.
// Direct gateway test (no widget) — assigns 5 mixed-tier assignments
// with explicit price + cost overrides, then asserts summarizeMargin
// returns the expected totals + per-tier rows. Also exercises the
// tierFilter parameter.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/admin/services/data_accuracy_admin_gateway.dart';
import 'package:forge_and_flow/domain/models/forge_flow_polling_tier_assignment.dart';

void main() {
  group('8.spine-bridge.C — Tab 2 margin rollup aggregates across 5+ '
      'operators with mixed tiers', () {
    test('summarizeMargin sums revenue/cost and returns 3 per-tier rows; '
        'tierFilter narrows to standard only', () async {
      const refs = <OperatorLocationRef>[
        OperatorLocationRef(
          operatorId: 'op-1',
          businessName: 'Diner A',
          locationId: 'loc-a',
          locationName: 'A1',
        ),
        OperatorLocationRef(
          operatorId: 'op-2',
          businessName: 'Diner B',
          locationId: 'loc-b',
          locationName: 'B1',
        ),
        OperatorLocationRef(
          operatorId: 'op-3',
          businessName: 'Diner C',
          locationId: 'loc-c',
          locationName: 'C1',
        ),
        OperatorLocationRef(
          operatorId: 'op-4',
          businessName: 'Diner D',
          locationId: 'loc-d',
          locationName: 'D1',
        ),
        OperatorLocationRef(
          operatorId: 'op-5',
          businessName: 'Diner E',
          locationId: 'loc-e',
          locationName: 'E1',
        ),
      ];
      final gateway = InMemoryDataAccuracyAdminGateway(
        operatorLocations: refs,
        initialTierDefinitions: <PollingTierKey, TierDefinition>{
          PollingTierKey.standard: kDemoStandardTierDefinition(),
          PollingTierKey.premium: kDemoPremiumTierDefinition(),
          PollingTierKey.custom: kDemoCustomTierDefinition(),
        },
      );

      // Assignments: 3 standard, 1 premium, 1 custom — explicit price + cost.
      final plan = <(int, PollingTierKey, int, int)>[
        (0, PollingTierKey.standard, 9900, 1200), // op-1
        (1, PollingTierKey.standard, 9900, 1200), // op-2
        (2, PollingTierKey.standard, 9900, 1200), // op-3
        (3, PollingTierKey.premium, 19900, 4800), // op-4
        (4, PollingTierKey.custom, 25000, 3000), // op-5
      ];
      for (final entry in plan) {
        final ref = refs[entry.$1];
        await gateway.assignTier(
          operatorId: ref.operatorId,
          locationId: ref.locationId,
          tierKey: entry.$2,
          monthlyPriceCentsOverride: entry.$3,
          vendorApiCostEstimateCentsMonthlyOverride: entry.$4,
          actorUserId: 'demo-super-admin',
          actorIsForgeAdmin: true,
        );
      }

      final rollup = await gateway.summarizeMargin();
      // Total revenue = 9900*3 + 19900 + 25000 = 29700 + 19900 + 25000 = 74600.
      expect(rollup.totalMonthlyPriceCents, equals(74600));
      // Total cost = 1200*3 + 4800 + 3000 = 3600 + 4800 + 3000 = 11400.
      expect(rollup.totalMonthlyVendorCostCents, equals(11400));
      // Margin = revenue - cost = 63200.
      expect(rollup.totalMonthlyMarginCents, equals(63200));
      // marginFraction = 63200 / 74600 ≈ 0.8472...
      expect(rollup.marginFraction, closeTo(63200 / 74600, 1e-9));

      // perTier has 3 entries.
      expect(rollup.perTier, hasLength(3));
      final perTierByKey = <PollingTierKey, TierMarginPerTier>{
        for (final pt in rollup.perTier) pt.tierKey: pt,
      };
      expect(perTierByKey[PollingTierKey.standard]!.assignmentCount, equals(3));
      expect(
        perTierByKey[PollingTierKey.standard]!.totalMonthlyPriceCents,
        equals(29700),
      );
      expect(perTierByKey[PollingTierKey.premium]!.assignmentCount, equals(1));
      expect(
        perTierByKey[PollingTierKey.premium]!.totalMonthlyPriceCents,
        equals(19900),
      );
      expect(perTierByKey[PollingTierKey.custom]!.assignmentCount, equals(1));
      expect(
        perTierByKey[PollingTierKey.custom]!.totalMonthlyPriceCents,
        equals(25000),
      );

      // Filter: tierFilter=standard returns only the 3 standard rows.
      final filtered = await gateway.summarizeMargin(
        tierFilter: PollingTierKey.standard,
      );
      expect(filtered.totalMonthlyPriceCents, equals(29700));
      expect(filtered.totalMonthlyVendorCostCents, equals(3600));
      expect(filtered.perTier, hasLength(1));
      expect(filtered.perTier.single.tierKey, equals(PollingTierKey.standard));
      expect(filtered.perTier.single.assignmentCount, equals(3));

      // Per-vendor allocation MUST sum exactly to total cost. The
      // rollup's floor + carry-the-remainder spread is the load-
      // bearing math; without this assertion a future refactor that
      // re-introduces `(cost / vendorIds.length).round()` would skew
      // the per-vendor breakdown vs the top-line metric.
      final perVendorSum = rollup.perVendor.fold<int>(
        0,
        (acc, entry) => acc + entry.totalMonthlyVendorCostCents,
      );
      expect(
        perVendorSum,
        equals(rollup.totalMonthlyVendorCostCents),
        reason:
            'per-vendor cost rollup must be lossless: '
            'sum(perVendor) == totalMonthlyVendorCostCents',
      );
    });

    test(
      'summarizeMargin uses tier vendor defaults when assignment cadence is empty',
      () async {
        const ref = OperatorLocationRef(
          operatorId: 'op-1',
          businessName: 'Diner A',
          locationId: 'loc-a',
          locationName: 'A1',
        );
        final now = DateTime.utc(2026, 5, 5, 12);
        final gateway = InMemoryDataAccuracyAdminGateway(
          operatorLocations: const <OperatorLocationRef>[ref],
          initialTierDefinitions: <PollingTierKey, TierDefinition>{
            PollingTierKey.standard: kDemoStandardTierDefinition(),
            PollingTierKey.premium: kDemoPremiumTierDefinition(),
            PollingTierKey.custom: kDemoCustomTierDefinition(),
          },
          initialAssignments: <String, ForgeFlowPollingTierAssignment>{
            'op-1/loc-a': ForgeFlowPollingTierAssignment(
              assignmentId: 'assignment-1',
              operatorId: 'op-1',
              locationId: 'loc-a',
              tierKey: PollingTierKey.standard,
              pollingCadencePerVendorSeconds: const <String, int>{},
              monthlyPriceCents: 9900,
              vendorApiCostEstimateCentsMonthly: 1200,
              effectiveAt: now,
              createdAt: now,
            ),
          },
        );

        final rollup = await gateway.summarizeMargin();
        final vendorIds = rollup.perVendor
            .map((entry) => entry.vendorId)
            .toSet();

        expect(vendorIds, contains('quickbooks_time'));
        expect(vendorIds, isNot(contains(kUnallocatedVendorId)));
        expect(
          rollup.perVendor.fold<int>(
            0,
            (acc, entry) => acc + entry.totalMonthlyVendorCostCents,
          ),
          equals(1200),
        );
      },
    );
  });
}
