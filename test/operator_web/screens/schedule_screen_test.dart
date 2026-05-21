// Phase 8 W5.B - Operator Web Schedule screen widget tests.
//
// Coverage:
//   * renders week header + daily rows + explainer panel for an
//     operator with a locked snapshot
//   * permission-denied state for actors without a console-read role
//   * setup state when no gateway is wired
//   * empty state when the gateway returns null
//   * thin-history fallback (no forecast context)
//   * gateway error state surfaces a plain-English message

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/operator_web_auth_source.dart';
import 'package:forge_and_flow/operator_web/screens/schedule_screen.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_schedule_gateway.dart';
import 'package:forge_and_flow/theme/app_theme.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeData,
    home: Scaffold(body: child),
  );

  Future<void> sizeViewport(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  OperatorWebSession sessionWith({
    List<String> roles = const <String>['operator_owner'],
    Set<String> permissions = const <String>{},
  }) => OperatorWebSession(
    uid: 'demo-uid',
    email: 'alex@brio-restaurants.com',
    displayName: 'Alex Morrison',
    operatorId: 'demo-operator',
    businessName: 'Brio Restaurants',
    primaryLocationId: 'demo-location',
    primaryLocationName: 'Brio Main Street',
    roles: roles,
    permissions: permissions,
    mfaEnrolled: false,
  );

  ScheduleSnapshot makeSnapshot({ScheduleForecastContext? context}) {
    final lockedAt = DateTime.utc(2026, 5, 3, 12);
    return ScheduleSnapshot(
      snapshotId: 'snap-1',
      operatorId: 'demo-operator',
      locationId: 'demo-location',
      restaurantId: 'demo-location',
      weekStartDate: '2026-05-04',
      weekEndDate: '2026-05-10',
      forecastCovers: 1230,
      forecastSales: 46740.0,
      requiredFohHours: 260,
      requiredBohHours: 188,
      theoreticalFohLaborDollars: 4810.0,
      theoreticalBohLaborDollars: 3055.0,
      coversSource: 'app_derived_from_historical_average',
      salesSource: 'app_derived_from_historical_average',
      lockedAt: lockedAt,
      dayRows: <ScheduleSnapshotDay>[
        for (var i = 0; i < 7; i++)
          ScheduleSnapshotDay(
            day: const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][i],
            businessDate: '2026-05-${(4 + i).toString().padLeft(2, '0')}',
            forecastCovers: 175,
            forecastSales: 6675.0,
            requiredFohHours: 36,
            requiredBohHours: 28,
          ),
      ],
      forecastContext:
          context ??
          ScheduleForecastContext(
            forecastContextId: 'ctx-1',
            weekStartDate: '2026-05-04',
            weekEndDate: '2026-05-10',
            coversSource: 'app_derived_from_historical_average',
            builtAt: lockedAt,
            targetPpa: 38.0,
            forecastSales: 46740.0,
            requiredFohHours: 260,
            requiredBohHours: 188,
            theoreticalLaborDollars: 7865.0,
            baselineWeeksRepresented: 60 / 7,
            anchorBusinessDate: '2026-05-03',
            baselineTotalCovers: 10110,
            baselineWeeklyAvgCovers: 1180,
            recentThreeWeekTotalCovers: 3540,
            recentThreeWeekWeeklyAvgCovers: 1198,
            recentTrendDeltaCovers: 18,
            resolvedWeeklyForecastCovers: 1230,
          ),
    );
  }

  group('ScheduleScreen', () {
    testWidgets('renders the week header, daily rows, and explainer panel', (
      tester,
    ) async {
      await sizeViewport(tester);
      final session = sessionWith();
      final gateway = OperatorWebDemoScheduleGateway(seed: makeSnapshot());
      await tester.pumpWidget(
        wrap(
          ScheduleScreen(
            session: session,
            locationId: session.primaryLocationId ?? '',
            locationName: session.primaryLocationName,
            gateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_screen')), findsOneWidget);
      expect(find.text('Plan'), findsOneWidget);
      expect(find.textContaining('Week of May 4'), findsOneWidget);
      expect(find.textContaining('Each row is the plan you'), findsNothing);
      // 7 daily rows + totals.
      expect(
        find.byKey(const Key('schedule_screen_daily_table')),
        findsOneWidget,
      );
      for (var i = 0; i < 7; i++) {
        final date = '2026-05-${(4 + i).toString().padLeft(2, '0')}';
        expect(
          find.byKey(Key('schedule_screen_day_row_$date')),
          findsOneWidget,
        );
      }
      expect(find.byKey(const Key('schedule_screen_totals')), findsOneWidget);
      // Explainer renders the rich panel, not the thin-history fallback.
      expect(
        find.byKey(const Key('schedule_forecast_explainer_panel')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('schedule_forecast_explainer_thin_history')),
        findsNothing,
      );
    });

    testWidgets(
      'renders permission-denied banner for actors without a read role',
      (tester) async {
        await sizeViewport(tester);
        final session = sessionWith(roles: const <String>[]);
        final gateway = OperatorWebDemoScheduleGateway(seed: makeSnapshot());
        await tester.pumpWidget(
          wrap(
            ScheduleScreen(
              session: session,
              locationId: session.primaryLocationId ?? '',
              locationName: session.primaryLocationName,
              gateway: gateway,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('schedule_screen_permission_denied')),
          findsOneWidget,
        );
        // Daily table must NOT render when permission is denied.
        expect(
          find.byKey(const Key('schedule_screen_daily_table')),
          findsNothing,
        );
      },
    );

    testWidgets('renders setup banner when no gateway is wired', (
      tester,
    ) async {
      await sizeViewport(tester);
      final session = sessionWith();
      await tester.pumpWidget(
        wrap(
          ScheduleScreen(
            session: session,
            locationId: session.primaryLocationId ?? '',
            locationName: session.primaryLocationName,
            gateway: null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('schedule_screen_unavailable')),
        findsOneWidget,
      );
    });

    testWidgets('renders empty banner when gateway returns null', (
      tester,
    ) async {
      await sizeViewport(tester);
      final session = sessionWith();
      await tester.pumpWidget(
        wrap(
          ScheduleScreen(
            session: session,
            locationId: session.primaryLocationId ?? '',
            locationName: session.primaryLocationName,
            gateway: OperatorWebDemoScheduleGateway(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_screen_empty')), findsOneWidget);
    });

    testWidgets('renders thin-history fallback when context is unavailable', (
      tester,
    ) async {
      await sizeViewport(tester);
      final session = sessionWith();
      final snapshot = makeSnapshot(
        context: ScheduleForecastContext(
          forecastContextId: 'ctx-1',
          weekStartDate: '2026-05-04',
          weekEndDate: '2026-05-10',
          coversSource: 'unavailable',
          builtAt: DateTime.utc(2026, 5, 3, 12),
          targetPpa: 0,
          forecastSales: 0,
          requiredFohHours: 0,
          requiredBohHours: 0,
          theoreticalLaborDollars: 0,
          baselineWeeksRepresented: 14 / 7,
        ),
      );
      final gateway = OperatorWebDemoScheduleGateway(seed: snapshot);
      await tester.pumpWidget(
        wrap(
          ScheduleScreen(
            session: session,
            locationId: session.primaryLocationId ?? '',
            locationName: session.primaryLocationName,
            gateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('schedule_forecast_explainer_thin_history')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('schedule_forecast_explainer_panel')),
        findsNothing,
      );
      expect(find.textContaining('14 days'), findsOneWidget);
    });

    testWidgets('renders error banner when gateway throws', (tester) async {
      await sizeViewport(tester);
      final session = sessionWith();
      final gateway = _ThrowingGateway();
      await tester.pumpWidget(
        wrap(
          ScheduleScreen(
            session: session,
            locationId: session.primaryLocationId ?? '',
            locationName: session.primaryLocationName,
            gateway: gateway,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_screen_error')), findsOneWidget);
    });

    testWidgets(
      'uses the top management banner instead of a page hierarchy notice',
      (tester) async {
        await sizeViewport(tester);
        final session = sessionWith();
        final loadedGateway = OperatorWebDemoScheduleGateway(
          seed: makeSnapshot(),
        );
        await tester.pumpWidget(
          wrap(
            ScheduleScreen(
              session: session,
              locationId: session.primaryLocationId ?? '',
              locationName: session.primaryLocationName,
              gateway: loadedGateway,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('schedule_screen_hierarchy_scope')),
          findsNothing,
        );
        expect(find.byKey(const Key('schedule_screen')), findsOneWidget);
      },
    );
  });
}

class _ThrowingGateway implements OperatorWebScheduleGateway {
  @override
  Future<ScheduleSnapshot?> fetchCurrent({
    required String operatorId,
    required String locationId,
  }) async {
    throw const OperatorWebScheduleGatewayException(
      code: 'transport_error',
      message: 'Schedule request failed.',
    );
  }
}
