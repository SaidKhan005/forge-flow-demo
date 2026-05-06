// Phase 10a.3 (layered) — outbox retention sweep + lag-hours producer
// tests.
//
// Local framework slice (no live database). Three groups:
//
//   1. Bounded-sweep migration shape
//      - The new run_event_outbox_retention_sweep() function pins the
//        contract literal predicate (delivered_at IS NOT NULL AND
//        delivered_at < now() - INTERVAL '7 days') inside a CTE
//        capped at LIMIT 10000. The companion event_outbox_retention_sweep_log
//        table carries swept_at + deleted_count + cap_hit and a
//        tenant-leading recent-pass index. The pg_cron schedule is
//        idempotent (unschedule-then-reschedule) and runs at 03:00
//        UTC daily.
//
//   2. eventOutboxRetentionLagProducer thresholds
//      - Green / yellow / red boundaries against the default 36h /
//        168h thresholds. The NULL-safe path (sweep never ran)
//        projects an unknown placeholder with metadata
//        `sweep_never_ran: true`. The producer's SQL pins the
//        monotonic shape MAX(swept_at) over the log table.
//
//   3. Env-var override + threshold resolver
//      - resolveEventOutboxRetentionLagThresholds applies the
//        EVENT_OUTBOX_RETENTION_LAG_YELLOW_HOURS /
//        EVENT_OUTBOX_RETENTION_LAG_RED_HOURS env vars; missing /
//        blank / non-numeric / non-positive values fall back to
//        defaults; an inverted pair clamps red to yellow + 1.
//
// The slice does NOT touch the bridge worker or the publishers (the
// NOTIFY-as-wake-up-only invariant is byte-identical pre/post). The
// tests assert that by absence: no edits to the realtime_bridge or
// publisher producers, only this file's new producer surfaces.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/advisor_proxy/health_producers/health_producer.dart';
import '../../../tool/advisor_proxy/health_producers/outbox_producers.dart';

import '../../proxy/health_producers/_test_helpers.dart';

