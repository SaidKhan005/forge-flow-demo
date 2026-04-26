// Forge & Flow — ClaudeLLMProvider adapter.
//
// 7.57.3d rename slice. Concrete `LLMProvider` for Anthropic's Claude
// family. Implements the tier dispatch locked into the 11a contract:
//
//   tier=quick   -> claude-haiku-4-5  (default)
//   tier=nuanced -> claude-sonnet-4-6
//
// The Anthropic SDK / HTTP gateway is injected as a callback so tests
// can substitute fakes; this slice does not wire real-API gateways
// into production.

import '../domain/services/advisor_model_routing.dart';
import '../domain/services/advisor_provider_constants.dart';
import '../domain/services/llm_provider.dart';

/// Gateway signature: send `question`/`context` to Anthropic at
/// `modelId` and receive the completion text back.
typedef ClaudeCompleteFn = Future<String> Function({
  required String modelId,
  required String question,
  required String context,
});

class ClaudeLLMProvider implements LLMProvider {
  final ClaudeCompleteFn _completeFn;
  final AdvisorModelRouting _routing;

  /// [routing] resolves tier -> model id. When omitted, tiers fall back
  /// to the pinned defaults from [AdvisorProviderConstants] (Haiku for
  /// quick, Sonnet for nuanced) — preserving the foundation-slice
  /// constructor behavior for callers that have no override config.
  ClaudeLLMProvider({
    required ClaudeCompleteFn completeFn,
    AdvisorModelRouting? routing,
  })  : _completeFn = completeFn,
        _routing = routing ?? AdvisorModelRouting.defaults;

  @override
  String get providerId => AdvisorProviderConstants.anthropicProviderId;

  @override
  Set<LLMProviderCapability> get capabilities =>
      const {LLMProviderCapability.promptCaching};

  @override
  String modelIdFor(LLMTier tier) => _routing.modelIdForTier(tier);

  @override
  Future<LLMCompletion> complete({
    required String question,
    required String context,
    LLMTier tier = LLMTier.quick,
  }) async {
    final modelId = modelIdFor(tier);
    final text = await _completeFn(
      modelId: modelId,
      question: question,
      context: context,
    );
    return LLMCompletion(text: text, modelId: modelId, tier: tier);
  }
}
