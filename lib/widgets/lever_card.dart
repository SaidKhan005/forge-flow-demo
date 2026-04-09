import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/legacy_fixture_data.dart';

class LeverCardWidget extends StatelessWidget {
  final LeverCardData data;

  const LeverCardWidget({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.backgroundMid, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(height: 2, color: AppColors.sunset.withValues(alpha: 0.60)),
          // Header row — badges
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                _Badge(
                  label: data.causeCategory,
                ),
              ],
            ),
          ),
          // Metric title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              data.metric,
              style: AppTextStyles.mono15(
                color: AppColors.textPrimary,
                weight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // WHAT HAPPENED section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'WHAT HAPPENED',
              style: AppTextStyles.mono11(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              data.whatHappened,
              style: AppTextStyles.body15(color: AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: 16),
          // Divider
          Container(height: 1, color: AppColors.borderSubtle),
          const SizedBox(height: 16),
          // WHAT TO STUDY section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'WHAT TO STUDY',
              style: AppTextStyles.mono11(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              data.teachingNote,
              style: AppTextStyles.body15(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;

  const _Badge({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.sunset.withValues(alpha: 0.10),
        border: Border.all(color: AppColors.sunset.withValues(alpha: 0.35), width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono8(color: AppColors.sunsetDark),
      ),
    );
  }
}
