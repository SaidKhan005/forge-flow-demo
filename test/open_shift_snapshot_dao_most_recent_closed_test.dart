// Focused DAO test for the closed-state Shift dashboard day selection
// (fix for the PR #937 defect: the unfiltered `getMostRecentBusinessDate`
// returned a FUTURE `status='projected'` day, so the closed-state screen
// rendered all zeros instead of the last COMPLETED day's settled finals).
//
// `getMostRecentClosedBusinessDate` must:
//   * Pick the LATEST `business_date` that has a `status='closed'` row.
//   * IGNORE `projected` (future/forecast) and `open` (in-progress) rows
//     even when their `business_date` is chronologically later.
//   * Return null when there is NO `status='closed'` row for the
//     restaurant (brand-new operator → simple empty state, never a zero
//     "Closed" screen).
//
// Contrast: the legacy `getMostRecentBusinessDate` (kept for any caller
// that genuinely wants the max across all statuses) still returns the
// max date regardless of status.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:forge_and_flow/infrastructure/persistence/sqlite/dao/open_shift_snapshot_dao.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';

const _r = 'demo_restaurant_001';

Future<void> _insert(
  dynamic db, {
  required String businessDate,
  required String status,
  required String dayLabel,
  String daypart = 'dinner',
}) async {
  await db.insert('open_shift_snapshots', {
    'restaurant_id': _r,
    'week_id': 'wk_$businessDate',
    'day_label': dayLabel,
    'daypart': daypart,
    'status': status,
    'business_date': businessDate,
    'forecast_covers': 0,
    'current_covers': 0,
    'scheduled_foh_hours': 0,
    'scheduled_boh_hours': 0,
    'current_ppa': 0.0,
    'current_cplh': 0.0,
    'current_splh': 0.0,
    'blended_wage': 0.0,
    'updated_at': '${businessDate}T00:00:00Z',
  });
}

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  setUp(() async {
    final db = await SqliteDatabase.instance.database;
    await db.delete('open_shift_snapshots');
  });

  test(
      'getMostRecentClosedBusinessDate picks the latest CLOSED day, '
      'ignoring later projected/open days', () async {
    final db = await SqliteDatabase.instance.database;
    final dao = OpenShiftSnapshotDao(db);

    // Two completed (closed) days, then a LATER projected future day and
    // a LATER open day. The naive max-date query would return the
    // projected/open future date; the closed-only query must return the
    // newest CLOSED day (2026-05-12).
    await _insert(db,
        businessDate: '2026-05-11', status: 'closed', dayLabel: 'Mon');
    await _insert(db,
        businessDate: '2026-05-12', status: 'closed', dayLabel: 'Tue');
    await _insert(db,
        businessDate: '2026-05-15', status: 'projected', dayLabel: 'Fri');
    await _insert(db,
        businessDate: '2026-05-16', status: 'open', dayLabel: 'Sat');

    final closed = await dao.getMostRecentClosedBusinessDate(_r);
    expect(closed, '2026-05-12',
        reason: 'must bind the latest COMPLETED day, never the later '
            'projected/open day');

    // Sanity: the legacy unfiltered query still returns the raw max
    // (this is exactly the buggy behavior the fix bypasses).
    final anyMax = await dao.getMostRecentBusinessDate(_r);
    expect(anyMax, '2026-05-16',
        reason: 'legacy method intentionally unchanged: max across all '
            'statuses');
  });

  test(
      'getMostRecentClosedBusinessDate returns null when only '
      'projected/open rows exist (no completed history)', () async {
    final db = await SqliteDatabase.instance.database;
    final dao = OpenShiftSnapshotDao(db);

    await _insert(db,
        businessDate: '2026-05-15', status: 'projected', dayLabel: 'Fri');
    await _insert(db,
        businessDate: '2026-05-16', status: 'open', dayLabel: 'Sat');

    final closed = await dao.getMostRecentClosedBusinessDate(_r);
    expect(closed, isNull,
        reason: 'no status=closed row → null → caller falls back to the '
            'simple empty state, NOT a zero Closed screen');
  });

  test(
      'getMostRecentClosedBusinessDate returns null for an empty table '
      '(brand-new operator)', () async {
    final db = await SqliteDatabase.instance.database;
    final dao = OpenShiftSnapshotDao(db);

    final closed = await dao.getMostRecentClosedBusinessDate(_r);
    expect(closed, isNull);
  });

  test(
      'getMostRecentClosedBusinessDate is scoped per restaurant', () async {
    final db = await SqliteDatabase.instance.database;
    final dao = OpenShiftSnapshotDao(db);

    await _insert(db,
        businessDate: '2026-05-12', status: 'closed', dayLabel: 'Tue');
    // A closed row for a DIFFERENT restaurant must not leak in.
    await db.insert('open_shift_snapshots', {
      'restaurant_id': 'other_restaurant_999',
      'week_id': 'wk_other',
      'day_label': 'Wed',
      'daypart': 'dinner',
      'status': 'closed',
      'business_date': '2026-05-20',
      'forecast_covers': 0,
      'current_covers': 0,
      'scheduled_foh_hours': 0,
      'scheduled_boh_hours': 0,
      'current_ppa': 0.0,
      'current_cplh': 0.0,
      'current_splh': 0.0,
      'blended_wage': 0.0,
      'updated_at': '2026-05-20T00:00:00Z',
    });

    final closed = await dao.getMostRecentClosedBusinessDate(_r);
    expect(closed, '2026-05-12',
        reason: 'another restaurant\'s later closed day must not leak '
            '(per-operator isolation)');
  });
}
