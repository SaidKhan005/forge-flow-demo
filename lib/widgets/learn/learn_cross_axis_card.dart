// === Variance Coaching V2 (Lane F) : Cross-Axis pair card =================
// Implements the Cross-Axis section of the V2-5 3-frame Learn structure.
// Per docs/contracts/phase_7_58_primary_driver_contract.md V2-5 and the
// binding mockup docs/f&f Coaching/variance_tab_v2_mockup.html
// (`#crossTrack` `.lc` with the `.lb` axis badge), Cross-Axis stays a
// 4-pair swipe: one card per `CrossAxisPairs` entry, each showing
// What happened / What to do / What to study.
//
// All teaching prose is rendered through Lane E's `InlineEmphasisText`
// (V2-4). Catalog strings carry no markup today, so this renders
// identically to plain `Text`; the renderer is wired for forward-compat
// without hand-adding markup to the locked catalog.

import 'package:flutter/material.dart';

import '../../domain/constants/cross_axis_pair_catalog.dart';
import '../../theme/app_theme.dart';
import '../variance/inline_emphasis_text.dart';

/// One Cross-Axis pair card (mockup `#crossTrack` `.lc`).
///
/// Layout: the `.lb` axis-glyph badge, the serif heading (`pair.metric`),
/// then three labelled prose blocks:
///   * What happened  -> `pair.whatHappened`
///   * What to do     -> `pair.whatToDo`
///   * What to study  -> `pair.teachingNote`
class LearnCrossAxisCard extends StatelessWidget {
  final CrossAxisPairData pair;

  /// The CPLH/SPLH glyph badge text (mockup `.lb`, e.g.
  /// `CPLH ↓ · SPLH ↑`).
  final String axisBadge;

  const LearnCrossAxisCard({
    super.key,
    required this.pair,
    required this.axisBadge,
  });

  @override
  Widget build(BuildContext context) {
    // Cross-Axis pairs in the locked catalog are all unfavorable; the
    // accent follows the pair sentiment so a future favorable pair would
    // render green automatically.
    final accent =
        pair.isFavorable ? AppColors.positive : AppColors.negative;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border:
            Border.all(color: accent.withValues(alpha: 0.35), width: 1),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.12),
            blurRadius: 18,
            spreadRadius: -4,
          ),
          const BoxShadow(
            color: Color(0x33000000),
            blurRadius: 20,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 3,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [accent, accent.withValues(alpha: 0.3)],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // .lb axis-glyph badge
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    axisBadge,
                    style: AppTextStyles.mono10(color: accent),
                  ),
                ),
                const SizedBox(height: 10),
                // serif heading = pair.metric
                Text(
                  pair.metric,
                  style: AppTextStyles.display16(
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 14),
                _Block(label: 'What happened.', body: pair.whatHappened),
                const SizedBox(height: 12),
                _Block(label: 'What to do.', body: pair.whatToDo),
                const SizedBox(height: 12),
                _Block(label: 'What to study.', body: pair.teachingNote),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One labelled prose block inside a Cross-Axis card. The bold lead-in
/// label mirrors the mockup's `<b>What happened.</b>` inline lead.
class _Block extends StatelessWidget {
  final String label;
  final String body;
  const _Block({required this.label, required this.body});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppTextStyles.mono12(
            color: AppColors.textPrimary,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 5),
        InlineEmphasisText(
          body,
          baseStyle:
              AppTextStyles.body15(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}
