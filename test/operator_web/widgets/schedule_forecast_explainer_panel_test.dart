// Phase 8 W5.B - Schedule forecast explainer panel widget tests.
//
// Coverage:
//   * each of the 7 explainer fields renders when context has a baseline
//   * thin-history fallback renders when the proxy says
//     `covers_source = unavailable` (or context is null)
//   * never shows zero for missing data — the placeholder is the
//     "need 60 days" caveat instead

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/services/operator_web_schedule_gateway.dart';
import 'package:forge_and_flow/operator_web/widgets/schedule_forecast_explainer_panel.dart';
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

  ScheduleForecastContext explainedContext({
    int? baselineWeekly = 1180,
    int? baselineTotal = 10110,
    double weeksRepresented = 60 / 7,
    int? recentTrend = 18,
    String coversSource = 'app_derived_from_historical_average',
  }) {
    return ScheduleForecastContext(
      forecastContextId: 'ctx-1',
      weekStartDate: '2026-05-04',
      weekEndDate: '2026-05-10',
      coversSource: coversSource,
      builtAt: DateTime.utc(2026, 5, 3, 12),
      targetPpa: 38.0,
      forecastSales: 46740.0,
      requiredFohHours: 260,
      requiredBohHours: 188,
      theoreticalLaborDollars: 7865.0,
      baselineWeeksRepresented: weeksRepresented,
      anchorBusinessDate: '2026-05-03',
      baselineTotalCovers: baselineTotal,
      baselineWeeklyAvgCovers: baselineWeekly,
      recentThreeWeekTotalCovers: 3540,
      recentThreeWeekWeeklyAvgCovers: 1198,
      recentTrendDeltaCovers: recentTrend,
      resolvedWeeklyForecastCovers: 1230,
    );
  }

  group('ScheduleForecastExplainerPanel', () {
    testWidgets('renders all seven explainer fields when context has baseline',
        (tester) async {
      await sizeViewport(tester);
      await tester.pumpWidget(
        wrap(ScheduleForecastExplainerPanel(context: explainedContext())),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('schedule_forecast_explainer_panel')),
        findsOneWidget,
      );
      // 7 explainer rows.
      expect(find.byKey(const Key('schedule_explainer_baseline')), findsOneWidget);
      expect(find.byKey(const Key('schedule_explainer_trend')), findsOneWidget);
      expect(find.byKey(const Key('schedule_explainer_ppa')), findsOneWidget);
      expect(
        find.byKey(const Key('schedule_explainer_forecast_sales')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('schedule_explainer_required_foh')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('schedule_explainer_required_boh')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('schedule_explainer_theoretical_dollars')),
        findsOneWidget,
      );
      // Plain-English values.
      expect(find.text('1180 covers / week'), findsOneWidget);
      expect(find.text('\$38'), findsOneWidget);
      expect(find.text('\$46,740'), findsOneWidget);
      expect(find.text('260 hrs / week'), findsOneWidget);
      expect(find.text('188 hrs / week'), findsOneWidget);
      expect(find.text('\$7,865'), findsOneWidget);
      expect(find.text('18 covers / week up'), findsOneWidget);
    });

    testWidgets(
      'renders the thin-history caveat when covers_source is unavailable',
      (tester) async {
        await sizeViewport(tester);
        await tester.pumpWidget(
          wrap(
            ScheduleForecastExplainerPanel(
              context: explainedContext(
                baselineWeekly: null,
                baselineTotal: null,
                weeksRepresented: 29 / 7,
                coversSource: 'unavailable',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('schedule_forecast_explainer_thin_history')),
          findsOneWidget,
        );
        expect(
          find.textContaining('Need 60 days of history'),
          findsOneWidget,
        );
        expect(find.textContaining('29 days'), findsOneWidget);
        // Never show zero for missing data.
        expect(find.text('0 covers / week'), findsNothing);
        expect(find.text('\$0'), findsNothing);
      },
    );

    testWidgets('renders the thin-history caveat when context is null',
        (tester) async {
      await sizeViewport(tester);
      await tester.pumpWidget(
        wrap(const ScheduleForecastExplainerPanel(context: null)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('schedule_forecast_explainer_thin_history')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Need 60 days of history'),
        findsOneWidget,
      );
    });

    testWidgets('renders flat-trend copy when recent delta is zero',
        (tester) async {
      await sizeViewport(tester);
      await tester.pumpWidget(
        wrap(
          ScheduleForecastExplainerPanel(
            context: explainedContext(recentTrend: 0),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Flat vs. baseline'), findsOneWidget);
    });
  });
}
