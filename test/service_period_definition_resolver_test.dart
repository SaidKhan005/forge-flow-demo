// Phase 7.55n.3 — ServicePeriodDefinitionResolver tests.
//
// Validates:
// A. ordered() sorts by sortOrder then id
// B. applicableForWeekday filters correctly
// C. idsForDayLabel matches current demo/fixture-era shape
// D. labelForId returns definition labels or raw id
// E. shortLabelForId returns definition short labels or raw id
// F. sortKey and sortIds order known before unknown
// F2. deterministic tie-breaking and multi-digit sortOrder
// G. sortIndex returns sortOrder for known, 99 for unknown
// H. demoDefinitions preserve current WeekDayOrder shape
// I. morning definition sorts correctly when configured

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/service_period_definition.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';

const _defs = ServicePeriodDefinitionResolver.demoDefinitions;

/// A morning definition for testing sortOrder behavior.
const _morningDef = ServicePeriodDefinition(
  id: 'morning',
  label: 'Morning',
  shortLabel: 'M',
  sortOrder: 0,
  startLocalTime: '06:00',
  endLocalTime: '11:00',
  rollsPastMidnight: false,
  applicableDays: [1, 2, 3, 4, 5, 6, 7],
);

void main() {
  // ── A: ordered() sorts by sortOrder then id ─────────────────────────────

  group('A — ordered', () {
    test('demo definitions come out in lunch, dinner, late_night order', () {
      final result = ServicePeriodDefinitionResolver.ordered(_defs);
      expect(result.map((d) => d.id).toList(),
          ['lunch', 'dinner', 'late_night']);
    });

    test('sorts by sortOrder first, then id for ties', () {
      const defs = [
        ServicePeriodDefinition(
          id: 'brunch', label: 'Brunch', shortLabel: 'BR', sortOrder: 2,
          startLocalTime: '10:00', endLocalTime: '14:00',
          rollsPastMidnight: false, applicableDays: [6, 7],
        ),
        ServicePeriodDefinition(
          id: 'dinner', label: 'Dinner', shortLabel: 'D', sortOrder: 2,
          startLocalTime: '17:00', endLocalTime: '23:00',
          rollsPastMidnight: false, applicableDays: [1, 2, 3, 4, 5, 6, 7],
        ),
        ServicePeriodDefinition(
          id: 'lunch', label: 'Lunch', shortLabel: 'L', sortOrder: 1,
          startLocalTime: '11:00', endLocalTime: '15:00',
          rollsPastMidnight: false, applicableDays: [1, 2, 3, 4, 5],
        ),
      ];
      final result = ServicePeriodDefinitionResolver.ordered(defs);
      expect(result.map((d) => d.id).toList(),
          ['lunch', 'brunch', 'dinner']);
    });

    test('does not mutate input list', () {
      final input = [..._defs].reversed.toList();
      final originalOrder = input.map((d) => d.id).toList();
      ServicePeriodDefinitionResolver.ordered(input);
      expect(input.map((d) => d.id).toList(), originalOrder);
    });
  });

  // ── B: applicableForWeekday ─────────────────────────────────────────────

  group('B — applicableForWeekday', () {
    test('Monday (1) returns lunch, dinner', () {
      final result =
          ServicePeriodDefinitionResolver.applicableForWeekday(_defs, 1);
      expect(result.map((d) => d.id).toList(), ['lunch', 'dinner']);
    });

    test('Friday (5) returns lunch, dinner, late_night', () {
      final result =
          ServicePeriodDefinitionResolver.applicableForWeekday(_defs, 5);
      expect(result.map((d) => d.id).toList(),
          ['lunch', 'dinner', 'late_night']);
    });

    test('Saturday (6) returns dinner, late_night', () {
      final result =
          ServicePeriodDefinitionResolver.applicableForWeekday(_defs, 6);
      expect(result.map((d) => d.id).toList(), ['dinner', 'late_night']);
    });

    test('Sunday (7) returns dinner only', () {
      final result =
          ServicePeriodDefinitionResolver.applicableForWeekday(_defs, 7);
      expect(result.map((d) => d.id).toList(), ['dinner']);
    });

    test('results are in sortOrder order', () {
      final result =
          ServicePeriodDefinitionResolver.applicableForWeekday(_defs, 5);
      for (int i = 0; i < result.length - 1; i++) {
        expect(result[i].sortOrder, lessThanOrEqualTo(result[i + 1].sortOrder));
      }
    });
  });

  // ── C: idsForDayLabel matches current demo shape ────────────────────────

  group('C — idsForDayLabel', () {
    test('Mon–Thu return [lunch, dinner]', () {
      for (final day in ['Mon', 'Tue', 'Wed', 'Thu']) {
        final ids =
            ServicePeriodDefinitionResolver.idsForDayLabel(_defs, day);
        expect(ids, ['lunch', 'dinner'], reason: '$day should have lunch + dinner');
      }
    });

    test('Fri returns [lunch, dinner, late_night]', () {
      final ids =
          ServicePeriodDefinitionResolver.idsForDayLabel(_defs, 'Fri');
      expect(ids, ['lunch', 'dinner', 'late_night']);
    });

    test('Sat returns [dinner, late_night]', () {
      final ids =
          ServicePeriodDefinitionResolver.idsForDayLabel(_defs, 'Sat');
      expect(ids, ['dinner', 'late_night']);
    });

    test('Sun returns [dinner]', () {
      final ids =
          ServicePeriodDefinitionResolver.idsForDayLabel(_defs, 'Sun');
      expect(ids, ['dinner']);
    });

    test('unrecognized label returns empty', () {
      final ids =
          ServicePeriodDefinitionResolver.idsForDayLabel(_defs, 'Holiday');
      expect(ids, isEmpty);
    });
  });

  // ── D: labelForId ───────────────────────────────────────────────────────

  group('D — labelForId', () {
    test('known IDs return their labels', () {
      expect(ServicePeriodDefinitionResolver.labelForId(_defs, 'lunch'),
          'Lunch');
      expect(ServicePeriodDefinitionResolver.labelForId(_defs, 'dinner'),
          'Dinner');
      expect(ServicePeriodDefinitionResolver.labelForId(_defs, 'late_night'),
          'Late Night');
    });

    test('unknown ID returns raw id', () {
      expect(ServicePeriodDefinitionResolver.labelForId(_defs, 'brunch'),
          'brunch');
    });
  });

  // ── E: shortLabelForId ──────────────────────────────────────────────────

  group('E — shortLabelForId', () {
    test('known IDs return their short labels', () {
      expect(ServicePeriodDefinitionResolver.shortLabelForId(_defs, 'lunch'),
          'L');
      expect(ServicePeriodDefinitionResolver.shortLabelForId(_defs, 'dinner'),
          'D');
      expect(ServicePeriodDefinitionResolver.shortLabelForId(_defs, 'late_night'),
          'LN');
    });

    test('unknown ID returns raw id', () {
      expect(
          ServicePeriodDefinitionResolver.shortLabelForId(_defs, 'after_hours'),
          'after_hours');
    });
  });

  // ── F: sortKey and sortIds ──────────────────────────────────────────────

  group('F — sortKey and sortIds', () {
    test('known IDs sort before unknown IDs', () {
      final knownKey =
          ServicePeriodDefinitionResolver.sortKey(_defs, 'lunch');
      final unknownKey =
          ServicePeriodDefinitionResolver.sortKey(_defs, 'brunch');
      expect(knownKey.compareTo(unknownKey), lessThan(0));
    });

    test('known IDs sort by sortOrder', () {
      final lunchKey =
          ServicePeriodDefinitionResolver.sortKey(_defs, 'lunch');
      final dinnerKey =
          ServicePeriodDefinitionResolver.sortKey(_defs, 'dinner');
      final lateKey =
          ServicePeriodDefinitionResolver.sortKey(_defs, 'late_night');
      expect(lunchKey.compareTo(dinnerKey), lessThan(0));
      expect(dinnerKey.compareTo(lateKey), lessThan(0));
    });

    test('unknown IDs sort alphabetically among themselves', () {
      final afterKey =
          ServicePeriodDefinitionResolver.sortKey(_defs, 'after_hours');
      final brunchKey =
          ServicePeriodDefinitionResolver.sortKey(_defs, 'brunch');
      expect(afterKey.compareTo(brunchKey), lessThan(0));
    });

    test('sortIds orders known first, then unknown alphabetically', () {
      final ids = ['brunch', 'late_night', 'lunch', 'after_hours', 'dinner'];
      final sorted = ServicePeriodDefinitionResolver.sortIds(_defs, ids);
      expect(sorted,
          ['lunch', 'dinner', 'late_night', 'after_hours', 'brunch']);
    });

    test('sortIds does not mutate input list', () {
      final input = ['dinner', 'lunch'];
      ServicePeriodDefinitionResolver.sortIds(_defs, input);
      expect(input, ['dinner', 'lunch']);
    });
  });

  // ── F2: deterministic tie-breaking and multi-digit sortOrder ─────────────

  group('F2 — deterministic sortKey tie-breaking', () {
    test('same-sortOrder ties break by id', () {
      const defs = [
        ServicePeriodDefinition(
          id: 'dinner', label: 'Dinner', shortLabel: 'D', sortOrder: 2,
          startLocalTime: '17:00', endLocalTime: '23:00',
          rollsPastMidnight: false, applicableDays: [1, 2, 3, 4, 5, 6, 7],
        ),
        ServicePeriodDefinition(
          id: 'brunch', label: 'Brunch', shortLabel: 'BR', sortOrder: 2,
          startLocalTime: '10:00', endLocalTime: '14:00',
          rollsPastMidnight: false, applicableDays: [6, 7],
        ),
      ];
      final sorted = ServicePeriodDefinitionResolver.sortIds(
          defs, ['dinner', 'brunch']);
      // Both have sortOrder 2 — should break tie alphabetically by id
      expect(sorted, ['brunch', 'dinner']);
    });

    test('multi-digit sortOrder values sort numerically', () {
      const defs = [
        ServicePeriodDefinition(
          id: 'early', label: 'Early', shortLabel: 'E', sortOrder: 2,
          startLocalTime: '06:00', endLocalTime: '09:00',
          rollsPastMidnight: false, applicableDays: [1, 2, 3, 4, 5],
        ),
        ServicePeriodDefinition(
          id: 'late', label: 'Late', shortLabel: 'LT', sortOrder: 10,
          startLocalTime: '22:00', endLocalTime: '02:00',
          rollsPastMidnight: true, applicableDays: [5, 6],
        ),
      ];
      final sorted = ServicePeriodDefinitionResolver.sortIds(
          defs, ['late', 'early']);
      // sortOrder 2 before sortOrder 10 — numeric, not lexicographic
      expect(sorted, ['early', 'late']);
    });

    test('unknown ids still sort alphabetically after all known ids', () {
      final sorted = ServicePeriodDefinitionResolver.sortIds(
          _defs, ['zebra', 'lunch', 'alpha', 'dinner']);
      expect(sorted, ['lunch', 'dinner', 'alpha', 'zebra']);
    });

    test('demo-order behavior unchanged after fix', () {
      final sorted = ServicePeriodDefinitionResolver.sortIds(
          _defs, ['late_night', 'dinner', 'lunch']);
      expect(sorted, ['lunch', 'dinner', 'late_night']);
    });
  });

  // ── G: sortIndex ────────────────────────────────────────────────────────

  group('G — sortIndex', () {
    test('returns sortOrder for known definitions', () {
      expect(ServicePeriodDefinitionResolver.sortIndex(_defs, 'lunch'), 1);
      expect(ServicePeriodDefinitionResolver.sortIndex(_defs, 'dinner'), 2);
      expect(
          ServicePeriodDefinitionResolver.sortIndex(_defs, 'late_night'), 3);
    });

    test('returns 99 for unknown IDs', () {
      expect(ServicePeriodDefinitionResolver.sortIndex(_defs, 'brunch'), 99);
      expect(
          ServicePeriodDefinitionResolver.sortIndex(_defs, 'after_hours'), 99);
    });
  });

  // ── H: demoDefinitions match current WeekDayOrder shape ─────────────────

  group('H — demoDefinitions shape', () {
    test('three definitions: lunch, dinner, late_night', () {
      expect(_defs.length, 3);
      expect(_defs.map((d) => d.id).toList(),
          ['lunch', 'dinner', 'late_night']);
    });

    test('lunch applies Mon–Fri (weekdays 1–5)', () {
      final lunch = _defs.firstWhere((d) => d.id == 'lunch');
      expect(lunch.applicableDays, [1, 2, 3, 4, 5]);
    });

    test('dinner applies Mon–Sun (weekdays 1–7)', () {
      final dinner = _defs.firstWhere((d) => d.id == 'dinner');
      expect(dinner.applicableDays, [1, 2, 3, 4, 5, 6, 7]);
    });

    test('late_night applies Fri–Sat (weekdays 5–6)', () {
      final lateNight = _defs.firstWhere((d) => d.id == 'late_night');
      expect(lateNight.applicableDays, [5, 6]);
    });

    test('late_night rolls past midnight', () {
      final lateNight = _defs.firstWhere((d) => d.id == 'late_night');
      expect(lateNight.rollsPastMidnight, isTrue);
    });
  });

  // ── I: morning definition sorts correctly when configured ───────────────

  group('I — morning support', () {
    test('morning with sortOrder 0 sorts before all demo definitions', () {
      final withMorning = [_morningDef, ..._defs];
      final result = ServicePeriodDefinitionResolver.ordered(withMorning);
      expect(result.first.id, 'morning');
      expect(result.map((d) => d.id).toList(),
          ['morning', 'lunch', 'dinner', 'late_night']);
    });

    test('morning appears in weekday applicability when configured', () {
      final withMorning = [_morningDef, ..._defs];
      // Monday should now include morning
      final monIds = ServicePeriodDefinitionResolver.idsForDayLabel(
          withMorning, 'Mon');
      expect(monIds, ['morning', 'lunch', 'dinner']);
    });

    test('morning label and short label resolve from definitions', () {
      final withMorning = [_morningDef, ..._defs];
      expect(ServicePeriodDefinitionResolver.labelForId(
          withMorning, 'morning'), 'Morning');
      expect(ServicePeriodDefinitionResolver.shortLabelForId(
          withMorning, 'morning'), 'M');
    });

    test('morning sorts before lunch in sortIds', () {
      final withMorning = [_morningDef, ..._defs];
      final ids = ['lunch', 'morning', 'dinner'];
      final sorted =
          ServicePeriodDefinitionResolver.sortIds(withMorning, ids);
      expect(sorted, ['morning', 'lunch', 'dinner']);
    });
  });
}
