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

  // ── Gemini fallback tiers (Phase 11A.4b) ─────────────────────────────────
  // Server-side fallback model when Anthropic's circuit is open. Tier
  // mapping: quick -> gemini-flash (default fallback),
  // nuanced -> gemini-pro (reserved). Server-side keys only — see Hard
  // Promise #7 in CLAUDE.md.
  static const String geminiProviderId = 'gemini';
  static const String geminiFlashModelId = 'gemini-2.5-flash';
  static const String geminiProModelId = 'gemini-2.5-pro';

  // ── Mock replay data source ───────────────────────────────────────────────
  /// Provider identifier for the kDemoMode writer that fills SQLite from
  /// `MockIntegrationReplaySeed`. Phase 8 will introduce additional vendor
  /// provider identifiers (e.g. `toast_pos`) that implement the same
  /// `DataSourceProvider` interface.
  static const String mockReplayProviderId = 'mock_replay';
}

/// Usage-class string for the server-side Voyage query-embedding call on
/// the advisor text-query retrieval path (POST /v1/advisor/retrieve).
///
/// HP #9 (AI cost metered by class): the Voyage embedding spend is a
/// distinct cost class from the Anthropic answer (`advisor_qa`), so it is
/// recorded under its own `usage_logs.usage_class`. `usage_class` is a
/// free-form text column (1 to 64 chars), so no migration is needed for a
/// new class. Exposed as a top-level const so route code and tests
/// reference the same literal instead of hardcoding it.
const String kVoyageQueryEmbeddingUsageClass = 'voyage_query_embedding';

/// Usage-class string for the server-side Voyage rerank call on the
/// advisor text-query retrieval path (POST /v1/advisor/retrieve).
///
/// HP #9 (AI cost metered by class): the Voyage rerank spend is a distinct
/// cost class from BOTH the Voyage embedding (`voyage_query_embedding`) and
/// the Anthropic answer (`advisor_qa`), so it is recorded under its own
/// `usage_logs.usage_class`. A single text-query request therefore records
/// TWO Voyage rows — one `voyage_query_embedding` (embed) and one
/// `voyage_rerank` (rerank) — which is correct: they are two distinct
/// provider calls. `usage_class` is a free-form text column (1 to 64
/// chars), so no migration is needed for a new class. Exposed as a
/// top-level const so route code and tests reference the same literal
/// instead of hardcoding it.
const String kVoyageRerankUsageClass = 'voyage_rerank';

/// Per-model token-cost rates. Cents per million tokens, stored as ints
/// so we can do integer-arithmetic cost computation without floats.
/// Numbers are list prices per provider as of late 2025 / early 2026 —
/// promote to a runtime config table when prices drift.
class LlmCostRates {
  const LlmCostRates({
    required this.inputCentsPerMillion,
    required this.outputCentsPerMillion,
  });

  final int inputCentsPerMillion;
  final int outputCentsPerMillion;

  /// Compute total cost in whole cents for the given token counts.
  /// Truncates fractional cents — at the dollar/cent precision the
  /// existing accounting layer enforces, this is the right behavior.
  int costCentsFor({required int inputTokens, required int outputTokens}) {
    final inputMicrocents = inputTokens * inputCentsPerMillion;
    final outputMicrocents = outputTokens * outputCentsPerMillion;
    return (inputMicrocents + outputMicrocents) ~/ 1000000;
  }
}

/// Cost rate registry keyed by `modelId`. Looked up at the proxy
/// adapter layer so each request charges the correct per-model rate.
abstract class LlmCostRateRegistry {
  LlmCostRateRegistry._();

  // Anthropic — list prices per https://www.anthropic.com/pricing.
  // Haiku 4.5: $1/MTok input, $5/MTok output → 100/500 cents/MTok.
  // Sonnet 4.6: $3/MTok input, $15/MTok output → 300/1500 cents/MTok.
  static const LlmCostRates _haiku45 = LlmCostRates(
    inputCentsPerMillion: 100,
    outputCentsPerMillion: 500,
  );
  static const LlmCostRates _sonnet46 = LlmCostRates(
    inputCentsPerMillion: 300,
    outputCentsPerMillion: 1500,
  );

  // Gemini — list prices per https://ai.google.dev/pricing.
  // Flash 2.5: $0.075/MTok input, $0.30/MTok output → 7.5/30 cents/MTok
  // (rounded up to 8/30 for integer arithmetic).
  // Pro 2.5: $1.25/MTok input, $5/MTok output → 125/500 cents/MTok.
  static const LlmCostRates _geminiFlash25 = LlmCostRates(
    inputCentsPerMillion: 8,
    outputCentsPerMillion: 30,
  );
  static const LlmCostRates _geminiPro25 = LlmCostRates(
    inputCentsPerMillion: 125,
    outputCentsPerMillion: 500,
  );

  // Voyage embeddings — list price per the official Voyage pricing page
  // https://docs.voyageai.com/docs/pricing (looked up 2026-05-24).
  // voyage-4-large: $0.12 per 1M tokens → 12 cents/MTok. Embeddings bill
  // INPUT tokens only (there is no generated-output token stream), so
  // outputCentsPerMillion is 0. The shared LlmCostRates.costCentsFor still
  // computes correctly: outputTokens contributes 0 regardless of value.
  // TODO(go-live): confirm against Voyage contract before enabling.
  static const LlmCostRates _voyage4Large = LlmCostRates(
    inputCentsPerMillion: 12,
    outputCentsPerMillion: 0,
  );

  // Voyage rerank — list price per the official Voyage pricing page
  // https://docs.voyageai.com/docs/pricing (looked up 2026-05-24).
  // rerank-2.5: $0.05 per 1M tokens → 5 cents/MTok. The rerank endpoint
  // bills the TOTAL number of processed tokens (query + every document),
  // and there is no generated-output token stream, so the whole
  // provider-reported `usage.total_tokens` is charged as INPUT tokens and
  // outputCentsPerMillion is 0. The shared LlmCostRates.costCentsFor still
  // computes correctly: outputTokens contributes 0 regardless of value.
  // TODO(go-live): confirm against Voyage contract before enabling.
  static const LlmCostRates _voyageRerank25 = LlmCostRates(
    inputCentsPerMillion: 5,
    outputCentsPerMillion: 0,
  );

  /// Returns the rate for [modelId], or null when the model is not
  /// recognized (the proxy falls back to a zero charge in that case
  /// AND logs a warning so unknown models don't silently bypass caps).
  static LlmCostRates? rateFor(String modelId) {
    switch (modelId) {
      case AdvisorProviderConstants.haikuModelId:
        return _haiku45;
      case AdvisorProviderConstants.sonnetModelId:
        return _sonnet46;
      case AdvisorProviderConstants.geminiFlashModelId:
        return _geminiFlash25;
      case AdvisorProviderConstants.geminiProModelId:
        return _geminiPro25;
      case AdvisorProviderConstants.voyageEmbeddingModelId:
        return _voyage4Large;
      case AdvisorProviderConstants.voyageRerankModelId:
        return _voyageRerank25;
    }
    return null;
  }
}
