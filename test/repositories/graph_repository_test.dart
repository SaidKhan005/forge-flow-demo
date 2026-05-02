// Phase 11A.3b — GraphRepository tests.
//
// Drives [GraphRepository.commitBatch] against a fake [PostgresPool]
// so the SQL shape, transactional ordering, and audit fan-out are
// pinned without a live Postgres instance. Coverage:
//
//   * A mixed approve + reject batch routes approves to canonical
//     `public.graph_nodes` / `public.graph_edges` and routes rejects
//     to `public.graphify_review_audit` only — never the reverse.
//   * Edit-as-approve writes to canonical (the unedited form lives
//     in the source graphify-out artifact, NOT production truth).
//   * The transaction issues `set_config('app.operator_id', ...)`,
//     `set_config('app.location_id', ...)`, and
//     `set_config('app.user_id', ...)` BEFORE any business write.
//   * Edge endpoint resolution: an edge whose endpoint is neither in
//     the prewarm cache nor approved earlier in the same batch raises
//     `GraphCommitBatchValidationError(409, edge_endpoint_unresolved)`.
//   * Empty batch raises `GraphCommitBatchValidationError(400,
//     empty_batch)` before opening the transaction.
//   * `FixedAuditLogsCutoverFlag(false)` skips the audit_logs fan-out
//     while still writing the canonical / audit row.
//   * Mixed batch: nodes are inserted before edges so the composite
//     FK on `graph_edges.from_node_id / to_node_id` finds its target.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
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
      payload: const <String, Object?>{'label': 'a node'},
      confidenceLabel: GraphCandidateLabel.extracted,
      confidenceScore: 0.95,
      sourceFile: 'methodology_seed.md',
    );

GraphCommitDecision _rejectNode(String key) => GraphCommitDecision(
      kind: GraphCandidateKind.node,
      decision: GraphDecisionKind.reject,
      candidateKey: key,
      candidateType: 'Concept',
      payload: const <String, Object?>{'label': 'rejected'},
      confidenceLabel: GraphCandidateLabel.ambiguous,
      confidenceScore: 0.41,
      sourceFile: 'methodology_seed.md',
      reason: 'not relevant',
    );

GraphCommitDecision _approveEdge(
  String key, {
  required String fromKey,
  required String toKey,
}) =>
    GraphCommitDecision(
      kind: GraphCandidateKind.edge,
      decision: GraphDecisionKind.approve,
      candidateKey: key,
      candidateType: 'CONTAINS',
      payload: const <String, Object?>{'label': 'an edge'},
      confidenceLabel: GraphCandidateLabel.extracted,
      confidenceScore: 0.92,
      sourceFile: 'methodology_seed.md',
      fromNodeKey: fromKey,
      toNodeKey: toKey,
    );

GraphCommitDecision _editEdge(
  String key, {
  required String fromKey,
  required String toKey,
}) =>
    GraphCommitDecision(
      kind: GraphCandidateKind.edge,
      decision: GraphDecisionKind.edit,
      candidateKey: key,
      candidateType: 'INFORMS',
      payload: const <String, Object?>{'label': 'an edited edge'},
      confidenceLabel: GraphCandidateLabel.inferred,
      confidenceScore: 0.65,
      sourceFile: 'methodology_seed.md',
      fromNodeKey: fromKey,
      toNodeKey: toKey,
    );

