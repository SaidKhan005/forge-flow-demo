import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/meridian_data.dart';
import '../widgets/lever_card.dart';
class VarianceReport extends StatelessWidget {
  const VarianceReport({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              'Variance',
              style: AppTextStyles.display20(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              WeeklyVariance.weekLabel,
              style: AppTextStyles.mono10(),
            ),
          ),

          // Weekly summary table
          _WeeklySummaryTable(),

          const SizedBox(height: 8),

          // Dollar impact card
          _DollarImpactCard(),

          const SizedBox(height: 8),

          // Diagnostic lever card
          LeverCardWidget(data: LeverCards.primaryDemoLever),

          // Plain-language weekly read
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              WeeklyVariance.plainLanguageRead,
              style: AppTextStyles.body13(color: AppColors.secondaryText),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _WeeklySummaryTable extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        children: [
          // Header
          _Row(
            label: 'METRIC',
            theoretical: 'THEORETICAL',
            actual: 'ACTUAL',
            variance: 'VARIANCE',
            isHeader: true,
          ),
          Container(height: 1, color: AppColors.rule),
          _Row(
            label: 'Covers',
            theoretical:
                WeeklyVariance.theoreticalCovers.toString(),
            actual: WeeklyVariance.actualCovers.toString(),
            variance: WeeklyVariance.coversVariance.toString(),
            varianceUnfavorable: WeeklyVariance.coversVariance < 0,
          ),
          Container(height: 1, color: AppColors.rule),
          _Row(
            label: 'FOH Hours',
            theoretical:
                WeeklyVariance.theoreticalFohHours.toString(),
            actual: WeeklyVariance.actualFohHours.toString(),
            variance:
                '+${WeeklyVariance.fohHoursVariance}',
            varianceUnfavorable: WeeklyVariance.fohHoursVariance > 0,
          ),
          Container(height: 1, color: AppColors.rule),
          _Row(
            label: 'BOH Hours',
            theoretical:
                WeeklyVariance.theoreticalBohHours.toString(),
            actual: WeeklyVariance.actualBohHours.toString(),
            variance:
                '+${WeeklyVariance.bohHoursVariance}',
            varianceUnfavorable: WeeklyVariance.bohHoursVariance > 0,
          ),
          Container(height: 1, color: AppColors.rule),
          _Row(
            label: 'FOH Labor %',
            theoretical:
                '${WeeklyVariance.theoreticalFohLaborPct.toStringAsFixed(1)}%',
            actual:
                '${WeeklyVariance.actualFohLaborPct.toStringAsFixed(1)}%',
            variance:
                '+${WeeklyVariance.fohLaborPctVariance.toStringAsFixed(1)} pt',
            varianceUnfavorable: true,
          ),
          Container(height: 1, color: AppColors.rule),
          _Row(
            label: 'BOH Labor %',
            theoretical:
                '${WeeklyVariance.theoreticalBohLaborPct.toStringAsFixed(1)}%',
            actual:
                '${WeeklyVariance.actualBohLaborPct.toStringAsFixed(1)}%',
            variance:
                '+${WeeklyVariance.bohLaborPctVariance.toStringAsFixed(1)} pt',
            varianceUnfavorable: true,
          ),
          Container(height: 1, color: AppColors.rule),
          _Row(
            label: 'Total Labor %',
            theoretical:
                '${WeeklyVariance.theoreticalTotalLaborPct.toStringAsFixed(1)}%',
            actual:
                '${WeeklyVariance.actualTotalLaborPct.toStringAsFixed(1)}%',
            variance:
                '+${WeeklyVariance.totalLaborPctVariance.toStringAsFixed(1)} pts',
            varianceUnfavorable: true,
            isBold: true,
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String theoretical;
  final String actual;
  final String variance;
  final bool isHeader;
  final bool varianceUnfavorable;
  final bool isBold;

  const _Row({
    required this.label,
    required this.theoretical,
    required this.actual,
    required this.variance,
    this.isHeader = false,
    this.varianceUnfavorable = false,
    this.isBold = false,
  });

  @override
  Widget build(BuildContext context) {
    final varianceColor = isHeader
        ? AppColors.secondaryText
        : (varianceUnfavorable ? AppColors.accent : AppColors.positive);

    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: isHeader
                  ? AppTextStyles.mono7()
                  : (isBold
                      ? AppTextStyles.mono10(
                          color: AppColors.primaryText)
                      : AppTextStyles.body11(
                          color: AppColors.primaryText,
                          style: FontStyle.normal)),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              theoretical,
              style: isHeader
                  ? AppTextStyles.mono7()
                  : AppTextStyles.mono10(
                      color: AppColors.secondaryText),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              actual,
              style: isHeader
                  ? AppTextStyles.mono7()
                  : AppTextStyles.mono10(
                      color: AppColors.primaryText),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              variance,
              style: isHeader
                  ? AppTextStyles.mono7()
                  : AppTextStyles.mono10(color: varianceColor),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class _DollarImpactCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'DOLLAR IMPACT',
            style: AppTextStyles.mono7(),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '\$${WeeklyVariance.dollarGapWeekly.toStringAsFixed(0)}',
                style: AppTextStyles.display28(color: AppColors.accent),
              ),
              const SizedBox(width: 8),
              Text(
                'this week',
                style: AppTextStyles.mono10(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '\$${_formatNum(WeeklyVariance.dollarGapAnnualized)}',
                style: AppTextStyles.display20(color: AppColors.accent),
              ),
              const SizedBox(width: 8),
              Text(
                'annualized',
                style: AppTextStyles.mono10(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            WeeklyVariance.annualizedContext,
            style: AppTextStyles.body11(),
          ),
        ],
      ),
    );
  }

  String _formatNum(double n) {
    return n
        .toStringAsFixed(0)
        .replaceAllMapped(
            RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  }
}
