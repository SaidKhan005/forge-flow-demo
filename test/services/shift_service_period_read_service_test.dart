// Phase 10.5.2 — ShiftServicePeriodReadService tests.
//
// Verifies the per-service-period accumulator that consumes 10.5.1's
// `DaypartBucketer` and folds canonical POS lines + labor punches
// into per-period totals (covers, sales, FOH/BOH minutes, wage
// dollars, derived CPLH / SPLH / PPA / blended wage).
//
// Acceptance criteria covered:
//   * Accumulator arithmetic verified by golden-input unit tests.
//   * Punch-split rule honored (non_service slivers excluded from
//     CPLH/SPLH denominators).
//   * Correction replay works on source-id replacement.
//   * Missing-tz refusal propagates from the bucketing engine.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/daypart_bucketer.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/services/shift_service_period_read_service.dart';
import 'package:forge_and_flow/state/shift_service_period_notifier.dart';

const _location = BucketingLocationContext(
  iana: 'America/St_Johns',
  businessDayStartLocalTime: '04:00',
);

final _definitions = ServicePeriodDefinitionResolver.demoDefinitions;
const _service = ShiftServicePeriodReadService();

void main() {
  group('ShiftServicePeriodReadService.build', () {
    test('empty inputs return empty accumulators for every defined period',
        () {
      final result = _service.build(
        posLines: const [],
        laborPunches: const [],
        location: _location,
        definitions: _definitions,
      );

      expect(result.keys, containsAll(['lunch', 'dinner', 'late_night']));
      for (final entry in result.entries) {
        expect(entry.value.covers, 0);
        expect(entry.value.sales, 0);
        expect(entry.value.fohMinutes, 0);
        expect(entry.value.bohMinutes, 0);
        expect(entry.value.cplh, 0);
        expect(entry.value.splh, 0);
        expect(entry.value.ppa, 0);
        expect(entry.value.blendedWage, 0);
        expect(entry.value.hasAnyData, isFalse);
      }
    });

    test(
        'single Lunch POS line + matching FOH+BOH punches yield correct '
        'per-period accumulator (golden arithmetic)', () {
      // Mon 2026-05-04 — Lunch 11:00-15:00 weekdays.
      final posLine = CanonicalPosLine(
        sourceId: 'order_a',
        eventLocalTimestamp: DateTime(2026, 5, 4, 12, 30),
        covers: 100,
        sales: 4200.00,
      );
      // 4-hour FOH punch wholly inside Lunch (11:00-15:00). Wage $20/hr.
      // Expected: 240 minutes FOH, 240/60 * 20 = $80 wage dollars.
      final fohPunch = CanonicalLaborPunch(
        sourceId: 'punch_foh',
        clockedInLocal: DateTime(2026, 5, 4, 11, 0),
        clockedOutLocal: DateTime(2026, 5, 4, 15, 0),
        role: 'foh',
        hourlyWage: 20.0,
      );
      // 4-hour BOH punch wholly inside Lunch. Wage $25/hr.
      // Expected: 240 minutes BOH, 240/60 * 25 = $100 wage dollars.
      final bohPunch = CanonicalLaborPunch(
        sourceId: 'punch_boh',
        clockedInLocal: DateTime(2026, 5, 4, 11, 0),
        clockedOutLocal: DateTime(2026, 5, 4, 15, 0),
        role: 'boh',
        hourlyWage: 25.0,
      );

      final result = _service.build(
        posLines: [posLine],
        laborPunches: [fohPunch, bohPunch],
        location: _location,
        definitions: _definitions,
      );

      final lunch = result['lunch']!;
      expect(lunch.covers, 100);
      expect(lunch.sales, 4200.00);
      expect(lunch.fohMinutes, 240);
      expect(lunch.bohMinutes, 240);
      expect(lunch.fohWageDollars, closeTo(80.0, 1e-9));
      expect(lunch.bohWageDollars, closeTo(100.0, 1e-9));
      expect(lunch.totalHours, closeTo(8.0, 1e-9));
      expect(lunch.cplh, closeTo(100 / 8.0, 1e-9));
      expect(lunch.splh, closeTo(4200.00 / 8.0, 1e-9));
      expect(lunch.ppa, closeTo(42.00, 1e-9));
      // Blended wage: ($80 + $100) / 8 hrs = $22.50
      expect(lunch.blendedWage, closeTo(22.50, 1e-9));

      // Dinner / Late Night untouched.
      expect(result['dinner']!.hasAnyData, isFalse);
      expect(result['late_night']!.hasAnyData, isFalse);
    });

    test(
        'punch spanning Lunch and Dinner with non_service gap honors the '
        'Jim Taylor split rule (gap minutes excluded)', () {
      // Phase doc worked example: punch 14:30 → 19:00 on Monday.
      // Lunch ∩ punch = 14:30 → 15:00 = 30 min
      // Gap = 15:00 → 17:00 = 120 min (non_service — must be excluded)
      // Dinner ∩ punch = 17:00 → 19:00 = 120 min
      final fohPunch = CanonicalLaborPunch(
        sourceId: 'punch_split',
        clockedInLocal: DateTime(2026, 5, 4, 14, 30),
        clockedOutLocal: DateTime(2026, 5, 4, 19, 0),
        role: 'foh',
        hourlyWage: 20.0,
      );

      final result = _service.build(
        posLines: const [],
        laborPunches: [fohPunch],
        location: _location,
        definitions: _definitions,
      );

      final lunch = result['lunch']!;
      final dinner = result['dinner']!;

      // Lunch absorbs only the 30 min in-period segment.
      expect(lunch.fohMinutes, 30);
      expect(lunch.bohMinutes, 0);
      expect(lunch.fohWageDollars, closeTo(30 * 20 / 60, 1e-9));

      // Dinner absorbs only the 120 min in-period segment.
      expect(dinner.fohMinutes, 120);
      expect(dinner.bohMinutes, 0);
      expect(dinner.fohWageDollars, closeTo(120 * 20 / 60, 1e-9));

      // Critical: the 120 non-service gap minutes are NOT part of any
      // bucket. Total accumulated = 30 + 120 = 150 min, not 270.
      // CPLH/SPLH denominators should not include the gap.
      final lunchHours = lunch.fohMinutes / 60.0;
      expect(lunchHours, closeTo(0.5, 1e-9));
      // Without covers we just check the denominator is the in-period
      // span only.
      expect(lunch.totalMinutes, 30);
      expect(dinner.totalMinutes, 120);
    });

    test(
        'POS line classified as non_service (between Lunch and Dinner) is '
        'dropped from every accumulator', () {
      final posLine = CanonicalPosLine(
        sourceId: 'order_gap',
        eventLocalTimestamp: DateTime(2026, 5, 4, 16, 0),
        covers: 50,
        sales: 1000.00,
      );

      final result = _service.build(
        posLines: [posLine],
        laborPunches: const [],
        location: _location,
        definitions: _definitions,
      );

      // The 16:00 POS line falls into the post-Lunch / pre-Dinner gap
      // and must not bleed into any service-period bucket.
      for (final bucket in result.values) {
        expect(bucket.covers, 0);
        expect(bucket.sales, 0);
      }
    });

    test('Late Night cross-midnight punch lands fully in late_night', () {
      // Sat 23:30 → Sun 01:30 calendar. Both endpoints pre-cutoff
      // resolve to Saturday's business day; Late Night [23:00, 02:00]
      // applies on Fri/Sat. Single late_night segment, 120 minutes.
      final punch = CanonicalLaborPunch(
        sourceId: 'punch_ln',
        clockedInLocal: DateTime(2026, 5, 9, 23, 30),
        clockedOutLocal: DateTime(2026, 5, 10, 1, 30),
        role: 'foh',
        hourlyWage: 22.0,
      );

      final result = _service.build(
        posLines: const [],
        laborPunches: [punch],
        location: _location,
        definitions: _definitions,
      );

      final ln = result['late_night']!;
      expect(ln.fohMinutes, 120);
      expect(ln.bohMinutes, 0);
      expect(ln.fohWageDollars, closeTo(120 * 22 / 60, 1e-9));
    });

    test('missing IANA timezone propagates as MissingTimezoneError', () {
      // The bucketing engine asserts the IANA field as a config gate.
      // The accumulator only invokes the bucketer when there is at
      // least one fact to classify; the test passes a real input so
      // the assertion fires.
      const badLocation = BucketingLocationContext(
        iana: '',
        businessDayStartLocalTime: '04:00',
      );
      final posLine = CanonicalPosLine(
        sourceId: 'order_x',
        eventLocalTimestamp: DateTime(2026, 5, 4, 12, 30),
        covers: 1,
        sales: 10.00,
      );
      expect(
        () => _service.build(
          posLines: [posLine],
          laborPunches: const [],
          location: badLocation,
          definitions: _definitions,
        ),
        throwsA(isA<MissingTimezoneError>()),
      );
    });
  });

  group('ShiftServicePeriodReadService.applyPosLineCorrection', () {
    test(
        'subtract-then-add yields the same bucket as a fresh build with the '
        'replacement fact (idempotency by sourceId)', () {
      // Build with prior fact: 100 covers / $4200 at Lunch.
      final prior = CanonicalPosLine(
        sourceId: 'order_correctable',
        eventLocalTimestamp: DateTime(2026, 5, 4, 12, 30),
        covers: 100,
        sales: 4200.00,
      );
      final initial = _service.build(
        posLines: [prior],
        laborPunches: const [],
        location: _location,
        definitions: _definitions,
      );

      // Replacement: correction lifts covers to 110 / $4620.
      final replacement = CanonicalPosLine(
        sourceId: 'order_correctable',
        eventLocalTimestamp: DateTime(2026, 5, 4, 12, 30),
        covers: 110,
        sales: 4620.00,
      );

      final corrected = _service.applyPosLineCorrection(
        current: initial,
        prior: prior,
        replacement: replacement,
        location: _location,
        definitions: _definitions,
      );

      // Should match fresh build with only the replacement.
      final freshBuild = _service.build(
        posLines: [replacement],
        laborPunches: const [],
        location: _location,
        definitions: _definitions,
      );

      expect(corrected['lunch']!.covers, freshBuild['lunch']!.covers);
      expect(corrected['lunch']!.sales,
          closeTo(freshBuild['lunch']!.sales, 1e-9));
      expect(corrected['lunch']!.covers, 110);
      expect(corrected['lunch']!.sales, closeTo(4620.00, 1e-9));
    });

    test('replacement = null deletes the prior fact contribution', () {
      final prior = CanonicalPosLine(
        sourceId: 'order_to_delete',
        eventLocalTimestamp: DateTime(2026, 5, 4, 19, 0),
        covers: 80,
        sales: 3200.00,
      );
      final initial = _service.build(
        posLines: [prior],
        laborPunches: const [],
        location: _location,
        definitions: _definitions,
      );
      expect(initial['dinner']!.covers, 80);

      final corrected = _service.applyPosLineCorrection(
        current: initial,
        prior: prior,
        replacement: null,
        location: _location,
        definitions: _definitions,
      );

      expect(corrected['dinner']!.covers, 0);
      expect(corrected['dinner']!.sales, closeTo(0, 1e-9));
    });
  });

  group('ShiftServicePeriodReadService.applyLaborPunchCorrection', () {
    test(
        'subtract-then-add yields the same bucket as a fresh build with the '
        'replacement punch', () {
      // Original FOH punch: 11:00-15:00 = 240 min in Lunch, $20/hr.
      final prior = CanonicalLaborPunch(
        sourceId: 'punch_foh_correctable',
        clockedInLocal: DateTime(2026, 5, 4, 11, 0),
        clockedOutLocal: DateTime(2026, 5, 4, 15, 0),
        role: 'foh',
        hourlyWage: 20.0,
      );
      final initial = _service.build(
        posLines: const [],
        laborPunches: [prior],
        location: _location,
        definitions: _definitions,
      );
      expect(initial['lunch']!.fohMinutes, 240);

      // Manager edits the punch out to 14:30 (270 → 210 minutes).
      final replacement = CanonicalLaborPunch(
        sourceId: 'punch_foh_correctable',
        clockedInLocal: DateTime(2026, 5, 4, 11, 0),
        clockedOutLocal: DateTime(2026, 5, 4, 14, 30),
        role: 'foh',
        hourlyWage: 20.0,
      );

      final corrected = _service.applyLaborPunchCorrection(
        current: initial,
        prior: prior,
        replacement: replacement,
        location: _location,
        definitions: _definitions,
      );

      final freshBuild = _service.build(
        posLines: const [],
        laborPunches: [replacement],
        location: _location,
        definitions: _definitions,
      );

      expect(corrected['lunch']!.fohMinutes,
          freshBuild['lunch']!.fohMinutes);
      expect(corrected['lunch']!.fohMinutes, 210);
      expect(corrected['lunch']!.fohWageDollars,
          closeTo(freshBuild['lunch']!.fohWageDollars, 1e-9));
    });

    test('punch_delete (replacement null) zeros out the prior contribution',
        () {
      final prior = CanonicalLaborPunch(
        sourceId: 'punch_to_delete',
        clockedInLocal: DateTime(2026, 5, 4, 17, 0),
        clockedOutLocal: DateTime(2026, 5, 4, 21, 0),
        role: 'boh',
        hourlyWage: 22.0,
      );
      final initial = _service.build(
        posLines: const [],
        laborPunches: [prior],
        location: _location,
        definitions: _definitions,
      );
      expect(initial['dinner']!.bohMinutes, 240);

      final corrected = _service.applyLaborPunchCorrection(
        current: initial,
        prior: prior,
        replacement: null,
        location: _location,
        definitions: _definitions,
      );

      expect(corrected['dinner']!.bohMinutes, 0);
      expect(corrected['dinner']!.bohWageDollars, closeTo(0, 1e-9));
    });

    test(
        'POS check correction is exact for zero-cover / zero-sales lines '
        '(no sign-heuristic miscount)', () {
      // A legitimate zero-cover/zero-sales POS line (e.g., a void or a
      // fully comped check) must still register as exactly one check
      // on build, and decrement by exactly one on a delete correction.
      // The previous sign heuristic would have miscounted: prior
      // (covers: 0, sales: x) was passed as (covers: 0, sales: -x) on
      // subtraction, both `>= 0`, incrementing checks instead of
      // decrementing.
      final voidLine = CanonicalPosLine(
        sourceId: 'order_void',
        eventLocalTimestamp: DateTime(2026, 5, 4, 12, 30),
        covers: 0,
        sales: 0,
      );
      final initial = _service.build(
        posLines: [voidLine],
        laborPunches: const [],
        location: _location,
        definitions: _definitions,
      );
      expect(initial['lunch']!.checks, 1);

      final deleted = _service.applyPosLineCorrection(
        current: initial,
        prior: voidLine,
        replacement: null,
        location: _location,
        definitions: _definitions,
      );
      expect(deleted['lunch']!.checks, 0);

      // A non-zero-cover correction also matches a fresh build's check
      // count (replacement equivalence includes checks).
      final priorWithCovers = CanonicalPosLine(
        sourceId: 'order_q',
        eventLocalTimestamp: DateTime(2026, 5, 4, 12, 30),
        covers: 4,
        sales: 100,
      );
      final replacement = CanonicalPosLine(
        sourceId: 'order_q',
        eventLocalTimestamp: DateTime(2026, 5, 4, 12, 30),
        covers: 6,
        sales: 150,
      );
      final start = _service.build(
        posLines: [priorWithCovers],
        laborPunches: const [],
        location: _location,
        definitions: _definitions,
      );
      final corrected = _service.applyPosLineCorrection(
        current: start,
        prior: priorWithCovers,
        replacement: replacement,
        location: _location,
        definitions: _definitions,
      );
      final freshBuild = _service.build(
        posLines: [replacement],
        laborPunches: const [],
        location: _location,
        definitions: _definitions,
      );
      expect(corrected['lunch']!.checks, freshBuild['lunch']!.checks);
      expect(corrected['lunch']!.checks, 1);
    });

    test(
        'correction that moves a punch across the period boundary updates '
        'both old and new period buckets', () {
      // Original: punch 14:00-15:00, fully in Lunch, FOH $20/hr.
      final prior = CanonicalLaborPunch(
        sourceId: 'punch_movable',
        clockedInLocal: DateTime(2026, 5, 4, 14, 0),
        clockedOutLocal: DateTime(2026, 5, 4, 15, 0),
        role: 'foh',
        hourlyWage: 20.0,
      );
      final initial = _service.build(
        posLines: const [],
        laborPunches: [prior],
        location: _location,
        definitions: _definitions,
      );
      expect(initial['lunch']!.fohMinutes, 60);
      expect(initial['dinner']!.fohMinutes, 0);

      // Manager edits the punch to 18:00-19:00 (Dinner).
      final replacement = CanonicalLaborPunch(
        sourceId: 'punch_movable',
        clockedInLocal: DateTime(2026, 5, 4, 18, 0),
        clockedOutLocal: DateTime(2026, 5, 4, 19, 0),
        role: 'foh',
        hourlyWage: 20.0,
      );

      final corrected = _service.applyLaborPunchCorrection(
        current: initial,
        prior: prior,
        replacement: replacement,
        location: _location,
        definitions: _definitions,
      );

      expect(corrected['lunch']!.fohMinutes, 0);
      expect(corrected['dinner']!.fohMinutes, 60);
    });
  });

  group('resolveActiveServicePeriodId — sub-minute precision', () {
    // The resolver must match `DaypartBucketer._classifyInstant`:
    // inclusive end applies only at the exact boundary instant. A
    // truncate-to-minute implementation would keep the ACTIVE chip /
    // time-into-service header visible for up to 59 seconds past
    // service end. These tests pin sub-minute precision.

    const cutoff = '04:00';
    final defs = ServicePeriodDefinitionResolver.demoDefinitions;

    test('exact 15:00:00 boundary still resolves to lunch', () {
      // Mon 2026-05-04 — Lunch 11:00–15:00 weekdays.
      final id = resolveActiveServicePeriodId(
        localNow: DateTime(2026, 5, 4, 15, 0, 0),
        businessDayStartLocalTime: cutoff,
        definitions: defs,
      );
      expect(id, 'lunch');
    });

    test('15:00:00.001 falls into post-lunch gap (returns null)', () {
      // One millisecond past the inclusive end; the prior minute-only
      // implementation would have returned 'lunch' here for up to 59
      // additional seconds.
      final id = resolveActiveServicePeriodId(
        localNow: DateTime(2026, 5, 4, 15, 0, 0, 1),
        businessDayStartLocalTime: cutoff,
        definitions: defs,
      );
      expect(id, isNull);
    });

    test('15:00:30 mid-second past end is post-lunch gap', () {
      final id = resolveActiveServicePeriodId(
        localNow: DateTime(2026, 5, 4, 15, 0, 30),
        businessDayStartLocalTime: cutoff,
        definitions: defs,
      );
      expect(id, isNull);
    });

    test('14:59:59 still inside lunch', () {
      final id = resolveActiveServicePeriodId(
        localNow: DateTime(2026, 5, 4, 14, 59, 59),
        businessDayStartLocalTime: cutoff,
        definitions: defs,
      );
      expect(id, 'lunch');
    });

    test(
        'late-night rolls-past-midnight: 02:00:00.000 resolves to '
        'late_night, 02:00:00.001 falls into the gap', () {
      // Sun-calendar 2026-05-10. With 04:00 cutoff this is Saturday's
      // business day (weekday 6); Late Night [23:00, 02:00] applies on
      // Fri/Sat.
      final atBoundary = resolveActiveServicePeriodId(
        localNow: DateTime(2026, 5, 10, 2, 0, 0),
        businessDayStartLocalTime: cutoff,
        definitions: defs,
      );
      expect(atBoundary, 'late_night');

      final pastBoundary = resolveActiveServicePeriodId(
        localNow: DateTime(2026, 5, 10, 2, 0, 0, 1),
        businessDayStartLocalTime: cutoff,
        definitions: defs,
      );
      expect(pastBoundary, isNull);
    });
  });
}
