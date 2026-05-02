// HARD-H — SQLite-backed [BoundaryEventOutbox] for the Flutter app.
//
// The Flutter app cannot reach Postgres directly (Hard Promise #7 in
// CLAUDE.md), so the per-device boundary backlog uses local SQLite.
// The boundary monitor's purpose is local UI refresh, so per-device
// durability is sufficient — the persisted rows do not need to fan
// out to Pub/Sub or other consumers.
//
// Concurrency model: the Flutter app runs a single boundary supervisor
// per process, but `drainBacklog()` is invoked from two lifecycle
// points (`_initBoundarySupervisor` at first start, and
// `didChangeAppLifecycleState` on resume-after-background). Both call
// sites use `unawaited(...)`, so a drain kicked off at startup can
// still be in flight when the resume-after-background drain begins.
// `claimPending` therefore runs a transactional SELECT + UPDATE that
// stamps `picked_up_at` on the returned rows, so the second drain
// sees those rows already claimed and skips them. A claimant that
// crashes between claim + mark-delivered leaves a stale
// `picked_up_at`; the [defaultClaimReclaimAfter] window lets the next
// drain re-claim it. This mirrors the Postgres
// `event_outbox.picked_up_at` lease semantics in
// [EventOutboxRepository.claimBatch].
//
// Resilience: every operation is wrapped in a try/catch so a missing
// or corrupt database (e.g. widget tests that did not init sqflite,
// or a first-run device whose schema migration is still in flight)
// degrades gracefully — `persist` returns null, `claimPending` returns
// empty, `markDelivered` no-ops. The supervisor's in-process
// `lastKnownBusinessDate` dedup is the safety net while the backlog
// is unavailable.

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../infrastructure/persistence/sqlite/sqlite_database.dart';
import 'boundary_event_outbox.dart';

class SqliteBoundaryEventOutbox implements BoundaryEventOutbox {
  SqliteBoundaryEventOutbox({
    DateTime Function()? clock,
    Duration claimReclaimAfter = defaultClaimReclaimAfter,
  })  : _clock = clock ?? DateTime.now,
        _claimReclaimAfter = claimReclaimAfter;

  /// Default reclaim window for stale claims. Mirrors the Postgres
  /// `EventOutboxRepository.defaultClaimReclaimAfter` so both adapters
  /// agree on "how long does a crashed claimant hold the row before
  /// the next drain may re-fire it." Five minutes is the conservative
  /// shared default.
  static const Duration defaultClaimReclaimAfter = Duration(minutes: 5);

  final DateTime Function() _clock;
  final Duration _claimReclaimAfter;

  Future<Database> get _db => SqliteDatabase.instance.database;

  @override
  Future<String?> persist({
    required String restaurantId,
    required String businessDate,
  }) async {
    try {
      final db = await _db;
      final id = await db.insert('boundary_event_outbox', <String, Object?>{
        'restaurant_id': restaurantId,
        'business_date': businessDate,
        'created_at': _clock().toUtc().toIso8601String(),
      });
      return id.toString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<PendingBoundaryEvent>> claimPending({int batchSize = 100}) async {
    if (batchSize <= 0) return const <PendingBoundaryEvent>[];
    try {
      final db = await _db;
      // Transactional claim: SELECT + UPDATE inside a single
      // `db.transaction` so two concurrent drainBacklog calls in this
      // process never read the same row before either marks it
      // delivered. SQLite serializes write transactions, so the second
      // drain blocks until the first commits, then sees the
      // freshly-stamped `picked_up_at` and skips the row.
      return db.transaction<List<PendingBoundaryEvent>>((txn) async {
        final reclaimThreshold = _clock()
            .toUtc()
            .subtract(_claimReclaimAfter)
            .toIso8601String();
        final rows = await txn.query(
          'boundary_event_outbox',
          columns: const <String>['id', 'restaurant_id', 'business_date'],
          // The OR-with-stale lets a drain re-claim a row whose
          // previous claimant crashed between picking it up and
          // marking it delivered. Mirrors the Postgres
          // `picked_up_at IS NULL OR picked_up_at < now() - <window>`
          // predicate so both adapters share the lease semantics.
          where: 'delivered_at IS NULL '
              'AND (picked_up_at IS NULL OR picked_up_at < ?)',
          whereArgs: <Object?>[reclaimThreshold],
          orderBy: 'id ASC',
          limit: batchSize,
        );
        if (rows.isEmpty) return const <PendingBoundaryEvent>[];
        final nowIso = _clock().toUtc().toIso8601String();
        final ids = <int>[
          for (final row in rows) row['id']! as int,
        ];
        final placeholders = List<String>.filled(ids.length, '?').join(',');
        await txn.rawUpdate(
          'UPDATE boundary_event_outbox '
          'SET picked_up_at = ? '
          'WHERE id IN ($placeholders)',
          <Object?>[nowIso, ...ids],
        );
        return <PendingBoundaryEvent>[
          for (final row in rows)
            PendingBoundaryEvent(
              eventId: (row['id']! as int).toString(),
              restaurantId: row['restaurant_id']! as String,
              businessDate: row['business_date']! as String,
            ),
        ];
      });
    } catch (_) {
      return const <PendingBoundaryEvent>[];
    }
  }

  @override
  Future<void> markDelivered(String eventId) async {
    final id = int.tryParse(eventId);
    if (id == null) return;
    try {
      final db = await _db;
      await db.update(
        'boundary_event_outbox',
        <String, Object?>{
          'delivered_at': _clock().toUtc().toIso8601String(),
        },
        where: 'id = ? AND delivered_at IS NULL',
        whereArgs: <Object?>[id],
      );
    } catch (_) {
      // Next claimPending after the reclaim window will re-read +
      // re-fire (at-least-once posture). The supervisor's
      // `lastKnownBusinessDate` in-process dedup tolerates this.
    }
  }
}
