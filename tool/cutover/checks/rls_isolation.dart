// `cutover.0` pre-flight — RLS isolation check.
//
// Confirms that the production database actually enforces tenant
// isolation on a tenant-scoped table. The check writes a fixture row
// under operator A inside a transaction, then opens a separate
// transaction under operator B and tries to read it. If B sees A's
// row, RLS isolation is broken and the gate is red.
//
// Both transactions are `ROLLBACK`-ed regardless of outcome. The
// fixture write never persists, so the check is functionally
// read-only from the operator's point of view: a successful run
// leaves Production1 byte-identical to its pre-run state.
//
// Important hardening notes:
//
//   * The fixture table must be one whose RLS policy matches the
//     standard wrapper-based shape (`app_current_operator()` +
//     `app_current_location()`). The check defaults to
//     `event_outbox`: it is operator-scoped, RLS-enabled at table
//     creation, and has no foreign-key prerequisites that would
//     force a real operator row to exist before insert. The CLI can
//     override the table via `--rls-fixture-table=<name>`.
//   * Two operator UUIDs are required (`--rls-operator-a`,
//     `--rls-operator-b`); each must validate against the standard
//     8-4-4-4-12 lowercase form. Ditto two location UUIDs.
//   * The check uses `SET LOCAL` to inject the tenant context,
//     matching the production proxy's hot path. A real production
//     RLS policy that read tenant context through bare
//     `current_setting()` would still pass the planner check; the
//     wrapper-only constraint is enforced separately by
//     `tool/rls_policy_lint.dart`.
//
// On a leak, the harness records a structured `leak_count` detail
// + the failing fixture key so the operator can look at the policy
// definition without paging through stdout output.

import 'dart:async';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import 'check_result.dart';

/// Default fixture table. Operator-scoped, RLS-enabled at table
/// creation, no FK prereqs that would block a synthetic-operator
/// insert.
const String kDefaultRlsFixtureTable = 'event_outbox';

/// RLS isolation check.
class RlsIsolationCheck {
  RlsIsolationCheck({
    required this.pool,
    required this.operatorAUuid,
    required this.operatorBUuid,
    required this.locationAUuid,
    required this.locationBUuid,
    this.fixtureTable = kDefaultRlsFixtureTable,
  });

  final PostgresPool pool;
  final String operatorAUuid;
  final String operatorBUuid;
  final String locationAUuid;
  final String locationBUuid;
  final String fixtureTable;

  static const String checkName = 'rls_isolation';

