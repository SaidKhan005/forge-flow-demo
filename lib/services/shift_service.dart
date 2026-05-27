// Phase 7.55m.1 note: ShiftService uses operational current-shift authority
// (OpenShiftSnapshotRepository) for business-date resolution, NOT the
// planning-anchor seam in BusinessDateAuthorityService. This separation is
// intentional — the planning anchor resolves from mock replay state and
// closed-shift history, while operational authority resolves from
// open/projected shift snapshots reflecting "what business day is it now."
//
// Phase 7.55n.4: locked WTD forecast accumulation now uses business-date
// comparison instead of ISO weekday-number ordering, so it stays honest
// regardless of the configured week-start day. The non-locked WTD path
// still uses weekId-based membership (not migrated).
//
// Phase 7.55n.4a: locked WTD closed-shift membership now loads by snapshot
// date span (getClosedShiftsInDateRange) instead of the compatibility weekId
// query, so actual closed-truth membership follows the configured week span.
// closedDayNumber now reflects position inside the configured week span,
// not fixed Mon–Sun numbering.
//
// Phase 7.55n.5: locked WTD closed-truth membership now consults
// ShiftBoundaryResolver for finalization authority. Under
// appLocalCutoffFallback, a same-business-date closed row is no longer
// treated as finalized — the current operational business date must be
// strictly later than the row's business date. Falls back to the existing
// closed-row behavior when timing config or operational business date is
// unavailable.

import '../domain/models/active_target_profile.dart';
import '../domain/models/closed_shift_input.dart';
import '../domain/models/open_shift_snapshot.dart';
import '../domain/models/restaurant_timing_config.dart';
import '../domain/models/weekly_plan_snapshot.dart';
import '../domain/models/shift_fact.dart';
import '../domain/models/target_profile_version.dart';
import '../domain/repositories/open_shift_snapshot_repository.dart';
import '../domain/repositories/restaurant_scope_repository.dart';
import '../domain/repositories/shift_record_repository.dart';
import '../domain/repositories/target_cycle_repository.dart';
import '../domain/repositories/target_profile_repository.dart';
import '../domain/repositories/week_record_repository.dart';
import '../domain/repositories/weekly_plan_snapshot_repository.dart';
import '../domain/services/locked_daypart_int_hours.dart';
import '../domain/services/shift_boundary_resolver.dart';
import '../domain/services/utc_metadata_timestamp.dart';
import '../state/app_runtime_invalidation_bus.dart';
import 'business_date_authority_service.dart';
import 'closed_truth_eligibility.dart';
import 'restaurant_timing_config_read_service.dart';
import 'schedule_plan_read_service.dart';
import 'weekly_plan_snapshot_service.dart';
import '../domain/services/shift_fact_builder.dart';
import '../domain/services/service_period_definition_resolver.dart';
import '../domain/services/target_snapshot_builder.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_open_shift_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_reservation_book_snapshot_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_restaurant_scope_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_cycle_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_target_profile_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_week_record_repository.dart';
import '../infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import '../models/current_week_state.dart';
import '../models/history_pattern_record.dart';
import '../models/shift_dashboard_read_model.dart';
import '../models/shift_record.dart';
import '../models/week_data.dart';
import '../models/week_record.dart';
import 'daypart_plan_allocator.dart';
import 'history_pattern_builder.dart';
import 'integration/shift_vendor_source_resolver.dart';
import 'labor_model.dart';
import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import '../domain/constants/app_defaults.dart'; // MeridianConfig for blended-wage zero-hour fallback only
import '../dev/mock_integration_replay_seed.dart';
import 'wage_standard_context_service.dart';

class ShiftService {
  ShiftService._();
  static final ShiftService instance = ShiftService._();

  final ShiftRecordRepository _shiftRepo = SqliteShiftRecordRepository.instance;
  final WeekRecordRepository _weekRepo = SqliteWeekRecordRepository.instance;
  final RestaurantScopeRepository _scopeRepo =
      SqliteRestaurantScopeRepository.instance;
  final TargetProfileRepository _profileRepo =
      SqliteTargetProfileRepository.instance;
  final OpenShiftSnapshotRepository _openShiftRepo =
      SqliteOpenShiftSnapshotRepository.instance;
  final WeeklyPlanSnapshotRepository _weeklyPlanSnapshotRepo =
      SqliteWeeklyPlanSnapshotRepository.instance;
  final TargetCycleRepository _targetCycleRepo =
      SqliteTargetCycleRepository.instance;

  Future<String> _activeRestaurantId() => _scopeRepo.getActiveRestaurantId();

  /// Loads the active target profile, bootstrapping with wage authority
  /// if no persisted profile exists.
  Future<ActiveTargetProfile> _loadActiveProfile(String restaurantId) async {
    return WageStandardContextService.instance.loadOrBootstrapProfile(
      restaurantId,
    );
  }

  // ── Week-to-date rollup from closed shift_records ────────────────────────────

