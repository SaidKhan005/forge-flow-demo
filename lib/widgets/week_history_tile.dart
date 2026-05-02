// Phase 7.15 — WeekHistoryTile premium page language.
// All data, logic, and navigation behavior unchanged.
// Visual hierarchy and contrast elevated to match This Week design system.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/app_defaults.dart';
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

    // 7.58.UX.5 (F-1): explicit lookup; null → degraded "—" badge.
    final leverCard = LeverCards.lookup(week.primaryLeverId);
    final lever = leverCard?.shortLabel ?? '—';
    final leverColor = leverCard == null
        ? AppColors.textMuted
        : (leverCard.isFavorable ? AppColors.positive : AppColors.negative);

    return InkWell(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [AppColors.backgroundMid, AppColors.cardGlow],
          ),
          border: Border(
            left: BorderSide(color: AppColors.borderSubtle, width: 3),
            top: BorderSide(color: AppColors.borderSubtle, width: 1),
            right: BorderSide(color: AppColors.borderSubtle, width: 1),
            bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Left: week label ────────────────────────────────────────
              SizedBox(
                width: 64,
                child: Text(week.weekLabel,
                    style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600)),
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

              const SizedBox(width: 6),

              // ── Chevron ───────────────────────────────────────────────────
              const Icon(
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
