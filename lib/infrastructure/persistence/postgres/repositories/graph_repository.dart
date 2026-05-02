// Phase 11A.3b — GraphRepository.
//
// Persistence layer for the Graphify candidate review pipeline. The
// proxy's commit-batch route hands a batch of approve/reject/edit
// decisions to [GraphRepository.commitBatch], which writes the
// approved decisions into `public.graph_nodes` / `public.graph_edges`
// (canonical truth, created in 9.0Σ.i) and the rejected decisions
// into `public.graphify_review_audit` (created in 11A.3b). All work
// happens inside ONE `withTenant` transaction so a failure mid-batch
// rolls back atomically — the commit-batch contract promises the
// operator either every decision lands or none do.
//
// Hard rules carried from the slice prompt and CLAUDE.md:
//
//   1. **Approved → canonical only.** [_writeApprovedNode] and
//      [_writeApprovedEdge] are the only callsites that touch
//      `public.graph_nodes` / `public.graph_edges`. They are
//      private; nothing outside this file can route a non-approved
//      payload to canonical storage.
//
//   2. **Rejected → audit only.** [_writeRejection] is the only
//      callsite that touches `public.graphify_review_audit`. The
//      audit table has no FK back to canonical-graph rows, so
//      AGE traversal cannot reach a rejected candidate.
//
//   3. **One transaction per batch.** The whole decision list runs
//      inside one [withTenant] body. A failure mid-batch (e.g. a
//      duplicate `node_key` in the same `(operator_id, graph_scope,
//      graph_version)` tuple) rolls back every prior write. The
//      idempotency-key dedup at the proxy layer makes the retry
//      safe — same key returns the cached response from
//      `proxy_requests`.
//
//   4. **Composite-FK ordering.** `graph_edges` has composite FKs
//      back to `graph_nodes` within the same `(operator_id,
//      graph_scope, graph_version)` tuple. The repository sorts the
//      decision batch so all approved nodes insert first, then all
//      approved edges; otherwise an edge whose endpoints are both
//      approved in the same batch could fail the FK check on the
//      first edge insert because the node has not landed yet.
//
//   5. **Tenant defense, not BYPASSRLS.** Every write runs through
//      [withTenant], not [withSystem]. RLS policies on `graph_nodes`,
//      `graph_edges`, and `graphify_review_audit` enforce the
//      operator boundary even if the repository is buggy.
//
//   6. **Audit fan-out.** Every batch writes ONE row per rejection
//      to `public.audit_logs` (via [AuditLogsRepository]) so the
//      hash-chained system audit trail captures the rejection too
//      (the `graphify_review_audit` row is the rich payload; the
//      `audit_logs` row is the cross-walk pointer). The fan-out is
//      gated by [AuditLogsCutoverFlag] so demo / scaffold paths can
//      run without a `feature_flags` row.

import 'dart:convert';

import '../operator_scoped_repository.dart';
import '../postgres_executor.dart';
import '../tenant_context.dart';
import 'audit_logs_repository.dart';

/// Classification carried on every candidate decision. Mirrors the
/// Graphify-emitted `confidence` string label exactly so the proxy
/// can pass it through without re-bucketing.
enum GraphCandidateLabel {
  extracted('EXTRACTED'),
  inferred('INFERRED'),
  ambiguous('AMBIGUOUS');

  const GraphCandidateLabel(this.wireValue);
  final String wireValue;

  static GraphCandidateLabel fromWire(String value) {
    for (final label in GraphCandidateLabel.values) {
      if (label.wireValue == value) return label;
    }
    throw ArgumentError.value(
      value,
      'wireValue',
      'unknown GraphCandidateLabel',
    );
  }
}

/// Decision a super_admin made about a single candidate row in a
/// commit-batch. Approve writes to canonical; reject writes to audit;
/// edit writes the modified payload to canonical (we do not preserve
/// the unedited form — the unedited form lives in the source
/// graphify-out artifact, which is NOT production truth).
enum GraphDecisionKind { approve, reject, edit }

/// Kind of candidate. Hyperedges are fanned out into pairwise edges
/// at importer time, so the repository sees nodes and edges only.
enum GraphCandidateKind { node, edge }

