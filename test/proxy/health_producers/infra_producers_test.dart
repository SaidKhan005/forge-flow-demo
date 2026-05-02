import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/health_producers/health_producer.dart';
import '../../../tool/advisor_proxy/health_producers/infra_producers.dart';

import '_test_helpers.dart';

void main() {
  group('infra_producers — happy paths', () {
    test('azure_extensions_present green when all required installed', () async {
      final runner = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'pg_extension': <Map<String, Object?>>[
            {'extname': 'age'},
            {'extname': 'vector'},
            {'extname': 'pg_diskann'},
            {'extname': 'pg_partman'},
            {'extname': 'pg_stat_statements'},
            {'extname': 'pgcrypto'},
          ],
        },
      );
      final metric = await azureExtensionsPresentProducer(contextWith(runner));
      expect(metric.status, equals('green'));
      expect(metric.value, equals(6));
      expect(metric.metadata['tier'], equals(1));
      expect(metric.metadata['required_count'], equals(6));
      expect(metric.metadata.containsKey('missing'), isFalse);
    });

    test('azure_extensions_present red when any required is missing', () async {
      final runner = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'pg_extension': <Map<String, Object?>>[
            {'extname': 'age'},
            {'extname': 'vector'},
          ],
        },
      );
      final metric = await azureExtensionsPresentProducer(contextWith(runner));
      expect(metric.status, equals('red'));
      expect(metric.value, equals(2));
      expect(metric.metadata['missing'], isA<List<dynamic>>());
    });

    test('partition_default_row_count yellow at 1, red at 1000', () async {
      final yellow = await partitionDefaultRowCountProducer(
        contextWith(runnerWith('usage_logs_default', <Map<String, Object?>>[
          {'cnt': 1},
        ])),
      );
      expect(yellow.status, equals('yellow'));
      final red = await partitionDefaultRowCountProducer(
        contextWith(runnerWith('usage_logs_default', <Map<String, Object?>>[
          {'cnt': 9999},
        ])),
      );
      expect(red.status, equals('red'));
      final green = await partitionDefaultRowCountProducer(
        contextWith(runnerWith('usage_logs_default', <Map<String, Object?>>[
          {'cnt': 0},
        ])),
      );
      expect(green.status, equals('green'));
    });

    test(
      'partition_maintenance_last_run_age_seconds yellow at 7200 / red at 14400',
      () async {
        final tsYellow = fixedNow().subtract(const Duration(hours: 3));
        final yellow = await partitionMaintenanceLastRunAgeSecondsProducer(
          contextWith(runnerWith('cron.job_run_details', <Map<String, Object?>>[
            {'last_end': tsYellow.toIso8601String()},
          ])),
        );
        expect(yellow.status, equals('yellow'));
        final tsRed = fixedNow().subtract(const Duration(hours: 5));
        final red = await partitionMaintenanceLastRunAgeSecondsProducer(
          contextWith(runnerWith('cron.job_run_details', <Map<String, Object?>>[
            {'last_end': tsRed.toIso8601String()},
          ])),
        );
        expect(red.status, equals('red'));
        final tsGreen = fixedNow().subtract(const Duration(minutes: 30));
        final green = await partitionMaintenanceLastRunAgeSecondsProducer(
          contextWith(runnerWith('cron.job_run_details', <Map<String, Object?>>[
            {'last_end': tsGreen.toIso8601String()},
          ])),
        );
        expect(green.status, equals('green'));
      },
    );

    test('pg_cron_scheduler_alive returns green when last run < 5 min', () async {
      final ts = fixedNow().subtract(const Duration(minutes: 1));
      final metric = await pgCronSchedulerAliveProducer(
        contextWith(runnerWith('cron.job_run_details', <Map<String, Object?>>[
          {'last_end': ts.toIso8601String()},
        ])),
      );
      expect(metric.status, equals('green'));
      expect(metric.value, isTrue);
    });

    test('pg_cron_jobs_failed_24h yellow at 1, red at 5', () async {
      final yellow = await pgCronJobsFailed24hProducer(
        contextWith(runnerWith('cron.job_run_details', <Map<String, Object?>>[
          {'cnt': 2},
        ])),
      );
      expect(yellow.status, equals('yellow'));
      final red = await pgCronJobsFailed24hProducer(
        contextWith(runnerWith('cron.job_run_details', <Map<String, Object?>>[
          {'cnt': 99},
        ])),
      );
      expect(red.status, equals('red'));
    });

    test('cloud_run_instance_count emits unknown when no metrics row', () async {
      final metric = await cloudRunInstanceCountProducer(
        contextWith(
          runnerWith('cloud_run_instance_metrics', const <Map<String, Object?>>[]),
        ),
      );
      expect(metric.status, equals('unknown'));
      expect(metric.metadata['warning'], equals('no_metrics_recorded'));
    });
  });

  group('infra_producers — error / timeout projections', () {
    test('producer_timeout projection when runner is slow', () async {
      final runner = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'pg_extension': <Map<String, Object?>>[
            {'extname': 'age'},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await azureExtensionsPresentProducer(
        contextWith(runner, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
      expect(metric.metadata['budget_ms'], equals(50));
    });

    test('producer_error projection when runner throws', () async {
      final runner = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'partman.part_config': StateError('synthetic db error'),
        },
      );
      final metric = await partitionCountActiveProducer(contextWith(runner));
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });
}
