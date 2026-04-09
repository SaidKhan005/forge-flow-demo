import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../data/week_data_notifier.dart';
import '../utils/formatters.dart';

class VarianceBanner extends StatelessWidget {
  final VoidCallback? onTap;

  const VarianceBanner({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Consumer<WeekDataNotifier>(
      builder: (context, notifier, _) {
        final weekData = notifier.weekData;

        final theoretical = weekData?.theoreticalLaborPct ?? 0.0;
        final actual = weekData?.actualLaborPct ?? 0.0;
        final variancePts = weekData?.variancePts ?? 0.0;
        final dollarGap = weekData?.dollarGap ?? 0.0;
        final annualized = weekData?.dollarGapAnnualized ?? 0.0;

        final isOver = variancePts > 0;
        final accentColor = isOver ? AppColors.negative : AppColors.positive;
        final ptSign = isOver ? '+' : '\u2212';
        final gapSign = isOver ? '\u2212' : '+';

        return GestureDetector(
          onTap: onTap,
          child: SizedBox.expand(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.shimmer,
                    AppColors.backgroundMid.withValues(alpha: 0.8),
                    AppColors.cardGlow,
                  ],
                ),
                border: Border(
                  left: BorderSide(color: AppColors.borderSubtle, width: 4),
                  top: BorderSide(
                      color: AppColors.borderSubtle.withValues(alpha: 0.6), width: 1),
                  bottom: BorderSide(
                      color: AppColors.borderSubtle.withValues(alpha: 0.6),
                      width: 1),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(14, 10, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Header row
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.shimmer,
                          border: Border.all(
                              color: AppColors.borderSubtle,
                              width: 1),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text('LABOR % VARIANCE',
                            style: AppTextStyles.mono7(
                                color: AppColors.textMuted)),
                      ),
                      const Spacer(),
                      Text('VIEW DETAILS',
                          style: AppTextStyles.mono7(
                              color: AppColors.textMuted)),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right,
                          size: 14, color: AppColors.textMuted),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Main row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        '${theoretical.toStringAsFixed(1)}%',
                        style: AppTextStyles.mono14(
                            color: AppColors.textSecondary),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.arrow_forward,
                            size: 12, color: AppColors.sunsetDark),
                      ),
                      Text(
                        '${actual.toStringAsFixed(1)}%',
                        style: AppTextStyles.mono20(
                            color: accentColor, weight: FontWeight.w700),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.10),
                          border: Border.all(
                              color: accentColor.withValues(alpha: 0.3),
                              width: 1),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          '$ptSign${variancePts.abs().toStringAsFixed(1)} pts',
                          style: AppTextStyles.mono10(color: accentColor),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  // Dollar gap
                  Row(
                    children: [
                      Text(
                        '$gapSign\$${Fmt.dollars(dollarGap.abs())}',
                        style: AppTextStyles.mono11(color: accentColor),
                      ),
                      Text(' weekly',
                          style: AppTextStyles.mono10(
                              color: AppColors.textMuted)),
                      const SizedBox(width: 12),
                      Text(
                        '$gapSign\$${Fmt.dollars(annualized.abs())}',
                        style: AppTextStyles.mono11(color: accentColor),
                      ),
                      Text(' annualized',
                          style: AppTextStyles.mono10(
                              color: AppColors.textMuted)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// SliverPersistentHeader delegate for sticky behavior
class VarianceBannerDelegate extends SliverPersistentHeaderDelegate {
  final VoidCallback? onTap;
  final double _minExtent;
  final double _maxExtent;

  const VarianceBannerDelegate({
    this.onTap,
    double minExtent = 108,
    double maxExtent = 108,
  })  : _minExtent = minExtent,
        _maxExtent = maxExtent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return VarianceBanner(onTap: onTap);
  }

  @override
  double get minExtent => _minExtent;

  @override
  double get maxExtent => _maxExtent;

  @override
  bool shouldRebuild(VarianceBannerDelegate oldDelegate) => false;
}
