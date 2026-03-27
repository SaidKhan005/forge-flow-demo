import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/meridian_data.dart';

class VarianceBanner extends StatelessWidget {
  final VoidCallback? onTap;

  const VarianceBanner({super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(height: 1, color: AppColors.rule),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(
                  'Theoretical ${WeeklyVariance.theoreticalTotalLaborPct.toStringAsFixed(1)}%',
                  style: AppTextStyles.mono12(color: AppColors.secondaryText),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.arrow_forward,
                    size: 14, color: AppColors.secondaryText),
                const SizedBox(width: 8),
                Text(
                  'Actual ${WeeklyVariance.actualTotalLaborPct.toStringAsFixed(1)}%',
                  style: AppTextStyles.mono14(
                    color: AppColors.accent,
                    weight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.chevron_right,
                    size: 16, color: AppColors.secondaryText),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '+${WeeklyVariance.totalLaborPctVariance.toStringAsFixed(1)} pts  ·  '
              '\$${WeeklyVariance.dollarGapWeekly.toStringAsFixed(0).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')} this week  ·  '
              '\$${WeeklyVariance.dollarGapAnnualized.toStringAsFixed(0).replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',')} annualized',
              style: AppTextStyles.mono10(),
            ),
            const SizedBox(height: 10),
            Container(height: 1, color: AppColors.rule),
          ],
        ),
      ),
    );
  }
}

// SliverPersistentHeader delegate for sticky behavior — used in shift_dashboard.dart
class VarianceBannerDelegate extends SliverPersistentHeaderDelegate {
  final VoidCallback? onTap;
  final double _minExtent;
  final double _maxExtent;

  const VarianceBannerDelegate({
    this.onTap,
    double minExtent = 60,
    double maxExtent = 60,
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
