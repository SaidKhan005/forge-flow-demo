// Phase 7.15 — WeekHistoryTile premium page language.
// All data, logic, and navigation behavior unchanged.
// Visual hierarchy and contrast elevated to match This Week design system.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/legacy_fixture_data.dart';
import '../models/week_record.dart';
import '../utils/formatters.dart';

class WeekHistoryTile extends StatelessWidget {
  final WeekRecord week;
  final VoidCallback? onTap;

  const WeekHistoryTile({super.key, required this.week, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isOver = week.isOverModel;
    final gapColor = isOver ? AppColors.negative : AppColors.positive;

    final gapSign = isOver ? '−' : '+';
    final gapFormatted = Fmt.dollars(week.dollarGap.abs());

    final varSign = isOver ? '−' : '+';
    final varAbs = week.laborPctVariance.abs().toStringAsFixed(1);

    final leverCard = LeverCards.all.firstWhere(
      (l) => l.id == week.primaryLeverId,
      orElse: () => LeverCards.coversDown,
    );
    final lever = leverCard.shortLabel;
    final leverColor =
        leverCard.isFavorable ? AppColors.positive : AppColors.negative;
    final sideLabel = _sideShortLabel(leverCard.side);

    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [AppColors.backgroundMid, AppColors.cardGlow],
          ),
          border: Border(
            left: const BorderSide(color: AppColors.borderSubtle, width: 3),
            top: const BorderSide(color: AppColors.borderSubtle, width: 1),
            right: const BorderSide(color: AppColors.borderSubtle, width: 1),
            bottom: const BorderSide(color: AppColors.borderSubtle, width: 1),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Left: week label + shifts completed ─────────────────────
              SizedBox(
                width: 84,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(week.weekLabel,
                        style: AppTextStyles.mono14(
                            color: AppColors.textPrimary,
                            weight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text(
                      '${week.shiftsCompleted} shifts',
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      week.provenanceLabel,
                      style: AppTextStyles.mono8(color: AppColors.textMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // ── Variance pts ─────────────────────────────────────────────
              Expanded(
                flex: 2,
                child: Text(
                  '$varSign$varAbs pts',
                  style: AppTextStyles.mono12(color: gapColor),
                  textAlign: TextAlign.right,
                ),
              ),

              const SizedBox(width: 10),

              // ── Dollar gap ────────────────────────────────────────────────
              Expanded(
                flex: 3,
                child: Text(
                  '$gapSign\$$gapFormatted',
                  style: AppTextStyles.mono14(
                      color: gapColor, weight: FontWeight.w700),
                  textAlign: TextAlign.right,
                ),
              ),

              const SizedBox(width: 8),

              // ── Lever badge ───────────────────────────────────────────────
              _LeverBadge(label: lever, color: leverColor),

              const SizedBox(width: 4),

              // ── Side badge ────────────────────────────────────────────────
              _LeverBadge(label: sideLabel, color: AppColors.textMuted),

              const SizedBox(width: 6),

              // ── Chevron ───────────────────────────────────────────────────
              Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _sideShortLabel(LeverSide side) {
  switch (side) {
    case LeverSide.foh:  return 'FOH';
    case LeverSide.boh:  return 'BOH';
    case LeverSide.both: return 'BOTH';
  }
}

class _LeverBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _LeverBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono8(color: color),
        textAlign: TextAlign.center,
      ),
    );
  }
}
