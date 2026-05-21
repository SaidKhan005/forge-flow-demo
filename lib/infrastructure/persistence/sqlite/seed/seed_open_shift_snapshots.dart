// Part of sqlite_database.dart. Current-week open_shift_snapshots builder + Downtown replay seeder.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

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
  final projectedShifts = currentWeekShifts
      .where((s) => s.isProjected)
      .toList();

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

    snapshots.add(
      OpenShiftSnapshot(
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
      ),
    );
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
  final openSourceShiftId = MockIntegrationReplaySeed.openShiftSourceShiftIdFor(
    scenario,
  );

  if (openDaypart != null && openSourceShiftId != null) {
    final progress =
        scenario.openProgressFraction ??
        MockIntegrationReplaySeed.openProgressFraction;
    final matches = currentWeekShifts.where(
      (s) =>
          s.dayLabel == scenario.openShiftDayLabel && s.daypart == openDaypart,
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

      snapshots.add(
        OpenShiftSnapshot(
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
          blendedWage: double.parse(
            openShiftPlan.blendedWage.toStringAsFixed(2),
          ),
          timeLabel:
              scenario.openTimeLabel ??
              MockIntegrationReplaySeed.openShiftTimeLabel,
          serviceElapsedLabel:
              scenario.openServiceElapsedLabel ??
              MockIntegrationReplaySeed.openShiftServiceElapsedLabel,
          sourceSystem: MockIntegrationReplaySeed.sourceSystem,
          sourceShiftId: openSourceShiftId,
          updatedAt: now,
        ),
      );
    }
  }

  // Seed closed dayparts for the open shift's day (whole-day aggregation).
  final currentDayClosed = currentWeekShifts
      .where(
        (s) => s.dayLabel == scenario.openShiftDayLabel && s.status == 'closed',
      )
      .toList();
  for (final s in currentDayClosed) {
    snapshots.add(
      OpenShiftSnapshot(
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
      ),
    );
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
  Database db,
  MockReplayOutput replay,
) async {
  final snapshots = _buildCurrentWeekOpenShiftSnapshots(
    restaurantId: DemoScope.restaurantId,
    currentWeekShifts: replay.currentWeekShifts,
    scenario: replay.scenario,
    now: nowIsoUtc(),
  );

  final batch = db.batch();
  for (final snap in snapshots) {
    batch.insert(
      'open_shift_snapshots',
      snap.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  await batch.commit(noResult: true);
}
