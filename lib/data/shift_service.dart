import '../domain/models/closed_shift_input.dart';
import '../domain/models/shift_fact.dart';
import '../domain/models/target_snapshot.dart';
import '../domain/services/shift_fact_builder.dart';
import '../domain/services/target_snapshot_builder.dart';
import '../models/history_pattern_record.dart';
import '../models/shift_record.dart';
import '../models/week_data.dart';
import '../models/week_record.dart';
import '../services/history_pattern_builder.dart';
import '../services/labor_model.dart';
import 'database_helper.dart';
import 'meridian_data.dart'; // provides MeridianConfig + BaselineData

class ShiftService {
  ShiftService._();
  static final ShiftService instance = ShiftService._();

  // ── Week-to-date rollup from closed shift_records ────────────────────────────

  Future<WeekData?> getWeekToDate(String weekId, String weekLabel) async {
    final shifts = await DatabaseHelper.instance.getShiftsForWeek(weekId);
    final closed = shifts.where((s) => s.isClosed).toList();
    if (closed.isEmpty) return null;

    final totalCovers        = closed.fold<int>(0, (s, r) => s + r.covers);
    final totalFoh           = closed.fold<int>(0, (s, r) => s + r.fohHours);
    final totalBoh           = closed.fold<int>(0, (s, r) => s + r.bohHours);
    final totalSales         = closed.fold<double>(0, (s, r) => s + r.actualSales);
    final wtdForecastCovers       = closed.fold<int>(0, (s, r) => s + r.forecastCovers);
    final totalWeekForecastCovers = shifts.fold<int>(0, (s, r) => s + r.forecastCovers);

    final avgPPA  = totalCovers > 0 ? totalSales / totalCovers : 0.0;
    final avgCPLH = totalFoh    > 0 ? totalCovers / totalFoh   : 0.0;
    final avgSPLH = totalBoh    > 0 ? totalSales  / totalBoh   : 0.0;

    // Aggregate stored labor dollars; used for WTD totals and blended wages
    final totalFohLaborDollar = closed.fold<double>(0, (s, r) => s + r.fohLaborDollar);
    final totalBohLaborDollar = closed.fold<double>(0, (s, r) => s + r.bohLaborDollar);
    final blendedFohWage = totalFoh > 0
        ? totalFohLaborDollar / totalFoh
        : MeridianConfig.fohWage;
    final blendedBohWage = totalBoh > 0
        ? totalBohLaborDollar / totalBoh
        : MeridianConfig.bohWage;

    final primaryLeverId = LaborModel.determineLever(
      actualCovers:      totalCovers,
      forecastCovers:    wtdForecastCovers,
      avgCPLH:           avgCPLH,
      avgPPA:            avgPPA,
      targetCPLH:        BaselineData.derivedTargetCPLH,
      targetPPA:         BaselineData.derivedTargetPPA,
      avgSPLH:           avgSPLH,
      targetSPLH:        BaselineData.derivedTargetSPLH,
      avgFohBlendedWage: blendedFohWage,
      targetFohWage:     MeridianConfig.fohWage,
      avgBohBlendedWage: blendedBohWage,
      targetBohWage:     MeridianConfig.bohWage,
    );

    // ── Day-of-week label for the sub-header ─────────────────────────────────
    const dayOrder = {'Mon': 1, 'Tue': 2, 'Wed': 3, 'Thu': 4, 'Fri': 5, 'Sat': 6, 'Sun': 7};
    const dayFull  = {1: 'Monday', 2: 'Tuesday', 3: 'Wednesday', 4: 'Thursday',
                      5: 'Friday', 6: 'Saturday', 7: 'Sunday'};
    final lastDayLabel   = closed
        .map((s) => s.dayLabel)
        .reduce((a, b) => (dayOrder[a] ?? 0) >= (dayOrder[b] ?? 0) ? a : b);
    final closedDayNum   = dayOrder[lastDayLabel] ?? 1;
    final lastClosedDay  = dayFull[closedDayNum] ?? 'Monday';

    return WeekData(
      weekId:             weekId,
      weekLabel:          weekLabel,
      totalCovers:        totalCovers,
      totalSales:         totalSales,
      totalFohHours:      totalFoh,
      totalBohHours:      totalBoh,
      shiftsCompleted:    closed.length,
      shiftsTotal:        14,   // full-week shift count for this venue
      wtdForecastCovers:       wtdForecastCovers,
      totalWeekForecastCovers: totalWeekForecastCovers,
      primaryLeverId:          primaryLeverId,
      lastClosedDay:           lastClosedDay,
      closedDayNumber:         closedDayNum,
      storedTotalFohLaborDollar: totalFohLaborDollar,
      storedTotalBohLaborDollar: totalBohLaborDollar,
    );
  }

