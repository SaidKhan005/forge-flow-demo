// HARD-H — SqliteBoundaryEventOutbox unit tests.
//
// Validates:
// A. persist + claimPending + markDelivered round-trip
// B. concurrent claims do not double-fire (the P2 review fix)
// C. stale-reclaim window lets a later drain re-claim a crashed
//    claimant's row
// D. delivered rows are skipped on subsequent claims
// E. broken event id strings are tolerated by markDelivered

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/services/boundary_event_outbox.dart';
import 'package:forge_and_flow/services/sqlite_boundary_event_outbox.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() async {
    // The shared SqliteDatabase singleton is also used by other tests.
    // `reseedDemo` covers the operational tables; the boundary outbox
    // is additive so we clear it explicitly to avoid cross-test
    // contamination.
    await setUpSqliteDemo();
    final db = await SqliteDatabase.instance.database;
    await db.delete('boundary_event_outbox');
  });

  group('A — basic round-trip', () {
    test('persist + claimPending + markDelivered cycle works end-to-end',
        () async {
      final outbox = SqliteBoundaryEventOutbox();
      final id = await outbox.persist(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-02',
      );
      expect(id, isNotNull, reason: 'persist returns a row id');

      final pending = await outbox.claimPending();
      expect(pending, hasLength(1));
      expect(pending.single.restaurantId, 'demo_restaurant_001');
      expect(pending.single.businessDate, '2026-05-02');
      expect(pending.single.eventId, id);

      await outbox.markDelivered(pending.single.eventId);

      final stillPending = await outbox.claimPending();
      expect(stillPending, isEmpty,
          reason: 'delivered_at filter excludes the now-delivered row');
    });
  });

  group('B — concurrent drains do not double-claim', () {
    test('two simultaneous claimPending calls each see disjoint rows', () async {
      final outbox = SqliteBoundaryEventOutbox();
      // Persist 4 rows so each concurrent claim can take some.
      for (var i = 0; i < 4; i++) {
        await outbox.persist(
          restaurantId: 'demo_restaurant_001',
          businessDate: '2026-05-0$i',
        );
      }

      // Race two drains. SQLite serializes write transactions so the
      // second one sees the rows the first one stamped picked_up_at.
      final futures = <Future<List<PendingBoundaryEvent>>>[
        outbox.claimPending(),
        outbox.claimPending(),
      ];
      final results = await Future.wait(futures);
      final firstIds = results[0].map((r) => r.eventId).toSet();
      final secondIds = results[1].map((r) => r.eventId).toSet();
      expect(
        firstIds.intersection(secondIds),
        isEmpty,
        reason: 'concurrent claims must return disjoint row sets — the '
            'P2 review fix locks rows via picked_up_at inside the '
            'select+update transaction',
      );
      expect(
        firstIds.length + secondIds.length,
        4,
        reason:
            'between the two drains, every persisted row should have been '
            'claimed exactly once',
      );
    });

    test('repeat claim within reclaim window returns nothing', () async {
      final outbox = SqliteBoundaryEventOutbox();
      await outbox.persist(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-02',
      );
      final firstClaim = await outbox.claimPending();
      expect(firstClaim, hasLength(1));
      // Second claim immediately after — picked_up_at is fresh.
      final secondClaim = await outbox.claimPending();
      expect(
        secondClaim,
        isEmpty,
        reason: 'second drain must not re-claim a row whose picked_up_at '
            'is still inside the reclaim window',
      );
    });
  });

  group('C — stale claim re-claim', () {
    test('claim past the reclaim window picks up an undelivered row',
        () async {
      // Use a clock that we can advance — first persist + claim at t0,
      // then claim again at t0 + reclaim window + 1s.
      final times = <DateTime>[
        DateTime.utc(2026, 5, 2, 10, 0, 0),
        DateTime.utc(2026, 5, 2, 10, 0, 1), // claim 1 at t+1s
        DateTime.utc(2026, 5, 2, 10, 6, 2), // claim 2 past 5-min window
      ];
      var idx = 0;
      final outbox = SqliteBoundaryEventOutbox(
        clock: () => times[idx.clamp(0, times.length - 1)],
      );

      idx = 0;
      await outbox.persist(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-02',
      );
      idx = 1;
      final firstClaim = await outbox.claimPending();
      expect(firstClaim, hasLength(1),
          reason: 'first claim picks up the persisted row');

      idx = 2;
      final secondClaim = await outbox.claimPending();
      expect(
        secondClaim,
        hasLength(1),
        reason: 'after the reclaim window passes, an undelivered row '
            'becomes claimable again — this is the safety net for a '
            'claimant that crashed between claim and markDelivered',
      );
    });
  });

  group('D — delivered rows stay out', () {
    test('delivered rows are not returned even after the reclaim window',
        () async {
      final times = <DateTime>[
        DateTime.utc(2026, 5, 2, 10, 0, 0),
        DateTime.utc(2026, 5, 2, 10, 6, 0), // 6 min later
      ];
      var idx = 0;
      final outbox = SqliteBoundaryEventOutbox(
        clock: () => times[idx.clamp(0, times.length - 1)],
      );

      idx = 0;
      await outbox.persist(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-02',
      );
      final firstClaim = await outbox.claimPending();
      await outbox.markDelivered(firstClaim.single.eventId);

      idx = 1;
      final laterClaim = await outbox.claimPending();
      expect(
        laterClaim,
        isEmpty,
        reason: 'delivered_at IS NULL filter still excludes the row '
            'even after the reclaim window passes',
      );
    });
  });

  group('E — markDelivered tolerates malformed ids', () {
    test('non-numeric eventId is a no-op, not a crash', () async {
      final outbox = SqliteBoundaryEventOutbox();
      // Should not throw.
      await outbox.markDelivered('not-a-number');
      // Persist + claim still works after the bad call.
      await outbox.persist(
        restaurantId: 'demo_restaurant_001',
        businessDate: '2026-05-02',
      );
      final pending = await outbox.claimPending();
      expect(pending, hasLength(1));
    });
  });
}