  Future<WeekData?> getWeekToDate(String weekId, String weekLabel) async {
    final restaurantId = await _activeRestaurantId();
    final profile = await _loadActiveProfile(restaurantId);
    final shifts = await _shiftRepo.getShiftsForWeek(restaurantId, weekId);
    final closed = await _eligibleClosedTruthRows(
      restaurantId,
      shifts.where((s) => s.isClosed),
    );
    if (closed.isEmpty) return null;

    final totalCovers = closed.fold<int>(0, (s, r) => s + r.covers);
    final totalFoh = closed.fold<int>(0, (s, r) => s + r.fohHours);
    final totalBoh = closed.fold<int>(0, (s, r) => s + r.bohHours);
    final totalSales = closed.fold<double>(0, (s, r) => s + r.actualSales);
    final wtdForecastCovers = closed.fold<int>(
      0,
      (s, r) => s + r.forecastCovers,
    );
    final totalWeekForecastCovers = shifts.fold<int>(
      0,
      (s, r) => s + r.forecastCovers,
    );

    final totalFohLaborDollar = closed.fold<double>(
      0,
      (s, r) => s + r.fohLaborDollar,
    );
    final totalBohLaborDollar = closed.fold<double>(
      0,
      (s, r) => s + r.bohLaborDollar,
    );
    final blendedFohWage = totalFoh > 0
        ? totalFohLaborDollar / totalFoh
        : profile.fohWage;
    final blendedBohWage = totalBoh > 0
        ? totalBohLaborDollar / totalBoh
        : profile.bohWage;

    final avgPPA = totalCovers > 0 ? totalSales / totalCovers : 0.0;
    final avgCPLH = totalFoh > 0 ? totalCovers / totalFoh : 0.0;
    final avgSPLH = totalBoh > 0 ? totalSales / totalBoh : 0.0;

    final wtdModelFoh = LaborModel.modelFohHours(
      totalCovers,
      profile.targetCPLH,
    );
    final wtdModelBoh = LaborModel.modelBohHoursFromSales(
      totalSales,
      profile.targetSPLH,
    );

    // 7.58.0a / Finding F-2: week-level aggregate producer. On-model
    // weeks (no axis past threshold) yield the `on_model` sentinel
    // instead of the legacy `covers_down` overclaim; WeekRecord/WeekData
    // renderers already degrade a null `LeverCards.lookup` to "—" /
    // LeverCardNotYetAvailable. Per-shift facts stay on the contract-
    // pinned `determineLever` (7.61 catalog discipline).
    final primaryLeverId = LaborModel.determineLeverGated(
      actualCovers: totalCovers,
      forecastCovers: wtdForecastCovers,
      avgCPLH: avgCPLH,
      avgPPA: avgPPA,
      targetCPLH: profile.targetCPLH,
      targetPPA: profile.targetPPA,
      avgSPLH: avgSPLH,
      targetSPLH: profile.targetSPLH,
      avgFohBlendedWage: blendedFohWage,
      targetFohWage: profile.fohWage,
      avgBohBlendedWage: blendedBohWage,
      targetBohWage: profile.bohWage,
      scheduledFohHours: totalFoh,
      modelFohHours: wtdModelFoh,
      scheduledBohHours: totalBoh,
      modelBohHours: wtdModelBoh,
    );

    final lastDayLabel = closed
        .map((s) => s.dayLabel)
        .reduce(
          (a, b) =>
              (BusinessDateAuthorityService.dayNumber(a) ?? 0) >=
                  (BusinessDateAuthorityService.dayNumber(b) ?? 0)
              ? a
              : b,
        );
    final closedDayNum =
        BusinessDateAuthorityService.dayNumber(lastDayLabel) ?? 1;
    final lastClosedDay =
        BusinessDateAuthorityService.fullDayNames[closedDayNum] ?? 'Monday';

    // ── Dollar Impact accumulation (7.55p.3a) ─────────────────────────
    // Compat path: derive month and 60-day windows from closed business
    // dates when available, same contract as the locked path.
    final closedDates = closed
        .map((s) => s.businessDate)
        .whereType<String>()
        .toList();
    final maxClosedDate = closedDates.isNotEmpty
        ? closedDates.reduce((a, b) => a.compareTo(b) >= 0 ? a : b)
        : null;

    double? monthDollarImpact;
    double? sixtyDayDollarImpact;
    if (maxClosedDate != null) {
      final closedDt = _parseDate(maxClosedDate);
      final monthStartDate = _formatDate(
        DateTime.utc(closedDt.year, closedDt.month, 1),
      );
      final monthShifts = await _shiftRepo.getClosedShiftsInDateRange(
        restaurantId,
        monthStartDate,
        maxClosedDate,
      );
      monthDollarImpact = _accumulateDollarImpact(
        await _eligibleClosedTruthRows(restaurantId, monthShifts),
      );

      final sixtyDayStartDt = closedDt.subtract(const Duration(days: 59));
      final sixtyDayStartDate = _formatDate(sixtyDayStartDt);
      final sixtyDayShifts = await _shiftRepo.getClosedShiftsInDateRange(
        restaurantId,
        sixtyDayStartDate,
        maxClosedDate,
      );
      sixtyDayDollarImpact = _accumulateDollarImpact(
        await _eligibleClosedTruthRows(restaurantId, sixtyDayShifts),
      );
    }

    return WeekData(
      weekId: weekId,
      weekLabel: weekLabel,
      totalCovers: totalCovers,
      totalSales: totalSales,
      totalFohHours: totalFoh,
      totalBohHours: totalBoh,
      shiftsCompleted: closed.length,
      shiftsTotal: 14,
      wtdForecastCovers: wtdForecastCovers,
      totalWeekForecastCovers: totalWeekForecastCovers,
      primaryLeverId: primaryLeverId,
      lastClosedDay: lastClosedDay,
      closedDayNumber: closedDayNum,
      lastClosedBusinessDate: maxClosedDate,
      storedTotalFohLaborDollar: totalFohLaborDollar,
      storedTotalBohLaborDollar: totalBohLaborDollar,
      monthDollarImpact: monthDollarImpact,
      sixtyDayDollarImpact: sixtyDayDollarImpact,
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
    final closedShifts = await _shiftRepo.getClosedShiftsForWeeks(
      restaurantId,
      weekIds,
    );
    final operationalBusinessDate = await _openShiftRepo.getCurrentBusinessDate(
      restaurantId,
    );
    return HistoryPatternBuilder.fromClosedShifts(
      closedShifts,
      weekLabelsById,
      currentOperationalBusinessDate: operationalBusinessDate,
      shiftCloseAuthorityForRow: ClosedTruthEligibility.closeAuthorityForShift,
    );
  }

  // ── Historical closed shifts (for benchmark daypart evidence) ────────────────

  Future<List<ShiftRecord>> getHistoricalClosedShifts() async {
    final weeks = await getWeekHistory();
    if (weeks.isEmpty) return [];
    final weekIds = weeks.map((w) => w.weekId).toList();
    final restaurantId = await _activeRestaurantId();
    final shifts = await _shiftRepo.getClosedShiftsForWeeks(
      restaurantId,
      weekIds,
    );
    final operationalBusinessDate = await _openShiftRepo.getCurrentBusinessDate(
      restaurantId,
    );
    return ClosedTruthEligibility.filter(
      shifts,
      currentOperationalBusinessDate: operationalBusinessDate,
    );
  }

  Future<List<ShiftRecord>> _eligibleClosedTruthRows(
    String restaurantId,
    Iterable<ShiftRecord> shifts, {
    String? currentOperationalBusinessDate,
  }) async {
    final operationalBusinessDate =
        currentOperationalBusinessDate ??
        await _openShiftRepo.getCurrentBusinessDate(restaurantId);
    return ClosedTruthEligibility.filter(
      shifts,
      currentOperationalBusinessDate: operationalBusinessDate,
    );
  }

  // ── Close a shift ─────────────────────────────────────────────────────────────

  Future<ShiftRecord> closeShift(ClosedShiftInput input) async {
    // 1. Load active target profile
    final profile = await _loadActiveProfile(input.restaurantId);

    // 2. Create or reuse the immutable target profile version.
    //
    // Server-truth active profiles already carry the canonical version id.
    // Reuse that id so mobile/local close paths lock the same identity the
    // server path would use. Only mint a local compatibility version when the
    // active profile has no version id yet.
    final now = nowIsoUtc();
    final activeVersionId = profile.targetProfileVersionId?.trim();
    final versionId = (activeVersionId != null && activeVersionId.isNotEmpty)
        ? activeVersionId
        : 'tpv_${now.replaceAll(RegExp(r'[^0-9]'), '')}_${input.weekId}_${input.dayLabel}_${input.daypart}';
    if (activeVersionId == null || activeVersionId.isEmpty) {
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
    }

    // 3. Build locked target snapshot from the active profile + version.
    //
    // Per-Daypart V1 (Slice 1): pass the shift's service period id so
    // the snapshot's `daypart*` fields can be populated from the
    // profile's per-period row when one exists. Prefer the explicit
    // `servicePeriodKey` (V1 canonical) and fall back to `daypart`
    // (legacy alias that still carries the same identifier in
    // ClosedShiftInput).
    final targetSnapshot = TargetSnapshotBuilder.fromActiveTargetProfile(
      profile,
      targetProfileVersionId: versionId,
      servicePeriodId: input.servicePeriodKey ?? input.daypart,
    );

    // 4. Build normalized shift fact
    final shiftFact = ShiftFactBuilder.fromClosedShiftInput(
      input,
      targetSnapshot,
    );

    // 5. Convert to ShiftRecord with locked target fields
    final record = _shiftRecordFromFact(shiftFact);

    // 6. Atomically replace any existing slot row
    await _shiftRepo.replaceShiftForSlot(record);

    // 7. Re-read all shifts for the week
    final allShifts = await _shiftRepo.getShiftsForWeek(
      input.restaurantId,
      input.weekId,
    );
    final closedShifts = await _eligibleClosedTruthRows(
      input.restaurantId,
      allShifts.where((s) => s.isClosed),
    );

    // 8. Upsert WeekRecord only when the week is fully closed.
    //
    // Per-Daypart V1 Slice 1.5 (Gap 24): the legacy gate hardcoded
    // `closedShifts.length == 14` (2 dayparts × 7 days). That gate
    // never fires for 3-period (21) / 4-period (28) configurations,
    // nor for weekend-only periods that have fewer rows. The new gate
    // reads the operator's configured `service_period_definitions`
    // count from `restaurant_timing_configs` and gates on
    // `period_count × 7`. When the operator hasn't persisted a timing
    // config yet, falls back to the legacy 14-row gate (honest
    // degradation — same behavior as pre-1.5 callers).
    final expectedClosedShifts = await _expectedClosedShiftsPerWeek(
      input.restaurantId,
    );
    if (closedShifts.length == expectedClosedShifts) {
      final weekRecord = await _buildWeekRecord(
        input.restaurantId,
        input.weekId,
        closedShifts,
      );
      await _weekRepo.upsertWeekRecord(weekRecord);
    }

    // 9. Signal current-state invalidation (7.55p.4b + 7.55n.11)
    AppRuntimeInvalidationBus.instance.notifyRuntimeWriteCompleted();

    return record;
  }

  /// Per-Daypart V1 Slice 1.5 (Gap 24) — expected closed-shift count
  /// per week. Reads the operator's configured service-period set
  /// from `RestaurantTimingConfig` and sums each period's
  /// `applicableDays.length` so weekend-only periods (e.g. Brunch
  /// Sat/Sun, the demo's Fri/Sat late-night) don't inflate the gate.
  /// When timing config is unavailable, falls back to the legacy
  /// 14-shift gate (2 dayparts × 7 days) so pre-7.55n.1 demo DBs
  /// continue to roll up week records the same way they did before.
  ///
  /// Legacy gate behavior: `closedShifts.length == 14` (hardcoded).
  /// New gate: sum of applicable-days-per-period across the week.
  Future<int> _expectedClosedShiftsPerWeek(String restaurantId) async {
    final timingConfig = await RestaurantTimingConfigReadService.instance
        .getTimingConfig(restaurantId);
    if (timingConfig == null || timingConfig.servicePeriodDefinitions.isEmpty) {
      return 14;
    }
    var total = 0;
    for (final period in timingConfig.servicePeriodDefinitions) {
      total += period.applicableDays.length;
    }
    return total;
  }

  // ── Private: convert ShiftFact → ShiftRecord ─────────────────────────────────
  //
  // Per-Daypart V1 (Slice 1, Gap 23 fix): previously this conversion
  // dropped `businessTimingProfileId` / `businessTimingProfileVersionId`
  // / `servicePeriodKey` even though `ShiftFact` (and its underlying
  // `ClosedShiftInput`) already carry them. The Postgres path
  // (`PostgresShiftRecordWriter`) preserves them; the SQLite-direct
  // mobile close-shift path silently stripped them. Now both paths
  // carry timing fields uniformly.
  //
  // Per-Daypart V1 (Slice 1) addition: per-period locked target stamps
  // (`daypartTarget*`) are also carried through to ShiftRecord. The
  // TargetSnapshot now resolves these from the cycle's per-period rows
  // (when present) so each closed shift gets its period's locked target
  // band stamped at close time. Promise 2: closed truth retains its
  // stamp. When the cycle has no per-period row for the shift's period
  // (Gap 42 fallback), the targetSnapshot's daypart fields are null and
  // the ShiftRecord retains null in those columns — consumers fall back
  // to the whole-day `targetCPLH` etc. on the same row.

  ShiftRecord _shiftRecordFromFact(ShiftFact fact) {
    final ts = fact.targetSnapshot;
    final bd = fact.businessDate;
    final businessDateStr =
        '${bd.year}-${bd.month.toString().padLeft(2, '0')}-${bd.day.toString().padLeft(2, '0')}';
    return ShiftRecord(
      restaurantId: fact.restaurantId,
      status: 'closed',
      weekId: fact.weekId,
      dayLabel: fact.dayLabel,
      daypart: fact.daypart,
      businessDate: businessDateStr,
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
      // Per-Daypart V1 (Slice 1, Gap 23): carry timing-provenance fields
      // from ShiftFact through to ShiftRecord. Mirrors the Postgres
      // writer behavior at `postgres_shift_record_writer.dart:214-216`.
      businessTimingProfileId: fact.businessTimingProfileId,
      businessTimingProfileVersionId: fact.businessTimingProfileVersionId,
      servicePeriodKey: fact.servicePeriodKey,
      // Per-Daypart V1 (Slice 1): per-period locked target stamps from
      // the TargetSnapshot. Nullable — when the cycle wrote no per-period
      // row for the shift's period (Gap 42 fallback) these stay null
      // and consumers fall back to the whole-day target* fields above.
      daypartTargetCPLH: ts.daypartTargetCPLH,
      daypartTargetSPLH: ts.daypartTargetSPLH,
      daypartTargetPPA: ts.daypartTargetPPA,
      daypartOpzFloorCPLH: ts.daypartOpzFloorCPLH,
      daypartOpzCeilingCPLH: ts.daypartOpzCeilingCPLH,
      sourceSystem: fact.sourceSystem,
      sourceShiftId: fact.sourceShiftId,
    );
  }

  // ── Private: build WeekRecord from 14 closed shifts ──────────────────────────
  // Materializes week-level locked targets from the closed shifts' locked targets.
  //
  // Phase 7.55q.5: also preserves the locked plan FOH/BOH hours from the
  // WeeklyPlanSnapshot in force for the week's business-date span. The
  // lookup is read-only (never auto-generates a snapshot); when no
  // snapshot is persisted for the anchor date, the locked-plan-hour
  // fields are left null and Week Detail renders "—" honestly rather
  // than re-modeling from actuals.

  Future<WeekRecord> _buildWeekRecord(
    String restaurantId,
    String weekId,
    List<ShiftRecord> closedShifts,
  ) async {
    final totalCovers = closedShifts.fold<int>(0, (s, r) => s + r.covers);
    final forecastCovers = closedShifts.fold<int>(
      0,
      (s, r) => s + r.forecastCovers,
    );
    final totalFohHours = closedShifts.fold<int>(0, (s, r) => s + r.fohHours);
    final totalBohHours = closedShifts.fold<int>(0, (s, r) => s + r.bohHours);
    final totalSales = closedShifts.fold<double>(
      0,
      (s, r) => s + r.actualSales,
    );
    final totalFohLaborDollar = closedShifts.fold<double>(
      0,
      (s, r) => s + r.fohLaborDollar,
    );
    final totalBohLaborDollar = closedShifts.fold<double>(
      0,
      (s, r) => s + r.bohLaborDollar,
    );
    final totalLaborDollar = totalFohLaborDollar + totalBohLaborDollar;

    final avgPPA = totalCovers > 0 ? totalSales / totalCovers : 0.0;
    final avgCPLH = totalFohHours > 0 ? totalCovers / totalFohHours : 0.0;

    // Zero-hour fallback uses the locked target wages from the shifts
    // instead of MeridianConfig, preserving closed-truth provenance.
    final fallbackFohWage =
        closedShifts.first.targetFohWage ?? MeridianConfig.fohWage;
    final fallbackBohWage =
        closedShifts.first.targetBohWage ?? MeridianConfig.bohWage;
    final blendedFohWage = totalFohHours > 0
        ? totalFohLaborDollar / totalFohHours
        : fallbackFohWage;
    final blendedBohWage = totalBohHours > 0
        ? totalBohLaborDollar / totalBohHours
        : fallbackBohWage;

    final actualLaborPct = totalSales > 0
        ? totalLaborDollar / totalSales * 100
        : 0.0;

    // ── Materialize week-level locked targets from shift locked targets ────
    double weightedAvg(
      double Function(ShiftRecord) field,
      double Function(ShiftRecord) weight,
    ) {
      final totalW = closedShifts.fold<double>(0, (s, r) => s + weight(r));
      if (totalW == 0) {
        return closedShifts.fold<double>(0, (s, r) => s + field(r)) /
            closedShifts.length;
      }
      return closedShifts.fold<double>(0, (s, r) => s + field(r) * weight(r)) /
          totalW;
    }

    double requireShiftField(ShiftRecord r, double? value, String name) {
      if (value == null) {
        throw StateError(
          'ShiftRecord ${r.weekId}/${r.dayLabel}/${r.daypart} has null $name '
          '— locked target field must be backfilled before week rollup.',
        );
      }
      return value;
    }

    final wkTargetCPLH = weightedAvg(
      (r) => requireShiftField(r, r.targetCPLH, 'targetCPLH'),
      (r) => r.covers.toDouble(),
    );
    final wkTargetSPLH = weightedAvg(
      (r) => requireShiftField(r, r.targetSPLH, 'targetSPLH'),
      (r) => r.actualSales,
    );
    final wkTargetPPA = weightedAvg(
      (r) => requireShiftField(r, r.targetPPA, 'targetPPA'),
      (r) => r.covers.toDouble(),
    );
    final wkTargetFohWage = weightedAvg(
      (r) => requireShiftField(r, r.targetFohWage, 'targetFohWage'),
      (r) => r.fohHours.toDouble(),
    );
    final wkTargetBohWage = weightedAvg(
      (r) => requireShiftField(r, r.targetBohWage, 'targetBohWage'),
      (r) => r.bohHours.toDouble(),
    );
    final wkTheoFohPct = weightedAvg(
      (r) => requireShiftField(
        r,
        r.theoreticalFohLaborPct,
        'theoreticalFohLaborPct',
      ),
      (r) => r.actualSales,
    );
    final wkTheoBohPct = weightedAvg(
      (r) => requireShiftField(
        r,
        r.theoreticalBohLaborPct,
        'theoreticalBohLaborPct',
      ),
      (r) => r.actualSales,
    );
    final wkTheoTotalPct = weightedAvg(
      (r) => r.theoreticalLaborPct,
      (r) => r.actualSales,
    );

    // Dollar gap from locked shift truth
    final summedTheoreticalLaborDollar = closedShifts.fold<double>(
      0,
      (s, r) => s + (r.actualSales * r.theoreticalLaborPct / 100),
    );
    final dollarGap = totalLaborDollar - summedTheoreticalLaborDollar;

    // Primary lever from locked targets
    final wkModelFoh = LaborModel.modelFohHours(totalCovers, wkTargetCPLH);
    final wkModelBoh = LaborModel.modelBohHoursFromSales(
      totalSales,
      wkTargetSPLH,
    );

    // 7.58.0a / Finding F-2: week-level aggregate producer. On-model
    // weeks (no axis past threshold) yield the `on_model` sentinel
    // instead of the legacy `covers_down` overclaim; WeekRecord/WeekData
    // renderers already degrade a null `LeverCards.lookup` to "—" /
    // LeverCardNotYetAvailable. Per-shift facts stay on the contract-
    // pinned `determineLever` (7.61 catalog discipline).
    final primaryLeverId = LaborModel.determineLeverGated(
      actualCovers: totalCovers,
      forecastCovers: forecastCovers,
      avgCPLH: avgCPLH,
      avgPPA: avgPPA,
      targetCPLH: wkTargetCPLH,
      targetPPA: wkTargetPPA,
      avgSPLH: totalBohHours > 0 ? totalSales / totalBohHours : 0,
      targetSPLH: wkTargetSPLH,
      avgFohBlendedWage: blendedFohWage,
      targetFohWage: wkTargetFohWage,
      avgBohBlendedWage: blendedBohWage,
      targetBohWage: wkTargetBohWage,
      scheduledFohHours: totalFohHours,
      modelFohHours: wkModelFoh,
      scheduledBohHours: totalBohHours,
      modelBohHours: wkModelBoh,
    );

    // Source type: use the first shift's source type as representative
    final sourceType = closedShifts.first.targetSourceType;

    // ── Preserved locked plan hours (7.55q.5) ────────────────────────
    // Look up the locked WeeklyPlanSnapshot in force for this week's
    // business-date span via the first closed shift's businessDate.
    // Read-only — never auto-generates a new snapshot. Missing
    // snapshot or missing anchor date leaves the locked-plan-hour
    // fields null (honest legacy degradation; Week Detail renders
    // "—" for those rows instead of re-modeling from actuals).
    int? lockedRequiredFohHours;
    int? lockedRequiredBohHours;
    String? targetCalibrationWindowStart;
    String? targetCalibrationWindowEnd;
    final anchorBusinessDate = _anchorBusinessDate(closedShifts);
    if (anchorBusinessDate != null) {
      final snapshot = await _weeklyPlanSnapshotRepo.getSnapshotForBusinessDate(
        restaurantId,
        anchorBusinessDate,
      );
      if (snapshot != null) {
        lockedRequiredFohHours = snapshot.requiredFohHours;
        lockedRequiredBohHours = snapshot.requiredBohHours;
        final cycle = await _targetCycleRepo.getCycleById(
          snapshot.targetCycleId,
        );
        if (cycle != null) {
          targetCalibrationWindowStart = cycle.calibrationWindowStart;
          targetCalibrationWindowEnd = cycle.calibrationWindowEnd;
        }
      }
    }

    // ── Frozen Dollar Impact windows (7.55q.10) ──────────────────────
    // Capture month + 60-day impact at close from the same closed-truth
    // date-range queries the live Variance card was reading. Locks the
    // 4-row Dollar Impact view at the close moment — Week Detail then
    // shows the same numbers that were on screen the instant the 14th
    // shift closed. Reuses _accumulateDollarImpact for parity with the
    // current-week WTD path.
    //
    // Honest legacy: if no shift has a businessDate, the windows + the
    // closedAt timestamp stay null and the Week Detail UI falls back to
    // its existing 2-row + boilerplate-footer view. Inherited debt:
    // "14 shifts" close-detection one layer above is unowned debt
    // (PROJECT_TRACKER line 90; phase_7_55_time_boundary_contract Rule 9).
    double? monthDollarImpact;
    double? sixtyDayDollarImpact;
    String? closedAt;
    final maxClosedDate = closedShifts
        .map((s) => s.businessDate)
        .whereType<String>()
        .fold<String?>(
          null,
          (max, d) => max == null || d.compareTo(max) > 0 ? d : max,
        );
    if (maxClosedDate != null) {
      closedAt = maxClosedDate;
      final closedDt = _parseDate(maxClosedDate);
      final monthStart = _formatDate(
        DateTime.utc(closedDt.year, closedDt.month, 1),
      );
      final monthShifts = await _shiftRepo.getClosedShiftsInDateRange(
        restaurantId,
        monthStart,
        maxClosedDate,
      );
      monthDollarImpact = _accumulateDollarImpact(
        await _eligibleClosedTruthRows(restaurantId, monthShifts),
      );
      final sixtyDayStart = _formatDate(
        closedDt.subtract(const Duration(days: 59)),
      );
      final sixtyDayShifts = await _shiftRepo.getClosedShiftsInDateRange(
        restaurantId,
        sixtyDayStart,
        maxClosedDate,
      );
      sixtyDayDollarImpact = _accumulateDollarImpact(
        await _eligibleClosedTruthRows(restaurantId, sixtyDayShifts),
      );
    }

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
      lockedRequiredFohHours: lockedRequiredFohHours,
      lockedRequiredBohHours: lockedRequiredBohHours,
      monthDollarImpact: monthDollarImpact,
      sixtyDayDollarImpact: sixtyDayDollarImpact,
      closedAt: closedAt,
      targetCalibrationWindowStart: targetCalibrationWindowStart,
      targetCalibrationWindowEnd: targetCalibrationWindowEnd,
    );
  }

