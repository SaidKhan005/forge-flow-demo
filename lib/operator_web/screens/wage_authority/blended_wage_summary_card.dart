// Wave 2 S-1 — Live blended-wage summary card.
//
// Origin: debug.md:198-235 (OW-13a + OW-13b). Sits below the
// HierarchyScopeNotice on the Wage Authority screen. Reads the current
// draft set of role rows (saved + in-flight edits) and renders:
//
//     Total hourly cost: $282.00 / 16 weighted hours
//     Blended wage mix: $17.62 / hr
//     FOH $16.00/hr · BOH $18.13/hr · Management $26.00/hr
//
// Pure-presentation; the screen passes a [BlendedWageSummary] in.
//
// UX writing standard (`memory/project_ux_writing_standard.md`): plain
// English coaching tone. No engineering jargon, no scope_id, no labor-
// bucket wire values (`'foh'`, `'manager'`) leak into the copy.

library;

import 'package:flutter/material.dart';

import '../../../theme/app_theme.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_section_heading.dart';
import 'blended_wage_calculator.dart';

/// Plain-English display name for each labor bucket. Keep in sync with
/// `_kBuckets` in `wage_authority_screen.dart` (intentional duplicate —
/// this widget is reusable and should not depend on the screen's
/// private `_BucketSpec`).
const Map<String, String> _kBucketDisplayNames = <String, String>{
  'foh': 'Front of house',
  'boh': 'Back of house',
  'manager': 'Management',
};

/// Format a dollar amount as `$1,234.56`. Negative values render with a
/// leading `-`. Kept simple — we never need locale-aware grouping for a
/// labor-mix preview.
String formatWageCurrency(double v) {
  final sign = v < 0 ? '-' : '';
  final abs = v.abs();
  return '$sign\$${abs.toStringAsFixed(2)}';
}

/// Format a fractional number to a fixed decimal count.
String formatWageHours(double v, {int decimals = 1}) {
  return v.toStringAsFixed(decimals);
}

class BlendedWageSummaryCard extends StatelessWidget {
  const BlendedWageSummaryCard({
    super.key,
    required this.summary,
    this.cardKey,
  });

  final BlendedWageSummary summary;

  /// Optional explicit key for the outer container so tests can
  /// `findsOneWidget` reliably even when the screen-level key changes.
  final Key? cardKey;

  @override
  Widget build(BuildContext context) {
    final hasAny = summary.hasAnyHours;
    return Container(
      key: cardKey ?? const Key('wage_authority_blended_summary_card'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          OperatorWebPlainSectionHeading(
            title: 'Blended wage mix',
            trailing: OperatorWebInfoButton(
              title: 'Blended wage mix',
              tooltip: 'Blended wage mix',
              body: Text(
                hasAny
                    ? "What an average hour of labor costs you across the rows "
                          "below. Updates as you type, before you save."
                    : "Add a role with hours and a rate and Forge & Flow will "
                          "show your average hourly labor cost here.",
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (hasAny) ...<Widget>[
            Wrap(
              spacing: 28,
              runSpacing: 14,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _SummaryMetric(
                  label: 'Blended rate',
                  value: '${formatWageCurrency(summary.blendedHourlyRate!)}/hr',
                  valueKey: const Key('wage_authority_blended_hourly'),
                  emphasized: true,
                ),
                _SummaryMetric(
                  label: 'Weekly wage model',
                  value: formatWageCurrency(summary.totalWeightedDollars),
                  valueKey: const Key('wage_authority_blended_totals_line'),
                ),
                _SummaryMetric(
                  label: 'Weighted hours',
                  value: formatWageHours(summary.totalWeightedHours),
                ),
                _SummaryMetric(
                  label: summary.rowCount == 1 ? 'Role' : 'Roles',
                  value: '${summary.rowCount}',
                ),
              ],
            ),
            const SizedBox(height: 16),
            _BucketBadgeRow(perBucket: summary.perBucket),
          ] else ...<Widget>[
            Text(
              'Not enough data yet',
              key: const Key('wage_authority_blended_empty'),
              style: AppTextStyles.body13(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
    required this.label,
    required this.value,
    this.valueKey,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final Key? valueKey;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: emphasized ? 170 : 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.body11(color: AppColors.textMuted)),
          const SizedBox(height: 3),
          Text(
            value,
            key: valueKey,
            style: emphasized
                ? AppTextStyles.display20(color: AppColors.textPrimary)
                : AppTextStyles.body14(
                    color: AppColors.textPrimary,
                  ).copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _BucketBadgeRow extends StatelessWidget {
  const _BucketBadgeRow({required this.perBucket});

  final List<BucketBlendedWage> perBucket;

  @override
  Widget build(BuildContext context) {
    final visible = perBucket.where((b) => b.hasRows).toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Wrap(
      key: const Key('wage_authority_blended_bucket_badges'),
      spacing: 10,
      runSpacing: 6,
      children: <Widget>[
        for (final bucket in visible)
          _BucketBadge(
            keyName:
                'wage_authority_blended_bucket_badge_${bucket.laborBucket}',
            label:
                _kBucketDisplayNames[bucket.laborBucket] ?? bucket.laborBucket,
            blendedHourlyRate: bucket.blendedHourlyRate!,
            totalWeightedHours: bucket.totalWeightedHours,
          ),
      ],
    );
  }
}

class _BucketBadge extends StatelessWidget {
  const _BucketBadge({
    required this.keyName,
    required this.label,
    required this.blendedHourlyRate,
    required this.totalWeightedHours,
  });

  final String keyName;
  final String label;
  final double blendedHourlyRate;
  final double totalWeightedHours;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(keyName),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        '$label · ${formatWageCurrency(blendedHourlyRate)}/hr '
        '(${formatWageHours(totalWeightedHours)} h)',
        style: AppTextStyles.body12(color: AppColors.textPrimary),
      ),
    );
  }
}