/// One candidate decision passed into [GraphRepository.commitBatch].
/// The proxy builds these from the request body; tests build them
/// directly.
class GraphCommitDecision {
  const GraphCommitDecision({
    required this.kind,
    required this.decision,
    required this.candidateKey,
    required this.candidateType,
    required this.payload,
    required this.confidenceLabel,
    this.confidenceScore,
    this.sourceFile,
    this.sourceRef,
    this.fromNodeKey,
    this.toNodeKey,
    this.reason,
  }) : assert(
          (kind == GraphCandidateKind.edge &&
                  fromNodeKey != null &&
                  toNodeKey != null) ||
              kind == GraphCandidateKind.node,
          'edge decisions must carry from_node_key and to_node_key',
        );

  final GraphCandidateKind kind;
  final GraphDecisionKind decision;

  /// Stable producer key. Maps to `graph_nodes.node_key` /
  /// `graph_edges.edge_key` per spec line 227-229. Already prefixed
  /// with `graphify:` by the importer.
  final String candidateKey;

  /// Maps to `graph_nodes.node_type` / `graph_edges.edge_type` per
  /// spec line 231-236. Already normalized to the F&F vocabulary by
  /// the importer.
  final String candidateType;

  /// The payload body. For nodes this lands in `graph_nodes.properties`
  /// (or in `graphify_review_audit.candidate_payload` on rejection).
  /// For edges, the same — endpoints carry separately via
  /// [fromNodeKey] / [toNodeKey].
  final Map<String, Object?> payload;

  final GraphCandidateLabel confidenceLabel;
  final double? confidenceScore;
  final String? sourceFile;
  final String? sourceRef;

  /// Edge endpoint, only set when [kind] is [GraphCandidateKind.edge].
  /// References the producer's `node_key`; the repository resolves
  /// the actual `graph_nodes.id` via the unique
  /// `(operator_id, graph_scope, graph_version, node_key)` index
  /// before inserting the edge.
  final String? fromNodeKey;
  final String? toNodeKey;

  /// Optional reason captured on rejection ('not relevant', 'wrong
  /// vocabulary', etc.). Stored in `graphify_review_audit.reason`.
  final String? reason;
}

/// Outcome of a single decision inside a commit batch.
class GraphCommitDecisionOutcome {
  const GraphCommitDecisionOutcome({
    required this.decisionIndex,
    required this.candidateKey,
    required this.kind,
    required this.decision,
    required this.persistedRowId,
  });

  /// The 0-based index of this decision in the batch the caller
  /// passed in. Lets the UI scroll to the offender on a partial
  /// failure (though the transaction is atomic, so a partial
  /// failure rolls back the whole batch — the field is for
  /// success-side correlation).
  final int decisionIndex;
  final String candidateKey;
  final GraphCandidateKind kind;
  final GraphDecisionKind decision;

  /// `graph_nodes.id` / `graph_edges.id` for approve/edit, or
  /// `graphify_review_audit.audit_id` for reject.
  final String persistedRowId;
}

/// Top-level result returned by [GraphRepository.commitBatch].
class GraphCommitBatchResult {
  const GraphCommitBatchResult({
    required this.outcomes,
    required this.approvedNodeCount,
    required this.approvedEdgeCount,
    required this.rejectedCount,
  });

  final List<GraphCommitDecisionOutcome> outcomes;
  final int approvedNodeCount;
  final int approvedEdgeCount;
  final int rejectedCount;

  Map<String, Object?> toJson() => <String, Object?>{
        'approved_node_count': approvedNodeCount,
        'approved_edge_count': approvedEdgeCount,
        'rejected_count': rejectedCount,
        'outcomes': <Map<String, Object?>>[
          for (final o in outcomes)
            <String, Object?>{
              'decision_index': o.decisionIndex,
              'candidate_key': o.candidateKey,
              'kind': o.kind.name,
              'decision': o.decision.name,
              'persisted_row_id': o.persistedRowId,
            },
        ],
      };
}