  /// Returns the first non-null `businessDate` from [closedShifts], or
  /// null when every shift is missing a business-date anchor.
  static String? _anchorBusinessDate(List<ShiftRecord> closedShifts) {
    for (final s in closedShifts) {
      final bd = s.businessDate;
      if (bd != null) return bd;
    }
    return null;
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
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
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
  ///
  /// Uses the locked [WeeklyPlanSnapshot] for the Plan-owned weekly
  /// forecast truth (forecast covers, plan hours WTD).
  ///
  /// 7.55q.4: the Benchmark-owned target standards (CPLH/SPLH/PPA/wages
  /// /theoretical %) are read from the CURRENT [ActiveTargetProfile] in
  /// `_buildLockedWeekToDate` — not from the snapshot's cycle. This is
  /// the conformance-Rule-3 fix: non-closed Variance rows must read
  /// shared objects 1:1, and the snapshot's cycle can lag behind the
  /// current Benchmark target.
  ///
  /// Uses the weekly-snapshot pipeline for current-week WTD truth.
  ///
  /// The current-week snapshot may still be auto-generated by
  /// [WeeklyPlanSnapshotService.getCurrentWeekSnapshot] when the week
  /// first comes into force, which is still within the single locked-plan
  /// authority path. What this method must NOT do is silently fall back to
  /// the historical live/model WTD path when locked weekly truth is
  /// unavailable.
  Future<WeekData?> getLiveWeekToDate() async {
    final weekId = await getCurrentWeekId();
    if (weekId == null) return null;
    final weekLabel = _weekLabelFromWeekId(weekId);

    // Try locked weekly snapshot for current-week Plan-owned truth.
    final snapshot = await WeeklyPlanSnapshotService.instance
        .getCurrentWeekSnapshot();
    if (snapshot != null) {
      return _buildLockedWeekToDate(weekId, weekLabel, snapshot);
    }

    // No locked weekly snapshot could be resolved/generated.
    // Degrade honestly instead of falling back to the historical
    // live/model target path, which would create a competing target layer.
    return null;
  }

  /// Builds current-week WTD from the locked snapshot (Plan-owned
  /// fields) and the current [ActiveTargetProfile] (Benchmark-owned
  /// fields).
  ///
  /// Closed-shift membership uses the snapshot date span
  /// ([getClosedShiftsInDateRange]) instead of the compatibility weekId
  /// query, so actuals follow the configured week span (7.55n.4a).
  ///
  /// Phase 7.55n.5: closed rows are now filtered through
  /// [ShiftBoundaryResolver.isEligibleForClosedTruth] using the
  /// restaurant's configured [ShiftCloseAuthority] and the current
  /// operational business date. Under [appLocalCutoffFallback],
  /// same-business-date closed rows are excluded from finalized truth.
  /// Falls back to the existing closed-row behavior when timing config
  /// or operational business date is unavailable.
  ///
  /// 7.55q.4: Plan-owned fields (forecast covers, plan hours WTD) come
  /// from the locked snapshot day rows. Benchmark-owned target fields
  /// (CPLH/SPLH/PPA/wages/theoretical %) come from the CURRENT
  /// [ActiveTargetProfile] — NOT from the snapshot's cycle. This is
  /// Rule 3 conformance: non-closed Variance rows read shared objects
  /// 1:1 with the active Benchmark. Closed-truth actuals are aggregated
  /// from `ShiftRecord.lockedTarget*` fields elsewhere
  /// (`_ClosedShiftDetail`), so the Rule 4 closed exception is preserved.
  Future<WeekData?> _buildLockedWeekToDate(
    String weekId,
    String weekLabel,
    WeeklyPlanSnapshot snapshot,
  ) async {
    final restaurantId = await _activeRestaurantId();
    // 7.55q.4: read CURRENT Benchmark target object, not snapshot.cycle.
    final profile = await _loadActiveProfile(restaurantId);

    // ── Load closed shifts by snapshot date span (7.55n.4a) ──────────
    // Uses business-date-range query instead of the compatibility weekId
    // query so actual closed-truth membership follows the configured
    // week span, not the ISO/Monday-based weekId bucket.
    final allClosed = await _shiftRepo.getClosedShiftsInDateRange(
      restaurantId,
      snapshot.weekStartDate,
      snapshot.weekEndDate,
    );
    if (allClosed.isEmpty) return null;

    // ── Finalization filter (7.55n.5) ────────────────────────────────
    //
    // Per-Daypart V1 Slice 1.5: the row-level close authority is now
    // auto-derived per shift from the POS vendor's
    // `CloseAuthorityCapability` (see
    // `lib/services/integration/close_authority_capability.dart`).
    // When the row's `sourceSystem` POS vendor exposes a reliable
    // finalization signal, the row is finalized as soon as
    // `status == 'closed'`. Otherwise the operator's business-day-start
    // is the fallback close moment — the row is finalized only when
    // the current operational business date is strictly later than
    // the row's business date. When the operational business date is
    // unknown, all closed rows pass through (honest legacy degradation
    // matching pre-1.5 behavior).
    final operationalBusinessDate = await _openShiftRepo.getCurrentBusinessDate(
      restaurantId,
    );

    final List<ShiftRecord> closed;
    if (operationalBusinessDate != null) {
      closed = allClosed
          .where(
            (s) => ShiftBoundaryResolver.isEligibleForClosedTruth(
              rowStatus: s.status,
              shiftCloseAuthority:
                  ClosedTruthEligibility.closeAuthorityForShift(s),
              rowBusinessDate: s.businessDate,
              currentOperationalBusinessDate: operationalBusinessDate,
            ),
          )
          .toList();
      if (closed.isEmpty) return null;
    } else {
      // Compatibility fallback: no operational business date — use all
      // closed rows as before (7.55n.5 doc documents this honestly).
      closed = allClosed;
    }

    // ── Closed-day position inside configured week span (7.55n.4a) ───
    // Derive closedDayNumber from the latest closed business date's
    // position inside the snapshot week span instead of ISO weekday
    // numbering. For Sunday-start, the first closed Sunday reads as
    // Day 1, not Day 7.
    final closedDates = closed
        .map((s) => s.businessDate)
        .whereType<String>()
        .toList();
    final maxClosedDate = closedDates.isNotEmpty
        ? closedDates.reduce((a, b) => a.compareTo(b) >= 0 ? a : b)
        : null;

    final int closedDayNum;
    final String lastClosedDay;
    if (maxClosedDate != null) {
      final weekStartDt = _parseDate(snapshot.weekStartDate);
      final closedDt = _parseDate(maxClosedDate);
      closedDayNum = closedDt.difference(weekStartDt).inDays + 1;
      // Derive human-readable name from the closed date's ISO weekday.
      final isoWeekday = closedDt.weekday; // 1=Mon, 7=Sun
      lastClosedDay =
          BusinessDateAuthorityService.fullDayNames[isoWeekday] ?? 'Monday';
    } else {
      // Fallback: no business dates available — use canonical day ordering.
      final lastDayLabel = closed
          .map((s) => s.dayLabel)
          .reduce(
            (a, b) =>
                (BusinessDateAuthorityService.dayNumber(a) ?? 0) >=
                    (BusinessDateAuthorityService.dayNumber(b) ?? 0)
                ? a
                : b,
          );
      closedDayNum = BusinessDateAuthorityService.dayNumber(lastDayLabel) ?? 1;
      lastClosedDay =
          BusinessDateAuthorityService.fullDayNames[closedDayNum] ?? 'Monday';
    }

    // ── Actual aggregation (unchanged from getWeekToDate) ─────────────
    final totalCovers = closed.fold<int>(0, (s, r) => s + r.covers);
    final totalFoh = closed.fold<int>(0, (s, r) => s + r.fohHours);
    final totalBoh = closed.fold<int>(0, (s, r) => s + r.bohHours);
    final totalSales = closed.fold<double>(0, (s, r) => s + r.actualSales);

    // ── Locked WTD forecast from snapshot day rows ────────────────────
    // Sum snapshot day-row forecast covers through the last closed
    // business date. Uses business-date comparison (7.55n.4).
    // Filter snapshot day rows through the last closed business date.
    final closedDayRows = maxClosedDate != null
        ? snapshot.dayRows
              .where(
                (d) =>
                    d.businessDate.compareTo(snapshot.weekStartDate) >= 0 &&
                    d.businessDate.compareTo(maxClosedDate) <= 0,
              )
              .toList()
        : snapshot.dayRows
              .where(
                (d) =>
                    (BusinessDateAuthorityService.dayNumber(d.day) ?? 0) <=
                    closedDayNum,
              )
              .toList();

    final wtdForecastCovers = closedDayRows.fold<int>(
      0,
      (s, d) => s + d.forecastCovers,
    );
    final wtdForecastSales = closedDayRows.fold<double>(
      0,
      (s, d) => s + d.forecastSales,
    );

    // ── Locked WTD plan hours from snapshot day rows ─────────────────
    final planFohHoursWtd = closedDayRows.fold<int>(
      0,
      (s, d) => s + d.requiredFohHours,
    );
    final planBohHoursWtd = closedDayRows.fold<int>(
      0,
      (s, d) => s + d.requiredBohHours,
    );

    final totalFohLaborDollar = closed.fold<double>(
      0,
      (s, r) => s + r.fohLaborDollar,
    );
    final totalBohLaborDollar = closed.fold<double>(
      0,
      (s, r) => s + r.bohLaborDollar,
    );
    final blendedFohWage = totalFoh > 0
        ? totalFohLaborDollar / totalFoh
        : profile.fohWage;
    final blendedBohWage = totalBoh > 0
        ? totalBohLaborDollar / totalBoh
        : profile.bohWage;

    final avgPPA = totalCovers > 0 ? totalSales / totalCovers : 0.0;
    final avgCPLH = totalFoh > 0 ? totalCovers / totalFoh : 0.0;
    final avgSPLH = totalBoh > 0 ? totalSales / totalBoh : 0.0;

    final wtdModelFoh = LaborModel.modelFohHours(
      totalCovers,
      profile.targetCPLH,
    );
    final wtdModelBoh = LaborModel.modelBohHoursFromSales(
      totalSales,
      profile.targetSPLH,
    );

    // 7.58.0a / Finding F-2: week-level aggregate producer. On-model
    // weeks (no axis past threshold) yield the `on_model` sentinel
    // instead of the legacy `covers_down` overclaim; WeekRecord/WeekData
    // renderers already degrade a null `LeverCards.lookup` to "—" /
    // LeverCardNotYetAvailable. Per-shift facts stay on the contract-
    // pinned `determineLever` (7.61 catalog discipline).
    final primaryLeverId = LaborModel.determineLeverGated(
      actualCovers: totalCovers,
      forecastCovers: wtdForecastCovers,
      avgCPLH: avgCPLH,
      avgPPA: avgPPA,
      targetCPLH: profile.targetCPLH,
      targetPPA: profile.targetPPA,
      avgSPLH: avgSPLH,
      targetSPLH: profile.targetSPLH,
      avgFohBlendedWage: blendedFohWage,
      targetFohWage: profile.fohWage,
      avgBohBlendedWage: blendedBohWage,
      targetBohWage: profile.bohWage,
      scheduledFohHours: totalFoh,
      modelFohHours: wtdModelFoh,
      scheduledBohHours: totalBoh,
      modelBohHours: wtdModelBoh,
    );

    // ── Multi-window dollar impact accumulation (7.55p.3) ──────────
    // Month: first of current calendar month through latest closed date.
    // 60-day: rolling window ending at latest closed date.
    // Uses per-shift locked targets so cross-cycle windows stay honest.
    double? monthDollarImpact;
    double? sixtyDayDollarImpact;
    if (maxClosedDate != null) {
      final closedDt = _parseDate(maxClosedDate);
      final monthStartDate = _formatDate(
        DateTime.utc(closedDt.year, closedDt.month, 1),
      );
      final monthShifts = await _shiftRepo.getClosedShiftsInDateRange(
        restaurantId,
        monthStartDate,
        maxClosedDate,
      );
      monthDollarImpact = _accumulateDollarImpact(monthShifts);

      final sixtyDayStartDt = closedDt.subtract(const Duration(days: 59));
      final sixtyDayStartDate = _formatDate(sixtyDayStartDt);
      final sixtyDayShifts = await _shiftRepo.getClosedShiftsInDateRange(
        restaurantId,
        sixtyDayStartDate,
        maxClosedDate,
      );
      sixtyDayDollarImpact = _accumulateDollarImpact(sixtyDayShifts);
    }

    // ── Locked forecast from snapshot; targets from cycle ─────────────
    return WeekData(
      weekId: weekId,
      weekLabel: weekLabel,
      totalCovers: totalCovers,
      totalSales: totalSales,
      totalFohHours: totalFoh,
      totalBohHours: totalBoh,
      shiftsCompleted: closed.length,
      shiftsTotal: 14,
      wtdForecastCovers: wtdForecastCovers,
      totalWeekForecastCovers: snapshot.forecastCovers,
      wtdForecastSales: wtdForecastSales,
      totalWeekForecastSales: snapshot.forecastSales,
      primaryLeverId: primaryLeverId,
      lastClosedDay: lastClosedDay,
      closedDayNumber: closedDayNum,
      lastClosedBusinessDate: maxClosedDate,
      storedTotalFohLaborDollar: totalFohLaborDollar,
      storedTotalBohLaborDollar: totalBohLaborDollar,
      planFohHoursWtd: planFohHoursWtd,
      planBohHoursWtd: planBohHoursWtd,
      monthDollarImpact: monthDollarImpact,
      sixtyDayDollarImpact: sixtyDayDollarImpact,
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

  // ── Shift dashboard read model ────────────────────────────────────────────

  /// Builds the whole-day Shift dashboard from SchedulePlan + aggregated
  /// snapshots. Returns null when no open shift or no plan is available.
  Future<ShiftDashboardReadModel?> getShiftDashboard() async {
    final restaurantId = await _activeRestaurantId();
    final profile = await _loadActiveProfile(restaurantId);

    // Find the business date with an open shift
    final businessDate = await _openShiftRepo.getCurrentBusinessDate(
      restaurantId,
    );
    if (businessDate == null) return null;

    // Load ALL daypart snapshots for this business day
    final snapshots = await _openShiftRepo.getSnapshotsForDay(
      restaurantId,
      businessDate,
    );
    if (snapshots.isEmpty) return null;

    // Resolve plan from the persisted locked weekly snapshot only.
    // If the snapshot is missing, degrade honestly instead of
    // silently swapping in the live plan.
    final plan = await SchedulePlanReadService.instance
        .getExistingCurrentLockedWeeklyPlan();

    // Pick the day row matching the open shift
    final openSnap =
        snapshots.where((s) => s.status == 'open').firstOrNull ??
        snapshots.first;
    final dayPlan = plan?.dayPlans
        .where((d) => d.day == openSnap.dayLabel)
        .firstOrNull;
    if (dayPlan == null) return null;

    // Aggregate reservation unseated covers for the whole day
    final resSnapshots = await SqliteReservationBookSnapshotRepository.instance
        .getForDay(restaurantId, businessDate);
    final totalUnseated = resSnapshots.fold<int>(
      0,
      (s, r) => s + r.unseatedCovers,
    );

    // Per-location vendor provenance (Defect 1): same fixture-derived
    // resolver as the notifier path, so every Shift surface tells the
    // same per-(operator, location, category) story. Caller-only — the
    // read-model gate bodies are untouched.
    final vendorSource = ShiftVendorSourceResolver.forLocation(restaurantId);
    return ShiftDashboardReadModel.buildWholeDay(
      snapshots: snapshots,
      profile: profile,
      forecastCovers: dayPlan.forecastCovers,
      forecastSales: dayPlan.forecastSales,
      planFohHours: dayPlan.requiredFohHours,
      planBohHours: dayPlan.requiredBohHours,
      inTheBooksCovers: totalUnseated > 0 ? totalUnseated : null,
      posSourceVendorId: vendorSource.posSourceVendorId,
      laborSourceVendorId: vendorSource.laborSourceVendorId,
    );
  }

  // ── Full-week shifts for Variance Full Week ──────────────────────────────

  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async {
    final restaurantId = await _activeRestaurantId();
    final dbShifts = await _shiftRepo.getShiftsForWeek(restaurantId, weekId);
    final openSnapshots = await _openShiftRepo.getOpenShiftsForWeek(
      restaurantId,
      weekId,
    );
    final operationalBusinessDate = await _openShiftRepo.getCurrentBusinessDate(
      restaurantId,
    );
    final eligibleClosed = await _eligibleClosedTruthRows(
      restaurantId,
      dbShifts.where((s) => s.isClosed),
      currentOperationalBusinessDate: operationalBusinessDate,
    );
    final eligibleClosedKeys = eligibleClosed
        .map((s) => '${s.dayLabel}|${s.daypart}')
        .toSet();

    // Build snapshot key set — these override projected shift_records rows
    final snapshotKeys = openSnapshots
        .map((s) => '${s.dayLabel}|${s.daypart}')
        .toSet();

    // Keep closed shift_records rows always; keep projected only if no snapshot
    final kept = dbShifts
        .where(
          (s) =>
              eligibleClosedKeys.contains('${s.dayLabel}|${s.daypart}') ||
              (!s.isClosed &&
                  !snapshotKeys.contains('${s.dayLabel}|${s.daypart}')),
        )
        .toList();

    // Convert open/projected snapshots to ShiftRecord shape.
    // 7.55q.4: non-closed Full Week rows now read Benchmark-owned target
    // fields from the CURRENT active profile, not from the snapshot-linked
    // cycle projection.
    //
    // 7.56c.0: when [weekId] matches the current operational week, also
    // load the locked weekly snapshot + active timing config + closed-history
    // distribution weights so non-closed rows can reuse the same shared
    // daypart plan-target allocation Schedule renders. Plan-owned values
    // (forecast covers, forecast sales, required FOH/BOH hours) come from
    // that allocation when available; the Benchmark-owned PPA / wages /
    // theoretical % still come from [profile]. When the locked snapshot is
    // unavailable (no current-week snapshot persisted, non-current weekId,
    // etc.) the overrides are skipped and snapshot values pass through
    // unchanged (honest legacy degradation).
    final closedKeys = kept
        .where((s) => s.isClosed)
        .map((s) => '${s.dayLabel}|${s.daypart}')
        .toSet();
    final profile = await _resolveProfileForFullWeek(restaurantId, weekId);

    final overrides = await _resolvePlanDaypartOverrides(
      restaurantId: restaurantId,
      weekId: weekId,
    );

    final keptWithPlanTargets = kept.map((s) {
      final allocation = overrides[s.dayLabel]?[s.daypart];
      return allocation == null ? s : _withPlanTargets(s, allocation);
    }).toList();

    final openAsRecords = openSnapshots
        .where((s) => !closedKeys.contains('${s.dayLabel}|${s.daypart}'))
        .map((s) {
          final snapshot = _snapshotForFullWeek(
            s,
            currentOperationalBusinessDate: operationalBusinessDate,
          );
          final allocation = overrides[s.dayLabel]?[s.daypart];
          return CurrentWeekState.shiftRecordFromSnapshot(
            snapshot,
            profile,
            planForecastCovers: allocation?.forecastCovers,
            planForecastSales: allocation?.forecastSales,
            planRequiredFohHours: allocation?.requiredFohHours,
            planRequiredBohHours: allocation?.requiredBohHours,
          );
        })
        .toList();

    return [...keptWithPlanTargets, ...openAsRecords];
  }

  OpenShiftSnapshot _snapshotForFullWeek(
    OpenShiftSnapshot snapshot, {
    required String? currentOperationalBusinessDate,
  }) {
    if (snapshot.status != 'closed') return snapshot;
    final eligible = ShiftBoundaryResolver.isEligibleForClosedTruth(
      rowStatus: snapshot.status,
      shiftCloseAuthority: ClosedTruthEligibility.closeAuthorityForSourceSystem(
        snapshot.sourceSystem,
      ),
      rowBusinessDate: snapshot.businessDate,
      currentOperationalBusinessDate: currentOperationalBusinessDate,
    );
    if (eligible) return snapshot;
    return OpenShiftSnapshot(
      restaurantId: snapshot.restaurantId,
      weekId: snapshot.weekId,
      dayLabel: snapshot.dayLabel,
      daypart: snapshot.daypart,
      status: 'projected',
      businessDate: snapshot.businessDate,
      businessTimingProfileId: snapshot.businessTimingProfileId,
      businessTimingProfileVersionId: snapshot.businessTimingProfileVersionId,
      servicePeriodKey: snapshot.servicePeriodKey,
      forecastCovers: snapshot.forecastCovers,
      currentCovers: 0,
      scheduledFohHours: snapshot.scheduledFohHours,
      scheduledBohHours: snapshot.scheduledBohHours,
      currentPPA: 0,
      currentCPLH: 0,
      currentSPLH: 0,
      blendedWage: snapshot.blendedWage,
      blendedWageAvailable: snapshot.blendedWageAvailable,
      timeLabel: snapshot.timeLabel,
      serviceElapsedLabel: snapshot.serviceElapsedLabel,
      sourceSystem: snapshot.sourceSystem,
      sourceShiftId: snapshot.sourceShiftId,
      provenance: snapshot.provenance,
      lastEventAt: snapshot.lastEventAt,
      updatedAt: snapshot.updatedAt,
    );
  }

  ShiftRecord _withPlanTargets(ShiftRecord s, DaypartAllocation allocation) {
    final isClosed = s.isClosed;
    return ShiftRecord(
      id: s.id,
      restaurantId: s.restaurantId,
      weekId: s.weekId,
      dayLabel: s.dayLabel,
      daypart: s.daypart,
      status: s.status,
      covers: s.covers,
      forecastCovers: allocation.forecastCovers,
      ppa: s.ppa,
      cplh: s.cplh,
      splh: s.splh,
      fohHours: isClosed ? s.fohHours : allocation.requiredFohHours,
      bohHours: isClosed ? s.bohHours : allocation.requiredBohHours,
      theoreticalLaborPct: s.theoreticalLaborPct,
      primaryLever: s.primaryLever,
      scheduledFohHours: allocation.requiredFohHours,
      scheduledBohHours: allocation.requiredBohHours,
      storedFohLaborDollar: s.storedFohLaborDollar,
      storedBohLaborDollar: s.storedBohLaborDollar,
      storedFohLaborPct: s.storedFohLaborPct,
      storedBohLaborPct: s.storedBohLaborPct,
      storedTotalLaborPct: s.storedTotalLaborPct,
      storedBlendedWage: s.storedBlendedWage,
      targetProfileId: s.targetProfileId,
      targetProfileVersionId: s.targetProfileVersionId,
      targetSourceType: s.targetSourceType,
      targetCPLH: s.targetCPLH,
      targetSPLH: s.targetSPLH,
      targetPPA: s.targetPPA,
      targetFohWage: s.targetFohWage,
      targetBohWage: s.targetBohWage,
      opzFloorCPLH: s.opzFloorCPLH,
      opzCeilingCPLH: s.opzCeilingCPLH,
      theoreticalFohLaborPct: s.theoreticalFohLaborPct,
      theoreticalBohLaborPct: s.theoreticalBohLaborPct,
      snapshotBlendedWage: s.snapshotBlendedWage,
      planForecastSales: allocation.forecastSales,
      businessDate: s.businessDate,
      sourceSystem: s.sourceSystem,
      sourceShiftId: s.sourceShiftId,
    );
  }

  /// Per-Daypart V1 (Slice 5): builds a
  /// `dayLabel -> daypart -> [DaypartAllocation]` lookup of locked-plan
  /// daypart targets for [weekId].
  ///
  /// Precedence (mirrors the proven Slice 3 pattern in
  /// `ScheduleForecastNotifier`):
  ///   - When the in-force `WeeklyPlanSnapshot.dayDayparts` is non-empty,
  ///     those PERSISTED locked per-(business_date, service_period) rows
  ///     are the AUTHORITY. Covers (int) and sales (double) carry
  ///     straight from the persisted row; the persisted hour doubles are
  ///     reconciled into integers via the shared
  ///     `reconcileLockedDaypartIntHours` helper so per-period whole
  ///     hours sum EXACTLY to the locked day-level integer hours
  ///     (Option B — no independent per-cell rounding, consistent with
  ///     #917 / #941). The set of periods per day is the persisted
  ///     sub-rows for that business date, NOT the render-time resolver.
  ///   - When `dayDayparts` is EMPTY (legacy snapshot written before
  ///     Slice 1, or Gap-42 insufficient-recommendation fallback), and
  ///     ONLY then, the deprecated render-time `DaypartPlanAllocator`
  ///     supplies the sub-rows so the screen still renders honestly.
  ///
  /// Returns an empty map (every lookup falls back to snapshot values)
  /// when [weekId] is not the current operational week, when no locked
  /// weekly snapshot exists for the current week, or when allocation
  /// inputs cannot be resolved. Read-only — never auto-generates a
  /// snapshot, never reaches into per-snapshot plan rebuilding. The
  /// non-current-week test guarantee from 7.55l.7c (no auto-generation)
  /// still holds because this path skips the snapshot lookup unless
  /// `weekId` matches the current operational week.
  Future<Map<String, Map<String, DaypartAllocation>>>
  _resolvePlanDaypartOverrides({
    required String restaurantId,
    required String weekId,
  }) async {
    final emptyOverrides = <String, Map<String, DaypartAllocation>>{};
    final currentWeekId = await getCurrentWeekId();
    if (currentWeekId == null || currentWeekId != weekId) {
      return emptyOverrides;
    }

    final snapshot = await WeeklyPlanSnapshotService.instance
        .getExistingCurrentWeekSnapshot();
    if (snapshot == null) return emptyOverrides;

    final config = await RestaurantTimingConfigReadService.instance
        .getActiveTimingConfig();
    final defs =
        config?.servicePeriodDefinitions ??
        ServicePeriodDefinitionResolver.demoDefinitions;

    final out = <String, Map<String, DaypartAllocation>>{};

    // Slice 5: persisted locked sub-rows are the authority when present.
    if (snapshot.dayDayparts.isNotEmpty) {
      // Day label → locked business date (same idiom Slice 3 uses in
      // ScheduleForecastNotifier). The period SET per day is the
      // persisted sub-rows for that business date (locked authority),
      // NOT the render-time resolver.
      final businessDateByDay = <String, String>{
        for (final dr in snapshot.dayRows) dr.day: dr.businessDate,
      };
      businessDateByDay.forEach((dayLabel, businessDate) {
        // FOH/BOH integers reconciled via the SINGLE shared helper so
        // per-period whole hours sum exactly to the locked day-level
        // integer hours (Option B). Covers/sales carry straight from the
        // persisted row.
        final reconciled = reconcileLockedDaypartIntHours(
          snapshot: snapshot,
          businessDate: businessDate,
          definitions: defs,
        );
        if (reconciled.isEmpty) return;
        out[dayLabel] = {
          for (final r in reconciled)
            r.servicePeriodId: DaypartAllocation(
              daypartId: r.servicePeriodId,
              label: r.label,
              forecastCovers: r.forecastCovers,
              forecastSales: r.forecastSales,
              requiredFohHours: r.requiredFohHours,
              requiredBohHours: r.requiredBohHours,
            ),
        };
      });
      return out;
    }

    // Empty `dayDayparts` (legacy snapshot pre-Slice 1 / Gap-42
    // insufficient-recommendation) — and ONLY then — fall back to the
    // deprecated render-time allocator so the screen still renders
    // honest sub-rows. New code must NOT add locked-read consumers here.
    final distributionWeights =
        await SchedulePlanReadService.loadDistributionWeights(restaurantId);
    for (final dayRow in snapshot.dayRows) {
      // Empty-dayDayparts legacy/Gap-42 fallback (see block comment
      // above); the DaypartPlanAllocator deprecation explicitly
      // preserves this path.
      // ignore: deprecated_member_use_from_same_package
      final allocations = DaypartPlanAllocator.allocate(
        day: dayRow.day,
        dayCovers: dayRow.forecastCovers,
        daySales: dayRow.forecastSales,
        dayFohHours: dayRow.requiredFohHours,
        dayBohHours: dayRow.requiredBohHours,
        definitions: defs,
        distributionWeights: distributionWeights,
      );
      if (allocations.isEmpty) continue;
      out[dayRow.day] = {for (final a in allocations) a.daypartId: a};
    }
    return out;
  }

  /// Resolves the target profile used when converting open/projected
  /// snapshots into [ShiftRecord]s for Full Week rendering.
  ///
  /// 7.55q.4: always returns the CURRENT [ActiveTargetProfile] —
  /// previously this branched on whether [weekId] matched the current
  /// week and projected the snapshot's cycle in that case, which made
  /// non-closed `ShiftRecord` rows carry snapshot-cycle target fields
  /// even when the active Benchmark had rolled. That violated Rule 3:
  /// non-closed Variance rows must read shared Benchmark/Plan objects
  /// 1:1. Plan-owned fields (forecast covers, scheduled hours) still
  /// come from the snapshot itself via
  /// [CurrentWeekState.shiftRecordFromSnapshot]; only the
  /// Benchmark-owned target fields are now sourced here.
  Future<ActiveTargetProfile> _resolveProfileForFullWeek(
    String restaurantId,
    String weekId,
  ) async {
    return _loadActiveProfile(restaurantId);
  }

  // ── Current week state ───────────────────────────────────────────────────

  /// Builds [CurrentWeekState] for the current week using locked truth.
  ///
  /// Uses [getLiveWeekToDate] for locked WTD and [getFullWeekShifts] for
  /// the full-week shift list. Returns null when locked WTD truth is not
  /// available for the in-force week.
  Future<CurrentWeekState?> getCurrentWeekState(
    String weekId,
    String weekLabel,
  ) async {
    // Use the locked current-week WTD path (7.55l.7b/7b1).
    final weekData = await getLiveWeekToDate();
    if (weekData == null) return null;
    final shifts = await getFullWeekShifts(weekId);
    return CurrentWeekState(weekData: weekData, fullWeekShifts: shifts);
  }

  // ── Reset to demo data ───────────────────────────────────────────────────

  Future<void> reseedDemo() async {
    await SqliteDatabase.instance.reseedDemo();
    AppRuntimeInvalidationBus.instance.notifyRuntimeWriteCompleted();
  }

  Future<void> clearAllData() async {
    await SqliteDatabase.instance.clearAllData();
    AppRuntimeInvalidationBus.instance.notifyRuntimeWriteCompleted();
  }

  // ── Mock replay scenario controls ──────────────────────────────────────

  /// Returns the persisted mock replay business date, or null if unset.
  Future<String?> getMockReplayBusinessDate() async {
    final restaurantId = await _activeRestaurantId();
    return SqliteDatabase.instance.getMockReplayBusinessDate(restaurantId);
  }

  /// Reseeds all operational tables for a specific mock replay business date.
  Future<void> reseedMockReplayForDate(String isoDate) async {
    await SqliteDatabase.instance.reseedMockReplayForBusinessDate(isoDate);
  }

  /// Advances the mock replay by one calendar day and reseeds coherently.
  Future<void> advanceMockReplayDay() async {
    final restaurantId = await _activeRestaurantId();
    final currentDate = await SqliteDatabase.instance.getMockReplayBusinessDate(
      restaurantId,
    );
    final base = currentDate ?? MockIntegrationReplaySeed.defaultBusinessDate;

    final parts = base.split('-');
    final dt = DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
    final next = DateTime(dt.year, dt.month, dt.day + 1);
    final nextDate =
        '${next.year}-${next.month.toString().padLeft(2, '0')}'
        '-${next.day.toString().padLeft(2, '0')}';

    await SqliteDatabase.instance.reseedMockReplayForBusinessDate(nextDate);
    AppRuntimeInvalidationBus.instance.notifyRuntimeWriteCompleted();
  }

  // ── Date helpers ────────────────────────────────────────────────────────

  static DateTime _parseDate(String isoDate) {
    final parts = isoDate.split('-');
    return DateTime.utc(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  static String _formatDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  // ── Dollar Impact accumulation (7.55p.3) ────────────────────────────────
  // Sums per-shift dollar impact using each shift's own locked targets.
  // Impact = actual labor − theoretical labor (model hours × locked wages).
  // Shifts with missing locked targets (targetCPLH or targetSPLH ≤ 0)
  // are skipped to avoid division errors.
  static double _accumulateDollarImpact(List<ShiftRecord> shifts) {
    return shifts.fold<double>(0, (sum, s) {
      final cplh = s.targetCPLH;
      final splh = s.targetSPLH;
      final fohWage = s.targetFohWage;
      final bohWage = s.targetBohWage;
      if (cplh == null ||
          cplh <= 0 ||
          splh == null ||
          splh <= 0 ||
          fohWage == null ||
          bohWage == null) {
        return sum;
      }
      final actualLabor = s.fohLaborDollar + s.bohLaborDollar;
      final modelFoh = LaborModel.modelFohHours(s.covers, cplh);
      final modelBoh = LaborModel.modelBohHoursFromSales(s.actualSales, splh);
      final theoreticalLabor = modelFoh * fohWage + modelBoh * bohWage;
      return sum + (actualLabor - theoreticalLabor);
    });
  }
}
