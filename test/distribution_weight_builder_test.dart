// Phase 7.55e.1 — DistributionWeightBuilder tests.
//
// Validates that day-of-week and day×daypart distribution weights are
// computed correctly from closed ShiftRecords, with explicit unavailability
// when history is insufficient.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/schedule_distribution_weights.dart';
import 'package:forge_and_flow/domain/services/distribution_weight_builder.dart';
import 'package:forge_and_flow/models/shift_record.dart';

/// Minimal ShiftRecord factory for testing — only fields relevant to
/// distribution weight computation are varied.
ShiftRecord _shift({
  required String weekId,
  required String dayLabel,
  required String daypart,
  int covers = 100,
  String status = 'closed',
}) =>
    ShiftRecord(
      weekId: weekId,
      dayLabel: dayLabel,
      daypart: daypart,
      status: status,
      covers: covers,
      forecastCovers: covers,
      fohHours: 20,
      bohHours: 20,
      ppa: 40.0,
      cplh: 4.5,
      splh: 180.0,
      primaryLever: 'none',
    );

/// Generate [weekCount] weeks of closed shifts across all 7 days with
/// [dayparts] per day. Each shift gets [coversPerShift] covers.
/// weekIds are '2026-W01', '2026-W02', etc.
List<ShiftRecord> _generateHistory({
  int weekCount = 3,
  List<String> dayparts = const ['lunch', 'dinner'],
  int coversPerShift = 100,
  Map<String, int>? coverOverrides, // 'dayLabel|daypart' -> covers
}) {
  final shifts = <ShiftRecord>[];
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  for (var w = 1; w <= weekCount; w++) {
    final weekId = '2026-W${w.toString().padLeft(2, '0')}';
    for (final day in days) {
      for (final dp in dayparts) {
        final key = '$day|$dp';
        shifts.add(_shift(
          weekId: weekId,
          dayLabel: day,
          daypart: dp,
          covers: coverOverrides?[key] ?? coversPerShift,
        ));
      }
    }
  }
  return shifts;
}

