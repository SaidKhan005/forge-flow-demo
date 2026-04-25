// Phase 7.55o.5 — Baseline Manager calendar grid + legend.
//
// Extracted from baseline_manager_screen.dart. Shows the 60-day
// calendar window with selected / suggested star overlays and the
// legend that explains the three dot colors. Behaviour and colors
// are unchanged.

import 'package:flutter/material.dart';

import '../../models/baseline_candidate_shift.dart';
import '../../theme/app_theme.dart';
import 'baseline_manager_helpers.dart';

// ─── Calendar grid (60-day window) ────────────────────────────────────────────

class CalendarGrid extends StatelessWidget {
  final List<String> windowDates;
  final Map<String, List<BaselineCandidateShift>> shiftsByDate;
  final Set<String> draftKeys;
  final ValueChanged<String> onDateTap;

  const CalendarGrid({
    super.key,
    required this.windowDates,
    required this.shiftsByDate,
    required this.draftKeys,
    required this.onDateTap,
  });

  @override
  Widget build(BuildContext context) {
    if (windowDates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'No closed shifts found.\nClose some shifts to build your baseline.',
            textAlign: TextAlign.center,
            style: AppTextStyles.body13(color: AppColors.textMuted),
          ),
        ),
      );
    }

    final startDt = parseIsoDate(windowDates.first);
    final endDt = parseIsoDate(windowDates.last);

    // Pad to full weeks (Monday-Sunday). Use DateTime constructor to
    // avoid DST day-shift bugs on Duration arithmetic.
    final mondayOffset = (startDt.weekday - 1) % 7;
    final gridStart = DateTime(
        startDt.year, startDt.month, startDt.day - mondayOffset);
    final sundayOffset = (7 - endDt.weekday) % 7;
    final gridEnd = DateTime(
        endDt.year, endDt.month, endDt.day + sundayOffset);
    // Build every date in the padded grid using constructor-based stepping
    // only — no Duration arithmetic — so DST boundaries never shift a cell.
    final gridDates = <DateTime>[];
    {
      var d = gridStart;
      while (!d.isAfter(gridEnd)) {
        gridDates.add(d);
        d = DateTime(d.year, d.month, d.day + 1);
      }
    }

    final windowSet = windowDates.toSet();

    // Build rows: month labels + week rows
    final rows = <Widget>[];
    int? prevMonth;

    for (int weekStart = 0; weekStart < gridDates.length; weekStart += 7) {
      // Find first in-window date in this week for month labelling
      for (int j = 0; j < 7 && weekStart + j < gridDates.length; j++) {
        final dt = gridDates[weekStart + j];
        if (!windowSet.contains(formatIsoDate(dt))) continue;
        if (dt.month != prevMonth) {
          rows.add(Padding(
            padding: EdgeInsets.fromLTRB(0, prevMonth == null ? 0 : 8, 0, 4),
            child: Text(
              '${monthNames[dt.month - 1].toUpperCase()} ${dt.year}',
              style: AppTextStyles.mono8(color: AppColors.textMuted),
            ),
          ));
          prevMonth = dt.month;
        }
        break;
      }

      // Build one week row (7 cells)
      final cells = <Widget>[];
      for (int j = 0; j < 7; j++) {
        final dayIndex = weekStart + j;
        if (dayIndex >= gridDates.length) {
          cells.add(const Expanded(child: SizedBox(height: 38)));
          continue;
        }

        final dt = gridDates[dayIndex];
        final dateStr = formatIsoDate(dt);
        final inWindow = windowSet.contains(dateStr);

        if (!inWindow) {
          cells.add(const Expanded(child: SizedBox(height: 38)));
          continue;
        }

        final shifts = shiftsByDate[dateStr] ?? [];
        final hasShifts = shifts.isNotEmpty;
        final hasSelected =
            shifts.any((c) => draftKeys.contains(c.recordKey));
        final hasSuggested =
            shifts.any(isSuggestedStar);

        // Visual priority: selected > suggested > available
        final Color cellBg;
        final Color cellBorder;
        final Color dotColor;
        if (hasSelected) {
          cellBg = AppColors.sunset.withValues(alpha: 0.15);
          cellBorder = AppColors.sunset.withValues(alpha: 0.5);
          dotColor = AppColors.sunset;
        } else if (hasSuggested) {
          cellBg = AppColors.jade.withValues(alpha: 0.12);
          cellBorder = AppColors.jade.withValues(alpha: 0.5);
          dotColor = AppColors.peacock;
        } else if (hasShifts) {
          cellBg = AppColors.backgroundMid;
          cellBorder = AppColors.borderSubtle;
          dotColor = AppColors.textMuted;
        } else {
          cellBg = Colors.transparent;
          cellBorder = Colors.transparent;
          dotColor = Colors.transparent;
        }

        cells.add(Expanded(
          child: GestureDetector(
            key: ValueKey<String>('cal_$dateStr'),
            onTap: () => onDateTap(dateStr),
            child: Container(
              height: 38,
              margin: const EdgeInsets.all(1),
              decoration: BoxDecoration(
                color: cellBg,
                border: Border.all(color: cellBorder, width: 1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${dt.day}',
                    style: AppTextStyles.mono10(
                      color: hasShifts
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                  if (hasShifts)
                    Container(
                      width: 4,
                      height: 4,
                      margin: const EdgeInsets.only(top: 2),
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ));
      }

      rows.add(Row(children: cells));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text('LAST 60 DAYS',
              style: AppTextStyles.mono11(color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Text(
            '${formatDisplayDate(windowDates.first)} – '
            '${formatDisplayDate(windowDates.last)}',
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
          const SizedBox(height: 6),
          // Legend
          Row(
            children: [
              _LegendDot(color: AppColors.textMuted, label: 'Closed shifts'),
              const SizedBox(width: 12),
              _LegendDot(color: AppColors.peacock, label: 'Suggested star'),
              const SizedBox(width: 12),
              _LegendDot(color: AppColors.sunset, label: 'Selected star'),
            ],
          ),
          const SizedBox(height: 8),
          // Weekday labels
          Row(
            children: ['M', 'T', 'W', 'T', 'F', 'S', 'S']
                .map((d) => Expanded(
                      child: Center(
                        child: Text(d,
                            style: AppTextStyles.mono8(
                                color: AppColors.textMuted)),
                      ),
                    ))
                .toList(),
          ),
          const SizedBox(height: 4),
          // Calendar rows
          ...rows,
        ],
      ),
    );
  }
}

// ─── Legend dot ───────────────────────────────────────────────────────────────

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: AppTextStyles.mono7(color: AppColors.textMuted)),
      ],
    );
  }
}
