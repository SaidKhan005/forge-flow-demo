// Forge & Flow — advisor provider constants.
//
// 7.57.3a foundation slice. Single source of truth for the provider /
// model identifiers locked into the 11a advisor contract:
//
//   - Voyage embeddings:  voyage-4-large at vector(1024) cosine retrieval
//     (`docs/phases/post_11a7_stabilization_plan.md` line 252).
//   - Voyage rerank:      rerank-2.5 ordering pgvector candidates before
//     Claude (`docs/phases/post_11a7_stabilization_plan.md` line 257).
//   - Claude answer:      tiered Sonnet/Haiku via the `tier` parameter
//     (`docs/phases/post_11a7_stabilization_plan.md` lines 167-169).
//       * tier=quick   -> Haiku  (default)
//       * tier=nuanced -> Sonnet
//
// Used by both the domain interfaces and the concrete adapter classes
// so the contract values live in exactly one place.

abstract class AdvisorProviderConstants {
  AdvisorProviderConstants._();

  // ── Voyage embeddings ─────────────────────────────────────────────────────
  static const String voyageProviderId = 'voyage';
  static const String voyageEmbeddingModelId = 'voyage-4-large';
  static const int voyageEmbeddingDimensions = 1024;

  // ── Voyage rerank ─────────────────────────────────────────────────────────
  static const String voyageRerankModelId = 'rerank-2.5';

  // ── Anthropic / Claude answer tiers ───────────────────────────────────────
  static const String anthropicProviderId = 'anthropic';

  /// Quick tier -> Haiku. Default tier for routine advisor turns.
  ///
  /// Pinned default. Dev overrides live in `AdvisorModelConfigService` and
  /// surface in the dev-only `ADVISOR MODELS` Settings section; this
  /// constant is the fallback when no override is set.
  static const String haikuModelId = 'claude-haiku-4-5';

  /// Nuanced tier -> Sonnet. Reserved for deep advisor turns.
  ///
  /// Pinned default. Dev overrides live in `AdvisorModelConfigService` and
  /// surface in the dev-only `ADVISOR MODELS` Settings section; this
  /// constant is the fallback when no override is set.
  static const String sonnetModelId = 'claude-sonnet-4-6';

  // ── Mock replay data source ───────────────────────────────────────────────
  /// Provider identifier for the kDemoMode writer that fills SQLite from
  /// `MockIntegrationReplaySeed`. Phase 8 will introduce additional vendor
  /// provider identifiers (e.g. `toast_pos`) that implement the same
  /// `DataSourceProvider` interface.
  static const String mockReplayProviderId = 'mock_replay';
}
