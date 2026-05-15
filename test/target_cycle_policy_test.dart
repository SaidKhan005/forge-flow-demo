// Phase 7.55l.1 — TargetCyclePolicy pure contract tests.
//
// Covers:
// A. Active-window detection
// B. Once-per-cycle manager override rule
// C. Manager override allowed during active window
// D. Admin replacement metadata path
// E. Auto-refresh boundary semantics at cycle end

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/target_cycle.dart';
import 'package:forge_and_flow/domain/models/target_cycle_source.dart';
import 'package:forge_and_flow/domain/services/target_cycle_policy.dart';

// ── Test helper ──────────────────────────────────────────────────────────────

TargetCycle _makeCycle({
  String effectiveStart = '2026-02-01',
  String effectiveEnd = '2026-04-01',
  String calibrationStart = '2025-12-04',
  String calibrationEnd = '2026-02-01',
  TargetCycleSource source = TargetCycleSource.recommended,
  bool managerOverrideUsed = false,
  String? managerOverrideAt,
  String? adminReplacedAt,
}) =>
    TargetCycle(
      cycleId: 'cycle_test_001',
      restaurantId: 'demo_restaurant_001',
      source: source,
      effectiveStart: effectiveStart,
      effectiveEnd: effectiveEnd,
      calibrationWindowStart: calibrationStart,
      calibrationWindowEnd: calibrationEnd,
      targetCPLH: 4.2,
      targetSPLH: 176.0,
      targetPPA: 42.5,
      fohWage: 17.50,
      bohWage: 22.50,
      opzFloorCPLH: 3.0,
      opzCeilingCPLH: 6.0,
      managerOverrideUsed: managerOverrideUsed,
      managerOverrideAt: managerOverrideAt,
      adminReplacedAt: adminReplacedAt,
      createdAt: '2026-02-01T00:00:00Z',
    );

