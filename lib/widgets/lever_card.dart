import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/meridian_data.dart';

class LeverCardWidget extends StatelessWidget {
  final LeverCardData data;

  const LeverCardWidget({super.key, required this.data});

  Color get _causeBadgeColor =>
      data.direction == LeverDirection.unfavorable
          ? AppColors.accent
          : AppColors.positive;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.rule, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row — badges
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                _Badge(
                  label: data.causeCategory,
                  color: _causeBadgeColor,
                ),
                const Spacer(),
                _Badge(
                  label: data.sideLabel,
                  color: AppColors.slateTag,
                ),
              ],
            ),
          ),
          // Metric title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              data.metric,
              style: AppTextStyles.mono14(
                color: AppColors.primaryText,
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
              style: AppTextStyles.mono7(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              data.whatHappened,
              style: AppTextStyles.body13(color: AppColors.primaryText),
            ),
          ),
          const SizedBox(height: 16),
          // Divider
          Container(height: 1, color: AppColors.rule),
          const SizedBox(height: 16),
          // WHAT TO DO section
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'WHAT TO DO',
              style: AppTextStyles.mono7(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              data.whatToDo,
              style: AppTextStyles.body13(color: AppColors.primaryText),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;

  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Text(
        label,
        style: AppTextStyles.mono7(color: color),
      ),
    );
  }
}
