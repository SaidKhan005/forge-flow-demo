import 'package:flutter/material.dart';

import '../../domain/models/forge_flow_polling_tier_assignment.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console/console_surface.dart';
import '../admin_button_styles.dart';
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
    // Mirror tier-definition card coloring: 0 is neutral (placeholder
    // / pre-pricing state), >0 green, <0 red.
    final Color marginColor;
    if (marginCents > 0) {
      marginColor = AppColors.positive;
    } else if (marginCents < 0) {
      marginColor = AppColors.negative;
    } else {
      marginColor = AppColors.textMuted;
    }
    final marginPctText = rollup.marginFraction == null
        ? '-'
        : '${(rollup.marginFraction! * 100).toStringAsFixed(1)}%';
    final totalCost = rollup.totalMonthlyVendorCostCents;

    return OperatorWebPanel(
      key: const Key('admin_margin_rollup_card'),
      title: 'Margin rollup',
      trailing: widget.canExportCsv
          ? OutlinedButton(
              key: const Key('admin_margin_rollup_export_button'),
              style: AdminButtonStyles.secondary(minWidth: 120, minHeight: 36),
              onPressed: _exporting ? null : _onExportPressed,
              child: Text(_exporting ? 'Exporting…' : 'Export CSV'),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              _Metric(
                label: 'Total monthly tier revenue (USD)',
                value: formatCents(rollup.totalMonthlyPriceCents),
                color: AppColors.textPrimary,
              ),
              _Metric(
                label: 'Total monthly vendor API cost basis (USD)',
                value: formatCents(totalCost),
                color: AppColors.textPrimary,
              ),
              _Metric(
                label: 'Net monthly margin (USD)',
                value: formatCents(marginCents),
                color: marginColor,
              ),
              _Metric(
                label: 'Margin %',
                value: marginPctText,
                color: marginColor,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Per-tier breakdown',
            style: AppTextStyles.uiLabel(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          _perTierBreakdown(rollup),
          const SizedBox(height: 16),
          Text(
            'Per-vendor cost breakdown',
            style: AppTextStyles.uiLabel(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          _perVendorBreakdown(rollup, totalCost),
        ],
      ),
    );
  }

  /// Per-tier revenue/cost/margin table, or an empty-state line when no
  /// tier assignments exist. Extracted from [build] verbatim so the
  /// dispatcher stays flat.
  static Widget _perTierBreakdown(TierMarginRollup rollup) {
    if (rollup.perTier.isEmpty) {
      return Text(
        'No tier assignments yet.',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const <DataColumn>[
          DataColumn(label: Text('Tier')),
          DataColumn(label: Text('Count')),
          DataColumn(label: Text('Revenue')),
          DataColumn(label: Text('Cost')),
          DataColumn(label: Text('Margin')),
        ],
        rows: <DataRow>[
          for (final entry in rollup.perTier)
            DataRow(
              cells: <DataCell>[
                DataCell(
                  Text(
                    entry.tierKey.wire,
                    style: AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                DataCell(
                  Text(
                    '${entry.assignmentCount}',
                    style: AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                DataCell(
                  Text(
                    formatCents(entry.totalMonthlyPriceCents),
                    style: AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                DataCell(
                  Text(
                    formatCents(entry.totalMonthlyVendorCostCents),
                    style: AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                DataCell(
                  Text(
                    formatCents(entry.marginCents),
                    style: AppTextStyles.mono14(
                      color: entry.marginCents > 0
                          ? AppColors.positive
                          : (entry.marginCents < 0
                                ? AppColors.negative
                                : AppColors.textMuted),
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// Per-vendor monthly-cost table with each vendor's share of total
  /// cost, or an empty-state line. Extracted from [build] verbatim.
  static Widget _perVendorBreakdown(
    TierMarginRollup rollup,
    int totalCost,
  ) {
    if (rollup.perVendor.isEmpty) {
      return Text(
        'No per-vendor cost data yet.',
        style: AppTextStyles.body13(color: AppColors.textMuted),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const <DataColumn>[
          DataColumn(label: Text('Vendor')),
          DataColumn(label: Text('Monthly cost basis')),
          DataColumn(label: Text('% of total cost')),
        ],
        rows: <DataRow>[
          for (final entry in rollup.perVendor)
            DataRow(
              cells: <DataCell>[
                DataCell(
                  Text(
                    entry.vendorId == kUnallocatedVendorId
                        ? kUnallocatedVendorDisplayName
                        : (kPollOnlyVendorDisplayNames[entry.vendorId] ??
                              entry.vendorId),
                    style: AppTextStyles.body13(
                      color: entry.vendorId == kUnallocatedVendorId
                          ? AppColors.textMuted
                          : AppColors.textPrimary,
                    ),
                  ),
                ),
                DataCell(
                  Text(
                    formatCents(entry.totalMonthlyVendorCostCents),
                    style: AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                DataCell(
                  Text(
                    totalCost <= 0
                        ? '-'
                        : '${(entry.totalMonthlyVendorCostCents * 100 / totalCost).toStringAsFixed(1)}%',
                    style: AppTextStyles.mono12(
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.uiLabel(color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Text(value, style: AppTextStyles.display20(color: color)),
        ],
      ),
    );
  }
}
