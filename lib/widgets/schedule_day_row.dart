import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
class ScheduleDayRow extends StatelessWidget {
  final String day;
  final int forecastCovers;
  final int requiredFohHours;
  final int requiredBohHours;
  final bool isHeader;
  final bool isTotal;

  const ScheduleDayRow({
    super.key,
    required this.day,
    required this.forecastCovers,
    required this.requiredFohHours,
    required this.requiredBohHours,
    this.isHeader = false,
    this.isTotal = false,
  });

  factory ScheduleDayRow.header() {
    return const ScheduleDayRow(
      day: 'DAY',
      forecastCovers: 0,
      requiredFohHours: 0,
      requiredBohHours: 0,
      isHeader: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final textColor =
        isTotal ? AppColors.primaryText : AppColors.primaryText;

    if (isHeader) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: AppColors.surface,
        child: Row(
          children: [
            Expanded(
                flex: 2,
                child: Text('DAY', style: AppTextStyles.mono7())),
            Expanded(
                flex: 3,
                child: Text('COVERS',
                    style: AppTextStyles.mono7(),
                    textAlign: TextAlign.right)),
            Expanded(
                flex: 3,
                child: Text('FOH HRS',
                    style: AppTextStyles.mono7(),
                    textAlign: TextAlign.right)),
            Expanded(
                flex: 3,
                child: Text('BOH HRS',
                    style: AppTextStyles.mono7(),
                    textAlign: TextAlign.right)),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: isTotal
            ? AppColors.rule.withValues(alpha: 0.5)
            : Colors.transparent,
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Text(
              day,
              style: isTotal
                  ? AppTextStyles.mono12(
                      color: textColor, weight: FontWeight.w700)
                  : AppTextStyles.mono12(color: textColor),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              forecastCovers.toString(),
              style: AppTextStyles.mono12(color: textColor),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              requiredFohHours.toString(),
              style: AppTextStyles.mono12(
                  color: isTotal ? AppColors.gold : AppColors.secondaryText),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              requiredBohHours.toString(),
              style: AppTextStyles.mono12(
                  color: isTotal ? AppColors.gold : AppColors.secondaryText),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
