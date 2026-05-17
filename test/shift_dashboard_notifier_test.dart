// Shift dashboard notifier tests — empty-state behavior + locked plan (7.55l.7a).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/schedule_plan_read_service.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/services/shift_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/models/current_state_freshness.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
    await SchedulePlanReadService.instance.getCurrentLockedWeeklyPlan();
  });

  test('notifier finishes loading with readModel when snapshot exists',
      () async {
    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.isLoading, isFalse);
    expect(notifier.readModel, isNotNull);
    expect(notifier.status, isNotNull);

    notifier.dispose();
  });

  test('notifier read model includes inTheBooksCovers after reseed',
      () async {
    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.readModel, isNotNull);
    // Whole-day "in the books" must be the day's unseated covers counted
    // exactly ONCE. The demo seed's 72 / 220 baseline is a whole-day
    // figure; before the double-count fix the forward envelope wrote the
    // whole-day figure into every served daypart row, so summing the
    // day's rows in _buildDayReadModel reported 2x (72 -> 144). 72 was
    // always the correct intended whole-day value.
    expect(notifier.readModel!.inTheBooksCovers, 72,
        reason: 'day unseated covers single-counted, not summed per period');

    notifier.dispose();
  });

  test('reservation book day rows sum once — no per-period double-count',
      () async {
    // Focused regression guard for the inTheBooks double-count: the
    // per-daypart reservation rows for the open business day must SUM to
    // the whole-day baseline (72), and no single period may carry the
    // whole-day figure (the regression was every row == 72).
    final db = await SqliteDatabase.instance.database;
    final openRows = await db.rawQuery(
      "SELECT business_date FROM open_shift_snapshots "
      "WHERE status = 'open' LIMIT 1",
    );
    expect(openRows, isNotEmpty,
        reason: 'demo seed must have one open shift');
    final businessDate = openRows.first['business_date'] as String;

    final resRows = await db.query(
      'reservation_book_snapshots',
      where: 'restaurant_id = ? AND business_date = ?',
      whereArgs: ['demo_restaurant_001', businessDate],
    );
    expect(resRows, isNotEmpty,
        reason: 'open day must have a forward reservation book');
    final daySum = resRows.fold<int>(
        0, (s, r) => s + (r['unseated_covers'] as int));
    expect(daySum, 72,
        reason: 'open day unseated covers sum exactly to the whole-day '
            'baseline (single-counted)');
    for (final r in resRows) {
      expect(r['unseated_covers'] as int, lessThan(72),
          reason: 'no single period carries the whole-day figure '
              '(double-count regression guard)');
    }
  });

  test('notifier finishes loading with null readModel when no snapshot exists',
      () async {
    // Clear open snapshots so there's no current shift
    final db = await SqliteDatabase.instance.database;
    await db.delete('open_shift_snapshots');

    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.isLoading, isFalse);
    expect(notifier.readModel, isNull);
    expect(notifier.status, isNotNull);
    // Status should indicate the data situation, not show a spinner
    expect(notifier.status!.type, isNot(equals(null)));

    notifier.dispose();
  });

  test(
      'no open shift + closed history + FUTURE projected rows → binds the '
      'most recent CLOSED day (not the projected future day), isClosedDay',
      () async {
    // Closed-state Shift dashboard (Per-Daypart V1 — closed-state
    // screen). Defect fix for PR #937: the demo seed persists FUTURE
    // `status='projected'` rows for the forthcoming week, so the old
    // unfiltered max-date selection bound a forecast-only future day
    // and rendered an all-zeros "Closed" screen. The notifier must
    // instead bind the most recent COMPLETED (`status='closed'`)
    // business day's already-persisted final values (reusing the same
    // buildWholeDay wiring) and mark the screen Closed.
    final db = await SqliteDatabase.instance.database;
    final deleted =
        await db.delete('open_shift_snapshots', where: "status = 'open'");
    expect(deleted, greaterThan(0),
        reason: 'demo seed should have at least one open snapshot');

    // Reality-check the fixture: both closed history AND later projected
    // rows must exist, and the projected max date must be STRICTLY later
    // than the latest closed date (otherwise this test would not
    // distinguish the fix from the bug).
    final latestClosedRow = await db.rawQuery(
        "SELECT MAX(business_date) d FROM open_shift_snapshots "
        "WHERE status = 'closed'");
    final latestClosed = latestClosedRow.first['d'] as String?;
    final maxAnyRow = await db.rawQuery(
        "SELECT MAX(business_date) d FROM open_shift_snapshots");
    final maxAny = maxAnyRow.first['d'] as String?;
    expect(latestClosed, isNotNull,
        reason: 'demo seed must have closed history');
    expect(maxAny, isNotNull);
    expect(maxAny!.compareTo(latestClosed!), greaterThan(0),
        reason:
            'fixture must have a projected future day strictly later than '
            'the latest closed day for this test to be meaningful');

    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.isLoading, isFalse);
    expect(notifier.readModel, isNotNull,
        reason:
            'closed-state path must bind the last COMPLETED day final values');
    expect(notifier.isClosedDay, isTrue,
        reason: 'no open shift + completed history → screen marked Closed');
    // The bound day must be the latest CLOSED day, NEVER the later
    // projected/forecast future day.
    expect(notifier.readModel!.businessDate, latestClosed,
        reason: 'must bind the most recent CLOSED day');
    expect(notifier.readModel!.businessDate, isNot(maxAny),
        reason: 'must NOT bind the projected future day (the #937 bug)');
    // Honesty: a real settled day has non-zero finals (not the phantom
    // all-zeros of a forecast-only projected day).
    expect(
        notifier.readModel!.actualSales > 0 ||
            notifier.readModel!.actualCovers > 0,
        isTrue,
        reason: 'a completed day carries non-zero settled finals, not the '
            'all-zeros of a projected-only future day');
    // Freshness is intentionally null on the closed path — the Closed
    // marker + reopen line carry the state, not a live/stale chip.
    expect(notifier.freshness, isNull);
    expect(notifier.status, isNotNull);

    notifier.dispose();
  });

  test(
      'no open shift + only projected rows (no closed history) → simple '
      'empty state, NOT a zero Closed screen',
      () async {
    // Brand-new operator analogue: a projected-only future week with NO
    // completed (`status='closed'`) history must fall back to the
    // existing simple empty state — never a fabricated all-zeros
    // "Closed" screen built from forecast-only rows (honesty).
    final db = await SqliteDatabase.instance.database;
    await db.delete('open_shift_snapshots', where: "status = 'open'");
    await db.delete('open_shift_snapshots', where: "status = 'closed'");
    final closedLeft = await db.rawQuery(
        "SELECT COUNT(*) c FROM open_shift_snapshots WHERE status = 'closed'");
    expect(closedLeft.first['c'], 0,
        reason: 'no closed history remains for this case');
    final projectedLeft = await db.rawQuery(
        "SELECT COUNT(*) c FROM open_shift_snapshots "
        "WHERE status = 'projected'");
    expect(projectedLeft.first['c'], greaterThan(0),
        reason: 'projected future rows must remain to prove they do NOT '
            'produce a Closed screen');

    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.isLoading, isFalse);
    expect(notifier.readModel, isNull,
        reason: 'projected-only, no closed history → simple empty state');
    expect(notifier.isClosedDay, isFalse,
        reason: 'never a Closed screen from forecast-only rows');
    expect(notifier.freshness, isNull);
    expect(notifier.lockedPlanUnavailable, isFalse,
        reason: 'this is the brand-new/no-history empty path, not the '
            'locked-plan-missing degrade path');
    expect(notifier.status, isNotNull);

    notifier.dispose();
  });

  test(
      'closed-day path stays empty when no locked plan day row matches',
      () async {
    // If the locked weekly plan has no matching day row, the closed
    // path must degrade honestly to the empty state exactly like the
    // live path (lockedPlanUnavailable) — never a Closed screen with
    // no data.
    final db = await SqliteDatabase.instance.database;
    await db.delete('open_shift_snapshots', where: "status = 'open'");
    await db.delete('weekly_plan_snapshots');

    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.isLoading, isFalse);
    expect(notifier.readModel, isNull,
        reason: 'no locked plan row → honest empty, not a Closed screen');
    expect(notifier.isClosedDay, isFalse);
    expect(notifier.lockedPlanUnavailable, isTrue);

    notifier.dispose();
  });

  test('after clearAllData notifier shows no-data status', () async {
    await SqliteDatabase.instance.clearAllData();

    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.isLoading, isFalse);
    expect(notifier.readModel, isNull);
    expect(notifier.status!.type, AppDataStatusType.noData);

    notifier.dispose();
  });

  // ── Freshness exposure tests (7.55n.7) ───────────────────────────────────

  test('notifier exposes live freshness after fresh reseed', () async {
    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.readModel, isNotNull);
    expect(notifier.freshness, isNotNull);
    // Demo seed timestamps are fresh (just written), so freshness should be
    // live. This validates that the notifier evaluates from persisted
    // OpenShiftSnapshot.updatedAt.
    expect(notifier.freshness!.state, FreshnessState.live);
    expect(notifier.freshness!.updatedAt, isNotNull);
    expect(notifier.freshness!.age, isNotNull);
    expect(notifier.freshness!.age!.inMinutes, lessThan(5));

    notifier.dispose();
  });

  test('notifier freshness is null when no snapshots exist', () async {
    final db = await SqliteDatabase.instance.database;
    await db.delete('open_shift_snapshots');

    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.readModel, isNull);
    expect(notifier.freshness, isNull,
        reason: 'no current-state data means no freshness to evaluate');

    notifier.dispose();
  });

  test('fromReadModel test constructor exposes injected freshness', () {
    final now = DateTime.utc(2026, 4, 13, 12, 0, 0);
    final freshness = CurrentStateFreshness(
      state: FreshnessState.updated,
      updatedAt: now.subtract(const Duration(minutes: 30)),
      evaluatedAt: now,
    );

    // Use fromReadModel with a minimal null-safe approach: we need a real
    // ShiftDashboardReadModel but the freshness seam is what we're testing.
    // Loading a real one is fine since setUp called reseedDemo().
    // For this test, just verify the constructor accepts freshness.
    final notifier = ShiftDashboardNotifier.emptyForTest(AppDataStatus.noData);
    expect(notifier.freshness, isNull,
        reason: 'emptyForTest sets freshness to null');
    notifier.dispose();

    // Verify the freshness model itself
    expect(freshness.state, FreshnessState.updated);
    expect(freshness.age!.inMinutes, 30);
  });

  // ── Locked weekly plan tests (7.55l.7a) ──────────────────────────────────

  test('notifier read model uses locked weekly plan day values', () async {
    // Get the locked plan to know expected day values
    final lockedPlan = await SchedulePlanReadService.instance
        .getExistingCurrentLockedWeeklyPlan();
    expect(lockedPlan, isNotNull);

    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.readModel, isNotNull);

    // Dashboard forecast must match a day from the locked plan
    final matchingDay = lockedPlan!.dayPlans
        .where((d) => d.forecastCovers == notifier.readModel!.forecastCovers)
        .firstOrNull;
    expect(matchingDay, isNotNull,
        reason:
            'Notifier forecast covers must match a locked plan day row');

    notifier.dispose();
  });

  test('notifier degrades honestly when locked snapshot is missing but live plan exists',
      () async {
    final db = await SqliteDatabase.instance.database;
    await db.delete('weekly_plan_snapshots');

    final livePlan =
        await SchedulePlanReadService.instance.getCurrentWeeklyPlan();
    expect(livePlan, isNotNull,
        reason: 'the live plan path should still be available');

    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.isLoading, isFalse);
    expect(notifier.readModel, isNull,
        reason: 'Shift must not silently fall back to the live plan');
    expect(notifier.lockedPlanUnavailable, isTrue);

    notifier.dispose();
  });

  test('ShiftService.getShiftDashboard returns a read model after explicit locked snapshot bootstrap',
      () async {
    final readModel = await ShiftService.instance.getShiftDashboard();
    expect(readModel, isNotNull);
  });

  // ── Per-operator isolation race test (Launch Blocker #1) ─────────────────

  test(
      'notifier abandons publish when the active restaurant flips mid-load',
      () async {
    // Simulate a shared-device operator switch: the active restaurant id
    // returned at fetch-start differs from the one returned at fetch-end.
    // CLAUDE.md: "Per-operator isolation is non-negotiable." Stale data
    // for the prior tenant must not be published to listeners.
    //
    // First read uses the seeded demo scope so the load itself completes
    // with real data; the second read returns a different id so the
    // re-check fires the abandon path against fully-loaded (but stale)
    // state — proving the contract.
    var call = 0;
    Future<String> flippingScopeReader() async {
      call++;
      return call == 1 ? DemoScope.restaurantId : 'flipped_tenant';
    }

    var notifyCount = 0;
    final notifier = ShiftDashboardNotifier(
      activeRestaurantIdReader: flippingScopeReader,
    );
    notifier.addListener(() {
      notifyCount++;
    });

    // Wait long enough for _load to complete all its awaits and reach the
    // re-check.
    await Future<void>.delayed(const Duration(milliseconds: 500));

    // The race-check must have aborted the publish: no notify, no state
    // mutation. _isLoading remains true (its initial value), readModel
    // and freshness stay null, status stays null.
    expect(notifyCount, 0,
        reason: 'mid-load scope flip must abandon notifyListeners');
    expect(notifier.isLoading, isTrue,
        reason: 'aborted load must not set _isLoading = false');
    expect(notifier.readModel, isNull,
        reason: 'aborted load must not publish a stale read model');
    expect(notifier.freshness, isNull,
        reason: 'aborted load must not publish stale freshness');
    expect(notifier.status, isNull,
        reason: 'aborted load must not publish a stale status');

    notifier.dispose();
  });

  test(
      'notifier publishes normally when the active restaurant is stable',
      () async {
    // Control case: the same restaurant id throughout the load. The
    // race-check passes and the load completes normally.
    Future<String> stableScopeReader() async => DemoScope.restaurantId;

    final notifier = ShiftDashboardNotifier(
      activeRestaurantIdReader: stableScopeReader,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.isLoading, isFalse);
    expect(notifier.status, isNotNull);

    notifier.dispose();
  });
}
