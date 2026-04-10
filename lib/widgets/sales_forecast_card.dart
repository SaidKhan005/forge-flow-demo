import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../utils/formatters.dart';

class SalesForecastCard extends StatelessWidget {
  final double currentSales;
  final double forecastSales;

  const SalesForecastCard({
    super.key,
    required this.currentSales,
    required this.forecastSales,
  });

  @override
  Widget build(BuildContext context) {
    final hasForecast = forecastSales > 0;
    final delta = currentSales - forecastSales;
    final isAhead = delta >= 0;
    final deltaColor = isAhead ? AppColors.positive : AppColors.negative;
    final deltaIcon = isAhead ? Icons.arrow_upward : Icons.arrow_downward;
    final progress = hasForecast
        ? (currentSales / forecastSales).clamp(0.0, 1.0)
        : 0.0;

    return Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.backgroundMid, AppColors.cardGlow],
          ),
          border: Border(
            left: BorderSide(color: AppColors.sunset, width: 4),
            top: BorderSide(
                color: AppColors.borderSubtle.withValues(alpha: 0.7),
                width: 1),
            right: BorderSide(
                color: AppColors.borderSubtle.withValues(alpha: 0.7),
                width: 1),
            bottom: BorderSide(
                color: AppColors.borderSubtle.withValues(alpha: 0.7),
                width: 1),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Label
            Text('SALES',
                style: AppTextStyles.mono10(color: AppColors.textMuted)),
            const SizedBox(height: 6),
            // Current value
            Text(
              '\$${Fmt.dollars(currentSales)}',
              style: AppTextStyles.mono28(),
            ),
            const SizedBox(height: 3),
            // Target reference
            Text(
              hasForecast
                  ? 'Forecast \$${Fmt.dollars(forecastSales)}'
                  : 'No forecast available',
              style: AppTextStyles.mono10(color: AppColors.textMuted),
            ),
            // Progress bar
            if (hasForecast) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: SizedBox(
                  height: 6,
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor:
                        AppColors.borderSubtle.withValues(alpha: 0.3),
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isAhead ? AppColors.positive : AppColors.sunset,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            // Delta pill
            if (hasForecast)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: deltaColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(deltaIcon, size: 14, color: deltaColor),
                    const SizedBox(width: 2),
                    Text(
                      '${isAhead ? '+' : '\u2212'}\$${Fmt.dollars(delta.abs())}',
                      style: AppTextStyles.mono12(
                          color: deltaColor, weight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
          ],
        ),
    );
  }
}
