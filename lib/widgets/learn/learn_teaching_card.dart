import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';

/// Read-only teaching card for the Variance > Learn carousel.
///
/// Forked from Barrio's `LearningSurfaceCard` with the interactive
/// quiz/decision code path removed. Uses Forge & Flow styling tokens
/// (`AppColors`, `AppTextStyles`) instead of Barrio's dark glass +
/// Playfair palette so the card reads as part of the same app as the
/// wage-mix / dollar-impact / variance cards.
///
/// Layout: accent pill badge + card title on top, optional [trailing]
/// slot (used for Leak Snapshot / Wins Snapshot mini-content), then the
/// body copy. Rounded 8px, sunset-accented border, gradient fill.
class LearnTeachingCard extends StatelessWidget {
  final String badgeLabel;
  final Color badgeColor;

  /// Optional card title. When null (or empty), only the badge renders
  /// in the header row — used by teaching cards inside a chapter that
  /// would otherwise repeat the same lever metric label on every card.
  final String? title;
  final String body;

  /// Optional pre-body content slot — used by the Leak/Wins Snapshot
  /// cards to render chips + metric rows before the body copy.
  final Widget? trailing;

  const LearnTeachingCard({
    super.key,
    required this.badgeLabel,
    required this.badgeColor,
    this.title,
    required this.body,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final hasTitle = title != null && title!.isNotEmpty;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(
            color: badgeColor.withValues(alpha: 0.35), width: 1),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: badgeColor.withValues(alpha: 0.12),
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
          // Top accent band echoing the teaching-surface visual language
          Container(
            height: 3,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  badgeColor,
                  badgeColor.withValues(alpha: 0.3),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Badge + optional title row. The title is hidden on
                // teaching cards that share a lever metric with their
                // sibling cards so "Covers came in light" / "PPA above
                // target" doesn't repeat four times across a chapter.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CardBadge(label: badgeLabel, color: badgeColor),
                    if (hasTitle) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          title!,
                          style: AppTextStyles.mono14(
                              color: AppColors.textPrimary,
                              weight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ],
                ),
                if (trailing != null) ...[
                  const SizedBox(height: 14),
                  trailing!,
                ],
                const SizedBox(height: 14),
                Container(
                    height: 1, color: AppColors.borderSubtle),
                const SizedBox(height: 14),
                // Body copy
                Text(
                  body,
                  style: AppTextStyles.body15(
                      color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CardBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _CardBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.08),
          ],
        ),
        border: Border.all(color: color.withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono8(color: color),
      ),
    );
  }
}
