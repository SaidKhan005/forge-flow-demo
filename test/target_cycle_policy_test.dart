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

  group('E — auto-refresh boundary', () {
    test('does not need refresh on effective end date', () {
      final cycle = _makeCycle();
      expect(
          TargetCyclePolicy.needsAutoRefresh(cycle, '2026-04-01'), isFalse);
    });

    test('needs refresh one day after effective end', () {
      final cycle = _makeCycle();
      expect(
          TargetCyclePolicy.needsAutoRefresh(cycle, '2026-04-02'), isTrue);
    });

    test('needs refresh well past effective end', () {
      final cycle = _makeCycle();
      expect(
          TargetCyclePolicy.needsAutoRefresh(cycle, '2026-05-15'), isTrue);
    });

    test('does not need refresh before cycle starts', () {
      final cycle = _makeCycle();
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
}
