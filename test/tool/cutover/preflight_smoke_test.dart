// `cutover.0` pre-flight smoke harness — unit tests.
//
// These tests drive each individual check + the aggregator against
// fakes so the harness is verified without a live Postgres. The
// fakes mimic the `PostgresExecutor` seam shape and let each test
// dictate what the "DB" returns for catalog queries / fixture
// writes / cross-tenant reads.
//
// Coverage (≥6 tests, per slice acceptance):
//
//   1. schema_presence: missing table → red.
//   2. schema_presence: all tables present + RLS posture clean → green.
//   3. rls_isolation: cross-tenant read returns empty → green.
//   4. rls_isolation: cross-tenant read returns rows → red.
//   5. dns_resolution: hostname does not resolve → red.
//   6. aggregator: any red → overall red.
//   7. aggregator: all green → overall green + correct JSON.
//   8. firewall_reachability: probe throws → red.
//   9. secret_manager_reachability: skipped → yellow.
//   10. config parsing: --include-rls-isolation without UUIDs → usage error.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import '../../../tool/cutover/checks/age_cypher_match.dart';
import '../../../tool/cutover/checks/check_result.dart';
import '../../../tool/cutover/checks/dns_resolution.dart';
import '../../../tool/cutover/checks/firewall_reachability.dart';
import '../../../tool/cutover/checks/health_endpoint.dart';
import '../../../tool/cutover/checks/partman_cron_active.dart';
import '../../../tool/cutover/checks/pgvector_cosine.dart';
import '../../../tool/cutover/checks/rls_isolation.dart';
import '../../../tool/cutover/checks/schema_presence.dart';
import '../../../tool/cutover/checks/secret_manager_reachability.dart';
import '../../../tool/cutover/preflight_smoke.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '22222222-2222-2222-2222-222222222222';
const String _locA = '33333333-3333-3333-3333-333333333333';
const String _locB = '44444444-4444-4444-4444-444444444444';

