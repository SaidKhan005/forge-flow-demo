// R1 — Choose Star Shifts: 2-state hero calendar.
//
// The 60-day window calendar is the dominant hero element of the
// screen. Cells have exactly TWO states: closed (a date with closed
// shifts in the active lens) and selected (a date with at least one
// drafted star in the active lens). The old "suggested" state and
// its legend entry are gone. The legend now has exactly two chips:
// Closed and Selected.
//
// Shifts are filtered to the active lens period before any cell math.
// For the Whole-day lens a small count badge ("n/total") shows how
// many of that date's services are drafted. The badge denominator and
// every period iteration come from the resolved, operator-configured
// service-period definitions threaded in via [periodIds] — never a
// hardcoded 3.
//
// The header text is exactly "LAST 60 DAYS" (no scope-word prefix);
// the date range sits on the right of that header line.

import 'package:flutter/material.dart';

import '../../models/baseline_candidate_shift.dart';
import '../../theme/app_theme.dart';
import 'baseline_manager_helpers.dart';
import 'baseline_manager_lens.dart';

// ─── Calendar grid (60-day window, hero element) ──────────────────────────────

class CalendarGrid extends StatelessWidget {
  final List<String> windowDates;
  final Map<String, List<BaselineCandidateShift>> shiftsByDate;
  final Set<String> draftKeys;
  final ValueChanged<String> onDateTap;

  /// Active lens period id. [kWholeDayLensId] = rollup of all periods.
  final String activeLensId;

  /// Resolved, operator-configured service-period ids (ordered). Used
  /// only for the Whole-day per-day count badge denominator. Never a
  /// hardcoded list — the parent threads
  /// `ServicePeriodDefinitionResolver.ordered(defs).map((d) => d.id)`.
  final List<String> periodIds;

  const CalendarGrid({
    super.key,
    required this.windowDates,
    required this.shiftsByDate,
    required this.draftKeys,
    required this.onDateTap,
    required this.activeLensId,
    required this.periodIds,
  });

  bool get _isWholeDay => activeLensId == kWholeDayLensId;

  /// Shifts for [dateStr] scoped to the active lens. Whole day = all
  /// configured-period shifts on that date; a period lens = only that
  /// period's shifts.
  List<BaselineCandidateShift> _lensShifts(String dateStr) {
    final all = shiftsByDate[dateStr] ?? const <BaselineCandidateShift>[];
    if (_isWholeDay) return all;
    return all.where((c) => c.daypart == activeLensId).toList();
  }

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
            padding: EdgeInsets.fromLTRB(0, prevMonth == null ? 0 : 10, 0, 6),
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
          cells.add(const Expanded(child: SizedBox(height: 50)));
          continue;
        }

        final dt = gridDates[dayIndex];
        final dateStr = formatIsoDate(dt);
        final inWindow = windowSet.contains(dateStr);

        if (!inWindow) {
          cells.add(const Expanded(child: SizedBox(height: 50)));
          continue;
        }

        final shifts = _lensShifts(dateStr);
        final hasShifts = shifts.isNotEmpty;
        final selectedCount =
            shifts.where((c) => draftKeys.contains(c.recordKey)).length;
        final hasSelected = selectedCount > 0;

        // TWO states only: selected > closed. No "suggested".
        final Color cellBg;
        final Color cellBorder;
        final Color dotColor;
        if (hasSelected) {
          cellBg = AppColors.sunset.withValues(alpha: 0.15);
          cellBorder = AppColors.sunset.withValues(alpha: 0.6);
          dotColor = AppColors.sunset;
        } else if (hasShifts) {
          cellBg = AppColors.backgroundMid;
          cellBorder = AppColors.borderSubtle;
          dotColor = AppColors.textMuted;
        } else {
          cellBg = Colors.transparent;
          cellBorder = Colors.transparent;
          dotColor = Colors.transparent;
        }

        // Whole-day lens: badge "selected/total" of that day's
        // configured services. Denominator comes from the resolved
        // configured periods present on the date, never a hardcoded 3.
        String? countBadge;
        if (_isWholeDay && hasShifts) {
          final servicesOnDay = shifts
              .where((c) => periodIds.contains(c.daypart))
              .map((c) => c.daypart)
              .toSet()
              .length;
          if (servicesOnDay > 0) {
            countBadge = '$selectedCount/$servicesOnDay';
          }
        }

        cells.add(Expanded(
          child: GestureDetector(
            key: ValueKey<String>('cal_$dateStr'),
            onTap: () => onDateTap(dateStr),
            child: Container(
              height: 50,
              margin: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: cellBg,
                border: Border.all(color: cellBorder, width: 1),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${dt.day}',
                    style: AppTextStyles.mono11(
                      color: hasShifts
                          ? AppColors.textPrimary
                          : AppColors.textMuted,
                    ),
                  ),
                  if (countBadge != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        countBadge,
                        style: AppTextStyles.mono7(
                          color: hasSelected
                              ? AppColors.sunsetDark
                              : AppColors.textMuted,
                        ),
                      ),
                    )
                  else if (hasShifts)
                    Container(
                      width: 5,
                      height: 5,
                      margin: const EdgeInsets.only(top: 3),
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
          // Section title — the calendar is the hero of this screen.
          Text(
            'Star shift selection',
            style: AppTextStyles.mono11(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 10),
          // Header line: exactly "LAST 60 DAYS" with the date range
          // pinned to the right. No scope-word prefix.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('LAST 60 DAYS',
                  style: AppTextStyles.mono11(color: AppColors.textMuted)),
              Text(
                '${formatDisplayDate(windowDates.first)} to '
                '${formatDisplayDate(windowDates.last)}',
                style: AppTextStyles.mono8(color: AppColors.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Legend — exactly two chips.
          Row(
            children: [
              _LegendDot(color: AppColors.textMuted, label: 'Closed'),
              const SizedBox(width: 16),
              _LegendDot(color: AppColors.sunset, label: 'Selected'),
            ],
          ),
          const SizedBox(height: 10),
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
          const SizedBox(height: 6),
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
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label, style: AppTextStyles.mono8(color: AppColors.textMuted)),
      ],
    );
  }
}
