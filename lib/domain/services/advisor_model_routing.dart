// Forge & Flow — AdvisorModelRouting (pure resolution model).
//
// 7.57.3a-review-fix. Pure value class that resolves the effective
// advisor model ids per tier from optional overrides, exposes a source
// label per tier (`Default` or `Override`), and pins the read-only
// Voyage embedding/rerank values for display surfaces.
//
// No I/O, no async, no SharedPreferences references. Persistence lives
// in `AdvisorModelConfigService`.

import 'advisor_answer_provider.dart';
import 'advisor_provider_constants.dart';

/// Provenance of a resolved advisor model id.
enum AdvisorModelSource {
  /// Pinned default from [AdvisorProviderConstants].
  defaultPinned,

  /// Dev override persisted via [AdvisorModelConfigService].
  userOverride,
}

class AdvisorModelRouting {
  // ── Effective advisor answer routing ──────────────────────────────────────
  /// Effective `quick` tier model id.
  final String effectiveQuickModelId;

  /// Effective `nuanced` tier model id.
  final String effectiveNuancedModelId;

  /// Source of [effectiveQuickModelId].
  final AdvisorModelSource quickSource;

  /// Source of [effectiveNuancedModelId].
  final AdvisorModelSource nuancedSource;

  // ── Pinned Voyage display values (not editable in any tier) ───────────────
  final String voyageEmbeddingProviderId;
  final String voyageEmbeddingModelId;
  final int voyageEmbeddingDimensions;
  final String voyageRerankProviderId;
  final String voyageRerankModelId;

  const AdvisorModelRouting({
    required this.effectiveQuickModelId,
    required this.effectiveNuancedModelId,
    required this.quickSource,
    required this.nuancedSource,
    required this.voyageEmbeddingProviderId,
    required this.voyageEmbeddingModelId,
    required this.voyageEmbeddingDimensions,
    required this.voyageRerankProviderId,
    required this.voyageRerankModelId,
  });

  /// Routing with no overrides — both tiers resolve to their pinned
  /// defaults from [AdvisorProviderConstants].
  static const AdvisorModelRouting defaults = AdvisorModelRouting(
    effectiveQuickModelId: AdvisorProviderConstants.haikuModelId,
    effectiveNuancedModelId: AdvisorProviderConstants.sonnetModelId,
    quickSource: AdvisorModelSource.defaultPinned,
    nuancedSource: AdvisorModelSource.defaultPinned,
    voyageEmbeddingProviderId: AdvisorProviderConstants.voyageProviderId,
    voyageEmbeddingModelId: AdvisorProviderConstants.voyageEmbeddingModelId,
    voyageEmbeddingDimensions: AdvisorProviderConstants.voyageEmbeddingDimensions,
    voyageRerankProviderId: AdvisorProviderConstants.voyageProviderId,
    voyageRerankModelId: AdvisorProviderConstants.voyageRerankModelId,
  );

  /// Resolve a routing from optional dev overrides. Empty / whitespace
  /// override strings count as "no override" — callers that want to
  /// clear an override should call
  /// `AdvisorModelConfigService.resetOverrides()` instead.
  factory AdvisorModelRouting.resolve({
    String? quickOverride,
    String? nuancedOverride,
  }) {
    final hasQuick = quickOverride != null && quickOverride.trim().isNotEmpty;
    final hasNuanced =
        nuancedOverride != null && nuancedOverride.trim().isNotEmpty;
    return AdvisorModelRouting(
      effectiveQuickModelId: hasQuick
          ? quickOverride.trim()
          : AdvisorProviderConstants.haikuModelId,
      effectiveNuancedModelId: hasNuanced
          ? nuancedOverride.trim()
          : AdvisorProviderConstants.sonnetModelId,
      quickSource: hasQuick
          ? AdvisorModelSource.userOverride
          : AdvisorModelSource.defaultPinned,
      nuancedSource: hasNuanced
          ? AdvisorModelSource.userOverride
          : AdvisorModelSource.defaultPinned,
      voyageEmbeddingProviderId: AdvisorProviderConstants.voyageProviderId,
      voyageEmbeddingModelId: AdvisorProviderConstants.voyageEmbeddingModelId,
      voyageEmbeddingDimensions:
          AdvisorProviderConstants.voyageEmbeddingDimensions,
      voyageRerankProviderId: AdvisorProviderConstants.voyageProviderId,
      voyageRerankModelId: AdvisorProviderConstants.voyageRerankModelId,
    );
  }

  /// Effective model id for [tier].
  String modelIdForTier(AdvisorTier tier) {
    switch (tier) {
      case AdvisorTier.quick:
        return effectiveQuickModelId;
      case AdvisorTier.nuanced:
        return effectiveNuancedModelId;
    }
  }

  /// Source of [tier]'s effective model id.
  AdvisorModelSource sourceForTier(AdvisorTier tier) {
    switch (tier) {
      case AdvisorTier.quick:
        return quickSource;
      case AdvisorTier.nuanced:
        return nuancedSource;
    }
  }

  /// Display-friendly source label: `Default` or `Override`.
  String sourceLabelForTier(AdvisorTier tier) {
    switch (sourceForTier(tier)) {
      case AdvisorModelSource.defaultPinned:
        return 'Default';
      case AdvisorModelSource.userOverride:
        return 'Override';
    }
  }
}
