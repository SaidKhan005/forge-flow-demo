// Forge & Flow — GeminiLLMProvider adapter.
//
// Block 2 fallback slice. Concrete `LLMProvider` for Google's Gemini
// family, used by the advisor proxy as the second slot in the
// fallback chain (anthropic -> gemini -> cached -> refusal). Tier
// dispatch:
//
//   tier=quick   -> gemini-2.5-flash  (default fallback)
//   tier=nuanced -> gemini-2.5-pro    (reserved)
//
// The Gemini SDK call is injected as a callback so this file stays
// SDK-free — the `google_generative_ai` import lives in
// `tool/advisor_proxy/proxy_bootstrap.dart` (server-side only). Client
// builds never carry the Gemini SDK or the GEMINI_API_KEY (Hard
// Promise #7 in CLAUDE.md).
//
// Streaming: the production callback uses `generateContentStream`
// under the hood and accumulates chunks. The optional `onChunk` hook
// in [GeminiCompleteFn] lets tests observe chunked arrival without
// changing the [LLMProvider] interface (Hard Constraint #1).

import '../domain/services/advisor_provider_constants.dart';
import '../domain/services/llm_provider.dart';

/// Gateway signature: send `question`/`context` to Gemini at `modelId`
/// and receive the (already concatenated) completion text back. The
/// optional [onChunk] hook fires once per stream chunk so tests can
/// assert that streaming actually happened.
typedef GeminiCompleteFn = Future<String> Function({
  required String modelId,
  required String question,
  required String context,
  void Function(String chunk)? onChunk,
});

/// Optional observer wired into the provider at construction time. The
/// provider forwards this to every [GeminiCompleteFn] call so callers
/// can audit streaming chunks without re-plumbing the seam at every
/// call site.
typedef GeminiChunkObserver = void Function(String chunk);

class GeminiLLMProvider implements LLMProvider {
  GeminiLLMProvider({
    required GeminiCompleteFn completeFn,
    GeminiChunkObserver? onChunkObserver,
  })  : _completeFn = completeFn,
        _onChunkObserver = onChunkObserver;

  final GeminiCompleteFn _completeFn;
  final GeminiChunkObserver? _onChunkObserver;

  @override
  String get providerId => AdvisorProviderConstants.geminiProviderId;

  /// Gemini does not expose Anthropic-style explicit prompt caching
  /// in the public API today, so this provider advertises no
  /// capabilities. Future work may add `LLMProviderCapability` flags
  /// for context caching once Google ships the equivalent surface.
  @override
  Set<LLMProviderCapability> get capabilities =>
      const <LLMProviderCapability>{};

  @override
  String modelIdFor(LLMTier tier) {
    switch (tier) {
      case LLMTier.quick:
        return AdvisorProviderConstants.geminiFlashModelId;
      case LLMTier.nuanced:
        return AdvisorProviderConstants.geminiProModelId;
    }
  }

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
      onChunk: _onChunkObserver,
    );
    return LLMCompletion(text: text, modelId: modelId, tier: tier);
  }
}