void main() {
  group('SchemaPresenceCheck', () {
    test('missing table → red with structured detail', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'information_schema.tables': <PostgresRow>[
              <String, Object?>{'table_name': 'operators'},
              <String, Object?>{'table_name': 'audit_logs'},
              // Note: missing every other expected table.
            ],
            'rowsecurity': <PostgresRow>[
              <String, Object?>{'tablename': 'audit_logs'},
            ],
            'pg_indexes': <PostgresRow>[
              <String, Object?>{
                'tablename': 'audit_logs',
                'indexdef':
                    'CREATE INDEX foo ON public.audit_logs USING btree '
                    '(operator_id, created_at)',
              },
            ],
          },
        ),
      ]);

      final check = SchemaPresenceCheck(
        pool: pool,
        expectedTables: const <String>{
          'operators',
          'audit_logs',
          'event_outbox', // missing
          'service_principals', // missing
        },
        expectedRlsTables: const <String>{'audit_logs'},
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_schema_presence'),
      );
      expect(result.details['missing_tables'], <String>[
        'event_outbox',
        'service_principals',
      ]);
    });

    test('all tables present + RLS posture clean → green', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'information_schema.tables': <PostgresRow>[
              <String, Object?>{'table_name': 'operators'},
              <String, Object?>{'table_name': 'audit_logs'},
              <String, Object?>{'table_name': 'event_outbox'},
            ],
            'rowsecurity': <PostgresRow>[
              <String, Object?>{'tablename': 'audit_logs'},
              <String, Object?>{'tablename': 'event_outbox'},
            ],
            'pg_indexes': <PostgresRow>[
              <String, Object?>{
                'tablename': 'audit_logs',
                'indexdef':
                    'CREATE INDEX foo ON public.audit_logs USING btree '
                    '(operator_id, created_at)',
              },
              <String, Object?>{
                'tablename': 'event_outbox',
                'indexdef':
                    'CREATE INDEX bar ON public.event_outbox USING btree '
                    '(operator_id, location_id)',
              },
            ],
          },
        ),
      ]);

      final check = SchemaPresenceCheck(
        pool: pool,
        expectedTables: const <String>{
          'operators',
          'audit_logs',
          'event_outbox',
        },
        expectedRlsTables: const <String>{'audit_logs', 'event_outbox'},
      );

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(result.message, contains('all 3 expected tables present'));
    });

    test('indexLeadsWithOperatorId helper', () {
      expect(
        indexLeadsWithOperatorId(
          'CREATE INDEX foo ON public.audit_logs USING btree '
          '(operator_id, created_at)',
        ),
        isTrue,
      );
      expect(
        indexLeadsWithOperatorId(
          'CREATE INDEX foo ON public.audit_logs USING btree '
          '(created_at, operator_id)',
        ),
        isFalse,
      );
      expect(
        indexLeadsWithOperatorId(
          'CREATE UNIQUE INDEX foo ON public.t USING btree (id)',
        ),
        isFalse,
      );
    });
  });

  group('RlsIsolationCheck', () {
    test('cross-tenant read returns zero rows → green', () async {
      final pool = _ScriptedPool([
        // First tx: fixture write under A. The scripted tx accepts
        // any execute() and any query() call; the fixture write
        // returns success.
        _ScriptedTransaction.acceptingAll(),
        // Second tx: cross-tenant SELECT returns count = 0.
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'select count(*)': <PostgresRow>[
              <String, Object?>{'n': 0},
            ],
          },
        ),
      ]);

      final check = RlsIsolationCheck(
        pool: pool,
        operatorAUuid: _opA,
        operatorBUuid: _opB,
        locationAUuid: _locA,
        locationBUuid: _locB,
      );

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(result.details['leak_count'], 0);
      // Fixture-tx and read-tx must both ROLLBACK so no rows
      // persist.
      expect(pool.transactions[0].rolledBack, isTrue);
      expect(pool.transactions[0].committed, isFalse);
      expect(pool.transactions[1].rolledBack, isTrue);
      expect(pool.transactions[1].committed, isFalse);
    });

    test('cross-tenant read returns rows → red', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction.acceptingAll(),
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'select count(*)': <PostgresRow>[
              <String, Object?>{'n': 7},
            ],
          },
        ),
      ]);

      final check = RlsIsolationCheck(
        pool: pool,
        operatorAUuid: _opA,
        operatorBUuid: _opB,
        locationAUuid: _locA,
        locationBUuid: _locB,
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_rls_isolation'),
      );
      expect(result.details['leak_count'], 7);
    });

    test('invalid UUID → red, no DB calls', () async {
      final pool = _ScriptedPool([]);
      final check = RlsIsolationCheck(
        pool: pool,
        operatorAUuid: 'not-a-uuid',
        operatorBUuid: _opB,
        locationAUuid: _locA,
        locationBUuid: _locB,
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(result.message, contains('invalid UUID'));
      expect(pool.beginTransactionCount, 0);
    });

    test('unsafe fixture-table identifier → red, no DB calls', () async {
      final pool = _ScriptedPool([]);
      final check = RlsIsolationCheck(
        pool: pool,
        operatorAUuid: _opA,
        operatorBUuid: _opB,
        locationAUuid: _locA,
        locationBUuid: _locB,
        fixtureTable: 'event_outbox; drop table operators',
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(result.message, contains('safe SQL identifier'));
      expect(pool.beginTransactionCount, 0);
    });
  });

  group('DnsResolutionCheck', () {
    test('hostname does not resolve → red', () async {
      final check = DnsResolutionCheck(
        resolver: (hostname) async {
          if (hostname == 'good.example.com') return ['1.2.3.4'];
          return <String>[];
        },
        hostnames: ['good.example.com', 'missing.example.com'],
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_dns_resolution'),
      );
      expect(result.details['unresolved_hostnames'], <String>[
        'missing.example.com',
      ]);
    });

    test('all hostnames resolve → green', () async {
      final check = DnsResolutionCheck(
        resolver: (hostname) async => <String>['1.2.3.4'],
        hostnames: ['a.example.com', 'b.example.com'],
      );

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(result.details['resolved_hostname_count'], 2);
    });
  });

  group('FirewallReachabilityCheck', () {
    test('probe throws → red', () async {
      final check = FirewallReachabilityCheck(
        connectivityProbe: () async {
          throw const SocketTestException('connection refused');
        },
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_firewall_reachability'),
      );
    });

    test('probe returns true → green', () async {
      final check = FirewallReachabilityCheck(
        connectivityProbe: () async => true,
        allowlistedSubnetCidr: '34.130.85.86/32',
      );

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(
        result.details['allowlisted_subnet_cidr'],
        '34.130.85.86/32',
      );
    });
  });

  group('SecretManagerReachabilityCheck', () {
    test('skipped → yellow with skip-reason', () async {
      final check = SecretManagerReachabilityCheck(
        secretRead: (_) async => true,
        skipped: true,
        skipReason: 'workstation_run',
      );

      final result = await check.run();

      expect(result.status, CheckStatus.yellow);
      expect(result.details['skipped'], true);
    });

    test('one secret unreadable → red, names offender', () async {
      final check = SecretManagerReachabilityCheck(
        secretRead: (name) async => name != 'forge-flow-production-anthropic-api-key',
        requiredSecrets: const <String>[
          'forge-flow-production-postgres-url',
          'forge-flow-production-anthropic-api-key',
        ],
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(result.details['unreadable_secret_names'], <String>[
        'forge-flow-production-anthropic-api-key',
      ]);
    });
  });

  group('AgeCypherMatchCheck', () {
    test('AGE MATCH returns rows → green', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            "cypher('forge_graph'": <PostgresRow>[
              <String, Object?>{'n': '{"id": 1}::vertex'},
            ],
          },
        ),
      ]);
      final check = AgeCypherMatchCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(result.details['returned_row_count'], 1);
      expect(result.details['graph_name'], 'forge_graph');
      expect(pool.transactions[0].rolledBack, isTrue);
    });

    test('empty result → green (graph just empty)', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: const <String, List<PostgresRow>>{},
        ),
      ]);
      final check = AgeCypherMatchCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(result.details['returned_row_count'], 0);
    });

    test('query throws (extension missing) → red', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(throwOnQuery: 'extension "age" does not exist'),
      ]);
      final check = AgeCypherMatchCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_age_cypher_match'),
      );
      expect(pool.transactions[0].rolledBack, isTrue);
    });

    test('unsafe graph name → red, no DB calls', () async {
      final pool = _ScriptedPool([]);
      final check = AgeCypherMatchCheck(
        pool: pool,
        graphName: "evil'; drop table users",
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(result.message, contains('safe SQL identifier'));
      expect(pool.beginTransactionCount, 0);
    });
  });

  group('PgvectorCosineCheck', () {
    test('cosine distance in range → green', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'as distance': <PostgresRow>[
              <String, Object?>{'distance': 1.0},
            ],
          },
        ),
      ]);
      final check = PgvectorCosineCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(result.details['distance'], 1.0);
      expect(pool.transactions[0].rolledBack, isTrue);
    });

    test('cosine distance returned as String parses → green', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'as distance': <PostgresRow>[
              <String, Object?>{'distance': '1.0'},
            ],
          },
        ),
      ]);
      final check = PgvectorCosineCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.green);
    });

    test('cosine distance out of range → red', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'as distance': <PostgresRow>[
              <String, Object?>{'distance': 5.0},
            ],
          },
        ),
      ]);
      final check = PgvectorCosineCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_pgvector_cosine'),
      );
    });

    test('query throws (extension missing) → red', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          throwOnQuery: 'operator does not exist: vector <=> vector',
        ),
      ]);
      final check = PgvectorCosineCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_pgvector_cosine'),
      );
      expect(pool.transactions[0].rolledBack, isTrue);
    });

    test('null distance → red (does not throw)', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'as distance': <PostgresRow>[
              <String, Object?>{'distance': null},
            ],
          },
        ),
      ]);
      final check = PgvectorCosineCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.red);
    });
  });

  group('HealthEndpointCheck', () {
    test('200 with marker → green', () async {
      final check = HealthEndpointCheck(
        healthUri: Uri.parse('https://proxy.example/health'),
        probe: (uri) async => const HealthProbeResponse(
          statusCode: 200,
          body: '{"status":"ok","app":"forge-flow"}',
        ),
      );

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(result.details['status_code'], 200);
    });

    test('200 without marker → red', () async {
      final check = HealthEndpointCheck(
        healthUri: Uri.parse('https://proxy.example/health'),
        probe: (uri) async => const HealthProbeResponse(
          statusCode: 200,
          body: '{"status":"ok"}',
        ),
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_health_endpoint'),
      );
    });

    test('non-200 status → red', () async {
      final check = HealthEndpointCheck(
        healthUri: Uri.parse('https://proxy.example/health'),
        probe: (uri) async => const HealthProbeResponse(
          statusCode: 502,
          body: 'bad gateway',
        ),
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(result.details['status_code'], 502);
    });

    test('probe throws → red, does not propagate', () async {
      final check = HealthEndpointCheck(
        healthUri: Uri.parse('https://proxy.example/health'),
        probe: (uri) async {
          throw const SocketTestException('connection refused');
        },
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_health_endpoint'),
      );
    });
  });

  group('PartmanCronActiveCheck', () {
    test('both extensions present, ≥1 cron job → green', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'pg_extension': <PostgresRow>[
              <String, Object?>{'extname': 'pg_partman'},
              <String, Object?>{'extname': 'pg_cron'},
            ],
            'cron.job': <PostgresRow>[
              <String, Object?>{'n': 3},
            ],
          },
        ),
      ]);
      final check = PartmanCronActiveCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(result.details['cron_job_count'], 3);
      expect(pool.transactions[0].rolledBack, isTrue);
    });

    test('one extension missing → red, names offender', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'pg_extension': <PostgresRow>[
              <String, Object?>{'extname': 'pg_partman'},
              // pg_cron missing
            ],
          },
        ),
      ]);
      final check = PartmanCronActiveCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(result.details['missing_extensions'], <String>['pg_cron']);
    });

    test('no cron jobs scheduled → red', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(
          queryResponses: <String, List<PostgresRow>>{
            'pg_extension': <PostgresRow>[
              <String, Object?>{'extname': 'pg_partman'},
              <String, Object?>{'extname': 'pg_cron'},
            ],
            'cron.job': <PostgresRow>[
              <String, Object?>{'n': 0},
            ],
          },
        ),
      ]);
      final check = PartmanCronActiveCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_partman_cron_active'),
      );
      expect(result.details['cron_job_count'], 0);
    });

    test('query throws → red, does not propagate', () async {
      final pool = _ScriptedPool([
        _ScriptedTransaction(throwOnQuery: 'permission denied'),
      ]);
      final check = PartmanCronActiveCheck(pool: pool);

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(
        result.message,
        contains('cutover_preflight_red_partman_cron_active_query_failed'),
      );
      expect(pool.transactions[0].rolledBack, isTrue);
    });
  });

  group('SecretReadProbe (live wiring via override)', () {
    test('all secrets readable → green', () async {
      final read = <String>[];
      final check = SecretManagerReachabilityCheck(
        secretRead: (name) async {
          read.add(name);
          return true;
        },
        requiredSecrets: const <String>[
          'forge-flow-production-postgres-url',
          'forge-flow-production-anthropic-api-key',
        ],
      );

      final result = await check.run();

      expect(result.status, CheckStatus.green);
      expect(read, hasLength(2));
    });

    test('probe throws on one secret → red, names offender', () async {
      final check = SecretManagerReachabilityCheck(
        secretRead: (name) async {
          if (name == 'forge-flow-production-voyage-api-key') {
            throw const SocketTestException('unauthorized');
          }
          return true;
        },
        requiredSecrets: const <String>[
          'forge-flow-production-postgres-url',
          'forge-flow-production-voyage-api-key',
        ],
      );

      final result = await check.run();

      expect(result.status, CheckStatus.red);
      expect(result.details['unreadable_secret_names'], <String>[
        'forge-flow-production-voyage-api-key',
      ]);
      // Errors map records the runtime type without leaking the message.
      final errors = result.details['errors_by_name'] as Map?;
      expect(errors!['forge-flow-production-voyage-api-key'], isNotNull);
    });
  });

  group('Aggregator (runPreflight)', () {
    test('any red → overall red', () async {
      final config = const PreflightConfig(
        run: true,
        showHelp: false,
        jsonOnly: false,
        requireAll: false,
        includeRlsIsolation: false,
        includeFirewallProbe: false,
        skipFirewall: false,
        skipSecrets: false,
      );

      final report = await runPreflight(
        config: config,
        schemaPresenceCheck: _StubSchemaPresenceCheck(
          const CheckResult(
            name: 'schema_presence',
            status: CheckStatus.red,
            message: 'cutover_preflight_red_schema_presence: 1 missing',
          ),
        ),
        secretsCheck: SecretManagerReachabilityCheck(
          secretRead: (_) async => true,
          skipped: true,
          skipReason: 'test',
        ),
      );

      expect(report.overall, CheckStatus.red);
      expect(report.overallGreen, isFalse);
    });

    test('all green → overall green + JSON shape', () async {
      final config = const PreflightConfig(
        run: true,
        showHelp: false,
        jsonOnly: false,
        requireAll: false,
        includeRlsIsolation: false,
        includeFirewallProbe: false,
        skipFirewall: false,
        skipSecrets: false,
        label: 'unit_test',
      );

      final report = await runPreflight(
        config: config,
        schemaPresenceCheck: _StubSchemaPresenceCheck(
          const CheckResult(
            name: 'schema_presence',
            status: CheckStatus.green,
            message: 'all expected tables present',
          ),
        ),
        secretsCheck: SecretManagerReachabilityCheck(
          secretRead: (_) async => true,
          requiredSecrets: const <String>['x'],
        ),
        dnsCheck: DnsResolutionCheck(
          resolver: (_) async => <String>['1.2.3.4'],
          hostnames: const <String>['x.example.com'],
        ),
      );

      expect(report.overall, CheckStatus.green);
      expect(report.overallGreen, isTrue);

      final json = report.toJson();
      expect(json['schema_version'], '1');
      expect(json['overall_status'], 'green');
      expect(json['overall_green'], true);
      expect(json['label'], 'unit_test');
      expect((json['checks'] as List).length, 3);
    });

    test('require_all flips yellow → red', () async {
      final config = const PreflightConfig(
        run: true,
        showHelp: false,
        jsonOnly: false,
        requireAll: true,
        includeRlsIsolation: false,
        includeFirewallProbe: false,
        skipFirewall: false,
        skipSecrets: true,
      );

      final report = await runPreflight(
        config: config,
        schemaPresenceCheck: _StubSchemaPresenceCheck(
          const CheckResult(
            name: 'schema_presence',
            status: CheckStatus.green,
            message: 'ok',
          ),
        ),
        secretsCheck: SecretManagerReachabilityCheck(
          secretRead: (_) async => true,
          skipped: true,
          skipReason: 'workstation_run',
        ),
      );

      // overall is yellow (the secret check is yellow), but
      // overallGreen is false because --require-all flips yellow to
      // blocking.
      expect(report.overall, CheckStatus.yellow);
      expect(report.overallGreen, isFalse);
    });
  });

  group('PreflightConfig.parse', () {
    test('--include-rls-isolation without UUIDs → UsageException', () {
      expect(
        () => PreflightConfig.parse(<String>[
          '--run',
          '--connection-string=postgres://u:p@h/d',
          '--include-rls-isolation',
        ]),
        throwsA(isA<UsageException>()),
      );
    });

    test('--run without --connection-string → UsageException', () {
      expect(
        () => PreflightConfig.parse(<String>['--run']),
        throwsA(isA<UsageException>()),
      );
    });

    test('plan-only mode does not require connection string', () {
      final config = PreflightConfig.parse(<String>[]);
      expect(config.run, isFalse);
      expect(config.connectionString, isNull);
    });

    test('--help short-circuits validation', () {
      final config = PreflightConfig.parse(<String>['--help']);
      expect(config.showHelp, isTrue);
    });

    test('multiple --dns-hostname accumulates', () {
      final config = PreflightConfig.parse(<String>[
        '--run',
        '--connection-string=postgres://u:p@h/d',
        '--dns-hostname=a.example.com',
        '--dns-hostname=b.example.com',
      ]);
      expect(config.dnsHostnames, <String>[
        'a.example.com',
        'b.example.com',
      ]);
    });

    test('--expect-table accumulates', () {
      final config = PreflightConfig.parse(<String>[
        '--run',
        '--connection-string=postgres://u:p@h/d',
        '--expect-table=foo',
        '--expect-table=bar',
      ]);
      expect(config.expectedTables, <String>{'foo', 'bar'});
    });
  });
}

