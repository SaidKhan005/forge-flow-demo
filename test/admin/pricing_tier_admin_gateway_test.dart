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

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/pricing_tier_admin_models.dart';
import 'package:forge_and_flow/admin/services/pricing_tier_admin_gateway.dart';
import 'package:http/http.dart' as http;

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
          idempotencyKey: 'k-tier-premium',
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
            idempotencyKey: 'k-tier-bad',
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
            idempotencyKey: 'k-tier-missing',
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
          idempotencyKey: 'k-cap-insert',
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
          idempotencyKey: 'k-cap-update',
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
            idempotencyKey: 'k-cap-negative',
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
            idempotencyKey: 'k-cap-empty-class',
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

  group('InMemoryPricingTierAdminGateway — deleteUsageCap (Phase 2)', () {
    UsageCapRow capRow({
      String capId = 'cap-1',
      String usageClass = 'advisor_qa',
    }) {
      final created = DateTime.utc(2026, 4, 1);
      return UsageCapRow(
        capId: capId,
        operatorId: 'op-1',
        locationId: 'loc-1',
        usageClass: usageClass,
        monthlyCapUsd: 50.0,
        perInvocationCapUsd: 0.10,
        staffId: null,
        workflowId: null,
        createdBy: null,
        updatedBy: null,
        createdAt: created,
        updatedAt: created,
      );
    }

    test('removes the matching cap by logical key', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          bundle(caps: <UsageCapRow>[capRow()]),
        ],
      );
      await gateway.deleteUsageCap(
        const UsageCapDeleteCommand(
          operatorId: 'op-1',
          locationId: 'loc-1',
          usageClass: 'advisor_qa',
          idempotencyKey: 'k-del-1',
        ),
      );
      final list = await gateway.listOperators();
      expect(list.single.caps, isEmpty);
    });

    test('removes by cap_id when supplied', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          bundle(
            caps: <UsageCapRow>[
              capRow(capId: 'cap-keep', usageClass: 'advisor_qa'),
              capRow(capId: 'cap-drop', usageClass: 'coach_qa'),
            ],
          ),
        ],
      );
      await gateway.deleteUsageCap(
        const UsageCapDeleteCommand(
          operatorId: 'op-1',
          locationId: 'loc-1',
          usageClass: 'coach_qa',
          capId: 'cap-drop',
          idempotencyKey: 'k-del-capid',
        ),
      );
      final list = await gateway.listOperators();
      expect(list.single.caps, hasLength(1));
      expect(list.single.caps.single.capId, equals('cap-keep'));
    });

    test('404-style error when no matching cap exists', () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle()],
      );
      Object? thrown;
      try {
        await gateway.deleteUsageCap(
          const UsageCapDeleteCommand(
            operatorId: 'op-1',
            locationId: 'loc-1',
            usageClass: 'advisor_qa',
            idempotencyKey: 'k-del-missing',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<PricingTierAdminGatewayError>());
      expect(
        (thrown! as PricingTierAdminGatewayError).errorCode,
        equals('unknown_usage_cap'),
      );
    });

    test('replayed delete under the same key is a no-op (idempotent)',
        () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[
          bundle(caps: <UsageCapRow>[capRow()]),
        ],
      );
      const command = UsageCapDeleteCommand(
        operatorId: 'op-1',
        locationId: 'loc-1',
        usageClass: 'advisor_qa',
        idempotencyKey: 'k-del-replay',
      );
      await gateway.deleteUsageCap(command);
      // Second call with the same key must NOT throw 404 even though the
      // row is already gone (mirrors the proxy's idempotent replay).
      await gateway.deleteUsageCap(command);
      final list = await gateway.listOperators();
      expect(list.single.caps, isEmpty);
    });

    test('fetchSpendSummary returns an empty summary in demo (fallback path)',
        () async {
      final gateway = InMemoryPricingTierAdminGateway(
        seed: <PricingOperatorBundle>[bundle()],
      );
      final summary = await gateway.fetchSpendSummary('op-1');
      expect(summary.byLocationAndClass, isEmpty);
      expect(summary.spendFor('loc-1', 'advisor_qa'), isNull);
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
          idempotencyKey: 'k-tmpl-premium',
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
          idempotencyKey: 'k-tmpl-pro',
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
          idempotencyKey: 'k-tmpl-enterprise',
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
            idempotencyKey: 'k-tmpl-bad',
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
            idempotencyKey: 'k-tmpl-no-primary',
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

  // HARD-H — admin idempotency parcel. The InMemory gateway caches
  // per-key like the proxy does against `admin_request_idempotency`.
  group('InMemoryPricingTierAdminGateway — idempotency replay', () {
    test(
      'second updateOperatorTier with same key returns cached bundle',
      () async {
        final gateway = InMemoryPricingTierAdminGateway(
          seed: <PricingOperatorBundle>[bundle(tier: 'starter')],
        );
        final command = const OperatorTierPatchCommand(
          operatorId: 'op-1',
          subscriptionTier: 'premium',
          idempotencyKey: 'idem-tier',
        );
        final first = await gateway.updateOperatorTier(command);
        final second = await gateway.updateOperatorTier(command);
        expect(second.subscriptionTier, equals(first.subscriptionTier));
      },
    );

    test(
      'second upsertUsageCap with same key returns cached row '
      '(no second mutation)',
      () async {
        final gateway = InMemoryPricingTierAdminGateway(
          seed: <PricingOperatorBundle>[bundle()],
          actorUserId: 'actor-x',
        );
        final first = await gateway.upsertUsageCap(
          const UsageCapUpsertCommand(
            operatorId: 'op-1',
            locationId: 'loc-1',
            usageClass: 'advisor_qa',
            monthlyCapUsd: 50.0,
            perInvocationCapUsd: 0.10,
            idempotencyKey: 'idem-cap',
          ),
        );
        // Replay with a DIFFERENT cap value under the same key — the
        // cached result wins (matches the proxy's
        // `idempotency_payload_mismatch` envelope by ignoring the
        // mutation).
        final second = await gateway.upsertUsageCap(
          const UsageCapUpsertCommand(
            operatorId: 'op-1',
            locationId: 'loc-1',
            usageClass: 'advisor_qa',
            monthlyCapUsd: 999.0,
            perInvocationCapUsd: 0.99,
            idempotencyKey: 'idem-cap',
          ),
        );
        expect(second.monthlyCapUsd, equals(first.monthlyCapUsd));
        expect(second.monthlyCapUsd, equals(50.0));
      },
    );

    test(
      'second applyTierTemplate with same key returns cached bundle',
      () async {
        final gateway = InMemoryPricingTierAdminGateway(
          seed: <PricingOperatorBundle>[bundle()],
        );
        final command = const ApplyTierTemplateCommand(
          operatorId: 'op-1',
          tierKey: 'premium',
          idempotencyKey: 'idem-apply',
        );
        final first = await gateway.applyTierTemplate(command);
        final second = await gateway.applyTierTemplate(command);
        expect(second.subscriptionTier, equals(first.subscriptionTier));
        expect(second.caps, hasLength(first.caps.length));
      },
    );
  });

  // HARD-H — Http variant attaches the Idempotency-Key header on
  // mutating commands.
  group('HttpPricingTierAdminGateway — Idempotency-Key wiring', () {
    test(
      'upsertUsageCap PUTs with Idempotency-Key header and JSON body '
      'WITHOUT the key inside',
      () async {
        final captured = <_CapturedAdminRequest>[];
        final client = _SingleResponseClient(
          captured: captured,
          response: _HttpFixture(
            statusCode: 200,
            body: <String, Object?>{
              'cap': <String, Object?>{
                'cap_id': 'cap-x',
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'advisor_qa',
                'monthly_cap_usd': 50.0,
                'per_invocation_cap_usd': 0.10,
                'staff_id': null,
                'workflow_id': null,
                'created_by': null,
                'updated_by': null,
                'created_at': '2026-05-02T12:00:00.000Z',
                'updated_at': '2026-05-02T12:00:00.000Z',
              },
            },
          ),
        );
        final gateway = HttpPricingTierAdminGateway(
          baseUri: Uri.parse('https://proxy.example.com'),
          bearerTokenProvider: () async => 'fake.token',
          httpClient: client,
        );
        await gateway.upsertUsageCap(
          const UsageCapUpsertCommand(
            operatorId: 'op-1',
            locationId: 'loc-1',
            usageClass: 'advisor_qa',
            monthlyCapUsd: 50.0,
            perInvocationCapUsd: 0.10,
            idempotencyKey: 'idem-http-cap',
          ),
        );
        final req = captured.single;
        expect(req.method, equals('PUT'));
        expect(req.uri.path, equals('/v1/admin/pricing/usage-caps'));
        expect(
          req.headers['idempotency-key'] ?? req.headers['Idempotency-Key'],
          equals('idem-http-cap'),
        );
        expect(req.body.containsKey('idempotency_key'), isFalse);
      },
    );

    test(
      'applyTierTemplate POSTs with Idempotency-Key header',
      () async {
        final captured = <_CapturedAdminRequest>[];
        final client = _SingleResponseClient(
          captured: captured,
          response: _HttpFixture(
            statusCode: 200,
            body: <String, Object?>{
              'operator': <String, Object?>{
                'operator_id': 'op-1',
                'business_name': 'Cafe',
                'subscription_tier': 'premium',
                'preferred_currency': 'USD',
                'primary_location_id': 'loc-1',
              },
              'caps': <Map<String, Object?>>[],
            },
          ),
        );
        final gateway = HttpPricingTierAdminGateway(
          baseUri: Uri.parse('https://proxy.example.com'),
          bearerTokenProvider: () async => 'fake.token',
          httpClient: client,
        );
        await gateway.applyTierTemplate(
          const ApplyTierTemplateCommand(
            operatorId: 'op-1',
            tierKey: 'premium',
            idempotencyKey: 'idem-http-apply',
          ),
        );
        final req = captured.single;
        expect(req.method, equals('POST'));
        expect(
          req.uri.path,
          equals('/v1/admin/pricing/operators/op-1/apply-template'),
        );
        expect(
          req.headers['idempotency-key'] ?? req.headers['Idempotency-Key'],
          equals('idem-http-apply'),
        );
      },
    );

    test(
      'deleteUsageCap DELETEs with Idempotency-Key header and logical-key '
      'body',
      () async {
        final captured = <_CapturedAdminRequest>[];
        final client = _SingleResponseClient(
          captured: captured,
          response: _HttpFixture(
            statusCode: 200,
            body: <String, Object?>{'deleted': true},
          ),
        );
        final gateway = HttpPricingTierAdminGateway(
          baseUri: Uri.parse('https://proxy.example.com'),
          bearerTokenProvider: () async => 'fake.token',
          httpClient: client,
        );
        await gateway.deleteUsageCap(
          const UsageCapDeleteCommand(
            operatorId: 'op-1',
            locationId: 'loc-1',
            usageClass: 'advisor_qa',
            idempotencyKey: 'idem-http-del',
          ),
        );
        final req = captured.single;
        expect(req.method, equals('DELETE'));
        expect(req.uri.path, equals('/v1/admin/pricing/usage-caps'));
        expect(
          req.headers['idempotency-key'] ?? req.headers['Idempotency-Key'],
          equals('idem-http-del'),
        );
        expect(req.body['operator_id'], equals('op-1'));
        expect(req.body['usage_class'], equals('advisor_qa'));
        expect(req.body.containsKey('idempotency_key'), isFalse);
      },
    );

    test(
      'fetchSpendSummary GETs the spend-summary path and parses the rows',
      () async {
        final captured = <_CapturedAdminRequest>[];
        final client = _SingleResponseClient(
          captured: captured,
          response: _HttpFixture(
            statusCode: 200,
            body: <String, Object?>{
              'operator_id': 'op-1',
              'spend': <Map<String, Object?>>[
                <String, Object?>{
                  'location_id': 'loc-1',
                  'usage_class': 'advisor_qa',
                  'spend_usd': 42.5,
                },
              ],
            },
          ),
        );
        final gateway = HttpPricingTierAdminGateway(
          baseUri: Uri.parse('https://proxy.example.com'),
          bearerTokenProvider: () async => 'fake.token',
          httpClient: client,
        );
        final summary = await gateway.fetchSpendSummary('op-1');
        final req = captured.single;
        expect(req.method, equals('GET'));
        expect(
          req.uri.path,
          equals('/v1/admin/pricing/operators/op-1/spend-summary'),
        );
        expect(summary.spendFor('loc-1', 'advisor_qa'), equals(42.5));
        expect(summary.spendFor('loc-1', 'coach_qa'), isNull);
      },
    );
  });
}

// ─── Test helpers ─────────────────────────────────────────────────

class _CapturedAdminRequest {
  _CapturedAdminRequest({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
  });
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}

class _HttpFixture {
  _HttpFixture({required this.statusCode, required this.body});
  final int statusCode;
  final Map<String, Object?> body;
}

class _SingleResponseClient extends http.BaseClient {
  _SingleResponseClient({required this.captured, required this.response});

  final List<_CapturedAdminRequest> captured;
  final _HttpFixture response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    Map<String, Object?> body = const <String, Object?>{};
    if (bodyBytes.isNotEmpty) {
      final decoded = jsonDecode(utf8.decode(bodyBytes));
      if (decoded is Map) body = decoded.cast<String, Object?>();
    }
    captured.add(
      _CapturedAdminRequest(
        method: request.method,
        uri: request.url,
        headers: Map<String, String>.from(request.headers),
        body: body,
      ),
    );
    final encoded = utf8.encode(jsonEncode(response.body));
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[encoded]),
      response.statusCode,
      contentLength: encoded.length,
      headers: const <String, String>{'content-type': 'application/json'},
    );
  }
}