void main() {
  // ── A. Availability threshold ─────────────────────────────────────────────

  group('A — availability threshold', () {
    test('unavailable when fewer than 14 distinct closed business days', () {
      // 1 week × 7 days = 7 distinct business days — below 14
      final shifts = _generateHistory(weekCount: 1);
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);

      expect(w.isAvailable, isFalse);
      expect(w.dayWeights, isEmpty);
      expect(w.daypartWeightsByDay, isEmpty);
      // Counts still preserved for diagnostics
      expect(w.closedShiftCount, 14); // 7 days × 2 dayparts
      expect(w.closedBusinessDayCount, 7);
      expect(w.totalCovers, greaterThan(0));
    });

    test('available when exactly 14 distinct closed business days', () {
      // 2 weeks × 7 days = 14 distinct business days
      final shifts = _generateHistory(weekCount: 2);
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);

      expect(w.isAvailable, isTrue);
      expect(w.closedBusinessDayCount, 14);
      expect(w.dayWeights, isNotEmpty);
    });

    test('custom threshold respected', () {
      final shifts = _generateHistory(weekCount: 1); // 7 business days
      final w = DistributionWeightBuilder.fromClosedShifts(
        shifts,
        minClosedBusinessDays: 5,
      );
      expect(w.isAvailable, isTrue);
    });
  });

  // ── B. Filtering ──────────────────────────────────────────────────────────

  group('B — filtering', () {
    test('ignores non-closed records; counts only closed shifts', () {
      final closed = _generateHistory(weekCount: 3); // 21 business days
      final projected = [
        _shift(
            weekId: '2026-W04', dayLabel: 'Mon', daypart: 'lunch',
            status: 'projected', covers: 999),
        _shift(
            weekId: '2026-W04', dayLabel: 'Mon', daypart: 'dinner',
            status: 'open', covers: 888),
      ];
      final w = DistributionWeightBuilder.fromClosedShifts(
          [...closed, ...projected]);

      expect(w.closedShiftCount, closed.length);
      expect(w.totalCovers, isNot(contains(999)));
      // Mon weight should be 3 weeks × (lunch 100 + dinner 100) = 600
      expect(w.dayWeights['Mon'], 600);
    });

    test('zero and negative cover shifts excluded from weights but counted', () {
      final base = _generateHistory(weekCount: 3);
      // Add zero-cover and negative-cover closed shifts
      final extras = [
        _shift(
            weekId: '2026-W04', dayLabel: 'Mon', daypart: 'lunch',
            covers: 0),
        _shift(
            weekId: '2026-W04', dayLabel: 'Tue', daypart: 'dinner',
            covers: -5),
      ];
      final all = [...base, ...extras];
      final w = DistributionWeightBuilder.fromClosedShifts(all);

      // Extras are closed, so they add to closedShiftCount
      expect(w.closedShiftCount, base.length + 2);
      // But their covers don't appear in weights
      expect(w.totalCovers, equals(base.length * 100));
      // W04 Mon and W04 Tue are new business days
      expect(w.closedBusinessDayCount, 23); // 21 + 2
    });
  });

  // ── C. Day weights ────────────────────────────────────────────────────────

  group('C — day weights', () {
    test('day weights sum positive closed covers by dayLabel', () {
      final shifts = _generateHistory(
        weekCount: 3,
        coverOverrides: {
          'Fri|lunch': 150,
          'Fri|dinner': 200,
          'Mon|lunch': 80,
          'Mon|dinner': 90,
        },
      );
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);

      // Fri: 3 weeks × (150 + 200) = 1050
      expect(w.dayWeights['Fri'], 1050);
      // Mon: 3 weeks × (80 + 90) = 510
      expect(w.dayWeights['Mon'], 510);
      // Tue: 3 weeks × (100 + 100) = 600 (no override)
      expect(w.dayWeights['Tue'], 600);
    });

    test('orderedDayWeights returns canonical Mon-Sun order', () {
      final shifts = _generateHistory(weekCount: 3);
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);
      final ordered = w.orderedDayWeights;

      expect(ordered.length, 7);
      expect(ordered.map((e) => e.$1).toList(),
          ScheduleDistributionWeights.canonicalDayOrder);
    });

    test('orderedDayWeights returns 0 for missing days', () {
      // Only Mon and Tue shifts — but need 14 business days
      final shifts = <ShiftRecord>[];
      for (var w = 1; w <= 8; w++) {
        final weekId = '2026-W${w.toString().padLeft(2, '0')}';
        shifts.add(_shift(weekId: weekId, dayLabel: 'Mon', daypart: 'lunch'));
        shifts.add(_shift(weekId: weekId, dayLabel: 'Tue', daypart: 'lunch'));
      }
      // 16 business days, threshold met
      final result = DistributionWeightBuilder.fromClosedShifts(shifts);

      expect(result.isAvailable, isTrue);
      final ordered = result.orderedDayWeights;
      expect(ordered.firstWhere((e) => e.$1 == 'Mon').$2, 800);
      expect(ordered.firstWhere((e) => e.$1 == 'Wed').$2, 0);
      expect(ordered.firstWhere((e) => e.$1 == 'Sun').$2, 0);
    });
  });

  // ── D. Daypart weights ────────────────────────────────────────────────────

  group('D — daypart weights', () {
    test('Saturday dinner differs from Tuesday dinner', () {
      final shifts = _generateHistory(
        weekCount: 3,
        coverOverrides: {
          'Sat|dinner': 300,
          'Tue|dinner': 120,
        },
      );
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);

      final satDinner = w.daypartWeightsFor('Sat')['dinner'];
      final tueDinner = w.daypartWeightsFor('Tue')['dinner'];
      expect(satDinner, 900); // 3 × 300
      expect(tueDinner, 360); // 3 × 120
      expect(satDinner, isNot(equals(tueDinner)));
    });

    test('daypartWeightsFor returns empty map for unknown day', () {
      final shifts = _generateHistory(weekCount: 3);
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);
      expect(w.daypartWeightsFor('Xmas'), isEmpty);
    });

    test('preserves daypart ids as-is from ShiftRecord (lunch, dinner, late_night)', () {
      final shifts = _generateHistory(
        weekCount: 3,
        dayparts: ['lunch', 'dinner', 'late_night'],
      );
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);

      for (final day in ScheduleDistributionWeights.canonicalDayOrder) {
        final parts = w.daypartWeightsFor(day);
        expect(parts.keys, containsAll(['lunch', 'dinner', 'late_night']));
      }
    });
  });

  // ── E. Immutability ───────────────────────────────────────────────────────

  group('E — immutability', () {
    test('dayWeights, daypartWeightsByDay, and inner maps are unmodifiable', () {
      final shifts = _generateHistory(weekCount: 3);
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);

      expect(() => w.dayWeights['Mon'] = 0, throwsUnsupportedError);
      expect(() => w.daypartWeightsByDay['Mon'] = {}, throwsUnsupportedError);
      expect(
          () => w.daypartWeightsFor('Mon')['lunch'] = 0, throwsUnsupportedError);
    });
  });

  // ── F. Diagnostic counts ──────────────────────────────────────────────────

  group('F — diagnostic counts preserved', () {
    test('closedShiftCount and closedBusinessDayCount correct for available result', () {
      final shifts = _generateHistory(weekCount: 3); // 42 shifts, 21 days
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);

      expect(w.closedShiftCount, 42);
      expect(w.closedBusinessDayCount, 21);
      expect(w.totalCovers, 4200); // 42 × 100
      expect(w.isAvailable, isTrue);
    });

    test('unavailable result still has accurate counts', () {
      final shifts = _generateHistory(weekCount: 1); // 14 shifts, 7 days
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);

      expect(w.isAvailable, isFalse);
      expect(w.closedShiftCount, 14);
      expect(w.closedBusinessDayCount, 7);
      expect(w.totalCovers, 1400);
    });
  });

  // ── G. Business-day counting ──────────────────────────────────────────────

  group('G — business-day counting by weekId|dayLabel', () {
    test('multiple dayparts on same day count as one business day', () {
      final shifts = <ShiftRecord>[];
      for (var w = 1; w <= 7; w++) {
        final weekId = '2026-W${w.toString().padLeft(2, '0')}';
        for (final day in ['Mon', 'Tue']) {
          // 3 dayparts per day
          shifts.add(_shift(weekId: weekId, dayLabel: day, daypart: 'lunch'));
          shifts.add(_shift(weekId: weekId, dayLabel: day, daypart: 'dinner'));
          shifts.add(
              _shift(weekId: weekId, dayLabel: day, daypart: 'late_night'));
        }
      }
      final w = DistributionWeightBuilder.fromClosedShifts(shifts);

      // 7 weeks × 2 days = 14 business days, but 42 shifts
      expect(w.closedBusinessDayCount, 14);
      expect(w.closedShiftCount, 42);
      expect(w.isAvailable, isTrue);
    });
  });

  // ── H. Independence from BaselineData ─────────────────────────────────────

  group('H — independence from BaselineData', () {
    test('weights are deterministic from input records only', () {
      // Build the same set of shifts twice and verify identical results.
      // This proves weights derive from ShiftRecord data, not ambient state.
      final shifts1 = _generateHistory(weekCount: 3, coversPerShift: 100);
      final shifts2 = _generateHistory(weekCount: 3, coversPerShift: 100);

      final w1 = DistributionWeightBuilder.fromClosedShifts(shifts1);
      final w2 = DistributionWeightBuilder.fromClosedShifts(shifts2);

      expect(w1.dayWeights, equals(w2.dayWeights));
      expect(w1.totalCovers, equals(w2.totalCovers));
      for (final day in ScheduleDistributionWeights.canonicalDayOrder) {
        expect(w1.daypartWeightsFor(day), equals(w2.daypartWeightsFor(day)));
      }
    });
  });
}
