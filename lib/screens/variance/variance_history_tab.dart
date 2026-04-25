// Phase 7.55o.2 — Variance "History" tab.
//
// Extracted from lib/screens/variance_report.dart. Owns the History tab,
// its data loader, the teaching summary card, and the evidence cards.
// Behaviour, labels, navigation, and fallback rules are unchanged from
// the pre-split implementation.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/legacy_fixture_data.dart';
import '../../data/shift_data_source.dart';
import '../../models/history_benchmark_daypart_summary.dart';
import '../../models/history_pattern_record.dart';
import '../../models/shift_record.dart';
import '../../models/week_record.dart';
import '../../services/daypart_evidence_visibility_policy.dart';
import '../../services/history_benchmark_daypart_read_service.dart';
import '../../services/history_teaching_analyzer.dart';
import '../../theme/app_theme.dart';
import '../../widgets/sticky_section_delegate.dart';
import '../../widgets/week_history_tile.dart';
import '../week_detail_screen.dart';
import 'variance_shared_widgets.dart';

class _TeachingSummaryCard extends StatelessWidget {
  final HistoryTeachingSummary summary;
  final LeverCardData leakCard;
  final int weekCount;
  final int totalHistoricalDayparts;
  final List<HistoryBenchmarkDaypartSummary> benchmarkDayparts;

  const _TeachingSummaryCard({
    required this.summary,
    required this.leakCard,
    required this.weekCount,
    required this.totalHistoricalDayparts,
    required this.benchmarkDayparts,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // MOST COMMON LEAK
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MOST COMMON LEAK',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
                const SizedBox(height: 8),
                _LeakEvidenceCard(
                  leakCard: leakCard,
                  repeatCount: summary.mostCommonLeakCount,
                  totalHistoricalDayparts: totalHistoricalDayparts,
                ),
              ],
            ),
          ),
          Container(height: 1, color: AppColors.borderSubtle),

          // BENCHMARK DAYPARTS ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â evidence-backed with visibility policy (7.55k.7)
          ..._buildBenchmarkDaypartRows(benchmarkDayparts),
        ],
      ),
    );
  }
}

/// Builds the benchmark daypart rows with visibility policy (7.55k.7).
/// Strong evidence renders as benchmark truth; thin evidence renders as
/// early signal; empty renders as a dash.
List<Widget> _buildBenchmarkDaypartRows(
  List<HistoryBenchmarkDaypartSummary> benchmarkDayparts,
) {
  if (benchmarkDayparts.isEmpty) {
    return [
      const _TeachRow(
        title: 'BENCHMARK DAYPARTS',
        value: '\u2014',
        valueColor: AppColors.positive,
        isLast: true,
      ),
    ];
  }

  final strong = <HistoryBenchmarkDaypartSummary>[];
  final earlySignal = <HistoryBenchmarkDaypartSummary>[];
  for (final b in benchmarkDayparts) {
    final tier = DaypartEvidenceVisibilityPolicy.classifyBenchmark(
      benchmarkCount: b.benchmarkCount,
      closedShiftCount: b.closedShiftCount,
    );
    if (tier == EvidenceTier.strong) {
      strong.add(b);
    } else if (tier == EvidenceTier.earlySignal) {
      earlySignal.add(b);
    }
  }

  return [
    Padding(
      padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (strong.isNotEmpty) ...[
            Text(
              'BENCHMARK DAYPARTS',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),
            for (final b in strong) ...[
              _BenchmarkDaypartEvidenceCard(
                summary: b,
                tone: AppColors.positive,
              ),
              const SizedBox(height: 8),
            ],
          ],
          if (earlySignal.isNotEmpty) ...[
            if (strong.isNotEmpty) const SizedBox(height: 8),
            Text(
              'EARLY SIGNALS',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),
            for (final b in earlySignal) ...[
              _BenchmarkDaypartEvidenceCard(
                summary: b,
                tone: AppColors.warning,
              ),
              const SizedBox(height: 8),
            ],
          ],
          if (strong.isEmpty && earlySignal.isEmpty) ...[
            Text(
              'BENCHMARK DAYPARTS',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),
            Text(
              '\u2014',
              style: AppTextStyles.mono14(color: AppColors.positive),
            ),
          ],
        ],
      ),
    ),
  ];
}

String _benchmarkDaypartEvidenceLabel(HistoryBenchmarkDaypartSummary summary) =>
    'Met benchmark ${summary.benchmarkCount} of ${summary.closedShiftCount} shifts';

class _BenchmarkDaypartEvidenceCard extends StatelessWidget {
  final HistoryBenchmarkDaypartSummary summary;
  final Color tone;

  const _BenchmarkDaypartEvidenceCard({
    required this.summary,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.05),
        border: Border.all(color: tone.withValues(alpha: 0.25), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            summary.label,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            _benchmarkDaypartEvidenceLabel(summary),
            style: AppTextStyles.mono10(color: tone),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              VarianceChip(
                label: '${summary.avgCPLH.toStringAsFixed(2)} CPLH',
                color: tone,
              ),
              VarianceChip(
                label: '\$${summary.avgSPLH.toStringAsFixed(0)} SPLH',
                color: tone,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LeakEvidenceCard extends StatelessWidget {
  final LeverCardData leakCard;
  final int repeatCount;
  final int totalHistoricalDayparts;

  const _LeakEvidenceCard({
    required this.leakCard,
    required this.repeatCount,
    required this.totalHistoricalDayparts,
  });

  @override
  Widget build(BuildContext context) {
    final repeatLabel = totalHistoricalDayparts > 0
        ? 'Showed up in $repeatCount of $totalHistoricalDayparts dayparts'
        : null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.05),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.25),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            leakCard.metric,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          if (repeatLabel != null) ...[
            const SizedBox(height: 4),
            Text(
              repeatLabel,
              style: AppTextStyles.mono10(color: AppColors.negative),
            ),
          ],
        ],
      ),
    );
  }
}

