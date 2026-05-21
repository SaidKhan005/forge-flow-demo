// Part of sqlite_database.dart. Per-location operational envelope seeders (snapshots/reservations/plans/notices).
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

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
  final profile =
      _demoLocationProfiles[locationIndex < _demoLocationProfiles.length
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

    final histShifts = _envelopeShiftsForLocation(
      replay.historicalClosedShifts,
      i,
      rid,
    );
    final currentShifts = _envelopeShiftsForLocation(
      replay.currentWeekShifts,
      i,
      rid,
    );

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
        blendedWage: double.parse(s.blendedWage.toStringAsFixed(2)),
        sourceSystem: s.sourceSystem ?? MockIntegrationReplaySeed.sourceSystem,
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
      batch.insert(
        'open_shift_snapshots',
        snapFor(s, 'closed').toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
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
      batch.insert(
        'open_shift_snapshots',
        snap.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  await batch.commit(noResult: true);
}

/// Gap 1 — the FORWARD reservation book across all 4 locations.
///
/// Reuses the EXISTING covers→unseated ratio from
/// `_seedReservationBookSnapshotsFromReplay` (Friday baseline 72
/// unseated covers / 18 parties per 220 *whole-day* covers), applied to
/// every current-week projected/open cell, scaled by each location's
/// volume profile.
///
/// Double-count fix: 72 / 18 is a WHOLE-DAY figure (the comment + the
/// `fridayUnseatedCovers / fridayBaseCovers` ratio are both day-level —
/// 72 unseated per 220 *day* covers). Writing it into every served
/// daypart row at full value made the Shift dashboard whole-day read
/// model (`SqliteReservationBookSnapshotRepository.getForDay` summed
/// across all dayparts in `ShiftDashboardNotifier._buildDayReadModel`)
/// count it once per daypart — a day with two open/projected periods
/// reported 2x (72 → 144). The day's unseated covers are now apportioned
/// across that day's served periods by the SAME `_daypartRatios` split
/// the closed-shift generator uses for cover distribution, so the
/// per-daypart rows sum back to exactly the intended whole-day total
/// (Downtown Friday = 72) instead of replicating it per period. Parties
/// are apportioned the same way. The largest-share period absorbs any
/// integer-rounding remainder so the day still sums exactly to the
/// whole-day baseline.
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
    'Mon': 140,
    'Tue': 150,
    'Wed': 160,
    'Thu': 190,
    'Fri': 220,
    'Sat': 230,
    'Sun': 110,
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

    // Group the forward (non-closed) cells by day so the WHOLE-DAY
    // unseated baseline is computed once per day and then apportioned
    // across that day's served periods — never replicated per period.
    final byDay = <String, List<ShiftRecord>>{};
    for (final s in replay.currentWeekShifts) {
      // Forward book only — closed/past cells have no live reservations.
      if (s.status == 'closed') continue;
      byDay.putIfAbsent(s.dayLabel, () => <ShiftRecord>[]).add(s);
    }

    for (final entry in byDay.entries) {
      final dayLabel = entry.key;
      final dayCovers = dayBaseCovers[dayLabel] ?? fridayBaseCovers;
      final coverRatio = dayCovers / fridayBaseCovers;
      // WHOLE-DAY unseated covers/parties for this location-day.
      final dayUnseatedCovers = (fridayUnseatedCovers * coverRatio * volume)
          .round();
      final dayUnseatedParties = (fridayUnseatedParties * coverRatio * volume)
          .round();
      if (dayUnseatedCovers <= 0) continue; // honest-degrade

      // Cover-share weight per served period (same split the rest of
      // the demo uses). Drop zero-share periods so they get no row.
      final served = entry.value
          .where(
            (s) =>
                MockIntegrationReplaySeed.daypartCoverShare(
                  dayLabel,
                  s.daypart,
                ) >
                0.0,
          )
          .toList();
      if (served.isEmpty) continue;
      // Largest-share period FIRST. Every other period gets its rounded
      // share; the largest-share period (index 0) absorbs whatever
      // remainder is left, so the day's rows sum EXACTLY to the
      // whole-day baseline with no rounding drift and the remainder
      // always lands on a comfortably-positive row (deterministic —
      // replay is pure, no RNG).
      served.sort(
        (a, b) =>
            MockIntegrationReplaySeed.daypartCoverShare(
              dayLabel,
              b.daypart,
            ).compareTo(
              MockIntegrationReplaySeed.daypartCoverShare(dayLabel, a.daypart),
            ),
      );

      // Pre-compute the non-largest periods' rounded shares; the largest
      // takes the remainder.
      final partCoversByIdx = List<int>.filled(served.length, 0);
      final partPartiesByIdx = List<int>.filled(served.length, 0);
      var coversRemainder = dayUnseatedCovers;
      var partiesRemainder = dayUnseatedParties;
      for (var idx = served.length - 1; idx >= 1; idx--) {
        final share = MockIntegrationReplaySeed.daypartCoverShare(
          dayLabel,
          served[idx].daypart,
        );
        final c = (dayUnseatedCovers * share).round();
        final p = (dayUnseatedParties * share).round();
        partCoversByIdx[idx] = c;
        partPartiesByIdx[idx] = p;
        coversRemainder -= c;
        partiesRemainder -= p;
      }
      // Largest-share period (idx 0) takes the remainder. Clamp to >= 0
      // (defensive — with these ratios the remainder is always the
      // dominant positive share).
      partCoversByIdx[0] = coversRemainder < 0 ? 0 : coversRemainder;
      partPartiesByIdx[0] = partiesRemainder < 0 ? 0 : partiesRemainder;

      for (var idx = 0; idx < served.length; idx++) {
        final s = served[idx];
        final partCovers = partCoversByIdx[idx];
        if (partCovers <= 0) continue; // honest-degrade (no phantom row)
        final bd = _businessDateFromWeekDay(s.weekId, s.dayLabel)!;
        batch.insert(
          'reservation_book_snapshots',
          ReservationBookSnapshot(
            restaurantId: rid,
            businessDate: bd,
            daypart: s.daypart,
            unseatedCovers: partCovers,
            unseatedPartyCount: partPartiesByIdx[idx],
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
    final cycleDayparts = await daoCycle.getDaypartsForCycle(
      parentCycle.cycleId,
    );
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
      final ws = WeeklyPlanSnapshotPolicy.weekStartForDate(
        bd,
        weekStartDay: weekStartDay,
      );
      final we = WeeklyPlanSnapshotPolicy.weekEndForDate(
        bd,
        weekStartDay: weekStartDay,
      );
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
        final reqFoh = cycleDp.targetCPLH > 0
            ? covers / cycleDp.targetCPLH
            : 0.0;
        final reqBoh = cycleDp.targetSPLH > 0
            ? sales / cycleDp.targetSPLH
            : 0.0;
        final fohDollars = reqFoh * cycle.fohWage;
        final bohDollars = reqBoh * cycle.bohWage;
        children.add(
          WeeklyPlanSnapshotDayDaypart(
            businessDate: bd,
            servicePeriodId: s.daypart,
            forecastCovers: covers,
            forecastSales: sales,
            requiredFohHours: reqFoh,
            requiredBohHours: reqBoh,
            theoreticalFohDollars: fohDollars,
            theoreticalBohDollars: bohDollars,
          ),
        );
        final agg = dayAgg.putIfAbsent(bd, () => _SeedDayAgg(day: s.dayLabel));
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

      // Per-Daypart V1 (bottom-up locked snapshot, PR #917 parity):
      // reconcile through the SHARED
      // `WeeklyPlanSnapshotBottomUpReconciler.reconcile` instead of
      // hand-rolling Σ(per-period) here. This historical seeder was
      // another divergent writer — its week hours were
      // `Σ(all per-period hrs).round()` (sum-then-round) while the
      // runtime lock path is `Σ(per-day rounded hrs)` (round-then-sum);
      // the shared reconciler is the single canonical implementation so
      // all three writers (runtime + both seed sites) agree by
      // construction (HP #2). Per-period rows (`children`) keep their
      // per-period rate fidelity unchanged. `children` is guaranteed
      // non-empty here (`if (children.isEmpty) continue;` above), so the
      // synthetic plan below is only the never-hit Gap-42 empty
      // fallback; it still carries honest pre-reconcile totals.
      final fallbackTheoreticalTotal =
          children.fold<double>(0, (a, c) => a + c.theoreticalFohDollars) +
          children.fold<double>(0, (a, c) => a + c.theoreticalBohDollars);
      final fallbackCovers = dayAgg.values.fold<int>(0, (a, v) => a + v.covers);
      final fallbackSales = dayAgg.values.fold<double>(
        0,
        (a, v) => a + v.sales,
      );
      final fallbackPlan = SchedulePlan(
        forecastCovers: fallbackCovers,
        forecastSales: fallbackSales,
        requiredFohHours: dayAgg.values
            .fold<double>(0, (a, v) => a + v.foh)
            .round(),
        requiredBohHours: dayAgg.values
            .fold<double>(0, (a, v) => a + v.boh)
            .round(),
        theoreticalFohLaborDollars: children.fold<double>(
          0,
          (a, c) => a + c.theoreticalFohDollars,
        ),
        theoreticalBohLaborDollars: children.fold<double>(
          0,
          (a, c) => a + c.theoreticalBohDollars,
        ),
        theoreticalLaborPct: fallbackSales > 0
            ? fallbackTheoreticalTotal / fallbackSales * 100
            : 0.0,
        targetBlendedWage: ActiveTargetProfile.computeTargetBlendedWage(
          targetCPLH: cycle.targetCPLH,
          targetSPLH: cycle.targetSPLH,
          targetPPA: cycle.targetPPA,
          fohWage: cycle.fohWage,
          bohWage: cycle.bohWage,
        ),
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
      );
      final reconciled = WeeklyPlanSnapshotBottomUpReconciler.reconcile(
        plan: fallbackPlan,
        dayRows: dayRows,
        dayDayparts: children,
      );

      final isInForce =
          scenario.currentBusinessDate.compareTo(weekStart) >= 0 &&
          scenario.currentBusinessDate.compareTo(weekEnd) <= 0;
      // Deterministic lock instant — locked at the close of the week
      // (never DateTime.now(); idempotent across reseeds).
      final lockTs = '${weekEnd}T23:59:00.000Z';

      final snapshot = WeeklyPlanSnapshot(
        snapshotId: '${rid}_snapshot_${weekStart.replaceAll('-', '')}',
        restaurantId: rid,
        weekStartDate: weekStart,
        weekEndDate: weekEnd,
        targetCycleId: cycle.cycleId,
        forecastCovers: reconciled.weekCovers,
        forecastSales: reconciled.weekSales,
        requiredFohHours: reconciled.weekFohHours,
        requiredBohHours: reconciled.weekBohHours,
        theoreticalFohLaborDollars: reconciled.weekFohDollars,
        theoreticalBohLaborDollars: reconciled.weekBohDollars,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
        generatedAt: lockTs,
        lockedAt: lockTs,
        dayRows: reconciled.dayRows,
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
      final encodedDayRows = jsonEncode(
        map.remove('day_rows') as List<dynamic>,
      );
      final forecastContext = map.remove('forecast_context');
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
        if (raw is bool) map['is_active'] = raw ? 1 : 0;
      }
      await db.insert(
        'weekly_plan_snapshots',
        map,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

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
      body:
          'Your last 60 days of point-of-sale history finished loading. '
          'Benchmarks and the weekly plan now reflect a full cycle of '
          'real services.',
      daysBefore: 9,
      read: true,
    ),
    _DemoNoticeTemplate(
      kind: 'weekly_plan_locked',
      type: 'notif.plan.updated',
      title: 'This week\'s plan is locked',
      body:
          'The operating plan for the current week is locked in. Open '
          'Shift to see the per-daypart cover, hour, and labor targets '
          'you are running against.',
      daysBefore: 1,
      read: false,
    ),
    _DemoNoticeTemplate(
      kind: 'target_cycle_refreshed',
      type: 'cycle_rollover',
      title: 'Target cycle refreshed',
      body:
          'A new 60-day target cycle is now in force. Benchmarks '
          'recalibrated from the most recent closed services — review the '
          'new lunch, dinner, and late-night targets.',
      daysBefore: 6,
      read: true,
    ),
    _DemoNoticeTemplate(
      kind: 'reservation_vendor_available',
      type: 'notif.vendor.now_available',
      title: 'A reservation integration is ready to connect',
      body:
          'A reservation provider you can link is now available. '
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
      batch.insert('app_notifications', {
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
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
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
