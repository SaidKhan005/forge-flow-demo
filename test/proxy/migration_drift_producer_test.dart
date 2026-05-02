// Phase 11A.B42 — proxy_migrations_applied registry + drift detection.
//
// These tests exercise the registry contract from the Dart side without a
// live Postgres database. The migration file itself
// (`db/migrations/202605020000_phase_11A_b42_proxy_migrations_applied.sql`)
// is gated by the standard SQL apply checks; here we focus on the
// behavior the proxy depends on.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/health_producers/audit_producers.dart';
import '../../tool/advisor_proxy/health_producers/health_producer.dart';

void main() {
  group('B42 migration grants', () {
    late String migration;

    setUpAll(() {
      migration = File(
        'db/migrations/202605020000_phase_11A_b42_proxy_migrations_applied.sql',
      ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    });

    test('grants registry writes and drift reads to runtime roles', () {
      expect(
        migration,
        contains(
          'grant insert, select on public.proxy_migrations_applied '
          'to service_role, forge_admin',
        ),
      );
      expect(
        migration,
        contains(
          'grant usage, select on sequence '
          'public.proxy_migrations_applied_id_seq '
          'to service_role, forge_admin',
        ),
      );
      expect(
        migration,
        contains(
          'grant execute on function '
          'public.proxy_migration_apply_drift(text[]) '
          'to service_role, forge_admin',
        ),
      );
    });
  });

  group('ProxyMigrationApplyRegistryWriter', () {
    test('records applied migration filenames idempotently', () async {
      final inserted = <String>[];
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async {
        if (sql.contains('insert into public.proxy_migrations_applied')) {
          // Convention check: writer must use named `@filename` binding.
          expect(sql, contains('@filename'));
          final filename = parameters['filename'] as String;
          if (inserted.contains(filename)) {
            // on conflict do nothing — return empty list.
            return const <Map<String, Object?>>[];
          }
          inserted.add(filename);
          return <Map<String, Object?>>[
            {'id': inserted.length},
          ];
        }
        return const <Map<String, Object?>>[];
      }

      final writer =
          ProxyMigrationApplyRegistryWriter(runnerFn: runnerFn);
      final firstInsert = await writer.recordAppliedMigrations(<String>[
        '202604280000_a.sql',
        '202604280001_b.sql',
      ]);
      expect(firstInsert, equals(2));
      // The writer must bind by named placeholder, never positional.
      expect(inserted, equals(<String>['202604280000_a.sql', '202604280001_b.sql']));

      final secondInsert = await writer.recordAppliedMigrations(<String>[
        '202604280000_a.sql',
        '202604280001_b.sql',
      ]);
      expect(secondInsert, equals(0));
    });

    test('rejects path-traversal-y filenames as a defensive check', () async {
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async =>
          const <Map<String, Object?>>[];

      final writer =
          ProxyMigrationApplyRegistryWriter(runnerFn: runnerFn);

      expect(
        () =>
            writer.recordAppliedMigrations(<String>['../escape.sql']),
        throwsArgumentError,
      );
      expect(
        () => writer
            .recordAppliedMigrations(<String>['/abs/path/file.sql']),
        throwsArgumentError,
      );
      expect(
        () => writer.recordAppliedMigrations(<String>[r'C:\windows.sql']),
        throwsArgumentError,
      );
    });

    test('computeDrift returns drift count and missing array', () async {
      Future<List<Map<String, Object?>>> runnerFn(
        String sql, {
        Map<String, Object?> parameters = const <String, Object?>{},
      }) async {
        expect(sql.contains('public.proxy_migration_apply_drift'), isTrue);
        // Convention check: named `@expected` binding.
        expect(sql, contains('@expected'));
        final expected = parameters['expected'] as List<dynamic>;
        return <Map<String, Object?>>[
          {
            'drift_count': expected.length,
            'missing_migrations': expected,
          },
        ];
      }

      final writer =
          ProxyMigrationApplyRegistryWriter(runnerFn: runnerFn);
      final result = await writer.computeDrift(<String>[
        'a.sql',
        'b.sql',
      ]);
      expect(result.driftCount, equals(2));
      expect(result.missing, equals(<String>['a.sql', 'b.sql']));
    });
  });

  group('migrationApplyDriftCountProducer (factory)', () {
    test(
      'unknown when no expected list is provided (default catalog entry)',
      () async {
        // The default catalog entry has no expected list — it must
        // project to unknown rather than green.
        final runner = FakeProxyHealthQueryRunner();
        final metric = await migrationApplyDriftCountProducer(
          ProxyHealthProducerContext(
            runner: runner,
            now: DateTime.utc(2026, 5, 1, 12),
          ),
        );
        expect(metric.status, equals('unknown'));
        expect(
          metric.metadata['warning'],
          equals('expected_filenames_not_provided'),
        );
      },
    );

    test('green when drift_count is 0', () async {
      final runner = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'proxy_migration_apply_drift': <Map<String, Object?>>[
            {'cnt': 0, 'missing': const <String>[]},
          ],
        },
      );
      final producer = migrationApplyDriftCountProducerFor(<String>[
        'a.sql',
        'b.sql',
      ]);
      final metric = await producer(
        ProxyHealthProducerContext(
          runner: runner,
          now: DateTime.utc(2026, 5, 1, 12),
        ),
      );
      expect(metric.status, equals('green'));
      expect(metric.value, equals(0));
      expect(metric.metadata['tier'], equals(1));
    });

    test('red when drift_count >= 1 and reports missing_count', () async {
      final runner = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'proxy_migration_apply_drift': <Map<String, Object?>>[
            {
              'cnt': 3,
              'missing': const <String>['a.sql', 'b.sql', 'c.sql'],
            },
          ],
        },
      );
      final producer = migrationApplyDriftCountProducerFor(<String>[
        'a.sql',
        'b.sql',
        'c.sql',
        'd.sql',
      ]);
      final metric = await producer(
        ProxyHealthProducerContext(
          runner: runner,
          now: DateTime.utc(2026, 5, 1, 12),
        ),
      );
      expect(metric.status, equals('red'));
      expect(metric.value, equals(3));
      expect(metric.metadata['missing_count'], equals(3));
    });

    test(
      'unknown projection when drift function call throws',
      () async {
        final runner = FakeProxyHealthQueryRunner(
          patterns: <String, Object>{
            'proxy_migration_apply_drift': StateError('boom'),
          },
        );
        final producer = migrationApplyDriftCountProducerFor(<String>[
          'a.sql',
        ]);
        final metric = await producer(
          ProxyHealthProducerContext(
            runner: runner,
            now: DateTime.utc(2026, 5, 1, 12),
          ),
        );
        expect(metric.status, equals('unknown'));
        expect(metric.metadata['warning'], equals('producer_error'));
      },
    );
  });
}
