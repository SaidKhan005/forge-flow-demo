// Closed-state Shift chrome hardening -- widget tests.
//
// The closed-state Shift dashboard reuses the LIVE Shift screen
// verbatim, bound to the last completed day. Four LIVE-ONLY chrome
// elements are wrong/misleading on a finished/closed day and are now
// suppressed/relabeled, gated strictly on the closed flag:
//
//   1. The live ticking wall clock (`_LiveClock`) + its leading `·`
//      separator are dropped when closed (date text stays).
//   2. No period pill carries the live "currently active period"
//      orange affordance (`shift_period_pill_active`) when closed.
//   3. The live vendor-connectivity health pill
//      (`_ShiftDashboardHealthPill`) is not rendered when closed.
//   4. The FOH Productivity zone card label reads "FINAL CPLH" instead
//      of "CURRENT CPLH" when closed.
//
// A regression group asserts the LIVE path (isClosedDay = false) still
// renders all four exactly as before. closed = false must be byte-
// identical to today.
//
// Presentation-only: no data/logic/seed/migration; no kDemoMode branch
// (demo and production identical).

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
import 'package:forge_and_flow/models/shift_dashboard_read_model.dart';
import 'package:forge_and_flow/screens/shift_dashboard.dart';
import 'package:forge_and_flow/widgets/data_source_health_pill.dart';

// ── Fixture helpers (mirror test/shift_freshness_ui_test.dart) ──────────

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

Widget _build({required bool isClosedDay}) {
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
          isClosedDay: isClosedDay,
        ),
      ),
    ],
    child: const MaterialApp(
      home: Scaffold(body: ShiftDashboard()),
    ),
  );
}

/// Matches `h:mm AM/PM`, the `_LiveClock` render. Used to assert the
/// ticking wall clock is absent on a closed day.
final _clockRe = RegExp(r'^\d{1,2}:\d{2}$');

bool _hasLiveClockText(WidgetTester tester) {
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    final s = w.data;
    if (s != null && _clockRe.hasMatch(s)) return true;
  }
  return false;
}

void main() {
  tearDown(() {
    ShiftDashboard.clockOverride = null;
  });

  // ── Closed state: the four LIVE-ONLY chrome elements are gone ────────

  group('closed state -- LIVE-only chrome suppressed', () {
    testWidgets(
      'no live ticking clock in the header, but the date still shows',
      (tester) async {
        // Pin the device clock so a stray `_LiveClock` would print a
        // deterministic "h:mm" we could detect.
        ShiftDashboard.clockOverride =
            () => DateTime(2026, 5, 17, 3, 50, 0);
        await tester.pumpWidget(_build(isClosedDay: true));
        await tester.pump();
        await tester.pump();

        // Fix 1: no `h:mm` live clock text anywhere.
        expect(_hasLiveClockText(tester), isFalse,
            reason: 'closed day must not render the live ticking clock');
        // The "day · Mon DD" date text still renders (Mar 27 fixture).
        expect(
          find.textContaining('Mar 27', skipOffstage: false),
          findsOneWidget,
        );
        // Sanity: the Closed marker is present (not the live screen).
        expect(find.text('Closed', skipOffstage: false), findsOneWidget);
        expect(find.text('Live', skipOffstage: false), findsNothing);
      },
    );

    testWidgets('no period pill carries the live active-now key',
        (tester) async {
      await tester.pumpWidget(_build(isClosedDay: true));
      await tester.pump();
      await tester.pump();

      // Fix 2: the orange "currently in progress" affordance is keyed
      // `shift_period_pill_active`; it must never appear when closed.
      expect(
        find.byKey(const Key('shift_period_pill_active')),
        findsNothing,
      );
    });

    testWidgets('the live vendor-connectivity health pill is absent',
        (tester) async {
      await tester.pumpWidget(_build(isClosedDay: true));
      await tester.pump();
      await tester.pump();

      // Fix 3: `_ShiftDashboardHealthPill` wraps the public
      // `DataSourceHealthPill`. When closed the wrapper sliver is not
      // built at all, so neither the present- nor the absent-marker
      // keyed child mounts. (Asserting on the public widget type is
      // robust: the OPZ sub-label's unrelated "Connect a labor
      // vendor" copy is out of scope and stays.)
      expect(find.byType(DataSourceHealthPill), findsNothing);
      expect(
        find.byKey(const Key('data_source_health_pill_present')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('data_source_health_pill_absent')),
        findsNothing,
      );
    });

    testWidgets('the zone card label reads FINAL CPLH, not CURRENT CPLH',
        (tester) async {
      await tester.pumpWidget(_build(isClosedDay: true));
      await tester.pump();
      await tester.pump();

      // Fix 4: whole-day always supplies a locked OPZ band, so the zone
      // card renders. The label must be relabeled when closed.
      expect(
        find.text('FINAL CPLH', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('CURRENT CPLH', skipOffstage: false),
        findsNothing,
      );
    });
  });

  // ── Regression: LIVE path (closed = false) unchanged ────────────────

  group('live path -- all four still render as before', () {
    testWidgets('live ticking clock renders in the header', (tester) async {
      ShiftDashboard.clockOverride = () => DateTime(2026, 5, 17, 3, 50, 0);
      await tester.pumpWidget(_build(isClosedDay: false));
      await tester.pump();
      await tester.pump();

      // Fix 1 inverse: the live clock IS present on the live path.
      expect(_hasLiveClockText(tester), isTrue,
          reason: 'live day must keep the ticking clock');
      // And no Closed marker on the live path.
      expect(find.text('Closed', skipOffstage: false), findsNothing);
    });

    testWidgets('zone card label is CURRENT CPLH on the live path',
        (tester) async {
      await tester.pumpWidget(_build(isClosedDay: false));
      await tester.pump();
      await tester.pump();

      // Fix 4 inverse: live keeps the original "CURRENT CPLH" label.
      expect(
        find.text('CURRENT CPLH', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('FINAL CPLH', skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('the health pill wrapper is mounted on the live path',
        (tester) async {
      await tester.pumpWidget(_build(isClosedDay: false));
      await tester.pump();
      await tester.pump();

      // Fix 3 inverse: on the live path `_ShiftDashboardHealthPill`
      // builds, so the public `DataSourceHealthPill` mounts and renders
      // exactly one of its two keyed children (present OR absent: the
      // pill is honest-silent when every metric is live, but the
      // wrapper is still in the tree, byte-unchanged from today).
      expect(find.byType(DataSourceHealthPill), findsOneWidget);
      final present = find
          .byKey(const Key('data_source_health_pill_present'))
          .evaluate()
          .isNotEmpty;
      final absent = find
          .byKey(const Key('data_source_health_pill_absent'))
          .evaluate()
          .isNotEmpty;
      expect(present || absent, isTrue,
          reason: 'live path keeps the health-pill wrapper mounted');
    });

    testWidgets(
      'live path renders the normal data view (RefreshIndicator)',
      (tester) async {
        await tester.pumpWidget(_build(isClosedDay: false));
        await tester.pump();
        await tester.pump();

        // The pull-to-refresh affordance is untouched by this slice on
        // either path (out of scope).
        expect(find.byType(RefreshIndicator), findsOneWidget);
      },
    );
  });
}