/// Raised when the input batch is structurally invalid (e.g. an
/// edge decision references an endpoint key that is neither in
/// canonical storage nor approved earlier in the same batch). The
/// proxy maps this to a 400/409 with the failing decision index
/// embedded.
class GraphCommitBatchValidationError implements Exception {
  const GraphCommitBatchValidationError({
    required this.statusCode,
    required this.code,
    required this.message,
    required this.decisionIndex,
  });

  final int statusCode;
  final String code;
  final String message;
  final int decisionIndex;

  @override
  String toString() =>
      'GraphCommitBatchValidationError($statusCode/$code at #$decisionIndex): $message';
}

class GraphRepository extends OperatorScopedRepository {
  GraphRepository(
    super.tenantWrapper, {
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    AuditLogsCutoverFlag auditLogsCutoverFlag =
        const FixedAuditLogsCutoverFlag(true),
  })  : _auditLogs = auditLogsRepository,
        _auditLogsCutoverFlag = auditLogsCutoverFlag;

  final AuditLogsRepository _auditLogs;
  final AuditLogsCutoverFlag _auditLogsCutoverFlag;

  /// Commits a batch of approve/reject/edit decisions atomically.
  ///
  /// Approves and edits write to `public.graph_nodes` /
  /// `public.graph_edges` with full provenance per spec line 253-255
  /// (admin actor, approval timestamp, source doc, source ref,
  /// Graphify version). Rejects write to
  /// `public.graphify_review_audit` only. Both paths fan out to
  /// `public.audit_logs` for the global hash-chain.
  ///
  /// The whole batch runs inside one [withTenant] transaction. Any
  /// failure (uniqueness violation, FK violation, etc.) rolls back
  /// every prior write. Idempotency-key dedup at the proxy layer
  /// makes retry safe.
  Future<GraphCommitBatchResult> commitBatch({
    required TenantContext tenantContext,
    required String graphScope,
    required String graphVersion,
    required String graphifyVersion,
    required String? graphifySourceCommit,
    required String idempotencyKey,
    required List<GraphCommitDecision> decisions,
  }) async {
    if (decisions.isEmpty) {
      throw const GraphCommitBatchValidationError(
        statusCode: 400,
        code: 'empty_batch',
        message: 'commit-batch requires at least one decision',
        decisionIndex: -1,
      );
    }

    // Sort decisions: nodes first, then edges. Within each kind,
    // preserve the caller's order so the outcome list correlates 1:1
    // with the input. The composite FK on graph_edges requires the
    // node to exist before the edge insert hits.
    final indexed = <int, GraphCommitDecision>{
      for (var i = 0; i < decisions.length; i++) i: decisions[i],
    };
    final sortedIndices = indexed.keys.toList()
      ..sort((a, b) {
        final ka = indexed[a]!.kind == GraphCandidateKind.node ? 0 : 1;
        final kb = indexed[b]!.kind == GraphCandidateKind.node ? 0 : 1;
        if (ka != kb) return ka.compareTo(kb);
        return a.compareTo(b);
      });

    return withTenant<GraphCommitBatchResult>(tenantContext, (exec) async {
      final outcomes = <GraphCommitDecisionOutcome>[];
      var approvedNodes = 0;
      var approvedEdges = 0;
      var rejected = 0;

      // Cache of node_key → graph_nodes.id resolved within this
      // batch. Lets an edge reference a node approved earlier in
      // the same batch without a second DB round-trip.
      final nodeIdCache = <String, String>{};

      // Pre-warm the cache with any nodes the edges in this batch
      // might reference (so we can resolve edges that point at
      // pre-existing canonical nodes without N+1 lookups).
      final referencedNodeKeys = <String>{
        for (final d in decisions)
          if (d.kind == GraphCandidateKind.edge &&
              d.decision != GraphDecisionKind.reject) ...[
            d.fromNodeKey!,
            d.toNodeKey!,
          ],
      };
      if (referencedNodeKeys.isNotEmpty) {
        final rows = await exec.query(
          'select node_key, id::text as id '
          'from public.graph_nodes '
          'where operator_id = @operator_id::uuid '
          'and graph_scope = @graph_scope '
          'and graph_version = @graph_version '
          'and node_key = any(@keys::text[])',
          parameters: <String, Object?>{
            'operator_id': tenantContext.operatorId,
            'graph_scope': graphScope,
            'graph_version': graphVersion,
            'keys': referencedNodeKeys.toList(),
          },
        );
        for (final row in rows) {
          nodeIdCache[row['node_key']! as String] = row['id']! as String;
        }
      }

      final auditLogsEnabled = await _auditLogsCutoverFlag.isEnabled(exec);

      for (final originalIndex in sortedIndices) {
        final decision = indexed[originalIndex]!;

        if (decision.decision == GraphDecisionKind.reject) {
          final auditId = await _writeRejection(
            exec,
            tenantContext: tenantContext,
            decision: decision,
            graphScope: graphScope,
            graphVersion: graphVersion,
            idempotencyKey: idempotencyKey,
          );
          if (auditLogsEnabled) {
            await _fanOutToAuditLogs(
              exec,
              tenantContext: tenantContext,
              action: 'admin.corpus.graph_candidate.rejected',
              targetId: auditId,
              payload: <String, Object?>{
                'audit_id': auditId,
                'candidate_kind': decision.kind.name,
                'candidate_key': decision.candidateKey,
                'graph_scope': graphScope,
                'graph_version': graphVersion,
                'idempotency_key': idempotencyKey,
              },
            );
          }
          outcomes.add(
            GraphCommitDecisionOutcome(
              decisionIndex: originalIndex,
              candidateKey: decision.candidateKey,
              kind: decision.kind,
              decision: decision.decision,
              persistedRowId: auditId,
            ),
          );
          rejected += 1;
          continue;
        }

        // Approve or edit — both write to canonical.
        if (decision.kind == GraphCandidateKind.node) {
          final nodeId = await _writeApprovedNode(
            exec,
            tenantContext: tenantContext,
            decision: decision,
            graphScope: graphScope,
            graphVersion: graphVersion,
            graphifyVersion: graphifyVersion,
            graphifySourceCommit: graphifySourceCommit,
          );
          nodeIdCache[decision.candidateKey] = nodeId;
          if (auditLogsEnabled) {
            await _fanOutToAuditLogs(
              exec,
              tenantContext: tenantContext,
              action: 'admin.corpus.graph_candidate.approved_node',
              targetId: nodeId,
              payload: <String, Object?>{
                'node_id': nodeId,
                'node_key': decision.candidateKey,
                'graph_scope': graphScope,
                'graph_version': graphVersion,
                'idempotency_key': idempotencyKey,
              },
            );
          }
          outcomes.add(
            GraphCommitDecisionOutcome(
              decisionIndex: originalIndex,
              candidateKey: decision.candidateKey,
              kind: decision.kind,
              decision: decision.decision,
              persistedRowId: nodeId,
            ),
          );
          approvedNodes += 1;
          continue;
        }

        // Edge.
        final fromKey = decision.fromNodeKey!;
        final toKey = decision.toNodeKey!;
        final fromNodeId = nodeIdCache[fromKey];
        final toNodeId = nodeIdCache[toKey];
        if (fromNodeId == null || toNodeId == null) {
          final missing = fromNodeId == null ? fromKey : toKey;
          throw GraphCommitBatchValidationError(
            statusCode: 409,
            code: 'edge_endpoint_unresolved',
            message:
                'edge candidate ${decision.candidateKey} references '
                'node_key $missing which is neither in canonical storage '
                'nor approved earlier in this batch',
            decisionIndex: originalIndex,
          );
        }
        final edgeId = await _writeApprovedEdge(
          exec,
          tenantContext: tenantContext,
          decision: decision,
          graphScope: graphScope,
          graphVersion: graphVersion,
          graphifyVersion: graphifyVersion,
          graphifySourceCommit: graphifySourceCommit,
          fromNodeId: fromNodeId,
          toNodeId: toNodeId,
        );
        if (auditLogsEnabled) {
          await _fanOutToAuditLogs(
            exec,
            tenantContext: tenantContext,
            action: 'admin.corpus.graph_candidate.approved_edge',
            targetId: edgeId,
            payload: <String, Object?>{
              'edge_id': edgeId,
              'edge_key': decision.candidateKey,
              'graph_scope': graphScope,
              'graph_version': graphVersion,
              'idempotency_key': idempotencyKey,
            },
          );
        }
        outcomes.add(
          GraphCommitDecisionOutcome(
            decisionIndex: originalIndex,
            candidateKey: decision.candidateKey,
            kind: decision.kind,
            decision: decision.decision,
            persistedRowId: edgeId,
          ),
        );
        approvedEdges += 1;
      }

      // Re-sort outcomes back to the caller's input order so the
      // response correlates 1:1 with the request batch.
      outcomes.sort((a, b) => a.decisionIndex.compareTo(b.decisionIndex));

      return GraphCommitBatchResult(
        outcomes: outcomes,
        approvedNodeCount: approvedNodes,
        approvedEdgeCount: approvedEdges,
        rejectedCount: rejected,
      );
    });
  }

