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

/// True when a demo location's vendor fixture has ZERO connected
/// categories ("none connected / awaiting first connection" — spec
/// §D.2/§D.3; today exactly Harbour, `DemoScope.harbourRestaurantId`).
///
/// SEED-ONLY honest-EMPTY (Metric Honesty, operator decision
/// 2026-05-16): a location with nothing connected must render the
/// existing "awaiting first connection" empty states — NOT fabricated
/// numbers. The lowest-risk fix is to NOT write that location's
/// operational/historical cohort (shift/week/snapshot/plan/cycle/
/// import/notification rows) so every reader honest-degrades to its
/// existing empty UI with NO production reader/formula change. The
/// location's `restaurant_locations` row (scope drawer) and its
/// `demo_mode_state` / vendor-fixture rows (demo banners) are still
/// seeded — only the operational/historical data is suppressed.
///
/// Generalized off [DemoVendorIntegrationStateFixture] connection state,
/// NOT a hardcoded "if harbour": any demo location whose fixture has
/// zero connected categories is honest-empty (Riverside is all-3
/// connected→live, North Loop POS-only, Downtown all-3 mixed, so today
/// only Harbour matches).
///
/// HP #2: writer/seed-side only. No `demo_*` table, no `kDemoMode`
/// reader branch — the readers are byte-unchanged and resolve demo and
/// prod identically; they simply find no rows for this scope.
bool _isNoneConnectedDemoLocation(String restaurantId) =>
    DemoVendorIntegrationStateFixture.isNoneConnected(restaurantId);

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