  // ── Historical weeks ─────────────────────────────────────────────────────────

  Future<List<WeekRecord>> getWeekHistory() async {
    return DatabaseHelper.instance.getWeekHistory();
  }

  // ── History pattern records ───────────────────────────────────────────────────

  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async {
    final weeks = await getWeekHistory();
    if (weeks.isEmpty) return [];
    final weekLabelsById = {for (final w in weeks) w.weekId: w.weekLabel};
    final weekIds = weeks.map((w) => w.weekId).toList();
    final closedShifts =
        await DatabaseHelper.instance.getClosedShiftsForWeeks(weekIds);
    return HistoryPatternBuilder.fromClosedShifts(closedShifts, weekLabelsById);
  }

  // ── Close a shift ─────────────────────────────────────────────────────────────
  //
  // Accepts a raw ClosedShiftInput, runs it through the canonical domain
  // pipeline (TargetSnapshotBuilder → ShiftFactBuilder), replaces any existing
  // projected (or closed) slot for the same week/day/daypart, and upserts the
  // completed WeekRecord when the week reaches 14 closed shifts.
  //
  // Returns the stored ShiftRecord.

  Future<ShiftRecord> closeShift(ClosedShiftInput input) async {
    // 1. Lock targets at close time
    final targetSnapshot = TargetSnapshotBuilder.fromCurrentBaseline();

    // 2. Build normalized shift fact
    final shiftFact = ShiftFactBuilder.fromClosedShiftInput(input, targetSnapshot);

    // 3. Convert to ShiftRecord
    final record = _shiftRecordFromFact(shiftFact);

    // 4. Atomically replace any existing slot row
    await DatabaseHelper.instance.replaceShiftForSlot(record);

    // 5. Re-read all shifts for the week
    final allShifts = await DatabaseHelper.instance.getShiftsForWeek(input.weekId);
    final closedShifts = allShifts.where((s) => s.isClosed).toList();

    // 6. Upsert WeekRecord only when the week is fully closed (14 shifts)
    if (closedShifts.length == 14) {
      final weekRecord = _buildWeekRecord(input.weekId, closedShifts, targetSnapshot);
      await DatabaseHelper.instance.upsertWeekRecord(weekRecord);
    }

    // 7. Return the stored record
    return record;
  }

  // ── Private: convert ShiftFact → ShiftRecord ─────────────────────────────────

  ShiftRecord _shiftRecordFromFact(ShiftFact fact) {
    return ShiftRecord(
      status: 'closed',
      weekId: fact.weekId,
      dayLabel: fact.dayLabel,
      daypart: fact.daypart,
      covers: fact.covers,
      forecastCovers: fact.forecastCovers,
      ppa: fact.ppa,
      cplh: fact.cplh,
      splh: fact.splh,
      fohHours: fact.actualFohHours,
      bohHours: fact.actualBohHours,
      theoreticalLaborPct: fact.targetSnapshot.theoreticalLaborPct,
      primaryLever: fact.primaryLeverId.toUpperCase(),
      scheduledFohHours: fact.scheduledFohHours,
      scheduledBohHours: fact.scheduledBohHours,
      storedFohLaborDollar: fact.actualFohLaborDollars,
      storedBohLaborDollar: fact.actualBohLaborDollars,
      sourceSystem: fact.sourceSystem,
      sourceShiftId: fact.sourceShiftId,
    );
  }

  // ── Private: build WeekRecord from 14 closed shifts ──────────────────────────