class _TeachRow extends StatelessWidget {
  final String title;
  final String value;
  final Color? valueColor;
  final bool isLast;

  const _TeachRow({
    required this.title,
    required this.value,
    this.valueColor,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 13, 16, isLast ? 16 : 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              title,
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: AppTextStyles.mono14(
                color: valueColor ?? AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ History tab ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬

/// Holds data sets loaded for the History tab.
class _HistoryData {
  final List<WeekRecord> weeks;
  final List<HistoryPatternRecord> patternRecords;
  final List<ShiftRecord> historicalClosedShifts;
  const _HistoryData({
    required this.weeks,
    required this.patternRecords,
    required this.historicalClosedShifts,
  });
}

class HistoryTab extends StatefulWidget {
  const HistoryTab({super.key});

  @override
  State<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<HistoryTab>
    with AutomaticKeepAliveClientMixin {
  late Future<_HistoryData> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final source = context.read<ShiftDataSource>();
    _future =
        Future.wait([
          source.getWeekHistory(),
          source.getHistoryPatternRecords(),
          source.getHistoricalClosedShifts(),
        ]).then(
          (results) => _HistoryData(
            weeks: results[0] as List<WeekRecord>,
            patternRecords: results[1] as List<HistoryPatternRecord>,
            historicalClosedShifts: results[2] as List<ShiftRecord>,
          ),
        );
  }

  String? _historyRangeLabel(List<WeekRecord> weeks) {
    if (weeks.isEmpty) return null;
    final sorted = [...weeks]..sort((a, b) => b.weekId.compareTo(a.weekId));
    final newest = sorted.first;
    final oldest = sorted.last;
    final oldestStart = _weekStartFromWeekId(oldest.weekId);
    final newestEnd =
        _parseIsoDate(newest.closedAt) ??
        _weekStartFromWeekId(newest.weekId)?.add(const Duration(days: 6));
    if (oldestStart == null || newestEnd == null) return null;
    return '${_formatMonthDayFromDate(oldestStart)} - '
        '${_formatMonthDayFromDate(newestEnd)}';
  }

  DateTime? _weekStartFromWeekId(String weekId) {
    final parts = weekId.split('-W');
    if (parts.length != 2) return null;
    final year = int.tryParse(parts[0]);
    final week = int.tryParse(parts[1]);
    if (year == null || week == null) return null;
    final jan4 = DateTime.utc(year, 1, 4);
    final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
    return week1Monday.add(Duration(days: (week - 1) * 7));
  }

  DateTime? _parseIsoDate(String? isoDate) {
    if (isoDate == null) return null;
    final parts = isoDate.split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    return DateTime.utc(year, month, day);
  }

  String _formatMonthDayFromDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<_HistoryData>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.sunset),
          );
        }
        if (snapshot.hasError) {
          return Center(
            child: Text(
              'Error loading history.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          );
        }
        final data =
            snapshot.data ??
            const _HistoryData(
              weeks: [],
              patternRecords: [],
              historicalClosedShifts: [],
            );
        final weeks = data.weeks;
        final patternRecords = data.patternRecords;

        // Teaching summary ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â only shown when pattern records exist.
        HistoryTeachingSummary? teachingSummary;
        LeverCardData? leakCard;
        if (patternRecords.isNotEmpty) {
          teachingSummary = HistoryTeachingAnalyzer.summarize(patternRecords);
          leakCard = LeverCards.all.firstWhere(
            (l) => l.id == teachingSummary!.mostCommonLeakId,
            orElse: () => LeverCards.coversDown,
          );
        }

        // Benchmark daypart evidence (7.55k.5).
        const benchmarkService = HistoryBenchmarkDaypartReadService();
        final benchmarkDayparts = benchmarkService.build(
          data.historicalClosedShifts,
        );
        final historyRangeLabel = _historyRangeLabel(weeks);

        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Previous Weeks', style: AppTextStyles.display28()),
                    if (historyRangeLabel != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        historyRangeLabel,
                        style: AppTextStyles.body13(color: AppColors.textMuted),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ Teaching summary ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â only when pattern records are present ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â€šÂ¬Ã‚ÂÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬
            if (teachingSummary != null && leakCard != null)
              SliverMainAxisGroup(
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: StickySectionDelegate('WHAT HISTORY IS TEACHING'),
                  ),
                  SliverToBoxAdapter(
                    child: _TeachingSummaryCard(
                      summary: teachingSummary,
                      leakCard: leakCard,
                      weekCount: weeks.length,
                      totalHistoricalDayparts:
                          data.historicalClosedShifts.length,
                      benchmarkDayparts: benchmarkDayparts,
                    ),
                  ),
                ],
              ),

            if (weeks.isEmpty)
              SliverFillRemaining(
                child: Center(
                  child: Text(
                    'No history yet.',
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  ),
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (_, i) => WeekHistoryTile(
                    week: weeks[i],
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => WeekDetailScreen(week: weeks[i]),
                      ),
                    ),
                  ),
                  childCount: weeks.length,
                ),
              ),
          ],
        );
      },
    );
  }
}
