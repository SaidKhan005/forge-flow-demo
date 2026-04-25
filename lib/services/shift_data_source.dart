// ─── ShiftDataSource — data-layer interface ───────────────────────────────────
// Decouples screens from SQLite. Swap LiveShiftDataSource for
// StaticShiftDataSource (or a mock) without touching any UI file.

import '../models/history_pattern_record.dart';
import '../models/shift_record.dart';
import '../models/week_data.dart';
import '../models/week_record.dart';
import 'history_pattern_builder.dart';
import 'labor_model.dart';
import '../data/app_defaults.dart';
import '../dev/demo_fixture_data.dart';
import 'mock_replay_data_source_provider.dart';
import 'shift_service.dart';

abstract class ShiftDataSource {
  Future<WeekData?> getWeekToDate();
  Future<List<WeekRecord>> getWeekHistory();
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords();
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId);
  Future<List<ShiftRecord>> getHistoricalClosedShifts();
}

// ── Live — reads from SQLite via ShiftService ─────────────────────────────────

class LiveShiftDataSource implements ShiftDataSource {
  const LiveShiftDataSource();

  @override
  Future<WeekData?> getWeekToDate() =>
      ShiftService.instance.getLiveWeekToDate();

  @override
  Future<List<WeekRecord>> getWeekHistory() =>
      ShiftService.instance.getWeekHistory();

  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() =>
      ShiftService.instance.getHistoryPatternRecords();

  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) =>
      ShiftService.instance.getFullWeekShifts(weekId);

  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() =>
      ShiftService.instance.getHistoricalClosedShifts();
}

// ── Static — test/preview compatibility using mock replay ────────────────────
// Non-SQLite fixture source backed by the mock-replay provider seam
// (7.57.3c). Used by widget tests that cannot use sqflite I/O.
// NOT wired into app runtime — ForgeFlowScope provides LiveShiftDataSource.
// Target fields use BaselineData/MeridianConfig as compatibility bridge (7.55i).

class StaticShiftDataSource implements ShiftDataSource {
  /// Mock-replay reads route through the [MockReplayProvider] seam so
  /// tests can swap in a fake without touching the seed file. Default
  /// retains the real wrap → pre-7.57.3c behavior is byte-identical.
  const StaticShiftDataSource({
    MockReplayProvider provider = const MockReplayDataSourceProvider(),
  }) : _provider = provider;

  final MockReplayProvider _provider;

  @override
  Future<WeekData?> getWeekToDate() async {
    final replay = await _provider.fetch();
    final closed = replay.currentWeekShifts.where((s) => s.isClosed).toList();

    final totalCovers = closed.fold<int>(0, (s, r) => s + r.covers);
    final totalFohHours = closed.fold<int>(0, (s, r) => s + r.fohHours);
    final totalBohHours = closed.fold<int>(0, (s, r) => s + r.bohHours);
    final totalSales = closed.fold<double>(0, (s, r) => s + r.actualSales);
    final wtdForecastCovers =
        closed.fold<int>(0, (s, r) => s + r.forecastCovers);
    final allForecastCovers =
        replay.currentWeekShifts.fold<int>(0, (s, r) => s + r.forecastCovers);
    final maxClosedBusinessDate = closed
        .map((s) => s.businessDate)
        .whereType<String>()
        .fold<String?>(
            null, (max, d) => max == null || d.compareTo(max) > 0 ? d : max);

    final avgPPA = totalCovers > 0 ? totalSales / totalCovers : 0.0;
    final avgCPLH = totalFohHours > 0 ? totalCovers / totalFohHours : 0.0;
    final avgSPLH = totalBohHours > 0 ? totalSales / totalBohHours : 0.0;

    final primaryLeverId = LaborModel.determineLever(
      actualCovers: totalCovers,
      forecastCovers: wtdForecastCovers,
      avgCPLH: avgCPLH,
      avgPPA: avgPPA,
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      avgSPLH: avgSPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
    );

    return WeekData(
      weekId: replay.scenario.currentWeekId,
      weekLabel: 'Week of Mar 24',
      totalCovers: totalCovers,
      totalSales: totalSales,
      totalFohHours: totalFohHours,
      totalBohHours: totalBohHours,
      shiftsCompleted: closed.length,
      shiftsTotal: replay.currentWeekShifts.length,
      wtdForecastCovers: wtdForecastCovers,
      totalWeekForecastCovers: allForecastCovers,
      primaryLeverId: primaryLeverId,
      lastClosedBusinessDate: maxClosedBusinessDate,
      targetCPLH: BaselineData.derivedTargetCPLH,
      targetSPLH: BaselineData.derivedTargetSPLH,
      targetPPA: BaselineData.derivedTargetPPA,
      targetFohWage: MeridianConfig.fohWage,
      targetBohWage: MeridianConfig.bohWage,
      theoreticalFohLaborPct: BaselineData.derivedFohTheoreticalLaborPct,
      theoreticalBohLaborPct: BaselineData.derivedBohTheoreticalLaborPct,
      theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
    );
  }

  @override
  Future<List<WeekRecord>> getWeekHistory() async {
    final replay = await _provider.fetch();
    return replay.weekRecords;
  }

  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async {
    final replay = await _provider.fetch();
    final weekLabelsById = {
      for (final w in replay.weekRecords) w.weekId: w.weekLabel
    };
    return HistoryPatternBuilder.fromClosedShifts(
        replay.historicalClosedShifts, weekLabelsById);
  }

  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() async {
    final replay = await _provider.fetch();
    return replay.historicalClosedShifts;
  }

  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async {
    final replay = await _provider.fetch();
    return replay.currentWeekShifts
        .map((s) => s.withLockedTargetDefaults(
              defaultTargetCPLH: MeridianConfig.targetCPLH,
              defaultTargetSPLH: MeridianConfig.targetSPLH,
              defaultTargetPPA: MeridianConfig.targetPPA,
              defaultFohWage: MeridianConfig.fohWage,
              defaultBohWage: MeridianConfig.bohWage,
              defaultOpzFloorCPLH: MeridianConfig.opzFloorCPLH,
              defaultOpzCeilingCPLH: MeridianConfig.opzCeilingCPLH,
              defaultTheoreticalFohLaborPct: MeridianConfig.fohTheoreticalLaborPct,
              defaultTheoreticalBohLaborPct: MeridianConfig.bohTheoreticalLaborPct,
            ))
        .toList();
  }
}