  WeekRecord _buildWeekRecord(
    String weekId,
    List<ShiftRecord> closedShifts,
    TargetSnapshot targetSnapshot,
  ) {
    final totalCovers       = closedShifts.fold<int>(0, (s, r) => s + r.covers);
    final forecastCovers    = closedShifts.fold<int>(0, (s, r) => s + r.forecastCovers);
    final totalFohHours     = closedShifts.fold<int>(0, (s, r) => s + r.fohHours);
    final totalBohHours     = closedShifts.fold<int>(0, (s, r) => s + r.bohHours);
    final totalSales        = closedShifts.fold<double>(0, (s, r) => s + r.actualSales);
    final totalFohLaborDollar = closedShifts.fold<double>(0, (s, r) => s + r.fohLaborDollar);
    final totalBohLaborDollar = closedShifts.fold<double>(0, (s, r) => s + r.bohLaborDollar);
    final totalLaborDollar  = totalFohLaborDollar + totalBohLaborDollar;

    final avgPPA  = totalCovers > 0 ? totalSales / totalCovers : 0.0;
    final avgCPLH = totalFohHours > 0 ? totalCovers / totalFohHours : 0.0;
    final avgSPLH = totalBohHours > 0 ? totalSales / totalBohHours : 0.0;

    final blendedFohWage = totalFohHours > 0
        ? totalFohLaborDollar / totalFohHours
        : targetSnapshot.fohWage;
    final blendedBohWage = totalBohHours > 0
        ? totalBohLaborDollar / totalBohHours
        : targetSnapshot.bohWage;

    final actualLaborPct = totalSales > 0
        ? totalLaborDollar / totalSales * 100
        : 0.0;

    // Theoretical labor %: weighted from each shift's locked snapshot value
    final theoreticalLaborDollar = closedShifts.fold<double>(
      0,
      (s, r) => s + (r.actualSales * r.theoreticalLaborPct / 100),
    );
    final theoreticalLaborPct = totalSales > 0
        ? theoreticalLaborDollar / totalSales * 100
        : 0.0;

    final dollarGap = LaborModel.dollarGap(
      totalLaborDollar,
      totalCovers,
      avgPPA,
      targetCPLH: targetSnapshot.targetCPLH,
      targetSPLH: targetSnapshot.targetSPLH,
      fohWage: targetSnapshot.fohWage,
      bohWage: targetSnapshot.bohWage,
    );

    final primaryLeverId = LaborModel.determineLever(
      actualCovers:      totalCovers,
      forecastCovers:    forecastCovers,
      avgCPLH:           avgCPLH,
      avgPPA:            avgPPA,
      targetCPLH:        targetSnapshot.targetCPLH,
      targetPPA:         targetSnapshot.targetPPA,
      avgSPLH:           avgSPLH,
      targetSPLH:        targetSnapshot.targetSPLH,
      avgFohBlendedWage: blendedFohWage,
      targetFohWage:     targetSnapshot.fohWage,
      avgBohBlendedWage: blendedBohWage,
      targetBohWage:     targetSnapshot.bohWage,
    );

    return WeekRecord(
      weekId: weekId,
      weekLabel: _weekLabelFromWeekId(weekId),
      totalCovers: totalCovers,
      forecastCovers: forecastCovers,
      totalFohHours: totalFohHours,
      totalBohHours: totalBohHours,
      avgPPA: avgPPA,
      avgCPLH: avgCPLH,
      theoreticalLaborPct: theoreticalLaborPct,
      actualLaborPct: actualLaborPct,
      dollarGap: dollarGap,
      primaryLeverId: primaryLeverId,
      shiftsCompleted: closedShifts.length,
      blendedFohWage: blendedFohWage,
      blendedBohWage: blendedBohWage,
    );
  }

  // ── Private: derive week label from ISO week id ───────────────────────────────
  //
  // Parses "YYYY-Www", computes the ISO week's Tuesday date, and returns a label
  // in the form "Mon DD" (e.g. "Mar 24" for 2026-W13).

  String _weekLabelFromWeekId(String weekId) {
    // weekId format: "YYYY-Www"
    final parts = weekId.split('-W');
    if (parts.length != 2) return weekId;
    final year = int.tryParse(parts[0]);
    final week = int.tryParse(parts[1]);
    if (year == null || week == null) return weekId;

    // ISO week 1 contains the first Thursday of the year.
    // Jan 4 is always in week 1. Find the Monday of week 1.
    final jan4 = DateTime(year, 1, 4);
    final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));

    // Monday of the target week
    final monday = week1Monday.add(Duration(days: (week - 1) * 7));

    // Use Tuesday (day index 1 past Monday) as the representative label date,
    // matching the "Mar 24" convention used in demo history for 2026-W13
    // (Mon Mar 23 + 1 = Tue Mar 24).
    final labelDate = monday.add(const Duration(days: 1));

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final month = months[labelDate.month - 1];
    return '$month ${labelDate.day}';
  }

  // ── Reset to demo data ───────────────────────────────────────────────────────

  Future<void> reseedDemo() async {
    await DatabaseHelper.instance.reseedDemo();
  }
}
