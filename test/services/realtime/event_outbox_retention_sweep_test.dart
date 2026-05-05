// Phase 10a.3 — event_outbox retention sweep tests.
//
// Local framework slice (no live database). Three groups:
//
//   1. Migration shape
//      ─ partial index + retention SQL function + idempotent pg_cron
//        registration. Asserts the literal predicate (`delivered_at
//        IS NOT NULL AND delivered_at < now() - INTERVAL '7 days'`)
//        and the un-delivered-rows-stay invariant by absence of any
//        `where delivered_at is null` DELETE.
//
//   2. Health producer thresholds
//      ─ green / yellow / red boundaries + the SQL predicate the
//        producer pins.
//
//   3. Producer registry wiring
//      ─ the new `event_outbox_retention_backlog` slot is in the
//        outbox producers map.
//
// The slice does NOT add a Dart side worker — the SQL function does
// the DELETE itself inside the cron context. The test pins the
// migration's predicate so a future contract drift (e.g. someone
// changing `delivered_at IS NOT NULL` to a join on the bridge's last
// publish ack) shows up before it lands.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/health_producers/event_outbox_retention_producer.dart';
import '../../../tool/advisor_proxy/health_producers/health_producer.dart';
import '../../../tool/advisor_proxy/health_producers/outbox_producers.dart';

import '../../proxy/health_producers/_test_helpers.dart';