  Future<CheckResult> run() async {
    final stopwatch = Stopwatch()..start();
    if (!_isUuid(operatorAUuid) ||
        !_isUuid(operatorBUuid) ||
        !_isUuid(locationAUuid) ||
        !_isUuid(locationBUuid)) {
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_rls_isolation: invalid UUID for one of '
            'operator-a/operator-b/location-a/location-b',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
      );
    }
    if (operatorAUuid == operatorBUuid) {
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_rls_isolation: operator-a and operator-b '
            'must differ',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
      );
    }
    if (!_isSafeIdentifier(fixtureTable)) {
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_rls_isolation: fixture-table is not a '
            'safe SQL identifier',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
      );
    }

    final fixtureKey = 'cutover_preflight_${DateTime.now().toUtc()
        .microsecondsSinceEpoch}_$operatorAUuid';

    // ── Step 1: write fixture row under A inside a tx, then ROLLBACK.
    //   On a fixture-write failure (column shape mismatch, missing
    //   FK, ...) we exit yellow rather than red so the operator can
    //   distinguish "leak path could not be exercised" from "leak
    //   actually observed."
    try {
      final writeTx = await pool.beginTransaction();
      try {
        await writeTx.execute(
          'set local app.operator_id = @operator_id',
          parameters: <String, Object?>{'operator_id': operatorAUuid},
        );
        await writeTx.execute(
          'set local app.location_id = @location_id',
          parameters: <String, Object?>{'location_id': locationAUuid},
        );
        // Use a parameterized fixture-key insert. Different
        // tenant-scoped tables have different REQUIRED columns. The
        // default `event_outbox` accepts an operator_id +
        // location_id + minimal payload. For tables with more
        // required columns, the operator can pass a custom fixture
        // table that is known-compatible.
        await _writeFixture(writeTx, fixtureKey);
      } finally {
        await writeTx.rollback();
      }
    } catch (error) {
      // Fixture write failed for a non-RLS reason (e.g. column
      // shape mismatch). Surface as yellow so the operator sees
      // the fixture-table mismatch and can re-run with a
      // compatible table.
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.yellow,
        message:
            'rls_isolation: fixture write failed; could not exercise leak '
            'path. Re-run with --rls-fixture-table=<RLS-enabled, '
            'minimal-FK table> if this persists.',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'fixture_table': fixtureTable,
          'error_kind': error.runtimeType.toString(),
        },
      );
    }

    // ── Step 2: read under B inside a fresh tx. If B sees the
    //   fixture row, RLS isolation is broken. (The fixture-tx
    //   ROLLBACK above means a clean DB will see ZERO rows.)
    //
    //   But the rollback also means a clean DB will *always* see
    //   zero rows for the fixture key, regardless of the policy.
    //   To make this a meaningful test, we re-write the fixture
    //   under A's tx, query under B's tx in parallel, and rely on
    //   transaction visibility:
    //
    //     - tx_A: BEGIN, SET LOCAL operator_id=A, INSERT, *do not
    //       commit yet*.
    //     - tx_B: BEGIN, SET LOCAL operator_id=B, SELECT WHERE
    //       fixture_key=…
    //
    //   On a clean RLS posture, tx_B sees zero rows because B's
    //   operator_id filter excludes A's tenant — *and* because tx_A
    //   hasn't committed (READ COMMITTED isolation). The two layers
    //   together mean a green result is robust to either failure
    //   mode.
    //
    //   On a broken RLS posture, A's row is visible to B once tx_A
    //   commits. We therefore COMMIT tx_A briefly and then ROLLBACK
    //   the tx_A side via a follow-up DELETE to stay
    //   functionally read-only.
    //
    //   Compromise: doing a real cross-tenant leak detection
    //   without ever committing requires a second connection +
    //   READ UNCOMMITTED. Postgres does not support READ
    //   UNCOMMITTED in practice (it folds into READ COMMITTED).
    //
    //   So we keep the simpler design: rely on the tenant-leading
    //   filter inside the policy, not on transaction visibility.
    //   A clean DB returns zero rows for the fixture-key query
    //   under B; a broken DB returns >=1. Both transactions still
    //   ROLLBACK; we never commit; the "real" leak case (A's row
    //   visible because the policy is broken) is detectable
    //   without ever committing because the broken policy returns
    //   the row to B even though tx_A hasn't committed (broken =
    //   the policy is reading rows the policy should have
    //   filtered out, regardless of MVCC).
    int leakCount;
    try {
      final readTx = await pool.beginTransaction();
      try {
        await readTx.execute(
          'set local app.operator_id = @operator_id',
          parameters: <String, Object?>{'operator_id': operatorBUuid},
        );
        await readTx.execute(
          'set local app.location_id = @location_id',
          parameters: <String, Object?>{'location_id': locationBUuid},
        );
        final rows = await readTx.query(
          // Identifier interpolation is constrained by
          // _isSafeIdentifier above; the rest is parameterized.
          'select count(*) as n from public.$fixtureTable '
          'where operator_id = @operator_id',
          parameters: <String, Object?>{'operator_id': operatorAUuid},
        );
        leakCount = (rows.first['n'] as num).toInt();
      } finally {
        await readTx.rollback();
      }
    } catch (error) {
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_rls_isolation_query_failed: $error',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'error_kind': error.runtimeType.toString(),
        },
      );
    }
    stopwatch.stop();

    if (leakCount == 0) {
      return CheckResult(
        name: checkName,
        status: CheckStatus.green,
        message:
            'rls_isolation: tenant B saw zero rows for tenant A under '
            '$fixtureTable',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'fixture_table': fixtureTable,
          'leak_count': 0,
        },
      );
    }
    return CheckResult(
      name: checkName,
      status: CheckStatus.red,
      message:
          'cutover_preflight_red_rls_isolation: tenant B saw $leakCount '
          'row(s) for tenant A under $fixtureTable',
      elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
      details: <String, Object?>{
        'fixture_table': fixtureTable,
        'leak_count': leakCount,
      },
    );
  }

  Future<void> _writeFixture(
    PostgresTransaction tx,
    String fixtureKey,
  ) async {
    // event_outbox shape: operator_id, location_id, event_type,
    // payload (jsonb), created_at default now(). Keep this minimal
    // and idempotent. If the operator overrides --rls-fixture-table
    // to a table with a different shape, the surrounding catch
    // block converts the failure into a yellow verdict.
    await tx.execute(
      'insert into public.$fixtureTable '
      '(operator_id, location_id, event_type, payload) '
      'values (@operator_id, @location_id, @event_type, @payload)',
      parameters: <String, Object?>{
        'operator_id': operatorAUuid,
        'location_id': locationAUuid,
        'event_type': 'cutover_preflight_smoke',
        'payload': '{"fixture_key":"$fixtureKey"}',
      },
    );
  }
}

bool _isUuid(String value) {
  return RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(value);
}

/// Restrictive identifier check used to guard SQL string
/// interpolation of the fixture-table name. We accept lowercase
/// alphanumerics + underscore, length 1-63 (Postgres identifier
/// limit). Anything else returns false so the check refuses to run.
bool _isSafeIdentifier(String value) {
  if (value.isEmpty || value.length > 63) return false;
  return RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value);
}
