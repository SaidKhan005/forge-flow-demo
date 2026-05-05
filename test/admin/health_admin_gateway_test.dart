// Phase 11A.UX.health (F.1) - health admin gateway parsing tests.
//
// Drives the typed envelope parser (`HealthEnvelope.fromJson`) and
// the in-memory gateway variants. The intent is to lock the contract
// shape before the screen/widget tests start consuming it: severity
// promotion (tier-1 fail → red banner driver), 503 path
// (`dependenciesUnavailable: true`), and tile chip color routing.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/health_admin_models.dart';
import 'package:forge_and_flow/admin/services/health_admin_gateway.dart';

void main() {
  group('HealthEnvelope.fromJson', () {
    test('parses dependencies, surfaces, metrics from a green envelope', () {
      final envelope = HealthEnvelope.fromJson(_greenEnvelopeJson());

      expect(envelope.status, 'ok');
      expect(envelope.severity, HealthSeverity.green);
      expect(envelope.contract, 'proxy_health.v1');
      expect(envelope.schemaVersion, 1);
      expect(envelope.checkedAt?.isUtc, isTrue);
      expect(envelope.dependenciesUnavailable, isFalse);

      expect(envelope.dependencies.map((d) => d.name).toSet(), <String>{
        'postgres',
        'age',
        'pgvector',
      });
      for (final dep in envelope.dependencies) {
        expect(dep.status, HealthSeverity.green);
      }

      expect(envelope.metrics.containsKey('audit_chain_lag_seconds'), isTrue);
      final auditLag = envelope.metrics['audit_chain_lag_seconds']!;
      expect(auditLag.tier, 1);
      expect(auditLag.status, HealthSeverity.green);
      expect(auditLag.value, 12);

      expect(envelope.surfaces.containsKey('graph'), isTrue);
      expect(
        envelope.surfaces['graph']!.metricKeys,
        contains('graph_traversal_latency_ms'),
      );
    });

    test('hasTier1Failure flips when a tier-1 metric is yellow/red', () {
      final json = _greenEnvelopeJson();
      // Force a tier-1 metric to red.
      (json['metrics']!
              as Map<String, Object?>)['migration_apply_drift_count'] =
          <String, Object?>{
            'status': 'red',
            'value': 3,
            'unit': 'count',
            'description': 'forced',
            'owner': 'B42',
            'observed_at': '2026-05-02T00:00:00.000Z',
            'thresholds': <String, Object?>{'red': 1},
            'metadata': <String, Object?>{'tier': 1},
          };
      final envelope = HealthEnvelope.fromJson(json);
      expect(envelope.hasTier1Failure, isTrue);
    });

    test('hasTier2Failure flips when only a tier-2 metric is failing', () {
      final json = _greenEnvelopeJson();
      (json['metrics']! as Map<String, Object?>)['rollup_freshness_per_grain'] =
          <String, Object?>{
            'status': 'yellow',
            'value': 4218,
            'unit': 'seconds',
            'description': 'forced',
            'owner': 'B45',
            'observed_at': '2026-05-02T00:00:00.000Z',
            'thresholds': <String, Object?>{'yellow': 3600, 'red': 21600},
            'metadata': <String, Object?>{'tier': 2},
          };
      final envelope = HealthEnvelope.fromJson(json);
      expect(envelope.hasTier1Failure, isFalse);
      expect(envelope.hasTier2Failure, isTrue);
    });

    test('dependenciesUnavailable=true sets hasTier1Failure even if metrics '
        'are green', () {
      final envelope = HealthEnvelope.fromJson(
        _greenEnvelopeJson(),
        dependenciesUnavailable: true,
      );
      expect(envelope.dependenciesUnavailable, isTrue);
      expect(envelope.hasTier1Failure, isTrue);
    });

    test('parses missing/null fields without throwing', () {
      final envelope = HealthEnvelope.fromJson(<String, Object?>{
        'status': 'unknown',
        'metrics': <String, Object?>{
          'unstoppable_metric': <String, Object?>{
            'status': 'unknown',
            'value': null,
            // unit, owner, observed_at intentionally missing.
          },
        },
      });
      expect(envelope.metrics.length, 1);
      final metric = envelope.metrics['unstoppable_metric']!;
      expect(metric.status, HealthSeverity.unknown);
      expect(metric.tier, 3); // default tier when metadata absent
      expect(metric.displayValue, '-');
    });

    test('parseHealthSeverity defaults to unknown on bad input', () {
      expect(parseHealthSeverity('bogus'), HealthSeverity.unknown);
      expect(parseHealthSeverity(null), HealthSeverity.unknown);
      expect(parseHealthSeverity(42), HealthSeverity.unknown);
    });
  });

  group('InMemoryHealthAdminGateway', () {
    test(
      'returns the seeded envelope and respects setEnvelope updates',
      () async {
        final gateway = InMemoryHealthAdminGateway(
          envelope: _greenEnvelopeJson(),
        );
        final first = await gateway.fetch();
        expect(first.severity, HealthSeverity.green);

        gateway.setEnvelope(
          _greenEnvelopeJson(),
          dependenciesUnavailable: true,
        );
        final second = await gateway.fetch();
        expect(second.dependenciesUnavailable, isTrue);
        expect(second.hasTier1Failure, isTrue);
      },
    );

    test(
      'setEnvelope errorOnFetch surfaces the configured exception',
      () async {
        final gateway = InMemoryHealthAdminGateway(
          envelope: _greenEnvelopeJson(),
        );
        gateway.setEnvelope(
          _greenEnvelopeJson(),
          errorOnFetch: const HealthAdminGatewayError(
            statusCode: 500,
            message: 'forced',
          ),
        );
        await expectLater(
          gateway.fetch(),
          throwsA(isA<HealthAdminGatewayError>()),
        );
      },
    );
  });

  group('HealthMetric.thresholdCaption', () {
    test('renders threshold map as one-line caption', () {
      final metric = HealthMetric.fromJson(
        'graph_traversal_latency_ms',
        const <String, Object?>{
          'status': 'green',
          'value': 92,
          'unit': 'milliseconds',
          'description': 'p95 latency',
          'owner': 'B44',
          'thresholds': <String, Object?>{'yellow': 250, 'red': 500},
          'metadata': <String, Object?>{'tier': 2},
        },
      );
      expect(metric.thresholdCaption, 'yellow: 250 · red: 500');
    });

    test('returns null when thresholds are absent', () {
      final metric = HealthMetric.fromJson(
        'graph_node_count',
        const <String, Object?>{
          'status': 'green',
          'value': 1245,
          'unit': 'count',
          'description': 'count',
          'owner': 'B44',
          'metadata': <String, Object?>{'tier': 2},
        },
      );
      expect(metric.thresholdCaption, isNull);
    });
  });
}

