// Phase 7.15 — Week Detail Screen (premium)
// Premium grouped table language matching the This Week design system.
// All data, math, and navigation behavior unchanged.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/app_defaults.dart'; // LeverCards
import '../models/week_record.dart';
import '../services/labor_model.dart';
import '../utils/formatters.dart';
import '../widgets/comparison_group_band.dart';
import '../widgets/comparison_metric_row.dart';
import '../widgets/dollar_impact_card.dart';
import '../widgets/lever_card.dart';
import '../widgets/sticky_section_delegate.dart';

class WeekDetailScreen extends StatelessWidget {
  final WeekRecord week;

  const WeekDetailScreen({super.key, required this.week});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDeep,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: CustomScrollView(
        cacheExtent: 9999,
        slivers: [
          // ── Header ──────────────────────────────────────────────────
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                'Week of ${week.weekLabel}',
                style: AppTextStyles.display20(),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                '${week.shiftsCompleted} shifts · Closed',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Targets: ${week.provenanceLabel}',
                    style: AppTextStyles.mono10(color: AppColors.textMuted),
                  ),
                  if (week.targetCalibrationWindowStart != null &&
                      week.targetCalibrationWindowEnd != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Built from '
                      '${_fmtMonthDay(week.targetCalibrationWindowStart!)} - '
                      '${_fmtMonthDay(week.targetCalibrationWindowEnd!)}',
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ),

          // ── Grouped Summary Table ───────────────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('WEEKLY SUMMARY vs LOCKED TARGETS'),
              ),
              SliverPersistentHeader(
                pinned: true,
                delegate: const StickyColumnHeaderDelegate(),
              ),
              SliverToBoxAdapter(
                child: _GroupedSummaryTable(week: week),
              ),
            ],
          ),

          // ── Dollar Impact Card ─────────────────────────────────────
          // Phase 7.55q.10: now shows the same 4 rows that were on the
          // live Variance card the moment the 14th shift closed (when
          // the closing wrote frozen month + 60-day windows). Legacy
          // rows (closed before V22) fall back to the historical 2-row
          // + boilerplate-footer view; no silent re-modeling.
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('DOLLAR IMPACT'),
              ),
              SliverToBoxAdapter(
                child: DollarImpactCard(
                  weekImpact: week.dollarGap,
                  monthImpact: week.monthDollarImpact,
                  sixtyDayImpact: week.sixtyDayDollarImpact,
                  annualizedImpact: week.frozenAnnualizedImpact ??
                      (week.closedAt == null
                          ? (week.dollarGap >= 0
                              ? week.dollarGapAnnualized
                              : -week.dollarGapAnnualized)
                          : null),
                  footerText: week.closedAt != null
                      ? 'As of close, ${_fmtClosedAt(week.closedAt!)}'
                      : 'At \$3M annual sales. One location.',
                  theoreticalLaborPct: week.theoreticalLaborPct,
                  actualLaborPct: week.actualLaborPct,
                ),
              ),
            ],
          ),

          // ── Primary Lever ──────────────────────────────────────────
          SliverMainAxisGroup(
            slivers: [
              SliverPersistentHeader(
                pinned: true,
                delegate: StickySectionDelegate('PRIMARY DRIVER'),
              ),
              SliverToBoxAdapter(
                child: Builder(builder: (context) {
                  // 7.58.UX.5 (F-1): explicit lookup; null → degraded card.
                  final lever = LeverCards.lookup(week.primaryLeverId);
                  if (lever == null) {
                    return const LeverCardNotYetAvailable();
                  }
                  // 7.58.UX.1: per-axis dollar attribution. Locked targets
                  // are required for closed weeks; if a legacy row lacks
                  // them, skip attribution honestly rather than silently
                  // re-modeling.
                  Map<String, double>? dollarImpactByAxis;
                  if (week.targetCPLH != null &&
                      week.targetSPLH != null &&
                      week.targetPPA != null &&
                      week.targetFohWage != null &&
                      week.targetBohWage != null) {
                    dollarImpactByAxis =
                        LaborModel.attributeDollarImpactByAxis(
                      actualCovers: week.totalCovers,
                      forecastCovers: week.forecastCovers,
                      actualFohHours: week.totalFohHours,
                      actualBohHours: week.totalBohHours,
                      avgPPA: week.avgPPA,
                      targetCPLH: week.storedTargetCPLH,
                      targetSPLH: week.storedTargetSPLH,
                      targetPPA: week.storedTargetPPA,
                      targetFohWage: week.storedTargetFohWage,
                      targetBohWage: week.storedTargetBohWage,
                      avgCPLH: week.avgCPLH,
                      avgSPLH: week.avgSPLH,
                      avgFohBlendedWage: week.hasActualBlendedWageTruth
                          ? week.blendedFohWage
                          : null,
                      avgBohBlendedWage: week.hasActualBlendedWageTruth
                          ? week.blendedBohWage
                          : null,
                    );
                  }
                  return LeverCardWidget(
                    data: lever,
                    dollarImpactByAxis: dollarImpactByAxis,
                    // 7.58.UX.8 — OPZ-aware row annotation. `WeekRecord`
                    // does not yet preserve the OPZ ceiling alongside
                    // its locked target rates, so closed-week rows pass
                    // null and the annotation honestly stays off until
                    // the ceiling is captured at close. This matches
                    // the existing locked-target null fallback above:
                    // no silent re-modeling against the current active
                    // profile's ceiling, which would mis-label closed
                    // weeks if the cycle's OPZ band has shifted since.
                    actualCPLH: week.avgCPLH,
                    opzCeilingCPLH: null,
                    actualSPLH: week.avgSPLH,
                    opzCeilingSPLH: null,
                  );
                }),
              ),
            ],
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }
}

