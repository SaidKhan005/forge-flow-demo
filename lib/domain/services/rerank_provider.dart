// Forge & Flow — RerankProvider interface.
//
// 7.57.3a foundation slice. Pure-formula domain interface; concrete
// adapters live under `lib/services/` (e.g. `VoyageRerankProvider`).
//
// 11a contract: Voyage `rerank-2.5` orders pgvector candidate chunks
// before Claude receives the answer prompt. See
// `AdvisorProviderConstants.voyageRerankModelId`.

/// One candidate document fed to the reranker.
class RerankCandidate {
  /// Stable identifier the caller uses to reconnect rerank scores back
  /// to its own candidate list (e.g. a corpus-chunk id).
  final String id;

  /// Raw text the reranker scores against the query. Implementations
  /// must not mutate or trim this beyond what the underlying API
  /// requires.
  final String text;

  const RerankCandidate({required this.id, required this.text});
}

/// One scored result from the reranker.
class RerankResult {
  /// Mirrors the `id` of the corresponding [RerankCandidate].
  final String id;

  /// Provider-reported relevance score. Higher = more relevant.
  final double score;

  /// 0-based rank after sorting by score descending. Index 0 is the
  /// top-scoring candidate.
  final int rank;

  const RerankResult({
    required this.id,
    required this.score,
    required this.rank,
  });
}

abstract class RerankProvider {
  /// Stable provider id (e.g. `voyage`).
  String get providerId;

  /// Stable model id (e.g. `rerank-2.5`).
  String get modelId;

  /// Rerank [candidates] against [query]. Returns one [RerankResult]
  /// per input candidate, sorted by score descending and tagged with
  /// the corresponding 0-based [RerankResult.rank].
  Future<List<RerankResult>> rerank(
    String query,
    List<RerankCandidate> candidates,
  );
}
