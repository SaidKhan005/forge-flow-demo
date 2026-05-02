// Phase 11A.3a — Corpus admin gateway.
//
// Translates the corpus screen's commands into proxy
// `/v1/admin/corpus/*` HTTP calls. The admin Flutter client never
// holds a Postgres connection string and never reaches the database
// directly — every read/write flows through the F&F admin proxy.
//
// Two implementations ship in this slice:
//
//   * [HttpCorpusAdminGateway] — production. GET/POST/PUT against the
//     proxy with the signed-in admin's bearer token. Mutations carry
//     an `Idempotency-Key` header so the proxy can dedupe retries.
//
//   * [InMemoryCorpusAdminGateway] — demo + widget tests. Mutates an
//     in-memory ledger so the admin screen runs end-to-end in
//     `kDemoMode` without Voyage / Anthropic / Postgres.
//
// Payload shapes mirror the proxy contract documented in
// `tool/advisor_proxy/advisor_proxy.dart` 11A.3a route handlers.

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/corpus_admin_models.dart';

/// Source for the bearer token the gateway attaches to every proxy
/// call. Production binds this to the admin Firebase ID-token stream;
/// tests pin a synthetic value.
typedef CorpusAdminBearerTokenProvider = Future<String> Function();

class CorpusAdminGatewayError implements Exception {
  const CorpusAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'CorpusAdminGatewayError($statusCode/$errorCode): $message';
}

abstract class CorpusAdminGateway {
  /// Lists every `corpus_versions` row, current-first.
  Future<List<CorpusVersionRef>> listVersions();

  /// Loads the chunks for one corpus version (current or prior).
  Future<CorpusBundle> fetchVersion({required String versionId});

  /// Stages the upload server-side and returns a diff against the
  /// active corpus. The diff carries a `preview_token` the admin
  /// hands back to [commitVersion].
  Future<CorpusDiff> previewDiff(UploadCommand command);

  /// Commits the staged upload as a new corpus version.
  Future<CorpusVersionRef> commitVersion(CommitCommand command);

  /// Rolls back to a prior version. Writes a fresh corpus_versions
  /// row pointing at the target.
  Future<CorpusVersionRef> rollbackToVersion(RollbackCommand command);

  // ─── Phase 11A.3b — Graphify candidate review ──────────────────

  /// Loads the current Graphify candidate diff. The proxy applies
  /// the corpus_manifest scope filter again as defense-in-depth, so
  /// every candidate returned here references an in-scope source
  /// document. Used by both super_admin (mutates) and ff_support
  /// (read-only) — the role gate sits server-side.
  Future<GraphCandidateDiff> listGraphCandidates();

  /// Commits a batch of approve/reject/edit decisions atomically.
  /// Returns the per-bucket counts of what landed.
  Future<BatchCommitResult> commitGraphCandidatesBatch(
    BatchCommitCommand command,
  );

  /// Triggers an AGE projection rebuild against the canonical
  /// graph tables. The launch slice ships a 501 stub on the
  /// proxy; the screen surfaces the response message in a banner so
  /// the operator knows the button is wired but the rebuild infra
  /// is not yet enabled.
  Future<AgeRebuildResult> requestAgeRebuild({required String idempotencyKey});
}

/// Result returned by [CorpusAdminGateway.requestAgeRebuild]. A 501
/// stub from the proxy projects through with [implemented] = false.
@immutable
class AgeRebuildResult {
  const AgeRebuildResult({required this.implemented, required this.message});

  final bool implemented;
  final String message;
}

