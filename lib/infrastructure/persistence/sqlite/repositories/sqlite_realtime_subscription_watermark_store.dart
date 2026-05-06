// Phase 10a.5 — SQLite-backed [RealtimeSubscriptionWatermarkStore].
//
// Persists the per-(operator, topic) last-seen `event_id` so the
// realtime subscription can resume across process restarts. The
// upsert runs inside a single transaction with a freshness guard so a
// late-arriving frame for an `occurred_at` older than the persisted
// row never moves the cursor backwards (the `event_outbox` lock is
// the canonical durable order; this client cache must not invent an
// out-of-order resume cursor).
//
// Why a separate file (and not inlined into
// `lib/services/realtime/realtime_subscription.dart`): the realtime
// subscription compiles for every flavor that imports it, including
// any future operator-web entrypoint. Keeping `dart:io` / `sqflite`
// in this leaf file means the subscription file stays free of
// platform-specific imports and the operator-web entrypoint can
// inject a no-op store without dragging SQLite onto the web.

import 'package:sqflite/sqflite.dart';

import '../../../../services/realtime/realtime_subscription.dart';
import '../sqlite_database.dart';

class SqliteRealtimeSubscriptionWatermarkStore
    implements RealtimeSubscriptionWatermarkStore {
  SqliteRealtimeSubscriptionWatermarkStore._();
  static final SqliteRealtimeSubscriptionWatermarkStore instance =
      SqliteRealtimeSubscriptionWatermarkStore._();

  Database? _db;

  Future<Database> get _database async {
    return _db ??= await SqliteDatabase.instance.database;
  }

  @override
  Future<RealtimeSubscriptionWatermark?> readNewestForOperator(
    String operatorId,
  ) async {
    final db = await _database;
    final rows = await db.query(
      'realtime_subscription_watermark',
      where: 'operator_id = ?',
      whereArgs: <Object?>[operatorId],
      orderBy: 'occurred_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final topic = row['topic'];
    final eventId = row['event_id'];
    final occurredAtRaw = row['occurred_at'];
    final updatedAtRaw = row['updated_at'];
    if (topic is! String ||
        eventId is! String ||
        occurredAtRaw is! String ||
        updatedAtRaw is! String) {
      // A malformed row has nothing useful to resume against; fall
      // back to "first connect, no replay" rather than raise.
      return null;
    }
    return RealtimeSubscriptionWatermark(
      operatorId: operatorId,
      topic: topic,
      eventId: eventId,
      occurredAt: DateTime.parse(occurredAtRaw),
      updatedAt: DateTime.parse(updatedAtRaw),
    );
  }

  @override
  Future<void> upsert({
    required String operatorId,
    required String topic,
    required String eventId,
    required DateTime occurredAt,
    required DateTime updatedAt,
  }) async {
    final db = await _database;
    final occurredAtUtc = occurredAt.toUtc().toIso8601String();
    final updatedAtUtc = updatedAt.toUtc().toIso8601String();
    await db.transaction<void>((txn) async {
      // Freshness guard: never move the cursor to an event older than
      // the persisted row. The realtime stream is at-least-once, so a
      // duplicate redelivery of an old event must not rewind a newer
      // cursor and re-replay everything between.
      final existing = await txn.query(
        'realtime_subscription_watermark',
        columns: <String>['occurred_at'],
        where: 'operator_id = ? AND topic = ?',
        whereArgs: <Object?>[operatorId, topic],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        final priorOccurredAtRaw = existing.single['occurred_at'];
        if (priorOccurredAtRaw is String) {
          final priorOccurredAt = DateTime.tryParse(priorOccurredAtRaw);
          if (priorOccurredAt != null &&
              priorOccurredAt.isAfter(occurredAt.toUtc())) {
            return;
          }
        }
      }
      await txn.insert(
        'realtime_subscription_watermark',
        <String, Object?>{
          'operator_id': operatorId,
          'topic': topic,
          'event_id': eventId,
          'occurred_at': occurredAtUtc,
          'updated_at': updatedAtUtc,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }
}
