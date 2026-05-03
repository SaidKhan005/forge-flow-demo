// Phase 8.0 (V1 lean cut 2) — MetricCardNotYetAvailable widget.
//
// Per `docs/contracts/metric_card_honesty_contract.md`. Renders in
// the same card slot as a normal metric card, with a dash and a
// short "Not yet available" message instead of a number, when the
// metric's [MetricProvenance.state] is `unavailable`.
//
// Mirrors the 7.58 `LeverCardNotYetAvailable` widget shape so the
// surface reads as one consistent honesty doctrine across cards
// and lever surfaces.
//
// Forbidden chrome (from the contract): no per-card dots, icons,
// warning glyphs, color shifts, muted weights, italics, or
// tooltips. The only operator-facing difference between this
// widget and a normal `InputMetricCard` is "no number → dash" + a
// 1-line plain-English caption. The dashboard health pill
// summarises degradations across the dashboard — never per card.

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Empty-state renderer for a single metric card whose state is
/// `unavailable`. Placed in the same slot as `InputMetricCard` so
/// the dashboard layout stays unchanged.
class MetricCardNotYetAvailable extends StatelessWidget {
  const MetricCardNotYetAvailable({
    super.key,
    required this.metricLabel,
    this.fullWidth = false,
  });

  /// Label of the metric (e.g. "CPLH", "PPA"). Renders in the same
  /// slot as a normal card's [InputMetric.name] so the operator
  /// keeps spatial recognition.
  final String metricLabel;

  /// Mirrors `InputMetric.fullWidth`. Renders the wage-style full-
  /// width slot when true.
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundMid,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            metricLabel.toUpperCase(),
            key: const Key('metric_card_not_yet_available_label'),
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          // Dash placeholder where the number would render. Same
          // size + weight as a number so layout doesn't reflow when
          // the metric flips to `live`.
          Text(
            '—',
            key: const Key('metric_card_not_yet_available_dash'),
            style: AppTextStyles.display20(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            'Not yet available',
            key: const Key('metric_card_not_yet_available_caption'),
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
