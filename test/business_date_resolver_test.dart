// Phase 7.55n.2 — BusinessDateResolver tests.
//
// Validates:
// A. Before-cutoff local timestamp resolves to previous calendar date
// B. Exact-cutoff local timestamp resolves to same calendar date
// C. After-cutoff local timestamp resolves to same calendar date
// D. Midnight-edge cases
// E. resolveFromIso convenience method
// F. Month and year boundary crossings
// G. Various business-day start times

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/business_date_resolver.dart';

void main() {
  // ── A: Before-cutoff resolves to previous calendar date ──────────────────

  group('A — before cutoff → previous date', () {
    test('03:59 with 04:00 cutoff resolves to previous date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 3, 59),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-12');
    });

    test('01:30 with 04:00 cutoff resolves to previous date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 1, 30),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-12');
    });

    test('00:01 with 04:00 cutoff resolves to previous date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 0, 1),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-12');
    });
  });

  // ── B: Exact cutoff resolves to same calendar date ───────────────────────

  group('B — exact cutoff → same date', () {
    test('04:00 with 04:00 cutoff resolves to same date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 4, 0),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-13');
    });

    test('06:00 with 06:00 cutoff resolves to same date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 6, 0),
        businessDayStartLocalTime: '06:00',
      );
      expect(result, '2026-04-13');
    });
  });

  // ── C: After cutoff resolves to same calendar date ───────────────────────

  group('C — after cutoff → same date', () {
    test('04:01 with 04:00 cutoff resolves to same date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 4, 1),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-13');
    });

    test('12:00 noon with 04:00 cutoff resolves to same date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 12, 0),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-13');
    });

    test('23:59 with 04:00 cutoff resolves to same date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 23, 59),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-13');
    });
  });

  // ── D: Midnight edge cases ───────────────────────────────────────────────

  group('D — midnight edge cases', () {
    test('midnight 00:00 with 04:00 cutoff resolves to previous date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 0, 0),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-12');
    });

    test('midnight 00:00 with 00:00 cutoff resolves to same date', () {
      // 00:00 cutoff means business day starts at midnight — 00:00 is at
      // the cutoff, so same date.
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 0, 0),
        businessDayStartLocalTime: '00:00',
      );
      expect(result, '2026-04-13');
    });
  });

  // ── E: resolveFromIso convenience ────────────────────────────────────────

  group('E — resolveFromIso', () {
    test('parses ISO string and resolves correctly', () {
      final result = BusinessDateResolver.resolveFromIso(
        localIsoTimestamp: '2026-04-13T03:30:00',
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-12');
    });

    test('at-cutoff ISO string resolves to same date', () {
      final result = BusinessDateResolver.resolveFromIso(
        localIsoTimestamp: '2026-04-13T04:00:00',
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-13');
    });

    test('after-cutoff ISO string resolves to same date', () {
      final result = BusinessDateResolver.resolveFromIso(
        localIsoTimestamp: '2026-04-13T14:30:00',
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-04-13');
    });
  });

  // ── F: Month and year boundary crossings ─────────────────────────────────

  group('F — boundary crossings', () {
    test('before-cutoff on first of month crosses to previous month', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 1, 2, 0),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-03-31');
    });

    test('before-cutoff on Jan 1 crosses to previous year', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 1, 1, 3, 0),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2025-12-31');
    });

    test('before-cutoff on March 1 non-leap year crosses to Feb 28', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 3, 1, 1, 0),
        businessDayStartLocalTime: '04:00',
      );
      expect(result, '2026-02-28');
    });
  });

  // ── G: Various business-day start times ──────────────────────────────────

  group('G — various cutoff times', () {
    test('06:00 cutoff: 05:59 resolves to previous date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 5, 59),
        businessDayStartLocalTime: '06:00',
      );
      expect(result, '2026-04-12');
    });

    test('06:00 cutoff: 06:00 resolves to same date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 6, 0),
        businessDayStartLocalTime: '06:00',
      );
      expect(result, '2026-04-13');
    });

    test('02:00 cutoff: 01:59 resolves to previous date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 1, 59),
        businessDayStartLocalTime: '02:00',
      );
      expect(result, '2026-04-12');
    });

    test('02:00 cutoff: 02:00 resolves to same date', () {
      final result = BusinessDateResolver.resolve(
        localTimestamp: DateTime(2026, 4, 13, 2, 0),
        businessDayStartLocalTime: '02:00',
      );
      expect(result, '2026-04-13');
    });
  });
}
