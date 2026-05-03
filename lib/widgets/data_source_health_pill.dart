// Phase 8.0 (V1 lean cut 2) — DataSourceHealthPill widget.
//
// Per `docs/contracts/metric_card_honesty_contract.md`. Top-left
// pill on the dashboard. Renders nothing when every visible metric
// is `live`; renders a single short plain-English line summarising
// the most-impactful degradation when any metric is non-live.
//
// Tap → opens a detail sheet listing each non-live source as one
// short line per source.
//
// Forbidden patterns enforced here:
//   * No "All live" reassurance pill when fully healthy.
//   * No per-card chrome — the pill is the single window into
//     degradation.

import 'package:flutter/material.dart';

import '../domain/models/metric_provenance.dart';
import '../theme/app_theme.dart';

/// One row in the detail sheet — names the metric and its non-live
/// state in plain English.
class DataSourceHealthEntry {
  const DataSourceHealthEntry({
    required this.metricLabel,
    required this.state,
    required this.provenance,
    required this.summaryLine,
  });

  /// Metric this entry is about ("CPLH", "PPA").
  final String metricLabel;

  /// Non-live state. The pill / sheet is only ever assembled from
  /// non-live entries; passing `live` here is a programming error.
  final MetricState state;

  /// Provenance string copied verbatim from the producer.
  final String provenance;

  /// Plain-English line shown in the detail sheet, e.g.,
  /// "CPLH: not yet connected", "PPA: covers via forecast".
  final String summaryLine;
}

/// Top-left dashboard pill. Mounted once at the dashboard root;
/// receives the union of [DataSourceHealthEntry] across every
/// visible metric.
class DataSourceHealthPill extends StatelessWidget {
  const DataSourceHealthPill({super.key, required this.entries});

  /// Non-empty entry list = at least one non-live metric. Empty
  /// list = pill renders nothing.
  final List<DataSourceHealthEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      // Forbidden patterns: no "All live" reassurance pill. The
      // dashboard reads as it does today when fully healthy.
      return const SizedBox.shrink(
        key: Key('data_source_health_pill_absent'),
      );
    }
    final headline = _headlineFor(entries);
    return GestureDetector(
      key: const Key('data_source_health_pill_present'),
      onTap: () => _openDetailSheet(context),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.10),
          border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.45),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.info_outline,
              size: 14,
              color: AppColors.warning,
            ),
            const SizedBox(width: 6),
            Text(
              headline,
              key: const Key('data_source_health_pill_headline'),
              style: AppTextStyles.mono11(color: AppColors.warning),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetailSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              key: const Key('data_source_health_pill_sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Data sources',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 8),
                Text(
                  'A source goes here when its data is not flowing live. '
                  'Once every source is live, this surface goes away.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                for (final entry in entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      entry.summaryLine,
                      key: Key(
                          'data_source_health_pill_sheet_${entry.metricLabel}'),
                      style: AppTextStyles.body14(color: AppColors.textPrimary),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Pick the most-impactful degradation as the headline. Order
  /// (per the contract): `unavailable` beats `fallback` beats
  /// `partial`. Within a tier, the first entry wins.
  String _headlineFor(List<DataSourceHealthEntry> entries) {
    DataSourceHealthEntry? top;
    for (final entry in entries) {
      if (top == null || _severity(entry.state) > _severity(top.state)) {
        top = entry;
      }
    }
    return top!.summaryLine;
  }

  int _severity(MetricState state) {
    switch (state) {
      case MetricState.unavailable:
        return 3;
      case MetricState.fallback:
        return 2;
      case MetricState.partial:
        return 1;
      case MetricState.live:
        return 0;
    }
  }
}
