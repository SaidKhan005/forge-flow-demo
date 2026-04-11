import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../data/legacy_fixture_data.dart';

class DaypartTable extends StatelessWidget {
  final List<DaypartRange> dayparts;

  const DaypartTable({super.key, required this.dayparts});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.surface, AppColors.cardGlow],
        ),
        border: Border.all(color: AppColors.rule, width: 1),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        children: [
          // Header row
          _TableRow(
            cells: const ['DAYPART', 'AVG COVERS', 'CPLH', 'SPLH', 'PPA'],
            isHeader: true,
          ),
          Container(height: 1, color: AppColors.rule),
          // Data rows
          ...dayparts.asMap().entries.map((entry) {
            final stat = entry.value;
            final isLast = entry.key == dayparts.length - 1;
            return Column(
              children: [
                _TableRow(
                  cells: [
                    stat.label,
                    stat.avgCovers.toString(),
                    stat.avgCPLH.toStringAsFixed(2),
                    '\$${stat.avgSPLH.toStringAsFixed(0)}',
                    '\$${stat.avgPPA.toStringAsFixed(2)}',
                  ],
                  isHeader: false,
                ),
                if (!isLast) Container(height: 1, color: AppColors.rule),
              ],
            );
          }),
        ],
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  final List<String> cells;
  final bool isHeader;

  const _TableRow({required this.cells, required this.isHeader});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: cells.asMap().entries.map((entry) {
          final i = entry.key;
          final cell = entry.value;
          final isFirst = i == 0;
          return Expanded(
            flex: isFirst ? 3 : 2,
            child: Text(
              cell,
              style: isHeader
                  ? AppTextStyles.mono7()
                  : (isFirst
                      ? AppTextStyles.body11(
                          color: AppColors.primaryText,
                          style: FontStyle.normal,
                        )
                      : AppTextStyles.mono10(color: AppColors.primaryText)),
              textAlign: isFirst ? TextAlign.left : TextAlign.right,
            ),
          );
        }).toList(),
      ),
    );
  }
}
