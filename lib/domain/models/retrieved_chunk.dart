// Forge & Flow — RetrievedChunk value object.
//
// Advisor Knowledge Activation — Slice A1.
//
// Immutable value object produced by corpus retrieval. Carries the
// minimum metadata needed by the reranker (A3) and the answer runtime
// (A4) without leaking postgres driver types outside the persistence
// layer. The `text` field is the full chunk body; callers that need
// an excerpt for display must compute it before rendering.
//
// Field names mirror the `public.advisor_search_chunks(...)` return
// columns (see `db/migrations/202604250003_advisor_vector_search.sql`)
// so the repository mapping is one-to-one and verifiable at a glance.

/// One chunk returned by `public.advisor_search_chunks(...)` mapped to
/// a Dart value object. Ordering is by cosine similarity descending
/// (similarity = 1 − distance; highest = most relevant).
class RetrievedChunk {
  const RetrievedChunk({
    required this.chunkId,
    required this.docId,
    required this.headingPath,
    required this.text,
    required this.similarity,
    this.sourcePath,
    this.scope,
  });

  /// Stable identifier for the chunk row (`advisor_source_chunks.chunk_id`).
  final String chunkId;

  /// Document the chunk belongs to (`advisor_source_chunks.doc_id`).
  final String docId;

  /// Ordered heading breadcrumb list from the source document.
  /// Empty list when no headings were extracted.
  final List<String> headingPath;

  /// Full chunk text. Callers computing snippets must truncate
  /// client-side; the repository returns the full body.
  final String text;

  /// Cosine similarity score in [0.0, 1.0]. Higher = closer match.
  /// Computed by the SQL function as `1.0 - (embedding <=> query_embedding)`.
  final double similarity;

  /// Source file path within the corpus (e.g.
  /// `docs/Knowledge_graph_docs/foo.md`). May be null when the
  /// column is not populated.
  final String? sourcePath;

  /// Corpus scope the chunk belongs to (e.g. `'methodology'`).
  final String? scope;

  @override
  String toString() =>
      'RetrievedChunk(chunkId: $chunkId, docId: $docId, '
      'similarity: ${similarity.toStringAsFixed(4)})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RetrievedChunk &&
          other.chunkId == chunkId &&
          other.docId == docId &&
          other.similarity == similarity;

  @override
  int get hashCode => Object.hash(chunkId, docId, similarity);
}
