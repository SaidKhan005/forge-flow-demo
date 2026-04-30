// Phase 11A.2 — Pricing tier admin gateway tests.
//
// Two coverage groups:
//
//   * `InMemoryPricingTierAdminGateway` — exercises the demo
//     gateway's command/response shapes and validation rules. The
//     screen widget tests run against this same gateway, so anything
//     it accepts must mirror the production validators in the proxy.
//
//   * `kPricingTierTemplates` — pins the locked tier-template catalog
//     so adding/removing a tier requires an explicit test edit.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/pricing_tier_admin_models.dart';
import 'package:forge_and_flow/admin/services/pricing_tier_admin_gateway.dart';

void main() {
  PricingOperatorBundle bundle({
    String operatorId = 'op-1',
    String tier = 'starter',
    String? primaryLocationId = 'loc-1',
    List<UsageCapRow> caps = const <UsageCapRow>[],
  }) {
    return PricingOperatorBundle(
      operatorId: operatorId,
      businessName: 'Cafe $operatorId',
      subscriptionTier: tier,
      preferredCurrency: 'USD',
      primaryLocationId: primaryLocationId,
      suspended: false,
      caps: caps,
    );
  }

  group('kPricingTierTemplates catalog', () {
    test('contains exactly the locked six tiers', () {
      expect(
        kPricingTierTemplates.map((t) => t.tierKey).toList(),
        equals(<String>[
          'pilot',
          'starter',
          'premium',
          'elite',
          'pro',
          'enterprise',
        ]),
      );
    });

    test('Pro template carries workflow allowances', () {
      final pro = findPricingTierTemplate('pro')!;
      final classes = pro.caps.map((c) => c.usageClass).toSet();
      expect(classes, contains('workflow_pl'));
      expect(classes, contains('workflow_schedule'));
    });

    test('Enterprise template has no caps (custom contract)', () {
      final enterprise = findPricingTierTemplate('enterprise')!;
      expect(enterprise.caps, isEmpty);
    });

    test('every key is a non-empty string', () {
      for (final t in kPricingTierTemplates) {
        expect(t.tierKey, isNotEmpty);
        expect(t.subscriptionTier, isNotEmpty);
        expect(t.displayName, isNotEmpty);
      }
    });
  });

  group('InMemoryPricingTierAdminGateway — listOperators', () {
    test('lists seeded operators alphabetically by business name',
        () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          bundle(operatorId: 'op-z'),
          bundle(operatorId: 'op-a'),
        ],
      );
      final list = await gateway.listOperators();
      expect(list.map((b) => b.operatorId).toList(),
          equals(<String>['op-a', 'op-z']));
    });
  });

  group('InMemoryPricingTierAdminGateway — updateOperatorTier', () {
    test('rewrites operators.subscription_tier', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle(tier: 'starter')],
      );
      final updated = await gateway.updateOperatorTier(
        const OperatorTierPatchCommand(
          operatorId: 'op-1',
          subscriptionTier: 'premium',
        ),
      );
      expect(updated.subscriptionTier, equals('premium'));
    });

    test('rejects an unknown subscription tier', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle()],
      );
      Object? thrown;
      try {
        await gateway.updateOperatorTier(
          const OperatorTierPatchCommand(
            operatorId: 'op-1',
            subscriptionTier: 'megapremium',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<PricingTierAdminGatewayError>());
      expect(
        (thrown! as PricingTierAdminGatewayError).errorCode,
        equals('unknown_subscription_tier'),
      );
    });

    test('returns a 404-style error for an unknown operator', () async {
      final gateway = InMemoryPricingTierAdminGateway();
      Object? thrown;
      try {
        await gateway.updateOperatorTier(
          const OperatorTierPatchCommand(
            operatorId: 'op-missing',
            subscriptionTier: 'pilot',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<PricingTierAdminGatewayError>());
      expect(
        (thrown! as PricingTierAdminGatewayError).statusCode,
        equals(404),
      );
    });
  });

  group('InMemoryPricingTierAdminGateway — upsertUsageCap', () {
    test('insert then update flips monthly_cap_usd', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle()],
      );

      final inserted = await gateway.upsertUsageCap(
        const UsageCapUpsertCommand(
          operatorId: 'op-1',
          locationId: 'loc-1',
          usageClass: 'advisor_qa',
          monthlyCapUsd: 50.0,
          perInvocationCapUsd: 0.10,
        ),
      );
      expect(inserted.monthlyCapUsd, equals(50.0));

      final updated = await gateway.upsertUsageCap(
        const UsageCapUpsertCommand(
          operatorId: 'op-1',
          locationId: 'loc-1',
          usageClass: 'advisor_qa',
          monthlyCapUsd: 100.0,
          perInvocationCapUsd: 0.10,
        ),
      );
      expect(updated.monthlyCapUsd, equals(100.0));

      final list = await gateway.listOperators();
      expect(list.single.caps, hasLength(1));
    });

    test('rejects negative caps', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle()],
      );
      Object? thrown;
      try {
        await gateway.upsertUsageCap(
          const UsageCapUpsertCommand(
            operatorId: 'op-1',
            locationId: 'loc-1',
            usageClass: 'advisor_qa',
            monthlyCapUsd: -5.0,
            perInvocationCapUsd: 0.10,
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<PricingTierAdminGatewayError>());
      expect(
        (thrown! as PricingTierAdminGatewayError).errorCode,
        equals('invalid_monthly_cap_usd'),
      );
    });

    test('rejects an empty usage_class', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle()],
      );
      Object? thrown;
      try {
        await gateway.upsertUsageCap(
          const UsageCapUpsertCommand(
            operatorId: 'op-1',
            locationId: 'loc-1',
            usageClass: '',
            monthlyCapUsd: 50.0,
            perInvocationCapUsd: 0.10,
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<PricingTierAdminGatewayError>());
      expect(
        (thrown! as PricingTierAdminGatewayError).errorCode,
        equals('missing_usage_class'),
      );
    });
  });

  group('InMemoryPricingTierAdminGateway — applyTierTemplate', () {
    test('Premium template seeds advisor_qa cap and switches tier',
        () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle(tier: 'starter')],
      );
      final updated = await gateway.applyTierTemplate(
        const ApplyTierTemplateCommand(
          operatorId: 'op-1',
          tierKey: 'premium',
        ),
      );
      expect(updated.subscriptionTier, equals('premium'));
      expect(updated.caps, hasLength(1));
      expect(updated.caps.single.usageClass, equals('advisor_qa'));
      expect(updated.caps.single.monthlyCapUsd, equals(200.0));
    });

    test('Pro template seeds workflow allowances', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle()],
      );
      final updated = await gateway.applyTierTemplate(
        const ApplyTierTemplateCommand(
          operatorId: 'op-1',
          tierKey: 'pro',
        ),
      );
      expect(updated.subscriptionTier, equals('pro'));
      final classes = updated.caps.map((c) => c.usageClass).toSet();
      expect(classes, contains('workflow_pl'));
      expect(classes, contains('workflow_schedule'));
    });

    test('Enterprise template flips tier without overwriting caps',
        () async {
      final cap = UsageCapRow(
        capId: 'cap-prior',
        operatorId: 'op-1',
        locationId: 'loc-1',
        usageClass: 'advisor_qa',
        monthlyCapUsd: 999.0,
        perInvocationCapUsd: 1.0,
        staffId: null,
        workflowId: null,
        createdBy: null,
        updatedBy: null,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          bundle(caps: <UsageCapRow>[cap]),
        ],
      );
      final updated = await gateway.applyTierTemplate(
        const ApplyTierTemplateCommand(
          operatorId: 'op-1',
          tierKey: 'enterprise',
        ),
      );
      expect(updated.subscriptionTier, equals('enterprise'));
      // Existing cap row is preserved (Enterprise template has no
      // caps, so nothing overwrites it).
      expect(updated.caps.single.monthlyCapUsd, equals(999.0));
    });

    test('rejects an unknown tier_key with a typed error', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle()],
      );
      Object? thrown;
      try {
        await gateway.applyTierTemplate(
          const ApplyTierTemplateCommand(
            operatorId: 'op-1',
            tierKey: 'megapremium',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<PricingTierAdminGatewayError>());
      expect(
        (thrown! as PricingTierAdminGatewayError).errorCode,
        equals('unknown_tier_template'),
      );
    });

    test('rejects when the operator has no primary_location_id',
        () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          bundle(primaryLocationId: null),
        ],
      );
      Object? thrown;
      try {
        await gateway.applyTierTemplate(
          const ApplyTierTemplateCommand(
            operatorId: 'op-1',
            tierKey: 'pilot',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<PricingTierAdminGatewayError>());
      expect(
        (thrown! as PricingTierAdminGatewayError).errorCode,
        equals('no_primary_location'),
      );
    });
  });
}
