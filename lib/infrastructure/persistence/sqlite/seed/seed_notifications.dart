// Part of sqlite_database.dart. Variance-breach notification seeder + week_id business-date helper.
//
// Mechanically split out of sqlite_database_seed.dart (code_hardening_plan
// 2026-05-21 §4.4 god-object #3). Moved verbatim — no change to what is
// seeded, table names, values, or ordering (HP #2 demo-writer parity).

part of '../sqlite_database.dart';

/// Notifications / alerts (§1.6 / Gap G9) — variance-breach-derived.
///
/// Metric Honesty: this does NOT fabricate an alert. It scans the
/// already-seeded, deterministic `week_records` for Downtown and emits
/// ONE `app_notifications` row for the worst real over-plan week — the
/// row with the largest positive `dollar_gap` (= `WeekRecord.isOverModel`,
/// labor ran over the locked plan). If no seeded week is over plan there
/// is NO breach and NO notification (honest empty). The notification is
/// persisted through the same `app_notifications` table + `${rid}_$key`
/// id shape `AppNotificationService` uses, so `NotificationsScreen`
/// renders it identically to a runtime-emitted alert (unknown event_key
/// → raw title/body + default icon/accent — verified graceful).
///
/// Determinism: the worst week is a pure function of deterministic
/// `week_records`; `created_at` is derived from that week's business
/// date (fixed time component), never `DateTime.now()`. `reseedDemo`
/// clears `app_notifications` then this re-seeds the identical row →
/// two reseeds byte-identical. `ConflictAlgorithm.ignore` matches the
/// table's `UNIQUE(restaurant_id, event_key)` dedupe.
Future<void> _seedDemoVarianceBreachNotification(Database db) async {
  if (!await _tableExists(db, 'app_notifications')) return;
  const rid = DemoScope.restaurantId;
  final rows = await db.query(
    'week_records',
    columns: [
      'week_id',
      'week_label',
      'dollar_gap',
      'actual_labor_pct',
      'theoretical_labor_pct',
      'closed_at',
    ],
    where: 'restaurant_id = ?',
    whereArgs: [rid],
  );
  if (rows.isEmpty) return;
  Map<String, Object?>? worst;
  var worstGap = 0.0;
  for (final r in rows) {
    final gap = (r['dollar_gap'] as num?)?.toDouble() ?? 0.0;
    // Over-plan only (isOverModel: dollar_gap > 0). A favorable week
    // is not a breach — no alert. Deterministic max; tie-break on
    // week_id so the choice is stable across reseeds.
    if (gap > worstGap ||
        (gap == worstGap &&
            worst != null &&
            (r['week_id'] as String).compareTo(worst['week_id'] as String) <
                0)) {
      worst = r;
      worstGap = gap;
    }
  }
  if (worst == null || worstGap <= 0) return; // no real breach → honest empty
  final weekId = worst['week_id'] as String;
  final weekLabel = (worst['week_label'] as String?) ?? weekId;
  final actualPct = (worst['actual_labor_pct'] as num?)?.toDouble() ?? 0.0;
  final theoPct = (worst['theoretical_labor_pct'] as num?)?.toDouble() ?? 0.0;
  final businessDate =
      (worst['closed_at'] as String?) ?? _businessDateFromWeekId(weekId);
  final eventKey =
      'variance_breach_${weekId.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}';
  await db.insert('app_notifications', {
    'notification_id': '${rid}_$eventKey',
    'restaurant_id': rid,
    'type': 'variance_breach',
    'event_key': eventKey,
    'title': 'Weekly labor ran over plan',
    'body':
        'Week $weekLabel: labor ran \$${worstGap.round()} over the '
        'locked plan (actual ${actualPct.toStringAsFixed(1)}% vs plan '
        '${theoPct.toStringAsFixed(1)}%). Open the Variance tab to '
        'review.',
    'business_date': businessDate,
    // Deterministic: derived from the breach week's business date,
    // never DateTime.now() — two reseeds byte-identical.
    'created_at': '${businessDate}T12:00:00.000Z',
    'read_at': null,
  }, conflictAlgorithm: ConflictAlgorithm.ignore);
}

/// Best-effort `YYYY-MM-DD` from a `week_id` when a week_record has no
/// `closed_at`. Demo `week_id`s carry a leading date segment; fall back
/// to a fixed in-window date if the shape is unexpected (still
/// deterministic).
String _businessDateFromWeekId(String weekId) {
  final m = RegExp(r'(\d{4}-\d{2}-\d{2})').firstMatch(weekId);
  return m?.group(1) ?? '2026-05-11';
}
