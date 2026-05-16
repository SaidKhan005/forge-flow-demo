// Phase 7.55o.6 — SQLite demo + mock-replay seed helpers.
//
// Part of sqlite_database.dart. Owns the demo-seed entrypoints
// (`_seedDemoRestaurant`, `_seedDemoTimingConfig`,
// `_seedDemoActiveTargetProfile`, `_loadSeedAuthorityProfile`,
// `_ensureDemoSeedCycle`, `_seedDemoDataFromReplay`,
// `_ensureDemoRestaurant`), the replay snapshot seeders
// (`_seedOpenShiftSnapshotsFromReplay`,
// `_seedReservationBookSnapshotsFromReplay`,
// `_seedWeeklyPlanSnapshotFromReplay` — FU-mobile-cold-boot fix),
// the locked-target backfill (`_backfillLockedTargets`), and the
// small helper functions (`_seedRecommendationCandidates`,
// `_addIsoDays`, `_deterministicHash`). Seed content is unchanged
// except for the new weekly-plan-snapshot bootstrap.

part of 'sqlite_database.dart';

/// Backfills locked-target columns on shift_records and week_records
/// that lack them, using the current active target profile.
/// Also ensures target-profile provenance and a compat version row.
Future<void> _backfillLockedTargets(
  Database db, {
  required String businessDate,
}) async {
  final cycle = await _ensureDemoSeedCycle(
    db,
    businessDate: businessDate,
  );
  final profile = await _loadSeedAuthorityProfile(
    db,
    businessDate: businessDate,
  );
  final compatVersionId = 'compat_${DemoScope.restaurantId}_v8_backfill';

  // Ensure a compat target_profile_versions row exists
  await db.insert('target_profile_versions', {
    'target_profile_version_id': compatVersionId,
    'target_profile_id': profile.targetProfileId,
    'restaurant_id': DemoScope.restaurantId,
    'source_type': profile.sourceType,
    'target_cplh': profile.targetCPLH,
    'target_splh': profile.targetSPLH,
    'target_ppa': profile.targetPPA,
    'foh_wage': profile.fohWage,
    'boh_wage': profile.bohWage,
    'opz_floor_cplh': profile.opzFloorCPLH,
    'opz_ceiling_cplh': profile.opzCeilingCPLH,
    'theoretical_foh_labor_pct': profile.theoreticalFohLaborPct,
    'theoretical_boh_labor_pct': profile.theoreticalBohLaborPct,
    'theoretical_labor_pct': profile.theoreticalLaborPct,
    'created_at': nowIsoUtc(),
  }, conflictAlgorithm: ConflictAlgorithm.ignore);

  await db.execute('''
    UPDATE shift_records SET
      target_profile_id = ?,
      target_profile_version_id = ?,
      target_source_type = ?,
      target_cplh = ?,
      target_splh = ?,
      target_ppa = ?,
      target_foh_wage = ?,
      target_boh_wage = ?,
      opz_floor_cplh = ?,
      opz_ceiling_cplh = ?,
      theoretical_foh_labor_pct = ?,
      theoretical_boh_labor_pct = ?
    WHERE target_cplh IS NULL AND restaurant_id = ?
  ''', [
    profile.targetProfileId,
    compatVersionId,
    profile.sourceType,
    profile.targetCPLH,
    profile.targetSPLH,
    profile.targetPPA,
    profile.fohWage,
    profile.bohWage,
    profile.opzFloorCPLH,
    profile.opzCeilingCPLH,
    profile.theoreticalFohLaborPct,
    profile.theoreticalBohLaborPct,
    DemoScope.restaurantId,
  ]);

  // ── Provenance-only repair for partially migrated rows ──────────────────
  // Rows that already have numeric locked targets but lack identity fields.
  await db.execute('''
    UPDATE shift_records SET
      target_profile_id = ?,
      target_profile_version_id = ?
    WHERE restaurant_id = ?
      AND target_cplh IS NOT NULL
      AND (target_profile_id IS NULL OR target_profile_version_id IS NULL)
  ''', [
    profile.targetProfileId,
    compatVersionId,
    DemoScope.restaurantId,
  ]);

  await db.execute('''
    UPDATE week_records SET
      target_source_type = ?,
      target_cplh = ?,
      target_splh = ?,
      target_ppa = ?,
      target_foh_wage = ?,
      target_boh_wage = ?,
      theoretical_foh_labor_pct = ?,
      theoretical_boh_labor_pct = ?
    WHERE target_cplh IS NULL AND restaurant_id = ?
  ''', [
    profile.sourceType,
    profile.targetCPLH,
    profile.targetSPLH,
    profile.targetPPA,
    profile.fohWage,
    profile.bohWage,
    profile.theoreticalFohLaborPct,
    profile.theoreticalBohLaborPct,
    DemoScope.restaurantId,
  ]);

  await db.execute('''
    UPDATE week_records SET
      target_calibration_window_start = ?,
      target_calibration_window_end = ?
    WHERE restaurant_id = ?
      AND (
        target_calibration_window_start IS NULL OR
        target_calibration_window_end IS NULL
      )
  ''', [
    cycle.calibrationWindowStart,
    cycle.calibrationWindowEnd,
    DemoScope.restaurantId,
  ]);
}

