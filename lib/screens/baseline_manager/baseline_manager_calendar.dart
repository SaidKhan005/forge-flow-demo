// Choose Star Shifts R1: hero calendar grid (60-day window).
//
// The calendar is the dominant element of the screen. Cells have TWO
// states only: closed (has selectable closed shifts) and selected (the
// operator picked at least one shift on that day). The old "suggested"
// state and its legend were removed in R1.
//
// The grid is filtered by the active service-period lens: when a period
// lens is active only that period's shifts count toward a day's state;
// "Whole day" shows every period. Lens filtering uses the day's already
// loaded candidates; no targets are recomputed here.

import 'package:flutter/material.dart';

import '../../domain/models/service_period_definition.dart';
import '../../models/baseline_candidate_shift.dart';
import '../../theme/app_theme.dart';
import 'baseline_manager_helpers.dart';
import 'baseline_manager_lens.dart';

// ─── Calendar grid (60-day window) ────────────────────────────────────────────

class CalendarGrid extends StatelessWidget {
  final List<String> windowDates;
  final Map<String, List<BaselineCandidateShift>> shiftsByDate;
  final Set<String> draftKeys;
  final ValueChanged<String> onDateTap;

  /// Active lens id: [kWholeDayLensId] shows every period; a period id
  /// restricts each day's state to that period's shifts only.
  final String activeLensId;

  /// Operator-configured service-period definitions. Drives the
  /// whole-day count badge denominator (services that day), never a
  /// hardcoded daypart count.
  final List<ServicePeriodDefinition> defs;

  const CalendarGrid({
    super.key,
    required this.windowDates,
    required this.shiftsByDate,
    required this.draftKeys,
    required this.onDateTap,
    required this.activeLensId,
    required this.defs,
  });

  /// Returns the candidates for [dateStr] that match the active lens.
  /// Whole day = all; a period lens = only that period's shifts.
  List<BaselineCandidateShift> _lensShifts(String dateStr) {
    final all = shiftsByDate[dateStr] ?? const <BaselineCandidateShift>[];
    if (activeLensId == kWholeDayLensId) return all;
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
          cells.add(const Expanded(child: SizedBox(height: 52)));
          continue;
        }

        final dt = gridDates[dayIndex];
        final dateStr = formatIsoDate(dt);
        final inWindow = windowSet.contains(dateStr);

        if (!inWindow) {
          cells.add(const Expanded(child: SizedBox(height: 52)));
          continue;
        }

        // Lens-filtered shifts drive this day's state.
        final shifts = _lensShifts(dateStr);
        final hasShifts = shifts.isNotEmpty;
        final hasSelected =
            shifts.any((c) => draftKeys.contains(c.recordKey));

        // Whole-day lens only: subtle "selected/total" badge where the
        // denominator is the number of distinct configured service
        // periods that have a shift this day (from `defs`, never a
        // hardcoded daypart count). Skipped under a period lens and on
        // days with no shifts so the existing 2-state layout is intact.
        // Prototype: the badge appears only on a SELECTED day and reads
        // n/total where total is that day's configured service-period
        // count (services that ran that day, from the resolved defs,
        // never a fixed number) and n is how many of them are kept.
        String? countBadge;
        if (activeLensId == kWholeDayLensId && hasSelected) {
          final configuredIds = defs.map((d) => d.id).toSet();
          final periodsWithShift = <String>{
            for (final c in shifts)
              if (configuredIds.contains(c.daypart)) c.daypart,
          };
          if (periodsWithShift.isNotEmpty) {
            final selectedPeriods = <String>{
              for (final c in shifts)
                if (configuredIds.contains(c.daypart) &&
                    draftKeys.contains(c.recordKey))
                  c.daypart,
            };
            countBadge =
                '${selectedPeriods.length}/${periodsWithShift.length}';
          }
        }

