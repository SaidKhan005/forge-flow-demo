import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/health_producers/audit_producers.dart';
import '../../../tool/advisor_proxy/health_producers/health_producer.dart';

import '_test_helpers.dart';

void main() {
  group('audit_producers — happy paths', () {
    test('audit_chain_lag_seconds yellow at 30m, red at 6h', () async {
      final yellow = await auditChainLagSecondsProducer(
        contextWith(runnerWith('audit_chain_anchors', <Map<String, Object?>>[
          {'lag': 1900},
        ])),
      );
      expect(yellow.status, equals('yellow'));
      final red = await auditChainLagSecondsProducer(
        contextWith(runnerWith('audit_chain_anchors', <Map<String, Object?>>[
          {'lag': 30000},
        ])),
      );
      expect(red.status, equals('red'));
      final green = await auditChainLagSecondsProducer(
        contextWith(runnerWith('audit_chain_anchors', <Map<String, Object?>>[
          {'lag': 60},
        ])),
      );
      expect(green.status, equals('green'));
    });

    test('audit_chain_lag_seconds red when no anchor exists', () async {
      final metric = await auditChainLagSecondsProducer(
        contextWith(runnerWith('audit_chain_anchors', <Map<String, Object?>>[
          {'lag': null},
        ])),
      );
      expect(metric.status, equals('red'));
      expect(metric.metadata['warning'], equals('no_anchor_recorded'));
    });

    test(
      'audit_chain_anchor_age_seconds: green when fresh, yellow at 24h, red at 48h',
      () async {
        final green = await auditChainAnchorAgeSecondsProducer(
          contextWith(runnerWith('audit_chain_anchors', <Map<String, Object?>>[
            {'age': 100},
          ])),
        );
        expect(green.status, equals('green'));
        final yellow = await auditChainAnchorAgeSecondsProducer(
          contextWith(runnerWith('audit_chain_anchors', <Map<String, Object?>>[
            {'age': 90000},
          ])),
        );
        expect(yellow.status, equals('yellow'));
        final red = await auditChainAnchorAgeSecondsProducer(
          contextWith(runnerWith('audit_chain_anchors', <Map<String, Object?>>[
            {'age': 200000},
          ])),
        );
        expect(red.status, equals('red'));
      },
    );

    test('migration_apply_drift_count: green at 0, red at 1+', () async {
      final producer = migrationApplyDriftCountProducerFor(<String>['a.sql']);
      final green = await producer(
        contextWith(runnerWith(
          'proxy_migration_apply_drift',
          <Map<String, Object?>>[
            {'cnt': 0, 'missing': const <String>[]},
          ],
        )),
      );
      expect(green.status, equals('green'));
      final red = await producer(
        contextWith(runnerWith(
          'proxy_migration_apply_drift',
          <Map<String, Object?>>[
            {'cnt': 1, 'missing': const <String>['a.sql']},
          ],
        )),
      );
      expect(red.status, equals('red'));
      expect(red.metadata['tier'], equals(1));
    });

    test('migration_apply_drift_count default entry is unknown', () async {
      // The catalog default has no expected list and must project to
      // unknown so the Tier-1 signal fails loud instead of silent green.
      final metric = await migrationApplyDriftCountProducer(
        contextWith(FakeProxyHealthQueryRunner()),
      );
      expect(metric.status, equals('unknown'));
      expect(
        metric.metadata['warning'],
        equals('expected_filenames_not_provided'),
      );
    });

    test(
      'firebase_jwks_fetch_alive green when alive and fresh, red otherwise',
      () async {
        final green = await firebaseJwksFetchAliveProducer(
          contextWith(runnerWith(
            'firebase_jwks_cache_status',
            <Map<String, Object?>>[
              {'alive': true, 'age_seconds': 60},
            ],
          )),
        );
        expect(green.status, equals('green'));
        final red = await firebaseJwksFetchAliveProducer(
          contextWith(runnerWith(
            'firebase_jwks_cache_status',
            <Map<String, Object?>>[
              {'alive': false, 'age_seconds': 99999},
            ],
          )),
        );
        expect(red.status, equals('red'));
      },
    );

    test(
      'service_principal_jwt_alive: green when signer loaded and verifies',
      () async {
        final green = await servicePrincipalJwtAliveProducer(
          contextWith(runnerWith(
            'service_principals_signer_status',
            <Map<String, Object?>>[
              {'signer_loaded': true, 'recent_verify_ok': true},
            ],
          )),
        );
        expect(green.status, equals('green'));
        final red = await servicePrincipalJwtAliveProducer(
          contextWith(runnerWith(
            'service_principals_signer_status',
            <Map<String, Object?>>[
              {'signer_loaded': true, 'recent_verify_ok': false},
            ],
          )),
        );
        expect(red.status, equals('red'));
      },
    );
  });

  group('audit_producers — error projections', () {
    test('producer_timeout projection on slow runner', () async {
      final slow = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'audit_chain_anchors': <Map<String, Object?>>[
            {'lag': 100},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await auditChainLagSecondsProducer(
        contextWith(slow, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
    });

    test('producer_error projection when runner throws', () async {
      final boom = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'firebase_jwks_cache_status': StateError('boom'),
        },
      );
      final metric = await firebaseJwksFetchAliveProducer(contextWith(boom));
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });
}
