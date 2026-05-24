// Forge & Flow — CorpusRetrievalRepository abstraction.
//
// Advisor Knowledge Activation — Slice A1.
//
// Domain-layer interface for corpus vector search. The concrete
// implementation lives in
// `lib/infrastructure/persistence/postgres/repositories/
//  corpus_retrieval_repository_impl.dart`
// and calls `public.advisor_search_chunks(...)`.
//
// Keeping the abstraction here lets `CorpusRetrievalService` depend on
// the interface rather than on the Postgres implementation, which keeps
// `package:postgres` out of `lib/services/` (CLAUDE.md Service-Layer
// Split and CI lint rule).

import '../models/retrieved_chunk.dart';

/// Corpus vector-search gateway. The domain layer depends only on this
/// interface; the Postgres implementation is in the infrastructure layer.
abstract class CorpusRetrievalRepository {
  /// Retrieve the top-K chunks matching [queryEmbedding] by cosine
  /// similarity from `public.advisor_search_chunks(...)`.
  ///
  /// Parameters:
  /// - [queryEmbedding] — 1024-dim embedding vector (caller must
  ///   guarantee length == 1024; [CorpusRetrievalService] guards this).
  /// - [graphScope] — corpus scope filter (e.g. `'methodology'`).
  /// - [restaurantId] — optional UUID string; null = global shared corpus.
  /// - [providerId] — embedding provider (locked to `'voyage'`).
  /// - [modelId] — embedding model (locked to `'voyage-4-large'`).
  /// - [dimension] — embedding dimension (locked to `1024`).
  /// - [maxResults] — upper bound on returned rows (1–100, capped by
  ///   the SQL function's `least(max_results, 100)`).
  ///
  /// Returns chunks ordered by similarity descending (most relevant
  /// first). Returns an empty list when no rows match.
  Future<List<RetrievedChunk>> searchChunks({
    required List<double> queryEmbedding,
    required String graphScope,
    String? restaurantId,
    required String providerId,
    required String modelId,
    required int dimension,
    required int maxResults,
  });
}
