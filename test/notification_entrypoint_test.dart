// Phase 7.55p.4d1 — Notification entrypoint widget tests.
//
// Validates:
// A. notification icon is visible on the default Shift tab (standalone mode)
// B. notification icon is an actionable IconButton
//
// Uses stub providers so the test runs without SQLite or DB access.
// Child widgets render in their initial/empty states.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/forge_flow_app.dart';
import 'package:forge_and_flow/data/active_target_profile_notifier.dart';
import 'package:forge_and_flow/data/demand_forecast_context_notifier.dart';
import 'package:forge_and_flow/data/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/data/schedule_distribution_weights_notifier.dart';
import 'package:forge_and_flow/data/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/data/shift_data_source.dart';
import 'package:forge_and_flow/data/week_data_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/domain/repositories/restaurant_scope_repository.dart';
import 'package:forge_and_flow/domain/repositories/shift_record_repository.dart';
import 'package:forge_and_flow/domain/repositories/week_record_repository.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/models/history_pattern_record.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/models/week_data.dart';
import 'package:forge_and_flow/models/week_record.dart';

// ── Stubs — prevent SQLite/DB access during test ────────────────────────

class _NullShiftDataSource implements ShiftDataSource {
  const _NullShiftDataSource();
  @override
  Future<WeekData?> getWeekToDate() async => null;
  @override
  Future<List<WeekRecord>> getWeekHistory() async => [];
  @override
  Future<List<HistoryPatternRecord>> getHistoryPatternRecords() async => [];
  @override
  Future<List<ShiftRecord>> getFullWeekShifts(String weekId) async => [];
  @override
  Future<List<ShiftRecord>> getHistoricalClosedShifts() async => [];
}

class _StubDemandForecastNotifier extends DemandForecastContextNotifier {
  @override
  Future<void> load() async {} // no-op — skip DB access
}

class _FakeScopeRepo implements RestaurantScopeRepository {
  @override
  Future<RestaurantLocation> getOrCreateActiveRestaurant() async =>
      const RestaurantLocation(
        restaurantId: 'test',
        displayName: 'Test',
        businessTimezone: 'UTC',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
      );
  @override
  Future<String> getActiveRestaurantId() async => 'test';
}

class _FakeWeekRepo implements WeekRecordRepository {
  @override
  Future<List<WeekRecord>> getWeekHistory(String restaurantId) async => [];
  @override
  Future<int> upsertWeekRecord(WeekRecord record) async => 1;
}

class _FakeShiftRepo implements ShiftRecordRepository {
  @override
  Future<List<ShiftRecord>> getShiftsForWeek(
          String restaurantId, String weekId) async =>
      [];
  @override
  Future<List<ShiftRecord>> getClosedShiftsForWeeks(
          String restaurantId, List<String> weekIds) async =>
      [];
  @override
  Future<List<ShiftRecord>> getClosedShiftsInDateRange(
          String restaurantId, String startDate, String endDate) async =>
      [];
  @override
  Future<String?> getLatestClosedBusinessDate(String restaurantId) async =>
      null;
  @override
  Future<int> replaceShiftForSlot(ShiftRecord record) async => 1;
}

// ── Test harness ────────────────────────────────────────────────────────

Widget _buildAppShell() {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>.value(
        value: RestaurantScopeNotifier.fromRestaurant(
          const RestaurantLocation(
            restaurantId: 'test',
            displayName: 'Test',
            businessTimezone: 'UTC',
            createdAt: '2026-01-01T00:00:00Z',
            updatedAt: '2026-01-01T00:00:00Z',
          ),
        ),
      ),
      Provider<ShiftDataSource>.value(value: const _NullShiftDataSource()),
      ChangeNotifierProvider<ActiveTargetProfileNotifier>.value(
        value: ActiveTargetProfileNotifier.fromProfile(
          const ActiveTargetProfile(
            targetProfileId: 'test_profile',
            restaurantId: 'test',
            sourceType: 'system_baseline',
            targetCPLH: 20.0,
            targetSPLH: 60.0,
            targetPPA: 30.0,
            fohWage: 15.0,
            bohWage: 18.0,
            opzFloorCPLH: 15.0,
            opzCeilingCPLH: 25.0,
            theoreticalFohLaborPct: 25.0,
            theoreticalBohLaborPct: 25.0,
            theoreticalLaborPct: 25.0,
            builtAt: '2026-01-01T00:00:00Z',
          ),
        ),
      ),
      ChangeNotifierProvider<WeekDataNotifier>(
        create: (_) => WeekDataNotifier(const _NullShiftDataSource()),
      ),
      ChangeNotifierProvider<ShiftDashboardNotifier>(
        create: (_) => ShiftDashboardNotifier.emptyForTest(AppDataStatus.noData),
      ),
      ChangeNotifierProvider<DemandForecastContextNotifier>(
        create: (_) => _StubDemandForecastNotifier(),
      ),
      ChangeNotifierProvider<ScheduleDistributionWeightsNotifier>(
        create: (_) => ScheduleDistributionWeightsNotifier(
          scopeRepo: _FakeScopeRepo(),
          weekRepo: _FakeWeekRepo(),
          shiftRepo: _FakeShiftRepo(),
        ),
      ),
    ],
    child: const MaterialApp(home: AppShell()),
  );
}

void main() {
  // ── A: notification icon visible on default Shift tab ─────────────────

  group('A — notification entrypoint on Shift tab', () {
    testWidgets('notification icon is present in standalone AppBar',
        (tester) async {
      await tester.pumpWidget(_buildAppShell());
      await tester.pump(); // settle initial build

      expect(
        find.byIcon(Icons.notifications_none_outlined),
        findsOneWidget,
        reason: 'notification icon should be visible on the default Shift tab',
      );
    });

    testWidgets('settings icon is also present (both icons reachable)',
        (tester) async {
      await tester.pumpWidget(_buildAppShell());
      await tester.pump();

      expect(
        find.byIcon(Icons.settings_outlined),
        findsOneWidget,
        reason: 'settings icon should be visible alongside notifications',
      );
    });
  });

  // ── B: notification icon is actionable ────────────────────────────────

  group('B — notification entrypoint is actionable', () {
    testWidgets('notification icon is inside a tappable IconButton',
        (tester) async {
      await tester.pumpWidget(_buildAppShell());
      await tester.pump();

      final iconButton = find.ancestor(
        of: find.byIcon(Icons.notifications_none_outlined),
        matching: find.byType(IconButton),
      );
      expect(iconButton, findsOneWidget,
          reason: 'notification icon should be wrapped in an IconButton');
    });
  });
}
