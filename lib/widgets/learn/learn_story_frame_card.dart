// === Variance Coaching V2 (Lane F) : 3-frame Learn story card ==============
// Implements the V2-5 3-frame Learn structure from
// docs/contracts/phase_7_58_primary_driver_contract.md and the binding
// layout in docs/f&f Coaching/variance_tab_v2_mockup.html (the Learn tab,
// `.lc` / `.fstep` / `.lcap` / `.fvis` / `.actioncard`).
//
// Recurring Leak and Repeatable Wins each render as a 3-frame horizontal
// story. Frame 1 = WHAT HAPPENED / WHAT HELD, Frame 2 = WHY IT MATTERS,
// Frame 3 = WHAT TO DO / WHAT TO PROTECT followed by an action card
// ("THE PLAY"). This widget renders one such frame.
//
// All teaching prose is rendered through Lane E's `InlineEmphasisText`
// (the V2-4 renderer). The caller (variance_learn_tab.dart) routes the
// verbatim catalog body through `LearnEmphasisMap` first, which wraps
// exact catalog substrings in the V2-4 causal tokens at RENDER time so
// the mockup `.em-bad` / `.em-good` highlights show. The catalog stays
// byte-for-byte plain; `InlineEmphasisMarkup.stripMarkup` of any body
// this card receives equals the plain catalog sentence exactly.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../variance/inline_emphasis_text.dart';

/// One frame of a 3-frame Learn story (Recurring Leak / Repeatable Wins).
///
/// Maps to the mockup `.lc` card: the `.fstep` step label, the serif
/// `<h3>` heading, an optional `.lcap` caption (frame 1 only), a `.fvis`
/// visual hint chip, the body prose (`InlineEmphasisText`), and an
/// optional `.actioncard` "THE PLAY" pinned to the bottom (frame 3).
class LearnStoryFrameCard extends StatelessWidget {
  /// e.g. `FRAME 1 · WHAT HAPPENED` (mockup `.fstep`).
  final String stepLabel;

  /// Serif heading for the frame (mockup `.lc h3`).
  final String heading;

  /// Optional caption under the heading (mockup `.lcap`). Frame 1 only;
  /// null on frames 2 and 3.
  final String? caption;

  /// The visual-hint chip line (mockup `.fvis`). Plain teaching string;
  /// rendered through `InlineEmphasisText` so any future emphasis markup
  /// promotes consistently. May be null when no hint applies.
  final String? visualHint;

  /// Body prose (mockup `.lc p`). Rendered through `InlineEmphasisText`.
  final String body;

  /// Optional action-card play text (mockup `.actioncard`). Frame 3
  /// only; null on frames 1 and 2.
  final String? actionPlay;

  /// Accent for the top band + step label, matching the section
  /// sentiment (Leak = negative, Wins = positive).
  final Color accent;

  const LearnStoryFrameCard({
    super.key,
    required this.stepLabel,
    required this.heading,
    required this.body,
    required this.accent,
    this.caption,
    this.visualHint,
    this.actionPlay,
  });

  @override
  Widget build(BuildContext context) {
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
          // Top accent band (mockup teaching-surface visual language).
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
                // .fstep step label
                Text(
                  stepLabel,
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
                const SizedBox(height: 8),
                // serif .lc h3 heading
                Text(
                  heading,
                  style: AppTextStyles.display16(
                    color: AppColors.textPrimary,
                  ),
                ),
                if (caption != null && caption!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  // .lcap caption (frame 1 only)
                  Text(
                    caption!,
                    style: AppTextStyles.mono11(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
                if (visualHint != null && visualHint!.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _VisualHint(text: visualHint!),
                ],
                const SizedBox(height: 12),
                // .lc p body, rendered through the V2-4 renderer.
                InlineEmphasisText(
                  body,
                  baseStyle: AppTextStyles.body15(
                    color: AppColors.textSecondary,
                  ),
                ),
                if (actionPlay != null && actionPlay!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _ActionCard(play: actionPlay!),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Mockup `.fvis` — a monospace visual-hint chip on a tinted panel.
class _VisualHint extends StatelessWidget {
  final String text;
  const _VisualHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(9),
      ),
      child: InlineEmphasisText(
        text,
        baseStyle: AppTextStyles.mono12(color: AppColors.textSecondary),
      ),
    );
  }
}

/// Mockup `.actioncard` "THE PLAY" — sunset-accented left border, label
/// + play prose. Frame 3 only.
class _ActionCard extends StatelessWidget {
  final String play;
  const _ActionCard({required this.play});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 12),
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.10),
        border: const Border(
          left: BorderSide(color: AppColors.sunset, width: 3),
        ),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(9),
          bottomRight: Radius.circular(9),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'THE PLAY',
            style: AppTextStyles.mono10(color: AppColors.sunset),
          ),
          const SizedBox(height: 5),
          InlineEmphasisText(
            play,
            baseStyle: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
        ],
      ),
    );
  }
}
