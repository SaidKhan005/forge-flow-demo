// `cutover.0` pre-flight — schema presence check.
//
// Verifies that the configured set of expected tables, RLS-enabled
// tables, and tenant-leading indexes are present on the target
// Production1 database. The check is read-only (information_schema +
// pg_tables + pg_indexes only), exits green when every expected
// object is present, and exits red with a structured `missing_*`
// detail when any object is missing.
//
// The expected-object set is *injected* rather than re-derived from
// `db/migrations/` at runtime, for two reasons:
//
//   1. The harness must be runnable against any CMK-applied baseline
//      (the second-batch cutoff is `202605021900_…seed_existing_chunks`
//      today, but follow-up batches will move the cutoff). The
//      operator passes the expected list at run time so the harness
//      stays useful as the cutoff advances without code edits.
//   2. A migration scanner here would re-derive truth from the
//      working tree, which is a different question from "is
//      Production1 in the state we expect it to be in." The two
//      questions diverge mid-batch (staging is ahead, Production1
//      lags); conflating them hides exactly the drift that
//      `cutover.0` exists to surface.
//
// Default expected set: a known subset of tables that must be
// present once the second-batch cutoff has been applied. The CLI can
// pass `--expect-table=<name>` repeatedly to extend the set, and
// `--expected-tables-from=<path>` to load a newline-delimited file.

import 'dart:async';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import 'check_result.dart';

/// Default required-table names. Every name here is created by a
/// migration applied through the second Production1 batch
/// (`202605021900_phase_11A_3a_corpus_versions_seed_existing_chunks.sql`)
/// or earlier, per
/// `runbooks/phase_9_production1_migration_apply_runbook.md`.
const Set<String> kDefaultExpectedTables = <String>{
  'operators',
  'locations',
  'users',
  'org_units',
  'event_outbox',
  'service_principals',
  'audit_logs',
  'audit_chain_anchors',
  'advisor_conversation_log',
  'advisor_source_chunks',
  'corpus_versions',
  'graph_nodes',
  'graph_edges',
  'usage_caps',
  'usage_logs',
  'proxy_requests',
  'proxy_migrations_applied',
  'feature_flags',
  'recovery_code_attempts',
  'admin_request_idempotency',
  'permission_keys',
};

/// Default RLS-enabled tables. Subset of expected tables whose
/// `pg_tables.rowsecurity = true` posture is required.
const Set<String> kDefaultExpectedRlsTables = <String>{
  'audit_logs',
  'advisor_conversation_log',
  'event_outbox',
  'graph_edges',
  'graph_nodes',
  'service_principals',
  'usage_caps',
  'proxy_requests',
};

/// Schema-presence check. Constructed with an injected pool + the
/// expected object lists; `run()` opens a transaction, runs three
/// read-only catalog queries, and either reports green or returns a
/// red verdict naming each missing object.
class SchemaPresenceCheck {
  SchemaPresenceCheck({
    required this.pool,
    Set<String>? expectedTables,
    Set<String>? expectedRlsTables,
    this.requireOperatorIdLeadingIndex = true,
  }) : expectedTables = expectedTables ?? kDefaultExpectedTables,
       expectedRlsTables = expectedRlsTables ?? kDefaultExpectedRlsTables;

  final PostgresPool pool;
  final Set<String> expectedTables;
  final Set<String> expectedRlsTables;

  /// When true, the check requires every expected RLS table to also
  /// have at least one B-tree index whose leading column is
  /// `operator_id`. Mirrors the CLAUDE.md "RLS-Ready Schema"
  /// guardrail.
  final bool requireOperatorIdLeadingIndex;

  static const String checkName = 'schema_presence';