/// Test-only exception so the firewall test can simulate a SocketException-
/// style failure without importing dart:io into a unit test that runs
/// under flutter_test.
class SocketTestException implements Exception {
  const SocketTestException(this.message);
  final String message;
  @override
  String toString() => 'SocketTestException: $message';
}

/// Test-only exception used by [_ScriptedTransaction.throwOnQuery] to
/// simulate a driver-level failure (e.g. `extension "age" does not
/// exist`, `operator does not exist: vector <=> vector`,
/// `permission denied`). The check under test must catch this and
/// convert it to a red verdict — never propagate.
class _ScriptedQueryFailure implements Exception {
  const _ScriptedQueryFailure(this.message);
  final String message;
  @override
  String toString() => 'ScriptedQueryFailure: $message';
}

class _ScriptedPool implements PostgresPool {
  _ScriptedPool(this._scripted);

  final List<_ScriptedTransaction> _scripted;
  final List<_ScriptedTransaction> transactions = <_ScriptedTransaction>[];
  int beginTransactionCount = 0;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    if (beginTransactionCount >= _scripted.length) {
      throw StateError(
        '_ScriptedPool: ran out of scripted transactions '
        '(asked for #${beginTransactionCount + 1}, '
        'only ${_scripted.length} scripted)',
      );
    }
    final tx = _scripted[beginTransactionCount];
    transactions.add(tx);
    beginTransactionCount++;
    return tx;
  }
}

