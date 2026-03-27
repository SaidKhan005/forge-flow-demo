import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/meridian_data.dart';

class InputMetricCard extends StatelessWidget {
  final InputMetric metric;

  const InputMetricCard({super.key, required this.metric});

  @override
  Widget build(BuildContext context) {
    final deltaColor =
        metric.deltaUnfavorable ? AppColors.accent : AppColors.positive;
    final arrowIcon = metric.deltaUnfavorable
        ? Icons.arrow_downward
        : Icons.arrow_upward;
    final isDashDelta = metric.deltaFormatted == '-';

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Metric name
          Text(
            metric.name,
            style: AppTextStyles.mono8(),
          ),
          const SizedBox(height: 6),
          // Current value
          Text(
            metric.currentFormatted,
            style: AppTextStyles.mono22(),
          ),
          const SizedBox(height: 4),
          // Target
          Text(
            metric.targetFormatted,
            style: AppTextStyles.mono10(),
          ),
          const SizedBox(height: 6),
          // Delta
          if (!isDashDelta)
            Row(
              children: [
                Icon(arrowIcon, size: 12, color: deltaColor),
                const SizedBox(width: 3),
                Text(
                  metric.deltaFormatted,
                  style: AppTextStyles.mono12(color: deltaColor),
                ),
              ],
            )
          else
            Text(
              '-',
              style: AppTextStyles.mono12(color: AppColors.secondaryText),
            ),
          const SizedBox(height: 4),
          // Status line
          Text(
            metric.statusLine,
            style: AppTextStyles.body11(),
          ),
        ],
      ),
    );
  }
}
