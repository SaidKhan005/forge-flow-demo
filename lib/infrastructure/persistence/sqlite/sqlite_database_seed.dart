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
  final cycle = TargetCycle.fromMap(cycleRows.first);

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
  );

  // Persist via the same map shape WeeklyPlanSnapshotDao.upsertSnapshot
  // writes (day_rows_json, forecast_context_json, metadata, is_active
  // coercions) — inlined here because the DAO can't be reached during
  // _onCreate (it would re-enter the database getter).
  final map = snapshot.toMap();
  final encodedDayRows =
      jsonEncode(map.remove('day_rows') as List<dynamic>);
  final forecastContext = map.remove('forecast_context');
  // Per-Daypart V1 (Slice 1): the seed's snapshot model now also
  // carries `day_dayparts` and `wage_at_lock_time_json`. Strip
  // `day_dayparts` from the parent insert (it's persisted into the
  // child table by the DAO at runtime; the seed path doesn't yet
  // need to persist them because the seed never sets them) and
  // JSON-encode the wage stamp for its dedicated column.
  map.remove('day_dayparts');
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
  await db.insert('restaurant_locations', {
    'restaurant_id': DemoScope.restaurantId,
    'display_name': DemoScope.displayName,
    'business_timezone': DemoScope.businessTimezone,
    'created_at': now,
    'updated_at': now,
  });

  // Seed demo timing config (7.55n.1).
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

String _addIsoDays(String isoDate, int days) {
  final result = DateTime.parse(isoDate).add(Duration(days: days));
  return '${result.year}-${result.month.toString().padLeft(2, '0')}'
      '-${result.day.toString().padLeft(2, '0')}';
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
}

String _deterministicHash(String payload) {
  int hash = 0x811c9dc5;
  for (int i = 0; i < payload.length; i++) {
    hash ^= payload.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

Future<void> _ensureDemoRestaurant(Database db) async {
  final existing = await db.query('restaurant_locations',
      where: 'restaurant_id = ?', whereArgs: [DemoScope.restaurantId]);
  if (existing.isEmpty) {
    await _seedDemoRestaurant(db);
  }
}

