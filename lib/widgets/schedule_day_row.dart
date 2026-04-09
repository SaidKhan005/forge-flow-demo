import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
class ScheduleDayRow extends StatelessWidget {
  final String day;
  final int forecastCovers;
  final int requiredFohHours;
  final int requiredBohHours;
  final bool isHeader;
  final bool isTotal;
  final bool isSubrow; // true for daypart sub-rows (indented, muted label)
  final Widget? trailing; // optional chevron or icon, rendered inside the row

  const ScheduleDayRow({
    super.key,
    required this.day,
    required this.forecastCovers,
    required this.requiredFohHours,
    required this.requiredBohHours,
    this.isHeader = false,
    this.isTotal = false,
    this.isSubrow = false,
    this.trailing,
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.backgroundSurface, AppColors.shimmer],
          ),
        ),
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

    final labelColor = isSubrow ? AppColors.textMuted : textColor;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: isTotal
            ? AppColors.rule.withValues(alpha: 0.5)
            : Colors.transparent,
      ),
      child: Row(
        children: [
          Expanded(
            flex: 2,
            child: Row(
              children: [
                if (isSubrow) const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    day,
                    style: isTotal
                        ? AppTextStyles.mono12(
                            color: labelColor, weight: FontWeight.w700)
                        : AppTextStyles.mono12(color: labelColor),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
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
                  color: isTotal ? AppColors.sunsetDark : AppColors.secondaryText),
              textAlign: TextAlign.right,
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              requiredBohHours.toString(),
              style: AppTextStyles.mono12(
                  color: isTotal ? AppColors.sunsetDark : AppColors.secondaryText),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}
