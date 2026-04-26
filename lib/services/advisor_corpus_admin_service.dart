// Phase 11a.12 — AdvisorCorpusAdminService.
//
// Pure local service that backs the dev/admin "ADVISOR CORPUS" Settings
// section. Validates a staged Markdown document the operator has typed
// or pasted into the UI and returns a deterministic local summary so a
// real corpus loader can be wired in later without changing the UI
// shape.
//
// Hard rules:
//   * No file picker, no shell-out to `tool/advisor_corpus`, no live
//     Anthropic / Voyage / Supabase / Firebase calls. Everything is in
//     memory.
//   * The "load to cloud" path is intentionally blocked. Cloud apply
//     depends on the 11a.11b prerequisites (Supabase CLI installed,
//     project linked, env exported). Until those land, this service
//     surfaces a blocked outcome that the UI renders as a disabled
//     action with an explanatory message.
//   * Token estimation is a simple deterministic heuristic
//     (`(length / 4).ceil()`). Good enough for an admin preview; the
//     real Voyage/Anthropic tokenizer is owned by the proxy, not the
//     client.
//   * The estimated chunk count uses a fixed token-per-chunk threshold
//     (`_chunkTokenThreshold`) — it does NOT replicate the
//     `tool/advisor_corpus` heading-aware planner. Treat it as an
//     order-of-magnitude hint, not an authoritative count.
//
// Source path preview is rendered at `docs/Knowledge_graph_docs/<name>`
// because that is the corpus root the manifest validator enforces.

import 'dart:math' as math;

/// Outcome of a local Markdown preview.
enum CorpusPreviewStatus {
  /// Valid Markdown passed validation. The ingestion-shaped fields
  /// (`normalizedFileName`, `sourcePathPreview`, `titlePreview`,
  /// `headingCount`, `estimatedChunkCount`, `lineCount`,
  /// `estimatedTokens`, `localStatus`) are populated.
  valid,

  /// File name failed normalization or the `.md` extension check.
  invalidName,

  /// Markdown body was empty or whitespace-only.
  blankMarkdown,
}

class CorpusPreviewResult {
  final CorpusPreviewStatus status;

  /// The raw file name the operator entered, after a single `trim`.
  /// Always populated; failure outcomes carry the entered value back so
  /// the UI can echo it in the error row.
  final String fileName;

  final String? errorMessage;

  // ── Ingestion-shaped preview fields (valid outcome only) ───────────

  /// File name after `trim`, backslash-to-slash conversion, basename
  /// extraction, and case-preserving validation. Null on failure.
  final String? normalizedFileName;

  /// `'docs/Knowledge_graph_docs/<normalizedFileName>'`. Mirrors the
  /// corpus manifest's `corpus_root` so the operator can see what
  /// `source_path` the eventual ingestion run would assign. Null on
  /// failure.
  final String? sourcePathPreview;

  /// Title extracted from the first H1 line (`# Title`). Falls back to
  /// the normalized file name with the `.md` extension stripped when
  /// no H1 is present. Null on failure.
  final String? titlePreview;

  /// Count of Markdown heading lines matching `^#{1,6}\s+`. Counts
  /// every level so the operator sees the structural density of the
  /// document. Null on failure.
  final int? headingCount;

  /// Coarse chunk-count estimate. Defined as
  /// `max(1, ceil(estimatedTokens / _chunkTokenThreshold))`. Null on
  /// failure.
  final int? estimatedChunkCount;

  final int? lineCount;
  final int? estimatedTokens;

  /// Always `'preview_local_only'` for the `valid` outcome and `null`
  /// for the failure outcomes. Surfaced in the UI as a status badge so
  /// the operator never confuses a successful local preview with an
  /// actual cloud load.
  final String? localStatus;

  const CorpusPreviewResult._({
    required this.status,
    required this.fileName,
    this.errorMessage,
    this.normalizedFileName,
    this.sourcePathPreview,
    this.titlePreview,
    this.headingCount,
    this.estimatedChunkCount,
    this.lineCount,
    this.estimatedTokens,
    this.localStatus,
  });

  factory CorpusPreviewResult.valid({
    required String fileName,
    required String normalizedFileName,
    required String sourcePathPreview,
    required String titlePreview,
    required int headingCount,
    required int estimatedChunkCount,
    required int lineCount,
    required int estimatedTokens,
  }) {
    return CorpusPreviewResult._(
      status: CorpusPreviewStatus.valid,
      fileName: fileName,
      normalizedFileName: normalizedFileName,
      sourcePathPreview: sourcePathPreview,
      titlePreview: titlePreview,
      headingCount: headingCount,
      estimatedChunkCount: estimatedChunkCount,
      lineCount: lineCount,
      estimatedTokens: estimatedTokens,
      localStatus: 'preview_local_only',
    );
  }

  factory CorpusPreviewResult.invalidName({
    required String fileName,
    required String message,
  }) {
    return CorpusPreviewResult._(
      status: CorpusPreviewStatus.invalidName,
      fileName: fileName,
      errorMessage: message,
    );
  }

  factory CorpusPreviewResult.blankMarkdown({
    required String fileName,
    required String message,
  }) {
    return CorpusPreviewResult._(
      status: CorpusPreviewStatus.blankMarkdown,
      fileName: fileName,
      errorMessage: message,
    );
  }

