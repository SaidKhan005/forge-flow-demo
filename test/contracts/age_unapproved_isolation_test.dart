// Phase 11A.3b — AGE unapproved-candidate isolation contract test.
//
// This is the central operator-facing guarantee of the slice: a
// rejected Graphify candidate must be unreachable through the
// canonical-graph tables AGE projects from. Two layers enforce this:
//
//   * **Data-flow layer (Group 1).** [GraphRepository.commitBatch]
//     routes approves to `public.graph_nodes` / `public.graph_edges`
//     and routes rejects to `public.graphify_review_audit` only. The
//     repository cannot accidentally route a rejected payload to
//     canonical even if a future code change muddied the call sites.
//
//   * **Schema layer (Group 2).** The 11A.3b migration ships
//     `graphify_review_audit` with **zero foreign keys** into
//     `graph_nodes` / `graph_edges`. AGE projects from canonical FKs;
//     no FK in → no path out. Combined with the append-only grant
//     shape (UPDATE/DELETE revoked) this is the schema-level
//     guarantee no future code change can quietly weaken.
//
// This test asserts both layers from a single file so a regression
// is loud and singular.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/graph_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _userA = '33333333-3333-3333-3333-333333333333';

TenantContext _ctx() =>
    TenantContext(operatorId: _opA, locationId: _locA, userId: _userA);

GraphCommitDecision _approveNode(String key) => GraphCommitDecision(
      kind: GraphCandidateKind.node,
      decision: GraphDecisionKind.approve,
      candidateKey: key,
      candidateType: 'Concept',
      payload: <String, Object?>{'label': 'approved $key'},
      confidenceLabel: GraphCandidateLabel.extracted,
      confidenceScore: 0.95,
      sourceFile: 'methodology_seed.md',
    );

GraphCommitDecision _rejectNode(String key) => GraphCommitDecision(
      kind: GraphCandidateKind.node,
      decision: GraphDecisionKind.reject,
      candidateKey: key,
      candidateType: 'Concept',
      payload: <String, Object?>{'label': 'rejected $key'},
      confidenceLabel: GraphCandidateLabel.ambiguous,
      confidenceScore: 0.41,
      sourceFile: 'methodology_seed.md',
      reason: 'not relevant',
    );