/// Builds the current-week open/projected/closed `open_shift_snapshots`
/// for ONE location from its already-seeded current-week shift set.
///
/// This is the single source of truth for "what Downtown's live week
/// looks like" — `_seedOpenShiftSnapshotsFromReplay` calls it for
/// Downtown with the base replay, and the per-location operational
/// envelope (`_seedHistoricalOpenShiftSnapshotsFromReplay`) calls it for
/// each non-Downtown location with that location's volume/wage/timing
/// scaled current-week shifts (`_envelopeShiftsForLocation`). Because the
/// open shift's in-progress covers/CPLH/SPLH are recomputed from the
/// passed-in (scaled) covers/hours, every location's live shift carries
/// its OWN per-location figures — not a clone of Downtown's — while the
/// row SHAPE is byte-identical to how Downtown's was always built.
///
/// `scenario` (week id / business date / open day+daypart) is
/// location-independent: the today-anchored calendar is shared, only the
/// metrics differ. [currentWeekShifts] must be the location's own scaled
/// rows so the open/projected/closed values are this location's.
///
/// Honest-degrade (Metric Honesty / Design Rule 2): a (day, daypart) the
/// scenario does not serve has no shift in [currentWeekShifts] and so no
/// fabricated row; the firstWhere below only resolves the open slot the
/// scenario explicitly designates.
List<OpenShiftSnapshot> _buildCurrentWeekOpenShiftSnapshots({
  required String restaurantId,
  required List<ShiftRecord> currentWeekShifts,
  required MockReplayScenario scenario,
  required String now,
}) {
  final projectedShifts =
      currentWeekShifts.where((s) => s.isProjected).toList();

  final snapshots = <OpenShiftSnapshot>[];

  final openDaypart = scenario.openShiftDaypart;

  for (final s in projectedShifts) {
    // Skip the open-shift slot — we'll insert the open snapshot for it.
    // QA fix: when the clock-derived scenario has NO open period
    // (`openDaypart == null`), nothing is skipped — every upcoming
    // current-day/future period is honestly `projected` (no fabricated
    // "live" period).
    if (openDaypart != null &&
        s.dayLabel == scenario.openShiftDayLabel &&
        s.daypart == openDaypart) {
      continue;
    }

    snapshots.add(OpenShiftSnapshot(
      restaurantId: restaurantId,
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

  // One current open shift — ONLY when the clock-derived scenario has a
  // period in progress. QA fix: when `openDaypart == null` (e.g. Sat
  // 09:25, before Lunch opens) NO open snapshot is written, so the Shift
  // card honestly shows forecast-only projected periods instead of a
  // not-yet-occurred Dinner displaying live whole-day numbers. The
  // in-progress covers + progress labels come from the clock-derived
  // scenario (`openProgressFraction` / `openTimeLabel` /
  // `openServiceElapsedLabel`), never the old fixed 0.63 / 7:45 PM /
  // 3h 15m fabrication.
  final openSourceShiftId =
      MockIntegrationReplaySeed.openShiftSourceShiftIdFor(scenario);

  if (openDaypart != null && openSourceShiftId != null) {
    final progress = scenario.openProgressFraction ??
        MockIntegrationReplaySeed.openProgressFraction;
    final matches = currentWeekShifts.where(
      (s) =>
          s.dayLabel == scenario.openShiftDayLabel &&
          s.daypart == openDaypart,
    );
    if (matches.isNotEmpty) {
      final openShiftPlan = matches.first;
      final openCovers = (openShiftPlan.forecastCovers * progress).round();
      final openPPA = openShiftPlan.ppa;
      final openSales = openCovers * openPPA;
      final openCPLH = openShiftPlan.fohHours > 0
          ? openCovers / openShiftPlan.fohHours
          : 0.0;
      final openSPLH = openShiftPlan.bohHours > 0
          ? openSales / openShiftPlan.bohHours
          : 0.0;

      snapshots.add(OpenShiftSnapshot(
        restaurantId: restaurantId,
        weekId: scenario.currentWeekId,
        dayLabel: scenario.openShiftDayLabel,
        daypart: openDaypart,
        status: 'open',
        businessDate: scenario.currentBusinessDate,
        forecastCovers: openShiftPlan.forecastCovers,
        currentCovers: openCovers,
        scheduledFohHours: openShiftPlan.fohHours,
        scheduledBohHours: openShiftPlan.bohHours,
        currentPPA: openPPA,
        currentCPLH: double.parse(openCPLH.toStringAsFixed(2)),
        currentSPLH: double.parse(openSPLH.toStringAsFixed(2)),
        blendedWage:
            double.parse(openShiftPlan.blendedWage.toStringAsFixed(2)),
        timeLabel: scenario.openTimeLabel ??
            MockIntegrationReplaySeed.openShiftTimeLabel,
        serviceElapsedLabel: scenario.openServiceElapsedLabel ??
            MockIntegrationReplaySeed.openShiftServiceElapsedLabel,
        sourceSystem: MockIntegrationReplaySeed.sourceSystem,
        sourceShiftId: openSourceShiftId,
        updatedAt: now,
      ));
    }
  }

  // Seed closed dayparts for the open shift's day (whole-day aggregation).
  final currentDayClosed = currentWeekShifts
      .where((s) =>
          s.dayLabel == scenario.openShiftDayLabel && s.status == 'closed')
      .toList();
  for (final s in currentDayClosed) {
    snapshots.add(OpenShiftSnapshot(
      restaurantId: restaurantId,
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

  return snapshots;
}

/// Seeds Downtown's open/projected shift snapshots for the current week
/// from replay output.
///
/// The open shift is determined by [replay.scenario], not hardcoded to
/// Friday dinner. Closed same-day dayparts and projected future dayparts
/// are derived from the scenario. Non-Downtown locations get the SAME
/// shape via `_seedHistoricalOpenShiftSnapshotsFromReplay` (it calls the
/// shared `_buildCurrentWeekOpenShiftSnapshots` with each location's
/// scaled current-week shifts) so every demo location has its own live
/// current-week shift — no longer Downtown-only.
Future<void> _seedOpenShiftSnapshotsFromReplay(
    Database db, MockReplayOutput replay) async {
  final snapshots = _buildCurrentWeekOpenShiftSnapshots(
    restaurantId: DemoScope.restaurantId,
    currentWeekShifts: replay.currentWeekShifts,
    scenario: replay.scenario,
    now: nowIsoUtc(),
  );

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

  // QA fix / honest-degrade: when the clock-derived scenario has NO
  // period in progress (`openShiftDaypart == null`, e.g. Sat 09:25),
  // there is no live unseated reservation book to seed for an
  // open service. The forward reservation envelope
  // (`_seedForwardReservationEnvelopeFromReplay`) still seeds every
  // current-week projected/open cell across all locations, so forward
  // coverage is unaffected.
  final scenarioDaypart = scenario.openShiftDaypart;
  if (scenarioDaypart == null) return;

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
    daypart: scenarioDaypart,
    unseatedCovers: unseatedCovers,
    unseatedPartyCount: unseatedParties,
    sourceSystem: 'demo_reservations',
    sourceServiceId:
        'demo_res_${scenario.openShiftDayLabel.toLowerCase()}_$scenarioDaypart',
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

/// The demo restaurant's business-day start (restaurant-local). Shared
/// by [_seedDemoTimingConfig] and [resolveDemoOpenPeriod] so the seeded
/// timing config and the clock-derived open-period selection use ONE
/// business-date basis (Time Guardrails — business date is the anchor).
const String _kDemoBusinessDayStartLocalTime = '04:00';

/// The demo restaurant's three service periods (business default,
/// applied to Downtown + every inheriting location).
///
/// QA fix (Change B): `lunch.applicable_days` now includes Sat (6) and
/// Sun (7) — weekends serve a lunch/brunch like a real restaurant, so
/// the per-daypart phase resolver treats weekend Lunch as a real,
/// applicable period (no longer "not applicable → always Opens at").
/// Kept byte-equal to [_kDemoBusinessDefaultServicePeriods] (the
/// East-Region override input) so the HP #11 diff stays a single axis
/// (week-start only). SINGLE source of truth for both the seeded
/// `service_period_definitions_json` and [resolveDemoOpenPeriod].
const List<Map<String, Object?>> _kDemoDowntownServicePeriods =
    <Map<String, Object?>>[
  {
    'id': 'lunch',
    'label': 'Lunch',
    'short_label': 'L',
    'sort_order': 1,
    'start_local_time': '11:00',
    'end_local_time': '15:00',
    'rolls_past_midnight': false,
    'applicable_days': [1, 2, 3, 4, 5, 6, 7],
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

Future<void> _seedDemoTimingConfig(Database db, String now) async {
  // Per-Daypart V1 Slice 1.5: `shift_close_authority` +
  // `local_close_fallback` dropped (operator decision 2026-05-15).
  await db.insert(
    'restaurant_timing_configs',
    {
      'restaurant_id': DemoScope.restaurantId,
      'business_day_start_local_time': _kDemoBusinessDayStartLocalTime,
      'week_start_day': DateTime.monday,
      'service_period_definitions_json':
          jsonEncode(_kDemoDowntownServicePeriods),
      'created_at': now,
      'updated_at': now,
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}

/// Parses an `HH:mm` clock string to minutes-since-midnight.
///
/// MUST mirror `_parseHm` in
/// `lib/state/shift_service_period_notifier.dart` (the canonical
/// per-daypart phase resolver). Replicated here (not imported) so
/// `lib/infrastructure` does not depend on `lib/state`; the parity
/// guard is this comment + the shared [_kDemoDowntownServicePeriods].
int? _demoParseHm(String hm) {
  final parts = hm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// Derives the demo restaurant's open service period from a
/// restaurant-local [localNow] at seed time — the QA fix for the
/// device-reproduced defect (Sat ~09:25 showed Dinner "live" because
/// the seed hardcoded `openShiftDaypart='dinner'`).
///
/// This MUST mirror `resolveActiveServicePeriodId` /
/// `resolveServicePeriodPhase` in
/// `lib/state/shift_service_period_notifier.dart:733-890` (the canonical
/// phase resolver cited by the per-daypart contract): business-date
/// weekday via [BusinessDateResolver] for applicability, inclusive-end
/// time-of-day comparison, and the `rollsPastMidnight` rule that a
/// non-active rolling period is always *future* (not closed). It is
/// replicated rather than imported to keep `lib/infrastructure` off
/// `lib/state`; both consume the SAME period defs
/// ([_kDemoDowntownServicePeriods]) so they cannot drift. Do not
/// diverge from the resolver without updating both.
///
/// Returns:
///  * the single period IN PROGRESS at [localNow] as `openDaypart`
///    with a real progress fraction + wall-clock / elapsed labels;
///  * `openDaypart == null` when NO period is in progress (honest — no
///    open shift; upcoming periods are projected, e.g. 09:25 < Lunch);
///  * `currentDayClosedPeriods` = periods applicable on the business
///    day that already ended (→ seeded `closed` with actuals — closed
///    truth is not rewritten).
OpenPeriodResolution resolveDemoOpenPeriod({required DateTime localNow}) {
  final defs = _kDemoDowntownServicePeriods
      .map(ServicePeriodDefinition.fromMap)
      .toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  final businessDateIso = BusinessDateResolver.resolve(
    localTimestamp: localNow,
    businessDayStartLocalTime: _kDemoBusinessDayStartLocalTime,
  );
  final businessWeekday = DateTime.parse(businessDateIso).weekday;
  final tod = Duration(
    hours: localNow.hour,
    minutes: localNow.minute,
    seconds: localNow.second,
    milliseconds: localNow.millisecond,
    microseconds: localNow.microsecond,
  );

  ServicePeriodDefinition? active;
  for (final d in defs) {
    if (!d.applicableDays.contains(businessWeekday)) continue;
    final s = _demoParseHm(d.startLocalTime);
    final e = _demoParseHm(d.endLocalTime);
    if (s == null || e == null) continue;
    final start = Duration(minutes: s);
    final end = Duration(minutes: e);
    if (d.rollsPastMidnight) {
      if (tod >= start || tod <= end) {
        active = d;
        break;
      }
    } else {
      if (tod >= start && tod <= end) {
        active = d;
        break;
      }
    }
  }

  // Periods applicable today, not active, already ended → closed.
  // Mirrors `resolveServicePeriodPhase`: a non-active `rollsPastMidnight`
  // period is always *future* (its only non-active window is "not
  // re-opened yet"), never closed.
  final closed = <String>[];
  for (final d in defs) {
    if (active != null && d.id == active.id) continue;
    if (!d.applicableDays.contains(businessWeekday)) continue;
    if (d.rollsPastMidnight) continue;
    final e = _demoParseHm(d.endLocalTime);
    if (e == null) continue;
    if (tod > Duration(minutes: e)) closed.add(d.id);
  }

  if (active == null) {
    return OpenPeriodResolution(
      openDaypart: null,
      openProgressFraction: null,
      openTimeLabel: null,
      openServiceElapsedLabel: null,
      currentDayClosedPeriods: closed,
    );
  }

  final startMin = _demoParseHm(active.startLocalTime)!;
  final endMin = _demoParseHm(active.endLocalTime)!;
  // Minutes-of-day, full sub-minute precision (deterministic given the
  // injected anchor — no DateTime.now() in any seeded VALUE).
  final nowMin = localNow.hour * 60 +
      localNow.minute +
      localNow.second / 60.0 +
      localNow.millisecond / 60000.0;
  final double elapsedMin;
  final double windowMin;
  if (active.rollsPastMidnight) {
    windowMin = ((1440 - startMin) + endMin).toDouble();
    elapsedMin =
        nowMin >= startMin ? nowMin - startMin : (1440 - startMin) + nowMin;
  } else {
    windowMin = (endMin - startMin).toDouble();
    elapsedMin = nowMin - startMin;
  }
  final fraction =
      windowMin <= 0 ? 0.0 : (elapsedMin / windowMin).clamp(0.0, 1.0);

  final h = localNow.hour;
  final hour12 = (h % 12) == 0 ? 12 : h % 12;
  final ampm = h < 12 ? 'AM' : 'PM';
  final timeLabel =
      '$hour12:${localNow.minute.toString().padLeft(2, '0')} $ampm';

  final elapsedWhole = elapsedMin.floor().clamp(0, 24 * 60);
  final eh = elapsedWhole ~/ 60;
  final em = elapsedWhole % 60;
  final elapsedLabel = '${eh}h ${em}m into service';

  return OpenPeriodResolution(
    openDaypart: active.id,
    openProgressFraction: double.parse(fraction.toStringAsFixed(4)),
    openTimeLabel: timeLabel,
    openServiceElapsedLabel: elapsedLabel,
    currentDayClosedPeriods: closed,
  );
}

/// SEED-TIME wrapper that guarantees the demo's Shift home is NEVER
/// blank for a CONNECTED demo location (operator decision 2026-05-16,
/// Fix B). [resolveDemoOpenPeriod] stays the honest clock truth (it
/// still returns `openDaypart == null` between services and all its
/// mirror-the-canonical-resolver tests stay green); this wrapper only
/// adjusts what the SEEDER persists.
///
/// Behaviour:
///  * When a period is genuinely IN PROGRESS at [localNow], this returns
///    the honest [resolveDemoOpenPeriod] result UNCHANGED (real clock,
///    real progress).
///  * When NO period is in progress (e.g. Sat 16:00, between Lunch and
///    Dinner), it picks the MOST-RELEVANT applicable period for the
///    business day and presents it as the live/open shift so the Shift
///    home always shows a real whole-day card:
///      - the UPCOMING period (earliest applicable period whose start is
///        still ahead of [localNow]) — generated `projected`, cleanly
///        upgradeable to `open`; else
///      - the MOST-RECENTLY-ENDED applicable non-rolling period (after
///        the day's last service). It is removed from
///        `currentDayClosedPeriods` so the generator emits it
///        `projected` (not `closed`) and the snapshot builder upgrades
///        exactly one slot to `open` — no open/closed UNIQUE collision.
///
/// Determinism (Hard Constraint): the SELECTION is clock-relative (the
/// existing injectable-anchor pattern), but every seeded VALUE is
/// derived from the chosen period's fixed window — fraction is the fixed
/// window MIDPOINT (0.5), labels are computed from the period's own
/// start/end literals, NEVER from [localNow] or `DateTime.now()`. Two
/// reseeds with the same anchor are byte-identical.
///
/// HP #2: seed/writer-side only. No `demo_*` table, no `kDemoMode`
/// reader branch — every reader is byte-unchanged.
OpenPeriodResolution seedTimeOpenPeriodResolution({
  required DateTime localNow,
}) {
  final honest = resolveDemoOpenPeriod(localNow: localNow);
  if (honest.openDaypart != null) {
    // A real service is live — keep the honest clock-derived answer.
    return honest;
  }

  final defs = _kDemoDowntownServicePeriods
      .map(ServicePeriodDefinition.fromMap)
      .toList()
    ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

  final businessDateIso = BusinessDateResolver.resolve(
    localTimestamp: localNow,
    businessDayStartLocalTime: _kDemoBusinessDayStartLocalTime,
  );
  final businessWeekday = DateTime.parse(businessDateIso).weekday;
  final todMin = localNow.hour * 60 + localNow.minute;

  // Applicable periods for this business day, in start-time order.
  final applicable = <ServicePeriodDefinition>[];
  for (final d in defs) {
    if (!d.applicableDays.contains(businessWeekday)) continue;
    if (_demoParseHm(d.startLocalTime) == null) continue;
    if (_demoParseHm(d.endLocalTime) == null) continue;
    applicable.add(d);
  }
  applicable.sort((a, b) => _demoParseHm(a.startLocalTime)!
      .compareTo(_demoParseHm(b.startLocalTime)!));

  if (applicable.isEmpty) {
    // No applicable period at all (should never happen — Lunch/Dinner
    // apply every day). Fall back to the deterministic legacy
    // resolution so the demo still shows a card.
    return MockIntegrationReplaySeed.legacyDefaultResolution;
  }

  // Prefer the UPCOMING period (earliest start still ahead of now).
  ServicePeriodDefinition? chosen;
  for (final d in applicable) {
    if (_demoParseHm(d.startLocalTime)! > todMin) {
      chosen = d;
      break;
    }
  }
  // Else (the day's last service already ended) → most-recently-ended
  // applicable non-rolling period (latest end time).
  chosen ??= applicable
      .where((d) => !d.rollsPastMidnight)
      .fold<ServicePeriodDefinition?>(null, (best, d) {
    if (best == null) return d;
    return _demoParseHm(d.endLocalTime)! > _demoParseHm(best.endLocalTime)!
        ? d
        : best;
  });
  // Absolute last resort: the first applicable period.
  chosen ??= applicable.first;

  // The chosen period must NOT also be seeded `closed` (else the
  // generator emits it `closed` and the snapshot builder would create
  // both an `open` and a `closed` row for the same slot → UNIQUE
  // replace collision). Drop it from the honest closed set; the
  // remaining genuinely-ended periods stay `closed` (closed truth).
  final closed = honest.currentDayClosedPeriods
      .where((id) => id != chosen!.id)
      .toList();

  // Deterministic presentation derived from the chosen period's FIXED
  // window — never from `localNow` (Hard Constraint: determinism).
  final startMin = _demoParseHm(chosen.startLocalTime)!;
  final endMin = _demoParseHm(chosen.endLocalTime)!;
  final windowMin = chosen.rollsPastMidnight
      ? ((1440 - startMin) + endMin)
      : (endMin - startMin);
  // Present the demo "live" shift at the window MIDPOINT (fully
  // deterministic) so the whole-day card shows a believable in-service
  // figure regardless of wall-clock.
  final midMin = startMin + (windowMin ~/ 2);
  final mh = (midMin ~/ 60) % 24;
  final mm = midMin % 60;
  final hour12 = (mh % 12) == 0 ? 12 : mh % 12;
  final ampm = mh < 12 ? 'AM' : 'PM';
  final timeLabel = '$hour12:${mm.toString().padLeft(2, '0')} $ampm';
  final elapsedWhole = (windowMin ~/ 2).clamp(0, 24 * 60);
  final elapsedLabel =
      '${elapsedWhole ~/ 60}h ${elapsedWhole % 60}m into service';

  return OpenPeriodResolution(
    openDaypart: chosen.id,
    openProgressFraction: 0.5,
    openTimeLabel: timeLabel,
    openServiceElapsedLabel: elapsedLabel,
    currentDayClosedPeriods: closed,
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

/// Per-Daypart V1 (SB consumer adaptation): builds the demo cycle's
/// per-period rows from the (now Jim-faithful) recommendation output.
///
/// SB makes the recommendation engine honest: a degenerate per-period
/// cohort (the pre-SA demo seed pins every shift to one CPLH value —
/// spec DIAG-0) no longer fabricates a band; the period's stats carry a
/// `building_*` verdict with zeroed band/target. The demo must still
/// render a usable, differentiated per-period number, so a period whose
/// recommendation did not produce a real teachable band falls back to
/// the deterministic demo band constants (the same constants stamped
/// onto the demo closed shifts) — exactly the existing insufficient
/// fallback, now also covering the honest `building_*` case. The SB
/// verdict + reason are carried through onto the row so the per-period
/// breakdown can still tell the honest story. SA's demo reseed restores
/// genuine variance so these periods become `teachable` end-to-end;
/// this keeps the demo functional in the interim without touching the
/// demo data shape (SA's territory).
List<TargetCycleDaypart> _buildDemoSeedDayparts({
  required RecommendedBenchmarkSelection recommendation,
  required Map<String, int> coversByPeriod,
}) {
  final dayparts = <TargetCycleDaypart>[];
  for (final periodId in MockIntegrationReplaySeed.demoServicePeriodIds) {
    final stats = recommendation.isInsufficient
        ? null
        : recommendation.perDaypartStats[periodId];
    final coverCount = coversByPeriod[periodId] ?? 0;
    // A "real teachable band" is one the engine actually drew (positive
    // band + target). building_* / running-hot-without-band yield zeros.
    final hasRealBand = stats != null &&
        stats.opzCeilingCPLH > 0 &&
        stats.recommendedTargetCPLH > 0;
    if (hasRealBand) {
      dayparts.add(TargetCycleDaypart(
        servicePeriodId: periodId,
        targetCPLH: stats.recommendedTargetCPLH,
        targetSPLH: stats.recommendedTargetSPLH,
        targetPPA: stats.recommendedTargetPPA,
        opzFloorCPLH: stats.opzFloorCPLH,
        opzCeilingCPLH: stats.opzCeilingCPLH,
        coverCount: coverCount,
        verdict: stats.verdict,
        verdictReason: stats.verdictReason,
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
        // Carry the honest verdict when the engine produced one (the
        // pre-SA degenerate-data `building_*` case); null on the
        // genuine insufficient path.
        verdict: stats?.verdict,
        verdictReason: stats?.verdictReason,
      ));
    }
  }
  return dayparts;
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
  final dayparts = _buildDemoSeedDayparts(
    recommendation: recommendation,
    coversByPeriod: coversByPeriod,
  );

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

  final dayparts = _buildDemoSeedDayparts(
    recommendation: recommendation,
    coversByPeriod: coversByPeriod,
  );

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
    // Honest-EMPTY: a "none connected" demo location (today Harbour) gets
    // NO operational/historical cohort so the existing readers
    // honest-degrade to "awaiting first connection" instead of phantom
    // numbers. Its `restaurant_locations` row is still seeded by
    // `_seedDemoRestaurant`, so it stays in the scope drawer.
    if (_isNoneConnectedDemoLocation(restaurantId)) continue;
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

// ── Demo-data Slice F — HP #11 scope-level overrides + notifications ───────
//
// Authority: docs/_audits/per_daypart_v1/full_demo_data_spec.md Slice F
//            (§2c "HP #11 override examples, one per scope level",
//            lines 140-144; §1.6 Notifications line 80; Gap G9/G10);
//            CLAUDE.md HP #11 / HP #2 / HP #4.
//
// Why this region exists (Gap G10 + G9): before Slice F there were NO
// scope-level override rows, so HP #11 inherited-vs-effective pills
// resolved trivially (one value at one scope), and there were NO
// notification/alert rows so the Notifications surface was empty.
//
// Realization (spec §4 watch item, line 210): mobile SQLite has NO
// `org_units` / scope-level columns — `restaurant_timing_configs`
// (PK `restaurant_id`), `wage_role_rows` (UNIQUE `restaurant_id`,
// `role_name`), and `data_accuracy_service_period_settings_cache`
// (PK `restaurant_id`, ...) are all `restaurant_id`-keyed. The §2c
// scope hierarchy (corp → region → district → location) lives in the
// operator-web fixture; on mobile a scope-level override is realized
// as a per-`restaurant_id` row, and "inherits" is realized as the
// ABSENCE of a per-location row (the production reader returns null /
// no cached row → the caller falls back to the business default). So:
//
//   * Business/operator default (the inherited-FROM source):
//       Downtown (`DemoScope.restaurantId`) — its existing
//       `_seedDemoTimingConfig` (week-start Monday) + `_seedDemoWageRoleRows`
//       (FOH 16.50 / BOH 21.35) + the data-accuracy baseline seeded
//       here (all periods covers_source `vendor`). UNCHANGED by this
//       region — it IS the baseline every other scope inherits.
//   * Region scope — East Region overrides timing: North Loop (the
//       other East-Region location) gets a `restaurant_timing_configs`
//       row whose week-start is Sunday (≠ business default Monday).
//   * District scope — Metro District overrides a data-accuracy
//       covers-source: North Loop (the sole location under Metro
//       District) gets a `data_accuracy_service_period_settings_cache`
//       dinner row with covers_source `manual` (≠ business default
//       `vendor`). Its lunch / late_night have NO row → inherit.
//   * Location scope — Riverside overrides wages (location wins over
//       the business default); Harbour inherits unchanged: Riverside
//       gets `wage_role_rows` blending FOH 17.50 / BOH 22.35
//       (≠ business default 16.50 / 21.35); Harbour gets NO override
//       row in ANY of the three tables, so every reader resolves
//       Harbour to the inherited business default — the "inherited
//       from Business" pill is exercised end-to-end.
//
// HP #2: standard production tables only (`restaurant_timing_configs`,
// `wage_role_rows`, `data_accuracy_service_period_settings_cache`,
// `app_notifications`). No `demo_*` table, no `kDemoMode` reader
// branch — writer-side seed only; every reader/repository/widget is
// untouched and resolves demo and prod identically.
// HP #4: every write is scoped to one demo `restaurant_id`; no
// cross-(operator, location) write.
// HP #11: this region ONLY ADDS override rows. It never deletes or
// rewrites a scope/inherited/effective affordance, and never touches
// Downtown's business-default rows. The operator-web wage/data-accuracy
// inherited-source PILL itself is Gap 32 (wage authority resolver
// hardcoded to location scope) / Gap 29 (no data-accuracy
// `HierarchyScopeNotice` yet) per the spec §1.7 — those are
// gated/incomplete UI, not removed affordances; this slice shapes the
// DATA so the inheritance is correct the moment those notices land,
// and mirrors the wage scope story into the operator-web demo gateway
// (`OperatorWebDemoWageAuthorityGateway` default fixture).
//
// Determinism (NO RNG): every value is a compile-time constant or is
// derived from already-deterministic seeded `week_records`. Timestamps
// are fixed literals (never `DateTime.now()`), so two reseeds are
// byte-identical. Operator-authority-safe: each seeder skips a
// `restaurant_id` that already has a row (mirrors `_seedDemoWageRoleRows`)
// and uses `ConflictAlgorithm.ignore`, so it can never clobber an
// operator's configured value.

/// Demo operator id used for the data-accuracy cache scope columns.
/// Mirrors `kDemoOperatorOperatorId` (`'n'`) from
/// `lib/services/auth/demo_auth_login_service.dart` without importing
/// the auth layer into persistence. The cache reader filters by
/// `restaurant_id` only; `operator_id` / `location_id` are stored
/// scope columns kept consistent with the runtime convention
/// (`location_id == restaurant_id`).
const String _kDemoScopeOperatorId = 'n';

/// The three demo service periods, identical to `_seedDemoTimingConfig`'s
/// business default ([_kDemoDowntownServicePeriods]). Replicated (not
/// shared) so the East-Region timing override is a clean SINGLE-axis
/// change (week-start only) — the service-period set stays byte-equal to
/// the business default so the HP #11 diff renders as exactly "week
/// start: Sunday (set at East Region) vs Monday (inherited from
/// Business)". QA fix (Change B): `lunch.applicable_days` includes Sat
/// (6) + Sun (7), kept byte-equal to [_kDemoDowntownServicePeriods] so
/// the single-axis invariant holds.
const List<Map<String, Object?>> _kDemoBusinessDefaultServicePeriods =
    <Map<String, Object?>>[
  {
    'id': 'lunch',
    'label': 'Lunch',
    'short_label': 'L',
    'sort_order': 1,
    'start_local_time': '11:00',
    'end_local_time': '15:00',
    'rolls_past_midnight': false,
    'applicable_days': [1, 2, 3, 4, 5, 6, 7],
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

/// Region scope (§2c) — East Region overrides timing.
///
/// East Region = Downtown + North Loop. Downtown carries the business
/// default (`_seedDemoTimingConfig`, week-start Monday) and is left
/// untouched. North Loop — the other East-Region location — gets a
/// `restaurant_timing_configs` row whose `week_start_day` is Sunday,
/// so the HP #11 resolver renders North Loop's effective week-start as
/// the East-Region override and Riverside / Harbour (no row →
/// `RestaurantTimingConfigDao.getConfig` returns null → caller
/// inherits) as the inherited business default.
Future<void> _seedDemoScopeOverrideTimingConfig(Database db) async {
  if (!await _tableExists(db, 'restaurant_timing_configs')) return;
  const overrideRestaurantId = DemoScope.northLoopRestaurantId;
  final existing = await db.query(
    'restaurant_timing_configs',
    where: 'restaurant_id = ?',
    whereArgs: [overrideRestaurantId],
    limit: 1,
  );
  if (existing.isNotEmpty) return; // operator authority — never clobber
  const now = '2026-05-15T00:00:00.000Z'; // fixed — determinism (NO now())
  await db.insert(
    'restaurant_timing_configs',
    {
      'restaurant_id': overrideRestaurantId,
      'business_day_start_local_time': '04:00',
      // East-Region timing override: Sunday week-start (business
      // default is Monday). Single-axis HP #11 diff.
      'week_start_day': DateTime.sunday,
      'service_period_definitions_json':
          jsonEncode(_kDemoBusinessDefaultServicePeriods),
      'created_at': now,
      'updated_at': now,
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}

/// Location scope (§2c) — Riverside overrides wages; Harbour inherits.
///
/// Riverside gets a full FOH/BOH `wage_role_rows` cohort whose weighted
/// blend (FOH 17.50 / BOH 22.35) deviates from the business default
/// (`_seedDemoWageRoleRows`: FOH 16.50 / BOH 21.35) — location wins
/// over the business default. North Loop + Harbour get NO wage rows, so
/// the wage waterfall / `_weightedAvgFromRows` resolves them to the
/// inherited business default (the empty-rows fallback == the business
/// default by construction), exercising the "inherited from Business"
/// pill for Harbour.
Future<void> _seedDemoScopeOverrideWageRows(Database db) async {
  const overrideRestaurantId = DemoScope.riversideRestaurantId;
  final existing = await db.query(
    'wage_role_rows',
    where: 'restaurant_id = ?',
    whereArgs: [overrideRestaurantId],
    limit: 1,
  );
  if (existing.isNotEmpty) return; // operator authority — never clobber
  const rows = <Map<String, Object?>>[
    // FOH cohort — weighted blend = (15.50 + 19.50) / 2 = 17.50
    // (business default 16.50 → +$1.00 location override).
    {
      'role_name': 'Server',
      'labor_bucket': 'foh',
      'hourly_rate': 15.50,
      'weighted_hours': 500.0,
    },
    {
      'role_name': 'Bartender',
      'labor_bucket': 'foh',
      'hourly_rate': 19.50,
      'weighted_hours': 500.0,
    },
    // BOH cohort — weighted blend = (20.35 + 24.35) / 2 = 22.35
    // (business default 21.35 → +$1.00 location override).
    {
      'role_name': 'Prep Cook',
      'labor_bucket': 'boh',
      'hourly_rate': 20.35,
      'weighted_hours': 500.0,
    },
    {
      'role_name': 'Line Cook',
      'labor_bucket': 'boh',
      'hourly_rate': 24.35,
      'weighted_hours': 500.0,
    },
  ];
  final batch = db.batch();
  for (final r in rows) {
    batch.insert(
      'wage_role_rows',
      {
        'restaurant_id': overrideRestaurantId,
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

/// District scope (§2c) — Metro District overrides a data-accuracy
/// covers-source; also seeds the business-default baseline.
///
/// Business default (the inherited-FROM source): Downtown gets the
/// three service-period rows with covers_source `vendor`. Metro
/// District (= North Loop, the sole location under it) gets a single
/// `dinner` row with covers_source `manual` — the deliberate one-axis
/// district override. North Loop's lunch / late_night and all of
/// Riverside / Harbour get NO row → the cache reader returns nothing →
/// the caller resolves them to the inherited business default.
Future<void> _seedDemoScopeOverrideDataAccuracy(Database db) async {
  if (!await _tableExists(
    db,
    'data_accuracy_service_period_settings_cache',
  )) {
    return;
  }
  const businessRid = DemoScope.restaurantId; // Downtown = business default
  const districtRid = DemoScope.northLoopRestaurantId; // Metro District
  final existing = await db.query(
    'data_accuracy_service_period_settings_cache',
    where: 'restaurant_id IN (?, ?)',
    whereArgs: [businessRid, districtRid],
    limit: 1,
  );
  if (existing.isNotEmpty) return; // operator authority — never clobber
  // Fixed literals — determinism (never DateTime.now()). The reader
  // picks the most recent row at-or-before the business date; a far-past
  // effective date keeps the baseline applicable to every demo date.
  const effectiveDate = '2020-01-01';
  const ts = '2026-05-15T00:00:00.000Z';
  Map<String, Object?> row({
    required String rid,
    required String period,
    required String coversSource,
  }) =>
      <String, Object?>{
        'restaurant_id': rid,
        'service_period_key': period,
        'effective_at_business_date': effectiveDate,
        'id': 'demo_das_${rid}_$period',
        'operator_id': _kDemoScopeOperatorId,
        'location_id': rid, // runtime convention: location_id == rid
        'covers_source': coversSource,
        'wage_source': 'vendor_per_employee',
        'created_at': ts,
        'updated_at': ts,
        'updated_by': 'demo_seed',
        'cached_at': ts,
      };
  final batch = db.batch();
  // Business-default baseline — Downtown, all 3 periods `vendor`.
  for (final period in const ['lunch', 'dinner', 'late_night']) {
    batch.insert(
      'data_accuracy_service_period_settings_cache',
      row(rid: businessRid, period: period, coversSource: 'vendor'),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
  // Metro District override — North Loop dinner covers_source `manual`.
  // Only the dinner row is seeded; lunch / late_night intentionally
  // have NO row so they inherit the business default (HP #11
  // inheritance is exercised WITHIN the district location too).
  batch.insert(
    'data_accuracy_service_period_settings_cache',
    row(rid: districtRid, period: 'dinner', coversSource: 'manual'),
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
  await batch.commit(noResult: true);
}

// ── R6 "Choose Star Shifts": 4-service-period demo operator ───────────────
//
// Authority: this slice's prompt + clarification (R6, data/seed only);
//            CLAUDE.md HP #2 / HP #4 / HP #11.
//
// Why this region exists: every other demo operator carries the
// fixture-era THREE service periods (lunch / dinner / late_night). That
// makes a fixed 3-element daypart shape unfalsifiable in demo: a
// regression that re-hardcodes "3 periods" would still look correct.
// This region seeds a SEPARATE standalone demo operator/location whose
// `restaurant_timing_configs.service_period_definitions_json` defines
// EXACTLY FOUR periods (Breakfast, Lunch, Dinner, Late night), with
// closed `shift_records` spread across the 60-day window so each of the
// four configured periods has real candidates. Every period key written
// is the configured period id; there is no fixed 3-element assumption
// anywhere in this region.
//
// HP #2: standard production tables only (`restaurant_locations`,
// `restaurant_timing_configs`, `shift_records`, `import_runs`,
// `raw_import_records`) written through the SAME DAO/insert path as
// production demo seeding. No `demo_*` table, no `kDemoMode` reader
// branch. The 4-period config resolves through the exact same
// `RestaurantTimingConfigDao` -> `ServicePeriodDefinitionResolver` path
// every reader uses; demo and prod resolve identically.
// HP #4: every write is scoped to the single
// `DemoScope.fourPeriodRestaurantId`; no cross-(operator, location)
// write, and no existing demo restaurant's rows are touched.
// HP #11: this operator is single-location (its own business default);
// it never deletes or rewrites a scope/inherited/effective affordance.
//
// Determinism (NO RNG): every value is a compile-time constant or a
// pure function of the deterministic anchor date. Timestamps are fixed
// literals (never `DateTime.now()`), so two reseeds are byte-identical.
// Idempotent: `ConflictAlgorithm.ignore` for the location/config rows;
// the table-wide `shift_records` / `import_runs` / `raw_import_records`
// deletes in `reseedMockReplayForBusinessDate` clear this operator too,
// then this re-seeds the identical cohort.

/// The R6 demo operator's four service periods. Order is the canonical
/// `sortOrder` ascending; ids are stable lowercase tokens. Note the
/// deliberately non-trivial fourth period (`late_night`) rolls past
/// midnight, and `breakfast` is unique to this operator: proof that
/// the resolver consumes whatever the config declares, not a fixed set.
const List<ServicePeriodDefinition> _kDemoFourPeriodDefinitions =
    <ServicePeriodDefinition>[
  ServicePeriodDefinition(
    id: 'breakfast',
    label: 'Breakfast',
    shortLabel: 'B',
    sortOrder: 1,
    startLocalTime: '06:00',
    endLocalTime: '10:30',
    rollsPastMidnight: false,
    applicableDays: [1, 2, 3, 4, 5, 6, 7],
  ),
  ServicePeriodDefinition(
    id: 'lunch',
    label: 'Lunch',
    shortLabel: 'L',
    sortOrder: 2,
    startLocalTime: '11:00',
    endLocalTime: '15:00',
    rollsPastMidnight: false,
    applicableDays: [1, 2, 3, 4, 5, 6, 7],
  ),
  ServicePeriodDefinition(
    id: 'dinner',
    label: 'Dinner',
    shortLabel: 'D',
    sortOrder: 3,
    startLocalTime: '17:00',
    endLocalTime: '22:30',
    rollsPastMidnight: false,
    applicableDays: [1, 2, 3, 4, 5, 6, 7],
  ),
  ServicePeriodDefinition(
    id: 'late_night',
    label: 'Late night',
    shortLabel: 'LN',
    sortOrder: 4,
    startLocalTime: '22:30',
    endLocalTime: '01:30',
    rollsPastMidnight: true,
    applicableDays: [4, 5, 6, 7],
  ),
];

/// Per-period base productivity for the R6 cohort. Distinct per period
/// so Benchmark/Variance render real per-period differences; held within
/// realistic ranges. Pure constants, NO RNG.
const Map<String, ({double cplh, double splh, double ppa})>
    _kDemoFourPeriodRates = {
  'breakfast': (cplh: 9.0, splh: 145.0, ppa: 16.0),
  'lunch': (cplh: 11.0, splh: 210.0, ppa: 19.0),
  'dinner': (cplh: 13.0, splh: 320.0, ppa: 31.0),
  'late_night': (cplh: 7.5, splh: 165.0, ppa: 22.0),
};

/// Per-period base covers for the R6 cohort. Deterministic; lightly
/// tilted day-over-day inside [_seedDemoFourPeriodOperator] so the
/// 60-day window is not a flat line while staying RNG-free.
const Map<String, int> _kDemoFourPeriodBaseCovers = {
  'breakfast': 70,
  'lunch': 120,
  'dinner': 180,
  'late_night': 55,
};

/// Seeds the R6 "Choose Star Shifts" 4-service-period demo
/// operator/location: its `restaurant_locations` row, its 4-period
/// `restaurant_timing_configs` row (same raw insert shape as
/// `_seedDemoTimingConfig`, byte-identical to the production DAO's
/// persisted JSON), and a 60-day window of closed `shift_records`
/// (+ matching `import_runs`/`raw_import_records`) where EVERY one of
/// the four configured periods has candidates spread across the window.
///
/// `anchorIsoDate` is the inclusive last business date of the window
/// (the caller passes the seed's business date so this cohort lines up
/// with the rest of the demo timeline). The window is the 60 calendar
/// days ending at `anchorIsoDate`.
Future<void> _seedDemoFourPeriodOperator(
  Database db,
  String anchorIsoDate,
) async {
  const rid = DemoScope.fourPeriodRestaurantId;
  // Fixed literals for determinism (never DateTime.now()).
  const seedTs = '2026-05-15T00:00:00.000Z';

  // 1. Location row (scope/identity). HP #2: standard table, `ignore`
  //    keeps it idempotent across reseeds.
  await db.insert(
    'restaurant_locations',
    {
      'restaurant_id': rid,
      'display_name': DemoScope.fourPeriodDisplayName,
      'business_timezone': DemoScope.businessTimezone,
      'created_at': seedTs,
      'updated_at': seedTs,
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );

  // 2. 4-period timing config. Written via the SAME raw insert shape as
  //    `_seedDemoTimingConfig` / `_seedDemoScopeOverrideTimingConfig`
  //    (the canonical demo timing-config seed path): the persisted
  //    `service_period_definitions_json` is `jsonEncode` of the ordered
  //    `ServicePeriodDefinition.toMap()` list, byte-identical to what
  //    `RestaurantTimingConfigDao.upsert` would write (it only sorts by
  //    sortOrder/id then jsonEncodes the same maps; the definitions here
  //    are already in sortOrder order). Resolves through the exact same
  //    `RestaurantTimingConfigDao.getRaw` -> `ServicePeriodDefinition
  //    .fromMap` -> `ServicePeriodDefinitionResolver` reader path every
  //    surface uses. Guard: table may not exist on older upgrade paths.
  //    Skip-if-present preserves operator authority (mirrors
  //    `_seedDemoScopeOverrideTimingConfig`).
  if (await _tableExists(db, 'restaurant_timing_configs')) {
    final existing = await db.query(
      'restaurant_timing_configs',
      where: 'restaurant_id = ?',
      whereArgs: [rid],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert(
        'restaurant_timing_configs',
        {
          'restaurant_id': rid,
          'business_day_start_local_time': '04:00',
          'week_start_day': DateTime.monday,
          'service_period_definitions_json': jsonEncode(
            _kDemoFourPeriodDefinitions.map((d) => d.toMap()).toList(),
          ),
          'created_at': seedTs,
          'updated_at': seedTs,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  // 3. Closed shift_records across the 60-day window. Every period key
  //    written is a configured period id (`def.id`); there is NO fixed
  //    3-element assumption; the loop is driven entirely by
  //    `_kDemoFourPeriodDefinitions`. A period appears on a given day
  //    only when that day's ISO weekday is in its `applicableDays`
  //    (so `late_night`, Thu-Sun only, is correctly sparser), proving
  //    the cohort honors the per-period config, not a flat 3x60 grid.
  final anchor = DateTime.parse(anchorIsoDate);
  final importRunId = 'demo_four_period_seed_$rid';
  final shiftRows = <Map<String, Object?>>[];
  final rawRows = <Map<String, Object?>>[];
  var rawIndex = 0;

  for (var dayOffset = 59; dayOffset >= 0; dayOffset--) {
    final date = anchor.subtract(Duration(days: dayOffset));
    final isoWeekday = date.weekday; // 1 = Mon ... 7 = Sun
    final businessDate =
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    // ISO week id (matches `_businessDateFromWeekId`'s leading-date
    // regex AND the canonical `YYYY-Wnn` shape used elsewhere).
    final weekId = _isoWeekId(date);
    final dayLabel = _isoWeekdayLabel(isoWeekday);

    for (final def in _kDemoFourPeriodDefinitions) {
      if (!def.applicableDays.contains(isoWeekday)) continue;
      final rate = _kDemoFourPeriodRates[def.id]!;
      final baseCovers = _kDemoFourPeriodBaseCovers[def.id]!;
      // Deterministic, RNG-free day tilt: a bounded triangular wave
      // keyed by the day offset so volume varies realistically across
      // the window without any random source.
      final tilt = 1.0 + (((dayOffset % 14) - 7).abs() - 3) * 0.02;
      final covers = (baseCovers * tilt).round().clamp(10, 9999);
      final forecastCovers =
          (baseCovers * (tilt + 0.03)).round().clamp(10, 9999);
      final fohHours =
          (covers / rate.cplh).round().clamp(1, 999999);
      final bohHours =
          ((covers * rate.ppa) / rate.splh).round().clamp(1, 999999);

      final shift = ShiftRecord(
        restaurantId: rid,
        weekId: weekId,
        dayLabel: dayLabel,
        // Period key == configured period id (no hardcoded set).
        daypart: def.id,
        status: 'closed',
        covers: covers,
        forecastCovers: forecastCovers,
        ppa: rate.ppa,
        cplh: rate.cplh,
        splh: rate.splh,
        fohHours: fohHours,
        bohHours: bohHours,
        primaryLever: 'covers',
        businessDate: businessDate,
        servicePeriodKey: def.id,
        sourceSystem: 'demo_four_period_seed',
      );
      final map = shift.toMap()..remove('id');
      shiftRows.add(map);
      final payloadJson = jsonEncode(map);
      rawRows.add(
        RawImportRecord(
          rawImportId: '${importRunId}_shift_$rawIndex',
          importRunId: importRunId,
          restaurantId: rid,
          sourceType: 'demo_four_period_seed',
          sourceEntityType: 'shift_record',
          sourceEntityId: '${weekId}_${dayLabel}_${def.id}',
          payloadHash: _deterministicHash(payloadJson),
          businessDate: businessDate,
          receivedAt: seedTs,
          status: 'applied',
          payloadJson: payloadJson,
        ).toMap(),
      );
      rawIndex++;
    }
  }

  final batch = db.batch();
  for (final row in shiftRows) {
    batch.insert('shift_records', row);
  }
  await batch.commit(noResult: true);

  await db.insert(
    'import_runs',
    ImportRun(
      importRunId: importRunId,
      restaurantId: rid,
      mode: 'demo_four_period_seed',
      startedAt: seedTs,
      completedAt: seedTs,
      status: 'completed',
    ).toMap(),
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );

  final rawBatch = db.batch();
  for (final row in rawRows) {
    rawBatch.insert('raw_import_records', row);
  }
  await rawBatch.commit(noResult: true);
}

/// ISO-8601 week id (`YYYY-Wnn`) for [date]. Matches the
/// `_businessDateFromWeekId` leading-date heuristic indirectly via the
/// year segment and the canonical `YYYY-Wnn` shape every other demo
/// `week_id` uses. Pure, no `DateTime.now()`.
String _isoWeekId(DateTime date) {
  // ISO week-numbering: week 1 is the week containing Jan 4th; weeks
  // start Monday. Mirrors `_businessDateFromWeekDay`'s inverse math.
  final thursday = date.add(Duration(days: 4 - date.weekday));
  final firstThursday = DateTime(thursday.year, 1, 4);
  final firstWeekMonday =
      firstThursday.subtract(Duration(days: firstThursday.weekday - 1));
  final week =
      ((thursday.difference(firstWeekMonday).inDays) ~/ 7) + 1;
  return '${thursday.year.toString().padLeft(4, '0')}-'
      'W${week.toString().padLeft(2, '0')}';
}

/// ISO weekday number (1 = Mon .. 7 = Sun) to the canonical 3-letter
/// label used by `_businessDateFromWeekDay`.
String _isoWeekdayLabel(int isoWeekday) {
  const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return labels[(isoWeekday - 1).clamp(0, 6)];
}

/// Notifications / alerts (§1.6 / Gap G9) — variance-breach-derived.
///
/// Metric Honesty: this does NOT fabricate an alert. It scans the
/// already-seeded, deterministic `week_records` for Downtown and emits
/// ONE `app_notifications` row for the worst real over-plan week — the
/// row with the largest positive `dollar_gap` (= `WeekRecord.isOverModel`,
/// labor ran over the locked plan). If no seeded week is over plan there
/// is NO breach and NO notification (honest empty). The notification is
/// persisted through the same `app_notifications` table + `${rid}_$key`
/// id shape `AppNotificationService` uses, so `NotificationsScreen`
/// renders it identically to a runtime-emitted alert (unknown event_key
/// → raw title/body + default icon/accent — verified graceful).
///
/// Determinism: the worst week is a pure function of deterministic
/// `week_records`; `created_at` is derived from that week's business
/// date (fixed time component), never `DateTime.now()`. `reseedDemo`
/// clears `app_notifications` then this re-seeds the identical row →
/// two reseeds byte-identical. `ConflictAlgorithm.ignore` matches the
/// table's `UNIQUE(restaurant_id, event_key)` dedupe.
Future<void> _seedDemoVarianceBreachNotification(Database db) async {
  if (!await _tableExists(db, 'app_notifications')) return;
  const rid = DemoScope.restaurantId;
  final rows = await db.query(
    'week_records',
    columns: [
      'week_id',
      'week_label',
      'dollar_gap',
      'actual_labor_pct',
      'theoretical_labor_pct',
      'closed_at',
    ],
    where: 'restaurant_id = ?',
    whereArgs: [rid],
  );
  if (rows.isEmpty) return;
  Map<String, Object?>? worst;
  var worstGap = 0.0;
  for (final r in rows) {
    final gap = (r['dollar_gap'] as num?)?.toDouble() ?? 0.0;
    // Over-plan only (isOverModel: dollar_gap > 0). A favorable week
    // is not a breach — no alert. Deterministic max; tie-break on
    // week_id so the choice is stable across reseeds.
    if (gap > worstGap ||
        (gap == worstGap &&
            worst != null &&
            (r['week_id'] as String).compareTo(worst['week_id'] as String) <
                0)) {
      worst = r;
      worstGap = gap;
    }
  }
  if (worst == null || worstGap <= 0) return; // no real breach → honest empty
  final weekId = worst['week_id'] as String;
  final weekLabel = (worst['week_label'] as String?) ?? weekId;
  final actualPct = (worst['actual_labor_pct'] as num?)?.toDouble() ?? 0.0;
  final theoPct =
      (worst['theoretical_labor_pct'] as num?)?.toDouble() ?? 0.0;
  final businessDate =
      (worst['closed_at'] as String?) ?? _businessDateFromWeekId(weekId);
  final eventKey =
      'variance_breach_${weekId.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';
  await db.insert(
    'app_notifications',
    {
      'notification_id': '${rid}_$eventKey',
      'restaurant_id': rid,
      'type': 'variance_breach',
      'event_key': eventKey,
      'title': 'Weekly labor ran over plan',
      'body': 'Week $weekLabel: labor ran \$${worstGap.round()} over the '
          'locked plan (actual ${actualPct.toStringAsFixed(1)}% vs plan '
          '${theoPct.toStringAsFixed(1)}%). Open the Variance tab to '
          'review.',
      'business_date': businessDate,
      // Deterministic: derived from the breach week's business date,
      // never DateTime.now() — two reseeds byte-identical.
      'created_at': '${businessDate}T12:00:00.000Z',
      'read_at': null,
    },
    conflictAlgorithm: ConflictAlgorithm.ignore,
  );
}

/// Best-effort `YYYY-MM-DD` from a `week_id` when a week_record has no
/// `closed_at`. Demo `week_id`s carry a leading date segment; fall back
/// to a fixed in-window date if the shape is unexpected (still
/// deterministic).
String _businessDateFromWeekId(String weekId) {
  final m = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(weekId);
  return m?.group(1) ?? '2026-05-11';
}

// ── Demo-data — per-location operational envelope ──────────────────────────
//
// Reconciliation (verified on master, this slice's PR documents it in
// full): Slice C already seeds `shift_records` + `week_records` +
// `target_cycles`/`target_cycle_dayparts` + `active_target_profiles` +
// `import_runs`/`raw_import_records` for ALL FOUR demo locations across
// {12 historical weeks + current} × the 14 served weekly slots, with
// per-location variance profiles (`_scaleShiftForLocation` +
// `_demoLocationProfiles`). The SALES pipeline is therefore the single
// coverage envelope; the non-sales operational tables below derive FROM
// that already-generated shift set rather than re-implementing it.
//
// What this region adds (each verified genuinely missing on master):
//  • `open_shift_snapshots`   — historical closed snapshots for the full
//    12-week range, all 4 locations, derived from the generated closed
//    shift set (Promise 2 — closed truth matches the closed shift
//    stamp), plus current-week closed/projected for the 3 non-Downtown
//    locations. Downtown's existing current-week cohort is untouched and
//    Downtown stays the only `status='open'` row (singular live shift).
//  • `reservation_book_snapshots` — the FORWARD reservation book
//    (current-week projected/open cells) for all 4 locations, scaled by
//    each location's volume profile through the EXISTING covers→unseated
//    ratio. Closed/past shifts get NO row: a service that already closed
//    has no live unseated reservation book — seeding one would be a
//    phantom metric (Metric Honesty / Design Rule 2). This intentionally
//    supersedes the prior single-row contract; the one pinned test that
//    encoded it is updated in lockstep.
//  • `weekly_plan_snapshots` + `weekly_plan_snapshot_day_dayparts` — a
//    locked weekly plan per location for every historical week + current
//    (the existing in-force Downtown snapshot is preserved via the
//    (restaurant_id, week_key) existence guard — closed truth is not
//    rewritten, Promise 2). The per-(day, service_period) child rows
//    carry each location's cycle per-period band targets (the demo
//    cycle's per-period rows derive from `MockIntegrationReplaySeed`'s
//    daypart CPLH/SPLH/PPA/OPZ bands, NOT a whole-day pooled value).
//    This child seeding is the data dependency Item 5 (per-daypart
//    target/benchmark footers) reads.
//  • `app_notifications` — a modest, deterministic sample inbox per
//    (operator, location) using recognized catalog/legacy event keys so
//    they render with the correct icon/accent + training-tone copy.
//
// HP #2: every row lands in the SAME standard production tables the
// runtime writes, distinguished only by `restaurant_id`/`DemoScope`
// scope. No `demo_*` table, no `kDemoMode` reader branch. HP #4: every
// row is restaurant-scoped; no cross-location/operator write. All values
// are pure functions of the deterministic replay — two reseeds are
// byte-identical (idempotent; `ConflictAlgorithm.replace`/`.ignore` +
// deterministic ids + business-date-derived timestamps, never
// `DateTime.now()`).

/// The closed/current shift set for [locationIndex] exactly as it landed
/// in `shift_records`. Index 0 (Downtown, identity profile) is the raw
/// base replay — byte-for-byte what `_seedDemoDataFromReplay` inserted.
/// Indices 1..3 reuse Slice C's `_scaleShiftForLocation` +
/// `_demoLocationProfiles` so the derived non-sales rows stay consistent
/// with each location's scaled `shift_records` (no re-derivation drift).
List<ShiftRecord> _envelopeShiftsForLocation(
  List<ShiftRecord> baseShifts,
  int locationIndex,
  String restaurantId,
) {
  if (locationIndex == 0) return baseShifts;
  final profile = _demoLocationProfiles[
      locationIndex < _demoLocationProfiles.length
          ? locationIndex
          : _demoLocationProfiles.length - 1];
  return baseShifts
      .map((s) => _scaleShiftForLocation(s, restaurantId, profile))
      .toList();
}

/// Single per-location seam invoked from BOTH the cold-boot
/// (`_onCreate`) and reseed/advance (`reseedMockReplayForBusinessDate`)
/// paths, AFTER the sales pipeline + cycles + the existing
/// Downtown-in-force snapshot/reservation seeders have run. Order
/// matters: each helper reads the already-persisted per-location cycle
/// and the generated shift set.
Future<void> _seedOperationalEnvelopeFromReplay(
  Database db,
  MockReplayOutput replay,
) async {
  await _seedHistoricalOpenShiftSnapshotsFromReplay(db, replay);
  await _seedForwardReservationEnvelopeFromReplay(db, replay);
  await _seedHistoricalWeeklyPlanSnapshotsFromReplay(db, replay);
  await _seedDemoSampleNotifications(db, replay);
}

/// Gap 2 — per-location historical `open_shift_snapshots` + every
/// location's OWN live current-week shift.
///
/// For every location: each generated historical CLOSED shift becomes a
/// `status='closed'` snapshot whose covers/PPA/CPLH/SPLH/hours/wage are
/// the closed shift's own stamp (Promise 2 — closed truth is never
/// re-derived). For the 3 non-Downtown locations the current week is
/// seeded through the SHARED `_buildCurrentWeekOpenShiftSnapshots` —
/// byte-identically to how Downtown's current week is built — using each
/// location's volume/wage/timing scaled current-week shifts. Each
/// non-Downtown location therefore gets its OWN `status='open'`
/// in-progress shift + projected siblings + open-day closed dayparts,
/// with per-location-distinct figures (NOT a clone of Downtown's, NOT a
/// fabricated phantom).
///
/// This fixes the operator-reproduced defect where switching to a
/// non-Downtown location showed HISTORICAL ONLY / empty Shift:
/// `ShiftDashboardNotifier._load()` resolves the live business date via
/// `OpenShiftSnapshotDao.getCurrentBusinessDate` (`WHERE status='open'`),
/// so a location with no `status='open'` row rendered the empty "No open
/// or projected shift" state. Every location now has exactly one
/// `status='open'` row scoped by `restaurant_id` (HP #4) — no longer a
/// single global Downtown-only open row.
///
/// Historical-closed `updated_at` is derived from each row's business
/// date (a past, deterministic instant) so it is always older than the
/// current-week open/projected rows the shared builder stamps with
/// `nowIsoUtc()` — keeping `OpenShiftSnapshotDao.getLatestOpenWeekId`'s
/// `updated_at DESC, week_id DESC` ordering resolving the live week
/// first, per location.
///
/// Idempotent: `ConflictAlgorithm.replace` keyed on the
/// `(restaurant_id, week_id, day_label, daypart)` UNIQUE constraint, so a
/// cold boot followed by a reseed/advance produces no duplicate rows and
/// no PK collision (Downtown's current week is still owned by
/// `_seedOpenShiftSnapshotsFromReplay`; the `isDowntown` guard below
/// leaves it untouched here).
Future<void> _seedHistoricalOpenShiftSnapshotsFromReplay(
  Database db,
  MockReplayOutput replay,
) async {
  final locations = DemoScope.locations;
  final batch = db.batch();

  for (var i = 0; i < locations.length; i++) {
    final rid = locations[i].restaurantId;
    // Honest-EMPTY: skip the "none connected" location (today Harbour) —
    // no historical-closed and no current-week open/projected snapshots,
    // so the Shift dashboard renders the existing "awaiting first
    // connection" empty state instead of a fabricated live shift.
    if (_isNoneConnectedDemoLocation(rid)) continue;
    final isDowntown = i == 0;

    final histShifts =
        _envelopeShiftsForLocation(replay.historicalClosedShifts, i, rid);
    final currentShifts =
        _envelopeShiftsForLocation(replay.currentWeekShifts, i, rid);

    OpenShiftSnapshot snapFor(ShiftRecord s, String status) {
      final bd = _businessDateFromWeekDay(s.weekId, s.dayLabel)!;
      return OpenShiftSnapshot(
        restaurantId: rid,
        weekId: s.weekId,
        dayLabel: s.dayLabel,
        daypart: s.daypart,
        status: status,
        businessDate: bd,
        businessTimingProfileId: s.businessTimingProfileId,
        businessTimingProfileVersionId: s.businessTimingProfileVersionId,
        servicePeriodKey: s.servicePeriodKey ?? s.daypart,
        forecastCovers: s.forecastCovers,
        currentCovers: status == 'projected' ? s.forecastCovers : s.covers,
        scheduledFohHours: s.scheduledFohHours ?? s.fohHours,
        scheduledBohHours: s.scheduledBohHours ?? s.bohHours,
        currentPPA: s.ppa,
        currentCPLH: s.cplh,
        currentSPLH: s.splh,
        blendedWage:
            double.parse(s.blendedWage.toStringAsFixed(2)),
        sourceSystem:
            s.sourceSystem ?? MockIntegrationReplaySeed.sourceSystem,
        sourceShiftId: MockIntegrationReplaySeed.snapshotSourceShiftId(
          weekId: s.weekId,
          dayLabel: s.dayLabel,
          daypart: s.daypart,
          status: status,
        ),
        // Deterministic, business-date-derived, strictly in the past so
        // it can never out-sort the live current-week rows.
        updatedAt: '${bd}T23:59:00.000Z',
      );
    }

    // Historical closed shifts → closed snapshots (all 4 locations).
    for (final s in histShifts) {
      if (s.status != 'closed') continue;
      batch.insert('open_shift_snapshots', snapFor(s, 'closed').toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    // Current-week coverage for the 3 non-Downtown locations only.
    // Downtown's current week is owned byte-for-byte by
    // `_seedOpenShiftSnapshotsFromReplay` (it ran earlier in both the
    // cold-boot and reseed/advance paths); the guard leaves it untouched.
    if (isDowntown) continue;
    // Mirror Downtown's current-week shape EXACTLY for this location
    // (its own scaled shifts → its own open/projected/closed figures).
    // `nowIsoUtc()` matches the Downtown seeder so this location's
    // `status='open'` row out-sorts its historical closed rows in
    // `getLatestOpenWeekId`.
    final currentWeekSnapshots = _buildCurrentWeekOpenShiftSnapshots(
      restaurantId: rid,
      currentWeekShifts: currentShifts,
      scenario: replay.scenario,
      now: nowIsoUtc(),
    );
    for (final snap in currentWeekSnapshots) {
      batch.insert('open_shift_snapshots', snap.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  await batch.commit(noResult: true);
}

/// Gap 1 — the FORWARD reservation book across all 4 locations.
///
/// Reuses the EXISTING covers→unseated ratio from
/// `_seedReservationBookSnapshotsFromReplay` (Friday baseline 72
/// unseated covers / 18 parties per 220 day covers) verbatim, applied to
/// every current-week projected/open cell, scaled by each location's
/// volume profile. Downtown's identity profile reproduces the existing
/// scenario open-shift row byte-for-byte (72 / 18 /
/// `demo_res_fri_dinner`), so the value the repository test pins is
/// preserved while the book now spans the whole forward week × 4
/// locations.
///
/// Honest-degrade (Metric Honesty / Design Rule 2): CLOSED/past cells
/// get NO row — a service that already closed has no live unseated
/// reservation book. A (day, daypart) the scenario does not serve has no
/// shift and therefore no row.
Future<void> _seedForwardReservationEnvelopeFromReplay(
  Database db,
  MockReplayOutput replay,
) async {
  const fridayBaseCovers = 220;
  const fridayUnseatedCovers = 72;
  const fridayUnseatedParties = 18;
  const dayBaseCovers = {
    'Mon': 140, 'Tue': 150, 'Wed': 160, 'Thu': 190,
    'Fri': 220, 'Sat': 230, 'Sun': 110,
  };

  final locations = DemoScope.locations;
  final batch = db.batch();

  for (var i = 0; i < locations.length; i++) {
    final rid = locations[i].restaurantId;
    // Honest-EMPTY: a "none connected" location has no reservation
    // vendor — no forward reservation book (today Harbour).
    if (_isNoneConnectedDemoLocation(rid)) continue;
    final volume = i == 0
        ? 1.0
        : _demoLocationProfiles[i < _demoLocationProfiles.length
                ? i
                : _demoLocationProfiles.length - 1]
            .volume;

    for (final s in replay.currentWeekShifts) {
      // Forward book only — closed/past cells have no live reservations.
      if (s.status == 'closed') continue;
      final bd = _businessDateFromWeekDay(s.weekId, s.dayLabel)!;
      final dayCovers =
          dayBaseCovers[s.dayLabel] ?? fridayBaseCovers;
      final coverRatio = dayCovers / fridayBaseCovers;
      final unseatedCovers =
          (fridayUnseatedCovers * coverRatio * volume).round();
      final unseatedParties =
          (fridayUnseatedParties * coverRatio * volume).round();
      if (unseatedCovers <= 0) continue; // honest-degrade
      batch.insert(
        'reservation_book_snapshots',
        ReservationBookSnapshot(
          restaurantId: rid,
          businessDate: bd,
          daypart: s.daypart,
          unseatedCovers: unseatedCovers,
          unseatedPartyCount: unseatedParties,
          sourceSystem: 'demo_reservations',
          sourceServiceId:
              'demo_res_${s.dayLabel.toLowerCase()}_${s.daypart}',
          // Deterministic — never DateTime.now() (idempotent reseed).
          updatedAt: '${bd}T00:00:00.000Z',
        ).toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  await batch.commit(noResult: true);
}

/// Gap 3 (highest value — the Item-5 dependency) — a locked
/// `weekly_plan_snapshots` row + its per-(business_date, service_period)
/// `weekly_plan_snapshot_day_dayparts` child rows, per location, for
/// every historical week + the current week.
///
/// The existing in-force Downtown snapshot
/// (`_seedWeeklyPlanSnapshotFromReplay`) is preserved untouched via the
/// `(restaurant_id, week_key)` existence guard — Promise 2 (closed truth
/// is not rewritten), and the Slice 3 contract test still reads exactly
/// that snapshot. Every other (location, week) cell is seeded here.
///
/// Per-period locked targets come from each location's active cycle's
/// per-period rows (`TargetCycleDao.getDaypartsForCycle`). Those rows
/// were built by `_buildDemoSeedCycle`/`_buildLocationSeedCycle` from
/// `MockIntegrationReplaySeed`'s daypart CPLH/SPLH/PPA/OPZ bands (or the
/// recommendation cohort over the band-stamped closed shifts) — i.e. the
/// child rows carry the differentiated per-daypart bands Item 5 reads,
/// never a whole-day pooled value.
Future<void> _seedHistoricalWeeklyPlanSnapshotsFromReplay(
  Database db,
  MockReplayOutput replay,
) async {
  if (!await _tableExists(db, 'weekly_plan_snapshots')) return;
  final scenario = replay.scenario;
  final locations = DemoScope.locations;
  final daoCycle = TargetCycleDao(db);

  for (var i = 0; i < locations.length; i++) {
    final rid = locations[i].restaurantId;
    // Honest-EMPTY: no locked weekly plan for a "none connected"
    // location (today Harbour) — the Plan surface honest-degrades.
    if (_isNoneConnectedDemoLocation(rid)) continue;

    final parentCycle = await daoCycle.getActiveCycle(rid);
    if (parentCycle == null) continue; // degrade silently (no cycle yet)
    final cycleDayparts =
        await daoCycle.getDaypartsForCycle(parentCycle.cycleId);
    if (cycleDayparts.isEmpty) continue; // no per-period bands → skip
    final cycle = parentCycle.copyWith(dayparts: cycleDayparts);

    // Configured week-start day for this location (North Loop's East
    // Region override is Sunday; everyone else Monday). Mirrors
    // `_seedWeeklyPlanSnapshotFromReplay`'s resolution.
    int weekStartDay = DateTime.monday;
    if (await _tableExists(db, 'restaurant_timing_configs')) {
      final cfg = await db.query(
        'restaurant_timing_configs',
        columns: const ['week_start_day'],
        where: 'restaurant_id = ?',
        whereArgs: [rid],
        limit: 1,
      );
      if (cfg.isNotEmpty) {
        final raw = cfg.first['week_start_day'];
        if (raw is int) {
          weekStartDay = raw;
        } else if (raw is num) {
          weekStartDay = raw.toInt();
        }
      }
    }

    final allShifts = <ShiftRecord>[
      ..._envelopeShiftsForLocation(replay.historicalClosedShifts, i, rid),
      ..._envelopeShiftsForLocation(replay.currentWeekShifts, i, rid),
    ];

    // Group every served cell by the configured business week.
    final byWeekKey = <String, List<ShiftRecord>>{};
    for (final s in allShifts) {
      final bd = _businessDateFromWeekDay(s.weekId, s.dayLabel);
      if (bd == null) continue;
      final ws = WeeklyPlanSnapshotPolicy.weekStartForDate(bd,
          weekStartDay: weekStartDay);
      final we = WeeklyPlanSnapshotPolicy.weekEndForDate(bd,
          weekStartDay: weekStartDay);
      final wk = WeeklyPlanSnapshotPolicy.weekKeyFromSpan(ws, we);
      (byWeekKey[wk] ??= <ShiftRecord>[]).add(s);
    }

    for (final entry in byWeekKey.entries) {
      final weekKey = entry.key;
      final weekShifts = entry.value;
      final parts = weekKey.split('_');
      if (parts.length != 2) continue;
      final weekStart = parts[0];
      final weekEnd = parts[1];

      // Preserve any already-locked snapshot for this week (the
      // existing in-force Downtown seeder, or a prior reseed's locked
      // truth). Closed truth is never rewritten (Promise 2).
      final existing = await db.query(
        'weekly_plan_snapshots',
        columns: const ['snapshot_id'],
        where: 'restaurant_id = ? AND week_key = ?',
        whereArgs: [rid, weekKey],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;

      // Per-(business_date, service_period) locked child rows, straight
      // from the served cells, judged against this location's cycle
      // per-period band targets (Design Rule 5 — per-period hours ×
      // whole-day wage).
      final children = <WeeklyPlanSnapshotDayDaypart>[];
      final dayAgg = <String, _SeedDayAgg>{};
      // Stable ordering so two reseeds are byte-identical.
      weekShifts.sort((a, b) {
        final c = a.dayLabel.compareTo(b.dayLabel);
        return c != 0 ? c : a.daypart.compareTo(b.daypart);
      });
      for (final s in weekShifts) {
        final cycleDp = cycle.daypartFor(s.daypart);
        if (cycleDp == null) continue;
        final bd = _businessDateFromWeekDay(s.weekId, s.dayLabel)!;
        final covers = s.forecastCovers; // the locked plan is a forecast
        if (covers <= 0) continue; // honest-degrade
        final sales = covers * cycleDp.targetPPA;
        final reqFoh =
            cycleDp.targetCPLH > 0 ? covers / cycleDp.targetCPLH : 0.0;
        final reqBoh =
            cycleDp.targetSPLH > 0 ? sales / cycleDp.targetSPLH : 0.0;
        final fohDollars = reqFoh * cycle.fohWage;
        final bohDollars = reqBoh * cycle.bohWage;
        children.add(WeeklyPlanSnapshotDayDaypart(
          businessDate: bd,
          servicePeriodId: s.daypart,
          forecastCovers: covers,
          forecastSales: sales,
          requiredFohHours: reqFoh,
          requiredBohHours: reqBoh,
          theoreticalFohDollars: fohDollars,
          theoreticalBohDollars: bohDollars,
        ));
        final agg = dayAgg.putIfAbsent(
            bd, () => _SeedDayAgg(day: s.dayLabel));
        agg.covers += covers;
        agg.sales += sales;
        agg.foh += reqFoh;
        agg.boh += reqBoh;
      }
      if (children.isEmpty) continue;

      // Parent day rows = Σ of the child rows (pool consistency:
      // parent == cover-weighted Σ of per-period rows).
      final dayDates = dayAgg.keys.toList()..sort();
      final dayRows = <WeeklyPlanSnapshotDay>[
        for (final d in dayDates)
          WeeklyPlanSnapshotDay(
            day: dayAgg[d]!.day,
            businessDate: d,
            forecastCovers: dayAgg[d]!.covers,
            forecastSales: dayAgg[d]!.sales,
            requiredFohHours: dayAgg[d]!.foh.round(),
            requiredBohHours: dayAgg[d]!.boh.round(),
          ),
      ];

      final totalCovers =
          dayAgg.values.fold<int>(0, (a, v) => a + v.covers);
      final totalSales =
          dayAgg.values.fold<double>(0, (a, v) => a + v.sales);
      final totalFoh =
          dayAgg.values.fold<double>(0, (a, v) => a + v.foh);
      final totalBoh =
          dayAgg.values.fold<double>(0, (a, v) => a + v.boh);
      final totalFohDollars =
          children.fold<double>(0, (a, c) => a + c.theoreticalFohDollars);
      final totalBohDollars =
          children.fold<double>(0, (a, c) => a + c.theoreticalBohDollars);

      final isInForce = scenario.currentBusinessDate.compareTo(weekStart) >=
              0 &&
          scenario.currentBusinessDate.compareTo(weekEnd) <= 0;
      // Deterministic lock instant — locked at the close of the week
      // (never DateTime.now(); idempotent across reseeds).
      final lockTs = '${weekEnd}T23:59:00.000Z';

      final snapshot = WeeklyPlanSnapshot(
        snapshotId:
            '${rid}_snapshot_${weekStart.replaceAll('-', '')}',
        restaurantId: rid,
        weekStartDate: weekStart,
        weekEndDate: weekEnd,
        targetCycleId: cycle.cycleId,
        forecastCovers: totalCovers,
        forecastSales: totalSales,
        requiredFohHours: totalFoh.round(),
        requiredBohHours: totalBoh.round(),
        theoreticalFohLaborDollars: totalFohDollars,
        theoreticalBohLaborDollars: totalBohDollars,
        coversSource:
            ForecastDemandSource.appDerivedFromHistoricalAverage,
        salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
        generatedAt: lockTs,
        lockedAt: lockTs,
        dayRows: dayRows,
        dayDayparts: children,
        wageAtLockTime: WeeklyPlanSnapshotWagesAtLockTime(
          fohWage: cycle.fohWage,
          bohWage: cycle.bohWage,
          blendedWage: ActiveTargetProfile.computeTargetBlendedWage(
            targetCPLH: cycle.targetCPLH,
            targetSPLH: cycle.targetSPLH,
            targetPPA: cycle.targetPPA,
            fohWage: cycle.fohWage,
            bohWage: cycle.bohWage,
          ),
        ),
        isActive: isInForce,
      );

      // Persist via the same map shape WeeklyPlanSnapshotDao.upsertSnapshot
      // writes (inlined — the DAO can't be reached during _onCreate).
      final map = snapshot.toMap();
      final encodedDayRows =
          jsonEncode(map.remove('day_rows') as List<dynamic>);
      final forecastContext = map.remove('forecast_context');
      final dayDaypartsToPersist =
          (map.remove('day_dayparts') as List<dynamic>? ??
              const <dynamic>[]);
      final wageAtLockTimeJson = map.remove('wage_at_lock_time_json');
      map['wage_at_lock_time_json'] = wageAtLockTimeJson == null
          ? null
          : jsonEncode(wageAtLockTimeJson);
      map['day_rows_json'] = encodedDayRows;
      map['forecast_context_json'] =
          forecastContext == null ? null : jsonEncode(forecastContext);
      if (map.containsKey('metadata')) {
        final rawMetadata = map['metadata'];
        map['metadata'] =
            rawMetadata == null ? null : jsonEncode(rawMetadata);
      }
      if (map.containsKey('is_active')) {
        final raw = map['is_active'];
        if (raw is bool) map['is_active'] = raw ? 1 : 0;
      }
      await db.insert('weekly_plan_snapshots', map,
          conflictAlgorithm: ConflictAlgorithm.replace);

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
          dp['created_at'] = lockTs;
          childBatch.insert('weekly_plan_snapshot_day_dayparts', dp);
        }
        await childBatch.commit(noResult: true);
      }
    }
  }
}

/// Per-day aggregate accumulator for the locked-plan parent day rows
/// (parent == Σ of the per-period child rows — pool consistency).
class _SeedDayAgg {
  _SeedDayAgg({required this.day});
  final String day;
  int covers = 0;
  double sales = 0;
  double foh = 0;
  double boh = 0;
}

/// Gap 5 — a modest, deterministic sample inbox per (operator,
/// location).
///
/// HP #2: standard `app_notifications` table, scoped by `restaurant_id`.
/// Event keys/types are recognized catalog/legacy keys so
/// `NotificationsScreen` renders them with the correct icon + accent +
/// training-tone copy. Distinct from `_seedDemoVarianceBreachNotification`
/// (`type='variance_breach'`) — no overlap, so the Slice F
/// variance-breach determinism/HP-#4 assertions are unaffected.
///
/// Deterministic + idempotent: fixed `event_key` per (location, kind),
/// `created_at` derived from the scenario business date (never
/// `DateTime.now()`), `ConflictAlgorithm.ignore` against the
/// `UNIQUE(restaurant_id, event_key)` constraint. `reseedDemo` clears
/// `app_notifications` then this re-seeds the identical rows → two
/// reseeds byte-identical.
Future<void> _seedDemoSampleNotifications(
  Database db,
  MockReplayOutput replay,
) async {
  if (!await _tableExists(db, 'app_notifications')) return;
  final base = replay.scenario.currentBusinessDate;

  const templates = <_DemoNoticeTemplate>[
    _DemoNoticeTemplate(
      kind: 'first_connect_backfill_complete',
      type: 'notif.backfill.complete',
      title: 'First Connect backfill complete',
      body: 'Your last 60 days of point-of-sale history finished loading. '
          'Benchmarks and the weekly plan now reflect a full cycle of '
          'real services.',
      daysBefore: 9,
      read: true,
    ),
    _DemoNoticeTemplate(
      kind: 'weekly_plan_locked',
      type: 'notif.plan.updated',
      title: 'This week\'s plan is locked',
      body: 'The operating plan for the current week is locked in. Open '
          'Shift to see the per-daypart cover, hour, and labor targets '
          'you are running against.',
      daysBefore: 1,
      read: false,
    ),
    _DemoNoticeTemplate(
      kind: 'target_cycle_refreshed',
      type: 'cycle_rollover',
      title: 'Target cycle refreshed',
      body: 'A new 60-day target cycle is now in force. Benchmarks '
          'recalibrated from the most recent closed services — review the '
          'new lunch, dinner, and late-night targets.',
      daysBefore: 6,
      read: true,
    ),
    _DemoNoticeTemplate(
      kind: 'reservation_vendor_available',
      type: 'notif.vendor.now_available',
      title: 'A reservation integration is ready to connect',
      body: 'A reservation provider you can link is now available. '
          'Connecting it lets Forge & Flow factor unseated covers into '
          'the live shift view.',
      daysBefore: 3,
      read: false,
    ),
  ];

  final locations = DemoScope.locations;
  final batch = db.batch();
  for (final loc in locations) {
    final rid = loc.restaurantId;
    // Honest-EMPTY: a "none connected" location (today Harbour) has no
    // backfill / plan-locked / cycle-refreshed events to show — those
    // sample notices would be phantom data for a location awaiting its
    // first connection. The bell stays honestly empty for it.
    if (_isNoneConnectedDemoLocation(rid)) continue;
    for (final t in templates) {
      final type = t.type;
      final title = t.title;
      final body = t.body;
      final bd = _subtractIsoDays(base, t.daysBefore);
      final eventKey = 'demo_seed_${t.kind}';
      batch.insert(
        'app_notifications',
        {
          'notification_id': '${rid}_$eventKey',
          'restaurant_id': rid,
          'type': type,
          'event_key': eventKey,
          'title': title,
          'body': body,
          'business_date': bd,
          // Deterministic — derived from the scenario date, fixed time
          // component; never DateTime.now() (idempotent reseed).
          'created_at': '${bd}T13:00:00.000Z',
          'read_at': t.read ? '${bd}T18:30:00.000Z' : null,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }
  await batch.commit(noResult: true);
}

/// Deterministic sample-notification template (no RNG; fixed copy).
class _DemoNoticeTemplate {
  const _DemoNoticeTemplate({
    required this.kind,
    required this.type,
    required this.title,
    required this.body,
    required this.daysBefore,
    required this.read,
  });

  final String kind;
  final String type;
  final String title;
  final String body;
  final int daysBefore;
  final bool read;
}

