// Part of sqlite_database.dart. Active target profile, demo seed cycle, dayparts, and wage_role_rows.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

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
  await db.insert(
    'active_target_profiles',
    profile.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  final versionId = profile.targetProfileVersionId;
  if (versionId != null && versionId.trim().isNotEmpty) {
    final versionMap = <String, Object?>{
      'target_profile_version_id': versionId,
      'target_profile_id': profile.targetProfileId,
      'restaurant_id': profile.restaurantId,
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
      'created_at': profile.builtAt,
    };
    if (await _columnExists(db, 'target_profile_versions', 'target_cycle_id')) {
      versionMap['target_cycle_id'] = profile.targetCycleId;
    }
    await db.insert(
      'target_profile_versions',
      versionMap,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }
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
    final hasRealBand =
        stats != null &&
        stats.opzCeilingCPLH > 0 &&
        stats.recommendedTargetCPLH > 0;
    if (hasRealBand) {
      dayparts.add(
        TargetCycleDaypart(
          servicePeriodId: periodId,
          targetCPLH: stats.recommendedTargetCPLH,
          targetSPLH: stats.recommendedTargetSPLH,
          targetPPA: stats.recommendedTargetPPA,
          opzFloorCPLH: stats.opzFloorCPLH,
          opzCeilingCPLH: stats.opzCeilingCPLH,
          coverCount: coverCount,
          verdict: stats.verdict,
          verdictReason: stats.verdictReason,
        ),
      );
    } else {
      final band = MockIntegrationReplaySeed.demoDaypartTargetBand(periodId)!;
      dayparts.add(
        TargetCycleDaypart(
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
        ),
      );
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
  final recommendation = RecommendedBenchmarkSelectionService.instance.select(
    candidates,
  );

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
      .where(
        (shift) =>
            shift.businessDate != null &&
            shift.businessDate!.compareTo(startDate) >= 0 &&
            shift.businessDate!.compareTo(businessDate) <= 0,
      )
      .map(
        (shift) => BaselineCandidateShift(
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
        ),
      )
      .toList();
}

/// Weighted average hourly rate from raw DB rows for a given labor bucket.
double? _weightedAvgFromRows(List<Map<String, dynamic>> rows, String bucket) {
  final filtered = rows.where((r) => r['labor_bucket'] == bucket).toList();
  if (filtered.isEmpty) return null;
  final totalHours = filtered.fold<double>(
    0,
    (s, r) => s + (r['weighted_hours'] as num).toDouble(),
  );
  if (totalHours <= 0) return null;
  final totalDollars = filtered.fold<double>(
    0,
    (s, r) =>
        s +
        (r['hourly_rate'] as num).toDouble() *
            (r['weighted_hours'] as num).toDouble(),
  );
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
    batch.insert('wage_role_rows', {
      'restaurant_id': DemoScope.restaurantId,
      'role_name': r['role_name'],
      'labor_bucket': r['labor_bucket'],
      'hourly_rate': r['hourly_rate'],
      'weighted_hours': r['weighted_hours'],
      'source': 'demo_seed',
      'is_active': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }
  await batch.commit(noResult: true);
}

String _addIsoDays(String isoDate, int days) {
  final result = DateTime.parse(isoDate).add(Duration(days: days));
  return '${result.year}-${result.month.toString().padLeft(2, '0')}'
      '-${result.day.toString().padLeft(2, '0')}';
}
