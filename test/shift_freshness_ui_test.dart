// Phase 7.55n.8 -- Shift freshness UI widget tests.
//
// Validates:
// A. freshness label renders "Live" when freshness state is live
// B. freshness label renders "Updated X min ago" when state is updated/stale
// C. pull-to-refresh affordance exists via RefreshIndicator
// D. refreshing state preserves prior age context
// E. empty state still renders correctly (no regression)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/state/restaurant_scope_notifier.dart';
import 'package:forge_and_flow/state/shift_dashboard_notifier.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/domain/models/open_shift_snapshot.dart';
import 'package:forge_and_flow/domain/models/restaurant_location.dart';
import 'package:forge_and_flow/models/app_data_status.dart';
import 'package:forge_and_flow/models/current_state_freshness.dart';
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/next_service_period_open_resolver.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';

// ── Fixture helpers ─────────────────────────────────────────────────────

ShiftDashboardReadModel _fixtureReadModel() {
  final profile = ActiveTargetProfile(
    targetProfileId: 'test_active',
    restaurantId: 'demo_restaurant_001',
    sourceType: 'system_baseline',
    targetCPLH: BaselineData.derivedTargetCPLH,
    targetSPLH: BaselineData.derivedTargetSPLH,
    targetPPA: BaselineData.derivedTargetPPA,
    fohWage: MeridianConfig.fohWage,
    bohWage: MeridianConfig.bohWage,
    opzFloorCPLH: BaselineData.opzFloorCPLH,
    opzCeilingCPLH: BaselineData.opzCeilingCPLH,
    theoreticalFohLaborPct: BaselineData.derivedFohTheoreticalLaborPct,
    theoreticalBohLaborPct: BaselineData.derivedBohTheoreticalLaborPct,
    theoreticalLaborPct: BaselineData.derivedTheoreticalLaborPct,
    builtAt: '2026-03-27T19:42:00',
  );
  final snapshot = OpenShiftSnapshot(
    restaurantId: 'demo_restaurant_001',
    weekId: '2026-W13',
    dayLabel: 'Fri',
    daypart: 'dinner',
    status: 'open',
    businessDate: '2026-03-27',
    forecastCovers: ShiftSnapshot.shiftForecastCovers,
    currentCovers: ShiftSnapshot.actualCovers,
    scheduledFohHours: ShiftSnapshot.scheduledFohHours,
    scheduledBohHours: ShiftSnapshot.scheduledBohHours,
    currentPPA: ShiftSnapshot.actualPPA,
    currentCPLH: ShiftSnapshot.actualCPLH,
    currentSPLH: ShiftSnapshot.actualSPLH,
    blendedWage: ShiftSnapshot.blendedWage,
    timeLabel: ShiftSnapshot.time,
    serviceElapsedLabel: ShiftSnapshot.serviceElapsed,
    updatedAt: '2026-03-27T19:42:00',
  );
  return ShiftDashboardReadModel.build(snapshot, profile);
}

Widget _buildWithFreshness(CurrentStateFreshness? freshness) {
  final rm = _fixtureReadModel();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>(
        create: (_) => RestaurantScopeNotifier.fromRestaurant(
          const RestaurantLocation(
            restaurantId: 'demo_restaurant_001',
            displayName: 'Test Restaurant',
            businessTimezone: 'America/St_Johns',
            createdAt: '2026-03-30T10:00:00',
            updatedAt: '2026-03-30T10:00:00',
          ),
        ),
      ),
      ChangeNotifierProvider<ShiftDashboardNotifier>(
        create: (_) =>
            ShiftDashboardNotifier.fromReadModel(rm, freshness: freshness),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(body: ShiftDashboard()),
    ),
  );
}

