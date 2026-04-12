// Shift dashboard notifier tests — empty-state behavior + locked plan (7.55l.7a).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/data/schedule_plan_read_service.dart';
import 'package:forge_and_flow/data/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/app_data_status.dart';

void main() {
  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
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
    expect(notifier.readModel!.inTheBooksCovers, 72);

    notifier.dispose();
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

  test('after clearAllData notifier shows no-data status', () async {
    await SqliteDatabase.instance.clearAllData();

    final notifier = ShiftDashboardNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(notifier.isLoading, isFalse);
    expect(notifier.readModel, isNull);
    expect(notifier.status!.type, AppDataStatusType.noData);

    notifier.dispose();
  });

  // ── Locked weekly plan tests (7.55l.7a) ──────────────────────────────────

  test('notifier read model uses locked weekly plan day values', () async {
    // Get the locked plan to know expected day values
    final lockedPlan = await SchedulePlanReadService.instance
        .getCurrentLockedWeeklyPlan();
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
}
