// Forge & Flow — AdvisorAnswerProvider interface.
//
// 7.57.3a foundation slice. Pure-formula domain interface; the
// concrete adapter lives at `lib/services/claude_answer_provider.dart`.
//
// 11a contract (`docs/phases/post_11a7_stabilization_plan.md`,
// lines 167-169): tiered Sonnet/Haiku routing controlled by the
// `tier` parameter:
//   - tier=quick   -> Haiku  (default)
//   - tier=nuanced -> Sonnet

/// Tier selection for advisor turns.
enum AdvisorTier {
  /// Routine advisor turns. Routes to Haiku.
  quick,

  /// Deep advisor turns. Routes to Sonnet.
  nuanced,
}

/// Output of one advisor turn.
class AdvisorAnswer {
  /// Plain-text answer body produced by the underlying model.
  final String text;

  /// Concrete model id the answer was generated with (e.g.
  /// `claude-haiku-4-5` for `quick`, `claude-sonnet-4-6` for `nuanced`
  /// when no dev override is active). Provenance is recorded so the
  /// advisor answer log and any future regression suite can audit which
  /// tier was used.
  final String modelId;

  /// The tier the caller asked for (after default resolution).
  final AdvisorTier tier;

  const AdvisorAnswer({
    required this.text,
    required this.modelId,
    required this.tier,
  });
}

abstract class AdvisorAnswerProvider {
  /// Stable provider id (e.g. `anthropic`).
  String get providerId;

  /// Resolve [tier] to its concrete model id without performing a call.
  /// Useful for telemetry, dry runs, and regression assertions.
  String modelIdFor(AdvisorTier tier);

  /// Produce an advisor answer for [question] grounded by [context].
  ///
  /// [tier] defaults to [AdvisorTier.quick] per the 11a contract.
  Future<AdvisorAnswer> answer({
    required String question,
    required String context,
    AdvisorTier tier = AdvisorTier.quick,
  });
}
