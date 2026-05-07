// `cutover.0` pre-flight — AGE Cypher MATCH smoke.
//
// Confirms the Apache AGE extension is installed on the target
// Production1 database AND a trivial Cypher `MATCH` traversal returns
// without error. This proves both:
//
//   1. `CREATE EXTENSION age` has been run.
//   2. The named graph (`forge_graph` by default — the contract name
//      every advisor / graphify path expects) exists and is reachable
//      under the Cypher entry point.
//
// The check is intentionally minimal: `MATCH (n) RETURN n LIMIT 1`.
// We do not assert the graph has any vertices yet — at `cutover.0`
// the graph may still be empty. Instead we assert the query itself
// completed without raising. An empty result is green; an
// extension-missing or graph-missing error is red.
//
// Like every other check, the live behavior is fully injected via a
// `PostgresPool`; tests pass a `_ScriptedPool` that simulates either
// a clean MATCH or an `extension "age" does not exist`-style error.

import 'dart:async';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import 'check_result.dart';

/// Default named graph. Mirrors the value baked into every advisor
/// retrieval path; never override unless the operator points the
/// harness at a non-default deployment.
const String kDefaultAgeGraphName = 'forge_graph';

/// AGE Cypher MATCH smoke.
class AgeCypherMatchCheck {
  AgeCypherMatchCheck({
    required this.pool,
    this.graphName = kDefaultAgeGraphName,
  });

  final PostgresPool pool;
  final String graphName;

  static const String checkName = 'age_cypher_match';

  Future<CheckResult> run() async {
    final stopwatch = Stopwatch()..start();
    if (!_isSafeIdentifier(graphName)) {
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_age_cypher_match: graph name is not a '
            'safe SQL identifier',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
      );
    }
    final tx = await pool.beginTransaction();
    try {
      // AGE requires the search_path to include `ag_catalog` so the
      // `cypher(...)` function and `agtype` cast resolve. Set this
      // transaction-locally so we never mutate the role's persistent
      // search_path.
      await tx.execute("set local search_path = ag_catalog, '\$user', public");
      final rows = await tx.query(
        "select * from cypher('$graphName', \$\$ MATCH (n) RETURN n LIMIT 1 \$\$) as (n agtype)",
      );
      await tx.rollback();
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.green,
        message:
            'age_cypher_match: cypher MATCH on graph $graphName '
            'returned ${rows.length} row(s)',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'graph_name': graphName,
          'returned_row_count': rows.length,
        },
      );
    } catch (error) {
      await tx.rollback();
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_age_cypher_match: cypher MATCH on graph '
            '$graphName failed (${error.runtimeType})',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'graph_name': graphName,
          'error_kind': error.runtimeType.toString(),
        },
      );
    }
  }
}

/// Restrictive identifier check used to guard SQL string interpolation
/// of the AGE graph name. Same shape as the rls_isolation safety
/// check.
bool _isSafeIdentifier(String value) {
  if (value.isEmpty || value.length > 63) return false;
  return RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value);
}
