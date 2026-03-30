// Phase 7.15 — Week Detail Screen (premium)
// Premium grouped table language matching the This Week design system.
// All data, math, and navigation behavior unchanged.

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/meridian_data.dart';
import '../models/week_record.dart';
import '../utils/formatters.dart';
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
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                '${week.shiftsCompleted} shifts · Closed',
                style: AppTextStyles.body13(color: AppColors.textMuted),
              ),
            ),

            // ── Grouped Summary Table ───────────────────────────────────
            _SectionLabel('WEEKLY SUMMARY vs BASELINE'),
            const SizedBox(height: 8),
            _GroupedSummaryTable(week: week),

            const SizedBox(height: 20),

            // ── Dollar Impact Card ─────────────────────────────────────
            _DollarImpactCard(week: week),

            const SizedBox(height: 16),

            // ── Primary Lever ──────────────────────────────────────────
            _SectionLabel('PRIMARY DRIVER'),
            const SizedBox(height: 8),
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
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 3, height: 14, color: AppColors.tealPrimary),
            const SizedBox(width: 8),
            Text(text,
                style: AppTextStyles.mono10(color: AppColors.textSecondary)),
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
    final ppaVar = week.avgPPA - BaselineData.derivedTargetPPA;
    final cplhVar = week.avgCPLH - BaselineData.derivedTargetCPLH;
    final splhVar = week.avgSPLH - BaselineData.derivedTargetSPLH;
    final fohVar = week.totalFohHours - week.targetFohHours;
    final bohVar = week.totalBohHours - week.targetBohHours;

    // Blended wage
    final actualBlendedWage = (week.blendedFohWage + week.blendedBohWage) / 2;
    final targetBlendedWage =
        (MeridianConfig.fohWage + MeridianConfig.bohWage) / 2;
    final wageVar = actualBlendedWage - targetBlendedWage;

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
            target: '\$${targetBlendedWage.toStringAsFixed(2)}',
            actual: '\$${actualBlendedWage.toStringAsFixed(2)}',
            variance: Fmt.varDollars(wageVar),
            varColor: Fmt.varColor('Blended Wage', wageVar),
          ),

          // ── EXECUTION ───────────────────────────────────────────────
          _GroupBand('EXECUTION'),
          _TableRow(
            label: 'PPA',
            target: '\$${BaselineData.derivedTargetPPA.toStringAsFixed(2)}',
            actual: '\$${week.avgPPA.toStringAsFixed(2)}',
            variance: Fmt.varDollars(ppaVar),
            varColor: Fmt.varColor('PPA', ppaVar),
          ),
          _divider(),
          _TableRow(
            label: 'FOH Hours',
            target: week.targetFohHours.toString(),
            actual: week.totalFohHours.toString(),
            variance: Fmt.varStr(fohVar),
            varColor: Fmt.varColor('FOH Hours', fohVar.toDouble()),
          ),
          _divider(),
          _TableRow(
            label: 'BOH Hours',
            target: week.targetBohHours.toString(),
            actual: week.totalBohHours.toString(),
            variance: Fmt.varStr(bohVar),
            varColor: Fmt.varColor('BOH Hours', bohVar.toDouble()),
          ),
          _divider(),
          _TableRow(
            label: 'CPLH',
            target: BaselineData.derivedTargetCPLH.toStringAsFixed(2),
            actual: week.avgCPLH.toStringAsFixed(2),
            variance: Fmt.varDelta(cplhVar),
            varColor: Fmt.varColor('CPLH', cplhVar),
          ),
          _divider(),
          _TableRow(
            label: 'SPLH',
            target: '\$${BaselineData.derivedTargetSPLH.toStringAsFixed(0)}',
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

          // ── Partial-week footnote ───────────────────────────────────
          if (week.shiftsCompleted < 14)
            Container(
              color: AppColors.backgroundDeep,
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
              child: Text(
                '* Target prorated for ${week.shiftsCompleted} of 14 shifts completed.',
                style: AppTextStyles.mono8(color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
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
          top: BorderSide(color: AppColors.tealPrimary, width: 3),
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                style: AppTextStyles.mono8(color: AppColors.tealPrimary),
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
          Container(width: 2, height: 10, color: AppColors.tealSoft),
          const SizedBox(width: 6),
          Text(label,
              style: AppTextStyles.mono8(color: AppColors.tealSoft)),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
                height: 1,
                color: AppColors.tealSoft.withValues(alpha: 0.2)),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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

// ─── Dollar Impact Card ──────────────────────────────────────────────────────

class _DollarImpactCard extends StatelessWidget {
  final WeekRecord week;
  const _DollarImpactCard({required this.week});

  @override
  Widget build(BuildContext context) {
    final isOver = week.isOverModel;
    final accentColor = isOver ? AppColors.negative : AppColors.positive;
    final sign = isOver ? '−' : '+';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundSurface, AppColors.shimmer, AppColors.cardGlow],
        ),
        border: Border(
          left: BorderSide(color: accentColor, width: 4),
          top: BorderSide(
              color: accentColor.withValues(alpha: 0.15), width: 1),
          right: const BorderSide(color: AppColors.borderSubtle, width: 1),
          bottom: const BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('DOLLAR IMPACT',
              style: AppTextStyles.mono11(color: AppColors.textMuted)),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('$sign\$${Fmt.dollars(week.dollarGap.abs())}',
                  style: AppTextStyles.display36(color: accentColor)),
              const SizedBox(width: 10),
              Text('this week',
                  style: AppTextStyles.mono12(
                      color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            height: 1,
            color: AppColors.borderSubtle.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text('$sign\$${Fmt.dollars(week.dollarGapAnnualized.abs())}',
                  style: AppTextStyles.display28(color: accentColor)),
              const SizedBox(width: 10),
              Text('annualized',
                  style: AppTextStyles.mono12(
                      color: AppColors.textSecondary)),
            ],
          ),
          const SizedBox(height: 12),
          Text('At \$3M annual sales. One location.',
              style: AppTextStyles.body13(color: AppColors.textMuted)),
        ],
      ),
    );
  }
}
