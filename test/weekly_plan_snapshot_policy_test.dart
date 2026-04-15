// Phase 7.55l.6a — WeeklyPlanSnapshotPolicy pure contract tests.
//
// Covers:
// A. Default Monday-start week span derivation
// B. Custom week-start derivation (Sunday-start)
// C. Deterministic week identity from week span
// D. Snapshot active-window detection for a business date
// E. Missing snapshot is eligible for generation
// F. Existing snapshot for the active week blocks duplicate regeneration
// G. Current-week snapshot remains valid despite midweek cycle refresh
// H. Model toMap/fromMap round-trip
// I. Week-key invariant (7.55l.6a1)

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/schedule_forecast_demand.dart';
import 'package:forge_and_flow/domain/models/weekly_plan_snapshot.dart';
import 'package:forge_and_flow/domain/services/weekly_plan_snapshot_policy.dart';

// ── Test helper ──────────────────────────────────────────────────────────────

WeeklyPlanSnapshot _makeSnapshot({
  String weekStartDate = '2026-04-06',
  String weekEndDate = '2026-04-12',
  String targetCycleId = 'cycle_001',
  List<WeeklyPlanSnapshotDay> dayRows = const [],
}) =>
    WeeklyPlanSnapshot(
      snapshotId: 'snap_test_001',
      restaurantId: 'demo_restaurant_001',
      weekStartDate: weekStartDate,
      weekEndDate: weekEndDate,
      targetCycleId: targetCycleId,
      forecastCovers: 500,
      forecastSales: 21000.0,
      requiredFohHours: 111,
      requiredBohHours: 117,
      theoreticalFohLaborDollars: 1942.50,
      theoreticalBohLaborDollars: 2632.50,
      coversSource: ForecastDemandSource.appDerivedFromHistoricalAverage,
      salesSource: ForecastDemandSource.appDerivedFromCoversAndPpa,
      generatedAt: '2026-04-06T00:00:00Z',
      lockedAt: '2026-04-06T00:00:00Z',
      dayRows: dayRows,
    );

