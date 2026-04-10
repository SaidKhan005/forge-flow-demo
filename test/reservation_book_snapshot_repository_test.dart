// Phase 7.56 — Reservation book snapshot repository tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/reservation_book_snapshot.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_reservation_book_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
  });

  test('reseed creates the demo reservation book snapshot', () async {
    final repo = SqliteReservationBookSnapshotRepository.instance;
    final snapshot =
        await repo.getForShift('demo_restaurant_001', '2026-03-27', 'dinner');
    expect(snapshot, isNotNull);
    expect(snapshot!.unseatedCovers, 72);
    expect(snapshot.unseatedPartyCount, 18);
    expect(snapshot.sourceSystem, 'demo_reservations');
    expect(snapshot.sourceServiceId, 'demo_res_fri_dinner');
  });

  test('getForShift returns unseated covers 72 for Fri dinner', () async {
    final repo = SqliteReservationBookSnapshotRepository.instance;
    final snapshot =
        await repo.getForShift('demo_restaurant_001', '2026-03-27', 'dinner');
    expect(snapshot, isNotNull);
    expect(snapshot!.unseatedCovers, 72);
  });

  test('getForShift returns null for non-existent shift', () async {
    final repo = SqliteReservationBookSnapshotRepository.instance;
    final snapshot =
        await repo.getForShift('demo_restaurant_001', '2026-03-27', 'lunch');
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
