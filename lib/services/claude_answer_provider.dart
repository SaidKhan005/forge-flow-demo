// Forge & Flow — ClaudeAnswerProvider adapter.
//
// 7.57.3a foundation slice. Concrete `AdvisorAnswerProvider` for
// Anthropic's Claude family. Implements the tier dispatch locked into
// the 11a contract:
//
//   tier=quick   -> claude-haiku-4-5  (default)
//   tier=nuanced -> claude-sonnet-4-6
//
// The Anthropic SDK / HTTP gateway is injected as a callback so tests
// can substitute fakes; this slice does not wire real-API gateways
// into production.

import '../domain/services/advisor_answer_provider.dart';
import '../domain/services/advisor_model_routing.dart';
import '../domain/services/advisor_provider_constants.dart';

/// Gateway signature: send `question`/`context` to Anthropic at
/// `modelId` and receive the answer text back.
typedef ClaudeAnswerFn = Future<String> Function({
  required String modelId,
  required String question,
  required String context,
});

class ClaudeAnswerProvider implements AdvisorAnswerProvider {
  final ClaudeAnswerFn _answerFn;
  final AdvisorModelRouting _routing;

  /// [routing] resolves tier -> model id. When omitted, tiers fall back
  /// to the pinned defaults from [AdvisorProviderConstants] (Haiku for
  /// quick, Sonnet for nuanced) — preserving the foundation-slice
  /// constructor behavior for callers that have no override config.
  ClaudeAnswerProvider({
    required ClaudeAnswerFn answerFn,
    AdvisorModelRouting? routing,
  })  : _answerFn = answerFn,
        _routing = routing ?? AdvisorModelRouting.defaults;

  @override
  String get providerId => AdvisorProviderConstants.anthropicProviderId;

  @override
  String modelIdFor(AdvisorTier tier) => _routing.modelIdForTier(tier);

  @override
  Future<AdvisorAnswer> answer({
    required String question,
    required String context,
    AdvisorTier tier = AdvisorTier.quick,
  }) async {
    final modelId = modelIdFor(tier);
    final text = await _answerFn(
      modelId: modelId,
      question: question,
      context: context,
    );
    return AdvisorAnswer(text: text, modelId: modelId, tier: tier);
  }
}