  // ─── private writers ─────────────────────────────────────────────

  /// Inserts one approved node into `public.graph_nodes` with full
  /// provenance per spec line 253-255. Returns the inserted `id`.
  Future<String> _writeApprovedNode(
    PostgresExecutor exec, {
    required TenantContext tenantContext,
    required GraphCommitDecision decision,
    required String graphScope,
    required String graphVersion,
    required String graphifyVersion,
    required String? graphifySourceCommit,
  }) async {
    final properties = <String, Object?>{
      ...decision.payload,
      'graphify_version': graphifyVersion,
      if (graphifySourceCommit != null)
        'graphify_source_commit': graphifySourceCommit,
      if (decision.sourceFile != null) 'source_file': decision.sourceFile,
      if (decision.sourceRef != null) 'source_provenance_ref': decision.sourceRef,
      'approved_by': tenantContext.userId,
      'approved_at': DateTime.now().toUtc().toIso8601String(),
      'confidence_label': decision.confidenceLabel.wireValue,
      'decision_kind': decision.decision.name,
    };
    final rows = await exec.query(
      'insert into public.graph_nodes ('
      'operator_id, location_id, graph_scope, graph_version, '
      'node_key, node_type, confidence, source, source_ref, properties) '
      'values ('
      '@operator_id::uuid, @location_id::uuid, '
      '@graph_scope, @graph_version, '
      '@node_key, @node_type, @confidence::numeric, '
      '@source, @source_ref, @properties::jsonb) '
      'returning id::text as id',
      parameters: <String, Object?>{
        'operator_id': tenantContext.operatorId,
        'location_id': tenantContext.locationId,
        'graph_scope': graphScope,
        'graph_version': graphVersion,
        'node_key': decision.candidateKey,
        'node_type': decision.candidateType,
        'confidence': decision.confidenceScore,
        'source': 'graphify',
        'source_ref': decision.sourceRef,
        'properties': jsonEncode(properties),
      },
    );
    return rows.single['id']! as String;
  }

