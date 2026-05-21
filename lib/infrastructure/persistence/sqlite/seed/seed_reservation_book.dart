// Part of sqlite_database.dart. Open-shift reservation_book_snapshots seeder.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

/// Seeds a reservation book snapshot for the scenario's open shift.
///
/// Unseated covers scale deterministically with the day's base cover
/// volume. The 72 / 18 Friday baseline is a WHOLE-DAY figure (72
/// unseated per 220 *day* covers), so the open period's row carries only
/// that period's cover-share slice of the whole-day total — NOT the
/// whole-day figure replicated onto one period. This keeps the row
/// consistent with `_seedForwardReservationEnvelopeFromReplay` (which
/// runs AFTER this and authoritatively re-seeds the whole forward book
/// with the same per-period apportionment, so the Shift dashboard
/// whole-day read model — which sums every daypart row for the day —
/// sees the day's unseated covers exactly once, never doubled).
Future<void> _seedReservationBookSnapshotsFromReplay(
  Database db,
  MockReplayOutput replay,
) async {
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

  // Scale unseated covers from Friday WHOLE-DAY baseline (72) by
  // day-volume ratio, then take only this period's cover-share slice.
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
  final dayLabel = scenario.openShiftDayLabel;
  final dayCovers = dayBaseCovers[dayLabel] ?? fridayBaseCovers;
  final coverRatio = dayCovers / fridayBaseCovers;
  final dayUnseatedCovers = fridayUnseatedCovers * coverRatio;
  final dayUnseatedParties = fridayUnseatedParties * coverRatio;
  final share = MockIntegrationReplaySeed.daypartCoverShare(
    dayLabel,
    scenarioDaypart,
  );
  final unseatedCovers = (dayUnseatedCovers * share).round();
  final unseatedParties = (dayUnseatedParties * share).round();
  // Honest-degrade: a period the scenario does not serve (zero share)
  // gets no row. The forward envelope still covers every served cell.
  if (unseatedCovers <= 0) return;

  final snapshot = ReservationBookSnapshot(
    restaurantId: DemoScope.restaurantId,
    businessDate: scenario.currentBusinessDate,
    daypart: scenarioDaypart,
    unseatedCovers: unseatedCovers,
    unseatedPartyCount: unseatedParties,
    sourceSystem: 'demo_reservations',
    sourceServiceId: 'demo_res_${dayLabel.toLowerCase()}_$scenarioDaypart',
    updatedAt: now,
  );
  await db.insert(
    'reservation_book_snapshots',
    snapshot.toMap(),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}