/// Seeds open/projected shift snapshots for the current week from replay output.
///
/// The open shift is determined by [replay.scenario], not hardcoded to
/// Friday dinner. Closed same-day dayparts and projected future dayparts
/// are derived from the scenario.
Future<void> _seedOpenShiftSnapshotsFromReplay(
    Database db, MockReplayOutput replay) async {
  final now = nowIsoUtc();
  final scenario = replay.scenario;
  final projectedShifts =
      replay.currentWeekShifts.where((s) => s.isProjected).toList();

  final snapshots = <OpenShiftSnapshot>[];

  for (final s in projectedShifts) {
    // Skip the open-shift slot — we'll insert the open snapshot for it
    if (s.dayLabel == scenario.openShiftDayLabel &&
        s.daypart == scenario.openShiftDaypart) {
      continue;
    }

    snapshots.add(OpenShiftSnapshot(
      restaurantId: DemoScope.restaurantId,
      weekId: s.weekId,
      dayLabel: s.dayLabel,
      daypart: s.daypart,
      status: 'projected',
      businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel)!,
      forecastCovers: s.forecastCovers,
      currentCovers: s.covers,
      scheduledFohHours: s.scheduledFohHours ?? s.fohHours,
      scheduledBohHours: s.scheduledBohHours ?? s.bohHours,
      currentPPA: s.ppa,
      currentCPLH: s.cplh,
      currentSPLH: s.splh,
      blendedWage: s.blendedWage,
      sourceSystem: s.sourceSystem ?? MockIntegrationReplaySeed.sourceSystem,
      sourceShiftId: MockIntegrationReplaySeed.snapshotSourceShiftId(
        weekId: s.weekId,
        dayLabel: s.dayLabel,
        daypart: s.daypart,
        status: 'projected',
      ),
      updatedAt: now,
    ));
  }

  // One current open shift from the scenario.
  // In-progress values simulate ~63% through service.
  final openShiftPlan = replay.currentWeekShifts.firstWhere(
    (s) =>
        s.dayLabel == scenario.openShiftDayLabel &&
        s.daypart == scenario.openShiftDaypart,
  );
  final openCovers = (openShiftPlan.forecastCovers *
          MockIntegrationReplaySeed.openProgressFraction)
      .round();
  final openPPA = openShiftPlan.ppa;
  final openSales = openCovers * openPPA;
  final openCPLH = openShiftPlan.fohHours > 0
      ? openCovers / openShiftPlan.fohHours
      : 0.0;
  final openSPLH = openShiftPlan.bohHours > 0
      ? openSales / openShiftPlan.bohHours
      : 0.0;

  snapshots.add(OpenShiftSnapshot(
    restaurantId: DemoScope.restaurantId,
    weekId: scenario.currentWeekId,
    dayLabel: scenario.openShiftDayLabel,
    daypart: scenario.openShiftDaypart,
    status: 'open',
    businessDate: scenario.currentBusinessDate,
    forecastCovers: openShiftPlan.forecastCovers,
    currentCovers: openCovers,
    scheduledFohHours: openShiftPlan.fohHours,
    scheduledBohHours: openShiftPlan.bohHours,
    currentPPA: openPPA,
    currentCPLH: double.parse(openCPLH.toStringAsFixed(2)),
    currentSPLH: double.parse(openSPLH.toStringAsFixed(2)),
    blendedWage: double.parse(openShiftPlan.blendedWage.toStringAsFixed(2)),
    timeLabel: MockIntegrationReplaySeed.openShiftTimeLabel,
    serviceElapsedLabel:
        MockIntegrationReplaySeed.openShiftServiceElapsedLabel,
    sourceSystem: MockIntegrationReplaySeed.sourceSystem,
    sourceShiftId:
        MockIntegrationReplaySeed.openShiftSourceShiftIdFor(scenario),
    updatedAt: now,
  ));

  // Seed closed dayparts for the open shift's day (whole-day aggregation).
  final currentDayClosed = replay.currentWeekShifts
      .where((s) =>
          s.dayLabel == scenario.openShiftDayLabel && s.status == 'closed')
      .toList();
  for (final s in currentDayClosed) {
    snapshots.add(OpenShiftSnapshot(
      restaurantId: DemoScope.restaurantId,
      weekId: s.weekId,
      dayLabel: s.dayLabel,
      daypart: s.daypart,
      status: 'closed',
      businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel)!,
      forecastCovers: s.forecastCovers,
      currentCovers: s.covers,
      scheduledFohHours: s.scheduledFohHours ?? s.fohHours,
      scheduledBohHours: s.scheduledBohHours ?? s.bohHours,
      currentPPA: s.ppa,
      currentCPLH: s.cplh,
      currentSPLH: s.splh,
      blendedWage: s.blendedWage,
      sourceSystem: s.sourceSystem ?? MockIntegrationReplaySeed.sourceSystem,
      sourceShiftId: MockIntegrationReplaySeed.snapshotSourceShiftId(
        weekId: s.weekId,
        dayLabel: s.dayLabel,
        daypart: s.daypart,
        status: 'closed',
      ),
      updatedAt: now,
    ));
  }

  final batch = db.batch();
  for (final snap in snapshots) {
    batch.insert('open_shift_snapshots', snap.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);
}

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
  final weekKey =
      WeeklyPlanSnapshotPolicy.weekKeyFromSpan(weekStart, weekEnd);

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
  final cycleDayparts =
      await TargetCycleDao(db).getDaypartsForCycle(parentCycle.cycleId);
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
    final iso = '${date.year.toString().padLeft(4, '0')}-'
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
  final dayDayparts = _buildSeedDayDaypartRows(
    cycle: cycle,
    dayRows: dayRows,
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
    forecastCovers: plan.forecastCovers,
    forecastSales: plan.forecastSales,
    requiredFohHours: plan.requiredFohHours,
    requiredBohHours: plan.requiredBohHours,
    theoreticalFohLaborDollars: plan.theoreticalFohLaborDollars,
    theoreticalBohLaborDollars: plan.theoreticalBohLaborDollars,
    coversSource: plan.coversSource,
    salesSource: plan.salesSource,
    generatedAt: now,
    lockedAt: now,
    dayRows: dayRows,
    dayDayparts: dayDayparts,
    wageAtLockTime: wageStamp,
  );

  // Persist via the same map shape WeeklyPlanSnapshotDao.upsertSnapshot
  // writes (day_rows_json, forecast_context_json, metadata, is_active
  // coercions) — inlined here because the DAO can't be reached during
  // _onCreate (it would re-enter the database getter).
  final map = snapshot.toMap();
  final encodedDayRows =
      jsonEncode(map.remove('day_rows') as List<dynamic>);
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
  map['wage_at_lock_time_json'] =
      wageAtLockTimeJson == null ? null : jsonEncode(wageAtLockTimeJson);
  map['day_rows_json'] = encodedDayRows;
  map['forecast_context_json'] =
      forecastContext == null ? null : jsonEncode(forecastContext);
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
      final periodReqFohHours =
          cycleDp.targetCPLH > 0 ? periodCovers / cycleDp.targetCPLH : 0.0;
      final periodReqBohHours =
          cycleDp.targetSPLH > 0 ? periodSales / cycleDp.targetSPLH : 0.0;
      final periodFohDollars = periodReqFohHours * cycle.fohWage;
      final periodBohDollars = periodReqBohHours * cycle.bohWage;
      out.add(WeeklyPlanSnapshotDayDaypart(
        businessDate: dayRow.businessDate,
        servicePeriodId: periodId,
        forecastCovers: periodCovers,
        forecastSales: periodSales,
        requiredFohHours: periodReqFohHours,
        requiredBohHours: periodReqBohHours,
        theoreticalFohDollars: periodFohDollars,
        theoreticalBohDollars: periodBohDollars,
      ));
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
    where: "restaurant_id = ? "
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
    where: "restaurant_id = ? "
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
    where: "restaurant_id = ? "
        "AND status = 'closed' "
        "AND business_date >= ? "
        "AND business_date <= ?",
    whereArgs: [DemoScope.restaurantId, baselineStart, anchorBusinessDate],
  );

  final recentStart = _subtractIsoDays(anchorBusinessDate, 20);
  final recentRows = await db.query(
    'shift_records',
    where: "restaurant_id = ? "
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

/// Seeds a reservation book snapshot for the scenario's open shift.
///
/// Unseated covers scale deterministically with the day's base cover volume.
Future<void> _seedReservationBookSnapshotsFromReplay(
    Database db, MockReplayOutput replay) async {
  final now = nowIsoUtc();
  final scenario = replay.scenario;

  // Scale unseated covers from Friday baseline (72) by day-volume ratio.
  const fridayBaseCovers = 220;
  const fridayUnseatedCovers = 72;
  const fridayUnseatedParties = 18;
  const dayBaseCovers = {
    'Mon': 140, 'Tue': 150, 'Wed': 160, 'Thu': 190,
    'Fri': 220, 'Sat': 230, 'Sun': 110,
  };
  final dayCovers = dayBaseCovers[scenario.openShiftDayLabel] ?? fridayBaseCovers;
  final coverRatio = dayCovers / fridayBaseCovers;
  final unseatedCovers = (fridayUnseatedCovers * coverRatio).round();
  final unseatedParties = (fridayUnseatedParties * coverRatio).round();

  final snapshot = ReservationBookSnapshot(
    restaurantId: DemoScope.restaurantId,
    businessDate: scenario.currentBusinessDate,
    daypart: scenario.openShiftDaypart,
    unseatedCovers: unseatedCovers,
    unseatedPartyCount: unseatedParties,
    sourceSystem: 'demo_reservations',
    sourceServiceId:
        'demo_res_${scenario.openShiftDayLabel.toLowerCase()}_${scenario.openShiftDaypart}',
    updatedAt: now,
  );
  await db.insert('reservation_book_snapshots', snapshot.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<void> _seedDemoRestaurant(Database db) async {
  final now = nowIsoUtc();

  // §2c hierarchy: seed all four demo locations (Downtown / North Loop
  // / Riverside / Harbour) so the scope drawer is a real switcher and
  // both consoles tell the same story. The org tree (corp → regions →
  // district) lives in the operator-web fixture; the mobile side has
  // no SQLite `org_units` table, so multi-location scope is expressed
  // purely as multiple `restaurant_locations` rows. HP #2: same table,
  // no `demo_*` table, no `kDemoMode` reader branch. `ignore` keeps
  // the seed idempotent/deterministic (reseed yields the same rows).
  // Slice A seeds the location rows only — per-location operational
  // data (shifts/weeks/cycle/plan) is Slice C.
  for (final location in DemoScope.locations) {
    await db.insert(
      'restaurant_locations',
      {
        'restaurant_id': location.restaurantId,
        'display_name': location.displayName,
        'business_timezone': location.businessTimezone,
        'created_at': now,
        'updated_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // Seed demo timing config (7.55n.1) for Downtown only —
  // `_seedDemoTimingConfig` is keyed to `DemoScope.restaurantId`, and
  // per-location timing is operational config owned by Slice C / the
  // HP #11 scope-override slice (F), not this foundation slice.
  // Defaults preserve the current fixture-era shape from WeekDayOrder.
  // Guard: table may not exist yet during older upgrade paths.
  if (await _tableExists(db, 'restaurant_timing_configs')) {
    await _seedDemoTimingConfig(db, now);
  }
}

Future<void> _seedDemoTimingConfig(Database db, String now) async {
  final demoServicePeriods = [
    {
      'id': 'lunch',
      'label': 'Lunch',
      'short_label': 'L',
      'sort_order': 1,
      'start_local_time': '11:00',
      'end_local_time': '15:00',
      'rolls_past_midnight': false,
      'applicable_days': [1, 2, 3, 4, 5],
    },
    {
      'id': 'dinner',
      'label': 'Dinner',
      'short_label': 'D',
      'sort_order': 2,
      'start_local_time': '17:00',
      'end_local_time': '23:00',
      'rolls_past_midnight': false,
      'applicable_days': [1, 2, 3, 4, 5, 6, 7],
    },
    {
      'id': 'late_night',
      'label': 'Late Night',
      'short_label': 'LN',
      'sort_order': 3,
      'start_local_time': '23:00',
      'end_local_time': '02:00',
      'rolls_past_midnight': true,
      'applicable_days': [5, 6],
    },
  ];
  // Per-Daypart V1 Slice 1.5: `shift_close_authority` +
  // `local_close_fallback` dropped (operator decision 2026-05-15).
  await db.insert(
    'restaurant_timing_configs',
    {
      'restaurant_id': DemoScope.restaurantId,
      'business_day_start_local_time': '04:00',
      'week_start_day': DateTime.monday,
      'service_period_definitions_json': jsonEncode(demoServicePeriods),
      'created_at': now,
      'updated_at': now,
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}

/// Seeds the demo active profile from the canonical cycle projection.
///
/// The pure `buildActiveTargetProfileFromBaseline(...)` helper remains as a
/// bridge-proof utility for tests, but the live demo/bootstrap database now
/// persists profile authority through a seeded `TargetCycle` and projects the
/// runtime profile from that cycle-backed standard object.
Future<void> _seedDemoActiveTargetProfile(
  Database db, {
  required String businessDate,
  MockReplayOutput? replay,
}) async {
  final profile = await _loadSeedAuthorityProfile(
    db,
    businessDate: businessDate,
    replay: replay,
  );
  await db.insert('active_target_profiles', profile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace);
}

Future<ActiveTargetProfile> _loadSeedAuthorityProfile(
  Database db, {
  required String businessDate,
  MockReplayOutput? replay,
}) async {
  final cycle = await _ensureDemoSeedCycle(
    db,
    businessDate: businessDate,
    replay: replay,
  );
  return TargetCycleActiveTargetProfileProjector.project(cycle);
}

Future<TargetCycle> _ensureDemoSeedCycle(
  Database db, {
  required String businessDate,
  MockReplayOutput? replay,
}) async {
  final existing = await db.query(
    'target_cycles',
    where: 'restaurant_id = ? AND deactivated_at IS NULL',
    whereArgs: [DemoScope.restaurantId],
    orderBy: 'created_at DESC',
    limit: 1,
  );
  if (existing.isNotEmpty) {
    return TargetCycle.fromMap(existing.first);
  }

  final wageRows = await db.query(
    'wage_role_rows',
    where: 'restaurant_id = ?',
    whereArgs: [DemoScope.restaurantId],
  );
  double? fohOverride;
  double? bohOverride;
  if (wageRows.isNotEmpty) {
    fohOverride = _weightedAvgFromRows(wageRows, 'foh');
    bohOverride = _weightedAvgFromRows(wageRows, 'boh');
    if (fohOverride == null || bohOverride == null) {
      fohOverride = null;
      bohOverride = null;
    }
  }

  final cycle = _buildDemoSeedCycle(
    businessDate: businessDate,
    fohWageOverride: fohOverride,
    bohWageOverride: bohOverride,
    replay: replay ?? MockIntegrationReplaySeed.generateForDate(businessDate),
  );
  // Persist through Slice 1's canonical cycle write path so the parent
  // `target_cycles` row AND the per-period `target_cycle_dayparts`
  // child rows land together in one transaction (Design Rule 4). The
  // old raw single-table `db.insert('target_cycles', ...)` wrote only
  // the parent, leaving `cycle.dayparts` unpersisted — every per-period
  // read then fell back to the whole-day pool and the demo showed one
  // identical number for every daypart.
  await TargetCycleDao(db).upsertCycle(cycle);
  return cycle;
}

TargetCycle _buildDemoSeedCycle({
  required String businessDate,
  double? fohWageOverride,
  double? bohWageOverride,
  required MockReplayOutput replay,
}) {
  final candidates = _seedRecommendationCandidates(
    replay,
    businessDate: businessDate,
  );
  final recommendation =
      RecommendedBenchmarkSelectionService.instance.select(candidates);

  // Per-period candidate cover totals over the same calibration-window
  // closed-shift cohort the recommendation engine consumed, so the
  // cover-weighted whole-day pool rollup matches the engine's view of
  // demand mix (Design Rule 4 — pool is the rollup of the period rows).
  final coversByPeriod = <String, int>{};
  for (final c in candidates) {
    coversByPeriod[c.daypart] = (coversByPeriod[c.daypart] ?? 0) + c.covers;
  }

  // Per-period locked rows. The demo MUST always show differentiated
  // targets, so each period prefers its own recommendation cohort stats
  // and otherwise falls back to the deterministic demo band (the same
  // constants stamped onto demo closed shifts). The whole-day scalars
  // are then the cover-weighted rollup of these rows — never the
  // deprecated pooled/union recommendation accessors.
  final dayparts = <TargetCycleDaypart>[];
  for (final periodId in MockIntegrationReplaySeed.demoServicePeriodIds) {
    final stats = recommendation.isInsufficient
        ? null
        : recommendation.perDaypartStats[periodId];
    final coverCount = coversByPeriod[periodId] ?? 0;
    if (stats != null) {
      dayparts.add(TargetCycleDaypart(
        servicePeriodId: periodId,
        targetCPLH: stats.recommendedTargetCPLH,
        targetSPLH: stats.recommendedTargetSPLH,
        targetPPA: stats.recommendedTargetPPA,
        opzFloorCPLH: stats.opzFloorCPLH,
        opzCeilingCPLH: stats.opzCeilingCPLH,
        coverCount: coverCount,
      ));
    } else {
      final band = MockIntegrationReplaySeed.demoDaypartTargetBand(periodId)!;
      dayparts.add(TargetCycleDaypart(
        servicePeriodId: periodId,
        targetCPLH: band.targetCPLH,
        targetSPLH: band.targetSPLH,
        targetPPA: band.targetPPA,
        opzFloorCPLH: band.opzFloorCPLH,
        opzCeilingCPLH: band.opzCeilingCPLH,
        coverCount: coverCount,
      ));
    }
  }

  final pool = TargetCycleDaypartPool.fromDayparts(dayparts);

  return TargetCycle(
    cycleId: 'demo_cycle_$businessDate',
    restaurantId: DemoScope.restaurantId,
    source: TargetCycleSource.recommended,
    effectiveStart: businessDate,
    effectiveEnd: _addIsoDays(businessDate, 59),
    calibrationWindowStart: _addIsoDays(businessDate, -59),
    calibrationWindowEnd: businessDate,
    targetCPLH: pool.targetCPLH,
    targetSPLH: pool.targetSPLH,
    targetPPA: pool.targetPPA,
    fohWage: fohWageOverride ?? MeridianConfig.fohWage,
    bohWage: bohWageOverride ?? MeridianConfig.bohWage,
    opzFloorCPLH: pool.opzFloorCPLH,
    opzCeilingCPLH: pool.opzCeilingCPLH,
    createdAt: nowIsoUtc(),
    dayparts: dayparts,
  );
}

List<BaselineCandidateShift> _seedRecommendationCandidates(
  MockReplayOutput replay, {
  required String businessDate,
}) {
  final startDate = _addIsoDays(businessDate, -59);
  final closedShifts = <ShiftRecord>[
    ...replay.historicalClosedShifts,
    ...replay.currentWeekShifts.where((s) => s.status == 'closed'),
  ];

  return closedShifts
      .where((shift) =>
          shift.businessDate != null &&
          shift.businessDate!.compareTo(startDate) >= 0 &&
          shift.businessDate!.compareTo(businessDate) <= 0)
      .map((shift) => BaselineCandidateShift(
            recordKey: '${shift.weekId}|${shift.dayLabel}|${shift.daypart}',
            weekId: shift.weekId,
            weekLabel: shift.weekId,
            dayLabel: shift.dayLabel,
            daypart: shift.daypart,
            covers: shift.covers,
            cplh: shift.cplh,
            splh: shift.splh,
            ppa: shift.ppa,
            primaryLeverId: shift.normalizedLeverId,
            isSelected: false,
            businessDate: shift.businessDate,
            actualLaborPct: shift.totalLaborPct,
            hasActualLaborPctTruth: shift.hasSourceBackedTotalLaborPct,
          ))
      .toList();
}

/// Weighted average hourly rate from raw DB rows for a given labor bucket.
double? _weightedAvgFromRows(
    List<Map<String, dynamic>> rows, String bucket) {
  final filtered =
      rows.where((r) => r['labor_bucket'] == bucket).toList();
  if (filtered.isEmpty) return null;
  final totalHours =
      filtered.fold<double>(0, (s, r) => s + (r['weighted_hours'] as num).toDouble());
  if (totalHours <= 0) return null;
  final totalDollars = filtered.fold<double>(
      0, (s, r) => s + (r['hourly_rate'] as num).toDouble() * (r['weighted_hours'] as num).toDouble());
  return totalDollars / totalHours;
}

/// Demo-data Slice B (§2g / G7): seed `wage_role_rows` for the demo
/// restaurant so the cycle's blended-wage waterfall is the production
/// `_weightedAvgFromRows` path over real role rows — NOT the
/// `MeridianConfig.fohWage/bohWage` empty-rows fallback in
/// `_ensureDemoSeedCycle`. The seeded FOH/BOH cohorts are weighted to
/// blend to exactly `MeridianConfig.fohWage` (16.50) / `bohWage`
/// (21.35), so the cycle's whole-day scalars are unchanged (existing
/// cycle/pool tests stay green) while the wage authority surface and
/// waterfall now render real, role-level demo evidence. Wage-AXIS
/// levers fire from the per-shift blended-wage deviation engineered in
/// `MockIntegrationReplaySeed._generateShift`, not from these rows.
///
/// HP #2: standard production `wage_role_rows` table, scoped by
/// `restaurant_id = DemoScope.restaurantId`. No `demo_*` table, no
/// `kDemoMode` reader branch.
///
/// Operator-authority safe (HP #11): seeds ONLY when the demo
/// restaurant has zero wage_role_rows (true first-boot / clean demo).
/// If ANY wage row already exists — operator-entered authority, or a
/// prior demo seed — this is a no-op and uses `ConflictAlgorithm.ignore`
/// so it can never overwrite an operator's configured wage. `reseedDemo`
/// never DELETEs `wage_role_rows`, so operator wage authority survives
/// reseed unchanged, and the seed is deterministic/idempotent across
/// reseeds (seed once when empty, skip thereafter).
Future<void> _seedDemoWageRoleRows(Database db) async {
  final existing = await db.query(
    'wage_role_rows',
    where: 'restaurant_id = ?',
    whereArgs: [DemoScope.restaurantId],
    limit: 1,
  );
  if (existing.isNotEmpty) {
    // Operator authority or a prior demo seed already present — never
    // clobber it (HP #11). The demo cohort is a cold-start convenience
    // only.
    return;
  }
  const rows = <Map<String, Object?>>[
    // FOH cohort — weighted blend = (14.50 + 18.50) / 2 = 16.50.
    {
      'role_name': 'Server',
      'labor_bucket': 'foh',
      'hourly_rate': 14.50,
      'weighted_hours': 500.0,
    },
    {
      'role_name': 'Bartender',
      'labor_bucket': 'foh',
      'hourly_rate': 18.50,
      'weighted_hours': 500.0,
    },
    // BOH cohort — weighted blend = (19.35 + 23.35) / 2 = 21.35.
    {
      'role_name': 'Prep Cook',
      'labor_bucket': 'boh',
      'hourly_rate': 19.35,
      'weighted_hours': 500.0,
    },
    {
      'role_name': 'Line Cook',
      'labor_bucket': 'boh',
      'hourly_rate': 23.35,
      'weighted_hours': 500.0,
    },
  ];
  final batch = db.batch();
  for (final r in rows) {
    batch.insert(
      'wage_role_rows',
      {
        'restaurant_id': DemoScope.restaurantId,
        'role_name': r['role_name'],
        'labor_bucket': r['labor_bucket'],
        'hourly_rate': r['hourly_rate'],
        'weighted_hours': r['weighted_hours'],
        'source': 'demo_seed',
        'is_active': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
  await batch.commit(noResult: true);
}

String _addIsoDays(String isoDate, int days) {
  final result = DateTime.parse(isoDate).add(Duration(days: days));
  return '${result.year}-${result.month.toString().padLeft(2, '0')}'
      '-${result.day.toString().padLeft(2, '0')}';
}

// ── Demo-data Slice C — per-location closed history + cycles ───────────────
//
// Today the rich Slice B demo cohort (≥60d closed shifts, week_records,
// an active TargetCycle + per-period dayparts) is seeded for Downtown
// (`DemoScope.restaurantId`) only. The other three §2c locations
// (North Loop / Riverside / Harbour) were empty shells, so the scope
// drawer, multi-location surfaces, and per-location Benchmark/Variance/
// History rendered trivial/empty.
//
// This region seeds the SAME shape of demo data for the 3 non-Downtown
// locations, scoped by each location's `restaurant_id` (HP #4 — never
// cross-write), so every location's dashboard is fully operational and
// switching locations visibly changes the numbers true-to-logic.
//
// HP #2: standard production tables only (`shift_records`,
// `week_records`, `target_cycles`, `target_cycle_dayparts`,
// `active_target_profiles`, `target_profile_versions`, `import_runs`,
// `raw_import_records`). No `demo_*` table, no `kDemoMode` reader
// branch. The generation helpers in `mock_integration_replay_seed.dart`
// are reused read-only (its `MockReplayOutput` shape + the recommendation
// path via `_seedRecommendationCandidates`); that file is NOT modified.

/// Deterministic per-location productivity/volume profile (NO RNG —
/// keyed by the location's index in [DemoScope.locations]).
///
/// Distinctness is layered ON TOP of Slice B's per-shift driver intent
/// WITHOUT changing it: every rate tilt is held strictly below the
/// matching `LaborModel.determineLever` threshold (cplh/splh ±5%,
/// ppa ±3%) and [volume] is applied to BOTH actual and forecast covers,
/// so the per-shift primary lever is identical to Downtown's on every
/// slot. Slice B's driver-mix + per-period differentiation is therefore
/// preserved per location, while covers/sales/dollar-gap volume and the
/// recommendation-derived per-period CPLH/SPLH/PPA differ materially so
/// Benchmark/Variance/History/scope-switch show real differences.
class _DemoLocationProfile {
  const _DemoLocationProfile({
    required this.volume,
    required this.cplh,
    required this.splh,
    required this.ppa,
  });

  /// Lever-neutral covers/sales/hours/$ scale (applied to actual AND
  /// forecast so the covers lever sees zero net deviation).
  final double volume;

  /// CPLH rate tilt — |tilt| < 5% (the `determineLever` cplh threshold)
  /// so a non-cplh-owned slot's cplh stays below threshold and the
  /// owned axis remains the sole `determineLever` candidate.
  final double cplh;

  /// SPLH rate tilt — |tilt| < 5% (the `determineLever` splh threshold).
  final double splh;

  /// PPA rate tilt — |tilt| < 3% (the `determineLever` ppa threshold).
  final double ppa;
}

/// Index aligns 1:1 with [DemoScope.locations]. Index 0 (Downtown) is
/// the identity profile and is never applied — Downtown keeps Slice B's
/// cohort byte-for-byte. North Loop = higher-volume; Riverside = tighter
/// labor (runs leaner hours → higher CPLH); Harbour = lower-volume,
/// looser.
const List<_DemoLocationProfile> _demoLocationProfiles = [
  _DemoLocationProfile(volume: 1.00, cplh: 1.000, splh: 1.000, ppa: 1.000),
  _DemoLocationProfile(volume: 1.22, cplh: 1.045, splh: 1.040, ppa: 1.020),
  _DemoLocationProfile(volume: 0.84, cplh: 0.962, splh: 0.965, ppa: 0.978),
  _DemoLocationProfile(volume: 0.93, cplh: 1.028, splh: 0.972, ppa: 1.012),
];

double _round2(double v) => double.parse(v.toStringAsFixed(2));

/// Scales one base (Downtown) [ShiftRecord] into a per-location row.
///
/// Stored cplh/splh/ppa are the authoritative judged RATES (the Slice B
/// generator stores the constructed rate, not covers ÷ rounded hours),
/// so applying a sub-threshold per-location rate tilt cannot move a
/// non-owned axis past its `determineLever` threshold and the
/// generator-computed [ShiftRecord.primaryLever] stays correct verbatim.
/// Hours scale so covers/sales ÷ hours == the scaled rate; stored labor
/// dollars scale with hours so the blended wage (and thus Slice B's
/// wage-axis levers) is unchanged.
ShiftRecord _scaleShiftForLocation(
  ShiftRecord s,
  String restaurantId,
  _DemoLocationProfile p,
) {
  final covers = (s.covers * p.volume).round().clamp(10, 9999);
  final forecastCovers =
      (s.forecastCovers * p.volume).round().clamp(10, 9999);
  final ppa = _round2(s.ppa * p.ppa);
  final cplh = _round2(s.cplh * p.cplh);
  final splh = _round2(s.splh * p.splh);
  final fohHours = s.fohHours > 0
      ? (s.fohHours * p.volume / p.cplh).round().clamp(1, 999999)
      : s.fohHours;
  final bohHours = s.bohHours > 0
      ? (s.bohHours * p.volume * p.ppa / p.splh).round().clamp(1, 999999)
      : s.bohHours;
  final scheduledFoh = s.scheduledFohHours == null
      ? null
      : (s.scheduledFohHours! * p.volume / p.cplh)
          .round()
          .clamp(1, 999999);
  final scheduledBoh = s.scheduledBohHours == null
      ? null
      : (s.scheduledBohHours! * p.volume * p.ppa / p.splh)
          .round()
          .clamp(1, 999999);
  final fohDollar = (s.storedFohLaborDollar != null && s.fohHours > 0)
      ? s.storedFohLaborDollar! * fohHours / s.fohHours
      : s.storedFohLaborDollar;
  final bohDollar = (s.storedBohLaborDollar != null && s.bohHours > 0)
      ? s.storedBohLaborDollar! * bohHours / s.bohHours
      : s.storedBohLaborDollar;

  return ShiftRecord(
    restaurantId: restaurantId,
    weekId: s.weekId,
    dayLabel: s.dayLabel,
    daypart: s.daypart,
    status: s.status,
    covers: covers,
    forecastCovers: forecastCovers,
    ppa: ppa,
    cplh: cplh,
    splh: splh,
    fohHours: fohHours,
    bohHours: bohHours,
    theoreticalLaborPct: s.theoreticalLaborPct,
    primaryLever: s.primaryLever,
    scheduledFohHours: scheduledFoh,
    scheduledBohHours: scheduledBoh,
    storedFohLaborDollar: fohDollar,
    storedBohLaborDollar: bohDollar,
    sourceSystem: s.sourceSystem,
    businessDate: s.businessDate,
    businessTimingProfileId: s.businessTimingProfileId,
    businessTimingProfileVersionId: s.businessTimingProfileVersionId,
    servicePeriodKey: s.servicePeriodKey,
    daypartTargetCPLH: s.daypartTargetCPLH,
    daypartTargetSPLH: s.daypartTargetSPLH,
    daypartTargetPPA: s.daypartTargetPPA,
    daypartOpzFloorCPLH: s.daypartOpzFloorCPLH,
    daypartOpzCeilingCPLH: s.daypartOpzCeilingCPLH,
  );
}

/// Scales one base (Downtown) week-record row map into a per-location
/// row map. Operates on the serialized map (not the typed model) so the
/// `part` file needs no extra import. Extensive aggregates scale with
/// volume; intensive rates scale with the matching rate tilt; locked
/// targets are stamped from the per-location cycle's projected profile
/// (the Downtown-scoped `_backfillLockedTargets` never touches these
/// restaurant_ids).
Map<String, dynamic> _scaleWeekMapForLocation(
  Map<String, dynamic> w,
  String restaurantId,
  _DemoLocationProfile p,
  ActiveTargetProfile profile,
  String calibStart,
  String calibEnd,
) {
  double n(Object? v) => (v as num).toDouble();
  double? nn(Object? v) => v == null ? null : (v as num).toDouble();
  return {
    ...w,
    'id': null,
    'restaurant_id': restaurantId,
    'total_covers': (n(w['total_covers']) * p.volume).round(),
    'forecast_covers': (n(w['forecast_covers']) * p.volume).round(),
    'total_foh_hours':
        (n(w['total_foh_hours']) * p.volume / p.cplh).round(),
    'total_boh_hours':
        (n(w['total_boh_hours']) * p.volume * p.ppa / p.splh).round(),
    'avg_ppa': _round2(n(w['avg_ppa']) * p.ppa),
    'avg_cplh': _round2(n(w['avg_cplh']) * p.cplh),
    'dollar_gap': n(w['dollar_gap']) * p.volume,
    'target_source_type': profile.sourceType,
    'target_cplh': profile.targetCPLH,
    'target_splh': profile.targetSPLH,
    'target_ppa': profile.targetPPA,
    'target_foh_wage': profile.fohWage,
    'target_boh_wage': profile.bohWage,
    'theoretical_foh_labor_pct': profile.theoreticalFohLaborPct,
    'theoretical_boh_labor_pct': profile.theoreticalBohLaborPct,
    'month_dollar_impact': nn(w['month_dollar_impact']) == null
        ? null
        : nn(w['month_dollar_impact'])! * p.volume,
    'sixty_day_dollar_impact': nn(w['sixty_day_dollar_impact']) == null
        ? null
        : nn(w['sixty_day_dollar_impact'])! * p.volume,
    'target_calibration_window_start': calibStart,
    'target_calibration_window_end': calibEnd,
  };
}

/// Per-location variant of [_buildDemoSeedCycle] — same canonical
/// `TargetCycleDaypartPool.fromDayparts` rollup path (Design Rule 4),
/// parameterized by `restaurantId`. The recommendation engine consumes
/// THIS location's scaled closed cohort, so each location's per-period
/// targets are differentiated true-to-logic, not cloned.
TargetCycle _buildLocationSeedCycle({
  required String restaurantId,
  required String businessDate,
  required MockReplayOutput replay,
}) {
  final candidates =
      _seedRecommendationCandidates(replay, businessDate: businessDate);
  final recommendation =
      RecommendedBenchmarkSelectionService.instance.select(candidates);

  final coversByPeriod = <String, int>{};
  for (final c in candidates) {
    coversByPeriod[c.daypart] = (coversByPeriod[c.daypart] ?? 0) + c.covers;
  }

  final dayparts = <TargetCycleDaypart>[];
  for (final periodId in MockIntegrationReplaySeed.demoServicePeriodIds) {
    final stats = recommendation.isInsufficient
        ? null
        : recommendation.perDaypartStats[periodId];
    final coverCount = coversByPeriod[periodId] ?? 0;
    if (stats != null) {
      dayparts.add(TargetCycleDaypart(
        servicePeriodId: periodId,
        targetCPLH: stats.recommendedTargetCPLH,
        targetSPLH: stats.recommendedTargetSPLH,
        targetPPA: stats.recommendedTargetPPA,
        opzFloorCPLH: stats.opzFloorCPLH,
        opzCeilingCPLH: stats.opzCeilingCPLH,
        coverCount: coverCount,
      ));
    } else {
      final band =
          MockIntegrationReplaySeed.demoDaypartTargetBand(periodId)!;
      dayparts.add(TargetCycleDaypart(
        servicePeriodId: periodId,
        targetCPLH: band.targetCPLH,
        targetSPLH: band.targetSPLH,
        targetPPA: band.targetPPA,
        opzFloorCPLH: band.opzFloorCPLH,
        opzCeilingCPLH: band.opzCeilingCPLH,
        coverCount: coverCount,
      ));
    }
  }

  final pool = TargetCycleDaypartPool.fromDayparts(dayparts);

  return TargetCycle(
    cycleId: 'demo_cycle_${restaurantId}_$businessDate',
    restaurantId: restaurantId,
    source: TargetCycleSource.recommended,
    effectiveStart: businessDate,
    effectiveEnd: _addIsoDays(businessDate, 59),
    calibrationWindowStart: _addIsoDays(businessDate, -59),
    calibrationWindowEnd: businessDate,
    targetCPLH: pool.targetCPLH,
    targetSPLH: pool.targetSPLH,
    targetPPA: pool.targetPPA,
    fohWage: MeridianConfig.fohWage,
    bohWage: MeridianConfig.bohWage,
    opzFloorCPLH: pool.opzFloorCPLH,
    opzCeilingCPLH: pool.opzCeilingCPLH,
    createdAt: nowIsoUtc(),
    dayparts: dayparts,
  );
}

/// Seeds the SAME shape of demo data Downtown has (closed shift_records
/// ≥60d, week_records, an active target_cycles + target_cycle_dayparts,
/// active_target_profiles, target_profile_versions,
/// import_runs/raw_import_records) for the 3 non-Downtown demo
/// locations, scoped by each location's `restaurant_id` (HP #4 — no
/// cross-write).
///
/// Idempotent + deterministic: the table-wide deletes in
/// `reseedMockReplayForBusinessDate` clear all locations before reseed,
/// and the per-location cycle mirrors `_ensureDemoSeedCycle`
/// reuse-if-present semantics (the advance path preserves locked
/// cycles). All variation derives from constant per-location factors +
/// the deterministic base replay, so two reseeds are byte-identical.
Future<void> _seedAdditionalLocationsFromReplay(
  Database db,
  MockReplayOutput baseReplay,
  String now,
  String baseImportRunId,
) async {
  final businessDate = baseReplay.scenario.currentBusinessDate;
  final locations = DemoScope.locations;
  for (var i = 1; i < locations.length; i++) {
    final restaurantId = locations[i].restaurantId;
    final profile = _demoLocationProfiles[
        i < _demoLocationProfiles.length
            ? i
            : _demoLocationProfiles.length - 1];

    final scaledHistorical = baseReplay.historicalClosedShifts
        .map((s) => _scaleShiftForLocation(s, restaurantId, profile))
        .toList();
    final scaledCurrent = baseReplay.currentWeekShifts
        .map((s) => _scaleShiftForLocation(s, restaurantId, profile))
        .toList();

    final perLocReplay = MockReplayOutput(
      historicalClosedShifts: scaledHistorical,
      currentWeekShifts: scaledCurrent,
      weekRecords: baseReplay.weekRecords,
      scenario: baseReplay.scenario,
    );

    // Mirror `_ensureDemoSeedCycle` idempotency: reuse an existing
    // active per-location cycle (advance path preserves locked cycles)
    // else build deterministically from this location's scaled closed
    // cohort through Slice 1's canonical write path (parent + per-period
    // child rows in one txn).
    final dao = TargetCycleDao(db);
    var cycle = await dao.getActiveCycle(restaurantId);
    if (cycle == null) {
      cycle = _buildLocationSeedCycle(
        restaurantId: restaurantId,
        businessDate: businessDate,
        replay: perLocReplay,
      );
      await dao.upsertCycle(cycle);
    }

    final atProfile =
        TargetCycleActiveTargetProfileProjector.project(cycle);
    await db.insert('active_target_profiles', atProfile.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);

    final versionId = 'compat_${restaurantId}_v8_backfill';
    await db.insert('target_profile_versions', {
      'target_profile_version_id': versionId,
      'target_profile_id': atProfile.targetProfileId,
      'restaurant_id': restaurantId,
      'source_type': atProfile.sourceType,
      'target_cplh': atProfile.targetCPLH,
      'target_splh': atProfile.targetSPLH,
      'target_ppa': atProfile.targetPPA,
      'foh_wage': atProfile.fohWage,
      'boh_wage': atProfile.bohWage,
      'opz_floor_cplh': atProfile.opzFloorCPLH,
      'opz_ceiling_cplh': atProfile.opzCeilingCPLH,
      'theoretical_foh_labor_pct': atProfile.theoreticalFohLaborPct,
      'theoretical_boh_labor_pct': atProfile.theoreticalBohLaborPct,
      'theoretical_labor_pct': atProfile.theoreticalLaborPct,
      'created_at': nowIsoUtc(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    // Stamp whole-day locked targets onto the scaled rows.
    // `withLockedTargetDefaults` fills only the null whole-day fields
    // and preserves the generator's per-period daypart stamps
    // (Design Rule 2 — null daypart stamps are never substituted).
    ShiftRecord stamp(ShiftRecord r) => r.withLockedTargetDefaults(
          defaultTargetCPLH: atProfile.targetCPLH,
          defaultTargetSPLH: atProfile.targetSPLH,
          defaultTargetPPA: atProfile.targetPPA,
          defaultFohWage: atProfile.fohWage,
          defaultBohWage: atProfile.bohWage,
          defaultOpzFloorCPLH: atProfile.opzFloorCPLH,
          defaultOpzCeilingCPLH: atProfile.opzCeilingCPLH,
          defaultTheoreticalFohLaborPct:
              atProfile.theoreticalFohLaborPct,
          defaultTheoreticalBohLaborPct:
              atProfile.theoreticalBohLaborPct,
          defaultTargetProfileId: atProfile.targetProfileId,
          defaultTargetProfileVersionId: versionId,
          defaultTargetSourceType: atProfile.sourceType,
        );

    final batch = db.batch();
    for (final s in scaledCurrent) {
      batch.insert('shift_records', stamp(s).toMap()..remove('id'));
    }
    for (final s in scaledHistorical) {
      batch.insert('shift_records', stamp(s).toMap()..remove('id'));
    }
    for (final w in baseReplay.weekRecords) {
      final scaledW = _scaleWeekMapForLocation(
        w.toMap(),
        restaurantId,
        profile,
        atProfile,
        cycle.calibrationWindowStart,
        cycle.calibrationWindowEnd,
      );
      batch.insert('week_records', scaledW,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);

    final importRunId = '${baseImportRunId}_$restaurantId';
    await db.insert(
      'import_runs',
      ImportRun(
        importRunId: importRunId,
        restaurantId: restaurantId,
        mode: 'mock_pos_labor_replay',
        startedAt: now,
        completedAt: now,
        status: 'completed',
      ).toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );

    final allShifts = [...scaledCurrent, ...scaledHistorical];
    final rawBatch = db.batch();
    for (var j = 0; j < allShifts.length; j++) {
      final s = allShifts[j];
      final payloadJson = jsonEncode(stamp(s).toMap()..remove('id'));
      final hash = _deterministicHash(payloadJson);
      rawBatch.insert(
        'raw_import_records',
        RawImportRecord(
          rawImportId: '${importRunId}_shift_$j',
          importRunId: importRunId,
          restaurantId: restaurantId,
          sourceType: 'mock_pos_labor_replay',
          sourceEntityType: 'shift_record',
          sourceEntityId: '${s.weekId}_${s.dayLabel}_${s.daypart}',
          payloadHash: hash,
          businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel)!,
          receivedAt: now,
          status: 'applied',
          payloadJson: payloadJson,
        ).toMap(),
      );
    }
    await rawBatch.commit(noResult: true);
  }
}

Future<void> _seedDemoDataFromReplay(Database db, MockReplayOutput replay) async {
  final now = DateTime.now().toIso8601String();
  final importRunId = 'mock_replay_seed_${now.replaceAll(RegExp(r'[^0-9]'), '')}';

  // Per-Daypart V1 (Slice 1, Decision 4) — pre-production reseed wipes
  // demo-scope closed shifts before regenerating so newly added
  // timing-provenance / per-period target stamp columns are populated
  // uniformly across every row. There is no "transition period" /
  // "dual shapes" / "retroactive re-grading" concern because the demo
  // restaurant has no real operator data to preserve. Production
  // behavior is "closed truth retains its stamp from close time"
  // (Promise 2) — that rule applies only to non-demo scopes.
  await db.delete(
    'shift_records',
    where: 'restaurant_id = ?',
    whereArgs: [DemoScope.restaurantId],
  );

  final batch = db.batch();

  for (final s in replay.currentWeekShifts) {
    final map = s.toMap()..remove('id');
    map['restaurant_id'] = DemoScope.restaurantId;
    batch.insert('shift_records', map);
  }
  for (final s in replay.historicalClosedShifts) {
    final map = s.toMap()..remove('id');
    map['restaurant_id'] = DemoScope.restaurantId;
    batch.insert('shift_records', map);
  }
  for (final w in replay.weekRecords) {
    final map = w.toMap()..remove('id');
    map['restaurant_id'] = DemoScope.restaurantId;
    batch.insert('week_records', map,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await batch.commit(noResult: true);

  // Record a mock_pos_labor_replay import run
  final importRun = ImportRun(
    importRunId: importRunId,
    restaurantId: DemoScope.restaurantId,
    mode: 'mock_pos_labor_replay',
    startedAt: now,
    completedAt: now,
    status: 'completed',
  );
  await db.insert('import_runs', importRun.toMap());

  // Insert raw import records for seeded shifts
  final allShifts = [
    ...replay.currentWeekShifts,
    ...replay.historicalClosedShifts,
  ];
  final rawBatch = db.batch();
  for (int i = 0; i < allShifts.length; i++) {
    final s = allShifts[i];
    final payloadJson = jsonEncode(s.toMap()..remove('id'));
    final hash = _deterministicHash(payloadJson);
    final record = RawImportRecord(
      rawImportId: '${importRunId}_shift_$i',
      importRunId: importRunId,
      restaurantId: DemoScope.restaurantId,
      sourceType: 'mock_pos_labor_replay',
      sourceEntityType: 'shift_record',
      sourceEntityId: '${s.weekId}_${s.dayLabel}_${s.daypart}',
      payloadHash: hash,
      businessDate: _businessDateFromWeekDay(s.weekId, s.dayLabel)!,
      receivedAt: now,
      status: 'applied',
      payloadJson: payloadJson,
    );
    rawBatch.insert('raw_import_records', record.toMap());
  }
  await rawBatch.commit(noResult: true);

  // Demo-data Slice C — after Downtown's cohort lands, seed the SAME
  // shape (scoped per `restaurant_id`, HP #4) for the 3 non-Downtown
  // §2c locations so the scope drawer is a real switcher and every
  // location's dashboard is fully operational. Called from BOTH the
  // cold-boot seed path and the reseed/advance path (this function is
  // the single per-location seed-orchestration seam).
  await _seedAdditionalLocationsFromReplay(db, replay, now, importRunId);

  // Demo-data Slice E pt2 (Gap G6) — arm the mobile-fold
  // `demo_mode_state` source so Settings → Integrations + the
  // `DemoModeBanner` render the per-(operator, location, category)
  // vendor demo state, consistent with pt1's (#800) fixture. Single
  // call site for this hook; both demo-seed paths (`_onCreate` cold
  // boot AND reseed/advance) flow through `_seedDemoDataFromReplay`,
  // mirroring the `_seedAdditionalLocationsFromReplay` seam above.
  await _seedDemoVendorIntegrationModeStateSource();
}

/// Demo-data Slice E pt2 — mobile-fold `demo_mode_state` seed hook.
///
/// HP #2 (CLAUDE.md → Demo Mode): the mobile fold + banner read ONLY
/// `DemoModeStateNotifier`, which is fed by an injected
/// `SyncProxyClient.fetchDemoModeStates`. The demo flavor bootstraps
/// with no proxy, so there is no SQLite `demo_mode_state` table to
/// write and inventing a `demo_*` table is forbidden. Per the pt2
/// prompt (Required #3) the "hook" instead WIRES pt1's fixture into the
/// mobile notifier's demo source — the notifier-side analogue of
/// `MockReplayDataSourceProvider`. This is a WRITER-side source swap,
/// not a `kDemoMode` reader branch: every reader resolves the records
/// through the SAME code path in demo and prod.
///
/// `_seedDemoDataFromReplay` runs in BOTH the demo flavor and ordinary
/// (production) `_onCreate` because the demo restaurant rows coexist in
/// the same tables (HP #2). The demo source must therefore arm ONLY in
/// the demo flavor; the gate below is the `kDemoMode` /
/// `FORGE_FLOW_DEMO_MODE` WRITER-side switch (HP #2 explicitly endorses
/// `kDemoMode` as a writer-side switch — used here in the seeder, not a
/// reader). In production the gate is false → the source is never armed
/// → `DemoVendorIntegrationDemoModeSource.maybeClient()` stays null →
/// the notifier resolves exactly the bootstrap proxy it always has, so
/// the production read path is byte-unchanged.
///
/// Determinism + HP #4: `armForDemoSeed` materializes and asserts the
/// canonical pt1 records for the 4 `DemoScope.locations` ×
/// {pos, labor, reservation} for the demo operator — pure, no RNG, no
/// `DateTime.now()`, no DB write, no cross-location/operator leakage.
/// Two reseeds are byte-identical.
Future<void> _seedDemoVendorIntegrationModeStateSource() async {
  if (!_kDemoModeWriterSwitch) return;
  DemoVendorIntegrationDemoModeSource.armForDemoSeed(
    demoLocationIds: <String>[
      for (final location in DemoScope.locations) location.restaurantId,
    ],
  );
}

/// `kDemoMode` / `FORGE_FLOW_DEMO_MODE` WRITER-side switch — the SAME
/// pair `main_forgeflow.dart`'s `_demoAuthEnabled` and the demo
/// `SettingsScreen` carve-outs use. Compile-time const; unset in
/// production builds so `_seedDemoVendorIntegrationModeStateSource` is
/// a no-op there and the demo source never arms.
const bool _kDemoModeWriterSwitch =
    bool.fromEnvironment('kDemoMode') ||
    bool.fromEnvironment('FORGE_FLOW_DEMO_MODE');

String _deterministicHash(String payload) {
  int hash = 0x811c9dc5;
  for (int i = 0; i < payload.length; i++) {
    hash ^= payload.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

Future<void> _ensureDemoRestaurant(Database db) async {
  // Unconditional + idempotent. A Downtown-only `existing.isEmpty` guard
  // would skip backfilling North Loop / Riverside / Harbour on any demo
  // DB that predates the multi-location build (Downtown already exists →
  // guard true → 3 locations never seeded). `_seedDemoRestaurant` uses
  // ConflictAlgorithm.ignore so re-running is a no-op for present rows
  // and backfills only the missing ones.
  await _seedDemoRestaurant(db);
}