class HttpCorpusAdminGateway implements CorpusAdminGateway {
  HttpCorpusAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`).
  final Uri baseUri;
  final CorpusAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;

  static const String versionsPath = '/v1/admin/corpus/versions';
  static const String versionsPrefix = '$versionsPath/';
  static const String uploadPath = '/v1/admin/corpus/upload';
  static const String previewDiffPath = '/v1/admin/corpus/preview-diff';
  static const String commitPath = '/v1/admin/corpus/commit';
  static const String rollbackPath = '/v1/admin/corpus/rollback';
  // Phase 11A.3b — Graphify candidate review routes.
  static const String graphCandidatesPath = '/v1/admin/corpus/graph-candidates';
  static const String graphCandidatesCommitPath =
      '/v1/admin/corpus/graph-candidates/commit-batch';
  static const String ageRebuildPath = '/v1/admin/age/rebuild';

  @override
  Future<List<CorpusVersionRef>> listVersions() async {
    final body = await _send(method: 'GET', path: versionsPath);
    final list = (body['versions'] as List?) ?? const [];
    return <CorpusVersionRef>[
      for (final entry in list)
        CorpusVersionRef.fromJson((entry as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<CorpusBundle> fetchVersion({required String versionId}) async {
    final body = await _send(
      method: 'GET',
      path: '$versionsPrefix${Uri.encodeComponent(versionId)}',
    );
    return CorpusBundle.fromJson(body);
  }

  @override
  Future<CorpusDiff> previewDiff(UploadCommand command) async {
    final body = await _send(
      method: 'POST',
      path: previewDiffPath,
      idempotencyKey: command.idempotencyKey,
      jsonBody: <String, Object?>{
        'file_name': command.fileName,
        'content_type': command.contentType,
        'content_base64': base64Encode(command.bytes),
      },
    );
    return CorpusDiff.fromJson(body);
  }

  @override
  Future<CorpusVersionRef> commitVersion(CommitCommand command) async {
    final body = await _send(
      method: 'POST',
      path: commitPath,
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return CorpusVersionRef.fromJson(
      (body['version'] as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<CorpusVersionRef> rollbackToVersion(RollbackCommand command) async {
    final body = await _send(
      method: 'POST',
      path: rollbackPath,
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return CorpusVersionRef.fromJson(
      (body['version'] as Map).cast<String, Object?>(),
    );
  }

  @override
  Future<GraphCandidateDiff> listGraphCandidates() async {
    final body = await _send(method: 'GET', path: graphCandidatesPath);
    return GraphCandidateDiff.fromJson(body);
  }

  @override
  Future<BatchCommitResult> commitGraphCandidatesBatch(
    BatchCommitCommand command,
  ) async {
    final body = await _send(
      method: 'POST',
      path: graphCandidatesCommitPath,
      idempotencyKey: command.idempotencyKey,
      jsonBody: command.toJson(),
    );
    return BatchCommitResult.fromJson(body);
  }

  @override
  Future<AgeRebuildResult> requestAgeRebuild({
    required String idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(ageRebuildPath);
    final request = http.Request('POST', uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json'
      ..headers['Idempotency-Key'] = idempotencyKey
      ..headers['content-type'] = 'application/json'
      ..bodyBytes = utf8.encode(jsonEncode(<String, Object?>{}));
    final response = await http.Response.fromStream(
      await _httpClient.send(request),
    );
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = decoded.cast<String, Object?>();
    }
    if (response.statusCode == 501) {
      return AgeRebuildResult(
        implemented: false,
        message:
            (parsed['message'] as String?) ??
            'AGE rebuild infrastructure is not yet enabled',
      );
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return AgeRebuildResult(
        implemented: true,
        message: (parsed['message'] as String?) ?? 'AGE rebuild scheduled',
      );
    }
    throw CorpusAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message:
          (parsed['message'] as String?) ??
          'admin AGE rebuild proxy returned an error',
    );
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    final response = await http.Response.fromStream(
      await _httpClient.send(request),
    );
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = decoded.cast<String, Object?>();
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    throw CorpusAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message:
          (parsed['message'] as String?) ??
          'admin corpus proxy returned an error',
    );
  }
}

/// In-memory gateway used by the demo walkthrough and widget tests.
/// Persists nothing across runs — every construction starts from
/// [seed]. Validation rules mirror the proxy:
///
///   * Upload rejected when [UploadCommand.bytes] exceeds the launch
///     ceiling of [kCorpusUploadMaxBytes].
///   * Upload rejected when the content-type isn't in
///     [kCorpusUploadAcceptedContentTypes] OR the bytes contain a
///     non-text byte run (the demo treats null bytes as a binary
///     marker).
///   * `commitVersion` requires a previously-staged preview token.
///   * `rollbackToVersion` requires a known version_id.
class InMemoryCorpusAdminGateway implements CorpusAdminGateway {
  InMemoryCorpusAdminGateway({
    Iterable<CorpusBundle> seed = const <CorpusBundle>[],
    GraphCandidateDiff? graphCandidateSeed,
    DateTime Function()? now,
    String Function()? idGenerator,
    String? actorUserId,
  }) : _now = now ?? DateTime.now,
       _idGenerator = idGenerator ?? _randomId,
       _actorUserId = actorUserId,
       _bundles = <String, _MutableBundle>{
         for (final bundle in seed)
           bundle.version.versionId: _MutableBundle.from(bundle),
       },
       _graphCandidates = graphCandidateSeed ?? _defaultDemoGraphCandidates();

  final DateTime Function() _now;
  final String Function() _idGenerator;
  final String? _actorUserId;
  final Map<String, _MutableBundle> _bundles;
  final Map<String, _PendingUpload> _pending = <String, _PendingUpload>{};
  final Set<String> _seenIdempotencyKeys = <String>{};
  final Map<String, CorpusVersionRef> _idempotentResults =
      <String, CorpusVersionRef>{};
  final Map<String, CorpusDiff> _idempotentDiffs = <String, CorpusDiff>{};

  // Phase 11A.3b — Graph candidate state.
  GraphCandidateDiff _graphCandidates;
  // Decisions the demo gateway has consumed in prior commits;
  // approved → no longer in the diff; rejected → moved to the audit
  // log. Replays with a known idempotency-key return the cached
  // result.
  final Map<String, BatchCommitResult> _idempotentBatchResults =
      <String, BatchCommitResult>{};
  // In-memory audit log so the demo walkthrough can show that
  // rejections did NOT touch canonical storage. Each entry is the
  // payload of a single rejected candidate.
  final List<Map<String, Object?>> _graphifyReviewAudit =
      <Map<String, Object?>>[];
  // In-memory canonical storage so the demo walkthrough can show
  // approved candidates landed somewhere. Same shape the production
  // GraphRepository would write.
  final List<Map<String, Object?>> _approvedNodes = <Map<String, Object?>>[];
  final List<Map<String, Object?>> _approvedEdges = <Map<String, Object?>>[];

  @override
  Future<List<CorpusVersionRef>> listVersions() async {
    final versions =
        _bundles.values
            .map(
              (b) => CorpusVersionRef(
                versionId: b.versionId,
                createdBy: b.createdBy,
                createdAt: b.createdAt,
                summary: b.summary,
                rollbackOf: b.rollbackOf,
                supersededAt: b.supersededAt,
                chunkCount: b.chunks.length,
              ),
            )
            .toList()
          ..sort((a, b) {
            if (a.isCurrent != b.isCurrent) return a.isCurrent ? -1 : 1;
            return b.createdAt.compareTo(a.createdAt);
          });
    return versions;
  }

  @override
  Future<CorpusBundle> fetchVersion({required String versionId}) async {
    final bundle = _bundles[versionId];
    if (bundle == null) {
      throw const CorpusAdminGatewayError(
        statusCode: 404,
        errorCode: 'unknown_version',
        message: 'corpus version not found',
      );
    }
    return bundle.toBundle();
  }

  @override
  Future<CorpusDiff> previewDiff(UploadCommand command) async {
    final cached = _idempotentDiffs[command.idempotencyKey];
    if (cached != null) return cached;
    _validateUpload(command);
    final markdown = utf8.decode(command.bytes, allowMalformed: true);
    final parsedChunks = _chunkMarkdown(
      sourcePath: command.fileName,
      markdown: markdown,
    );
    final activeBundle = _activeBundle();
    final activeByPath = <String, ChunkPreview>{};
    if (activeBundle != null) {
      for (final c in activeBundle.chunks) {
        activeByPath['${c.sourcePath}#${c.chunkId}'] = c;
      }
    }

    final added = <ChunkPreview>[];
    final modified = <ChunkPreview>[];
    final inactivated = <ChunkPreview>[];
    final newKeys = <String>{};
    for (final c in parsedChunks) {
      final key = '${c.sourcePath}#${c.chunkId}';
      newKeys.add(key);
      final prior = activeByPath[key];
      if (prior == null) {
        added.add(c);
      } else if (prior.contentSha256 != c.contentSha256) {
        modified.add(c);
      }
    }
    if (activeBundle != null) {
      for (final c in activeBundle.chunks) {
        final key = '${c.sourcePath}#${c.chunkId}';
        if (!newKeys.contains(key)) inactivated.add(c);
      }
    }

    final summary = _autoSummary(
      command.fileName,
      added.length,
      modified.length,
      inactivated.length,
    );
    final token = _idGenerator();
    _pending[token] = _PendingUpload(
      fileName: command.fileName,
      chunks: parsedChunks,
      summary: summary,
    );
    final diff = CorpusDiff(
      previewToken: token,
      added: added,
      modified: modified,
      inactivated: inactivated,
      summary: summary,
    );
    _idempotentDiffs[command.idempotencyKey] = diff;
    return diff;
  }

  @override
  Future<CorpusVersionRef> commitVersion(CommitCommand command) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached != null) return cached;
    if (_seenIdempotencyKeys.contains(command.idempotencyKey)) {
      // The key was used for a different operation (rollback) — proxy
      // would return 409. Same shape locally.
      throw const CorpusAdminGatewayError(
        statusCode: 409,
        errorCode: 'idempotency_key_reused',
        message: 'Idempotency-Key was already used for another request',
      );
    }
    final pending = _pending[command.previewToken];
    if (pending == null) {
      throw const CorpusAdminGatewayError(
        statusCode: 400,
        errorCode: 'unknown_preview_token',
        message:
            'preview_token does not match any staged upload; re-run preview',
      );
    }
    final ts = _now().toUtc();
    // Supersede the prior current version, if any.
    final priorCurrent = _activeBundle();
    if (priorCurrent != null) priorCurrent.supersededAt = ts;
    final versionId = _idGenerator();
    final bundle = _MutableBundle(
      versionId: versionId,
      createdBy: _actorUserId,
      createdAt: ts,
      summary: command.summary.isEmpty ? pending.summary : command.summary,
      rollbackOf: null,
      supersededAt: null,
      chunks: pending.chunks
          .map(
            (c) => ChunkPreview(
              chunkId: c.chunkId,
              docId: c.docId,
              sourcePath: c.sourcePath,
              headingPath: c.headingPath,
              snippet: c.snippet,
              estimatedTokens: c.estimatedTokens,
              riskLevel: c.riskLevel,
              contentSha256: c.contentSha256,
              versionId: versionId,
              active: true,
            ),
          )
          .toList(),
    );
    _bundles[versionId] = bundle;
    _pending.remove(command.previewToken);
    _seenIdempotencyKeys.add(command.idempotencyKey);
    final ref = bundle.toRef();
    _idempotentResults[command.idempotencyKey] = ref;
    return ref;
  }

  @override
  Future<CorpusVersionRef> rollbackToVersion(RollbackCommand command) async {
    final cached = _idempotentResults[command.idempotencyKey];
    if (cached != null) return cached;
    if (_seenIdempotencyKeys.contains(command.idempotencyKey)) {
      throw const CorpusAdminGatewayError(
        statusCode: 409,
        errorCode: 'idempotency_key_reused',
        message: 'Idempotency-Key was already used for another request',
      );
    }
    final target = _bundles[command.targetVersionId];
    if (target == null) {
      throw const CorpusAdminGatewayError(
        statusCode: 404,
        errorCode: 'unknown_version',
        message: 'rollback target version not found',
      );
    }
    final ts = _now().toUtc();
    final priorCurrent = _activeBundle();
    if (priorCurrent != null) priorCurrent.supersededAt = ts;
    final versionId = _idGenerator();
    final newBundle = _MutableBundle(
      versionId: versionId,
      createdBy: _actorUserId,
      createdAt: ts,
      summary: command.summary.isEmpty
          ? 'Rolled back to ${target.versionId}'
          : command.summary,
      rollbackOf: target.versionId,
      supersededAt: null,
      chunks: target.chunks
          .map(
            (c) => ChunkPreview(
              chunkId: c.chunkId,
              docId: c.docId,
              sourcePath: c.sourcePath,
              headingPath: c.headingPath,
              snippet: c.snippet,
              estimatedTokens: c.estimatedTokens,
              riskLevel: c.riskLevel,
              contentSha256: c.contentSha256,
              versionId: versionId,
              active: true,
            ),
          )
          .toList(),
    );
    _bundles[versionId] = newBundle;
    _seenIdempotencyKeys.add(command.idempotencyKey);
    final ref = newBundle.toRef();
    _idempotentResults[command.idempotencyKey] = ref;
    return ref;
  }

  @override
  Future<GraphCandidateDiff> listGraphCandidates() async {
    return _graphCandidates;
  }

  @override
  Future<BatchCommitResult> commitGraphCandidatesBatch(
    BatchCommitCommand command,
  ) async {
    final cached = _idempotentBatchResults[command.idempotencyKey];
    if (cached != null) return cached;
    if (_seenIdempotencyKeys.contains(command.idempotencyKey)) {
      throw const CorpusAdminGatewayError(
        statusCode: 409,
        errorCode: 'idempotency_key_reused',
        message: 'Idempotency-Key was already used for another request',
      );
    }
    final byId = <String, GraphCandidate>{
      for (final c in _graphCandidates.extracted) c.candidateId: c,
      for (final c in _graphCandidates.inferred) c.candidateId: c,
      for (final c in _graphCandidates.ambiguous) c.candidateId: c,
    };
    var approvedNodes = 0;
    var approvedEdges = 0;
    var rejected = 0;
    final consumedIds = <String>{};
    for (final decision in command.decisions) {
      final candidate = byId[decision.candidateId];
      if (candidate == null) {
        throw CorpusAdminGatewayError(
          statusCode: 404,
          errorCode: 'unknown_candidate',
          message:
              'candidate ${decision.candidateId} is not in the current diff',
        );
      }
      consumedIds.add(decision.candidateId);
      switch (decision.kind) {
        case GraphDecisionKind.approve:
        case GraphDecisionKind.edit:
          if (candidate.kind == GraphCandidateKind.node) {
            _approvedNodes.add(<String, Object?>{
              'node_key': candidate.candidateKey,
              'node_type':
                  decision.editedCandidateType ?? candidate.candidateType,
              'properties': decision.editedPayload ?? candidate.payload,
              'graphify_version': _graphCandidates.graphifyVersion,
            });
            approvedNodes += 1;
          } else {
            _approvedEdges.add(<String, Object?>{
              'edge_key': candidate.candidateKey,
              'edge_type':
                  decision.editedCandidateType ?? candidate.candidateType,
              'from_node_key': candidate.fromNodeKey,
              'to_node_key': candidate.toNodeKey,
              'properties': decision.editedPayload ?? candidate.payload,
              'graphify_version': _graphCandidates.graphifyVersion,
            });
            approvedEdges += 1;
          }
          break;
        case GraphDecisionKind.reject:
          _graphifyReviewAudit.add(<String, Object?>{
            'candidate_id': candidate.candidateId,
            'candidate_kind': candidate.kind.name,
            'candidate_key': candidate.candidateKey,
            'candidate_payload': candidate.payload,
            'target_graph_scope': _graphCandidates.graphScope,
            'target_graph_version': _graphCandidates.graphVersion,
            'confidence_label': candidate.label.wireValue,
            'confidence_score': candidate.confidenceScore,
            'reason': decision.reason,
            'idempotency_key': command.idempotencyKey,
          });
          rejected += 1;
          break;
      }
    }
    // Drop the consumed candidates from the diff so a follow-up
    // listGraphCandidates() reflects the post-commit state.
    GraphCandidateDiff dropConsumed(GraphCandidateDiff diff) {
      List<GraphCandidate> filter(List<GraphCandidate> bucket) =>
          <GraphCandidate>[
            for (final c in bucket)
              if (!consumedIds.contains(c.candidateId)) c,
          ];
      return GraphCandidateDiff(
        graphScope: diff.graphScope,
        graphVersion: diff.graphVersion,
        graphifyVersion: diff.graphifyVersion,
        graphifySourceCommit: diff.graphifySourceCommit,
        extracted: filter(diff.extracted),
        inferred: filter(diff.inferred),
        ambiguous: filter(diff.ambiguous),
      );
    }

    _graphCandidates = dropConsumed(_graphCandidates);
    _seenIdempotencyKeys.add(command.idempotencyKey);
    final result = BatchCommitResult(
      approvedNodeCount: approvedNodes,
      approvedEdgeCount: approvedEdges,
      rejectedCount: rejected,
    );
    _idempotentBatchResults[command.idempotencyKey] = result;
    return result;
  }

  @override
  Future<AgeRebuildResult> requestAgeRebuild({
    required String idempotencyKey,
  }) async {
    if (_seenIdempotencyKeys.contains(idempotencyKey) &&
        _idempotentBatchResults.containsKey(idempotencyKey)) {
      throw const CorpusAdminGatewayError(
        statusCode: 409,
        errorCode: 'idempotency_key_reused',
        message: 'Idempotency-Key was already used for another request',
      );
    }
    _seenIdempotencyKeys.add(idempotencyKey);
    return const AgeRebuildResult(
      implemented: false,
      message:
          'AGE rebuild infrastructure is not yet enabled (501 in '
          'demo and proxy until the rebuild slice ships)',
    );
  }

  // Inspector hooks for the demo walkthrough + widget tests so they
  // can assert that approved candidates landed in canonical storage
  // and rejected candidates landed in the audit log only. Production
  // never reads these — the proxy is the read path.
  List<Map<String, Object?>> get debugApprovedNodes =>
      List<Map<String, Object?>>.unmodifiable(_approvedNodes);
  List<Map<String, Object?>> get debugApprovedEdges =>
      List<Map<String, Object?>>.unmodifiable(_approvedEdges);
  List<Map<String, Object?>> get debugRejectedAudit =>
      List<Map<String, Object?>>.unmodifiable(_graphifyReviewAudit);

  void _validateUpload(UploadCommand command) {
    if (command.bytes.length > kCorpusUploadMaxBytes) {
      throw CorpusAdminGatewayError(
        statusCode: 400,
        errorCode: 'upload_too_large',
        message: 'upload exceeds ${kCorpusUploadMaxBytes ~/ 1024} KiB cap',
      );
    }
    if (!kCorpusUploadAcceptedContentTypes.contains(command.contentType)) {
      throw CorpusAdminGatewayError(
        statusCode: 400,
        errorCode: 'unsupported_content_type',
        message:
            'content_type ${command.contentType} is not allowed; '
            'expected one of ${kCorpusUploadAcceptedContentTypes.join(', ')}',
      );
    }
    // Cheap binary sniff — null bytes are a strong signal that this
    // is a PNG / PDF / random binary the user dropped by mistake.
    final scanLen = math.min(command.bytes.length, 4096);
    for (var i = 0; i < scanLen; i++) {
      if (command.bytes[i] == 0) {
        throw const CorpusAdminGatewayError(
          statusCode: 400,
          errorCode: 'binary_or_unsupported_file',
          message: 'upload appears to be binary; only markdown is accepted',
        );
      }
    }
  }

  _MutableBundle? _activeBundle() {
    for (final bundle in _bundles.values) {
      if (bundle.supersededAt == null) return bundle;
    }
    return null;
  }

  static String _autoSummary(
    String fileName,
    int added,
    int modified,
    int inactivated,
  ) {
    final parts = <String>[
      if (added > 0) '+$added new',
      if (modified > 0) '~$modified modified',
      if (inactivated > 0) '-$inactivated inactivated',
    ];
    final shape = parts.isEmpty ? 'no changes' : parts.join(', ');
    return 'Uploaded $fileName ($shape)';
  }

  static int _idCounter = 0;
  static String _randomId() {
    _idCounter += 1;
    final hex = _idCounter.toRadixString(16).padLeft(12, '0');
    return '00000000-0000-4000-9000-$hex';
  }
}

/// Best-effort markdown chunker. Splits on H2 headings (`## …`) so the
/// demo walkthrough produces a deterministic chunk shape without
/// requiring the full advisor materializer. The proxy uses the live
/// chunker; the demo gateway only needs enough fidelity for the
/// click path.
List<ChunkPreview> _chunkMarkdown({
  required String sourcePath,
  required String markdown,
}) {
  final lines = const LineSplitter().convert(markdown);
  final chunks = <ChunkPreview>[];
  final buffer = StringBuffer();
  String currentHeading = sourcePath;
  String? currentH1;
  var index = 0;
  void flush() {
    if (buffer.isEmpty) return;
    final text = buffer.toString().trim();
    if (text.isEmpty) {
      buffer.clear();
      return;
    }
    final hash = _stableHash(text);
    final chunkId = '$sourcePath#${index.toString().padLeft(3, '0')}';
    chunks.add(
      ChunkPreview(
        chunkId: chunkId,
        docId: sourcePath,
        sourcePath: sourcePath,
        headingPath: <String>[
          if (currentH1 != null) currentH1,
          if (currentHeading != currentH1 && currentHeading != sourcePath)
            currentHeading,
        ],
        snippet: text.length > 280 ? '${text.substring(0, 280)}…' : text,
        estimatedTokens: (text.length / 4).ceil(),
        riskLevel: 'standard',
        contentSha256: hash,
        versionId: null,
        active: true,
      ),
    );
    index += 1;
    buffer.clear();
  }

  for (final line in lines) {
    if (line.startsWith('# ')) {
      flush();
      final heading = line.substring(2).trim();
      currentH1 = heading;
      currentHeading = heading;
      continue;
    }
    if (line.startsWith('## ')) {
      flush();
      currentHeading = line.substring(3).trim();
      continue;
    }
    buffer.writeln(line);
  }
  flush();
  if (chunks.isEmpty) {
    final hash = _stableHash(markdown.trim());
    chunks.add(
      ChunkPreview(
        chunkId: '$sourcePath#000',
        docId: sourcePath,
        sourcePath: sourcePath,
        headingPath: const <String>[],
        snippet: markdown.trim(),
        estimatedTokens: (markdown.length / 4).ceil(),
        riskLevel: 'standard',
        contentSha256: hash,
        versionId: null,
        active: true,
      ),
    );
  }
  return chunks;
}

// Web targets (dart2js) cannot represent 64-bit integer literals exactly,
// so we use SHA-256 from package:crypto. Output shape matches the proxy's
// `^[a-f0-9]{64}$` constraint even in demo data.
String _stableHash(String text) => sha256.convert(utf8.encode(text)).toString();

class _MutableBundle {
  _MutableBundle({
    required this.versionId,
    required this.createdBy,
    required this.createdAt,
    required this.summary,
    required this.rollbackOf,
    required this.supersededAt,
    required List<ChunkPreview> chunks,
  }) : chunks = List<ChunkPreview>.from(chunks);

