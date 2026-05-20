// Phase 7.56 — Reservation book snapshot repository tests.
//
// Double-count fix (claude/fix-reservation-inthebooks-double-count):
// the demo reservation book's 72 / 18 Friday baseline is a WHOLE-DAY
// figure. The forward envelope now apportions it across the day's
// served periods by cover share instead of replicating the whole-day
// figure onto every period, so the Shift dashboard whole-day read model
// (which sums every daypart row for the day) counts the day's unseated
// covers exactly once. These tests pin the corrected invariant: the
// per-period rows SUM to the whole-day baseline (72 covers / 18 parties
// for Downtown Friday), and no single period carries the whole-day
// figure.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/reservation_book_snapshot.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_reservation_book_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

void main() {
  setUp(setUpSqliteDemo);

  test('reseed creates the demo reservation book — day sums to 72 / 18',
      () async {
    final repo = SqliteReservationBookSnapshotRepository.instance;
    // Whole-day invariant: every daypart row for Downtown Friday sums to
    // exactly the whole-day baseline (single-counted — no per-period
    // replication of the whole-day figure).
    final dayRows =
        await repo.getForDay('demo_restaurant_001', '2026-03-27');
    expect(dayRows, isNotEmpty);
    final dayCovers =
        dayRows.fold<int>(0, (s, r) => s + r.unseatedCovers);
    final dayParties =
        dayRows.fold<int>(0, (s, r) => s + r.unseatedPartyCount);
    expect(dayCovers, 72,
        reason: 'day unseated covers must equal the whole-day baseline '
            'exactly once (no double-count)');
    expect(dayParties, 18,
        reason: 'day unseated parties must equal the whole-day baseline '
            'exactly once');
    expect(dayRows.first.sourceSystem, 'demo_reservations');
  });

  test('no single period carries the whole-day unseated figure', () async {
    final repo = SqliteReservationBookSnapshotRepository.instance;
    final dayRows =
        await repo.getForDay('demo_restaurant_001', '2026-03-27');
    expect(dayRows, isNotEmpty);
    // Each period row is an honest cover-share slice — strictly less than
    // the whole-day total (the double-count regression was every row == 72).
    for (final r in dayRows) {
      expect(r.unseatedCovers, lessThan(72),
          reason:
              'a single period must not carry the whole-day figure '
              '(double-count regression guard)');
      expect(r.unseatedCovers, greaterThan(0),
          reason: 'seeded period rows are honest-positive (no phantom 0)');
    }
  });

  test('Fri lunch has no row (closed period — honest-degrade)', () async {
    final repo = SqliteReservationBookSnapshotRepository.instance;
    // Lunch is in the legacy default scenario's closed periods, so the
    // forward book has no live unseated reservations for it.
    final snapshot =
        await repo.getForShift('demo_restaurant_001', '2026-03-27', 'lunch');
    expect(snapshot, isNull);
  });

  test('getForShift returns null for non-existent shift', () async {
    final repo = SqliteReservationBookSnapshotRepository.instance;
    final snapshot = await repo.getForShift(
        'demo_restaurant_001', '2026-03-27', 'no_such_daypart');
    expect(snapshot, isNull);
  });

  test('replacing a snapshot updates the returned value', () async {
    final repo = SqliteReservationBookSnapshotRepository.instance;
    final now = DateTime.now().toIso8601String();

    await repo.replaceReservationBookSnapshot(ReservationBookSnapshot(
      restaurantId: 'demo_restaurant_001',
      businessDate: '2026-03-27',
      daypart: 'dinner',
      unseatedCovers: 55,
      unseatedPartyCount: 14,
      sourceSystem: 'demo_reservations',
      sourceServiceId: 'demo_res_fri_dinner',
      updatedAt: now,
    ));

    final snapshot =
        await repo.getForShift('demo_restaurant_001', '2026-03-27', 'dinner');
    expect(snapshot, isNotNull);
    expect(snapshot!.unseatedCovers, 55);
    expect(snapshot.unseatedPartyCount, 14);
  });

  test('clearAllData removes reservation snapshots', () async {
    await SqliteDatabase.instance.clearAllData();
    final repo = SqliteReservationBookSnapshotRepository.instance;
    final snapshot =
        await repo.getForShift('demo_restaurant_001', '2026-03-27', 'dinner');
    expect(snapshot, isNull);
  });
}
