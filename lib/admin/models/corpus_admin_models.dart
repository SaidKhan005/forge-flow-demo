// Phase 11A.3a - Corpus admin value objects.
//
// Carries the corpus snapshot the admin Corpus screen needs to render
// + commit + rollback. Mirrors the post-11A.3a Postgres shape:
//
//   * `corpus_versions` ledger
//     (`db/migrations/202605010000_phase_11A_3a_corpus_versions_ledger.sql`).
//   * `advisor_source_chunks` cloud-foundation rows
//     (`db/migrations/202604250001_advisor_corpus_storage_schema.sql`)
//     with the new `version_id` / `superseded_at` columns.
//
// Decisions intentionally NOT made here (per Block 3 hard
// constraints):
//
//   * Plaintext markdown never lives in this model. The admin screen
//     uploads bytes through the proxy; the proxy-side pipeline does
//     the chunking and embedding. The client only ever sees the
//     resulting [ChunkPreview] payloads.
//   * Voyage / Anthropic calls happen server-side. The demo gateway
//     simulates the chunking step so kDemoMode walkthroughs run
//     without a live provider.

import 'package:flutter/foundation.dart';

/// Snapshot of one corpus version row plus the chunks attached to it.
@immutable
class CorpusBundle {
  const CorpusBundle({required this.version, required this.chunks});

  final CorpusVersionRef version;
  final List<ChunkPreview> chunks;

  static CorpusBundle fromJson(Map<String, Object?> json) {
    final v = (json['version'] as Map).cast<String, Object?>();
    final chunks = (json['chunks'] as List?) ?? const [];
    return CorpusBundle(
      version: CorpusVersionRef.fromJson(v),
      chunks: <ChunkPreview>[
        for (final c in chunks)
          ChunkPreview.fromJson((c as Map).cast<String, Object?>()),
      ],
    );
  }
}

/// One row in the `corpus_versions` ledger.
@immutable
class CorpusVersionRef {
  const CorpusVersionRef({
    required this.versionId,
    required this.createdBy,
    required this.createdAt,
    required this.summary,
    required this.rollbackOf,
    required this.supersededAt,
    required this.chunkCount,
  });

  final String versionId;
  final String? createdBy;
  final DateTime createdAt;
  final String summary;
  final String? rollbackOf;
  final DateTime? supersededAt;
  final int chunkCount;

  bool get isCurrent => supersededAt == null;

