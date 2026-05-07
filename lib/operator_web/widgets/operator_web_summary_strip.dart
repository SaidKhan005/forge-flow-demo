import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

@immutable
class OperatorWebSummaryItem {
  const OperatorWebSummaryItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.helper,
  });

  final IconData icon;
  final String label;
  final String value;
  final String helper;
}

class OperatorWebSummaryStrip extends StatelessWidget {
  const OperatorWebSummaryStrip({
    super.key,
    required this.items,
    this.minTileWidth = 176,
  });

  final List<OperatorWebSummaryItem> items;
  final double minTileWidth;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 10.0;
        final maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 900.0;
        final columns = _columnCount(maxWidth, items.length);
        final tileWidth = ((maxWidth - spacing * (columns - 1)) / columns)
            .clamp(minTileWidth, maxWidth)
            .toDouble();
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final item in items)
              SizedBox(
                width: tileWidth,
                child: _SummaryTile(item: item),
              ),
          ],
        );
      },
    );
  }

  int _columnCount(double width, int count) {
    if (count <= 1 || width < 520) return 1;
    if (width < 840) return count >= 2 ? 2 : count;
    return count >= 4 ? 4 : count;
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.item});

  final OperatorWebSummaryItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.sunset.withValues(alpha: 0.10),
              border: Border.all(
                color: AppColors.sunset.withValues(alpha: 0.26),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(item.icon, size: 17, color: AppColors.sunsetDark),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono8(color: AppColors.textMuted),
                ),
                const SizedBox(height: 3),
                Text(
                  item.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.mono15(
                    color: AppColors.textPrimary,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  item.helper,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.body12(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