  Future<CheckResult> run() async {
    final stopwatch = Stopwatch()..start();
    final tx = await pool.beginTransaction();
    try {
      final presentTables = await _readPresentTables(tx);
      final rlsTables = await _readRlsTables(tx);
      final indexedTables = requireOperatorIdLeadingIndex
          ? await _readOperatorLeadingIndexedTables(tx)
          : <String>{};
      await tx.rollback();
      stopwatch.stop();

      final missingTables = expectedTables
          .where((t) => !presentTables.contains(t))
          .toList()
        ..sort();
      final missingRls = expectedRlsTables
          .where((t) => presentTables.contains(t) && !rlsTables.contains(t))
          .toList()
        ..sort();
      final missingIndex = requireOperatorIdLeadingIndex
          ? (expectedRlsTables
                .where(
                  (t) =>
                      presentTables.contains(t) &&
                      !indexedTables.contains(t),
                )
                .toList()
              ..sort())
          : <String>[];

      if (missingTables.isEmpty &&
          missingRls.isEmpty &&
          missingIndex.isEmpty) {
        return CheckResult(
          name: checkName,
          status: CheckStatus.green,
          message:
              'all ${expectedTables.length} expected tables present, '
              'RLS posture matches expected, tenant-leading indexes ok',
          elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
          details: <String, Object?>{
            'expected_table_count': expectedTables.length,
            'present_table_count': presentTables.length,
            'expected_rls_table_count': expectedRlsTables.length,
          },
        );
      }
      final reasons = <String>[];
      if (missingTables.isNotEmpty) {
        reasons.add('${missingTables.length} table(s) missing');
      }
      if (missingRls.isNotEmpty) {
        reasons.add('${missingRls.length} table(s) RLS not enabled');
      }
      if (missingIndex.isNotEmpty) {
        reasons.add(
          '${missingIndex.length} table(s) missing operator-leading index',
        );
      }
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message: 'cutover_preflight_red_schema_presence: ${reasons.join('; ')}',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          if (missingTables.isNotEmpty) 'missing_tables': missingTables,
          if (missingRls.isNotEmpty) 'missing_rls_enabled': missingRls,
          if (missingIndex.isNotEmpty)
            'missing_operator_leading_index': missingIndex,
        },
      );
    } catch (error) {
      await tx.rollback();
      stopwatch.stop();
      return CheckResult(
        name: checkName,
        status: CheckStatus.red,
        message:
            'cutover_preflight_red_schema_presence_query_failed: $error',
        elapsedMs: stopwatch.elapsedMicroseconds / 1000.0,
        details: <String, Object?>{
          'error_kind': error.runtimeType.toString(),
        },
      );
    }
  }

  Future<Set<String>> _readPresentTables(PostgresTransaction tx) async {
    final rows = await tx.query(
      "select table_name from information_schema.tables "
      "where table_schema = 'public'",
    );
    return rows.map((row) => row['table_name']!.toString()).toSet();
  }

  Future<Set<String>> _readRlsTables(PostgresTransaction tx) async {
    final rows = await tx.query(
      "select tablename from pg_tables "
      "where schemaname = 'public' and rowsecurity = true",
    );
    return rows.map((row) => row['tablename']!.toString()).toSet();
  }

  Future<Set<String>> _readOperatorLeadingIndexedTables(
    PostgresTransaction tx,
  ) async {
    // pg_indexes.indexdef looks like:
    //   CREATE INDEX … ON public.audit_logs USING btree (operator_id, …)
    // We accept any index whose first column is `operator_id` —
    // either solo or paired with `location_id` per the RLS-ready
    // schema guardrail.
    final rows = await tx.query(
      "select tablename, indexdef from pg_indexes "
      "where schemaname = 'public'",
    );
    final tables = <String>{};
    for (final row in rows) {
      final tableName = row['tablename']!.toString();
      final indexDef = row['indexdef']!.toString();
      if (indexLeadsWithOperatorId(indexDef)) {
        tables.add(tableName);
      }
    }
    return tables;
  }
}

/// Pure helper: returns true if [indexDef] (as emitted by
/// `pg_indexes.indexdef`) defines a B-tree index whose first column
/// is `operator_id`. Public so the unit-test file can verify the
/// regex against `pg_indexes` literal samples without standing up a
/// full pool fake.
bool indexLeadsWithOperatorId(String indexDef) {
  // The match window is the parenthesized column list after USING …
  // We accept any USING clause (btree is dominant) but pin the
  // first identifier. The pattern is anchored on the first paren-
  // open after USING.
  final match = RegExp(
    r'USING\s+\w+\s*\(\s*([a-zA-Z_][a-zA-Z0-9_]*)',
    caseSensitive: false,
  ).firstMatch(indexDef);
  if (match == null) return false;
  return match.group(1)!.toLowerCase() == 'operator_id';
}
