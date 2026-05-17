// Pure unit tests for NextServicePeriodOpenResolver — the closed-state
// Shift dashboard's reopen-time helper.
//
// These prove the resolver math only (no I/O, no widgets): before
// service, between periods, after close, applicable-days skip,
// past-midnight rollover, and the timezone-agnostic contract (the
// caller supplies a restaurant-local instant; the resolver returns a
// restaurant-local instant — no UTC conversion happens here).

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/next_service_period_open_resolver.dart';

const _lunch = ServicePeriodDefinition(
  id: 'lunch',
  label: 'Lunch',
  shortLabel: 'L',
  sortOrder: 1,
  startLocalTime: '11:00',
  endLocalTime: '15:00',
  rollsPastMidnight: false,
  applicableDays: [1, 2, 3, 4, 5],
);

const _dinner = ServicePeriodDefinition(
  id: 'dinner',
  label: 'Dinner',
  shortLabel: 'D',
  sortOrder: 2,
  startLocalTime: '17:00',
  endLocalTime: '23:00',
  rollsPastMidnight: false,
  applicableDays: [1, 2, 3, 4, 5, 6, 7],
);

// Late Night: Fri (5) + Sat (6) only, rolls past midnight (23:00 -> 02:00).
const _lateNight = ServicePeriodDefinition(
  id: 'late_night',
  label: 'Late Night',
  shortLabel: 'LN',
  sortOrder: 3,
  startLocalTime: '23:00',
  endLocalTime: '02:00',
  rollsPastMidnight: true,
  applicableDays: [5, 6],
);

const _all = [_lunch, _dinner, _lateNight];

void main() {
  group('NextServicePeriodOpenResolver', () {
    test('before service today → next open is today\'s first period', () {
      // Wednesday 2026-05-13 at 08:00 local. Lunch (11:00) is next.
      final now = DateTime(2026, 5, 13, 8, 0);
      final r = NextServicePeriodOpenResolver.resolve(
        localNow: now,
        definitions: _all,
      );
      expect(r, isNotNull);
      expect(r!.definition.id, 'lunch');
      expect(r.localOpen, DateTime(2026, 5, 13, 11, 0));
      expect(r.isoWeekday, DateTime.wednesday);
      expect(r.weekdayName, 'Wednesday');
    });

    test('between periods → next open is the later same-day period', () {
      // Wednesday 2026-05-13 at 16:00 (after Lunch ends 15:00, before
      // Dinner 17:00). Next open is Dinner today.
      final now = DateTime(2026, 5, 13, 16, 0);
      final r = NextServicePeriodOpenResolver.resolve(
        localNow: now,
        definitions: _all,
      );
      expect(r!.definition.id, 'dinner');
      expect(r.localOpen, DateTime(2026, 5, 13, 17, 0));
      expect(r.weekdayName, 'Wednesday');
    });

    test('after close → next open is the next applicable day', () {
      // Wednesday 2026-05-13 at 23:30 (Dinner ended 23:00; Late Night
      // is Fri/Sat only so not applicable Wed). Next open is Thursday
      // Lunch 11:00.
      final now = DateTime(2026, 5, 13, 23, 30);
      final r = NextServicePeriodOpenResolver.resolve(
        localNow: now,
        definitions: _all,
      );
      expect(r!.definition.id, 'lunch');
      expect(r.localOpen, DateTime(2026, 5, 14, 11, 0));
      expect(r.weekdayName, 'Thursday');
    });

    test('applicable-days skip: Late Night only resolves on Fri/Sat', () {
      // Define a restaurant that ONLY runs Late Night (Fri 5 + Sat 6).
      // From Sunday 2026-05-17 13:00, the next open is Friday
      // 2026-05-22 at 23:00 — every Mon-Thu is skipped.
      final now = DateTime(2026, 5, 17, 13, 0); // Sunday
      final r = NextServicePeriodOpenResolver.resolve(
        localNow: now,
        definitions: const [_lateNight],
      );
      expect(r, isNotNull);
      expect(r!.definition.id, 'late_night');
      expect(r.isoWeekday, DateTime.friday);
      expect(r.weekdayName, 'Friday');
      expect(r.localOpen, DateTime(2026, 5, 22, 23, 0));
    });

    test('past-midnight period reopens at its START, not its rolled end',
        () {
      // Friday 2026-05-15 at 03:00 (Late Night ran 23:00 Fri -> 02:00
      // Sat; it is now past 02:00 so it is closed). With ONLY Late
      // Night configured, the next open is Friday 23:00 (its own start
      // today — Fri is applicable), NOT the 02:00 cross-midnight end.
      final now = DateTime(2026, 5, 15, 3, 0); // Friday
      final r = NextServicePeriodOpenResolver.resolve(
        localNow: now,
        definitions: const [_lateNight],
      );
      expect(r!.definition.id, 'late_night');
      expect(r.localOpen, DateTime(2026, 5, 15, 23, 0));
      expect(r.weekdayName, 'Friday');
    });

    test('a period starting exactly now is "active", not the next open',
        () {
      // Wednesday 11:00 exactly — Lunch is starting/active now, so the
      // NEXT open is Dinner 17:00 the same day.
      final now = DateTime(2026, 5, 13, 11, 0);
      final r = NextServicePeriodOpenResolver.resolve(
        localNow: now,
        definitions: _all,
      );
      expect(r!.definition.id, 'dinner');
      expect(r.localOpen, DateTime(2026, 5, 13, 17, 0));
    });

    test('timezone-agnostic: same local wall time yields same local open',
        () {
      // The resolver does no UTC math. Two callers in different real
      // timezones that both pass the SAME restaurant-local wall-clock
      // instant must get the SAME restaurant-local open instant back.
      final nowA = DateTime(2026, 5, 13, 8, 0);
      final nowB = DateTime(2026, 5, 13, 8, 0); // same wall time
      final ra = NextServicePeriodOpenResolver.resolve(
        localNow: nowA,
        definitions: _all,
      );
      final rb = NextServicePeriodOpenResolver.resolve(
        localNow: nowB,
        definitions: _all,
      );
      expect(ra!.localOpen, rb!.localOpen);
      expect(ra.localOpen, DateTime(2026, 5, 13, 11, 0));
    });

    test('empty definitions → null (caller omits the reopen line)', () {
      final r = NextServicePeriodOpenResolver.resolve(
        localNow: DateTime(2026, 5, 13, 8, 0),
        definitions: const [],
      );
      expect(r, isNull);
    });

    test('weekday correct when next open is not the next calendar day', () {
      // ONLY Late Night (Fri/Sat). From Tuesday 2026-05-12 10:00 the
      // next open is Friday 2026-05-15 23:00 — three calendar days
      // later; the weekday must read Friday, not Wednesday.
      final now = DateTime(2026, 5, 12, 10, 0); // Tuesday
      final r = NextServicePeriodOpenResolver.resolve(
        localNow: now,
        definitions: const [_lateNight],
      );
      expect(r!.weekdayName, 'Friday');
      expect(r.localOpen, DateTime(2026, 5, 15, 23, 0));
    });
  });
}
