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
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
}

class HttpCorpusAdminGateway implements CorpusAdminGateway {
  HttpCorpusAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    HttpClient? httpClient,
  }) : _httpClient = httpClient ?? HttpClient();

  /// Proxy base URI (e.g. `https://admin-proxy.forgeflow.app`).
  final Uri baseUri;
  final CorpusAdminBearerTokenProvider bearerTokenProvider;
  final HttpClient _httpClient;

  static const String versionsPath = '/v1/admin/corpus/versions';
  static const String versionsPrefix = '$versionsPath/';
  static const String uploadPath = '/v1/admin/corpus/upload';
  static const String previewDiffPath = '/v1/admin/corpus/preview-diff';
  static const String commitPath = '/v1/admin/corpus/commit';
  static const String rollbackPath = '/v1/admin/corpus/rollback';

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

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    final uri = baseUri.resolve(path);
    final request = await _httpClient.openUrl(method, uri);
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    if (jsonBody != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(jsonBody)));
    }
    final response = await request.close();
    final raw = await response.transform(utf8.decoder).join();
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
      message: (parsed['message'] as String?) ??
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
    DateTime Function()? now,
    String Function()? idGenerator,
    String? actorUserId,
  })  : _now = now ?? DateTime.now,
        _idGenerator = idGenerator ?? _randomId,
        _actorUserId = actorUserId,
        _bundles = <String, _MutableBundle>{
          for (final bundle in seed)
            bundle.version.versionId: _MutableBundle.from(bundle),
        };

  final DateTime Function() _now;
  final String Function() _idGenerator;
  final String? _actorUserId;
  final Map<String, _MutableBundle> _bundles;
  final Map<String, _PendingUpload> _pending = <String, _PendingUpload>{};
  final Set<String> _seenIdempotencyKeys = <String>{};
  final Map<String, CorpusVersionRef> _idempotentResults =
      <String, CorpusVersionRef>{};
  final Map<String, CorpusDiff> _idempotentDiffs = <String, CorpusDiff>{};

  @override
  Future<List<CorpusVersionRef>> listVersions() async {
    final versions = _bundles.values
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

  static String _autoSummary(String fileName, int added, int modified, int inactivated) {
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

/// Stable, dependency-free hash for the demo gateway. Production runs
/// SHA-256 server-side; the demo's diff only needs deterministic
/// fingerprints across test runs, not cryptographic strength.
String _stableHash(String text) {
  final bytes = utf8.encode(text);
  // FNV-1a 64-bit. Output formatted as 16 hex chars left-padded to 64
  // so the schema's `^[a-f0-9]{64}$` constraint shape mirrors the
  // production sha256 column even in demo data.
  const offset = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  var hash = offset;
  for (final byte in bytes) {
    hash = (hash ^ byte) & 0xffffffffffffffff;
    hash = (hash * prime) & 0xffffffffffffffff;
  }
  final hex = hash.toRadixString(16).padLeft(16, '0');
  return (hex * 4).substring(0, 64);
}

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
