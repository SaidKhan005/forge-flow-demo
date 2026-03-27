import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/meridian_data.dart';

class ZoneStatusCard extends StatelessWidget {
  const ZoneStatusCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status label
          Text(
            'IN OPZ',
            style: AppTextStyles.display28(color: AppColors.positive),
          ),
          const SizedBox(height: 16),
          // CPLH gauge
          _CplhGauge(
            opzFloor: MeridianConfig.opzFloorCPLH,
            opzCeiling: MeridianConfig.opzCeilingCPLH,
            target: MeridianConfig.targetCPLH,
            current: ShiftSnapshot.actualCPLH,
          ),
          const SizedBox(height: 12),
          // Sub-label
          Text(
            ShiftSnapshot.opzSubLabel,
            style: AppTextStyles.body13(color: AppColors.secondaryText),
          ),
        ],
      ),
    );
  }
}

class _CplhGauge extends StatelessWidget {
  final double opzFloor;
  final double opzCeiling;
  final double target;
  final double current;

  const _CplhGauge({
    required this.opzFloor,
    required this.opzCeiling,
    required this.target,
    required this.current,
  });

  @override
  Widget build(BuildContext context) {
    // Gauge spans 0 to 7.5 for visual range
    const double gaugeMin = 0.0;
    const double gaugeMax = 7.5;
    const double gaugeRange = gaugeMax - gaugeMin;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Zone labels above bar
        Row(
          children: [
            Expanded(
              flex: ((opzFloor / gaugeRange) * 100).round(),
              child: Text(
                'Below OPZ',
                style: AppTextStyles.mono8(color: AppColors.accent),
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              flex: (((opzCeiling - opzFloor) / gaugeRange) * 100).round(),
              child: Text(
                'OPZ',
                style: AppTextStyles.mono8(color: AppColors.positive),
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              flex: (((gaugeMax - opzCeiling) / gaugeRange) * 100).round(),
              child: Text(
                'Above OPZ',
                style: AppTextStyles.mono8(color: AppColors.gold),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Gauge bar with current position indicator
        LayoutBuilder(
          builder: (context, constraints) {
            final totalWidth = constraints.maxWidth;
            final currentPos = ((current - gaugeMin) / gaugeRange) * totalWidth;
            final targetPos = ((target - gaugeMin) / gaugeRange) * totalWidth;

            final belowFlex = ((opzFloor / gaugeRange) * 100).round();
            final opzFlex =
                (((opzCeiling - opzFloor) / gaugeRange) * 100).round();
            final aboveFlex =
                (((gaugeMax - opzCeiling) / gaugeRange) * 100).round();

            return Stack(
              clipBehavior: Clip.none,
              children: [
                // Bar segments
                Row(
                  children: [
                    Expanded(
                      flex: belowFlex,
                      child: Container(
                        height: 10,
                        color: AppColors.accent.withValues(alpha: 0.35),
                      ),
                    ),
                    Expanded(
                      flex: opzFlex,
                      child: Container(
                        height: 10,
                        color: AppColors.positive.withValues(alpha: 0.35),
                      ),
                    ),
                    Expanded(
                      flex: aboveFlex,
                      child: Container(
                        height: 10,
                        color: AppColors.gold.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
                // Target marker (gold tick)
                Positioned(
                  left: targetPos - 1,
                  top: -4,
                  child: Container(
                    width: 2,
                    height: 18,
                    color: AppColors.gold,
                  ),
                ),
                // Current position dot
                Positioned(
                  left: currentPos - 6,
                  top: -3,
                  child: Container(
                    width: 12,
                    height: 16,
                    decoration: const BoxDecoration(
                      color: AppColors.primaryText,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        // Value labels below bar
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'CPLH ${current.toStringAsFixed(1)}',
              style: AppTextStyles.mono10(color: AppColors.primaryText),
            ),
            Text(
              'Target ${target.toStringAsFixed(1)}',
              style: AppTextStyles.mono10(color: AppColors.gold),
            ),
            Text(
              'OPZ ceiling ${opzCeiling.toStringAsFixed(1)}',
              style: AppTextStyles.mono10(color: AppColors.gold),
            ),
          ],
        ),
      ],
    );
  }
}
