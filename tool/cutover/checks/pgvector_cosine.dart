// `cutover.0` pre-flight — pgvector cosine similarity smoke.
//
// Confirms the `pgvector` extension is installed on the target
// Production1 database AND the `<=>` (cosine distance) operator
// resolves and produces a numeric result inside the documented
// [0, 2] range.
//
// The probe runs:
//
//     SELECT '[1,0,0]'::vector <=> '[0,1,0]'::vector AS distance
//
// On a healthy install this returns a float very close to `1.0`
// (orthogonal unit vectors). The harness asserts only the looser
// `0 <= distance <= 2` guarantee so the check stays robust to
// implementation rounding and future operator semantics.
//
// Like every other check, the live behavior is fully injected via a
// `PostgresPool`; tests pass a scripted pool that simulates either a
// clean cosine call or an `operator does not exist: vector <=> vector`
// error.

import 'dart:async';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import 'check_result.dart';

class PgvectorCosineCheck {
  PgvectorCosineCheck({
    required this.pool,
  });

  final PostgresPool pool;

  static const String checkName = 'pgvector_cosine';

  /// Documented range for the cosine *distance* operator (`<=>`).
  /// pgvector defines it as `1 - cosine_similarity`, so values fall
  /// in `[0, 2]` for unit vectors and slightly wider for
  /// non-normalized inputs. We clamp to the documented bound and
  /// reject anything outside.
  static const double minDistance = 0.0;
  static const double maxDistance = 2.0;

  Future<CheckResult> run() async {
    final stopwatch = Stopwatch()..start();
    final tx = await pool.beginTransaction();
    try {
      final rows = await tx.query(
        "select '[1,0,0]'::vector <=> '[0,1,0]'::vector as distance",
      );
      await tx.rollback();
      stopwatch.stop();

      if (rows.isEmpty || rows.first['distance'] == null) {
        return CheckResult(
          name: checkName,
          status: CheckStatus.red,
          message:
              'cutover_preflight_red_pgvector_cosine: probe returned no '
              'rows or null distance',
          elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        );
      }
      final raw = rows.first['distance'];
      final double distance;
      if (raw is num) {
        distance = raw.toDouble();
      } else if (raw is String) {
        distance = double.tryParse(raw) ?? double.nan;
      } else {
        return CheckResult(
          name: checkName,
          status: CheckStatus.red,
          message:
              'cutover_preflight_red_pgvector_cosine: probe returned '
              'unexpected type ${raw.runtimeType}',
          elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
          details: <String, Object?>{
            'returned_type': raw.runtimeType.toString(),
          },
        );
      }
      if (distance.isNaN ||
          distance < minDistance ||
          distance > maxDistance) {
        return CheckResult(
          name: checkName,
          status: CheckStatus.red,
          message:
              'cutover_preflight_red_pgvector_cosine: distance $distance '
              'outside documented [$minDistance, $maxDistance] range',
          elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
          details: <String, Object?>{'distance': distance},
        );
      }
      return CheckResult(
        name: checkName,
        status: CheckStatus.green,
        message:
            'pgvector_cosine: cosine distance probe returned $distance '
            '(within [$minDistance, $maxDistance])',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{'distance': distance},
      );
    } catch (error) {
      await tx.rollback();
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_pgvector_cosine: probe failed '
            '(${error.runtimeType})',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'error_kind': error.runtimeType.toString(),
        },
      );
    }
  }
}
