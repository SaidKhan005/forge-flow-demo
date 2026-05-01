// Forge & Flow — LLMProvider interface.
//
// 7.57.3d rename slice. General-purpose LLM completion seam; the
// concrete adapter lives at `lib/services/claude_llm_provider.dart`.
// The advisor (11b) is one consumer; future workflow automation
// (Phase 12) will be another with the same plumbing.
//
// 11a contract (`docs/phases/post_11a7_stabilization_plan.md`,
// lines 167-169): tiered Sonnet/Haiku routing controlled by the
// `tier` parameter:
//   - tier=quick   -> Haiku  (default)
//   - tier=nuanced -> Sonnet
//
// Lock 7 (`docs/phases/phase_11a/phase_11a_decision_register.md:938-972`):
// `LLMProviderException` carries a `FailureKind` so the circuit breaker
// at the call site can distinguish 5xx / 429 / timeout / cost-breach.
// `classifyLlmFailure` maps thrown exceptions to that taxonomy; unknown
// kinds count toward the consecutive-failure trigger (false positives are
// safer than false negatives for breakers).

import 'dart:async';

import 'circuit_breaker.dart';

/// Tier selection for LLM completions.
enum LLMTier {
  /// Routine turns. Routes to Haiku.
  quick,

  /// Deep turns. Routes to Sonnet.
  nuanced,
}

/// Capabilities a concrete [LLMProvider] may advertise. Consumers
/// inspect [LLMProvider.capabilities] to feature-gate behavior such
/// as prompt caching without depending on the concrete adapter type.
enum LLMProviderCapability {
  /// Provider supports prompt caching for repeated context blocks.
  promptCaching,
}

/// Output of one LLM completion turn.
class LLMCompletion {
  /// Plain-text completion body produced by the underlying model.
  final String text;

  /// Concrete model id the completion was generated with (e.g.
  /// `claude-haiku-4-5` for `quick`, `claude-sonnet-4-6` for `nuanced`
  /// when no dev override is active). Provenance is recorded so the
  /// advisor answer log and any future regression suite can audit which
  /// tier was used.
  final String modelId;

  /// The tier the caller asked for (after default resolution).
  final LLMTier tier;

  const LLMCompletion({
    required this.text,
    required this.modelId,
    required this.tier,
  });
}

abstract class LLMProvider {
  /// Stable provider id (e.g. `anthropic`).
  String get providerId;

  /// Capabilities this provider advertises (e.g. prompt caching).
  Set<LLMProviderCapability> get capabilities;

  /// Resolve [tier] to its concrete model id without performing a call.
  /// Useful for telemetry, dry runs, and regression assertions.
  String modelIdFor(LLMTier tier);

  /// Produce a completion for [question] grounded by [context].
  ///
  /// [tier] defaults to [LLMTier.quick] per the 11a contract.
  Future<LLMCompletion> complete({
    required String question,
    required String context,
    LLMTier tier = LLMTier.quick,
  });
}

/// Exception thrown by LLM providers (or proxy adapters) to signal a
/// classified failure to the circuit breaker. Concrete adapters wrap
/// network / HTTP errors in this type so the breaker can distinguish
/// 5xx / 429 / timeout / cost-breach.
class LLMProviderException implements Exception {
  const LLMProviderException(this.kind, this.message, {this.statusCode});

  final FailureKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'LLMProviderException(${kind.name}): $message';
}

/// Map a thrown error to a [FailureKind] for breaker accounting.
/// Unknown shapes count toward the consecutive-failure trigger.
FailureKind classifyLlmFailure(Object error) {
  if (error is TimeoutException) {
    return FailureKind.timeout;
  }
  if (error is LLMProviderException) {
    return error.kind;
  }
  return FailureKind.unknown;
}
