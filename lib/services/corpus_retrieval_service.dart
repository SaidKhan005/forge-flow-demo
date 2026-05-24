// Forge & Flow — CorpusRetrievalService.
//
// Advisor Knowledge Activation — Slice A1.
//
// Runtime orchestration layer for corpus vector search. Delegates to a
// [CorpusRetrievalRepository] abstraction so the service has no direct
// dependency on `package:postgres` (CLAUDE.md Service-Layer Split).
//
// Locked embedding contract (AdvisorProviderConstants):
//   provider  = 'voyage'
//   model     = 'voyage-4-large'
//   dimension = 1024
//
// The service guards the caller from accidentally passing an embedding
// produced by a different model (wrong dimension) by throwing an
// [ArgumentError] when the embedding length is not exactly 1024. The
// guard is the ONLY validation this service owns; all other parameter
// bounds (maxResults capping) are delegated to the SQL function.
//
// No Voyage API calls are made here. Query embeddings are produced by
// the caller (Slice A2 wires the runtime Voyage call). This service is
// read-only retrieval plumbing only.

import '../domain/models/retrieved_chunk.dart';
import '../domain/repositories/corpus_retrieval_repository.dart';
import '../domain/services/advisor_provider_constants.dart';

/// Orchestrates corpus chunk retrieval via vector similarity search.
///
/// Callers supply a pre-computed 1024-dim query embedding and receive an
/// ordered list of [RetrievedChunk] instances, most-relevant first.
///
/// This service is read-only. It does not call any external API, does not
/// write to any table, and does not touch the advisor proxy.
class CorpusRetrievalService {
  CorpusRetrievalService({required CorpusRetrievalRepository repository})
      : _repository = repository;

  final CorpusRetrievalRepository _repository;

  /// The embedding dimension this service enforces. Matches the locked
  /// contract constant so a future dimension change only needs one edit.
  static const int _requiredDimension =
      AdvisorProviderConstants.voyageEmbeddingDimensions; // 1024

  /// Retrieve the top-K chunks from the corpus that best match
  /// [queryEmbedding].
  ///
  /// Parameters:
  /// - [queryEmbedding] — must be exactly 1024 floats. Throws
  ///   [ArgumentError] otherwise.
  /// - [graphScope] — corpus scope (default `'methodology'`; global shared
  ///   methodology corpus is the launch scope).
  /// - [restaurantId] — optional UUID string; null targets the global shared
  ///   corpus (Hard Promise #4: per-operator isolation enforced by scope +
  ///   restaurantId at the retrieval layer).
  /// - [maxResults] — maximum chunks to return, default 8 (capped to
  ///   1–100 by the underlying SQL function).
  ///
  /// Returns chunks ordered by cosine similarity descending (most relevant
  /// first). Returns an empty list when no chunks match.
  ///
  /// Throws [ArgumentError] when [queryEmbedding] is not exactly
  /// [_requiredDimension] elements long.
  Future<List<RetrievedChunk>> retrieve({
    required List<double> queryEmbedding,
    String graphScope = 'methodology',
    String? restaurantId,
    int maxResults = 8,
  }) async {
    if (queryEmbedding.length != _requiredDimension) {
      throw ArgumentError(
        'queryEmbedding must be exactly $_requiredDimension dimensions '
        '(got ${queryEmbedding.length}). '
        'Use the Voyage voyage-4-large model to produce query embeddings.',
        'queryEmbedding',
      );
    }

    return _repository.searchChunks(
      queryEmbedding: queryEmbedding,
      graphScope: graphScope,
      restaurantId: restaurantId,
      providerId: AdvisorProviderConstants.voyageProviderId,
      modelId: AdvisorProviderConstants.voyageEmbeddingModelId,
      dimension: AdvisorProviderConstants.voyageEmbeddingDimensions,
      maxResults: maxResults,
    );
  }
}