  /// Inserts one approved edge into `public.graph_edges`. Endpoints
  /// resolved to canonical `graph_nodes.id` by the caller.
  Future<String> _writeApprovedEdge(
    PostgresExecutor exec, {
    required TenantContext tenantContext,
    required GraphCommitDecision decision,
    required String graphScope,
    required String graphVersion,
    required String graphifyVersion,
    required String? graphifySourceCommit,
    required String fromNodeId,
    required String toNodeId,
  }) async {
    final properties = <String, Object?>{
      ...decision.payload,
      'graphify_version': graphifyVersion,
      if (graphifySourceCommit != null)
        'graphify_source_commit': graphifySourceCommit,
      if (decision.sourceFile != null) 'source_file': decision.sourceFile,
      if (decision.sourceRef != null) 'source_provenance_ref': decision.sourceRef,
      'approved_by': tenantContext.userId,
      'approved_at': DateTime.now().toUtc().toIso8601String(),
      'confidence_label': decision.confidenceLabel.wireValue,
      'decision_kind': decision.decision.name,
      'from_node_key': decision.fromNodeKey,
      'to_node_key': decision.toNodeKey,
    };
    final rows = await exec.query(
      'insert into public.graph_edges ('
      'operator_id, location_id, graph_scope, graph_version, '
      'edge_key, edge_type, from_node_id, to_node_id, '
      'confidence, source, source_ref, properties) '
      'values ('
      '@operator_id::uuid, @location_id::uuid, '
      '@graph_scope, @graph_version, '
      '@edge_key, @edge_type, @from_node_id::uuid, @to_node_id::uuid, '
      '@confidence::numeric, @source, @source_ref, @properties::jsonb) '
      'returning id::text as id',
      parameters: <String, Object?>{
        'operator_id': tenantContext.operatorId,
        'location_id': tenantContext.locationId,
        'graph_scope': graphScope,
        'graph_version': graphVersion,
        'edge_key': decision.candidateKey,
        'edge_type': decision.candidateType,
        'from_node_id': fromNodeId,
        'to_node_id': toNodeId,
        'confidence': decision.confidenceScore,
        'source': 'graphify',
        'source_ref': decision.sourceRef,
        'properties': jsonEncode(properties),
      },
    );
    return rows.single['id']! as String;
  }

