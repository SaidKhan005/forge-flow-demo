// Wave 2 MO-2 — ManualCoverEntryDao smoke tests.
//
// Validates the table migration + DAO round-trip against the real
// SQLite singleton:
//   * Insert one row -> read it back by listRecentForRestaurant.
//   * Re-insert (same restaurant_id, business_date, daypart) replaces
//     the row rather than throwing on the PK conflict.
//   * findEntry returns null when no row matches.
//   * Recent ordering is most-recent business_date first.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/manual_cover_entry_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() async {
    final db = await SqliteDatabase.instance.database;
    await db.delete('manual_cover_entries');
  });

  test('upsert + listRecentForRestaurant round-trips a single row', () async {
    final db = await SqliteDatabase.instance.database;
    final dao = ManualCoverEntryDao(db);

    await dao.upsert(
      const ManualCoverEntry(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-10',
        daypart: 'dinner',
        covers: 84,
        recordedAt: '2026-05-10T22:30:00Z',
      ),
    );

    final rows = await dao.listRecentForRestaurant('demo_restaurant_001');
    expect(rows, hasLength(1));
    expect(rows.single.covers, 84);
    expect(rows.single.businessDate, '2026-05-10');
    expect(rows.single.daypart, 'dinner');
  });

  test('upsert replaces the row on (restaurant_id, business_date, daypart) '
      'PK conflict', () async {
    final db = await SqliteDatabase.instance.database;
    final dao = ManualCoverEntryDao(db);

    await dao.upsert(
      const ManualCoverEntry(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-10',
        daypart: 'dinner',
        covers: 84,
        recordedAt: '2026-05-10T22:30:00Z',
      ),
    );
    await dao.upsert(
      const ManualCoverEntry(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-10',
        daypart: 'dinner',
        covers: 92,
        recordedAt: '2026-05-10T23:00:00Z',
      ),
    );

    final rows = await dao.listRecentForRestaurant('demo_restaurant_001');
    expect(rows, hasLength(1));
    expect(rows.single.covers, 92);
    expect(rows.single.recordedAt, '2026-05-10T23:00:00Z');
  });

  test('listRecentForRestaurant orders by business_date DESC', () async {
    final db = await SqliteDatabase.instance.database;
    final dao = ManualCoverEntryDao(db);

    await dao.upsert(
      const ManualCoverEntry(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-08',
        daypart: 'lunch',
        covers: 42,
        recordedAt: '2026-05-08T15:00:00Z',
      ),
    );
    await dao.upsert(
      const ManualCoverEntry(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-10',
        daypart: 'dinner',
        covers: 84,
        recordedAt: '2026-05-10T22:30:00Z',
      ),
    );

    final rows = await dao.listRecentForRestaurant('demo_restaurant_001');
    expect(rows, hasLength(2));
    expect(rows.first.businessDate, '2026-05-10');
    expect(rows.last.businessDate, '2026-05-08');
  });

  test('findEntry returns null when no row matches', () async {
    final db = await SqliteDatabase.instance.database;
    final dao = ManualCoverEntryDao(db);

    final hit = await dao.findEntry(
      restaurantId: 'demo_restaurant_001',
      businessDate: '2099-01-01',
      daypart: 'dinner',
    );
    expect(hit, isNull);
  });
}