// ─── Grouped Summary Table ───────────────────────────────────────────────────

class _GroupedSummaryTable extends StatelessWidget {
  final WeekRecord week;
  const _GroupedSummaryTable({required this.week});

  @override
  Widget build(BuildContext context) {
    final coversVar = week.totalCovers - week.targetCovers;
    final ppaVar = week.avgPPA - week.storedTargetPPA;
    final cplhVar = week.avgCPLH - week.storedTargetCPLH;
    final splhVar = week.avgSPLH - week.storedTargetSPLH;

    // ── Preserved locked plan hours (7.55q.5) ────────────────────────────
    // FOH / BOH Hours target rows and the target blended wage both
    // depend on the preserved locked plan hours. When absent (legacy
    // row without a locked snapshot captured at close), render "—"
    // for the target cells instead of re-modeling from actuals.
    final preservedFohHours = week.preservedTargetFohHours;
    final preservedBohHours = week.preservedTargetBohHours;
    final hasPreservedPlanHours =
        preservedFohHours != null && preservedBohHours != null;

    // ── Weighted blended wage (7.55q.5) ──────────────────────────────────
    // Actual blended wage is hour-weighted over the closed actual FOH/BOH
    // hour mix. Target blended wage is hour-weighted over the preserved
    // locked plan FOH/BOH hours. Replaces the pre-7.55q.5 unweighted
    // (FOH wage + BOH wage) / 2 shortcut, which was mathematically wrong
    // as a "blended wage" metric.
    final totalActualHours = week.totalFohHours + week.totalBohHours;
    final double? actualBlendedWage =
        week.hasActualBlendedWageTruth && totalActualHours > 0
            ? (week.totalFohHours * week.blendedFohWage +
                    week.totalBohHours * week.blendedBohWage) /
                totalActualHours
            : null;
    final double? targetBlendedWage = hasPreservedPlanHours
        ? _weightedBlendedWage(
            preservedFohHours,
            preservedBohHours,
            week.storedTargetFohWage,
            week.storedTargetBohWage,
          )
        : null;
    final double? wageVar = targetBlendedWage != null &&
            actualBlendedWage != null
        ? actualBlendedWage - targetBlendedWage
        : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Column header (TARGET | ACTUAL | VAR) extracted to a sticky
          // SliverPersistentHeader in the sliver tree above.

          // ── CONDITIONS ──────────────────────────────────────────────
          const ComparisonGroupBand('CONDITIONS'),
          ComparisonMetricRow(
            label: 'Covers',
            target: week.targetCovers.toString(),
            actual: week.totalCovers.toString(),
            variance: Fmt.varStr(coversVar),
            varColor: Fmt.varColor('Covers', coversVar.toDouble()),
            verticalPadding: 14,
          ),
          _divider(),
          ComparisonMetricRow(
            label: 'Blended Wage',
            target: targetBlendedWage != null
                ? '\$${targetBlendedWage.toStringAsFixed(2)}'
                : '—',
            actual: actualBlendedWage != null
                ? '\$${actualBlendedWage.toStringAsFixed(2)}'
                : 'â€”',
            variance: wageVar != null ? Fmt.varDollars(wageVar) : '—',
            varColor: wageVar != null
                ? Fmt.varColor('Blended Wage', wageVar)
                : AppColors.textMuted,
            verticalPadding: 14,
          ),

          // ── EXECUTION ───────────────────────────────────────────────
          const ComparisonGroupBand('EXECUTION'),
          ComparisonMetricRow(
            label: 'PPA',
            target: '\$${week.storedTargetPPA.toStringAsFixed(2)}',
            actual: '\$${week.avgPPA.toStringAsFixed(2)}',
            variance: Fmt.varDollars(ppaVar),
            varColor: Fmt.varColor('PPA', ppaVar),
            verticalPadding: 14,
          ),
          _divider(),
          ComparisonMetricRow(
            label: 'FOH Hours',
            target: preservedFohHours != null
                ? preservedFohHours.toString()
                : '—',
            actual: week.totalFohHours.toString(),
            variance: preservedFohHours != null
                ? Fmt.varStr(week.totalFohHours - preservedFohHours)
                : '—',
            varColor: preservedFohHours != null
                ? Fmt.varColor('FOH Hours',
                    (week.totalFohHours - preservedFohHours).toDouble())
                : AppColors.textMuted,
            verticalPadding: 14,
          ),
          _divider(),
          ComparisonMetricRow(
            label: 'BOH Hours',
            target: preservedBohHours != null
                ? preservedBohHours.toString()
                : '—',
            actual: week.totalBohHours.toString(),
            variance: preservedBohHours != null
                ? Fmt.varStr(week.totalBohHours - preservedBohHours)
                : '—',
            varColor: preservedBohHours != null
                ? Fmt.varColor('BOH Hours',
                    (week.totalBohHours - preservedBohHours).toDouble())
                : AppColors.textMuted,
            verticalPadding: 14,
          ),
          _divider(),
          ComparisonMetricRow(
            label: 'CPLH',
            target: week.storedTargetCPLH.toStringAsFixed(2),
            actual: week.avgCPLH.toStringAsFixed(2),
            variance: Fmt.varDelta(cplhVar),
            varColor: Fmt.varColor('CPLH', cplhVar),
            verticalPadding: 14,
          ),
          _divider(),
          ComparisonMetricRow(
            label: 'SPLH',
            target: '\$${week.storedTargetSPLH.toStringAsFixed(0)}',
            actual: '\$${week.avgSPLH.toStringAsFixed(0)}',
            variance: Fmt.varDollars(splhVar),
            varColor: Fmt.varColor('SPLH', splhVar),
            verticalPadding: 14,
          ),

          // ── OUTCOMES ────────────────────────────────────────────────
          const ComparisonGroupBand('OUTCOMES'),
          ComparisonMetricRow(
            label: 'Total Labor %',
            target: '${week.theoreticalLaborPct.toStringAsFixed(1)}%',
            actual: '${week.actualLaborPct.toStringAsFixed(1)}%',
            variance: Fmt.varPts(week.laborPctVariance),
            varColor: Fmt.varColor('Total Labor %', week.laborPctVariance),
            isBold: true,
            verticalPadding: 14,
          ),
        ],
      ),
    );
  }

  /// 7.55q.5 — hour-weighted blended wage.
  /// `(fohHours × fohWage + bohHours × bohWage) / (fohHours + bohHours)`.
  /// Returns 0.0 when the hour inputs sum to zero.
  static double _weightedBlendedWage(
    int fohHours,
    int bohHours,
    double fohWage,
    double bohWage,
  ) {
    final totalHours = fohHours + bohHours;
    if (totalHours <= 0) return 0.0;
    return (fohHours * fohWage + bohHours * bohWage) / totalHours;
  }

  static Widget _divider() =>
      Container(height: 1, color: AppColors.borderSubtle);
}


// ─── Closed-at footer formatting ─────────────────────────────────────────────
// 'YYYY-MM-DD' → 'Mon DD'. Mirrors the month-array style in
// shift_service._weekLabelFromWeekId rather than introducing a new
// shared util — keeps scope tight for this slice.

String _fmtClosedAt(String iso) {
  return _fmtMonthDay(iso);
}

String _fmtMonthDay(String iso) {
  final parts = iso.split('-');
  if (parts.length != 3) return iso;
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (month == null || day == null || month < 1 || month > 12) return iso;
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${months[month - 1]} $day';
}