  /// Inserts one rejection row into `public.graphify_review_audit`.
  /// Returns the inserted `audit_id`. NEVER touches canonical-graph
  /// tables — the audit table has zero FKs back to them by design,
  /// so AGE traversal physically cannot reach a rejected candidate.
  Future<String> _writeRejection(
    PostgresExecutor exec, {
    required TenantContext tenantContext,
    required GraphCommitDecision decision,
    required String graphScope,
    required String graphVersion,
    required String idempotencyKey,
  }) async {
    final auditPayload = <String, Object?>{
      ...decision.payload,
      'candidate_key': decision.candidateKey,
      'candidate_type': decision.candidateType,
      if (decision.fromNodeKey != null) 'from_node_key': decision.fromNodeKey,
      if (decision.toNodeKey != null) 'to_node_key': decision.toNodeKey,
    };
    final rows = await exec.query(
      'insert into public.graphify_review_audit ('
      'operator_id, location_id, decided_by, decision, reason, '
      'candidate_kind, candidate_payload, '
      'target_graph_scope, target_graph_version, '
      'source_file, source_ref, '
      'confidence_label, confidence_score, idempotency_key) '
      'values ('
      '@operator_id::uuid, @location_id::uuid, @decided_by::uuid, '
      '@decision, @reason, '
      '@candidate_kind, @candidate_payload::jsonb, '
      '@target_graph_scope, @target_graph_version, '
      '@source_file, @source_ref, '
      '@confidence_label, @confidence_score::numeric, '
      '@idempotency_key) '
      'returning audit_id::text as audit_id',
      parameters: <String, Object?>{
        'operator_id': tenantContext.operatorId,
        'location_id': tenantContext.locationId,
        'decided_by': tenantContext.userId,
        'decision': decision.decision == GraphDecisionKind.edit
            ? 'edited_then_rejected'
            : 'rejected',
        'reason': decision.reason,
        'candidate_kind': decision.kind.name,
        'candidate_payload': jsonEncode(auditPayload),
        'target_graph_scope': graphScope,
        'target_graph_version': graphVersion,
        'source_file': decision.sourceFile,
        'source_ref': decision.sourceRef,
        'confidence_label': decision.confidenceLabel.wireValue,
        'confidence_score': decision.confidenceScore,
        'idempotency_key': idempotencyKey,
      },
    );
    return rows.single['audit_id']! as String;
  }

  Future<void> _fanOutToAuditLogs(
    PostgresExecutor exec, {
    required TenantContext tenantContext,
    required String action,
    required String targetId,
    required Map<String, Object?> payload,
  }) {
    final actorUserId = tenantContext.userId;
    if (actorUserId == null) {
      // No human actor — skip fan-out. The graphify_review_audit /
      // graph_nodes row still lands; we just do not write a global
      // audit_logs row because audit_logs requires a non-null actor
      // identifier per the actor_shape_check constraint and we have
      // no service-principal id either.
      return Future<void>.value();
    }
    return _auditLogs.writeRow(
      exec,
      operatorId: tenantContext.operatorId,
      locationId: tenantContext.locationId,
      actorKind: 'user',
      actorUserId: actorUserId,
      targetKind: action.contains('rejected')
          ? 'graphify_review_audit'
          : action.contains('node')
              ? 'graph_node'
              : 'graph_edge',
      targetId: targetId,
      action: action,
      payload: payload,
    );
  }
}