void main() {
  final migrationSql = _readSqlNormalized(
    'db/migrations/'
    '202605050200_phase_10a_3_event_outbox_retention.sql',
  );

  group('Phase 10a.3 migration shape', () {
    test('declares the retention function with the contract literal '
        'predicate (delivered_at IS NOT NULL AND delivered_at < now() - '
        "INTERVAL '7 days')", () {
      expect(
        migrationSql,
        contains(
          'create or replace function public.event_outbox_retention_sweep()',
        ),
      );
      // Pin the literal SQL predicate. Both halves are required —
      // dropping `delivered_at is not null` would auto-delete
      // un-delivered rows older than 7 days, which the contract
      // forbids ("Un-delivered rows: never auto-deleted").
      expect(
        migrationSql,
        contains(
          'delete from public.event_outbox\n'
          '   where delivered_at is not null\n'
          "     and delivered_at < now() - interval '7 days'",
        ),
      );
    });

    test('un-delivered rows MUST stay — the migration contains no '
        'DELETE that would reach a delivered_at IS NULL row', () {
      // Brute-force check: there is exactly ONE executable DELETE
      // statement in the migration (the retention sweep), and it is
      // gated by `delivered_at is not null`. Any other DELETE — or
      // any DELETE missing the not-null guard — would be a contract
      // violation. Comment lines (lines that start with `--` after
      // optional whitespace) are excluded so the worked-example
      // DELETE in the file's authority block does not count.
      final executableLines = migrationSql
          .split('\n')
          .where((line) => !RegExp(r'^\s*--').hasMatch(line))
          .join('\n');
      final deletes = RegExp(
        r'delete\s+from\s+public\.event_outbox\b',
        caseSensitive: false,
      ).allMatches(executableLines);
      expect(
        deletes.length,
        equals(1),
        reason: 'migration must contain exactly one executable DELETE '
            'against event_outbox (the retention sweep)',
      );
      // The retention sweep predicate is the only path that touches
      // event_outbox via DELETE in this slice; the absence of any
      // DELETE that filters on `delivered_at is null` (or omits the
      // guard altogether) is what enforces the un-delivered-stays
      // invariant.
      expect(
        migrationSql,
        isNot(
          matches(
            RegExp(
              r'delete\s+from\s+public\.event_outbox[^;]*delivered_at\s+is\s+null',
              caseSensitive: false,
            ),
          ),
        ),
        reason: 'no DELETE may target rows where delivered_at IS NULL',
      );
    });

    test('partial index on delivered rows is tenant-leading per CLAUDE.md '
        'RLS performance discipline', () {
      // operator_id MUST lead so the per-tenant RLS policy folds
      // into the index probe for per-operator triage queries. The
      // partial WHERE clause keeps the index off the un-delivered
      // head of the queue (covered by event_outbox_claim_idx).
      expect(
        migrationSql,
        contains(
          'create index if not exists event_outbox_delivered_idx\n'
          '  on public.event_outbox (operator_id, delivered_at desc, id)\n'
          '  where delivered_at is not null;',
        ),
      );
    });

    test('retention function runs SECURITY DEFINER and is owned by '
        'forge_admin (so the cross-operator DELETE inherits BYPASSRLS)',
        () {
      expect(migrationSql, contains('security definer'));
      // search_path locked so a SECURITY DEFINER function can\'t be
      // hijacked by a same-named object in a session-injected schema.
      expect(
        migrationSql,
        contains('set search_path = public, pg_catalog'),
      );
      expect(
        migrationSql,
        contains(
          'alter function public.event_outbox_retention_sweep() owner '
          'to forge_admin',
        ),
      );
      // Defense-in-depth: revoke from public, grant only to
      // forge_admin so the runtime service_role cannot trigger the
      // sweep on its own.
      expect(
        migrationSql,
        contains(
          'revoke execute on function public.event_outbox_retention_sweep()\n'
          '  from public',
        ),
      );
      expect(
        migrationSql,
        contains(
          'grant execute on function public.event_outbox_retention_sweep()\n'
          '  to forge_admin',
        ),
      );
    });

    test('pg_cron schedule registration is idempotent — re-applying the '
        'migration on a host where the schedule already exists is a no-op',
        () {
      // Idempotency pattern matches phase_9_0sigma_k_pg_cron_jobs +
      // phase_9_8_email_provider: unschedule any prior entry by jobid
      // first, then reschedule. cron.schedule() raises a unique_violation
      // on a duplicate jobname, so the absence of the unschedule loop
      // would break re-runs.
      expect(
        migrationSql,
        contains(
          "select jobid from cron.job where jobname = "
          "'forge_event_outbox_retention_sweep'",
        ),
      );
      expect(migrationSql, contains('perform cron.unschedule(v_jobid);'));
      // Daily at 09:00 UTC (04:00 ET / 01:00 PT) — restaurants
      // closed across North America so the cross-operator DELETE
      // does not contend with producer enqueues.
      expect(
        migrationSql,
        contains(
          "perform cron.schedule(\n"
          "    'forge_event_outbox_retention_sweep',\n"
          "    '0 9 * * *',\n"
          "    'select public.event_outbox_retention_sweep();'\n"
          "  );",
        ),
      );
      // Azure DB Flexible Server keeps pg_cron metadata in a
      // separate database; the DO block must NOTICE-and-return so
      // the live apply log captures the schedule_in_database manual
      // step rather than failing.
      expect(
        migrationSql,
        contains("if to_regnamespace('cron') is null"),
      );
      expect(
        migrationSql,
        contains("or to_regclass('cron.job') is null then"),
      );
      expect(
        migrationSql,
        contains(
          "schedule from cron.database_name with cron.schedule_in_database",
        ),
      );
    });
  });

  group('eventOutboxRetentionBacklogProducer thresholds', () {
    test('green at 0 (steady state — sweep just ran)', () async {
      final metric = await eventOutboxRetentionBacklogProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'cnt': 0},
        ])),
      );
      expect(metric.status, equals('green'));
      expect(metric.value, equals(0));
      expect(metric.unit, equals('count'));
      expect(metric.thresholds['yellow'], equals(100));
      expect(metric.thresholds['red'], equals(10000));
    });

    test('green within the inter-sweep window (count below yellow '
        'threshold of 100)', () async {
      final metric = await eventOutboxRetentionBacklogProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'cnt': 50},
        ])),
      );
      expect(metric.status, equals('green'));
      expect(metric.value, equals(50));
    });

    test('yellow at 100 (sustained backlog suggests sweep falling '
        'behind)', () async {
      final metric = await eventOutboxRetentionBacklogProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'cnt': 100},
        ])),
      );
      expect(metric.status, equals('yellow'));
      expect(metric.value, equals(100));
    });

    test('red at 10000 (multi-day backlog — sweep clearly broken)',
        () async {
      final metric = await eventOutboxRetentionBacklogProducer(
        contextWith(runnerWith('event_outbox', <Map<String, Object?>>[
          {'cnt': 10000},
        ])),
      );
      expect(metric.status, equals('red'));
      expect(metric.value, equals(10000));
    });

    test('producer SQL pins the literal contract predicate '
        '(delivered_at IS NOT NULL AND delivered_at < now() - 7 days)',
        () async {
      final runner = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'event_outbox': <Map<String, Object?>>[
            {'cnt': 0},
          ],
        },
      );
      await eventOutboxRetentionBacklogProducer(contextWith(runner));
      final issued = runner.calls.single;
      expect(issued, contains('from event_outbox'));
      // Both predicates required — un-delivered rows must NEVER be
      // counted as a retention backlog signal.
      expect(issued, contains('delivered_at is not null'));
      expect(
        issued,
        contains("delivered_at < now() - interval '7 days'"),
      );
    });

    test('producer_timeout projection on slow runner', () async {
      final slow = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'event_outbox': <Map<String, Object?>>[
            {'cnt': 0},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await eventOutboxRetentionBacklogProducer(
        contextWith(slow, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
    });

    test('producer_error projection when runner throws', () async {
      final boom = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'event_outbox': StateError('boom'),
        },
      );
      final metric = await eventOutboxRetentionBacklogProducer(
        contextWith(boom),
      );
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });

  group('outbox producers registry', () {
    test('event_outbox_retention_backlog is wired into outboxProducers',
        () {
      expect(
        outboxProducers.containsKey('event_outbox_retention_backlog'),
        isTrue,
        reason: 'Phase 10a.3 producer must surface in the family map '
            'so the proxy /health envelope reports it',
      );
      expect(
        outboxProducers['event_outbox_retention_backlog'],
        same(eventOutboxRetentionBacklogProducer),
      );
    });
  });
}

/// Reads [path] and collapses CRLF → LF so multi-line `contains(...)`
/// assertions work on Windows checkouts (default `core.autocrlf=true`)
/// as well as on Linux/macOS CI runners.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
