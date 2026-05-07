// `cutover.0` pre-flight — `pg_partman` + `pg_cron` active smoke.
//
// Confirms two extensions are installed AND `pg_cron` has at least
// one scheduled job. The two-stage assertion mirrors the cutover.0
// checklist:
//
//   1. `SELECT extname FROM pg_extension WHERE extname IN
//      ('pg_partman', 'pg_cron')` returns BOTH names. A missing
//      extension is red.
//   2. `SELECT count(*) FROM cron.job` is `>= 1`. The audit-chain
//      anchor + per-operator partman maintenance both register cron
//      jobs at deploy time; zero scheduled jobs means deploy never
//      ran or jobs were dropped, which would silently break audit
//      log integrity. Red.
//
// Like every other check, the live behavior is fully injected via a
// `PostgresPool`; tests pass a `_ScriptedPool` that simulates either
// both extensions present + ≥1 job, missing-extension, or
// zero-job cases.

import 'dart:async';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import 'check_result.dart';

/// Default minimum number of cron jobs that must be scheduled. Set to
/// 1 because the audit-chain anchor job alone satisfies the
/// "deploy ran" assertion.
const int kDefaultMinCronJobCount = 1;

class PartmanCronActiveCheck {
  PartmanCronActiveCheck({
    required this.pool,
    this.minCronJobCount = kDefaultMinCronJobCount,
  });

  final PostgresPool pool;
  final int minCronJobCount;

  static const String checkName = 'partman_cron_active';

  Future<CheckResult> run() async {
    final stopwatch = Stopwatch()..start();
    final tx = await pool.beginTransaction();
    try {
      final extRows = await tx.query(
        "select extname from pg_extension "
        "where extname in ('pg_partman', 'pg_cron')",
      );
      final presentExtensions = extRows
          .map((r) => r['extname']!.toString())
          .toSet();
      final missingExtensions = <String>[];
      for (final required in const <String>['pg_partman', 'pg_cron']) {
        if (!presentExtensions.contains(required)) {
          missingExtensions.add(required);
        }
      }
      if (missingExtensions.isNotEmpty) {
        await tx.rollback();
        stopwatch.stop();
        return CheckResult(
          name: checkName,
          status: CheckStatus.red,
          message:
              'cutover_preflight_red_partman_cron_active: '
              '${missingExtensions.length} required extension(s) missing',
          elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
          details: <String, Object?>{
            'missing_extensions': missingExtensions,
            'present_extensions': presentExtensions.toList()..sort(),
          },
        );
      }
      final jobRows = await tx.query('select count(*) as n from cron.job');
      final jobCount = jobRows.isEmpty
          ? 0
          : (jobRows.first['n'] as num).toInt();
      await tx.rollback();
      stopwatch.stop();
      if (jobCount < minCronJobCount) {
        return CheckResult(
          name: checkName,
          status: CheckStatus.red,
          message:
              'cutover_preflight_red_partman_cron_active: cron.job has '
              '$jobCount scheduled job(s), expected >= $minCronJobCount',
          elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
          details: <String, Object?>{
            'cron_job_count': jobCount,
            'min_cron_job_count': minCronJobCount,
          },
        );
      }
      return CheckResult(
        name: checkName,
        status: CheckStatus.green,
        message:
            'partman_cron_active: pg_partman + pg_cron present, '
            '$jobCount cron job(s) scheduled',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'cron_job_count': jobCount,
          'present_extensions': const <String>['pg_cron', 'pg_partman'],
        },
      );
    } catch (error) {
      await tx.rollback();
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_partman_cron_active_query_failed: '
            '${error.runtimeType}',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'error_kind': error.runtimeType.toString(),
        },
      );
    }
  }
}
