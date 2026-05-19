// Builds HistoryPatternRecords from real closed ShiftRecords.
//
// Replaces the manual hand-authored DemoData.historyPatternRecords list.
// The ingest path (Phase 3) will close shifts into SQLite; this builder
// reads those records back and produces the pattern signal that
// HistoryTeachingAnalyzer summarizes.
//
// Phase 7.55k.3: DaypartPatternSummaryBuilder now exists as a richer
// aggregate builder. This builder remains the active path for
// HistoryTeachingAnalyzer and LearnTeachingAnalyzer until 7.55k.5 /
// 7.55k.6 migrate them.

import '../domain/constants/app_defaults.dart';
import '../domain/models/restaurant_timing_config.dart';
import '../domain/services/shift_boundary_resolver.dart';
import '../models/history_pattern_record.dart';
import '../models/shift_record.dart';
import '../services/closed_timing_label_resolver.dart';
import '../services/labor_model.dart';

typedef HistoryPatternShiftCloseAuthorityResolver =
    ShiftCloseAuthority Function(ShiftRecord shift);

class HistoryPatternBuilder {
  HistoryPatternBuilder._();

  /// Builds one [HistoryPatternRecord] per eligible closed shift.
  ///
  /// Eligibility rules:
  /// - `shift` is eligible for closed-truth surfaces
  /// - `shift.normalizedLeverId != 'on_model'`
  /// - `shift.normalizedLeverId` exists in `LeverCards.all`
  ///
  /// [weekLabelsById] maps weekId → human-readable label (e.g. 'Mar 17').
  /// Falls back to the raw weekId when no label is found.
  static List<HistoryPatternRecord> fromClosedShifts(
    List<ShiftRecord> shifts,
    Map<String, String> weekLabelsById, {
    ClosedTimingLabelResolver? timingLabelResolver,
    String? currentOperationalBusinessDate,
    HistoryPatternShiftCloseAuthorityResolver? shiftCloseAuthorityForRow,
  }) {
    final validLeverIds = LeverCards.all.map((l) => l.id).toSet();

    final result = <HistoryPatternRecord>[];
    for (final shift in shifts) {
      if (!_isEligibleClosedTruth(
        shift,
        currentOperationalBusinessDate: currentOperationalBusinessDate,
        shiftCloseAuthorityForRow: shiftCloseAuthorityForRow,
      )) {
        continue;
      }

      final leverId = shift.normalizedLeverId;
      if (leverId == 'on_model') continue;
      if (!validLeverIds.contains(leverId)) continue;

      result.add(
        HistoryPatternRecord(
          weekId: shift.weekId,
          weekLabel: weekLabelsById[shift.weekId] ?? shift.weekId,
          dayLabel: shift.dayLabel,
          daypart: timingLabelResolver?.bucketKeyFor(shift) ?? shift.daypart,
          servicePeriodLabel: timingLabelResolver?.labelFor(shift),
          leverId: leverId,
          isBenchmark: LaborModel.isFavorableLever(leverId),
        ),
      );
    }
    return result;
  }

  static bool _isEligibleClosedTruth(
    ShiftRecord shift, {
    required String? currentOperationalBusinessDate,
    required HistoryPatternShiftCloseAuthorityResolver?
    shiftCloseAuthorityForRow,
  }) {
    if (currentOperationalBusinessDate == null) return shift.isClosed;
    return ShiftBoundaryResolver.isEligibleForClosedTruth(
      rowStatus: shift.status,
      shiftCloseAuthority:
          shiftCloseAuthorityForRow?.call(shift) ??
          ShiftCloseAuthority.appLocalCutoffFallback,
      rowBusinessDate: shift.businessDate,
      currentOperationalBusinessDate: currentOperationalBusinessDate,
    );
  }
}
