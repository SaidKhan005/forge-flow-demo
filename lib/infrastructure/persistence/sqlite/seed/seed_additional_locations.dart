// Part of sqlite_database.dart. Per-location closed history + cycles for the non-Downtown demo sites.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

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
  final forecastCovers = (s.forecastCovers * p.volume).round().clamp(10, 9999);
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
      : (s.scheduledFohHours! * p.volume / p.cplh).round().clamp(1, 999999);
  final scheduledBoh = s.scheduledBohHours == null
      ? null
      : (s.scheduledBohHours! * p.volume * p.ppa / p.splh).round().clamp(
          1,
          999999,
        );
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
    'total_foh_hours': (n(w['total_foh_hours']) * p.volume / p.cplh).round(),
    'total_boh_hours': (n(w['total_boh_hours']) * p.volume * p.ppa / p.splh)
        .round(),
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
  final candidates = _seedRecommendationCandidates(
    replay,
    businessDate: businessDate,
  );
  final recommendation = RecommendedBenchmarkSelectionService.instance.select(
    candidates,
  );

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
    final profile =
        _demoLocationProfiles[i < _demoLocationProfiles.length
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

    final atProfile = TargetCycleActiveTargetProfileProjector.project(cycle);
    await db.insert(
      'active_target_profiles',
      atProfile.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.insert('target_profile_versions', {
      'target_profile_version_id': atProfile.targetProfileVersionId,
      'target_profile_id': atProfile.targetProfileId,
      'restaurant_id': restaurantId,
      'target_cycle_id': cycle.cycleId,
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
      'created_at': atProfile.builtAt,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);

    final versionId = 'compat_${restaurantId}_v8_backfill';
    await db.insert('target_profile_versions', {
      'target_profile_version_id': versionId,
      'target_profile_id': atProfile.targetProfileId,
      'restaurant_id': restaurantId,
      'target_cycle_id': cycle.cycleId,
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
      defaultTheoreticalFohLaborPct: atProfile.theoreticalFohLaborPct,
      defaultTheoreticalBohLaborPct: atProfile.theoreticalBohLaborPct,
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
      batch.insert(
        'week_records',
        scaledW,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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