void main() {
  group('GraphRepository.commitBatch', () {
    test(
        'mixed batch (approve node + approve edge + reject node + edit edge) '
        'routes approves to canonical and rejects to graphify_review_audit',
        () async {
      // Prewarm cache returns the existing canonical node ids the
      // edges will reference; the approved-node insert returns its
      // own id; the edit-edge references the prewarm-cache node.
      final pool = _GraphPool(rowsByContains: <String, List<PostgresRow>>{
        'select node_key, id::text as id': <PostgresRow>[
          <String, Object?>{
            'node_key': 'graphify:existing_target',
            'id': '00000000-0000-4000-9000-aaaaaaaaaaaa',
          },
        ],
        'insert into public.graph_nodes': <PostgresRow>[
          <String, Object?>{'id': '00000000-0000-4000-9000-bbbbbbbbbbbb'},
        ],
        'insert into public.graph_edges': <PostgresRow>[
          <String, Object?>{'id': '00000000-0000-4000-9000-cccccccccccc'},
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
      final result = await repo.commitBatch(
        tenantContext: _ctx(),
        graphScope: 'methodology',
        graphVersion: '1',
        graphifyVersion: 'v5',
        graphifySourceCommit: 'commit-abc',
        idempotencyKey: 'batch-1',
        decisions: <GraphCommitDecision>[
          _approveNode('graphify:approved_node'),
          _approveEdge(
            'graphify:approved_edge',
            fromKey: 'graphify:approved_node',
            toKey: 'graphify:existing_target',
          ),
          _rejectNode('graphify:rejected_node'),
          _editEdge(
            'graphify:edited_edge',
            fromKey: 'graphify:approved_node',
            toKey: 'graphify:existing_target',
          ),
        ],
      );
      expect(result.approvedNodeCount, equals(1));
      expect(result.approvedEdgeCount, equals(2),
          reason: 'edit-as-approve also writes canonical so the edge '
              'count picks it up');
      expect(result.rejectedCount, equals(1));

      final tx = pool.transactions.single;
      final stages =
          tx.executed.map((s) => s.sql).toList(growable: false);
      // SET LOCAL injections fire before any business write.
      expect(
        stages.indexWhere((s) => s.contains('app.operator_id')),
        greaterThanOrEqualTo(0),
      );
      expect(
        stages.indexWhere((s) => s.contains('app.location_id')),
        greaterThanOrEqualTo(0),
      );
      expect(
        stages.indexWhere((s) => s.contains('app.user_id')),
        greaterThanOrEqualTo(0),
      );

      // Approves landed in canonical-graph tables.
      expect(
        stages.where((s) => s.contains('insert into public.graph_nodes')),
        hasLength(1),
        reason: 'one approved node decision → one graph_nodes insert',
      );
      expect(
        stages.where((s) => s.contains('insert into public.graph_edges')),
        hasLength(2),
        reason: 'one approved edge + one edit-as-approve → two '
            'graph_edges inserts',
      );
      // Reject landed in audit table only.
      expect(
        stages.where(
          (s) => s.contains('insert into public.graphify_review_audit'),
        ),
        hasLength(1),
      );

      // No canonical insert ever carries the rejected_node payload —
      // the rejected candidate must be unreachable through the
      // canonical-graph tables.
      final approveNodeInserts = tx.executed
          .where((s) => s.sql.contains('insert into public.graph_nodes'))
          .map((s) => s.parameters['node_key'])
          .toList();
      expect(approveNodeInserts, isNot(contains('graphify:rejected_node')));

      // Audit log fan-out fires (FixedAuditLogsCutoverFlag(true) by
      // default in the production-shaped GraphRepository ctor).
      expect(
        stages.where((s) => s.contains('insert into public.audit_logs')),
        hasLength(4),
        reason: 'one fan-out per decision (1 reject + 1 approve node + '
            '2 approve/edit edges = 4)',
      );
    });

    test(
        'sets app.operator_id / location_id / user_id BEFORE the first '
        'business write',
        () async {
      final pool = _GraphPool(rowsByContains: <String, List<PostgresRow>>{
        'insert into public.graph_nodes': <PostgresRow>[
          <String, Object?>{'id': '00000000-0000-4000-9000-bbbbbbbbbbbb'},
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
        idempotencyKey: 'batch-set-local',
        decisions: <GraphCommitDecision>[
          _approveNode('graphify:n1'),
        ],
      );
      final stages =
          pool.transactions.single.executed.map((s) => s.sql).toList();
      final firstBusinessWrite = stages.indexWhere(
        (s) => s.contains('insert into public.graph_nodes'),
      );
      final operatorIdSet =
          stages.indexWhere((s) => s.contains('app.operator_id'));
      final locationIdSet =
          stages.indexWhere((s) => s.contains('app.location_id'));
      final userIdSet =
          stages.indexWhere((s) => s.contains('app.user_id'));

      expect(operatorIdSet, lessThan(firstBusinessWrite));
      expect(locationIdSet, lessThan(firstBusinessWrite));
      expect(userIdSet, lessThan(firstBusinessWrite));
    });

    test(
        'edge with unresolved endpoint (neither in prewarm cache nor '
        'in batch) raises 409 edge_endpoint_unresolved', () async {
      // Empty prewarm result + the batch carries no node decision the
      // edge could lean on → endpoint is unresolved.
      final pool = _GraphPool(rowsByContains: <String, List<PostgresRow>>{
        'select node_key, id::text as id': const <PostgresRow>[],
      });
      final repo = GraphRepository(TenantTransactionWrapper(pool));
      await expectLater(
        () => repo.commitBatch(
          tenantContext: _ctx(),
          graphScope: 'methodology',
          graphVersion: '1',
          graphifyVersion: 'v5',
          graphifySourceCommit: null,
          idempotencyKey: 'batch-orphan',
          decisions: <GraphCommitDecision>[
            _approveEdge(
              'graphify:orphan_edge',
              fromKey: 'graphify:phantom_a',
              toKey: 'graphify:phantom_b',
            ),
          ],
        ),
        throwsA(isA<GraphCommitBatchValidationError>()
            .having((e) => e.statusCode, 'statusCode', 409)
            .having((e) => e.code, 'code', 'edge_endpoint_unresolved')),
      );
    });

    test('empty batch raises 400 empty_batch before opening a transaction',
        () async {
      final pool = _GraphPool();
      final repo = GraphRepository(TenantTransactionWrapper(pool));
      await expectLater(
        () => repo.commitBatch(
          tenantContext: _ctx(),
          graphScope: 'methodology',
          graphVersion: '1',
          graphifyVersion: 'v5',
          graphifySourceCommit: null,
          idempotencyKey: 'batch-empty',
          decisions: const <GraphCommitDecision>[],
        ),
        throwsA(isA<GraphCommitBatchValidationError>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.code, 'code', 'empty_batch')),
      );
      expect(pool.transactions, isEmpty,
          reason: 'empty-batch validation must short-circuit before the '
              'transaction is opened');
    });

    test(
        'FixedAuditLogsCutoverFlag(false) skips the audit_logs fan-out '
        'but still writes canonical / audit rows', () async {
      final pool = _GraphPool(rowsByContains: <String, List<PostgresRow>>{
        'insert into public.graph_nodes': <PostgresRow>[
          <String, Object?>{'id': '00000000-0000-4000-9000-bbbbbbbbbbbb'},
        ],
        'insert into public.graphify_review_audit': <PostgresRow>[
          <String, Object?>{
            'audit_id': '00000000-0000-4000-9000-dddddddddddd',
          },
        ],
      });
      final repo = GraphRepository(
        TenantTransactionWrapper(pool),
        auditLogsCutoverFlag: const FixedAuditLogsCutoverFlag(false),
      );
      await repo.commitBatch(
        tenantContext: _ctx(),
        graphScope: 'methodology',
        graphVersion: '1',
        graphifyVersion: 'v5',
        graphifySourceCommit: null,
        idempotencyKey: 'batch-no-fanout',
        decisions: <GraphCommitDecision>[
          _approveNode('graphify:n1'),
          _rejectNode('graphify:n2'),
        ],
      );
      final stages =
          pool.transactions.single.executed.map((s) => s.sql).toList();
      // Canonical + audit rows still wrote.
      expect(
        stages.where((s) => s.contains('insert into public.graph_nodes')),
        hasLength(1),
      );
      expect(
        stages.where(
          (s) => s.contains('insert into public.graphify_review_audit'),
        ),
        hasLength(1),
      );
      // Audit-logs fan-out is gated off by the cutover flag.
      expect(
        stages.where((s) => s.contains('insert into public.audit_logs')),
        isEmpty,
        reason: 'cutover flag false must skip the global audit_logs '
            'hash-chain fan-out so the legacy path can run cleanly',
      );
    });

    test(
        'mixed batch inserts every node before any edge so the composite '
        'FK on graph_edges resolves', () async {
      final pool = _GraphPool(rowsByContains: <String, List<PostgresRow>>{
        // Edges in the batch reference nodes also in the batch — the
        // prewarm cache returns nothing.
        'select node_key, id::text as id': const <PostgresRow>[],
        'insert into public.graph_nodes': <PostgresRow>[
          <String, Object?>{'id': '00000000-0000-4000-9000-bbbbbbbbbbb1'},
        ],
        'insert into public.graph_edges': <PostgresRow>[
          <String, Object?>{'id': '00000000-0000-4000-9000-cccccccccccc'},
        ],
        'insert into public.audit_logs': <PostgresRow>[
          <String, Object?>{'id': '00000000-0000-4000-9000-eeeeeeeeeeee'},
        ],
      });
      final repo = GraphRepository(TenantTransactionWrapper(pool));
      // Caller hands in the edge BEFORE both node decisions so we
      // can prove the repository sorted them.
      await repo.commitBatch(
        tenantContext: _ctx(),
        graphScope: 'methodology',
        graphVersion: '1',
        graphifyVersion: 'v5',
        graphifySourceCommit: null,
        idempotencyKey: 'batch-fk-order',
        decisions: <GraphCommitDecision>[
          _approveEdge(
            'graphify:e1',
            fromKey: 'graphify:n1',
            toKey: 'graphify:n2',
          ),
          _approveNode('graphify:n1'),
          _approveNode('graphify:n2'),
        ],
      );
      final tx = pool.transactions.single;
      final inserts = tx.executed
          .map((s) => s.sql)
          .where((s) =>
              s.contains('insert into public.graph_nodes') ||
              s.contains('insert into public.graph_edges'))
          .toList();
      // First two writes are node inserts; only after both nodes
      // land does the edge insert fire.
      expect(inserts, hasLength(3));
      expect(inserts[0], contains('insert into public.graph_nodes'));
      expect(inserts[1], contains('insert into public.graph_nodes'));
      expect(inserts[2], contains('insert into public.graph_edges'),
          reason: 'composite FK on graph_edges (operator_id, graph_scope, '
              'graph_version, from_node_id) requires the node to exist '
              'before the edge insert hits — repository must sort');
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