class _ScriptedTransaction implements PostgresTransaction {
  _ScriptedTransaction({
    Map<String, List<PostgresRow>>? queryResponses,
    this.acceptAnyExecute = false,
    this.throwOnQuery,
  }) : queryResponses = queryResponses ?? <String, List<PostgresRow>>{};

  /// Convenience: a transaction that accepts any execute() / query()
  /// call without raising. Used for the fixture-write step in the
  /// RLS isolation check.
  factory _ScriptedTransaction.acceptingAll() => _ScriptedTransaction(
    acceptAnyExecute: true,
    queryResponses: const <String, List<PostgresRow>>{},
  );

  /// Map of substring → response. The first entry in the map whose
  /// key appears in the SQL statement determines the response.
  final Map<String, List<PostgresRow>> queryResponses;
  final bool acceptAnyExecute;

  /// When set, every `query(...)` call raises a [_ScriptedQueryFailure]
  /// carrying this message. Used by tests that want to simulate
  /// "extension not installed" / "permission denied" / "operator does
  /// not exist" responses from the underlying driver.
  final String? throwOnQuery;

  bool committed = false;
  bool rolledBack = false;
  final executedSql = <String>[];
  final queriedSql = <String>[];

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queriedSql.add(sql);
    if (throwOnQuery != null) {
      throw _ScriptedQueryFailure(throwOnQuery!);
    }
    for (final entry in queryResponses.entries) {
      if (sql.contains(entry.key)) {
        return entry.value;
      }
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executedSql.add(sql);
    if (acceptAnyExecute) return 1;
    return 1;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
  }
}

class _StubSchemaPresenceCheck implements SchemaPresenceCheck {
  _StubSchemaPresenceCheck(this._result);

  final CheckResult _result;

  @override
  Future<CheckResult> run() async => _result;

  // The rest of the SchemaPresenceCheck surface is irrelevant for
  // tests — the aggregator only calls `.run()`. Throw on anything
  // else so a future change that touches the surface fails loudly.
  @override
  PostgresPool get pool => throw UnimplementedError();
  @override
  Set<String> get expectedTables => throw UnimplementedError();
  @override
  Set<String> get expectedRlsTables => throw UnimplementedError();
  @override
  bool get requireOperatorIdLeadingIndex => throw UnimplementedError();
}