void main() {
  final migrationSql = _readSqlNormalized(
    'db/migrations/'
    '202605051000_phase_10a_3_outbox_retention_sweep.sql',
  );

  group('Phase 10a.3 (layered) bounded sweep migration shape', () {
    test('declares the run_event_outbox_retention_sweep() function with '
        'the contract literal predicate '
        "(delivered_at IS NOT NULL AND delivered_at < now() - INTERVAL '7 days')",
        () {
      expect(
        migrationSql,
        contains(
          'create or replace function public.run_event_outbox_retention_sweep()',
        ),
      );
      // Pin the literal predicate inside the victims CTE. Both halves
      // are required; dropping `delivered_at is not null` would auto-
      // delete un-delivered rows older than 7 days, which the
      // contract forbids.
      expect(
        migrationSql,
        contains(
          'with victims as (\n'
          '    select id\n'
          '      from public.event_outbox\n'
          '     where delivered_at is not null\n'
          "       and delivered_at < now() - interval '7 days'",
        ),
      );
    });

    test('bounded DELETE caps at 10000 rows per call so a backlogged '
        'sweep cannot hold a long row-level lock', () {
      // The cap declaration is the single source of truth for the
      // bound. Future bumps require a paired update to the contract +
      // walkthrough.
      expect(
        migrationSql,
        contains('v_cap constant integer := 10000;'),
      );
      // The DELETE consumes the CTE's id list — confirms the cap is
      // applied before the DELETE rather than as a post-DELETE filter.
      expect(
        migrationSql,
        contains(
          'delete from public.event_outbox\n'
          '   where id in (select id from victims);',
        ),
      );
      expect(migrationSql, contains('limit v_cap'));
    });

    test('un-delivered rows MUST stay — no DELETE in the migration '
        'reaches a delivered_at IS NULL row', () {
      // Brute-force check: there is exactly one executable DELETE
      // statement in the migration (the bounded sweep), and it is
      // gated by the victims CTE which itself filters on
      // `delivered_at is not null`. Comment lines are excluded so the
      // worked-example DELETE in the file's authority block does not
      // count.
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
            'against event_outbox (the bounded retention sweep)',
      );
      // No DELETE may target rows where delivered_at IS NULL.
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

    test('every sweep call (including zero-delete passes) logs a row '
        'into event_outbox_retention_sweep_log with deleted_count + '
        'cap_hit', () {
      expect(
        migrationSql,
        contains(
          'insert into public.event_outbox_retention_sweep_log\n'
          '    (swept_at, deleted_count, cap_hit)\n'
          '  values\n'
          '    (now(), v_deleted, v_deleted >= v_cap);',
        ),
      );
    });

    test('sweep function runs SECURITY DEFINER and is owned by '
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
          'alter function public.run_event_outbox_retention_sweep() '
          'owner to forge_admin',
        ),
      );
      // Defense-in-depth: revoke from public, grant only to
      // forge_admin so the runtime service_role cannot trigger the
      // sweep on its own.
      expect(
        migrationSql,
        contains(
          'revoke execute on function public.run_event_outbox_retention_sweep()\n'
          '  from public',
        ),
      );
      expect(
        migrationSql,
        contains(
          'grant execute on function public.run_event_outbox_retention_sweep()\n'
          '  to forge_admin',
        ),
      );
    });

    test('event_outbox_retention_sweep_log carries swept_at + '
        'deleted_count + cap_hit + always-NULL operator_id (so the '
        'tenant-leading index discipline lands)', () {
      expect(
        migrationSql,
        contains(
          'create table if not exists public.event_outbox_retention_sweep_log',
        ),
      );
      expect(migrationSql, contains('id bigserial primary key'));
      expect(migrationSql, contains('operator_id uuid null'));
      expect(migrationSql, contains('swept_at timestamptz not null'));
      expect(migrationSql, contains('deleted_count bigint not null'));
      expect(migrationSql, contains('check (deleted_count >= 0)'));
      expect(migrationSql, contains('cap_hit boolean not null'));
    });

    test('event_outbox_retention_sweep_log_recent_idx leads with '
        'operator_id per CLAUDE.md RLS performance discipline (even '
        'though the column is unused for queries)', () {
      // The lint enforces the lead on every B-tree on a table that
      // declares operator_id; this index pins the rule here.
      expect(
        migrationSql,
        contains(
          'create index if not exists event_outbox_retention_sweep_log_recent_idx\n'
          '  on public.event_outbox_retention_sweep_log (operator_id, swept_at desc);',
        ),
      );
    });

    test('pg_cron schedule registration is idempotent and fires at '
        '03:00 UTC daily', () {
      // Idempotency pattern matches phase_9_0sigma_k_pg_cron_jobs +
      // phase_9_8_email_provider: unschedule any prior entry by
      // jobid first, then reschedule.
      expect(
        migrationSql,
        contains(
          "select jobid from cron.job\n"
          "     where jobname = 'event_outbox_retention_sweep_daily'",
        ),
      );
      expect(migrationSql, contains('perform cron.unschedule(v_jobid);'));
      // Daily at 03:00 UTC (22:00 ET / 19:00 PT prior calendar day).
      expect(
        migrationSql,
        contains(
          "perform cron.schedule(\n"
          "    'event_outbox_retention_sweep_daily',\n"
          "    '0 3 * * *',\n"
          "    'select public.run_event_outbox_retention_sweep();'\n"
          "  );",
        ),
      );
      // Azure split-database guard.
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

  group('eventOutboxRetentionLagProducer thresholds', () {
    test('green well under the yellow threshold (1 hour after sweep)',
        () async {
      final metric = await eventOutboxRetentionLagProducer(
        contextWith(
          runnerWith(
            'event_outbox_retention_sweep_log',
            <Map<String, Object?>>[
              {'lag_hours': 1.0},
            ],
          ),
        ),
      );
      expect(metric.status, equals('green'));
      expect(metric.value, equals(1.0));
      expect(metric.unit, equals('hours'));
      expect(metric.thresholds['yellow'], equals(36));
      expect(metric.thresholds['red'], equals(168));
      expect(metric.metadata['tier'], equals(2));
    });

    test('green at 35 hours (just under the yellow boundary)', () async {
      final metric = await eventOutboxRetentionLagProducer(
        contextWith(
          runnerWith(
            'event_outbox_retention_sweep_log',
            <Map<String, Object?>>[
              {'lag_hours': 35.5},
            ],
          ),
        ),
      );
      expect(metric.status, equals('green'));
      expect(metric.value, equals(35.5));
    });

    test('yellow at 36 hours (sweep missed two daily cron passes)',
        () async {
      final metric = await eventOutboxRetentionLagProducer(
        contextWith(
          runnerWith(
            'event_outbox_retention_sweep_log',
            <Map<String, Object?>>[
              {'lag_hours': 36.0},
            ],
          ),
        ),
      );
      expect(metric.status, equals('yellow'));
      expect(metric.value, equals(36.0));
    });

    test('yellow at 167 hours (just under the red boundary)', () async {
      final metric = await eventOutboxRetentionLagProducer(
        contextWith(
          runnerWith(
            'event_outbox_retention_sweep_log',
            <Map<String, Object?>>[
              {'lag_hours': 167.0},
            ],
          ),
        ),
      );
      expect(metric.status, equals('yellow'));
      expect(metric.value, equals(167.0));
    });

    test('red at 168 hours (sweep missed a full week)', () async {
      final metric = await eventOutboxRetentionLagProducer(
        contextWith(
          runnerWith(
            'event_outbox_retention_sweep_log',
            <Map<String, Object?>>[
              {'lag_hours': 168.0},
            ],
          ),
        ),
      );
      expect(metric.status, equals('red'));
      expect(metric.value, equals(168.0));
    });

    test('NULL-safe: sweep never ran -> unknown with sweep_never_ran '
        'metadata so triage can tell the empty-table state apart from '
        'a numeric lag', () async {
      final metric = await eventOutboxRetentionLagProducer(
        contextWith(
          runnerWith(
            'event_outbox_retention_sweep_log',
            <Map<String, Object?>>[
              {'lag_hours': null},
            ],
          ),
        ),
      );
      expect(metric.status, equals('unknown'));
      expect(metric.value, isNull);
      expect(metric.metadata['sweep_never_ran'], isTrue);
      // No tenant identifiers may appear in the envelope.
      expect(metric.metadata.containsKey('operator_id'), isFalse);
      expect(metric.metadata.containsKey('location_id'), isFalse);
    });

    test('producer SQL pins the monotonic MAX(swept_at) shape against '
        'event_outbox_retention_sweep_log', () async {
      final runner = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'event_outbox_retention_sweep_log': <Map<String, Object?>>[
            {'lag_hours': 0.5},
          ],
        },
      );
      await eventOutboxRetentionLagProducer(contextWith(runner));
      final issued = runner.calls.single;
      // Single-table scan, no joins. The MAX(swept_at) shape keeps
      // the producer on the tenant-leading recent-pass index probe.
      expect(issued, contains('from public.event_outbox_retention_sweep_log'));
      expect(issued, contains('max(swept_at)'));
      expect(issued, contains('extract(epoch from'));
      expect(issued, contains('/ 3600'));
    });

    test('producer_timeout projection on slow runner', () async {
      final slow = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'event_outbox_retention_sweep_log': <Map<String, Object?>>[
            {'lag_hours': 0.5},
          ],
        },
        simulatedLatency: const Duration(milliseconds: 300),
      );
      final metric = await eventOutboxRetentionLagProducer(
        contextWith(slow, budget: const Duration(milliseconds: 50)),
      );
      expectUnknownProjection(metric, warning: 'producer_timeout');
    });

    test('producer_error projection when runner throws', () async {
      final boom = FakeProxyHealthQueryRunner(
        patterns: <String, Object>{
          'event_outbox_retention_sweep_log': StateError('boom'),
        },
      );
      final metric = await eventOutboxRetentionLagProducer(
        contextWith(boom),
      );
      expectUnknownProjection(metric, warning: 'producer_error');
    });
  });

  group('resolveEventOutboxRetentionLagThresholds env-var override', () {
    test('empty environment falls back to defaults (36h yellow / 168h red)',
        () {
      final out = resolveEventOutboxRetentionLagThresholds(
        const <String, String>{},
      );
      expect(out.yellowHours, equals(defaultEventOutboxRetentionLagYellowHours));
      expect(out.redHours, equals(defaultEventOutboxRetentionLagRedHours));
    });

    test('valid env override applies the supplied yellow + red hours', () {
      final out = resolveEventOutboxRetentionLagThresholds(
        const <String, String>{
          eventOutboxRetentionLagYellowHoursEnvVar: '12',
          eventOutboxRetentionLagRedHoursEnvVar: '72',
        },
      );
      expect(out.yellowHours, equals(12));
      expect(out.redHours, equals(72));
    });

    test('blank / non-numeric / non-positive values fall back to defaults',
        () {
      for (final bad in <String>['', '   ', 'oops', '0', '-5', '1.5']) {
        final out = resolveEventOutboxRetentionLagThresholds(
          <String, String>{
            eventOutboxRetentionLagYellowHoursEnvVar: bad,
            eventOutboxRetentionLagRedHoursEnvVar: bad,
          },
        );
        expect(
          out.yellowHours,
          equals(defaultEventOutboxRetentionLagYellowHours),
          reason: 'bad yellow value $bad should fall back to default',
        );
        expect(
          out.redHours,
          equals(defaultEventOutboxRetentionLagRedHours),
          reason: 'bad red value $bad should fall back to default',
        );
      }
    });

    test('inverted pair clamps red to yellow + 1 so the yellow band '
        'never collapses', () {
      final out = resolveEventOutboxRetentionLagThresholds(
        const <String, String>{
          eventOutboxRetentionLagYellowHoursEnvVar: '100',
          eventOutboxRetentionLagRedHoursEnvVar: '50',
        },
      );
      expect(out.yellowHours, equals(100));
      expect(out.redHours, equals(101));
    });

    test('equal yellow and red also clamp red to yellow + 1', () {
      final out = resolveEventOutboxRetentionLagThresholds(
        const <String, String>{
          eventOutboxRetentionLagYellowHoursEnvVar: '24',
          eventOutboxRetentionLagRedHoursEnvVar: '24',
        },
      );
      expect(out.yellowHours, equals(24));
      expect(out.redHours, equals(25));
    });
  });

  group('outbox producers registry', () {
    test('event_outbox_retention_lag_hours is wired into outboxProducers',
        () {
      expect(
        outboxProducers.containsKey('event_outbox_retention_lag_hours'),
        isTrue,
        reason: 'Phase 10a.3 layered producer must surface in the family '
            'map so the proxy /health envelope reports it',
      );
      expect(
        outboxProducers['event_outbox_retention_lag_hours'],
        same(eventOutboxRetentionLagProducer),
      );
    });

    test('the existing event_outbox_retention_backlog producer stays '
        'registered (the layered slice is additive)', () {
      expect(
        outboxProducers.containsKey('event_outbox_retention_backlog'),
        isTrue,
      );
    });
  });
}

/// Reads [path] and collapses CRLF -> LF so multi-line `contains(...)`
/// assertions work on Windows checkouts (default `core.autocrlf=true`)
/// as well as on Linux/macOS CI runners.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