  bool get isValid => status == CorpusPreviewStatus.valid;
}

/// Outcome of an attempted live cloud load. Until 11a.11b prerequisites
/// land this is always `blocked`.
enum CorpusCloudLoadStatus { blocked }

class CorpusCloudLoadResult {
  final CorpusCloudLoadStatus status;
  final String message;

  const CorpusCloudLoadResult.blocked({required this.message})
      : status = CorpusCloudLoadStatus.blocked;
}

/// Corpus root mirrored from the real manifest validator. Kept inline
/// here rather than imported from `tool/` so the Flutter app does not
/// pull in tool-only code.
const String _previewCorpusRoot = 'docs/Knowledge_graph_docs';

/// Token threshold per estimated chunk. Picked to match the order of
/// magnitude of the real heading-aware planner without claiming to
/// reproduce its boundaries; documented so the operator understands
/// the field is an order-of-magnitude hint.
const int _chunkTokenThreshold = 400;

class AdvisorCorpusAdminService {
  AdvisorCorpusAdminService();

  /// Validates [fileName] + [markdown] locally and returns a
  /// deterministic preview summary. Never touches disk, network, or
  /// any external process.
  Future<CorpusPreviewResult> preview({
    required String fileName,
    required String markdown,
  }) async {
    final trimmedFileName = fileName.trim();

    final normalized = _normalizeFileName(trimmedFileName);
    if (normalized == null) {
      return CorpusPreviewResult.invalidName(
        fileName: trimmedFileName,
        message: 'File name must end with .md.',
      );
    }

    if (markdown.trim().isEmpty) {
      return CorpusPreviewResult.blankMarkdown(
        fileName: trimmedFileName,
        message: 'Markdown content must not be empty.',
      );
    }

    final lineCount = markdown.split('\n').length;
    final estimatedTokens = (markdown.length / 4).ceil();
    final headingCount = _countHeadings(markdown);
    final titlePreview = _extractTitle(markdown) ??
        _stripMdExtension(normalized);
    final estimatedChunkCount =
        math.max(1, (estimatedTokens / _chunkTokenThreshold).ceil());
    final sourcePathPreview = '$_previewCorpusRoot/$normalized';

    return CorpusPreviewResult.valid(
      fileName: trimmedFileName,
      normalizedFileName: normalized,
      sourcePathPreview: sourcePathPreview,
      titlePreview: titlePreview,
      headingCount: headingCount,
      estimatedChunkCount: estimatedChunkCount,
      lineCount: lineCount,
      estimatedTokens: estimatedTokens,
    );
  }

  /// Cloud apply is gated on the 11a.11b prerequisites. Until those
  /// land this returns a deterministic `blocked` outcome the UI can
  /// render. The implementation never opens a socket or process.
  Future<CorpusCloudLoadResult> attemptCloudLoad({
    required String fileName,
    required String markdown,
  }) async {
    return const CorpusCloudLoadResult.blocked(
      message:
          'Cloud load is blocked. The 11a.11b cloud DB apply '
          'prerequisites are not satisfied in this environment '
          '(see docs/phases/phase_11a/'
          'phase_11a_11b_cloud_db_apply_readiness.md).',
    );
  }

  /// Trim, convert backslashes to slashes, take the basename, and
  /// require a `.md` extension (case-insensitive). Case is preserved
  /// in the returned value so the operator's intent is not silently
  /// rewritten. Returns null when the result would be empty or fails
  /// the extension check.
  String? _normalizeFileName(String trimmed) {
    if (trimmed.isEmpty) return null;
    final slashed = trimmed.replaceAll(r'\', '/');
    final lastSlash = slashed.lastIndexOf('/');
    final basename = lastSlash >= 0 ? slashed.substring(lastSlash + 1) : slashed;
    if (basename.isEmpty) return null;
    if (!basename.toLowerCase().endsWith('.md')) return null;
    if (basename.toLowerCase() == '.md') return null;
    return basename;
  }

  /// Returns the trimmed text of the first H1 line (`# Title`). H2+
  /// lines are ignored even if they appear before the first H1.
  String? _extractTitle(String markdown) {
    final h1 = RegExp(r'^# +(.+?)\s*$', multiLine: true);
    final match = h1.firstMatch(markdown);
    if (match == null) return null;
    final text = match.group(1)?.trim();
    if (text == null || text.isEmpty) return null;
    return text;
  }

  /// Counts every line that begins with 1–6 `#` characters followed
  /// by whitespace. Mirrors how a Markdown parser detects heading
  /// lines without pulling in a parser dependency.
  int _countHeadings(String markdown) {
    final heading = RegExp(r'^#{1,6} +\S', multiLine: true);
    return heading.allMatches(markdown).length;
  }

  /// Returns [normalized] without its `.md`/`.MD` suffix. Case is
  /// preserved on the stem so a doc named `Wage_Standards.md` falls
  /// back to `Wage_Standards`, not `wage_standards`.
  String _stripMdExtension(String normalized) {
    if (normalized.length <= 3) return normalized;
    return normalized.substring(0, normalized.length - 3);
  }
}
