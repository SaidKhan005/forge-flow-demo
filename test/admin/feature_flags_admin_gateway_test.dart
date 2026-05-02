// Phase 11A.7 — Feature flags admin gateway tests.
//
// Coverage:
//
//   * `InMemoryFeatureFlagsAdminGateway.listFlags` — exercises the
//     ordering rule (destructive first, then alphabetical) so the
//     screen widget tests can rely on a stable position.
//
//   * `InMemoryFeatureFlagsAdminGateway.toggleFlag` — flips `enabled`,
//     updates `updated_by` from the actor, returns the post-toggle
//     row, and rejects unknown `flag_id` with a structured 404 error.
//
//   * Idempotency: replaying the same key returns the cached result
//     instead of toggling twice (mirrors the proxy `proxy_requests`
//     UNIQUE constraint).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/feature_flags_admin_models.dart';
import 'package:forge_and_flow/admin/services/feature_flags_admin_gateway.dart';

void main() {
  FeatureFlagAdminRow row({
    required String id,
    required String name,
    bool enabled = false,
    String kind = kFeatureFlagKindStandard,
    String? operatorId,
    String? locationId,
  }) {
    return FeatureFlagAdminRow(
      flagId: id,
      flagName: name,
      operatorId: operatorId,
      locationId: locationId,
      enabled: enabled,
      kind: kind,
      description: null,
      updatedBy: 'seed-actor',
      createdAt: DateTime.utc(2026, 5, 1, 10, 0),
      updatedAt: DateTime.utc(2026, 5, 1, 10, 0),
    );
  }

  group('FeatureFlagAdminRow', () {
    test('isDestructive flips on kind = destructive', () {
      expect(
        row(id: 'a', name: 'a', kind: kFeatureFlagKindDestructive)
            .isDestructive,
        isTrue,
      );
      expect(row(id: 'b', name: 'b').isDestructive, isFalse);
    });

    test('scopeLabel reads the (operator, location) shape', () {
      expect(row(id: 'g', name: 'g').scopeLabel, equals('global'));
      expect(
        row(id: 'o', name: 'o', operatorId: 'op-1').scopeLabel,
        equals('operator'),
      );
      expect(
        row(
          id: 'l',
          name: 'l',
          operatorId: 'op-1',
          locationId: 'loc-1',
        ).scopeLabel,
        equals('location'),
      );
    });
  });

  group('InMemoryFeatureFlagsAdminGateway.listFlags', () {
    test(
      'returns destructive flags first, alphabetical within each '
      'kind bucket',
      () async {
        final gateway = InMemoryFeatureFlagsAdminGateway(
          seed: <FeatureFlagAdminRow>[
            row(id: '1', name: 'b_standard'),
            row(id: '2', name: 'a_destructive', kind: kFeatureFlagKindDestructive),
            row(id: '3', name: 'a_standard'),
            row(id: '4', name: 'b_destructive', kind: kFeatureFlagKindDestructive),
          ],
        );
        final list = await gateway.listFlags();
        expect(
          list.map((r) => r.flagName).toList(),
          equals(<String>[
            'a_destructive',
            'b_destructive',
            'a_standard',
            'b_standard',
          ]),
        );
      },
    );
  });

  group('InMemoryFeatureFlagsAdminGateway.toggleFlag', () {
    test('flips enabled and updates updated_by/updated_at', () async {
      final clock = DateTime.utc(2026, 5, 2, 12, 0);
      final gateway = InMemoryFeatureFlagsAdminGateway(
        actorUserId: 'super-admin-uuid',
        now: () => clock,
        seed: <FeatureFlagAdminRow>[
          row(id: 'flag-1', name: 'advisor_enabled', enabled: false),
        ],
      );
      final updated = await gateway.toggleFlag(
        const FeatureFlagToggleCommand(
          flagId: 'flag-1',
          enabled: true,
          idempotencyKey: 'k-1',
        ),
      );
      expect(updated.enabled, isTrue);
      expect(updated.updatedBy, equals('super-admin-uuid'));
      expect(updated.updatedAt, equals(clock.toUtc()));
    });

    test('rejects unknown flag_id with 404 unknown_flag', () async {
      final gateway = InMemoryFeatureFlagsAdminGateway();
      Object? thrown;
      try {
        await gateway.toggleFlag(
          const FeatureFlagToggleCommand(
            flagId: 'flag-missing',
            enabled: true,
            idempotencyKey: 'k-missing',
          ),
        );
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isA<FeatureFlagsAdminGatewayError>());
      final err = thrown! as FeatureFlagsAdminGatewayError;
      expect(err.statusCode, equals(404));
      expect(err.errorCode, equals('unknown_flag'));
    });

    test(
      'idempotency-key replay returns the cached result without '
      're-toggling',
      () async {
        var tick = 0;
        final gateway = InMemoryFeatureFlagsAdminGateway(
          actorUserId: 'super-admin-uuid',
          now: () => DateTime.utc(2026, 5, 2, 12, tick++),
          seed: <FeatureFlagAdminRow>[
            row(id: 'flag-1', name: 'circuit_breaker_open', enabled: false),
          ],
        );
        final first = await gateway.toggleFlag(
          const FeatureFlagToggleCommand(
            flagId: 'flag-1',
            enabled: true,
            idempotencyKey: 'idem-replay',
          ),
        );
        // Second call with the same key — must NOT flip back to false
        // (which is what passing `enabled: false` would do without
        // idempotency caching).
        final second = await gateway.toggleFlag(
          const FeatureFlagToggleCommand(
            flagId: 'flag-1',
            enabled: false,
            idempotencyKey: 'idem-replay',
          ),
        );
        expect(first.enabled, isTrue);
        expect(second.enabled, isTrue);
        expect(second.updatedAt, equals(first.updatedAt));
      },
    );
  });
}