  factory _MutableBundle.from(CorpusBundle bundle) {
    return _MutableBundle(
      versionId: bundle.version.versionId,
      createdBy: bundle.version.createdBy,
      createdAt: bundle.version.createdAt,
      summary: bundle.version.summary,
      rollbackOf: bundle.version.rollbackOf,
      supersededAt: bundle.version.supersededAt,
      chunks: bundle.chunks,
    );
  }

  final String versionId;
  final String? createdBy;
  final DateTime createdAt;
  String summary;
  String? rollbackOf;
  DateTime? supersededAt;
  final List<ChunkPreview> chunks;

  CorpusBundle toBundle() => CorpusBundle(
    version: toRef(),
    chunks: List<ChunkPreview>.unmodifiable(chunks),
  );

  CorpusVersionRef toRef() => CorpusVersionRef(
    versionId: versionId,
    createdBy: createdBy,
    createdAt: createdAt,
    summary: summary,
    rollbackOf: rollbackOf,
    supersededAt: supersededAt,
    chunkCount: chunks.length,
  );
}

class _PendingUpload {
  _PendingUpload({
    required this.fileName,
    required this.chunks,
    required this.summary,
  });

  final String fileName;
  final List<ChunkPreview> chunks;
  final String summary;
}

/// Internal helper Uint8List bridge. Exposed so widget-test callers
/// can produce demo-realistic upload bodies without pulling in `dart:io`
/// in the test layer.
Uint8List corpusUploadBytesFromString(String markdown) =>
    Uint8List.fromList(utf8.encode(markdown));

/// Phase 11A.3b — deterministic demo seed for the Graph candidates
/// tab. Mirrors the kind of payload the importer would produce from
/// `graphify-out/graph.json` against the seeded methodology corpus.
GraphCandidateDiff _defaultDemoGraphCandidates() {
  return GraphCandidateDiff(
    graphScope: 'methodology',
    graphVersion: '1',
    graphifyVersion: 'v5',
    graphifySourceCommit: 'demo-seed',
    extracted: <GraphCandidate>[
      GraphCandidate(
        candidateId: 'node:graphify:methodology_seed_doc',
        kind: GraphCandidateKind.node,
        candidateKey: 'graphify:methodology_seed_doc',
        candidateType: 'Document',
        label: GraphCandidateLabel.extracted,
        confidenceScore: 0.95,
        sourceFile: 'methodology_seed.md',
        sourceRef: null,
        payload: const <String, Object?>{
          'label': 'Methodology Seed',
          'community': 0,
        },
      ),
      GraphCandidate(
        candidateId:
            'edge:graphify:edge:methodology_seed_doc:cycles_section:contains',
        kind: GraphCandidateKind.edge,
        candidateKey:
            'graphify:edge:methodology_seed_doc:cycles_section:contains',
        candidateType: 'CONTAINS',
        label: GraphCandidateLabel.extracted,
        confidenceScore: 0.92,
        sourceFile: 'methodology_seed.md',
        sourceRef: null,
        fromNodeKey: 'graphify:methodology_seed_doc',
        toNodeKey: 'graphify:cycles_section',
        payload: const <String, Object?>{
          'graphify_relation': 'CONTAINS',
          'label': 'doc CONTAINS cycles section',
        },
      ),
    ],
    inferred: <GraphCandidate>[
      GraphCandidate(
        candidateId:
            'edge:graphify:edge:cycles_section:weekly_plan_concept:informs',
        kind: GraphCandidateKind.edge,
        candidateKey:
            'graphify:edge:cycles_section:weekly_plan_concept:informs',
        candidateType: 'INFORMS',
        label: GraphCandidateLabel.inferred,
        confidenceScore: 0.62,
        sourceFile: 'methodology_seed.md',
        sourceRef: null,
        fromNodeKey: 'graphify:cycles_section',
        toNodeKey: 'graphify:weekly_plan_concept',
        payload: const <String, Object?>{
          'graphify_relation': 'TEACHES',
          'label': 'cycles INFORMS weekly plan concept',
        },
      ),
    ],
    ambiguous: <GraphCandidate>[
      GraphCandidate(
        candidateId:
            'edge:graphify:edge:daypart_section:cycles_section:relates_to',
        kind: GraphCandidateKind.edge,
        candidateKey: 'graphify:edge:daypart_section:cycles_section:relates_to',
        candidateType: 'RELATES_TO',
        label: GraphCandidateLabel.ambiguous,
        confidenceScore: 0.41,
        sourceFile: 'methodology_seed.md',
        sourceRef: null,
        fromNodeKey: 'graphify:daypart_section',
        toNodeKey: 'graphify:cycles_section',
        payload: const <String, Object?>{
          'graphify_relation': 'NEAR',
          'label': 'daypart section near cycles section',
        },
      ),
    ],
  );
}
