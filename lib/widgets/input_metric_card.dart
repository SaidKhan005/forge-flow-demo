import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/legacy_fixture_data.dart';

class InputMetricCard extends StatelessWidget {
  final InputMetric metric;

  const InputMetricCard({super.key, required this.metric});

  @override
  Widget build(BuildContext context) {
    final isUnfavorable = metric.deltaUnfavorable;
    final deltaColor = isUnfavorable ? AppColors.negative : AppColors.positive;
    final arrowIcon =
        isUnfavorable ? Icons.arrow_downward : Icons.arrow_upward;
    final isDashDelta =
        metric.deltaFormatted == '\u2014' || metric.deltaFormatted == '-';
    final isHero = metric.isHero;
    final statusOk = metric.statusFavorable ?? !isUnfavorable;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: isHero
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.sunset.withValues(alpha: 0.06),
                  AppColors.cardGlow,
                ],
              )
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppColors.backgroundMid, AppColors.cardGlow],
              ),
        border: Border.all(
            color: isHero
                ? AppColors.borderSubtle
                : AppColors.borderSubtle.withValues(alpha: 0.7),
            width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Name row + hero badge
          Row(
            children: [
              Text(metric.name.toUpperCase(),
                  style: AppTextStyles.mono10(
                      color: isHero ? AppColors.sunsetDark : AppColors.textMuted)),
              if (isHero) ...[
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppColors.sunset.withValues(alpha: 0.10),
                    border: Border.all(
                        color: AppColors.sunset.withValues(alpha: 0.35), width: 1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Text('DRIVER',
                      style: AppTextStyles.mono7(color: AppColors.sunsetDark)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Current value
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(metric.currentFormatted, style: AppTextStyles.mono28()),
          ),
          const SizedBox(height: 3),
          // Target
          Text(metric.targetFormatted,
              style: AppTextStyles.mono10(color: AppColors.textMuted)),
          if (metric.targetSupportFormatted != null) ...[
            const SizedBox(height: 2),
            Text(metric.targetSupportFormatted!,
                style: AppTextStyles.mono10(color: AppColors.textMuted)),
          ],
          const SizedBox(height: 8),
          // Delta row
          if (!isDashDelta)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: deltaColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(arrowIcon, size: 14, color: deltaColor),
                  const SizedBox(width: 2),
                  Text(
                    metric.deltaFormatted,
                    style: AppTextStyles.mono12(
                        color: deltaColor, weight: FontWeight.w700),
                  ),
                ],
              ),
            )
          else
            Text('\u2014',
                style: AppTextStyles.mono12(color: AppColors.neutral)),
          const SizedBox(height: 4),
          // Status dot + text
          Row(
            children: [
              Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color:
                      statusOk ? AppColors.positive : AppColors.negative,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                metric.statusLine,
                style: AppTextStyles.mono10(
                  color:
                      statusOk ? AppColors.positive : AppColors.negative,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
