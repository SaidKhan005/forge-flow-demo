import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/console/console_surface.dart';
import '../admin_button_styles.dart';
import '../admin_human_labels.dart';
import '../services/data_accuracy_admin_gateway.dart';

class MarginRollupCard extends StatefulWidget {
  const MarginRollupCard({
    super.key,
    required this.rollup,
    required this.canExportCsv,
    required this.onExportCsv,
  });

  final TierMarginRollup rollup;
  final bool canExportCsv;
  final Future<void> Function() onExportCsv;

  @override
  State<MarginRollupCard> createState() => _MarginRollupCardState();
}

class _MarginRollupCardState extends State<MarginRollupCard> {
  bool _exporting = false;

  Future<void> _onExportPressed() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      await widget.onExportCsv();
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rollup = widget.rollup;
    final marginCents = rollup.totalMonthlyMarginCents;
    final marginColor = _marginColor(marginCents);
    final marginPctText = rollup.marginFraction == null
        ? '-'
        : '${(rollup.marginFraction! * 100).toStringAsFixed(1)}%';
    final totalCost = rollup.totalMonthlyVendorCostCents;

    return OperatorWebPanel(
      key: const Key('admin_margin_rollup_card'),
      title: 'Margin snapshot',
      subtitle: 'Monthly price, vendor cost, and margin for shown locations.',
      trailing: widget.canExportCsv
          ? OutlinedButton(
              key: const Key('admin_margin_rollup_export_button'),
              style: AdminButtonStyles.secondary(minWidth: 120, minHeight: 36),
              onPressed: _exporting ? null : _onExportPressed,
              child: Text(_exporting ? 'Exporting...' : 'Export CSV'),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _MetricGrid(
            metrics: _marginMetricSpecs(
              rollup: rollup,
              totalCost: totalCost,
              marginCents: marginCents,
              marginColor: marginColor,
              marginPctText: marginPctText,
            ),
          ),
          const SizedBox(height: 16),
          _RevenueMix(
            totalPriceCents: rollup.totalMonthlyPriceCents,
            totalCostCents: totalCost,
            marginCents: marginCents,
          ),
          const SizedBox(height: 16),
          const _BreakdownHeader(
            title: 'By tier',
            hint: 'Revenue share and margin by assigned tier.',
          ),
          const SizedBox(height: 6),
          _perTierBreakdown(rollup),
          const SizedBox(height: 16),
          const _BreakdownHeader(
            title: 'Vendor cost',
            hint: 'Share of the monthly vendor cost basis.',
          ),
          const SizedBox(height: 6),
          _perVendorBreakdown(rollup, totalCost),
        ],
      ),
    );
  }

  static Widget _perTierBreakdown(TierMarginRollup rollup) {
    if (rollup.perTier.isEmpty) {
      return Text(
        'No tiers assigned yet.',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      );
    }
    return Column(
      children: <Widget>[
        for (final entry in rollup.perTier)
          _LabeledBar(
            label: adminPollingTierLabel(entry.tierKey),
            fraction: rollup.totalMonthlyPriceCents <= 0
                ? 0
                : entry.totalMonthlyPriceCents / rollup.totalMonthlyPriceCents,
            barColor: _marginColor(entry.marginCents),
            valueText:
                '${formatCents(entry.marginCents)} margin, '
                '${entry.assignmentCount} '
                '${entry.assignmentCount == 1 ? 'location' : 'locations'}',
            valueColor: _marginColor(entry.marginCents),
          ),
      ],
    );
  }

  static Widget _perVendorBreakdown(TierMarginRollup rollup, int totalCost) {
    if (rollup.perVendor.isEmpty) {
      return Text(
        'No vendor cost yet.',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      );
    }
    return Column(
      children: <Widget>[
        for (final entry in rollup.perVendor)
          _LabeledBar(
            label: entry.vendorId == kUnallocatedVendorId
                ? kUnallocatedVendorDisplayName
                : (kPollOnlyVendorDisplayNames[entry.vendorId] ??
                      entry.vendorId),
            fraction: totalCost <= 0
                ? 0
                : entry.totalMonthlyVendorCostCents / totalCost,
            barColor: AppColors.warning,
            valueText: totalCost <= 0
                ? formatCents(entry.totalMonthlyVendorCostCents)
                : '${formatCents(entry.totalMonthlyVendorCostCents)}, '
                      '${(entry.totalMonthlyVendorCostCents * 100 / totalCost).toStringAsFixed(1)}%',
            valueColor: AppColors.textPrimary,
            mutedLabel: entry.vendorId == kUnallocatedVendorId,
          ),
      ],
    );
  }
}

Color _marginColor(int marginCents) {
  if (marginCents > 0) return AppColors.positive;
  if (marginCents < 0) return AppColors.negative;
  return AppColors.textMuted;
}

class _MetricSpec {
  const _MetricSpec({
    required this.keyName,
    required this.label,
    required this.value,
    required this.caption,
    required this.icon,
    required this.accent,
    this.valueColor = AppColors.textPrimary,
  });

  final String keyName;
  final String label;
  final String value;
  final String caption;
  final IconData icon;
  final Color accent;
  final Color valueColor;
}

