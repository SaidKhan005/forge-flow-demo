// Per-Daypart V1 (UX) — Shift active-period chip + FOH matrix label tests.
//
// Operator findings (live walkthrough, binding):
//   A. The active service-period chip must drop the literal "ACTIVE NOW"
//      text. The current real-time period is signalled by a surrounding
//      orange (sunset) border ONLY; other chips keep the subtle border.
//   B. The FOH PRODUCTIVITY CPLH x SPLH matrix row/column labels must
//      render in full ("CPLH OVER/OPZ/UNDER", "SPLH LOW/ON/HIGH"), not
//      ellipsized, with no RenderFlex overflow at phone width.

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
import 'package:forge_and_flow/theme/app_theme.dart';
import 'package:forge_and_flow/widgets/opz_matrix_grid.dart';

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

Widget _buildShiftDashboard() {
  final rm = _fixtureReadModel();
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<RestaurantScopeNotifier>(
        create: (_) => RestaurantScopeNotifier.fromRestaurant(
          RestaurantLocation(
            restaurantId: 'demo_restaurant_001',
            displayName: MeridianConfig.restaurantName,
            businessTimezone: 'America/St_Johns',
            createdAt: '2026-03-30T10:00:00',
            updatedAt: '2026-03-30T10:00:00',
          ),
        ),
      ),
      ChangeNotifierProvider<ShiftDashboardNotifier>(
        create: (_) => ShiftDashboardNotifier.fromReadModel(rm),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: ShiftDashboard())),
  );
}

void main() {
  tearDown(() {
    ShiftDashboard.clockOverride = null;
  });

  group('Finding A — active period chip is border-only', () {
    testWidgets(
      'active chip carries an orange border and NO "ACTIVE NOW" text',
      (tester) async {
        // Fri 2026-03-27 20:30 — Dinner is the live service period.
        ShiftDashboard.clockOverride = () => DateTime(2026, 3, 27, 20, 30);

        await tester.pumpWidget(_buildShiftDashboard());
        await tester.pump();
        await tester.pump();

        // The literal label is gone everywhere.
        expect(
          find.text('ACTIVE NOW', skipOffstage: false),
          findsNothing,
        );

        // Exactly one chip is flagged active via the stable key.
        final activeChip =
            find.byKey(const Key('shift_period_pill_active'), skipOffstage: false);
        expect(activeChip, findsOneWidget);

        // The sole active affordance is the orange (sunset) border.
        final container = tester.widget<Container>(activeChip);
        final decoration = container.decoration as BoxDecoration;
        final border = decoration.border as Border;
        expect(border.top.color, AppColors.sunset);
        expect(border.top.width, 2.0);
      },
    );

    testWidgets('no active chip when the clock is between periods',
        (tester) async {
      // Tue 2026-03-31 16:00 — outside Lunch, before Dinner.
      ShiftDashboard.clockOverride = () => DateTime(2026, 3, 31, 16, 0);

      await tester.pumpWidget(_buildShiftDashboard());
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('shift_period_pill_active'),
            skipOffstage: false),
        findsNothing,
      );
      expect(find.text('ACTIVE NOW', skipOffstage: false), findsNothing);
    });
  });

  group('Finding B — FOH matrix labels render in full, no overflow', () {
    Future<void> pumpGrid(WidgetTester tester, double width) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: const OpzMatrixGrid(
                  cplh: OpzCplhBand.inOpz,
                  splh: OpzSplhBand.onTarget,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    const fullLabels = <String>[
      'CPLH OVER',
      'CPLH OPZ',
      'CPLH UNDER',
      'SPLH LOW',
      'SPLH ON',
      'SPLH HIGH',
    ];

    for (final width in <double>[1080, 360, 300]) {
      testWidgets('full labels present, no overflow at ${width}px',
          (tester) async {
        await pumpGrid(tester, width);

        // No RenderFlex overflow / layout exception at this width.
        expect(tester.takeException(), isNull);

        // Every label renders with its complete string (find.text matches
        // the Text widget's data even when it soft-wraps to two lines —
        // so this proves the copy is full, never hard-clipped).
        for (final label in fullLabels) {
          expect(
            find.text(label, skipOffstage: false),
            findsOneWidget,
            reason: 'label "$label" must render in full at ${width}px',
          );
        }
      });
    }
  });
}
