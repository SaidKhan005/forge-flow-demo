import '../domain/models/active_target_profile.dart';
import '../domain/models/closed_shift_input.dart';
import '../domain/models/shift_fact.dart';
import '../domain/models/target_profile_version.dart';
import '../domain/repositories/open_shift_snapshot_repository.dart';
import '../domain/repositories/restaurant_scope_repository.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../domain/repositories/target_profile_repository.dart';
import '../domain/repositories/week_record_repository.dart';
import '../domain/services/shift_fact_builder.dart';
import '../domain/services/target_snapshot_builder.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../models/current_week_state.dart';
import '../models/history_pattern_record.dart';
import '../models/shift_dashboard_read_model.dart';
import '../models/shift_record.dart';
import '../models/week_data.dart';
import '../models/week_record.dart';
import '../services/history_pattern_builder.dart';
import '../services/labor_model.dart';
import 'legacy_fixture_data.dart'; // MeridianConfig for blended-wage zero-hour fallback only

class ShiftService {
  ShiftService._();
  static final ShiftService instance = ShiftService._();

  final ShiftRecordRepository _shiftRepo =
      SqliteShiftRecordRepository.instance;
  final WeekRecordRepository _weekRepo = SqliteWeekRecordRepository.instance;
  final RestaurantScopeRepository _scopeRepo =
      SqliteRestaurantScopeRepository.instance;
  final TargetProfileRepository _profileRepo =
      SqliteTargetProfileRepository.instance;
  final OpenShiftSnapshotRepository _openShiftRepo =
      SqliteOpenShiftSnapshotRepository.instance;

  Future<String> _activeRestaurantId() => _scopeRepo.getActiveRestaurantId();

  /// Loads the active target profile, bootstrapping from BaselineData if missing.
  Future<ActiveTargetProfile> _loadActiveProfile(String restaurantId) async {
    final existing = await _profileRepo.getActiveTargetProfile(restaurantId);
    if (existing != null) return existing;
    final profile =
        SqliteDatabase.buildActiveTargetProfileFromBaseline(restaurantId);
    await _profileRepo.upsertActiveTargetProfile(profile);
    return profile;
  }

  // ── Week-to-date rollup from closed shift_records ────────────────────────────