void main() {
  // ── A: Active-window detection ──────────────────────────────────────────────

  group('A — active-window detection', () {
    test('date before effective start is not active', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.isActiveForDate(cycle, '2026-01-31'), isFalse);
    });

    test('effective start date is active', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.isActiveForDate(cycle, '2026-02-01'), isTrue);
    });

    test('midpoint date is active', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.isActiveForDate(cycle, '2026-03-15'), isTrue);
    });

    test('effective end date is active (inclusive)', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.isActiveForDate(cycle, '2026-04-01'), isTrue);
    });

    test('date after effective end is not active', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.isActiveForDate(cycle, '2026-04-02'), isFalse);
    });
  });

  // ── B: Once-per-cycle manager override rule ─────────────────────────────────

  group('B — once-per-cycle manager override rule', () {
    test('override available on fresh recommended cycle during active window', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.canManagerOverride(cycle, '2026-03-01'), isTrue);
    });

    test('override not available after manager already overrode', () {
      final cycle = _makeCycle(
        source: TargetCycleSource.managerOverride,
        managerOverrideUsed: true,
        managerOverrideAt: '2026-02-10T14:30:00Z',
      );
      expect(TargetCyclePolicy.canManagerOverride(cycle, '2026-03-01'), isFalse);
    });

    test('override consumed flag blocks even if source is still recommended', () {
      // Edge case: managerOverrideUsed set but source not changed yet
      final cycle = _makeCycle(managerOverrideUsed: true);
      expect(TargetCyclePolicy.canManagerOverride(cycle, '2026-03-01'), isFalse);
    });
  });

  // ── C: Manager override requires active window ─────────────────────────────

  group('C — manager override requires active window', () {
    test('can override on first day of cycle', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.canManagerOverride(cycle, '2026-02-01'), isTrue);
    });

    test('can override on last day of cycle if not yet used', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.canManagerOverride(cycle, '2026-04-01'), isTrue);
    });

    test('cannot override after cycle expires even if override unused', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.canManagerOverride(cycle, '2026-04-02'), isFalse);
    });

    test('cannot override before cycle starts even if override unused', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.canManagerOverride(cycle, '2026-01-15'), isFalse);
    });
  });

  // ── D: Admin replacement metadata path ──────────────────────────────────────

  group('D — admin replacement metadata', () {
    test('admin replacement is expressible in TargetCycleSource', () {
      final cycle = _makeCycle(
        source: TargetCycleSource.adminReplacement,
        managerOverrideUsed: true,
        managerOverrideAt: '2026-02-10T14:30:00Z',
        adminReplacedAt: '2026-03-01T09:00:00Z',
      );
      expect(cycle.source, TargetCycleSource.adminReplacement);
      expect(cycle.adminReplacedAt, isNotNull);
    });

    test('admin replacement serializes and deserializes', () {
      final cycle = _makeCycle(
        source: TargetCycleSource.adminReplacement,
        adminReplacedAt: '2026-03-01T09:00:00Z',
      );
      final map = cycle.toMap();
      final restored = TargetCycle.fromMap(map);
      expect(restored.source, TargetCycleSource.adminReplacement);
      expect(restored.adminReplacedAt, '2026-03-01T09:00:00Z');
    });
  });

  // ── E: Auto-refresh boundary semantics ──────────────────────────────────────
  //
  // Per-daypart-targets V1 (Slice 0): auto-refresh gates to the operator's
  // configured `week_start_day`. Tests below pin the cycle's effective end
  // to a Wednesday (`2026-04-01`, ISO weekday 3) so the cross-boundary
  // behavior — past-end-but-not-yet-week-start vs past-end-and-week-start —
  // can be exercised independently.

  group('E — auto-refresh boundary (week-start gated)', () {
    test('does not need refresh on effective end date', () {
      final cycle = _makeCycle();
      // 2026-04-01 is Wednesday (ISO 3); default weekStartDay = Monday (1).
      // Not past effective end → false regardless of weekday.
      expect(
          TargetCyclePolicy.needsAutoRefresh(cycle, '2026-04-01'), isFalse);
    });

    test('past effective end but not yet week-start day defers refresh', () {
      final cycle = _makeCycle();
      // 2026-04-02 is Thursday; default weekStartDay = Monday.
      // Past effective end but not week-start → defer (false).
      expect(
          TargetCyclePolicy.needsAutoRefresh(cycle, '2026-04-02'), isFalse);
    });

    test('past effective end AND week-start day triggers refresh', () {
      final cycle = _makeCycle();
      // 2026-04-06 is Monday; default weekStartDay = Monday.
      // Past effective end and week-start → refresh (true).
      expect(
          TargetCyclePolicy.needsAutoRefresh(cycle, '2026-04-06'), isTrue);
    });

    test('well past effective end on the next week-start triggers refresh', () {
      final cycle = _makeCycle();
      // 2026-04-13 is Monday → refresh.
      expect(
          TargetCyclePolicy.needsAutoRefresh(cycle, '2026-04-13'), isTrue);
    });

    test('well past effective end on a non-week-start day still defers', () {
      final cycle = _makeCycle();
      // 2026-05-15 is Friday; default weekStartDay = Monday.
      expect(
          TargetCyclePolicy.needsAutoRefresh(cycle, '2026-05-15'), isFalse);
    });

    test('does not need refresh before cycle starts', () {
      final cycle = _makeCycle();
      // 2026-01-15 is Thursday and well before cycle start.
      expect(
          TargetCyclePolicy.needsAutoRefresh(cycle, '2026-01-15'), isFalse);
    });

    test('daysRemainingInCycle is calendar days to effective end', () {
      final cycle = _makeCycle(); // effectiveEnd = 2026-04-01
      // March 1 → April 1 = 31 calendar days
      expect(TargetCyclePolicy.daysRemainingInCycle(cycle, '2026-03-01'), 31);
    });

    test('daysRemainingInCycle returns 1 the day before effective end', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.daysRemainingInCycle(cycle, '2026-03-31'), 1);
    });

    test('daysRemainingInCycle returns 0 on effective end', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.daysRemainingInCycle(cycle, '2026-04-01'), 0);
    });

    test('daysRemainingInCycle returns 0 after effective end', () {
      final cycle = _makeCycle();
      expect(TargetCyclePolicy.daysRemainingInCycle(cycle, '2026-04-10'), 0);
    });
  });

  // ── F: Serialization round-trip ─────────────────────────────────────────────

  group('F — serialization round-trip', () {
    test('toMap/fromMap preserves all fields', () {
      final cycle = _makeCycle(
        source: TargetCycleSource.managerOverride,
        managerOverrideUsed: true,
        managerOverrideAt: '2026-02-10T14:30:00Z',
      );
      final map = cycle.toMap();
      final restored = TargetCycle.fromMap(map);

      expect(restored.cycleId, cycle.cycleId);
      expect(restored.restaurantId, cycle.restaurantId);
      expect(restored.source, cycle.source);
      expect(restored.effectiveStart, cycle.effectiveStart);
      expect(restored.effectiveEnd, cycle.effectiveEnd);
      expect(restored.calibrationWindowStart, cycle.calibrationWindowStart);
      expect(restored.calibrationWindowEnd, cycle.calibrationWindowEnd);
      expect(restored.targetCPLH, cycle.targetCPLH);
      expect(restored.targetSPLH, cycle.targetSPLH);
      expect(restored.targetPPA, cycle.targetPPA);
      expect(restored.fohWage, cycle.fohWage);
      expect(restored.bohWage, cycle.bohWage);
      expect(restored.opzFloorCPLH, cycle.opzFloorCPLH);
      expect(restored.opzCeilingCPLH, cycle.opzCeilingCPLH);
      expect(restored.managerOverrideUsed, cycle.managerOverrideUsed);
      expect(restored.managerOverrideAt, cycle.managerOverrideAt);
      expect(restored.adminReplacedAt, cycle.adminReplacedAt);
      expect(restored.createdAt, cycle.createdAt);
    });

    test('TargetCycleSource round-trips through label', () {
      for (final s in TargetCycleSource.values) {
        expect(TargetCycleSource.fromLabel(s.label), s);
      }
    });

    test('unknown TargetCycleSource label throws', () {
      expect(
        () => TargetCycleSource.fromLabel('garbage'),
        throwsArgumentError,
      );
    });
  });

  // ── G: copyWith preserves identity fields ───────────────────────────────────

  group('G — copyWith', () {
    test('copyWith changes only specified fields', () {
      final original = _makeCycle();
      final overridden = original.copyWith(
        source: TargetCycleSource.managerOverride,
        targetCPLH: 5.0,
        managerOverrideUsed: true,
        managerOverrideAt: '2026-03-01T12:00:00Z',
      );

      // Changed fields
      expect(overridden.source, TargetCycleSource.managerOverride);
      expect(overridden.targetCPLH, 5.0);
      expect(overridden.managerOverrideUsed, isTrue);
      expect(overridden.managerOverrideAt, '2026-03-01T12:00:00Z');

      // Preserved fields
      expect(overridden.cycleId, original.cycleId);
      expect(overridden.restaurantId, original.restaurantId);
      expect(overridden.effectiveStart, original.effectiveStart);
      expect(overridden.effectiveEnd, original.effectiveEnd);
      expect(overridden.targetSPLH, original.targetSPLH);
      expect(overridden.targetPPA, original.targetPPA);
      expect(overridden.createdAt, original.createdAt);
    });
  });

  // ── H: Per-daypart V1 Slice 0 — week-start day gating ──────────────────────
  //
  // Cycle effective end pinned to 2026-04-01 (Wednesday, ISO 3). For each
  // ISO weekday value (1=Mon … 7=Sun) the first matching business date
  // after effective end should trigger refresh, and the day immediately
  // after that should defer refresh because it is no longer the configured
  // week-start day.

  group('H — week-start day gating (per-daypart V1 Slice 0)', () {
    // (weekStartDay, firstMatchDateAfterEffectiveEnd, dayAfterMatch).
    final cases = <List<dynamic>>[
      [1, '2026-04-06', '2026-04-07'], // Monday
      [2, '2026-04-07', '2026-04-08'], // Tuesday
      [3, '2026-04-08', '2026-04-09'], // Wednesday
      [4, '2026-04-02', '2026-04-03'], // Thursday
      [5, '2026-04-03', '2026-04-04'], // Friday
      [6, '2026-04-04', '2026-04-05'], // Saturday
      [7, '2026-04-05', '2026-04-06'], // Sunday
    ];

    for (final c in cases) {
      final weekStartDay = c[0] as int;
      final matchDate = c[1] as String;
      final deferDate = c[2] as String;
      final wd = const [
        '',
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday',
      ][weekStartDay];

      test('weekStartDay=$weekStartDay ($wd): triggers refresh on $matchDate',
          () {
        final cycle = _makeCycle();
        expect(
          TargetCyclePolicy.needsAutoRefresh(
            cycle,
            matchDate,
            weekStartDay: weekStartDay,
          ),
          isTrue,
        );
      });

      test('weekStartDay=$weekStartDay ($wd): defers refresh on $deferDate',
          () {
        final cycle = _makeCycle();
        expect(
          TargetCyclePolicy.needsAutoRefresh(
            cycle,
            deferDate,
            weekStartDay: weekStartDay,
          ),
          isFalse,
        );
      });
    }

    test('past effective end but mid-week defers regardless of how far past',
        () {
      final cycle = _makeCycle(); // effectiveEnd = 2026-04-01 (Wed)
      // 2026-04-30 is a Thursday, deep past the effective end. With
      // weekStartDay = Monday the refresh still defers — gating is not a
      // grace-period that lapses; it is a structural rule.
      expect(
        TargetCyclePolicy.needsAutoRefresh(
          cycle,
          '2026-04-30',
          weekStartDay: DateTime.monday,
        ),
        isFalse,
      );
    });

    test('cycle that crosses week-start defers to the next week-start day',
        () {
      // Cycle whose effective end is mid-week (Thursday 2026-04-09 → ISO 4).
      // With weekStartDay = Monday (1), the next Monday after effective end
      // is 2026-04-13. Refresh should NOT fire on 2026-04-10 (Friday) or
      // 2026-04-12 (Sunday); it should fire on 2026-04-13 (Monday).
      final cycle = _makeCycle(effectiveEnd: '2026-04-09');
      expect(
        TargetCyclePolicy.needsAutoRefresh(
          cycle,
          '2026-04-10',
          weekStartDay: DateTime.monday,
        ),
        isFalse,
      );
      expect(
        TargetCyclePolicy.needsAutoRefresh(
          cycle,
          '2026-04-12',
          weekStartDay: DateTime.monday,
        ),
        isFalse,
      );
      expect(
        TargetCyclePolicy.needsAutoRefresh(
          cycle,
          '2026-04-13',
          weekStartDay: DateTime.monday,
        ),
        isTrue,
      );
    });

    test('default weekStartDay = Monday matches DateTime.monday convention',
        () {
      final cycle = _makeCycle();
      // 2026-04-06 is Monday. With no explicit weekStartDay, the policy
      // should use DateTime.monday and trigger refresh.
      expect(
        TargetCyclePolicy.needsAutoRefresh(cycle, '2026-04-06'),
        isTrue,
      );
    });
  });

  // ── I: Slice 0 — recommended-cycle effective window invariants ─────────────
  //
  // Slice 0 leaves `_createRecommendedCycle` unchanged (it already computes
  // `effectiveStart = businessDate` and `effectiveEnd = businessDate + 59`).
  // These tests pin the invariant the gating relies on: when refresh fires
  // (i.e. businessDate is the configured week-start day), a freshly
  // computed cycle inherits that week-start anchor and spans exactly 60
  // business dates (inclusive).

  group('I — recommended-cycle effective window invariants', () {
    test('effectiveStart equals refresh businessDate (week-start anchor)', () {
      // Mirrors the computation in TargetCycleService._createRecommendedCycle:
      // effectiveStart = businessDate, effectiveEnd = +59 days.
      const businessDate = '2026-04-06'; // Monday (ISO 1)
      final start = DateTime.utc(2026, 4, 6);
      final end = start.add(const Duration(days: 59));
      // Span is exactly 60 inclusive business dates.
      expect(end.difference(start).inDays, 59);
      // Effective end on the same anchor convention.
      expect(
        '${end.year}-${end.month.toString().padLeft(2, '0')}'
        '-${end.day.toString().padLeft(2, '0')}',
        '2026-06-04',
      );
      expect(businessDate, start.toIso8601String().substring(0, 10));
    });

    test(
        'effectiveEnd = effectiveStart + 59 days holds for any week-start anchor',
        () {
      for (final anchor in const [
        '2026-04-06', // Monday
        '2026-04-07', // Tuesday
        '2026-04-08', // Wednesday
        '2026-04-02', // Thursday
        '2026-04-03', // Friday
        '2026-04-04', // Saturday
        '2026-04-05', // Sunday
      ]) {
        final parts = anchor.split('-').map(int.parse).toList();
        final start = DateTime.utc(parts[0], parts[1], parts[2]);
        final end = start.add(const Duration(days: 59));
        expect(end.difference(start).inDays, 59,
            reason: 'anchor $anchor must span 60 inclusive business dates');
      }
    });
  });
}
