// Per-Daypart Targets V1 — Slice 5: Variance Full Week non-closed rows
// read the PERSISTED locked per-period sub-rows (Option B exact
// integer-hours reconciliation), with the render-time
// `DaypartPlanAllocator` demoted to the empty-`dayDayparts` fallback
// only.
//
// Authority: docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md
//            Slice 5 + Design Rule 4 (read through the persisted
//            canonical write path) + #917/#941 (single shared
//            largest-remainder allocation — no independent rounding);
//            CLAUDE.md HP #2 (demo == prod) / HP #3 (no app-logic
//            change).
//
// What this guards:
//  1. `ShiftService.getFullWeekShifts` non-closed rows' covers/sales
//     come straight from `WeeklyPlanSnapshot.dayDaypartFor(...)`, and
//     FOH/BOH come from the SHARED exact reconciliation
//     (`reconcileLockedDaypartIntHours`) so per-period whole hours sum
//     EXACTLY to the locked day-level integer hours (Option B, not
//     naive per-cell round).
//  2. Empty `dayDayparts` → the shared helper returns `[]` and the
//     audit's allocator FALLBACK labels appear (legacy / Gap-42).
//  3. Pattern B integration: the real
//     `DataAlignmentAuditReadService.computeAuditChecks` "Full Week
//     non-closed ... = locked dayDayparts" group is FULLY aligned
//     (N/N) for the demo seed and the `DaypartPlanAllocator
//     (fallback ...)` labels are ABSENT — WITHOUT editing the audit
//     scorer.
//  4. Parity: the Variance row per-period integer hours == the Shift
//     card per-period integer hours for the same (day, period) (both
//     are the single shared reconciliation function).
//  5. Closed-row invariance: a closed row's actual
//     fohHours/bohHours/forecastCovers are byte-identical before/after
//     the swap (closed rows keep source truth).

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/domain/services/locked_daypart_int_hours.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_shift_record_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_weekly_plan_snapshot_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/models/data_alignment_audit_check.dart';
import 'package:forge_and_flow/models/data_alignment_drift_check.dart';
import 'package:forge_and_flow/models/shift_record.dart';
import 'package:forge_and_flow/services/data_alignment_audit_read_service.dart';
import 'package:forge_and_flow/services/shift_service.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const restaurantId = 'demo_restaurant_001';
  const weekId = '2026-W13';
  const businessDate = '2026-03-27'; // seeded Friday

  final defs = ServicePeriodDefinitionResolver.demoDefinitions;

  late String weekKey;

  setUp(() async {
    await SqliteDatabase.instance.reseedDemo();
    final ws = WeeklyPlanSnapshotPolicy.weekStartForDate(businessDate);
    final we = WeeklyPlanSnapshotPolicy.weekEndForDate(businessDate);
    weekKey = WeeklyPlanSnapshotPolicy.weekKeyFromSpan(ws, we);
  });

  group('Slice 5 — Variance non-closed reads locked sub-rows', () {
    test(
        'non-closed getFullWeekShifts rows: covers/sales = persisted '
        'locked sub-row; FOH/BOH = shared exact reconciliation summing '
        'to the locked day-level integer hours', () async {
      final snapshot = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);
      expect(snapshot, isNotNull);
      expect(snapshot!.dayDayparts, isNotEmpty,
          reason: 'demo seed persists locked sub-rows → locked-authority '
              'branch runs, allocator is strictly the empty fallback');

      final shifts = await ShiftService.instance.getFullWeekShifts(weekId);
      final nonClosed = shifts.where((s) => !s.isClosed).toList();
      expect(nonClosed, isNotEmpty);

      final businessDateByDay = <String, String>{
        for (final dr in snapshot.dayRows) dr.day: dr.businessDate,
      };

      for (final s in nonClosed) {
        final bd = businessDateByDay[s.dayLabel];
        expect(bd, isNotNull);
        final dd = snapshot.dayDaypartFor(
          businessDate: bd!,
          servicePeriodId: s.daypart,
        );
        expect(dd, isNotNull,
            reason: '${s.dayLabel}/${s.daypart}: must map to a persisted '
                'locked sub-row');
        final recon = reconciledLockedDaypartFor(
          snapshot: snapshot,
          businessDate: bd,
          servicePeriodId: s.daypart,
          definitions: defs,
        );
        expect(recon, isNotNull);

        // Covers (int) + sales (double) carry straight from persisted.
        expect(s.forecastCovers, equals(dd!.forecastCovers));
        expect(s.planForecastSales, closeTo(dd.forecastSales, 0.01));
        // FOH/BOH come from the SHARED exact reconciliation.
        expect(s.fohHours, equals(recon!.requiredFohHours));
        expect(s.bohHours, equals(recon.requiredBohHours));
        expect(s.scheduledFohHours, equals(recon.requiredFohHours));
        expect(s.scheduledBohHours, equals(recon.requiredBohHours));
      }

      // Option B core invariant: the SHARED reconciliation distributes
      // the locked day-level integer hours across ALL of that day's
      // persisted periods so Σ(per-period whole hours) == the locked
      // day-row integer EXACTLY (no independent per-cell rounding
      // drift). This is the property #917/#941 protect — it holds over
      // the full locked period set for the day, independent of which
      // periods happen to surface as Full Week shift rows (a period
      // with no open snapshot / shift_record legitimately has no row).
      var checkedDays = 0;
      for (final dr in snapshot.dayRows) {
        final recon = reconcileLockedDaypartIntHours(
          snapshot: snapshot,
          businessDate: dr.businessDate,
          definitions: defs,
        );
        if (recon.isEmpty) continue;
        final fohSum =
            recon.fold<int>(0, (a, r) => a + r.requiredFohHours);
        final bohSum =
            recon.fold<int>(0, (a, r) => a + r.requiredBohHours);
        expect(fohSum, equals(dr.requiredFohHours),
            reason: '${dr.day}: Σ(per-period FOH) must equal the locked '
                'day-row integer exactly (Option B)');
        expect(bohSum, equals(dr.requiredBohHours),
            reason: '${dr.day}: Σ(per-period BOH) must equal the locked '
                'day-row integer exactly (Option B)');
        checkedDays++;
      }
      expect(checkedDays, greaterThan(0),
          reason: 'fixture must contain at least one day with locked '
              'per-period sub-rows');
    });

    test(
        'empty dayDayparts → shared reconciliation returns [] and the '
        'audit takes the allocator FALLBACK labels (legacy / Gap-42)',
        () async {
      // Synthetic legacy snapshot: whole-day rows but NO persisted
      // per-period sub-rows. The shared helper must report "nothing
      // persisted" so callers take their allocator fallback.
      final legacy = WeeklyPlanSnapshot(
        snapshotId: 'legacy-no-dayparts',
        restaurantId: restaurantId,
        weekStartDate: '2026-03-23',
        weekEndDate: '2026-03-29',
        targetCycleId: 'tc-legacy',
        forecastCovers: 600,
        forecastSales: 24000,
        requiredFohHours: 120,
        requiredBohHours: 132,
        theoreticalFohLaborDollars: 1980,
        theoreticalBohLaborDollars: 2818,
        coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        salesSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
        generatedAt: '2026-03-22T00:00:00Z',
        lockedAt: '2026-03-22T00:00:00Z',
        dayRows: const [
          WeeklyPlanSnapshotDay(
            day: 'Mon',
            businessDate: '2026-03-23',
            forecastCovers: 80,
            forecastSales: 3200,
            requiredFohHours: 16,
            requiredBohHours: 18,
          ),
        ],
        // dayDayparts intentionally omitted → empty (legacy snapshot).
      );
      expect(legacy.dayDayparts, isEmpty);

      final recon = reconcileLockedDaypartIntHours(
        snapshot: legacy,
        businessDate: '2026-03-23',
        definitions: defs,
      );
      expect(recon, isEmpty,
          reason: 'no persisted sub-rows → caller must use the allocator '
              'fallback, not fabricate from absent locked rows');

      // Drive the REAL audit scorer (untouched) with the legacy
      // snapshot + a synthetic non-closed shift. The allocator-fallback
      // labels must appear; the locked-authority labels must not.
      final synthShift = ShiftRecord(
        weekId: weekId,
        dayLabel: 'Mon',
        daypart: 'lunch',
        status: 'projected',
        covers: 0,
        forecastCovers: 36,
        ppa: 0,
        cplh: 0,
        splh: 0,
        fohHours: 7,
        bohHours: 8,
        primaryLever: '',
      );
      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: null,
        targetCycle: null,
        snapshot: legacy,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: [synthShift],
        servicePeriodDefinitions: defs,
        distributionWeights: null,
      );
      final labels = checks
          .where((c) => c.groupId == DataAlignmentAuditGroup.planRuntime)
          .map((c) => c.label)
          .toList();
      expect(
        labels.any((l) => l.contains('DaypartPlanAllocator (fallback')),
        isTrue,
        reason: 'empty dayDayparts → audit must score against the '
            'allocator fallback labels',
      );
      expect(
        labels.any((l) =>
            l == 'Full Week non-closed forecast covers = locked dayDayparts'),
        isFalse,
        reason: 'the locked-authority labels must NOT appear when there '
            'are no persisted sub-rows',
      );
    });

    test(
        'Pattern B integration: real computeAuditChecks "Full Week '
        'non-closed ... = locked dayDayparts" group is FULLY aligned '
        '(N/N) and the allocator-fallback labels are ABSENT — audit '
        'scorer untouched', () async {
      final snapshot = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);
      expect(snapshot, isNotNull);
      final shifts = await ShiftService.instance.getFullWeekShifts(weekId);

      final checks = DataAlignmentAuditReadService.computeAuditChecks(
        profile: null,
        targetCycle: null,
        snapshot: snapshot,
        plan: null,
        shiftReadModel: null,
        weekData: null,
        benchmarkSelectionSummary: null,
        benchmarkSelectionSummaryTableAvailable: false,
        fullWeekShifts: shifts,
        servicePeriodDefinitions: defs,
        distributionWeights: null,
      );

      final planRuntime = checks
          .where((c) => c.groupId == DataAlignmentAuditGroup.planRuntime)
          .toList();

      // The four Full Week non-closed locked-authority checks.
      const lockedLabels = [
        'Full Week non-closed forecast covers = locked dayDayparts',
        'Full Week non-closed forecast sales = locked dayDayparts',
        'Full Week non-closed FOH hrs = locked dayDayparts',
        'Full Week non-closed BOH hrs = locked dayDayparts',
      ];
      for (final label in lockedLabels) {
        final c =
            planRuntime.firstWhere((c) => c.label == label, orElse: () {
          fail('expected locked-authority audit check "$label"');
        });
        expect(
          c.status,
          equals(DriftCheckStatus.aligned),
          reason: '"$label" must be fully aligned after the Slice 5 '
              'locked-read swap (got ${c.status}; detail ${c.detail})',
        );
        // N/N — every non-closed cell aligned, none drifted/unavailable.
        expect(c.detail, contains('aligned'));
        final parts = c.detail.split('/');
        expect(parts.length, greaterThanOrEqualTo(2));
        final aligned = int.parse(parts[0].trim());
        final total =
            int.parse(parts[1].trim().split(' ').first.trim());
        expect(total, greaterThan(0),
            reason: '"$label" must have scored at least one cell');
        expect(aligned, equals(total),
            reason: '"$label" must be N/N aligned');
      }

      // The allocator-fallback labels must be ABSENT (we are on the
      // locked authority path, not the empty-dayDayparts fallback).
      expect(
        planRuntime.any(
            (c) => c.label.contains('DaypartPlanAllocator (fallback')),
        isFalse,
        reason: 'demo seed has persisted sub-rows → the allocator '
            'fallback labels must not appear',
      );
    });

    test(
        'parity: Variance Full Week per-period integer hours == Shift '
        'card per-period integer hours for the same (day, period) — '
        'single shared reconciliation function', () async {
      final snapshot = await SqliteWeeklyPlanSnapshotRepository.instance
          .getSnapshotForWeekKey(restaurantId, weekKey);
      expect(snapshot, isNotNull);
      final shifts = await ShiftService.instance.getFullWeekShifts(weekId);
      final nonClosed = shifts.where((s) => !s.isClosed).toList();
      expect(nonClosed, isNotEmpty);

      final businessDateByDay = <String, String>{
        for (final dr in snapshot!.dayRows) dr.day: dr.businessDate,
      };

      for (final s in nonClosed) {
        final bd = businessDateByDay[s.dayLabel];
        if (bd == null) continue;
        // The Shift card surfaces the operator integer via
        // `requiredHours.round()` of the value the notifier feeds it;
        // the notifier feeds the SAME shared reconciliation
        // (`reconciledLockedDaypartFor`). So the integer the Shift card
        // shows is exactly this:
        final cardHrs = reconciledLockedDaypartFor(
          snapshot: snapshot,
          businessDate: bd,
          servicePeriodId: s.daypart,
          definitions: defs,
        );
        if (cardHrs == null) continue;
        final shiftCardFohInt =
            cardHrs.requiredFohHours.toDouble().round();
        final shiftCardBohInt =
            cardHrs.requiredBohHours.toDouble().round();
        // The Variance row integer is `s.fohHours` / `s.bohHours`.
        expect(s.fohHours, equals(shiftCardFohInt),
            reason: '${s.dayLabel}/${s.daypart}: Variance FOH int must '
                'equal the Shift card FOH int (same shared function)');
        expect(s.bohHours, equals(shiftCardBohInt),
            reason: '${s.dayLabel}/${s.daypart}: Variance BOH int must '
                'equal the Shift card BOH int (same shared function)');
      }
    });

    test(
        'closed-row invariance: a closed row\'s actual '
        'fohHours/bohHours/forecastCovers come from source truth and '
        'are unaffected by the locked-read swap', () async {
      final sourceRows = await SqliteShiftRecordRepository.instance
          .getShiftsForWeek(restaurantId, weekId);
      final sourceByKey = {
        for (final s in sourceRows) '${s.dayLabel}|${s.daypart}': s,
      };

      final shifts = await ShiftService.instance.getFullWeekShifts(weekId);
      final closed = shifts.where((s) => s.isClosed).toList();
      expect(closed, isNotEmpty);

      for (final s in closed) {
        final src = sourceByKey['${s.dayLabel}|${s.daypart}'];
        expect(src, isNotNull);
        // Closed actuals are byte-identical to the persisted source
        // shift_records row — the `isClosed ? s.x : allocation.x`
        // ternary in `_withPlanTargets` is preserved.
        expect(s.fohHours, equals(src!.fohHours),
            reason: '${s.dayLabel}/${s.daypart}: closed actual FOH hours '
                'must remain source truth');
        expect(s.bohHours, equals(src.bohHours),
            reason: '${s.dayLabel}/${s.daypart}: closed actual BOH hours '
                'must remain source truth');
        expect(s.covers, equals(src.covers),
            reason: '${s.dayLabel}/${s.daypart}: closed actual covers '
                'must remain source truth');
      }
    });
  });
}
