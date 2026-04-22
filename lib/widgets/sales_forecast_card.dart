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
          border: Border.all(
              color: AppColors.borderSubtle.withValues(alpha: 0.7), width: 1),
          borderRadius: BorderRadius.circular(3),
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
            // Progress bar — taller, with a clear track outline so the
            // filling edge is visible against the background, plus a
            // brighter leading edge on the filled portion. Uses
            // FractionallySizedBox (no LayoutBuilder) so it stays
            // intrinsic-safe inside IntrinsicHeight parents.
            if (hasForecast) ...[
              const SizedBox(height: 10),
              _SalesProgressBar(progress: progress, isAhead: isAhead),
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

class _SalesProgressBar extends StatelessWidget {
  final double progress;
  final bool isAhead;
  const _SalesProgressBar({required this.progress, required this.isAhead});

  @override
  Widget build(BuildContext context) {
    final fillColor = isAhead ? AppColors.positive : AppColors.sunset;
    return Container(
      height: 10,
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(
            color: AppColors.borderStrong.withValues(alpha: 0.7),
            width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: progress.clamp(0.0, 1.0),
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  fillColor.withValues(alpha: 0.7),
                  fillColor,
                ],
              ),
              border: progress > 0.0 && progress < 1.0
                  ? Border(
                      right: BorderSide(color: fillColor, width: 2),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