void main() {
  group('AGE isolation - data-flow contract', () {
    test(
        'every canonical-table insert maps to an approved decision; '
        'every audit insert maps to a rejected decision',
        () async {
      final pool = _GraphPool(rowsByContains: <String, List<PostgresRow>>{
        'select node_key, id::text as id': const <PostgresRow>[],
        'insert into public.graph_nodes': <PostgresRow>[
          <String, Object?>{'id': '00000000-0000-4000-9000-bbbbbbbbbbbb'},
        ],
        'insert into public.graphify_review_audit': <PostgresRow>[
          <String, Object?>{
            'audit_id': '00000000-0000-4000-9000-dddddddddddd',
          },
        ],
        'insert into public.audit_logs': <PostgresRow>[
          <String, Object?>{'id': '00000000-0000-4000-9000-eeeeeeeeeeee'},
        ],
      });
      final repo = GraphRepository(TenantTransactionWrapper(pool));
      await repo.commitBatch(
        tenantContext: _ctx(),
        graphScope: 'methodology',
        graphVersion: '1',
        graphifyVersion: 'v5',
        graphifySourceCommit: null,
        idempotencyKey: 'isolation-batch',
        decisions: <GraphCommitDecision>[
          _approveNode('graphify:approved_a'),
          _approveNode('graphify:approved_b'),
          _rejectNode('graphify:rejected_a'),
          _rejectNode('graphify:rejected_b'),
        ],
      );

      final tx = pool.transactions.single;

      // Approves landed in canonical-graph tables; the candidateKeys
      // recorded on those inserts are exactly the approved set.
      final canonicalKeys = tx.executed
          .where((s) => s.sql.contains('insert into public.graph_nodes') ||
              s.sql.contains('insert into public.graph_edges'))
          .map((s) => s.parameters['node_key'] ?? s.parameters['edge_key'])
          .whereType<String>()
          .toSet();
      expect(canonicalKeys, equals(<String>{
        'graphify:approved_a',
        'graphify:approved_b',
      }));

      // Rejects landed in audit only; the candidate_payload includes
      // the rejected candidate_key.
      final auditKeys = tx.executed
          .where((s) =>
              s.sql.contains('insert into public.graphify_review_audit'))
          .map((s) => s.parameters['candidate_payload'])
          .whereType<String>()
          .toSet();
      // The repository serializes the candidate_payload as JSON; the
      // rejected key appears literally in the JSON body.
      expect(
        auditKeys.where((s) => s.contains('graphify:rejected_a')),
        hasLength(1),
      );
      expect(
        auditKeys.where((s) => s.contains('graphify:rejected_b')),
        hasLength(1),
      );

      // The rejected payload NEVER appears in any canonical-graph insert.
      final canonicalInserts = tx.executed
          .where((s) =>
              s.sql.contains('insert into public.graph_nodes') ||
              s.sql.contains('insert into public.graph_edges'))
          .toList();
      for (final insert in canonicalInserts) {
        final paramText = insert.parameters.values
            .map((v) => v?.toString() ?? '')
            .join('|');
        expect(paramText, isNot(contains('graphify:rejected_a')),
            reason: 'rejected candidates must never reach canonical '
                'graph storage; AGE projects from canonical only');
        expect(paramText, isNot(contains('graphify:rejected_b')));
      }
    });
  });

  group('AGE isolation - schema-level contract', () {
    test(
        'graphify_review_audit migration has zero FKs into '
        'graph_nodes / graph_edges and is RLS-protected + append-only',
        () async {
      // The migration lives at db/migrations/202605020001_phase_11A_3b_
      // graphify_review_audit.sql; this test runs from
      // Directory.current which is the worktree root in the test
      // harness setup.
      final migrationFile = File(
        p.join(
          Directory.current.path,
          'db',
          'migrations',
          '202605020001_phase_11A_3b_graphify_review_audit.sql',
        ),
      );
      expect(migrationFile.existsSync(), isTrue,
          reason: 'the 11A.3b migration must exist on disk for this '
              'contract to be exercised');
      final source = await migrationFile.readAsString();
      final lower = source.toLowerCase();

      // ── 1. ZERO FKs into the canonical-graph tables ─────────────
      //
      // AGE projects from canonical FKs; an FK into a canonical row
      // would create a reachable path from audit data and break the
      // isolation guarantee.
      expect(
        lower.contains('references public.graph_nodes'),
        isFalse,
        reason: 'graphify_review_audit must NOT reference '
            'public.graph_nodes — AGE projection would surface the '
            'rejected payload through the FK',
      );
      expect(
        lower.contains('references public.graph_edges'),
        isFalse,
        reason: 'graphify_review_audit must NOT reference '
            'public.graph_edges — AGE projection would surface the '
            'rejected payload through the FK',
      );
      // Defensive: no FK to a hypothetical singular form either.
      expect(lower.contains('references graph_nodes'), isFalse);
      expect(lower.contains('references graph_edges'), isFalse);

      // ── 2. RLS is on with the wrapper-only policy form ──────────
      //
      // Per CLAUDE.md "RLS UUID wrappers (item 4)", policies use
      // `public.app_current_operator()` (or the equivalent wrappers).
      // Bare `current_setting()` reads are forbidden by the lint.
      expect(
        lower.contains('enable row level security'),
        isTrue,
        reason: 'the table must enable RLS at create time',
      );
      expect(
        lower.contains('app_current_operator()'),
        isTrue,
        reason: 'policies must use the STABLE LEAKPROOF wrapper, not '
            'bare current_setting()',
      );

      // ── 3. Append-only by grant shape ───────────────────────────
      //
      // service_role + forge_admin both get INSERT and SELECT only;
      // UPDATE and DELETE are explicitly REVOKEd. Mirrors the
      // auth_events_audit pattern from migration 202604260001.
      expect(
        lower.contains(
          'revoke update, delete on public.graphify_review_audit '
          'from service_role',
        ),
        isTrue,
        reason: 'append-only grant shape: service_role must be '
            'denied UPDATE/DELETE so the audit row is immutable',
      );
      expect(
        lower.contains(
          'revoke update, delete on public.graphify_review_audit '
          'from forge_admin',
        ),
        isTrue,
        reason: 'append-only grant shape: forge_admin must be denied '
            'UPDATE/DELETE so even BYPASSRLS callers cannot rewrite '
            'audit history',
      );
      expect(
        lower.contains(
          'grant select, insert on public.graphify_review_audit '
          'to service_role',
        ),
        isTrue,
        reason: 'service_role must be granted SELECT/INSERT so the '
            'gateway can write rejection rows under tenant context',
      );
    });
  });
}

class _GraphPool implements PostgresPool {
  _GraphPool({
    this.rowsByContains = const <String, List<PostgresRow>>{},
  });

  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_GraphTx> transactions = <_GraphTx>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _GraphTx(rowsByContains: rowsByContains);
    transactions.add(tx);
    return tx;
  }
}

class _RecordedSql {
  _RecordedSql({required this.sql, required this.parameters});
  final String sql;
  final PostgresParameters parameters;
}

class _GraphTx extends PostgresTransaction {
  _GraphTx({required this.rowsByContains});

  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_RecordedSql> executed = <_RecordedSql>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executed.add(_RecordedSql(sql: sql, parameters: parameters));
    for (final entry in rowsByContains.entries) {
      if (sql.contains(entry.key)) return entry.value;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executed.add(_RecordedSql(sql: sql, parameters: parameters));
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
