// Baseline Manager screen — PREVIEW and OVERRIDE tests.
// Covers groups I-K from the original 3,608-line monolith: PPA guardrail
// (forecast covers / sales / FOH / BOH invariants), ManagerOverridePlan-
// Preview unit tests, and period-lens sheet LABOR % rendering. Split out
// in Bucket 5b of the 2026-05-20 test-suite tightening audit; helpers +
// fixtures live in `baseline_manager_screen_test_helpers.dart`.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/baseline_manager_service.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/database_helper.dart';
import 'package:forge_and_flow/services/demand_forecast_context_service.dart';
import 'package:forge_and_flow/domain/constants/app_defaults.dart';
import 'package:forge_and_flow/dev/demo_fixture_data.dart';
import 'package:forge_and_flow/domain/models/active_target_profile.dart';
import 'package:forge_and_flow/models/baseline_candidate_shift.dart';
import 'package:forge_and_flow/screens/baseline_manager_screen.dart';
import 'package:forge_and_flow/services/labor_model.dart';

import 'baseline_manager_screen_test_helpers.dart';

void main() {
  int? demandCovers;

  setUp(() async {
    BaselineData.clearManagerOverride();
    BaselineManagerService.instance.serverSelectionWriter = null;
    await DatabaseHelper.instance.reseedDemo();
    await DatabaseHelper.instance.replaceBaselineSelectedRecordKeys({});
    final ctx = await DemandForecastContextService.instance.getCurrentContext();
    demandCovers = ctx.historicalWeeklyAvgCovers;
  });

  tearDown(() {
    BaselineManagerService.instance.serverSelectionWriter = null;
  });

  // ── I — PPA guardrail: changing PPA changes sales/BOH, not covers/FOH ─────

  group('I - PPA guardrail', () {
    // Two candidates with same CPLH/SPLH but different PPA.
    const lowPPA = BaselineCandidateShift(
      recordKey: '2026-W10|Mon|lunch_low',
      weekId: '2026-W10',
      weekLabel: 'Week of Mar 3',
      dayLabel: 'Mon',
      daypart: 'lunch',
      covers: 160,
      cplh: 4.80,
      splh: 185.0,
      ppa: 38.0,
      primaryLeverId: 'cplh_up',
      isSelected: false,
      actualLaborPct: 26.5,
    );

    const highPPA = BaselineCandidateShift(
      recordKey: '2026-W10|Mon|lunch_high',
      weekId: '2026-W10',
      weekLabel: 'Week of Mar 3',
      dayLabel: 'Mon',
      daypart: 'lunch',
      covers: 160,
      cplh: 4.80,
      splh: 185.0,
      ppa: 52.0,
      primaryLeverId: 'cplh_up',
      isSelected: false,
      actualLaborPct: 20.2,
    );

    test(
      'different PPA → same forecast covers, different sales and BOH hrs',
      () async {
        final demandCtx = await DemandForecastContextService.instance
            .getCurrentContext();
        final demandCovers = demandCtx.historicalWeeklyAvgCovers;

        final previewLow = ManagerOverridePlanPreview.fromDraftSelection([
          lowPPA,
        ], historicalWeeklyAvgCovers: demandCovers);
        final previewHigh = ManagerOverridePlanPreview.fromDraftSelection([
          highPPA,
        ], historicalWeeklyAvgCovers: demandCovers);

        expect(previewLow, isNotNull);
        expect(previewHigh, isNotNull);

        // Forecast covers are fixed from demand — same regardless of PPA.
        expect(previewLow!.forecastCovers, equals(previewHigh!.forecastCovers));
        expect(previewLow.forecastCovers, equals(demandCovers));

        // Forecast sales changes: covers * PPA.
        expect(
          previewHigh.forecastSales,
          greaterThan(previewLow.forecastSales),
        );

        // FOH hours unchanged (driven by covers/CPLH, same for both).
        expect(
          previewLow.requiredFohHours,
          equals(previewHigh.requiredFohHours),
        );

        // BOH hours change (driven by sales/SPLH, sales differs).
        expect(
          previewHigh.requiredBohHours,
          greaterThan(previewLow.requiredBohHours),
        );
      },
    );
  });

  // ── J — ManagerOverridePlanPreview unit tests ─────────────────────────────

  group('J - ManagerOverridePlanPreview unit', () {
    test('returns null when no shifts selected', () async {
      final demandCtx = await DemandForecastContextService.instance
          .getCurrentContext();
      final preview = ManagerOverridePlanPreview.fromDraftSelection(
        [],
        historicalWeeklyAvgCovers: demandCtx.historicalWeeklyAvgCovers,
      );
      expect(preview, isNull);
    });

    test('uses canonical demand context, not BaselineData', () async {
      final demandCtx = await DemandForecastContextService.instance
          .getCurrentContext();
      final demandCovers = demandCtx.historicalWeeklyAvgCovers;

      final preview = ManagerOverridePlanPreview.fromDraftSelection([
        lunch1,
      ], historicalWeeklyAvgCovers: demandCovers);
      expect(preview, isNotNull);
      expect(preview!.forecastCovers, equals(demandCovers));
      expect(preview.forecastSales, greaterThan(0));
      expect(preview.requiredFohHours, greaterThan(0));
      expect(preview.requiredBohHours, greaterThan(0));
      expect(
        preview.theoreticalLaborPct,
        closeTo(
          LaborModel.theoreticalLaborPct(
            lunch1.cplh,
            lunch1.splh,
            lunch1.ppa,
            MeridianConfig.fohWage,
            MeridianConfig.bohWage,
          ),
          0.001,
        ),
      );
      expect(
        preview.targetBlendedWage,
        closeTo(
          ActiveTargetProfile.computeTargetBlendedWage(
            targetCPLH: lunch1.cplh,
            targetSPLH: lunch1.splh,
            targetPPA: lunch1.ppa,
            fohWage: MeridianConfig.fohWage,
            bohWage: MeridianConfig.bohWage,
          ),
          0.001,
        ),
      );
    });

    test('averages multiple candidates', () async {
      final demandCtx = await DemandForecastContextService.instance
          .getCurrentContext();
      final demandCovers = demandCtx.historicalWeeklyAvgCovers;

      final preview = ManagerOverridePlanPreview.fromDraftSelection([
        lunch1,
        dinner1,
      ], historicalWeeklyAvgCovers: demandCovers);
      expect(preview, isNotNull);
      expect(preview!.forecastCovers, equals(demandCovers));
      expect(preview.forecastSales, greaterThan(0));
      final avgCplh = (lunch1.cplh + dinner1.cplh) / 2;
      final avgSplh = (lunch1.splh + dinner1.splh) / 2;
      final avgPpa = (lunch1.ppa + dinner1.ppa) / 2;
      expect(
        preview.theoreticalLaborPct,
        closeTo(
          LaborModel.theoreticalLaborPct(
            avgCplh,
            avgSplh,
            avgPpa,
            MeridianConfig.fohWage,
            MeridianConfig.bohWage,
          ),
          0.001,
        ),
      );
    });
  });

  // ── K — Period-lens sheet shows LABOR % ──────────────────────────────────

  group('K - period-lens sheet LABOR %', () {
    testWidgets('period-lens sheet shows LABOR % with the actual value', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          BaselineManagerScreen.withCandidates(
            allCandidates,
            initialDemandCovers: demandCovers,
          ),
        ),
      );
      await tester.pump();

      await tapLensChip(tester, 'lunch');
      await tapCalendarDate(tester, '2026-03-02');

      // Scope to the sheet: the preview panel behind the modal also
      // carries a "LABOR %" cell.
      final inSheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: inSheet, matching: find.text('LABOR %')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('24.3%')),
        findsOneWidget,
      );

      await dismissModalBarrier(tester);
      await tapCalendarDate(tester, '2026-03-10');
      expect(
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text('25.1%'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('period-lens sheet shows -- when labor truth is unavailable', (
      tester,
    ) async {
      const unknownLabor = BaselineCandidateShift(
        recordKey: '2026-W10|Mon|lunch_unknown',
        weekId: '2026-W10',
        weekLabel: 'Week of Mar 3',
        dayLabel: 'Mon',
        daypart: 'lunch',
        covers: 190,
        cplh: 4.4,
        splh: 178.0,
        ppa: 41.0,
        primaryLeverId: 'cplh_up',
        isSelected: false,
        businessDate: '2026-03-02',
        actualLaborPct: 0.0,
        hasActualLaborPctTruth: false,
      );

      await tester.pumpWidget(
        wrap(
          const BaselineManagerScreen.withCandidates([
            unknownLabor,
          ], initialDemandCovers: 1800),
        ),
      );
      await tester.pump();

      await tapLensChip(tester, 'lunch');
      await tapCalendarDate(tester, '2026-03-02');

      final inSheet = find.byType(BottomSheet);
      expect(
        find.descendant(of: inSheet, matching: find.text('LABOR %')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('--')),
        findsAtLeastNWidgets(1),
      );
      expect(
        find.descendant(of: inSheet, matching: find.text('0.0%')),
        findsNothing,
      );
    });
  });
}