  static CorpusVersionRef fromJson(Map<String, Object?> json) {
    return CorpusVersionRef(
      versionId: json['version_id']! as String,
      createdBy: json['created_by'] as String?,
      createdAt: DateTime.parse(json['created_at']! as String),
      summary: (json['summary'] as String?) ?? '',
      rollbackOf: json['rollback_of'] as String?,
      supersededAt: json['superseded_at'] is String
          ? DateTime.parse(json['superseded_at']! as String)
          : null,
      chunkCount: (json['chunk_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Per-chunk projection used by the preview pane. Carries enough text
/// for the admin to skim what's in the chunk before committing without
/// shipping the entire markdown source through the wire.
@immutable
class ChunkPreview {
  const ChunkPreview({
    required this.chunkId,
    required this.docId,
    required this.sourcePath,
    required this.headingPath,
    required this.snippet,
    required this.estimatedTokens,
    required this.riskLevel,
    required this.contentSha256,
    required this.versionId,
    required this.active,
  });

  final String chunkId;
  final String docId;
  final String sourcePath;
  final List<String> headingPath;

  /// First ~280 characters of the chunk text. The full text never
  /// leaves the proxy; the admin reviews structure + risk level + the
  /// hash, not full bodies.
  final String snippet;

  final int estimatedTokens;
  final String riskLevel;
  final String contentSha256;
  final String? versionId;
  final bool active;

  static ChunkPreview fromJson(Map<String, Object?> json) {
    final raw = json['heading_path'];
    final heading = <String>[if (raw is List) ...raw.whereType<String>()];
    return ChunkPreview(
      chunkId: json['chunk_id']! as String,
      docId: json['doc_id']! as String,
      sourcePath: json['source_path']! as String,
      headingPath: heading,
      snippet: (json['snippet'] as String?) ?? '',
      estimatedTokens: (json['estimated_tokens'] as num?)?.toInt() ?? 0,
      riskLevel: (json['risk_level'] as String?) ?? 'unknown',
      contentSha256: (json['content_sha256'] as String?) ?? '',
      versionId: json['version_id'] as String?,
      active: (json['active'] as bool?) ?? true,
    );
  }
}

/// Difference computed by the proxy between the staged upload and
/// the current active corpus. The admin reviews this before deciding
/// whether to commit.
@immutable
class CorpusDiff {
  const CorpusDiff({
    required this.previewToken,
    required this.added,
    required this.modified,
    required this.inactivated,
    required this.summary,
  });

  /// Server-side handle for the staged upload. The admin sends this
  /// back on `commit` so the proxy can resolve the same staged set
  /// without re-uploading the source markdown. Demo gateway treats
  /// this as an opaque key into its in-memory pending bundle.
  final String previewToken;

  final List<ChunkPreview> added;
  final List<ChunkPreview> modified;
  final List<ChunkPreview> inactivated;

  /// Auto-generated summary the admin can edit before commit.
  final String summary;

  int get totalChanges => added.length + modified.length + inactivated.length;

  static CorpusDiff fromJson(Map<String, Object?> json) {
    final added = (json['added'] as List?) ?? const [];
    final modified = (json['modified'] as List?) ?? const [];
    final inactivated = (json['inactivated'] as List?) ?? const [];
    return CorpusDiff(
      previewToken: json['preview_token']! as String,
      added: <ChunkPreview>[
        for (final c in added)
          ChunkPreview.fromJson((c as Map).cast<String, Object?>()),
      ],
      modified: <ChunkPreview>[
        for (final c in modified)
          ChunkPreview.fromJson((c as Map).cast<String, Object?>()),
      ],
      inactivated: <ChunkPreview>[
        for (final c in inactivated)
          ChunkPreview.fromJson((c as Map).cast<String, Object?>()),
      ],
      summary: (json['summary'] as String?) ?? '',
    );
  }
}

/// Upload command. The admin drops a markdown file (or a small
/// archive) on the screen; the gateway translates that into a
/// multipart upload in the HTTP variant. Demo gateways simulate the
/// server-side chunking against an in-memory fixture so the
/// walkthrough click path runs without Voyage / Anthropic.
@immutable
class UploadCommand {
  const UploadCommand({
    required this.fileName,
    required this.contentType,
    required this.bytes,
    required this.idempotencyKey,
  });

  final String fileName;
  final String contentType;
  final List<int> bytes;

  /// Caller-supplied idempotency key. Forwarded as the
  /// `Idempotency-Key` header so a retry returns the same preview
  /// token instead of re-staging the upload.
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'file_name': fileName,
    'content_type': contentType,
    'idempotency_key': idempotencyKey,
  };
}

/// Commit command. The proxy resolves [previewToken] back to the
/// staged upload and writes the corpus_versions ledger row plus the
/// new chunks under the same idempotency key.
@immutable
class CommitCommand {
  const CommitCommand({
    required this.previewToken,
    required this.summary,
    required this.idempotencyKey,
  });

  final String previewToken;
  final String summary;
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'preview_token': previewToken,
    'summary': summary,
  };
}

/// Rollback command. The proxy writes a fresh corpus_versions row
/// whose `rollback_of` points at [targetVersionId] and re-points the
/// active corpus at the rolled-back chunk set. The idempotency key
/// makes the operation safe to retry on a flaky network.
@immutable
class RollbackCommand {
  const RollbackCommand({
    required this.targetVersionId,
    required this.summary,
    required this.idempotencyKey,
  });

  final String targetVersionId;
  final String summary;
  final String idempotencyKey;

  Map<String, Object?> toJson() => <String, Object?>{
    'target_version_id': targetVersionId,
    'summary': summary,
  };
}

/// Maximum bytes a markdown upload may carry. The admin pipeline
/// keeps small structured corpora (methodology seeds, SOPs); a single
/// upload over a megabyte is almost certainly a binary mistake. The
/// client checks first so the user sees a clean banner instead of a
/// 413 from the proxy.
const int kCorpusUploadMaxBytes = 1 * 1024 * 1024;

/// Markdown content types the screen accepts. Anything else is
/// rejected client-side with a `binary_or_unsupported_file` error.
/// The proxy enforces the same allowlist server-side.
const Set<String> kCorpusUploadAcceptedContentTypes = <String>{
  'text/markdown',
  'text/plain',
  'application/octet-stream',
};

// ─── Phase 11A.3b - Graphify candidate review ────────────────────────
//
// Models for the new `Graph candidates` tab on the Corpus Admin
// screen. The flow is:
//
//   1. The F&F build tool (`tool/advisor_corpus prepare-graphify-
//      candidates`) reads `graphify-out/graph.json` and emits
//      deterministic JSONL artifacts under `graphify-out/candidates/`.
//      The proxy loads those artifacts on demand to feed the admin
//      review screen.
//
//   2. The screen lists candidates grouped by Graphify-emitted
//      classification (`EXTRACTED` → batch-approvable per spec line
//      246-247; `INFERRED` → per-edge approve required per spec line
//      248; `AMBIGUOUS` → debug-only until edited per spec line 249).
//
//   3. The super_admin marks each candidate approve / reject / edit,
//      then commits the batch. Approved decisions land in canonical
//      `public.graph_nodes` / `public.graph_edges`; rejected
//      decisions land in `public.graphify_review_audit` only.
//
// Hard constraints from the slice prompt:
//
//   * `graphify-out/graph.json` is NOT shipped as production truth.
//     The screen never reads it directly; the proxy mediates every
//     access.
//   * Confidence < 0.7 is flagged with a warning chip; the threshold
//     is captured in [kGraphCandidateConfidenceWarningThreshold].

/// Confidence threshold below which the screen renders a warning
/// chip. Spec hard-pins this at 0.7 (Block 3 task list, "Confidence
/// chip: warn when score < 0.7").
const double kGraphCandidateConfidenceWarningThreshold = 0.7;

/// Graphify-emitted bucket label. The producer emits these strings
/// directly in `graph.json`; the F&F admin trusts them as the bucket
/// rather than re-classifying from the numeric `confidence_score`.
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

/// Whether a candidate proposes a node or an edge. Hyperedges are
/// fanned out to pairwise edges by the importer, so the admin sees
/// nodes and edges only.
enum GraphCandidateKind { node, edge }

/// One Graphify-derived graph candidate as the admin sees it. Carries
/// just enough payload for the screen to render the diff card and
/// route the decision back to the proxy.
@immutable
class GraphCandidate {
  const GraphCandidate({
    required this.candidateId,
    required this.kind,
    required this.candidateKey,
    required this.candidateType,
    required this.label,
    required this.confidenceScore,
    required this.sourceFile,
    required this.sourceRef,
    required this.payload,
    this.fromNodeKey,
    this.toNodeKey,
  });

  /// Stable identifier the proxy uses to correlate decisions with
  /// candidate rows. Generated by the importer from the candidate
  /// kind + key so a re-run produces the same id.
  final String candidateId;
  final GraphCandidateKind kind;

  /// Stable producer key. Maps to `graph_nodes.node_key` /
  /// `graph_edges.edge_key`; already prefixed with `graphify:` per
  /// spec line 227-229.
  final String candidateKey;

  /// Maps to `graph_nodes.node_type` / `graph_edges.edge_type`,
  /// already normalized to the F&F vocabulary by the importer
  /// per spec line 231-236.
  final String candidateType;

  final GraphCandidateLabel label;
  final double? confidenceScore;
  final String? sourceFile;
  final String? sourceRef;

  /// Body payload - properties JSONB on canonical insert, or full
  /// audit payload on rejection. The screen surfaces the
  /// `label` field here (Graphify's display label) when present so
  /// the admin sees something meaningful in the list view.
  final Map<String, Object?> payload;

  /// Edge endpoints, set only when [kind] is [GraphCandidateKind.edge].
  final String? fromNodeKey;
  final String? toNodeKey;

  bool get hasLowConfidence =>
      confidenceScore != null &&
      confidenceScore! < kGraphCandidateConfidenceWarningThreshold;

  /// Display-friendly label pulled from the payload when present;
  /// falls back to the candidate key.
  String get displayLabel {
    final raw = payload['label'];
    if (raw is String && raw.trim().isNotEmpty) return raw;
    return candidateKey;
  }

  static GraphCandidate fromJson(Map<String, Object?> json) {
    return GraphCandidate(
      candidateId: json['candidate_id']! as String,
      kind: GraphCandidateKind.values.firstWhere(
        (k) => k.name == json['kind'],
        orElse: () => GraphCandidateKind.node,
      ),
      candidateKey: json['candidate_key']! as String,
      candidateType: json['candidate_type']! as String,
      label: GraphCandidateLabel.fromWire(json['label']! as String),
      confidenceScore: (json['confidence_score'] as num?)?.toDouble(),
      sourceFile: json['source_file'] as String?,
      sourceRef: json['source_ref'] as String?,
      fromNodeKey: json['from_node_key'] as String?,
      toNodeKey: json['to_node_key'] as String?,
      payload:
          ((json['payload'] as Map?)?.cast<String, Object?>()) ??
          const <String, Object?>{},
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'candidate_id': candidateId,
    'kind': kind.name,
    'candidate_key': candidateKey,
    'candidate_type': candidateType,
    'label': label.wireValue,
    if (confidenceScore != null) 'confidence_score': confidenceScore,
    if (sourceFile != null) 'source_file': sourceFile,
    if (sourceRef != null) 'source_ref': sourceRef,
    if (fromNodeKey != null) 'from_node_key': fromNodeKey,
    if (toNodeKey != null) 'to_node_key': toNodeKey,
    'payload': payload,
  };
}

/// The diff the proxy returns from `GET /v1/admin/corpus/graph-
/// candidates`. Three buckets matching the spec's approval rules.
@immutable
class GraphCandidateDiff {
  const GraphCandidateDiff({
    required this.graphScope,
    required this.graphVersion,
    required this.graphifyVersion,
    required this.graphifySourceCommit,
    required this.extracted,
    required this.inferred,
    required this.ambiguous,
  });

  /// Target `graph_scope` an approval would write to. The proxy
  /// pulls this from the build-tool manifest (defaults to
  /// `methodology` for the launch slice).
  final String graphScope;

  /// Target `graph_version` an approval would write to.
  final String graphVersion;

  /// Graphify package / commit version the candidates were produced
  /// from. Mirrored into `graph_nodes.properties` /
  /// `graph_edges.properties` on approval per spec line 254.
  final String graphifyVersion;
  final String? graphifySourceCommit;

  final List<GraphCandidate> extracted;
  final List<GraphCandidate> inferred;
  final List<GraphCandidate> ambiguous;

  int get totalCount => extracted.length + inferred.length + ambiguous.length;

  static GraphCandidateDiff fromJson(Map<String, Object?> json) {
    List<GraphCandidate> readBucket(String key) {
      final list = (json[key] as List?) ?? const <Object?>[];
      return <GraphCandidate>[
        for (final entry in list)
          GraphCandidate.fromJson((entry as Map).cast<String, Object?>()),
      ];
    }

    return GraphCandidateDiff(
      graphScope: (json['graph_scope'] as String?) ?? 'methodology',
      graphVersion: (json['graph_version'] as String?) ?? '1',
      graphifyVersion: (json['graphify_version'] as String?) ?? 'unknown',
      graphifySourceCommit: json['graphify_source_commit'] as String?,
      extracted: readBucket('extracted'),
      inferred: readBucket('inferred'),
      ambiguous: readBucket('ambiguous'),
    );
  }
}

/// One decision the admin made about a single candidate. The
/// commit-batch endpoint takes a list of these.
enum GraphDecisionKind { approve, reject, edit }

@immutable
class ApprovalDecision {
  const ApprovalDecision({
    required this.candidateId,
    required this.kind,
    this.editedPayload,
    this.editedCandidateType,
    this.reason,
  });

  /// Matches the candidate's [GraphCandidate.candidateId] from the
  /// most recent diff load. The proxy resolves the id back to the
  /// staged candidate without trusting the client-supplied payload
  /// for anything except the optional edit field.
  final String candidateId;
  final GraphDecisionKind kind;

  /// Replacement properties body for an `edit` decision. NULL for
  /// approve / reject. The proxy validates that this is provided
  /// when `kind == edit`.
  final Map<String, Object?>? editedPayload;

  /// Replacement node_type / edge_type for an `edit` decision. The
  /// admin can re-bucket a candidate (e.g. ambiguous → CONTAINS) by
  /// setting this. NULL falls back to the original candidate type.
  final String? editedCandidateType;

  /// Optional rejection reason captured for the audit row.
  final String? reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'candidate_id': candidateId,
    'kind': kind.name,
    if (editedPayload != null) 'edited_payload': editedPayload,
    if (editedCandidateType != null)
      'edited_candidate_type': editedCandidateType,
    if (reason != null) 'reason': reason,
  };
}

/// Top-level batch commit command. The admin queues decisions in the
/// screen's tray and submits the whole batch atomically. Carries the
/// (operator, location) the approved candidates land in - super_admin
/// is cross-tenant so the destination is an explicit per-batch choice
/// (the proxy route's `target_operator_id` / `target_location_id`
/// body fields).
@immutable
class BatchCommitCommand {
  const BatchCommitCommand({
    required this.idempotencyKey,
    required this.targetOperatorId,
    required this.targetLocationId,
    required this.decisions,
  });

  final String idempotencyKey;
  final String targetOperatorId;
  final String targetLocationId;
  final List<ApprovalDecision> decisions;

  Map<String, Object?> toJson() => <String, Object?>{
    'target_operator_id': targetOperatorId,
    'target_location_id': targetLocationId,
    'decisions': <Map<String, Object?>>[for (final d in decisions) d.toJson()],
  };
}

/// Result returned by the proxy after a successful batch commit.
@immutable
class BatchCommitResult {
  const BatchCommitResult({
    required this.approvedNodeCount,
    required this.approvedEdgeCount,
    required this.rejectedCount,
  });

  final int approvedNodeCount;
  final int approvedEdgeCount;
  final int rejectedCount;

  int get totalCount => approvedNodeCount + approvedEdgeCount + rejectedCount;

  static BatchCommitResult fromJson(Map<String, Object?> json) {
    return BatchCommitResult(
      approvedNodeCount: (json['approved_node_count'] as num?)?.toInt() ?? 0,
      approvedEdgeCount: (json['approved_edge_count'] as num?)?.toInt() ?? 0,
      rejectedCount: (json['rejected_count'] as num?)?.toInt() ?? 0,
    );
  }
}
