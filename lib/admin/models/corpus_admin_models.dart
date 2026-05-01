// Phase 11A.3a — Corpus admin value objects.
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
    final heading = <String>[
      if (raw is List) ...raw.whereType<String>(),
    ];
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
