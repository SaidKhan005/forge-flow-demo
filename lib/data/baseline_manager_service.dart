// Phase 5 — Baseline Manager Service
// Loads historical closed shifts as selectable baseline candidates,
// persists the manager's selection, and applies it to BaselineData.

import '../models/baseline_candidate_shift.dart';
import 'database_helper.dart';
import 'meridian_data.dart';
import 'shift_service.dart';

class BaselineManagerService {
  BaselineManagerService._();
  static final BaselineManagerService instance = BaselineManagerService._();

  // ── Candidate loading ──────────────────────────────────────────────────────

  Future<List<BaselineCandidateShift>> getCandidateShifts() async {
    final weeks = await ShiftService.instance.getWeekHistory();
    if (weeks.isEmpty) return [];

    final weekLabelsById = {for (final w in weeks) w.weekId: w.weekLabel};
    final weekIds = weeks.map((w) => w.weekId).toList();

    final closedShifts =
        await DatabaseHelper.instance.getClosedShiftsForWeeks(weekIds);
    final selectedKeys =
        await DatabaseHelper.instance.getBaselineSelectedRecordKeys();

    final candidates = closedShifts.map((shift) {
      final recordKey =
          '${shift.weekId}|${shift.dayLabel}|${shift.daypart}';
      return BaselineCandidateShift(
        recordKey:      recordKey,
        weekId:         shift.weekId,
        weekLabel:      weekLabelsById[shift.weekId] ?? shift.weekId,
        dayLabel:       shift.dayLabel,
        daypart:        shift.daypart,
        covers:         shift.covers,
        cplh:           shift.cplh,
        splh:           shift.splh,
        ppa:            shift.ppa,
        primaryLeverId: shift.normalizedLeverId,
        isSelected:     selectedKeys.contains(recordKey),
      );
    }).toList();

    // Sort: daypart order, then cplh DESC, splh DESC, ppa DESC, weekId DESC, day order
    const daypartOrder = <String, int>{
      'lunch': 0, 'dinner': 1, 'late_night': 2,
    };
    const dayOrder = <String, int>{
      'Mon': 0, 'Tue': 1, 'Wed': 2, 'Thu': 3, 'Fri': 4, 'Sat': 5, 'Sun': 6,
    };

    candidates.sort((a, b) {
      final dp = (daypartOrder[a.daypart] ?? 99)
          .compareTo(daypartOrder[b.daypart] ?? 99);
      if (dp != 0) return dp;

      final cplh = b.cplh.compareTo(a.cplh);
      if (cplh != 0) return cplh;

      final splh = b.splh.compareTo(a.splh);
      if (splh != 0) return splh;

      final ppa = b.ppa.compareTo(a.ppa);
      if (ppa != 0) return ppa;

      final week = b.weekId.compareTo(a.weekId);
      if (week != 0) return week;

      return (dayOrder[a.dayLabel] ?? 99)
          .compareTo(dayOrder[b.dayLabel] ?? 99);
    });

    return candidates;
  }

  // ── Apply persisted selection to BaselineData ──────────────────────────────

  Future<void> primeManagerOverride() async {
    final candidates = await getCandidateShifts();

    if (candidates.isEmpty) {
      BaselineData.clearHistoricalContext();
      BaselineData.clearManagerOverride();
      return;
    }

    // Always load the full tracked historical context first
    final fullHistoricalContext = candidates
        .map((c) => DaypartBaseline(
              daypart:    c.daypart,
              cplh:       c.cplh,
              splh:       c.splh,
              ppa:        c.ppa,
              covers:     c.covers,
              isSelected: c.isSelected,
            ))
        .toList();

    BaselineData.applyHistoricalContext(fullHistoricalContext);

    final selected = candidates.where((c) => c.isSelected).toList();

    if (selected.isEmpty) {
      BaselineData.clearManagerOverride();
      return;
    }

    BaselineData.applyManagerOverride(fullHistoricalContext);
  }

  // ── Commit draft selection ─────────────────────────────────────────────────

  Future<void> saveSelection(Set<String> selectedKeys) async {
    await DatabaseHelper.instance
        .replaceBaselineSelectedRecordKeys(selectedKeys);
    if (selectedKeys.isEmpty) {
      BaselineData.clearManagerOverride();
    } else {
      await primeManagerOverride();
    }
  }
}