void main() {
  // ── A: Default Monday-start week span derivation ───────────────────────────

  group('A — default Monday-start week span', () {
    test('Monday returns itself as week start', () {
      // 2026-04-06 is a Monday
      expect(
        WeeklyPlanSnapshotPolicy.weekStartForDate('2026-04-06'),
        '2026-04-06',
      );
      expect(
        WeeklyPlanSnapshotPolicy.weekEndForDate('2026-04-06'),
        '2026-04-12',
      );
    });

    test('Wednesday returns preceding Monday as week start', () {
      // 2026-04-08 is a Wednesday
      expect(
        WeeklyPlanSnapshotPolicy.weekStartForDate('2026-04-08'),
        '2026-04-06',
      );
      expect(
        WeeklyPlanSnapshotPolicy.weekEndForDate('2026-04-08'),
        '2026-04-12',
      );
    });

    test('Sunday returns preceding Monday as week start', () {
      // 2026-04-12 is a Sunday
      expect(
        WeeklyPlanSnapshotPolicy.weekStartForDate('2026-04-12'),
        '2026-04-06',
      );
      expect(
        WeeklyPlanSnapshotPolicy.weekEndForDate('2026-04-12'),
        '2026-04-12',
      );
    });

    test('week span is always 7 days', () {
      // 2026-04-09 is a Thursday
      final start = WeeklyPlanSnapshotPolicy.weekStartForDate('2026-04-09');
      final end = WeeklyPlanSnapshotPolicy.weekEndForDate('2026-04-09');
      expect(start, '2026-04-06');
      expect(end, '2026-04-12');
    });
  });

  // ── B: Custom week-start derivation (Sunday-start) ─────────────────────────

  group('B — custom Sunday-start week span', () {
    test('Sunday returns itself as week start', () {
      // 2026-04-05 is a Sunday
      expect(
        WeeklyPlanSnapshotPolicy.weekStartForDate(
          '2026-04-05',
          weekStartDay: DateTime.sunday,
        ),
        '2026-04-05',
      );
      expect(
        WeeklyPlanSnapshotPolicy.weekEndForDate(
          '2026-04-05',
          weekStartDay: DateTime.sunday,
        ),
        '2026-04-11',
      );
    });

    test('Wednesday in Sunday-start week returns preceding Sunday', () {
      // 2026-04-08 is a Wednesday
      expect(
        WeeklyPlanSnapshotPolicy.weekStartForDate(
          '2026-04-08',
          weekStartDay: DateTime.sunday,
        ),
        '2026-04-05',
      );
    });

    test('Saturday in Sunday-start week returns preceding Sunday', () {
      // 2026-04-11 is a Saturday — last day of a Sun-start week
      expect(
        WeeklyPlanSnapshotPolicy.weekStartForDate(
          '2026-04-11',
          weekStartDay: DateTime.sunday,
        ),
        '2026-04-05',
      );
      expect(
        WeeklyPlanSnapshotPolicy.weekEndForDate(
          '2026-04-11',
          weekStartDay: DateTime.sunday,
        ),
        '2026-04-11',
      );
    });
  });

  // ── C: Deterministic week identity from week span ──────────────────────────

  group('C — deterministic week key', () {
    test('week key from span is deterministic', () {
      expect(
        WeeklyPlanSnapshotPolicy.weekKeyFromSpan('2026-04-06', '2026-04-12'),
        '2026-04-06_2026-04-12',
      );
    });

    test('weekKeyForDate is consistent with weekStart/weekEnd', () {
      const date = '2026-04-09';
      final start = WeeklyPlanSnapshotPolicy.weekStartForDate(date);
      final end = WeeklyPlanSnapshotPolicy.weekEndForDate(date);
      expect(
        WeeklyPlanSnapshotPolicy.weekKeyForDate(date),
        WeeklyPlanSnapshotPolicy.weekKeyFromSpan(start, end),
      );
    });

    test('different dates in same week produce same key', () {
      expect(
        WeeklyPlanSnapshotPolicy.weekKeyForDate('2026-04-06'),
        WeeklyPlanSnapshotPolicy.weekKeyForDate('2026-04-10'),
      );
    });

    test('dates in different weeks produce different keys', () {
      // 2026-04-05 (Sun) and 2026-04-06 (Mon) are in different Mon-start weeks
      expect(
        WeeklyPlanSnapshotPolicy.weekKeyForDate('2026-04-05'),
        isNot(WeeklyPlanSnapshotPolicy.weekKeyForDate('2026-04-06')),
      );
    });
  });

  // ── D: Snapshot active-window detection ─────────────────────────────────────

  group('D — snapshot active-window detection', () {
    test('date on week start is active', () {
      final snapshot = _makeSnapshot();
      expect(
        WeeklyPlanSnapshotPolicy.isActiveForDate(snapshot, '2026-04-06'),
        isTrue,
      );
    });

    test('midweek date is active', () {
      final snapshot = _makeSnapshot();
      expect(
        WeeklyPlanSnapshotPolicy.isActiveForDate(snapshot, '2026-04-09'),
        isTrue,
      );
    });

    test('date on week end is active (inclusive)', () {
      final snapshot = _makeSnapshot();
      expect(
        WeeklyPlanSnapshotPolicy.isActiveForDate(snapshot, '2026-04-12'),
        isTrue,
      );
    });

    test('date before week start is not active', () {
      final snapshot = _makeSnapshot();
      expect(
        WeeklyPlanSnapshotPolicy.isActiveForDate(snapshot, '2026-04-05'),
        isFalse,
      );
    });

    test('date after week end is not active', () {
      final snapshot = _makeSnapshot();
      expect(
        WeeklyPlanSnapshotPolicy.isActiveForDate(snapshot, '2026-04-13'),
        isFalse,
      );
    });
  });

  // ── E: Missing snapshot is eligible for generation ─────────────────────────

  group('E — missing snapshot eligible for generation', () {
    test('null snapshot means generation is needed', () {
      expect(
        WeeklyPlanSnapshotPolicy.shouldGenerate(
          businessDate: '2026-04-08',
          existingSnapshot: null,
        ),
        isTrue,
      );
    });
  });

  // ── F: Existing snapshot blocks duplicate regeneration ─────────────────────

  group('F — existing snapshot blocks duplicate regeneration', () {
    test('existing snapshot for same week blocks generation', () {
      final snapshot = _makeSnapshot(); // week 2026-04-06 to 2026-04-12
      expect(
        WeeklyPlanSnapshotPolicy.shouldGenerate(
          businessDate: '2026-04-08', // same week
          existingSnapshot: snapshot,
        ),
        isFalse,
      );
    });

    test('existing snapshot for different week does not block', () {
      final snapshot = _makeSnapshot(); // week 2026-04-06 to 2026-04-12
      expect(
        WeeklyPlanSnapshotPolicy.shouldGenerate(
          businessDate: '2026-04-13', // next week (Monday)
          existingSnapshot: snapshot,
        ),
        isTrue,
      );
    });
  });

  // ── G: Midweek cycle refresh does not invalidate snapshot ──────────────────

  group('G — midweek cycle refresh stability', () {
    test('snapshot remains valid for business date within its week', () {
      final snapshot = _makeSnapshot(targetCycleId: 'old_cycle');
      expect(
        WeeklyPlanSnapshotPolicy.snapshotRemainsValidDespiteCycleRefresh(
          snapshot: snapshot,
          businessDate: '2026-04-09',
        ),
        isTrue,
      );
    });

    test('snapshot is not valid for business date outside its week', () {
      final snapshot = _makeSnapshot(targetCycleId: 'old_cycle');
      expect(
        WeeklyPlanSnapshotPolicy.snapshotRemainsValidDespiteCycleRefresh(
          snapshot: snapshot,
          businessDate: '2026-04-13',
        ),
        isFalse,
      );
    });
  });

  // ── H: Model toMap/fromMap round-trip ──────────────────────────────────────

  group('H — serialization round-trip', () {
    test('toMap/fromMap preserves all weekly-level fields', () {
      final snapshot = _makeSnapshot();
      final map = snapshot.toMap();
      final restored = WeeklyPlanSnapshot.fromMap(map);

      expect(restored.snapshotId, snapshot.snapshotId);
      expect(restored.restaurantId, snapshot.restaurantId);
      expect(restored.weekKey, snapshot.weekKey);
      expect(restored.weekStartDate, snapshot.weekStartDate);
      expect(restored.weekEndDate, snapshot.weekEndDate);
      expect(restored.targetCycleId, snapshot.targetCycleId);
      expect(restored.forecastCovers, snapshot.forecastCovers);
      expect(restored.forecastSales, snapshot.forecastSales);
      expect(restored.requiredFohHours, snapshot.requiredFohHours);
      expect(restored.requiredBohHours, snapshot.requiredBohHours);
      expect(restored.theoreticalFohLaborDollars,
          snapshot.theoreticalFohLaborDollars);
      expect(restored.theoreticalBohLaborDollars,
          snapshot.theoreticalBohLaborDollars);
      expect(restored.coversSource, snapshot.coversSource);
      expect(restored.salesSource, snapshot.salesSource);
      expect(restored.generatedAt, snapshot.generatedAt);
      expect(restored.lockedAt, snapshot.lockedAt);
    });

    test('toMap/fromMap preserves day rows', () {
      final snapshot = _makeSnapshot(
        dayRows: [
          const WeeklyPlanSnapshotDay(
            day: 'Monday',
            businessDate: '2026-04-06',
            forecastCovers: 72,
            forecastSales: 3024.0,
            requiredFohHours: 16,
            requiredBohHours: 17,
          ),
          const WeeklyPlanSnapshotDay(
            day: 'Tuesday',
            businessDate: '2026-04-07',
            forecastCovers: 65,
            forecastSales: 2730.0,
            requiredFohHours: 14,
            requiredBohHours: 15,
          ),
        ],
      );
      final map = snapshot.toMap();
      final restored = WeeklyPlanSnapshot.fromMap(map);

      expect(restored.dayRows.length, 2);
      expect(restored.dayRows[0].day, 'Monday');
      expect(restored.dayRows[0].businessDate, '2026-04-06');
      expect(restored.dayRows[0].forecastCovers, 72);
      expect(restored.dayRows[0].forecastSales, 3024.0);
      expect(restored.dayRows[1].day, 'Tuesday');
      expect(restored.dayRows[1].businessDate, '2026-04-07');
    });

    test('derived getters compute correctly', () {
      final snapshot = _makeSnapshot();
      expect(
        snapshot.theoreticalTotalLaborDollars,
        snapshot.theoreticalFohLaborDollars +
            snapshot.theoreticalBohLaborDollars,
      );
      expect(
        snapshot.totalRequiredHours,
        snapshot.requiredFohHours + snapshot.requiredBohHours,
      );
    });
  });

  // ── I: Week-key invariant (7.55l.6a1) ─────────────────────────────────────

  group('I — week-key invariant', () {
    test('weekKey is derived from weekStartDate and weekEndDate', () {
      final snapshot = _makeSnapshot();
      expect(snapshot.weekKey, '${snapshot.weekStartDate}_${snapshot.weekEndDate}');
    });

    test('changing weekStartDate changes weekKey', () {
      final a = _makeSnapshot(weekStartDate: '2026-04-06', weekEndDate: '2026-04-12');
      final b = _makeSnapshot(weekStartDate: '2026-04-13', weekEndDate: '2026-04-19');
      expect(a.weekKey, isNot(b.weekKey));
    });

    test('fromMap rejects inconsistent week_key', () {
      final validMap = _makeSnapshot().toMap();
      validMap['week_key'] = 'bad_key';
      expect(
        () => WeeklyPlanSnapshot.fromMap(validMap),
        throwsArgumentError,
      );
    });

    test('fromMap accepts consistent week_key', () {
      final snapshot = _makeSnapshot();
      final map = snapshot.toMap();
      final restored = WeeklyPlanSnapshot.fromMap(map);
      expect(restored.weekKey, snapshot.weekKey);
    });

    test('fromMap accepts missing week_key (derives from span)', () {
      final map = _makeSnapshot().toMap();
      map.remove('week_key');
      final restored = WeeklyPlanSnapshot.fromMap(map);
      expect(restored.weekKey, '2026-04-06_2026-04-12');
    });

    test('toMap emits derived weekKey', () {
      final snapshot = _makeSnapshot();
      final map = snapshot.toMap();
      expect(map['week_key'], snapshot.weekKey);
    });
  });
}
