// Forge & Flow — EmbeddingProvider interface.
//
// 7.57.3a foundation slice. Pure-formula domain interface; concrete
// adapters live under `lib/services/` (e.g. `VoyageEmbeddingProvider`).
//
// 11a contract: Voyage `voyage-4-large` retrieval embeddings at
// `vector(1024)` cosine. See `AdvisorProviderConstants` for the locked
// identifiers and dimensions.

abstract class EmbeddingProvider {
  /// Stable provider id (e.g. `voyage`). Used for telemetry and for
  /// consistency checks against the persisted `embedding_provider`
  /// column on `corpus_embedding_records`.
  String get providerId;

  /// Stable model id (e.g. `voyage-4-large`).
  String get modelId;

  /// Vector length the provider produces. Must match the destination
  /// pgvector column width (`vector(1024)` for the current contract).
  int get dimensions;

  /// Embed a single text into a `dimensions`-length vector.
  Future<List<double>> embed(String text);

  /// Embed a batch of texts. Implementations should preserve input order
  /// in the returned list.
  Future<List<List<double>>> embedBatch(List<String> texts);
}