Widget _buildClosedState({NextServicePeriodOpen? nextOpen}) {
  final rm = _fixtureReadModel();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>(
        create: (_) => RestaurantScopeNotifier.fromRestaurant(
          const RestaurantLocation(
            restaurantId: 'demo_restaurant_001',
            displayName: 'Test Restaurant',
            businessTimezone: 'America/St_Johns',
            createdAt: '2026-03-30T10:00:00',
            updatedAt: '2026-03-30T10:00:00',
          ),
        ),
      ),
      ChangeNotifierProvider<ShiftDashboardNotifier>(
        create: (_) => ShiftDashboardNotifier.fromReadModel(
          rm,
          isClosedDay: true,
          nextOpen: nextOpen,
        ),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(body: ShiftDashboard()),
    ),
  );
}

Widget _buildEmptyState() {
  return ChangeNotifierProvider<ShiftDashboardNotifier>(
    create: (_) => ShiftDashboardNotifier.emptyForTest(AppDataStatus.noData),
    child: const MaterialApp(
      home: Scaffold(body: ShiftDashboard()),
    ),
  );
}

void main() {
  tearDown(() {
    ShiftDashboard.clockOverride = null;
  });

  // ── A: live freshness ─────────────────────────────────────────────────

  group('A -- live freshness label', () {
    testWidgets('renders Live when freshness state is live', (tester) async {
      final now = DateTime.utc(2026, 4, 13, 12, 0, 0);
      final freshness = CurrentStateFreshness(
        state: FreshnessState.live,
        updatedAt: now,
        evaluatedAt: now,
      );
      await tester.pumpWidget(_buildWithFreshness(freshness));
      await tester.pump();
      await tester.pump();

      expect(find.text('Live', skipOffstage: false), findsOneWidget);
    });
  });

  // ── B: updated / stale freshness ──────────────────────────────────────

  group('B -- updated/stale freshness label', () {
    testWidgets('renders Updated 3 min ago when 3 minutes old',
        (tester) async {
      final now = DateTime.utc(2026, 4, 13, 12, 0, 0);
      final freshness = CurrentStateFreshness(
        state: FreshnessState.updated,
        updatedAt: now.subtract(const Duration(minutes: 3)),
        evaluatedAt: now,
      );
      await tester.pumpWidget(_buildWithFreshness(freshness));
      await tester.pump();
      await tester.pump();

      expect(
          find.text('Updated 3 min ago', skipOffstage: false), findsOneWidget);
    });

    testWidgets('renders Updated 1 hr ago when stale at 90 minutes',
        (tester) async {
      final now = DateTime.utc(2026, 4, 13, 12, 0, 0);
      final freshness = CurrentStateFreshness(
        state: FreshnessState.stale,
        updatedAt: now.subtract(const Duration(minutes: 90)),
        evaluatedAt: now,
      );
      await tester.pumpWidget(_buildWithFreshness(freshness));
      await tester.pump();
      await tester.pump();

      expect(
          find.text('Updated 1 hr ago', skipOffstage: false), findsOneWidget);
    });

    testWidgets('renders Updated just now when age < 1 min', (tester) async {
      final now = DateTime.utc(2026, 4, 13, 12, 0, 0);
      final freshness = CurrentStateFreshness(
        state: FreshnessState.updated,
        updatedAt: now.subtract(const Duration(seconds: 30)),
        evaluatedAt: now,
      );
      await tester.pumpWidget(_buildWithFreshness(freshness));
      await tester.pump();
      await tester.pump();

      expect(find.text('Updated just now', skipOffstage: false),
          findsOneWidget);
    });
  });

  // ── C: pull-to-refresh affordance ─────────────────────────────────────

  group('C -- pull-to-refresh', () {
    testWidgets('RefreshIndicator exists on data view', (tester) async {
      final now = DateTime.utc(2026, 4, 13, 12, 0, 0);
      final freshness = CurrentStateFreshness(
        state: FreshnessState.live,
        updatedAt: now,
        evaluatedAt: now,
      );
      await tester.pumpWidget(_buildWithFreshness(freshness));
      await tester.pump();
      await tester.pump();

      expect(find.byType(RefreshIndicator), findsOneWidget);
    });

    testWidgets('RefreshIndicator exists on empty state', (tester) async {
      await tester.pumpWidget(_buildEmptyState());
      await tester.pump();

      expect(find.byType(RefreshIndicator), findsOneWidget);
    });
  });

  // ── D: refreshing preserves prior age ─────────────────────────────────

  group('D -- refreshing state', () {
    testWidgets('preserves prior age text during refresh', (tester) async {
      final now = DateTime.utc(2026, 4, 13, 12, 0, 0);
      final freshness = CurrentStateFreshness.refreshing(
        priorUpdatedAt: now.subtract(const Duration(minutes: 7)),
        evaluatedAt: now,
      );
      await tester.pumpWidget(_buildWithFreshness(freshness));
      await tester.pump();
      await tester.pump();

      expect(
          find.text('Updated 7 min ago', skipOffstage: false), findsOneWidget);
    });
  });

  // ── E: no freshness (null) ────────────────────────────────────────────

  group('E -- null freshness', () {
    testWidgets('no freshness label when freshness is null', (tester) async {
      await tester.pumpWidget(_buildWithFreshness(null));
      await tester.pump();
      await tester.pump();

      expect(find.text('Live', skipOffstage: false), findsNothing);
      expect(
          find.textContaining('Updated', skipOffstage: false), findsNothing);
    });
  });

  // ── F: empty state non-regression ─────────────────────────────────────

  group('F -- empty state non-regression', () {
    testWidgets('empty state still renders NO DATA headline', (tester) async {
      await tester.pumpWidget(_buildEmptyState());
      await tester.pump();

      expect(find.text('NO DATA'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  // ── G: closed-state Shift dashboard ───────────────────────────────────
  // Per-Daypart V1 — closed-state screen. The SAME Shift layout renders
  // bound to the last completed day's final values, marked Closed: a
  // grey "Closed" marker replaces the green "Live" chip and a slim
  // reopen line shows under the title. Same widgets, presentation only.

  group('G -- closed-state dashboard', () {
    testWidgets('renders grey "Closed" marker, never "Live"',
        (tester) async {
      await tester.pumpWidget(_buildClosedState());
      await tester.pump();
      await tester.pump();

      expect(find.text('Closed', skipOffstage: false), findsOneWidget);
      expect(find.text('Live', skipOffstage: false), findsNothing);
      // Same layout: the normal data view (RefreshIndicator) renders,
      // NOT the bare empty state.
      expect(find.byType(RefreshIndicator), findsOneWidget);
    });

    testWidgets('shows the reopen line with weekday + time', (tester) async {
      const lateNight = ServicePeriodDefinition(
        id: 'late_night',
        label: 'Late Night',
        shortLabel: 'LN',
        sortOrder: 3,
        startLocalTime: '23:00',
        endLocalTime: '02:00',
        rollsPastMidnight: true,
        applicableDays: [5, 6],
      );
      // Friday 2026-05-15 23:00 local.
      final nextOpen = NextServicePeriodOpen(
        localOpen: DateTime(2026, 5, 15, 23, 0),
        definition: lateNight,
        isoWeekday: DateTime.friday,
      );
      await tester.pumpWidget(_buildClosedState(nextOpen: nextOpen));
      await tester.pump();
      await tester.pump();

      expect(
        find.text(
          'Final results for this day. Live shift reopens '
          'Friday, 11:00 PM.',
          skipOffstage: false,
        ),
        findsOneWidget,
      );
    });

    testWidgets('omits the reopen sentence when next open is unresolved',
        (tester) async {
      await tester.pumpWidget(_buildClosedState(nextOpen: null));
      await tester.pump();
      await tester.pump();

      // Lead-in still shows (settled history), but no phantom time.
      expect(
        find.text('Final results for this day.', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.textContaining('reopens', skipOffstage: false),
        findsNothing,
      );
    });
  });
}
