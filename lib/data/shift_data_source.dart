// ─── ShiftDataSource — data-layer interface ───────────────────────────────────
// Decouples screens from SQLite. Swap LiveShiftDataSource for
// StaticShiftDataSource (or a mock) without touching any UI file.
//
// All screens that need WTD or history data call ShiftDataSource methods —
// never ShiftService directly.

import '../models/history_pattern_record.dart';
import '../models/week_data.dart';
import '../models/week_record.dart';
import '../services/history_pattern_builder.dart';
import 'demo_data.dart';
import 'meridian_data.dart';
import 'shift_service.dart';
import '../services/labor_model.dart';

abstract class ShiftDataSource {
  Future<WeekData?> getWeekToDate();
  Future<List<WeekRecord>> getWeekHistory();
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords();
}

// ── Live — reads from SQLite via ShiftService ─────────────────────────────────

class LiveShiftDataSource implements ShiftDataSource {
  const LiveShiftDataSource();

  @override
  Future<WeekData?> getWeekToDate() => ShiftService.instance
      .getWeekToDate(WeekToDate.currentWeekId, WeekToDate.weekLabel);

  @override
  Future<List<WeekRecord>> getWeekHistory() =>
      ShiftService.instance.getWeekHistory();

  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() =>
      ShiftService.instance.getHistoryPatternRecords();
}

// ── Static — wraps WeekToDate constants for demo / offline use ────────────────

class StaticShiftDataSource implements ShiftDataSource {
  const StaticShiftDataSource();

  @override
  Future<WeekData?> getWeekToDate() async {
    final primaryLeverId = LaborModel.determineLever(
      actualCovers:      WeekToDate.totalCovers,
      forecastCovers:    WeekToDate.wtdForecastCovers,
      avgCPLH:           WeekToDate.avgCPLH,
      avgPPA:            WeekToDate.avgPPA,
      targetCPLH:        BaselineData.derivedTargetCPLH,
      targetPPA:         BaselineData.derivedTargetPPA,
      avgSPLH:           WeekToDate.avgSPLH,
      targetSPLH:        BaselineData.derivedTargetSPLH,
      avgFohBlendedWage: WeekToDate.blendedFohWage,
      targetFohWage:     MeridianConfig.fohWage,
      avgBohBlendedWage: WeekToDate.blendedBohWage,
      targetBohWage:     MeridianConfig.bohWage,
    );
    return WeekData(
      weekId:            WeekToDate.currentWeekId,
      weekLabel:         WeekToDate.weekLabel,
      totalCovers:       WeekToDate.totalCovers,
      totalSales:        WeekToDate.totalCovers * WeekToDate.avgPPA,
      totalFohHours:     WeekToDate.totalFohHours,
      totalBohHours:     WeekToDate.totalBohHours,
      shiftsCompleted:         WeekToDate.shiftsCompleted,
      shiftsTotal:             WeekToDate.shiftsTotal,
      wtdForecastCovers:       WeekToDate.wtdForecastCovers,
      totalWeekForecastCovers: 2760, // 9 closed (1780) + 5 projected (980)
      primaryLeverId:          primaryLeverId,
      lastClosedDay:           WeekToDate.lastClosedDay,
      closedDayNumber:         WeekToDate.closedDayNumber,
    );
  }

  @override
  Future<List<WeekRecord>> getWeekHistory() async => DemoData.weekHistory;

  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async {
    final weekLabelsById = {
      for (final w in DemoData.weekHistory) w.weekId: w.weekLabel
    };
    return HistoryPatternBuilder.fromClosedShifts(
        DemoData.historicalClosedShifts, weekLabelsById);
  }
}