/// Hand-rolled green envelope so the test does not couple to the
/// demo seed in the gateway file. Mirrors the shape contracted by
/// `docs/contracts/proxy_health_contract.md`.
Map<String, Object?> _greenEnvelopeJson() => <String, Object?>{
  'status': 'ok',
  'severity': 'green',
  'contract': 'proxy_health.v1',
  'schema_version': 1,
  'checked_at': '2026-05-02T00:00:00.000Z',
  'dependencies': <String, Object?>{
    'postgres': <String, Object?>{
      'status': 'green',
      'check': 'select_1',
      'legacy_key': 'postgres_select_1',
    },
    'age': <String, Object?>{
      'status': 'green',
      'check': 'cypher_match',
      'legacy_key': 'age_cypher_match',
    },
    'pgvector': <String, Object?>{
      'status': 'green',
      'check': 'similarity',
      'legacy_key': 'pgvector_similarity',
    },
  },
  'surfaces': <String, Object?>{
    'graph': <String, Object?>{
      'status': 'green',
      'metrics': <String>['graph_traversal_latency_ms'],
      'owner': 'B44',
    },
  },
  'metrics': <String, Object?>{
    'audit_chain_lag_seconds': <String, Object?>{
      'status': 'green',
      'value': 12,
      'unit': 'seconds',
      'description': 'audit lag',
      'owner': 'B37/B43',
      'observed_at': '2026-05-02T00:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 1800, 'red': 21600},
      'metadata': <String, Object?>{'tier': 1},
    },
    'graph_traversal_latency_ms': <String, Object?>{
      'status': 'green',
      'value': 92,
      'unit': 'milliseconds',
      'description': 'p95 latency',
      'owner': 'B44',
      'observed_at': '2026-05-02T00:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 250, 'red': 500},
      'metadata': <String, Object?>{'tier': 2, 'percentile': 'p95'},
    },
    'prompt_cache_hit_rate': <String, Object?>{
      'status': 'green',
      'value': 0.62,
      'unit': 'ratio',
      'description': 'cache hit',
      'owner': 'B42',
      'observed_at': '2026-05-02T00:00:00.000Z',
      'thresholds': <String, Object?>{'yellow': 0.30, 'red': 0.10},
      'metadata': <String, Object?>{'tier': 3},
    },
  },
  'warnings': <Object?>[],
};
