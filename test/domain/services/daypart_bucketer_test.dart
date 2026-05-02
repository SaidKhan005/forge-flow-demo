// Phase 10.5.1 — Daypart bucketing engine tests.
//
// Fixtures use `ServicePeriodDefinitionResolver.demoDefinitions`
// (Lunch 11:00–15:00 weekdays Mon–Fri, Dinner 17:00–23:00 every day,
// Late Night 23:00–02:00 Fri/Sat with `rollsPastMidnight`). All
// timestamps are restaurant-local (the bucketer's input contract).
// `BucketingLocationContext` carries an IANA timezone solely as the
// missing-tz assertion gate; the engine itself does not perform
// timezone conversion.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/business_date_resolver.dart';
import 'package:forge_and_flow/domain/services/daypart_bucketer.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';

const _location = BucketingLocationContext(
  iana: 'America/St_Johns',
  businessDayStartLocalTime: '04:00',
);

final _definitions = ServicePeriodDefinitionResolver.demoDefinitions;

void main() {
  group('DaypartBucketer.bucketPosLine', () {
    test('Lunch hit (Mon 12:30 → lunch)', () {
      final id = DaypartBucketer.bucketPosLine(
        BucketingPosLine(
          sourceId: 'order_001',
          eventLocalTimestamp: DateTime(2026, 5, 4, 12, 30),
        ),
        _location,
        _definitions,
      );
      expect(id, 'lunch');
    });

    test('Dinner hit (Mon 19:00 → dinner)', () {
      final id = DaypartBucketer.bucketPosLine(
        BucketingPosLine(
          sourceId: 'order_002',
          eventLocalTimestamp: DateTime(2026, 5, 4, 19, 0),
        ),
        _location,
        _definitions,
      );
      expect(id, 'dinner');
    });

    test('Between periods returns null (Mon 16:00 → null)', () {
      final id = DaypartBucketer.bucketPosLine(
        BucketingPosLine(
          sourceId: 'order_003',
          eventLocalTimestamp: DateTime(2026, 5, 4, 16, 0),
        ),
        _location,
        _definitions,
      );
      expect(id, isNull);
    });

    test(
      'Boundary tie-break (Mon 15:00:00 → lunch; phase doc inclusive end)',
      () {
        // Phase doc Decisions Locked: "Event at exact endLocalTime of a
        // period belongs to the ending period (inclusive end). … An
        // event at 15:00:00 with Lunch 11:00 to 15:00 and Dinner 17:00
        // to 22:00 belongs to Lunch."
        final id = DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: 'order_004',
            eventLocalTimestamp: DateTime(2026, 5, 4, 15, 0),
          ),
          _location,
          _definitions,
        );
        expect(id, 'lunch');
      },
    );

    test(
      'One second past inclusive end (Mon 15:00:01 → null; sub-minute '
      'precision honored)',
      () {
        // The phase doc reserves the exact-boundary instant for the
        // ending period. 15:00:00.001 onward must fall into the
        // post-Lunch gap; the classifier compares full sub-minute
        // precision instead of rounding to the minute.
        final id = DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: 'order_004b',
            eventLocalTimestamp: DateTime(2026, 5, 4, 15, 0, 1),
          ),
          _location,
          _definitions,
        );
        expect(id, isNull);
      },
    );

    test(
      'One second before inclusive end (Mon 14:59:59 → lunch)',
      () {
        final id = DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: 'order_004c',
            eventLocalTimestamp: DateTime(2026, 5, 4, 14, 59, 59),
          ),
          _location,
          _definitions,
        );
        expect(id, 'lunch');
      },
    );

    test(
      'Rolls-past-midnight inclusive end (Sun-calendar 02:00:00 → '
      'late_night) and one second past (02:00:01 → null)',
      () {
        // The exact 02:00:00.000 instant is still inside Late Night
        // on the Sat business day (rolls-past-midnight inclusive end).
        // 02:00:00.001 onward must drop out — no period covers it.
        final atBoundary = DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: 'order_004d',
            eventLocalTimestamp: DateTime(2026, 5, 10, 2, 0, 0),
          ),
          _location,
          _definitions,
        );
        expect(atBoundary, 'late_night');

        final pastBoundary = DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: 'order_004e',
            eventLocalTimestamp: DateTime(2026, 5, 10, 2, 0, 1),
          ),
          _location,
          _definitions,
        );
        expect(pastBoundary, isNull);
      },
    );

    test('Lunch not applicable on Saturday (Sat 12:30 → null)', () {
      // demoDefinitions: Lunch applies only Mon–Fri. May 9, 2026 is Sat.
      final id = DaypartBucketer.bucketPosLine(
        BucketingPosLine(
          sourceId: 'order_005',
          eventLocalTimestamp: DateTime(2026, 5, 9, 12, 30),
        ),
        _location,
        _definitions,
      );
      expect(id, isNull);
    });

    test(
      'Late Night roll-over: 02:00 Sun-calendar → Sat business day → late_night',
      () {
        // 2026-05-10 02:00 is Sun-calendar. With cutoff 04:00 the
        // business date is 2026-05-09 (Sat, ISO weekday 6). Late Night
        // applies on Fri/Sat (5, 6) and rolls past midnight, so the
        // fact buckets to Late Night, not "any-period on Sun".
        // Sanity-check the business-date math first.
        expect(
          BusinessDateResolver.resolve(
            localTimestamp: DateTime(2026, 5, 10, 2, 0),
            businessDayStartLocalTime: '04:00',
          ),
          '2026-05-09',
        );
        final id = DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: 'order_006',
            eventLocalTimestamp: DateTime(2026, 5, 10, 2, 0),
          ),
          _location,
          _definitions,
        );
        expect(id, 'late_night');
      },
    );

    test('Missing IANA tz → MissingTimezoneError', () {
      const noTz = BucketingLocationContext(
        iana: '',
        businessDayStartLocalTime: '04:00',
      );
      expect(
        () => DaypartBucketer.bucketPosLine(
          BucketingPosLine(
            sourceId: 'order_007',
            eventLocalTimestamp: DateTime(2026, 5, 4, 12, 30),
          ),
          noTz,
          _definitions,
        ),
        throwsA(isA<MissingTimezoneError>()),
      );
    });
  });

  group('DaypartBucketer.bucketReservation', () {
    test('Dinner hit (Fri 18:30 → dinner)', () {
      final id = DaypartBucketer.bucketReservation(
        BucketingReservation(
          sourceId: 'res_001',
          reservationLocalTimestamp: DateTime(2026, 5, 8, 18, 30),
        ),
        _location,
        _definitions,
      );
      expect(id, 'dinner');
    });

    test('Pre-service returns null (Fri 09:00 → null)', () {
      final id = DaypartBucketer.bucketReservation(
        BucketingReservation(
          sourceId: 'res_002',
          reservationLocalTimestamp: DateTime(2026, 5, 8, 9, 0),
        ),
        _location,
        _definitions,
      );
      expect(id, isNull);
    });

    test('Missing IANA tz → MissingTimezoneError', () {
      const noTz = BucketingLocationContext(
        iana: '   ',
        businessDayStartLocalTime: '04:00',
      );
      expect(
        () => DaypartBucketer.bucketReservation(
          BucketingReservation(
            sourceId: 'res_003',
            reservationLocalTimestamp: DateTime(2026, 5, 8, 18, 30),
          ),
          noTz,
          _definitions,
        ),
        throwsA(isA<MissingTimezoneError>()),
      );
    });
  });

  group('DaypartBucketer.bucketLaborPunch', () {
    test(
      'Punch-split worked example: Mon 14:30 → 22:30 → '
      '[lunch 30, non_service 120, dinner 330]',
      () {
        // From phase doc Bucketing Engine Design → Punch split rule
        // → Worked example, with end extended from 19:00 → 22:30 to
        // exercise the full Dinner span.
        //   * Lunch [11:00, 15:00) ∩ punch = 30 min (14:30 → 15:00)
        //   * Non-service gap = 120 min (15:00 → 17:00)
        //   * Dinner [17:00, 23:00) ∩ punch = 330 min (17:00 → 22:30)
        final segments = DaypartBucketer.bucketLaborPunch(
          BucketingLaborPunch(
            sourceId: 'punch_001',
            clockedInLocal: DateTime(2026, 5, 4, 14, 30),
            clockedOutLocal: DateTime(2026, 5, 4, 22, 30),
          ),
          _location,
          _definitions,
        );
        expect(segments, hasLength(3));

        expect(segments[0].servicePeriodId, 'lunch');
        expect(segments[0].startLocal, DateTime(2026, 5, 4, 14, 30));
        expect(segments[0].endLocal, DateTime(2026, 5, 4, 15, 0));
        expect(segments[0].minutes, 30);

        expect(segments[1].servicePeriodId, isNull);
        expect(segments[1].startLocal, DateTime(2026, 5, 4, 15, 0));
        expect(segments[1].endLocal, DateTime(2026, 5, 4, 17, 0));
        expect(segments[1].minutes, 120);

        expect(segments[2].servicePeriodId, 'dinner');
        expect(segments[2].startLocal, DateTime(2026, 5, 4, 17, 0));
        expect(segments[2].endLocal, DateTime(2026, 5, 4, 22, 30));
        expect(segments[2].minutes, 330);

        // Total minutes reconcile back to the punch duration.
        final total =
            segments.fold<int>(0, (sum, seg) => sum + seg.minutes);
        expect(total, 8 * 60);
      },
    );

    test(
      'Punch fully inside Dinner emits a single dinner segment',
      () {
        final segments = DaypartBucketer.bucketLaborPunch(
          BucketingLaborPunch(
            sourceId: 'punch_002',
            clockedInLocal: DateTime(2026, 5, 4, 18, 0),
            clockedOutLocal: DateTime(2026, 5, 4, 21, 30),
          ),
          _location,
          _definitions,
        );
        expect(segments, hasLength(1));
        expect(segments.single.servicePeriodId, 'dinner');
        expect(segments.single.minutes, 3 * 60 + 30);
      },
    );

    test(
      'Late Night punch crossing midnight stays on the originating '
      'business date',
      () {
        // Punch Sat 23:30 → Sun 01:30 (calendar). Both ends fall
        // inside Sat business date because Sun 01:30 < 04:00 cutoff.
        // Late Night applies on Sat (weekday 6) and rolls past
        // midnight, so the entire span buckets to late_night with
        // no non_service slivers.
        final segments = DaypartBucketer.bucketLaborPunch(
          BucketingLaborPunch(
            sourceId: 'punch_003',
            clockedInLocal: DateTime(2026, 5, 9, 23, 30),
            clockedOutLocal: DateTime(2026, 5, 10, 1, 30),
          ),
          _location,
          _definitions,
        );
        expect(segments, hasLength(1));
        expect(segments.single.servicePeriodId, 'late_night');
        expect(segments.single.startLocal, DateTime(2026, 5, 9, 23, 30));
        expect(segments.single.endLocal, DateTime(2026, 5, 10, 1, 30));
        expect(segments.single.minutes, 120);
      },
    );

    test(
      'Boundary tie-break inside a punch: minute starting at 15:00 '
      'belongs to non_service, not Lunch',
      () {
        // Plan worked example: Lunch ∩ punch = 30 min for a 14:30
        // → 15:00 portion. The minute starting at 15:00 (i.e.
        // [15:00, 15:01)) is therefore the first minute of the
        // post-Lunch gap. Inclusive-end is a point-in-time rule for
        // POS lines; minute-counting uses half-open intervals.
        final segments = DaypartBucketer.bucketLaborPunch(
          BucketingLaborPunch(
            sourceId: 'punch_004',
            clockedInLocal: DateTime(2026, 5, 4, 14, 45),
            clockedOutLocal: DateTime(2026, 5, 4, 15, 30),
          ),
          _location,
          _definitions,
        );
        expect(segments, hasLength(2));
        expect(segments[0].servicePeriodId, 'lunch');
        expect(segments[0].minutes, 15); // 14:45 → 15:00
        expect(segments[1].servicePeriodId, isNull);
        expect(segments[1].minutes, 30); // 15:00 → 15:30
      },
    );

    test('Degenerate punch (clock-out <= clock-in) returns empty list',
        () {
      final segments = DaypartBucketer.bucketLaborPunch(
        BucketingLaborPunch(
          sourceId: 'punch_005',
          clockedInLocal: DateTime(2026, 5, 4, 19, 0),
          clockedOutLocal: DateTime(2026, 5, 4, 19, 0),
        ),
        _location,
        _definitions,
      );
      expect(segments, isEmpty);
    });

    test('Missing IANA tz → MissingTimezoneError', () {
      const noTz = BucketingLocationContext(
        iana: '',
        businessDayStartLocalTime: '04:00',
      );
      expect(
        () => DaypartBucketer.bucketLaborPunch(
          BucketingLaborPunch(
            sourceId: 'punch_006',
            clockedInLocal: DateTime(2026, 5, 4, 14, 30),
            clockedOutLocal: DateTime(2026, 5, 4, 22, 30),
          ),
          noTz,
          _definitions,
        ),
        throwsA(isA<MissingTimezoneError>()),
      );
    });
  });
}