        // TWO states only: selected > closed. No "suggested".
        // Prototype: a selected day is a FILLED sunset cell with the day
        // number in white plus a small n/total badge; closed days are the
        // muted outlined style; empty days are blank.
        final Color cellBg;
        final Color cellBorder;
        final Color dotColor;
        final Color dayNumberColor;
        final FontWeight dayNumberWeight;
        if (hasSelected) {
          cellBg = AppColors.sunset;
          cellBorder = AppColors.sunsetDark;
          dotColor = Colors.white;
          dayNumberColor = Colors.white;
          dayNumberWeight = FontWeight.w700;
        } else if (hasShifts) {
          cellBg = AppColors.backgroundMid;
          cellBorder = AppColors.borderSubtle;
          dotColor = AppColors.textMuted;
          dayNumberColor = AppColors.textPrimary;
          dayNumberWeight = FontWeight.w600;
        } else {
          cellBg = Colors.transparent;
          cellBorder = Colors.transparent;
          dotColor = Colors.transparent;
          dayNumberColor = AppColors.textMuted;
          dayNumberWeight = FontWeight.w400;
        }

        cells.add(Expanded(
          child: GestureDetector(
            key: ValueKey<String>('cal_$dateStr'),
            onTap: () => onDateTap(dateStr),
            child: Container(
              height: 52,
              margin: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: cellBg,
                border: Border.all(color: cellBorder, width: 1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${dt.day}',
                    style: AppTextStyles.mono14(
                      color: dayNumberColor,
                      weight: dayNumberWeight,
                    ),
                  ),
                  if (hasShifts && countBadge != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        countBadge,
                        key: ValueKey<String>('cal_badge_$dateStr'),
                        style: AppTextStyles.mono7(color: dotColor),
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

    // R9: the calendar lays out at its full intrinsic height inside the
    // screen's ONE single page scroll. It is NOT its own scrollable
    // (no SingleChildScrollView / ListView here) and the parent does NOT
    // wrap it in Expanded/Flexible, so the single page scroll owns all
    // scrolling and there are no nested scroll conflicts. This is a
    // plain Column of the header, legend, weekday labels, and week rows.
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: exact text per R1 spec, no scope word, no dashes.
          Text('LAST 60 DAYS',
              style: AppTextStyles.mono14(
                color: AppColors.textPrimary,
                weight: FontWeight.w600,
              )),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${formatDisplayDate(windowDates.first)} to '
            '${formatDisplayDate(windowDates.last)}',
            style: AppTextStyles.mono8(color: AppColors.textMuted),
          ),
          const SizedBox(height: AppSpacing.md),
          // Legend: two pills (Closed, Selected) plus a count caption on
          // the whole-day lens explaining the n/total badge. Plain
          // English, no dashes.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              const _LegendPill(
                key: ValueKey<String>('cal_legend_closed'),
                swatchColor: AppColors.backgroundMid,
                swatchBorder: AppColors.borderSubtle,
                label: 'Closed',
              ),
              const _LegendPill(
                key: ValueKey<String>('cal_legend_selected'),
                swatchColor: AppColors.sunset,
                swatchBorder: AppColors.sunsetDark,
                label: 'Selected',
              ),
              if (activeLensId == kWholeDayLensId)
                Container(
                  key: const ValueKey<String>('cal_legend_count_caption'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.backgroundDeep,
                    border:
                        Border.all(color: AppColors.borderSubtle, width: 1),
                    borderRadius: AppRadius.pillR,
                  ),
                  child: Text(
                    'Count = services kept that day',
                    style: AppTextStyles.mono7(color: AppColors.textMuted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
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
          const SizedBox(height: AppSpacing.sm),
          // Calendar rows
          ...rows,
        ],
      ),
    );
  }
}

/// Small pill used in the calendar legend: a colored swatch plus a
/// plain-English label. Mirrors the prototype's `.lg` chips.
class _LegendPill extends StatelessWidget {
  final Color swatchColor;
  final Color swatchBorder;
  final String label;

  const _LegendPill({
    super.key,
    required this.swatchColor,
    required this.swatchBorder,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: AppRadius.pillR,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: swatchColor,
              border: Border.all(color: swatchBorder, width: 1),
              borderRadius: AppRadius.smallR,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            label,
            style: AppTextStyles.mono8(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}
