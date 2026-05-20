// Wave 2 MO-2 — manual_cover_entries DAO.
//
// Mobile-side mirror for operator-entered covers. Each row is one
// operator-entered cover count for a specific (restaurant_id,
// business_date, daypart). Signed-in production writes go through the
// proxy first into `public.data_accuracy_settings.covers_manual_entries`
// (jsonb), then mirror here so Settings can show recent entries quickly.
//
// Demo-mode invariant: the unauth/demo fallback writes to this same table
// whether the restaurant is in demo or live mode — no `kDemoMode`
// reader branch (HP #2 in CLAUDE.md). The demo seeder leaves this
// table empty; manual entries the operator types in demo mode land
// next to the seeded `shift_records` rows on the same Variance / Plan
// / Benchmark tabs.
// Live signed-in SettingsScreen bypasses that fallback and calls the
// canonical proxy writer before this local mirror is updated.

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class ManualCoverEntry {
  const ManualCoverEntry({
    required this.restaurantId,
    required this.businessDate,
    required this.daypart,
    required this.covers,
    required this.recordedAt,
  });

  /// Restaurant / location scope key. Mirrors `shift_records.restaurant_id`.
  final String restaurantId;

  /// ISO `YYYY-MM-DD` business date the cover count applies to.
  final String businessDate;

  /// Daypart wire value (`lunch`, `dinner`, `late_night`). Matches the
  /// suffix on `data_accuracy_settings.covers_source_<daypart>`.
  final String daypart;

  /// Operator-typed cover count. Always >= 0.
  final int covers;

  /// ISO-8601 UTC timestamp of when the entry was recorded.
  final String recordedAt;

  Map<String, Object?> toMap() => <String, Object?>{
    'restaurant_id': restaurantId,
    'business_date': businessDate,
    'daypart': daypart,
    'covers': covers,
    'recorded_at': recordedAt,
  };

  factory ManualCoverEntry.fromMap(Map<String, Object?> row) {
    return ManualCoverEntry(
      restaurantId: row['restaurant_id'] as String,
      businessDate: row['business_date'] as String,
      daypart: row['daypart'] as String,
      covers: (row['covers'] as num).toInt(),
      recordedAt: row['recorded_at'] as String,
    );
  }
}

/// DAO for the `manual_cover_entries` table.
///
/// The primary key (restaurant_id, business_date, daypart) means
/// [upsert] replaces an existing entry rather than creating a duplicate
/// row. Reads order most-recent first by business_date so the Settings
/// section can show the operator their last few entries.
class ManualCoverEntryDao {
  final Database _db;
  const ManualCoverEntryDao(this._db);

  /// Insert or replace one entry. Returns the rowid (sqlite's
  /// auto-row identity — not surfaced to the UI; used here only so
  /// callers can detect a successful write via `> 0`).
  Future<int> upsert(ManualCoverEntry entry) async {
    return _db.insert(
      'manual_cover_entries',
      entry.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Replace the cached recent-list rows for [restaurantId] with the
  /// server-authoritative [entries]. Returns true when the cache changed.
  Future<bool> replaceAllForRestaurant(
    String restaurantId,
    Iterable<ManualCoverEntry> entries,
  ) async {
    final target = entries.toList(growable: false);
    final existing = await listRecentForRestaurant(
      restaurantId,
      limit: 1000000,
    );
    if (_sameEntrySet(existing, target)) {
      return false;
    }

    await _db.transaction((txn) async {
      await txn.delete(
        'manual_cover_entries',
        where: 'restaurant_id = ?',
        whereArgs: [restaurantId],
      );
      for (final entry in target) {
        await txn.insert(
          'manual_cover_entries',
          entry.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
    return true;
  }

  /// Most-recent entries for [restaurantId], newest business_date
  /// first. The optional [limit] caps the result so the Settings
  /// section can show "your last N entries" without unbounded growth.
  Future<List<ManualCoverEntry>> listRecentForRestaurant(
    String restaurantId, {
    int limit = 20,
  }) async {
    final rows = await _db.query(
      'manual_cover_entries',
      where: 'restaurant_id = ?',
      whereArgs: [restaurantId],
      orderBy: 'business_date DESC, daypart ASC',
      limit: limit,
    );
    return rows
        .map((row) => ManualCoverEntry.fromMap(Map<String, Object?>.from(row)))
        .toList(growable: false);
  }

  /// Single-entry lookup. Returns null when no row exists for the
  /// (restaurant_id, business_date, daypart) triple.
  Future<ManualCoverEntry?> findEntry({
    required String restaurantId,
    required String businessDate,
    required String daypart,
  }) async {
    final rows = await _db.query(
      'manual_cover_entries',
      where: 'restaurant_id = ? AND business_date = ? AND daypart = ?',
      whereArgs: [restaurantId, businessDate, daypart],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ManualCoverEntry.fromMap(Map<String, Object?>.from(rows.first));
  }

  static bool _sameEntrySet(
    List<ManualCoverEntry> left,
    List<ManualCoverEntry> right,
  ) {
    if (left.length != right.length) return false;
    final leftKeys = <String, ManualCoverEntry>{
      for (final entry in left) _entryKey(entry): entry,
    };
    for (final entry in right) {
      final existing = leftKeys[_entryKey(entry)];
      if (existing == null ||
          existing.covers != entry.covers ||
          existing.recordedAt != entry.recordedAt) {
        return false;
      }
    }
    return true;
  }

  static String _entryKey(ManualCoverEntry entry) =>
      '${entry.restaurantId}\u0000${entry.businessDate}\u0000${entry.daypart}';
}