  Future<WeekData?> getWeekToDate(String weekId, String weekLabel) async {
    final restaurantId = await _activeRestaurantId();
    final profile = await _loadActiveProfile(restaurantId);
    final shifts = await _shiftRepo.getShiftsForWeek(restaurantId, weekId);
    final closed = shifts.where((s) => s.isClosed).toList();
    if (closed.isEmpty) return null;

    final totalCovers        = closed.fold<int>(0, (s, r) => s + r.covers);
    final totalFoh           = closed.fold<int>(0, (s, r) => s + r.fohHours);
    final totalBoh           = closed.fold<int>(0, (s, r) => s + r.bohHours);
    final totalSales         = closed.fold<double>(0, (s, r) => s + r.actualSales);
    final wtdForecastCovers       = closed.fold<int>(0, (s, r) => s + r.forecastCovers);
    final totalWeekForecastCovers = shifts.fold<int>(0, (s, r) => s + r.forecastCovers);

    final totalFohLaborDollar = closed.fold<double>(0, (s, r) => s + r.fohLaborDollar);
    final totalBohLaborDollar = closed.fold<double>(0, (s, r) => s + r.bohLaborDollar);
    final blendedFohWage = totalFoh > 0
        ? totalFohLaborDollar / totalFoh : profile.fohWage;
    final blendedBohWage = totalBoh > 0
        ? totalBohLaborDollar / totalBoh : profile.bohWage;

    final avgPPA  = totalCovers > 0 ? totalSales / totalCovers : 0.0;
    final avgCPLH = totalFoh    > 0 ? totalCovers / totalFoh   : 0.0;
    final avgSPLH = totalBoh    > 0 ? totalSales  / totalBoh   : 0.0;

    final primaryLeverId = LaborModel.determineLever(
      actualCovers:      totalCovers,
      forecastCovers:    wtdForecastCovers,
      avgCPLH:           avgCPLH,
      avgPPA:            avgPPA,
      targetCPLH:        profile.targetCPLH,
      targetPPA:         profile.targetPPA,
      avgSPLH:           avgSPLH,
      targetSPLH:        profile.targetSPLH,
      avgFohBlendedWage: blendedFohWage,
      targetFohWage:     profile.fohWage,
      avgBohBlendedWage: blendedBohWage,
      targetBohWage:     profile.bohWage,
    );

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
      shiftsTotal:        14,
      wtdForecastCovers:       wtdForecastCovers,
      totalWeekForecastCovers: totalWeekForecastCovers,
      primaryLeverId:          primaryLeverId,
      lastClosedDay:           lastClosedDay,
      closedDayNumber:         closedDayNum,
      storedTotalFohLaborDollar: totalFohLaborDollar,
      storedTotalBohLaborDollar: totalBohLaborDollar,
      targetCPLH: profile.targetCPLH,
      targetSPLH: profile.targetSPLH,
      targetPPA: profile.targetPPA,
      targetFohWage: profile.fohWage,
      targetBohWage: profile.bohWage,
      theoreticalFohLaborPct: profile.theoreticalFohLaborPct,
      theoreticalBohLaborPct: profile.theoreticalBohLaborPct,
      theoreticalLaborPct: profile.theoreticalLaborPct,
    );
  }

  // ── Historical weeks ─────────────────────────────────────────────────────────

  Future<List<WeekRecord>> getWeekHistory() async {
    final restaurantId = await _activeRestaurantId();
    return _weekRepo.getWeekHistory(restaurantId);
  }

  // ── History pattern records ───────────────────────────────────────────────────

  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async {
    final weeks = await getWeekHistory();
    if (weeks.isEmpty) return [];
    final weekLabelsById = {for (final w in weeks) w.weekId: w.weekLabel};
    final weekIds = weeks.map((w) => w.weekId).toList();
    final restaurantId = await _activeRestaurantId();
    final closedShifts =
        await _shiftRepo.getClosedShiftsForWeeks(restaurantId, weekIds);
    return HistoryPatternBuilder.fromClosedShifts(closedShifts, weekLabelsById);
  }

  // ── Close a shift ─────────────────────────────────────────────────────────────

  Future<ShiftRecord> closeShift(ClosedShiftInput input) async {
    // 1. Load active target profile
    final profile = await _loadActiveProfile(input.restaurantId);

    // 2. Create an immutable target profile version
    final now = DateTime.now().toIso8601String();
    final versionId = 'tpv_${now.replaceAll(RegExp(r'[^0-9]'), '')}_${input.weekId}_${input.dayLabel}_${input.daypart}';
    final version = TargetProfileVersion(
      targetProfileVersionId: versionId,
      targetProfileId: profile.targetProfileId,
      restaurantId: input.restaurantId,
      sourceType: profile.sourceType,
      targetCPLH: profile.targetCPLH,
      targetSPLH: profile.targetSPLH,
      targetPPA: profile.targetPPA,
      fohWage: profile.fohWage,
      bohWage: profile.bohWage,
      opzFloorCPLH: profile.opzFloorCPLH,
      opzCeilingCPLH: profile.opzCeilingCPLH,
      theoreticalFohLaborPct: profile.theoreticalFohLaborPct,
      theoreticalBohLaborPct: profile.theoreticalBohLaborPct,
      theoreticalLaborPct: profile.theoreticalLaborPct,
      createdAt: now,
    );
    await _profileRepo.insertTargetProfileVersion(version);

    // 3. Build locked target snapshot from the active profile + version
    final targetSnapshot = TargetSnapshotBuilder.fromActiveTargetProfile(
      profile,
      targetProfileVersionId: versionId,
    );

    // 4. Build normalized shift fact
    final shiftFact = ShiftFactBuilder.fromClosedShiftInput(input, targetSnapshot);

    // 5. Convert to ShiftRecord with locked target fields
    final record = _shiftRecordFromFact(shiftFact);

    // 6. Atomically replace any existing slot row
    await _shiftRepo.replaceShiftForSlot(record);

    // 7. Re-read all shifts for the week
    final allShifts =
        await _shiftRepo.getShiftsForWeek(input.restaurantId, input.weekId);
    final closedShifts = allShifts.where((s) => s.isClosed).toList();

    // 8. Upsert WeekRecord only when the week is fully closed (14 shifts)
    if (closedShifts.length == 14) {
      final weekRecord = _buildWeekRecord(
        input.restaurantId, input.weekId, closedShifts,
      );
      await _weekRepo.upsertWeekRecord(weekRecord);
    }

    return record;
  }

  // ── Private: convert ShiftFact → ShiftRecord ─────────────────────────────────

  ShiftRecord _shiftRecordFromFact(ShiftFact fact) {
    final ts = fact.targetSnapshot;
    return ShiftRecord(
      restaurantId: fact.restaurantId,
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
      theoreticalLaborPct: ts.theoreticalLaborPct,
      primaryLever: fact.primaryLeverId.toUpperCase(),
      scheduledFohHours: fact.scheduledFohHours,
      scheduledBohHours: fact.scheduledBohHours,
      storedFohLaborDollar: fact.actualFohLaborDollars,
      storedBohLaborDollar: fact.actualBohLaborDollars,
      targetProfileId: ts.targetProfileId,
      targetProfileVersionId: ts.targetProfileVersionId,
      targetSourceType: ts.sourceType,
      targetCPLH: ts.targetCPLH,
      targetSPLH: ts.targetSPLH,
      targetPPA: ts.targetPPA,
      targetFohWage: ts.fohWage,
      targetBohWage: ts.bohWage,
      opzFloorCPLH: ts.opzFloorCPLH,
      opzCeilingCPLH: ts.opzCeilingCPLH,
      theoreticalFohLaborPct: ts.theoreticalFohLaborPct,
      theoreticalBohLaborPct: ts.theoreticalBohLaborPct,
      sourceSystem: fact.sourceSystem,
      sourceShiftId: fact.sourceShiftId,
    );
  }

  // ── Private: build WeekRecord from 14 closed shifts ──────────────────────────
  // Materializes week-level locked targets from the closed shifts' locked targets.

  WeekRecord _buildWeekRecord(
    String restaurantId,
    String weekId,
    List<ShiftRecord> closedShifts,
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

    final blendedFohWage = totalFohHours > 0
        ? totalFohLaborDollar / totalFohHours : MeridianConfig.fohWage;
    final blendedBohWage = totalBohHours > 0
        ? totalBohLaborDollar / totalBohHours : MeridianConfig.bohWage;

    final actualLaborPct = totalSales > 0
        ? totalLaborDollar / totalSales * 100 : 0.0;

    // ── Materialize week-level locked targets from shift locked targets ────
    double _weightedAvg(double Function(ShiftRecord) field,
        double Function(ShiftRecord) weight) {
      final totalW = closedShifts.fold<double>(0, (s, r) => s + weight(r));
      if (totalW == 0) {
        return closedShifts.fold<double>(0, (s, r) => s + field(r)) /
            closedShifts.length;
      }
      return closedShifts.fold<double>(
              0, (s, r) => s + field(r) * weight(r)) /
          totalW;
    }

    double _requireShiftField(ShiftRecord r, double? value, String name) {
      if (value == null) {
        throw StateError(
          'ShiftRecord ${r.weekId}/${r.dayLabel}/${r.daypart} has null $name '
          '— locked target field must be backfilled before week rollup.',
        );
      }
      return value;
    }

    final wkTargetCPLH = _weightedAvg(
        (r) => _requireShiftField(r, r.targetCPLH, 'targetCPLH'),
        (r) => r.covers.toDouble());
    final wkTargetSPLH = _weightedAvg(
        (r) => _requireShiftField(r, r.targetSPLH, 'targetSPLH'),
        (r) => r.actualSales);
    final wkTargetPPA = _weightedAvg(
        (r) => _requireShiftField(r, r.targetPPA, 'targetPPA'),
        (r) => r.covers.toDouble());
    final wkTargetFohWage = _weightedAvg(
        (r) => _requireShiftField(r, r.targetFohWage, 'targetFohWage'),
        (r) => r.fohHours.toDouble());
    final wkTargetBohWage = _weightedAvg(
        (r) => _requireShiftField(r, r.targetBohWage, 'targetBohWage'),
        (r) => r.bohHours.toDouble());
    final wkTheoFohPct = _weightedAvg(
        (r) => _requireShiftField(r, r.theoreticalFohLaborPct, 'theoreticalFohLaborPct'),
        (r) => r.actualSales);
    final wkTheoBohPct = _weightedAvg(
        (r) => _requireShiftField(r, r.theoreticalBohLaborPct, 'theoreticalBohLaborPct'),
        (r) => r.actualSales);
    final wkTheoTotalPct = _weightedAvg(
        (r) => r.theoreticalLaborPct,
        (r) => r.actualSales);

    // Dollar gap from locked shift truth
    final summedTheoreticalLaborDollar = closedShifts.fold<double>(
      0, (s, r) => s + (r.actualSales * r.theoreticalLaborPct / 100));
    final dollarGap = totalLaborDollar - summedTheoreticalLaborDollar;

    // Primary lever from locked targets
    final primaryLeverId = LaborModel.determineLever(
      actualCovers:      totalCovers,
      forecastCovers:    forecastCovers,
      avgCPLH:           avgCPLH,
      avgPPA:            avgPPA,
      targetCPLH:        wkTargetCPLH,
      targetPPA:         wkTargetPPA,
      avgSPLH:           totalBohHours > 0 ? totalSales / totalBohHours : 0,
      targetSPLH:        wkTargetSPLH,
      avgFohBlendedWage: blendedFohWage,
      targetFohWage:     wkTargetFohWage,
      avgBohBlendedWage: blendedBohWage,
      targetBohWage:     wkTargetBohWage,
    );

    // Source type: use the first shift's source type as representative
    final sourceType = closedShifts.first.targetSourceType;

    return WeekRecord(
      restaurantId: restaurantId,
      weekId: weekId,
      weekLabel: _weekLabelFromWeekId(weekId),
      totalCovers: totalCovers,
      forecastCovers: forecastCovers,
      totalFohHours: totalFohHours,
      totalBohHours: totalBohHours,
      avgPPA: avgPPA,
      avgCPLH: avgCPLH,
      theoreticalLaborPct: wkTheoTotalPct,
      actualLaborPct: actualLaborPct,
      dollarGap: dollarGap,
      primaryLeverId: primaryLeverId,
      shiftsCompleted: closedShifts.length,
      blendedFohWage: blendedFohWage,
      blendedBohWage: blendedBohWage,
      targetSourceType: sourceType,
      targetCPLH: wkTargetCPLH,
      targetSPLH: wkTargetSPLH,
      targetPPA: wkTargetPPA,
      targetFohWage: wkTargetFohWage,
      targetBohWage: wkTargetBohWage,
      theoreticalFohLaborPct: wkTheoFohPct,
      theoreticalBohLaborPct: wkTheoBohPct,
    );
  }

  String _weekLabelFromWeekId(String weekId) {
    final parts = weekId.split('-W');
    if (parts.length != 2) return weekId;
    final year = int.tryParse(parts[0]);
    final week = int.tryParse(parts[1]);
    if (year == null || week == null) return weekId;

    final jan4 = DateTime(year, 1, 4);
    final week1Monday = jan4.subtract(Duration(days: jan4.weekday - 1));
    final monday = week1Monday.add(Duration(days: (week - 1) * 7));
    final labelDate = monday.add(const Duration(days: 1));

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final month = months[labelDate.month - 1];
    return '$month ${labelDate.day}';
  }

  // ── Live current-week resolution ──────────────────────────────────────────

  /// Resolves the current week id from persisted open/projected state.
  Future<String?> getCurrentWeekId() async {
    final restaurantId = await _activeRestaurantId();
    // Prefer the week id from the current open shift
    final openShift = await _openShiftRepo.getCurrentOpenShift(restaurantId);
    if (openShift != null) return openShift.weekId;
    // Fall back to the latest open/projected snapshot (deterministic ordering)
    return _openShiftRepo.getLatestOpenWeekId(restaurantId);
  }

  /// WTD query that resolves the current week from persisted state.
  Future<WeekData?> getLiveWeekToDate() async {
    final weekId = await getCurrentWeekId();
    if (weekId == null) return null;
    final weekLabel = _weekLabelFromWeekId(weekId);
    return getWeekToDate(weekId, weekLabel);
  }

  // ── Shift dashboard read model ────────────────────────────────────────────

  Future<ShiftDashboardReadModel?> getShiftDashboard() async {
    final restaurantId = await _activeRestaurantId();
    final profile = await _loadActiveProfile(restaurantId);
    final snapshot = await _openShiftRepo.getCurrentOpenShift(restaurantId);
    if (snapshot == null) return null;
    return ShiftDashboardReadModel.build(snapshot, profile);
  }

  // ── Full-week shifts for Variance Full Week ──────────────────────────────

  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async {
    final restaurantId = await _activeRestaurantId();
    final dbShifts =
        await _shiftRepo.getShiftsForWeek(restaurantId, weekId);
    final openSnapshots =
        await _openShiftRepo.getOpenShiftsForWeek(restaurantId, weekId);

    // Build snapshot key set — these override projected shift_records rows
    final snapshotKeys = openSnapshots
        .map((s) => '${s.dayLabel}|${s.daypart}')
        .toSet();

    // Keep closed shift_records rows always; keep projected only if no snapshot
    final kept = dbShifts
        .where((s) =>
            s.isClosed || !snapshotKeys.contains('${s.dayLabel}|${s.daypart}'))
        .toList();

    // Convert open/projected snapshots to ShiftRecord shape
    final closedKeys = kept
        .where((s) => s.isClosed)
        .map((s) => '${s.dayLabel}|${s.daypart}')
        .toSet();
    // Load active profile once for snapshot conversion
    final profile = await _loadActiveProfile(restaurantId);
    final openAsRecords = openSnapshots
        .where((s) => !closedKeys.contains('${s.dayLabel}|${s.daypart}'))
        .map((s) => CurrentWeekState.shiftRecordFromSnapshot(s, profile))
        .toList();

    return [...kept, ...openAsRecords];
  }

  // ── Current week state ───────────────────────────────────────────────────

  Future<CurrentWeekState?> getCurrentWeekState(
      String weekId, String weekLabel) async {
    final weekData = await getWeekToDate(weekId, weekLabel);
    if (weekData == null) return null;
    final shifts = await getFullWeekShifts(weekId);
    return CurrentWeekState(weekData: weekData, fullWeekShifts: shifts);
  }

  // ── Reset to demo data ───────────────────────────────────────────────────

  Future<void> reseedDemo() async {
    await SqliteDatabase.instance.reseedDemo();
  }

  Future<void> clearAllData() async {
    await SqliteDatabase.instance.clearAllData();
  }
}
