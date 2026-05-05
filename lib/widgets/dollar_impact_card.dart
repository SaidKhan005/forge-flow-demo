// ─── DollarImpactCard — shared Variance + Week Detail widget ─────────────────
//
// Phase 7.55q.10: lifted out of `lib/screens/variance_report.dart` so the
// current-week (live WTD) and week-history (frozen-at-close) surfaces render
// through one source of truth. The previous duplication is what let the two
// cards drift in row count, annualized formula, and footer text. By
// construction now they cannot.
//
// Renders 1–4 stacked impact rows depending on which optional values are
// non-null. The owning screen renders its own section label outside the
// card; this widget is layout + rows + dividers + footer only.
//
// Sign convention: positive `value` (over model) → `−$X` in negative color.
// Negative `value` (under model) → `+$X` in positive color.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

class DollarImpactCard extends StatelessWidget {
  /// Required. The week's own dollar gap. Always rendered as the primary row.
  final double weekImpact;

  /// Optional. Month-to-date impact through the latest closed business date.
  /// Null → row is hidden.
  final double? monthImpact;

  /// Optional. Last-60-days impact through the latest closed business date.
  /// Null → row is hidden.
  final double? sixtyDayImpact;

  /// Optional. Annualized projection, typically `(365/60) × sixtyDayImpact`
  /// when 60-day data is available, else `dollarGap × 52` as fallback.
  /// Null → row is hidden.
  final double? annualizedImpact;

  /// Required. Footer text shown below the rows. The card does not derive
  /// or interpret this — owners pass exactly what should render. Examples:
  /// "Through Tuesday", "As of close, Mar 29", or a static fallback for
  /// legacy rows. Used as the honest fallback when [theoreticalLaborPct]
  /// is null.
  final String footerText;

  /// Optional. The week's mathematical labor floor at the locked target
  /// rates and wages (Jim Taylor ch. 8). When non-null and paired with
  /// [actualLaborPct], the footer renders the
  /// `Best Possible / Actual / Closable Gap` triplet instead of [footerText].
  /// Null on legacy rows where the floor was not preserved at close.
  final double? theoreticalLaborPct;

  /// Optional. The week's actual labor percentage. Pairs with
  /// [theoreticalLaborPct] in the triplet line. Null when the triplet is
  /// not being rendered.
  final double? actualLaborPct;

  const DollarImpactCard({
    super.key,
    required this.weekImpact,
    this.monthImpact,
    this.sixtyDayImpact,
    this.annualizedImpact,
    required this.footerText,
    this.theoreticalLaborPct,
    this.actualLaborPct,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.backgroundSurface,
            AppColors.shimmer,
            AppColors.cardGlow,
          ],
        ),
        border: Border(
          left: const BorderSide(color: AppColors.borderSubtle, width: 4),
          top: BorderSide(
              color: AppColors.borderSubtle.withValues(alpha: 0.6), width: 1),
          right: const BorderSide(color: AppColors.borderSubtle, width: 1),
          bottom: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ImpactRow(value: weekImpact, label: 'this week', primary: true),
          if (monthImpact != null) ...[
            const SizedBox(height: 6),
            _ImpactDivider(),
            const SizedBox(height: 6),
            _ImpactRow(value: monthImpact!, label: 'this month'),
          ],
          if (sixtyDayImpact != null) ...[
            const SizedBox(height: 6),
            _ImpactDivider(),
            const SizedBox(height: 6),
            _ImpactRow(value: sixtyDayImpact!, label: 'last 60 days'),
          ],
          if (annualizedImpact != null) ...[
            const SizedBox(height: 6),
            _ImpactDivider(),
            const SizedBox(height: 6),
            _ImpactRow(value: annualizedImpact!, label: 'annualized'),
          ],
          const SizedBox(height: 12),
          _DepthFooter(
            theoreticalLaborPct: theoreticalLaborPct,
            actualLaborPct: actualLaborPct,
            footerText: footerText,
          ),
        ],
      ),
    );
  }
}

/// Footer renderer. Shows the `Best Possible / Actual / Closable Gap`
/// triplet when the math floor is known; honest fallback to [footerText]
/// otherwise. Phase 7.58.UX.6: theoretical labor % is named as the
/// mathematical floor at the locked target rates and wages — not a
/// corporate target above the floor.
class _DepthFooter extends StatelessWidget {
  final double? theoreticalLaborPct;
  final double? actualLaborPct;
  final String footerText;

  const _DepthFooter({
    required this.theoreticalLaborPct,
    required this.actualLaborPct,
    required this.footerText,
  });

  @override
  Widget build(BuildContext context) {
    final theo = theoreticalLaborPct;
    final actual = actualLaborPct;
    if (theo == null || actual == null) {
      return Text(
        footerText,
        style: AppTextStyles.body13(color: AppColors.textMuted),
      );
    }
    final closableGap = actual - theo;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            'Best Possible: ${theo.toStringAsFixed(1)}%'
            '  ·  Actual: ${actual.toStringAsFixed(1)}%'
            '  ·  Closable Gap: ${Fmt.varPts(closableGap)}',
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }
}

class _ImpactRow extends StatelessWidget {
  final double value;
  final String label;
  final bool primary;
  const _ImpactRow({
    required this.value,
    required this.label,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    final isOver = value > 0;
    final color = isOver ? AppColors.negative : AppColors.positive;
    final sign = isOver ? '\u2212' : '+';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          '$sign\$${Fmt.dollars(value.abs())}',
          style: primary
              ? AppTextStyles.display36(color: color)
              : AppTextStyles.display28(color: color),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: AppTextStyles.mono12(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _ImpactDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: AppColors.borderSubtle.withValues(alpha: 0.5),
    );
  }
}
