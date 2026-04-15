// Phase 7.15 — Week Detail Screen (premium)
// Premium grouped table language matching the This Week design system.
// All data, math, and navigation behavior unchanged.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/legacy_fixture_data.dart'; // LeverCards
import '../models/week_record.dart';
import '../utils/formatters.dart';
import '../widgets/dollar_impact_card.dart';
import '../widgets/lever_card.dart';

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
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Text(
                'Week of ${week.weekLabel}',
                style: AppTextStyles.display20(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                '${week.shiftsCompleted} shifts · Closed',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                'Targets: ${week.provenanceLabel}',
                style: AppTextStyles.mono10(color: AppColors.textMuted),
              ),
            ),

            // ── Grouped Summary Table ───────────────────────────────────
            _SectionLabel('WEEKLY SUMMARY vs LOCKED TARGETS'),
            _GroupedSummaryTable(week: week),

            const SizedBox(height: 20),

            // ── Dollar Impact Card ─────────────────────────────────────
            // Phase 7.55q.10: now shows the same 4 rows that were on the
            // live Variance card the moment the 14th shift closed (when
            // the closing wrote frozen month + 60-day windows). Legacy
            // rows (closed before V22) fall back to the historical 2-row
            // + boilerplate-footer view; no silent re-modeling.
            _SectionLabel('DOLLAR IMPACT'),
            DollarImpactCard(
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
            ),

            const SizedBox(height: 16),

            // ── Primary Lever ──────────────────────────────────────────
            _SectionLabel('PRIMARY DRIVER'),
            Builder(builder: (context) {
              final lever = LeverCards.all.firstWhere(
                (l) => l.id == week.primaryLeverId,
                orElse: () => LeverCards.coversDown,
              );
              return LeverCardWidget(data: lever);
            }),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ─── Section label — teal accent ─────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 32, 16, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 20,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [AppColors.sunset, AppColors.sunsetDark],
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Text(text,
                    style: AppTextStyles.mono14(color: AppColors.textPrimary, weight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 2,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.sunset, AppColors.sunsetDark],
                ),
              ),
            ),
          ],
        ),
      );
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
          // ── Column header band ──────────────────────────────────────
          _ColumnHeader(),

          // ── CONDITIONS ──────────────────────────────────────────────
          _GroupBand('CONDITIONS'),
          _TableRow(
            label: 'Covers',
            target: week.targetCovers.toString(),
            actual: week.totalCovers.toString(),
            variance: Fmt.varStr(coversVar),
            varColor: Fmt.varColor('Covers', coversVar.toDouble()),
          ),
          _divider(),
          _TableRow(
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
          ),

          // ── EXECUTION ───────────────────────────────────────────────
          _GroupBand('EXECUTION'),
          _TableRow(
            label: 'PPA',
            target: '\$${week.storedTargetPPA.toStringAsFixed(2)}',
            actual: '\$${week.avgPPA.toStringAsFixed(2)}',
            variance: Fmt.varDollars(ppaVar),
            varColor: Fmt.varColor('PPA', ppaVar),
          ),
          _divider(),
          _TableRow(
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
          ),
          _divider(),
          _TableRow(
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
          ),
          _divider(),
          _TableRow(
            label: 'CPLH',
            target: week.storedTargetCPLH.toStringAsFixed(2),
            actual: week.avgCPLH.toStringAsFixed(2),
            variance: Fmt.varDelta(cplhVar),
            varColor: Fmt.varColor('CPLH', cplhVar),
          ),
          _divider(),
          _TableRow(
            label: 'SPLH',
            target: '\$${week.storedTargetSPLH.toStringAsFixed(0)}',
            actual: '\$${week.avgSPLH.toStringAsFixed(0)}',
            variance: Fmt.varDollars(splhVar),
            varColor: Fmt.varColor('SPLH', splhVar),
          ),

          // ── OUTCOMES ────────────────────────────────────────────────
          _GroupBand('OUTCOMES'),
          _TableRow(
            label: 'Total Labor %',
            target: '${week.theoreticalLaborPct.toStringAsFixed(1)}%',
            actual: '${week.actualLaborPct.toStringAsFixed(1)}%',
            variance: Fmt.varPts(week.laborPctVariance),
            varColor: Fmt.varColor('Total Labor %', week.laborPctVariance),
            isBold: true,
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

// ─── Column header band ──────────────────────────────────────────────────────

class _ColumnHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border(
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          const Expanded(flex: 5, child: SizedBox()),
          Expanded(
            flex: 3,
            child: Text('TARGET',
                style: AppTextStyles.mono8(color: AppColors.textMuted),
                textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 3,
            child: Text('ACTUAL',
                style: AppTextStyles.mono8(color: AppColors.textSecondary),
                textAlign: TextAlign.right),
          ),
          Expanded(
            flex: 3,
            child: Text('VAR',
                style: AppTextStyles.mono8(color: AppColors.sunsetDark),
                textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}

// ─── Group band ──────────────────────────────────────────────────────────────

class _GroupBand extends StatelessWidget {
  final String label;
  const _GroupBand(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.backgroundDeep,
      padding: const EdgeInsets.fromLTRB(14, 7, 14, 7),
      child: Row(
        children: [
          Container(width: 2, height: 10, color: AppColors.sunsetDark),
          const SizedBox(width: 6),
          Text(label,
              style: AppTextStyles.mono8(color: AppColors.sunsetDark)),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
                height: 1,
                color: AppColors.sunsetDark.withValues(alpha: 0.2)),
          ),
        ],
      ),
    );
  }
}

// ─── Table row ───────────────────────────────────────────────────────────────

class _TableRow extends StatelessWidget {
  final String label;
  final String target;
  final String actual;
  final String variance;
  final Color varColor;
  final bool isBold;

  const _TableRow({
    required this.label,
    required this.target,
    required this.actual,
    required this.variance,
    this.varColor = AppColors.textMuted,
    this.isBold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      child: Row(
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: isBold
                  ? AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w600)
                  : AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              target,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              actual,
              style: isBold
                  ? AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w600)
                  : AppTextStyles.mono12(color: AppColors.textPrimary),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              variance,
              style: AppTextStyles.mono14(
                  color: varColor, weight: FontWeight.w700),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Closed-at footer formatting ─────────────────────────────────────────────
// 'YYYY-MM-DD' → 'Mon DD'. Mirrors the month-array style in
// shift_service._weekLabelFromWeekId rather than introducing a new
// shared util — keeps scope tight for this slice.

String _fmtClosedAt(String iso) {
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
