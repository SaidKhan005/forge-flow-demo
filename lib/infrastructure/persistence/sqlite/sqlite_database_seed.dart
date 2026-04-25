// Phase 7.55o.6 — SQLite demo + mock-replay seed helpers.
//
// Part of sqlite_database.dart. Owns the demo-seed entrypoints
// (`_seedDemoRestaurant`, `_seedDemoTimingConfig`,
// `_seedDemoActiveTargetProfile`, `_loadSeedAuthorityProfile`,
// `_ensureDemoSeedCycle`, `_seedDemoDataFromReplay`,
// `_ensureDemoRestaurant`), the replay snapshot seeders
// (`_seedOpenShiftSnapshotsFromReplay`,
// `_seedReservationBookSnapshotsFromReplay`), the locked-target
// backfill (`_backfillLockedTargets`), and the small helper
// functions (`_seedRecommendationCandidates`, `_addIsoDays`,
// `_deterministicHash`). Seed content is unchanged.

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
  await db.insert(
    'restaurant_timing_configs',
    {
      'restaurant_id': DemoScope.restaurantId,
      'business_day_start_local_time': '04:00',
      'week_start_day': DateTime.monday,
      'service_period_definitions_json': jsonEncode(demoServicePeriods),
      'shift_close_authority': 'app_local_cutoff_fallback',
      'local_close_fallback': '04:00',
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
  await db.insert(
    'target_cycles',
    cycle.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  return cycle;
}

TargetCycle _buildDemoSeedCycle({
  required String businessDate,
  double? fohWageOverride,
  double? bohWageOverride,
  required MockReplayOutput replay,
}) {
  final recommendation = RecommendedBenchmarkSelectionService.instance.select(
    _seedRecommendationCandidates(
      replay,
      businessDate: businessDate,
    ),
  );
  final isInsufficient = recommendation.isInsufficient;

  return TargetCycle(
    cycleId: 'demo_cycle_$businessDate',
    restaurantId: DemoScope.restaurantId,
    source: TargetCycleSource.recommended,
    effectiveStart: businessDate,
    effectiveEnd: _addIsoDays(businessDate, 59),
    calibrationWindowStart: _addIsoDays(businessDate, -59),
    calibrationWindowEnd: businessDate,
    targetCPLH: isInsufficient
        ? MeridianConfig.targetCPLH
        : recommendation.pooledRecommendedTargetCPLH,
    targetSPLH: isInsufficient
        ? MeridianConfig.targetSPLH
        : recommendation.pooledRecommendedTargetSPLH,
    targetPPA: isInsufficient
        ? MeridianConfig.targetPPA
        : recommendation.pooledRecommendedTargetPPA,
    fohWage: fohWageOverride ?? MeridianConfig.fohWage,
    bohWage: bohWageOverride ?? MeridianConfig.bohWage,
    opzFloorCPLH: isInsufficient
        ? MeridianConfig.opzFloorCPLH
        : recommendation.unionOpzFloorCPLH,
    opzCeilingCPLH: isInsufficient
        ? MeridianConfig.opzCeilingCPLH
        : recommendation.unionOpzCeilingCPLH,
    createdAt: nowIsoUtc(),
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

