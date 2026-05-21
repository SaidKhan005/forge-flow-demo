// Part of sqlite_database.dart. weekly_plan_snapshots bootstrap seeder + its demand/weights replicas.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

/// FU-mobile-cold-boot-shift-stale-state: bootstrap-time seeder for
/// `weekly_plan_snapshots`.
///
/// Cold-boot path (`_onCreate`) and replay-advance path
/// (`reseedMockReplayForBusinessDate`) both call this so the locked
/// weekly plan for the in-force week is persisted synchronously before
/// the dashboard notifiers fire. Without it, `ShiftDashboardNotifier`'s
/// first read of `getExistingCurrentLockedWeeklyPlan()` finds nothing
/// and caches `lockedPlanUnavailable = true` — a stale state the user
/// only escapes by tapping a Settings write that fires the invalidation
/// bus.
///
/// HP #2 compliance: this is a writer-side bootstrap path. The reader
/// (`ShiftDashboardNotifier._load()`) is unchanged and never branches
/// on `kDemoMode`. The seeded row uses the same schema and columns as
/// the runtime `WeeklyPlanSnapshotService._generateAndPersistSnapshot`
/// pipeline.
///
/// Behaviour:
/// - Computes the configured week-start day from `restaurant_timing_configs`
///   (falls back to Monday) so the week span matches what the runtime
///   policy would derive.
/// - No-ops when a snapshot already exists for the week-in-force, so
///   same-week replay advance never rewrites locked truth.
/// - Aggregates the weekly forecast covers from `replay.currentWeekShifts`
///   (every shift carries its own forecast covers per daypart) and
///   delegates the day-level distribution to the pure
///   [SchedulePlanResolver] — the same resolver the runtime live path
///   uses, so the seeded shape is byte-equivalent to what the
///   auto-generator would have produced.
/// - Requires the demo target cycle to be seeded first (it is — `_onCreate`
///   calls `_seedDemoActiveTargetProfile` before this, and the advance
///   path runs `_backfillLockedTargets` ahead of this call).
Future<void> _seedWeeklyPlanSnapshotFromReplay(
  Database db, {
  required String businessDate,
}) async {
  // Resolve the configured week-start day; default to Monday when no
  // timing config exists (mirrors WeeklyPlanSnapshotService).
  int weekStartDay = DateTime.monday;
  if (await _tableExists(db, 'restaurant_timing_configs')) {
    final configRows = await db.query(
      'restaurant_timing_configs',
      columns: const ['week_start_day'],
      where: 'restaurant_id = ?',
      whereArgs: [DemoScope.restaurantId],
      limit: 1,
    );
    if (configRows.isNotEmpty) {
      final raw = configRows.first['week_start_day'];
      if (raw is int) {
        weekStartDay = raw;
      } else if (raw is num) {
        weekStartDay = raw.toInt();
      }
    }
  }

  final weekStart = WeeklyPlanSnapshotPolicy.weekStartForDate(
    businessDate,
    weekStartDay: weekStartDay,
  );
  final weekEnd = WeeklyPlanSnapshotPolicy.weekEndForDate(
    businessDate,
    weekStartDay: weekStartDay,
  );
  final weekKey = WeeklyPlanSnapshotPolicy.weekKeyFromSpan(weekStart, weekEnd);

  // No-op when a snapshot already covers the in-force week. Preserves
  // the locked-snapshot-survives-same-week-advance contract (7.55l.6b1).
  final existing = await db.query(
    'weekly_plan_snapshots',
    columns: const ['snapshot_id'],
    where: 'restaurant_id = ? AND week_key = ?',
    whereArgs: [DemoScope.restaurantId, weekKey],
    limit: 1,
  );
  if (existing.isNotEmpty) return;

  // Require the demo target cycle (seeded earlier in the same path).
  // If it's missing for any reason, degrade silently — the runtime
  // auto-generator will pick up the slack on first access.
  final cycleRows = await db.query(
    'target_cycles',
    where: 'restaurant_id = ? AND deactivated_at IS NULL',
    whereArgs: [DemoScope.restaurantId],
    orderBy: 'created_at DESC',
    limit: 1,
  );
  if (cycleRows.isEmpty) return;
  // Per-Daypart V1 (Slice 3): `TargetCycle.fromMap` rehydrates the
  // parent `target_cycles` row only — its `dayparts` list is empty.
  // The runtime lock path (`WeeklyPlanSnapshotService
  // ._generateAndPersistSnapshot`) gets a cycle hydrated with its
  // per-period child rows via `TargetCycleService.getOrCreateActiveCycle`
  // → `TargetCycleDao._hydrateWithDayparts`. Mirror that here by reading
  // the same `target_cycle_dayparts` child rows the demo cycle write
  // path (`_ensureDemoSeedCycle` → `TargetCycleDao.upsertCycle`) just
  // persisted, so the snapshot's per-period sub-rows derive from the
  // same per-period targets the rest of the demo reads. Without this the
  // cycle's `dayparts` stay empty, `_buildSeedDayDaypartRows` returns the
  // Gap-42 empty list, and the demo-locked snapshot stays a structurally
  // pre-Slice-1 "legacy" snapshot (the Gap-12 1:1 allocator trap is
  // never actually closed in demo).
  final parentCycle = TargetCycle.fromMap(cycleRows.first);
  final cycleDayparts = await TargetCycleDao(
    db,
  ).getDaypartsForCycle(parentCycle.cycleId);
  final cycle = cycleDayparts.isEmpty
      ? parentCycle
      : parentCycle.copyWith(dayparts: cycleDayparts);

  // Mirror DemandForecastContextService.getContextForAnchorDate exactly:
  // weekly forecast covers come from the just-seeded closed shifts in
  // the 60-day baseline + 21-day recent windows. This keeps the seeded
  // snapshot byte-equivalent to what the runtime auto-generator would
  // have produced (the same SchedulePlanResolver runs over the same
  // demand + same data-driven weights), so the contract test
  // `weekly_plan_snapshot_service_test D — snapshot matches generated
  // SchedulePlan` still holds.
  final weeklyForecastCovers = await _resolveSeedDemandWeeklyCovers(
    db,
    anchorBusinessDate: businessDate,
  );
  if (weeklyForecastCovers <= 0) return;

  // Build data-driven distribution weights from the just-seeded closed
  // shifts using the same 60-day baseline + 21-day recent windows the
  // runtime `SchedulePlanReadService.loadDistributionWeights` reads.
  // Without these, the resolver falls back to its hardcoded default
  // day weights and the seeded snapshot would diverge from what the
  // runtime path produces (test D-day-rows enforces parity).
  final distributionWeights = await _buildSeedDistributionWeights(
    db,
    anchorBusinessDate: businessDate,
  );

  // Delegate to the same pure resolver the runtime live path uses so
  // the seeded shape stays byte-equivalent (forecast sales, day
  // rotation, largest-remainder allocation, data-driven day weights).
  final plan = SchedulePlanResolver.resolveFromValues(
    forecastCovers: weeklyForecastCovers,
    targetPPA: cycle.targetPPA,
    targetCPLH: cycle.targetCPLH,
    targetSPLH: cycle.targetSPLH,
    fohWage: cycle.fohWage,
    bohWage: cycle.bohWage,
    coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
    salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
    distributionWeights: distributionWeights,
  );

  // Map SchedulePlan day rows → WeeklyPlanSnapshotDay with business dates.
  // dayPlans is Mon-first; rotate to match configured week start the
  // same way WeeklyPlanSnapshotService._buildDayRows does.
  final rotationOffset = (weekStartDay - 1) % 7;
  final rotated = rotationOffset == 0
      ? plan.dayPlans
      : <ScheduleDayPlan>[
          ...plan.dayPlans.sublist(rotationOffset),
          ...plan.dayPlans.sublist(0, rotationOffset),
        ];

  final startDate = DateTime.utc(
    int.parse(weekStart.split('-')[0]),
    int.parse(weekStart.split('-')[1]),
    int.parse(weekStart.split('-')[2]),
  );

  final dayRows = List<WeeklyPlanSnapshotDay>.generate(rotated.length, (i) {
    final dayPlan = rotated[i];
    final date = startDate.add(Duration(days: i));
    final iso =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    return WeeklyPlanSnapshotDay(
      day: dayPlan.day,
      businessDate: iso,
      forecastCovers: dayPlan.forecastCovers,
      forecastSales: dayPlan.forecastSales,
      requiredFohHours: dayPlan.requiredFohHours,
      requiredBohHours: dayPlan.requiredBohHours,
    );
  });

  // Per-Daypart V1 (Slice 3): build the locked per-(business_date,
  // service_period) sub-rows + the wages-at-lock-time stamp exactly the
  // way the runtime lock path does (`WeeklyPlanSnapshotService
  // ._buildDayDaypartRowsForLock` + its wage stamp, ~lines 188-231).
  // Without these the demo-seeded snapshot is structurally a
  // pre-Slice-1 "legacy" snapshot: `schedule_forecast_notifier`
  // (`adjustedDayViews`, ~lines 519-530) sees `dayDayparts.isEmpty` and
  // silently falls back to the read-time `DaypartPlanAllocator`
  // regeneration, so Slice 3's persistence read-swap is dead in demo
  // (Gap-12 1:1 trap never actually closed for the shipped demo).
  final dayDayparts = _buildSeedDayDaypartRows(cycle: cycle, dayRows: dayRows);

  // Per-Daypart V1 (bottom-up locked snapshot, PR #917 parity): the
  // demo seed used to be a THIRD divergent writer — it constructed the
  // snapshot from raw `plan.*` week totals and raw `dayRows`, so
  // Σ(per-period) ≠ day ≠ week and the Data Alignment Audit panel
  // showed covers/sales drift. The runtime lock path
  // (`WeeklyPlanSnapshotService._generateAndPersistSnapshot`) reconciles
  // through the SHARED `WeeklyPlanSnapshotBottomUpReconciler.reconcile`;
  // the seed now calls the SAME shared reconciler so demo mirrors
  // production (HP #2) with exactly one implementation of the math.
  // Per-period rows (`dayDayparts`) keep per-period rate fidelity
  // unchanged — `_buildSeedDayDaypartRows` is untouched. The Gap-42
  // honest fallback (no per-period rows → keep pooled `plan.*`, never
  // zero) is preserved by the shared reconciler.
  final reconciled = WeeklyPlanSnapshotBottomUpReconciler.reconcile(
    plan: plan,
    dayRows: dayRows,
    dayDayparts: dayDayparts,
  );

  // Design Rule 8 — the locked-plan wage stamp. Pull wages from the
  // cycle in force at lock time (not "current" wages); blended wage
  // uses the canonical cover-independent formula on the shared
  // `ActiveTargetProfile` seam so the stamp can't drift from runtime.
  final wageStamp = WeeklyPlanSnapshotWagesAtLockTime(
    fohWage: cycle.fohWage,
    bohWage: cycle.bohWage,
    blendedWage: ActiveTargetProfile.computeTargetBlendedWage(
      targetCPLH: cycle.targetCPLH,
      targetSPLH: cycle.targetSPLH,
      targetPPA: cycle.targetPPA,
      fohWage: cycle.fohWage,
      bohWage: cycle.bohWage,
    ),
  );

  final now = nowIsoUtc();
  final snapshot = WeeklyPlanSnapshot(
    snapshotId:
        '${DemoScope.restaurantId}_snapshot_${weekStart.replaceAll('-', '')}',
    restaurantId: DemoScope.restaurantId,
    weekStartDate: weekStart,
    weekEndDate: weekEnd,
    targetCycleId: cycle.cycleId,
    forecastCovers: reconciled.weekCovers,
    forecastSales: reconciled.weekSales,
    requiredFohHours: reconciled.weekFohHours,
    requiredBohHours: reconciled.weekBohHours,
    theoreticalFohLaborDollars: reconciled.weekFohDollars,
    theoreticalBohLaborDollars: reconciled.weekBohDollars,
    coversSource: plan.coversSource,
    salesSource: plan.salesSource,
    generatedAt: now,
    lockedAt: now,
    dayRows: reconciled.dayRows,
    dayDayparts: dayDayparts,
    wageAtLockTime: wageStamp,
  );

  // Persist via the same map shape WeeklyPlanSnapshotDao.upsertSnapshot
  // writes (day_rows_json, forecast_context_json, metadata, is_active
  // coercions) — inlined here because the DAO can't be reached during
  // _onCreate (it would re-enter the database getter).
  final map = snapshot.toMap();
  final encodedDayRows = jsonEncode(map.remove('day_rows') as List<dynamic>);
  final forecastContext = map.remove('forecast_context');
  // Per-Daypart V1 (Slice 1/3): the seed's snapshot model now also
  // carries `day_dayparts` and `wage_at_lock_time_json`. `day_dayparts`
  // is not a column on the parent `weekly_plan_snapshots` table — it is
  // persisted into the `weekly_plan_snapshot_day_dayparts` child table
  // below, mirroring `WeeklyPlanSnapshotDao.upsertSnapshot`'s
  // replace-for-snapshot child write. Strip it from the parent map and
  // JSON-encode the wage stamp for its dedicated column.
  final dayDaypartsToPersist =
      (map.remove('day_dayparts') as List<dynamic>? ?? const <dynamic>[]);
  final wageAtLockTimeJson = map.remove('wage_at_lock_time_json');
  map['wage_at_lock_time_json'] = wageAtLockTimeJson == null
      ? null
      : jsonEncode(wageAtLockTimeJson);
  map['day_rows_json'] = encodedDayRows;
  map['forecast_context_json'] = forecastContext == null
      ? null
      : jsonEncode(forecastContext);
  if (map.containsKey('metadata')) {
    final rawMetadata = map['metadata'];
    map['metadata'] = rawMetadata == null ? null : jsonEncode(rawMetadata);
  }
  if (map.containsKey('is_active')) {
    final raw = map['is_active'];
    if (raw is bool) {
      map['is_active'] = raw ? 1 : 0;
    }
  }
  await db.insert(
    'weekly_plan_snapshots',
    map,
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  // Per-Daypart V1 (Slice 3): persist the per-(business_date,
  // service_period) child rows. `reseedDemo` clears
  // `weekly_plan_snapshots` but NOT `weekly_plan_snapshot_day_dayparts`,
  // and the demo snapshot_id is deterministic
  // (`${restaurantId}_snapshot_${weekStartCompact}`), so a stale child
  // row from a prior seed would collide on the
  // `(snapshot_id, business_date, service_period_id)` primary key.
  // Delete-then-insert by snapshot_id mirrors
  // `WeeklyPlanSnapshotDao.upsertSnapshot`'s replace-for-snapshot
  // semantics and keeps the seed idempotent/deterministic across
  // reseeds (two reseeds yield byte-identical child rows). Closed-truth
  // immutability is upheld upstream: this whole function no-ops when a
  // snapshot already covers the in-force week (the `existing.isNotEmpty`
  // guard above), so a same-week replay advance never reaches this
  // delete and never rewrites already-locked child rows.
  await db.delete(
    'weekly_plan_snapshot_day_dayparts',
    where: 'snapshot_id = ?',
    whereArgs: [snapshot.snapshotId],
  );
  if (dayDaypartsToPersist.isNotEmpty) {
    final childBatch = db.batch();
    for (final raw in dayDaypartsToPersist) {
      final dp = Map<String, dynamic>.from(raw as Map);
      dp['snapshot_id'] = snapshot.snapshotId;
      dp['created_at'] = now;
      childBatch.insert('weekly_plan_snapshot_day_dayparts', dp);
    }
    await childBatch.commit(noResult: true);
  }
}

/// Per-Daypart V1 (Slice 3): pure replica of
/// `WeeklyPlanSnapshotService._buildDayDaypartRows` (the runtime lock
/// path, ~lines 372-437), invoked here with no
/// `applicablePeriodIdsByWeekday` map — exactly as the runtime
/// `_buildDayDaypartRowsForLock` calls it — so the seeded per-period
/// sub-rows are byte-equivalent to what the runtime auto-generator
/// would have produced for the same cycle + day rows.
///
/// This is the same inlined-replica pattern the rest of this file uses
/// for runtime parity (`_resolveSeedDemandWeeklyCovers`,
/// `_buildSeedDistributionWeights`): the runtime helper is `static`
/// private on `WeeklyPlanSnapshotService` and its public test hook is
/// `@visibleForTesting` (illegal to call from production seed code), so
/// the formula is mirrored here verbatim rather than re-invented.
///
/// Allocation (mirrors runtime exactly — do NOT add largest-remainder
/// reconciliation the runtime path does not have, or the seeded shape
/// diverges from the live auto-generator):
///   - period covers  = round(day covers × period cover-weight ÷ Σweights)
///   - period sales    = period covers × period target PPA
///   - period FOH hrs  = period covers ÷ period target CPLH
///   - period BOH hrs  = period sales  ÷ period target SPLH
///   - period FOH $    = period FOH hrs × whole-day FOH wage (Design Rule 5)
///   - period BOH $    = period BOH hrs × whole-day BOH wage
///
/// Returns `const []` when the cycle has no per-period rows (Gap 42
/// fallback) — read consumers then fall back to whole-day day rows
/// honestly, same as runtime.
List<WeeklyPlanSnapshotDayDaypart> _buildSeedDayDaypartRows({
  required TargetCycle cycle,
  required List<WeeklyPlanSnapshotDay> dayRows,
}) {
  if (cycle.dayparts.isEmpty) {
    return const <WeeklyPlanSnapshotDayDaypart>[];
  }

  final periodCoverWeights = <String, int>{
    for (final dp in cycle.dayparts) dp.servicePeriodId: dp.coverCount,
  };

  final out = <WeeklyPlanSnapshotDayDaypart>[];
  for (final dayRow in dayRows) {
    // Runtime lock path passes no applicable-periods map → every
    // per-period row is applicable on every weekday (the cycle was
    // built from the operator's real calibration-window evidence;
    // periods that never serve a given weekday contribute zero covers).
    final periodIds = cycle.dayparts.map((d) => d.servicePeriodId).toList();
    final totalWeight = periodIds
        .map((id) => periodCoverWeights[id] ?? 0)
        .fold<int>(0, (a, b) => a + b);
    for (final periodId in periodIds) {
      final cycleDp = cycle.daypartFor(periodId);
      if (cycleDp == null) continue;
      final w = periodCoverWeights[periodId] ?? 0;
      final periodCovers = totalWeight > 0
          ? ((dayRow.forecastCovers * w) / totalWeight).round()
          : 0;
      final periodSales = periodCovers * cycleDp.targetPPA;
      final periodReqFohHours = cycleDp.targetCPLH > 0
          ? periodCovers / cycleDp.targetCPLH
          : 0.0;
      final periodReqBohHours = cycleDp.targetSPLH > 0
          ? periodSales / cycleDp.targetSPLH
          : 0.0;
      final periodFohDollars = periodReqFohHours * cycle.fohWage;
      final periodBohDollars = periodReqBohHours * cycle.bohWage;
      out.add(
        WeeklyPlanSnapshotDayDaypart(
          businessDate: dayRow.businessDate,
          servicePeriodId: periodId,
          forecastCovers: periodCovers,
          forecastSales: periodSales,
          requiredFohHours: periodReqFohHours,
          requiredBohHours: periodReqBohHours,
          theoreticalFohDollars: periodFohDollars,
          theoreticalBohDollars: periodBohDollars,
        ),
      );
    }
  }
  return out;
}

/// Inlined replica of `DemandForecastContextService.getContextForAnchorDate`
/// resolved-weekly-covers math, run directly against the in-flight
/// `_onCreate` database handle. Must not call the runtime singleton
/// (`SqliteDatabase.instance.database`) because we are still inside
/// `_initDb()` — `_db` has not been assigned yet and a singleton read
/// would re-enter `openDatabase` and deadlock.
///
/// Mirrors the runtime contract:
///   - 60-day baseline window weekly avg = totalCovers / (60/7)
///   - 21-day recent window weekly avg   = totalCovers / 3
///   - resolved = max(0, baseline + (recent - baseline)/2) when 21-day is non-empty,
///     else baseline.
Future<int> _resolveSeedDemandWeeklyCovers(
  Database db, {
  required String anchorBusinessDate,
}) async {
  const weeksIn60DayWindow = 60 / 7;
  const weeksIn21DayWindow = 3;

  final baselineStart = _subtractIsoDays(anchorBusinessDate, 59);
  final baselineRows = await db.query(
    'shift_records',
    columns: const ['covers'],
    where:
        "restaurant_id = ? "
        "AND status = 'closed' "
        "AND business_date >= ? "
        "AND business_date <= ?",
    whereArgs: [DemoScope.restaurantId, baselineStart, anchorBusinessDate],
  );
  if (baselineRows.isEmpty) return 0;
  final baselineTotal = baselineRows.fold<int>(
    0,
    (sum, row) => sum + ((row['covers'] as num?)?.toInt() ?? 0),
  );
  final baselineWeeklyAvg = (baselineTotal / weeksIn60DayWindow).round();

  final recentStart = _subtractIsoDays(anchorBusinessDate, 20);
  final recentRows = await db.query(
    'shift_records',
    columns: const ['covers'],
    where:
        "restaurant_id = ? "
        "AND status = 'closed' "
        "AND business_date >= ? "
        "AND business_date <= ?",
    whereArgs: [DemoScope.restaurantId, recentStart, anchorBusinessDate],
  );

  if (recentRows.isEmpty) return baselineWeeklyAvg;

  final recentTotal = recentRows.fold<int>(
    0,
    (sum, row) => sum + ((row['covers'] as num?)?.toInt() ?? 0),
  );
  final recentWeeklyAvg = (recentTotal / weeksIn21DayWindow).round();
  final trendDelta = recentWeeklyAvg - baselineWeeklyAvg;
  final resolved = baselineWeeklyAvg + (trendDelta / 2).round();
  return resolved < 0 ? 0 : resolved;
}

String _subtractIsoDays(String isoDate, int days) {
  final parts = isoDate.split('-');
  final dt = DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
  final result = dt.subtract(Duration(days: days));
  return '${result.year.toString().padLeft(4, '0')}-'
      '${result.month.toString().padLeft(2, '0')}-'
      '${result.day.toString().padLeft(2, '0')}';
}

/// Inlined replica of `SchedulePlanReadService.loadDistributionWeights`
/// driven directly from the in-flight `_onCreate` database handle.
///
/// Reads the closed shift_records in the 60-day baseline + 21-day recent
/// windows and delegates to the pure
/// `DistributionWeightBuilder.fromDateWindowShifts` — the same builder
/// the runtime live path uses. Returns null when the resulting weights
/// are unavailable, which lets the resolver fall back to its default
/// day weights honestly.
Future<ScheduleDistributionWeights?> _buildSeedDistributionWeights(
  Database db, {
  required String anchorBusinessDate,
}) async {
  final baselineStart = _subtractIsoDays(anchorBusinessDate, 59);
  final baselineRows = await db.query(
    'shift_records',
    where:
        "restaurant_id = ? "
        "AND status = 'closed' "
        "AND business_date >= ? "
        "AND business_date <= ?",
    whereArgs: [DemoScope.restaurantId, baselineStart, anchorBusinessDate],
  );

  final recentStart = _subtractIsoDays(anchorBusinessDate, 20);
  final recentRows = await db.query(
    'shift_records',
    where:
        "restaurant_id = ? "
        "AND status = 'closed' "
        "AND business_date >= ? "
        "AND business_date <= ?",
    whereArgs: [DemoScope.restaurantId, recentStart, anchorBusinessDate],
  );

  final baselineShifts = baselineRows
      .map((row) => ShiftRecord.fromMap(Map<String, dynamic>.from(row)))
      .toList();
  final recentShifts = recentRows
      .map((row) => ShiftRecord.fromMap(Map<String, dynamic>.from(row)))
      .toList();

  final weights = DistributionWeightBuilder.fromDateWindowShifts(
    baselineShifts: baselineShifts,
    recentShifts: recentShifts,
  );
  return weights.isAvailable ? weights : null;
}