List<_MetricSpec> _marginMetricSpecs({
  required TierMarginRollup rollup,
  required int totalCost,
  required int marginCents,
  required Color marginColor,
  required String marginPctText,
}) {
  return <_MetricSpec>[
    _MetricSpec(
      keyName: 'admin_margin_metric_revenue',
      label: 'Revenue',
      value: formatCents(rollup.totalMonthlyPriceCents),
      caption: 'Assigned tier price',
      icon: Icons.payments_outlined,
      accent: AppColors.sunset,
    ),
    _MetricSpec(
      keyName: 'admin_margin_metric_vendor_cost',
      label: 'Vendor cost',
      value: formatCents(totalCost),
      caption: 'API cost basis',
      icon: Icons.account_tree_outlined,
      accent: AppColors.warning,
    ),
    _MetricSpec(
      keyName: 'admin_margin_metric_net_margin',
      label: 'Net margin',
      value: formatCents(marginCents),
      caption: 'Revenue minus cost',
      icon: Icons.trending_up_outlined,
      accent: marginColor,
      valueColor: marginColor,
    ),
    _MetricSpec(
      keyName: 'admin_margin_metric_margin_percent',
      label: 'Margin %',
      value: marginPctText,
      caption: rollup.marginFraction == null
          ? 'No revenue yet'
          : 'Net margin / revenue',
      icon: Icons.percent,
      accent: marginColor,
      valueColor: marginColor,
    ),
  ];
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});

  final List<_MetricSpec> metrics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 12.0;
        final perRow = constraints.maxWidth >= 760 ? 4 : 2;
        final rows = <Widget>[];
        for (var i = 0; i < metrics.length; i += perRow) {
          final end = i + perRow > metrics.length ? metrics.length : i + perRow;
          final rowMetrics = metrics.sublist(i, end);
          rows.add(
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (var j = 0; j < rowMetrics.length; j++) ...<Widget>[
                    if (j > 0) const SizedBox(width: gap),
                    Expanded(child: _MetricTile(metric: rowMetrics[j])),
                  ],
                ],
              ),
            ),
          );
          if (end < metrics.length) rows.add(const SizedBox(height: gap));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        );
      },
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.metric});

  final _MetricSpec metric;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key(metric.keyName),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(height: 3, color: metric.accent),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(metric.icon, size: 16, color: metric.accent),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          metric.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.uiLabel(
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    metric.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.mono20(
                      color: metric.valueColor,
                      weight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    metric.caption,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body11(color: AppColors.textMuted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RevenueMix extends StatelessWidget {
  const _RevenueMix({
    required this.totalPriceCents,
    required this.totalCostCents,
    required this.marginCents,
  });

  final int totalPriceCents;
  final int totalCostCents;
  final int marginCents;

  @override
  Widget build(BuildContext context) {
    if (totalPriceCents <= 0) {
      return Text(
        'Assign tiers to see price, cost, and margin.',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      );
    }
    final marginColor = _marginColor(marginCents);
    final costFraction = totalCostCents / totalPriceCents;
    final marginFraction = marginCents > 0
        ? marginCents / totalPriceCents
        : 0.0;
    final costPct = (costFraction * 100).toStringAsFixed(1);
    final marginPct = marginCents <= 0
        ? 'No margin'
        : '${(marginFraction * 100).toStringAsFixed(1)}% margin';
    return Column(
      key: const Key('admin_margin_revenue_mix'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Revenue mix',
                style: AppTextStyles.body13(
                  color: AppColors.textPrimary,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              '$costPct% cost, $marginPct',
              style: AppTextStyles.body12(color: AppColors.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 14,
            child: Stack(
              children: <Widget>[
                const Positioned.fill(
                  child: ColoredBox(color: AppColors.shimmer),
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _clampFraction(costFraction),
                  heightFactor: 1,
                  child: const ColoredBox(color: AppColors.warning),
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerRight,
                  widthFactor: _clampFraction(marginFraction),
                  heightFactor: 1,
                  child: ColoredBox(color: marginColor),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: <Widget>[
            const _LegendDot(label: 'Vendor cost', color: AppColors.warning),
            _LegendDot(label: 'Net margin', color: marginColor),
          ],
        ),
      ],
    );
  }
}

class _BreakdownHeader extends StatelessWidget {
  const _BreakdownHeader({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Text(
          title,
          style: AppTextStyles.body13(
            color: AppColors.textPrimary,
          ).copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: AppTextStyles.body12(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _LabeledBar extends StatelessWidget {
  const _LabeledBar({
    required this.label,
    required this.fraction,
    required this.barColor,
    required this.valueText,
    required this.valueColor,
    this.mutedLabel = false,
  });

  final String label;
  final double fraction;
  final Color barColor;
  final String valueText;
  final Color valueColor;
  final bool mutedLabel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final labelText = Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyles.body13(
            color: mutedLabel ? AppColors.textMuted : AppColors.textPrimary,
          ).copyWith(fontWeight: FontWeight.w600),
        );
        final bar = ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 12,
            child: Stack(
              children: <Widget>[
                const Positioned.fill(
                  child: ColoredBox(color: AppColors.shimmer),
                ),
                FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: _clampFraction(fraction),
                  heightFactor: 1,
                  child: ColoredBox(color: barColor),
                ),
              ],
            ),
          ),
        );
        final value = Text(
          valueText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: constraints.maxWidth < 520
              ? TextAlign.left
              : TextAlign.right,
          style: AppTextStyles.body12(
            color: valueColor,
          ).copyWith(fontWeight: FontWeight.w700),
        );
        if (constraints.maxWidth < 520) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                labelText,
                const SizedBox(height: 6),
                bar,
                const SizedBox(height: 4),
                value,
              ],
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: <Widget>[
              SizedBox(width: 148, child: labelText),
              const SizedBox(width: 12),
              Expanded(child: bar),
              const SizedBox(width: 12),
              SizedBox(width: 176, child: value),
            ],
          ),
        );
      },
    );
  }
}

double _clampFraction(double value) {
  if (value.isNaN || value <= 0) return 0.001;
  if (value >= 1) return 1;
  return value;
}
