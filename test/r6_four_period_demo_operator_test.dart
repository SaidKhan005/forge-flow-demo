// R6 — Choose Star Shifts: 4-period demo operator.
//
// Proves the data-only R6 slice:
//   A. The dedicated 4-period proof location seeds a
//      `restaurant_timing_configs` row whose
//      `service_period_definitions_json` resolves — through the SAME
//      runtime read seam (`SqliteRestaurantTimingConfigRepository` →
//      `ServicePeriodDefinitionResolver`) every reader uses — to FOUR
//      ordered service periods (Breakfast/Lunch/Dinner/Late night).
//   B. The 60-day closed `shift_records` cohort gives EACH of the four
//      configured periods candidates, keyed by the configured period
//      id (no fixed 3-element assumption), within the
//      baseline-candidate 60-day read window.
//
// This is the dataset the daypart de-hardcode is proven against:
// before R6 every demo dataset was 3-period, so a >3-period restaurant
// could not exercise the de-hardcode.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/service_period_definition_resolver.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/repositories/sqlite_restaurant_timing_config_repository.dart';

import '_test_helpers/sqlite_demo_helpers.dart';

const _fourPeriodRestaurantId = 'demo_restaurant_four_period';

void main() {
  setUp(() async {
    await setUpSqliteDemo();
    SqliteRestaurantTimingConfigRepository.instance.resetDao();
  });

  group('A — 4-period timing config resolves via the runtime read seam', () {
    test('proof location has a timing config with FOUR ordered periods',
        () async {
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final config = await repo.getTimingConfig(_fourPeriodRestaurantId);
      expect(config, isNotNull,
          reason: 'the 4-period proof location must be seeded');
      expect(config!.restaurantId, _fourPeriodRestaurantId);

      // Resolve through the SAME resolver every reader uses — no fixed
      // 3-element assumption: assert exactly four, in canonical order.
      final ordered = ServicePeriodDefinitionResolver.ordered(
        config.servicePeriodDefinitions,
      );
      expect(ordered.length, 4,
          reason: 'proves the dataset is N!=3 (de-hardcode target)');
      expect(
        ordered.map((d) => d.id).toList(),
        ['breakfast', 'lunch', 'dinner', 'late_night'],
      );
      expect(
        ordered.map((d) => d.label).toList(),
        ['Breakfast', 'Lunch', 'Dinner', 'Late night'],
      );
      expect(
        ordered.map((d) => d.shortLabel).toList(),
        ['B', 'L', 'D', 'LN'],
      );

      // sort_order strictly increasing in canonical order.
      for (var i = 1; i < ordered.length; i++) {
        expect(ordered[i].sortOrder, greaterThan(ordered[i - 1].sortOrder));
      }

      // Per-period definition fields are real (id/label/shortLabel/
      // sortOrder/start/end/applicableDays all populated).
      final lateNight =
          ordered.firstWhere((d) => d.id == 'late_night');
      expect(lateNight.rollsPastMidnight, isTrue);
      expect(lateNight.startLocalTime, '23:00');
      expect(lateNight.endLocalTime, '02:00');
      expect(lateNight.applicableDays, [4, 5, 6, 7]);

      final breakfast = ordered.firstWhere((d) => d.id == 'breakfast');
      expect(breakfast.applicableDays, [1, 2, 3, 4, 5, 6, 7]);
      expect(breakfast.rollsPastMidnight, isFalse);
    });

    test('the 3-period Downtown demo is unchanged (HP #2 same-table)',
        () async {
      // Both restaurants live in the SAME `restaurant_timing_configs`
      // table; the 4-period proof location must not perturb the
      // existing 3-period Downtown proof reference.
      final repo = SqliteRestaurantTimingConfigRepository.instance;
      final downtown = await repo.getTimingConfig('demo_restaurant_001');
      expect(downtown, isNotNull);
      final downtownOrdered = ServicePeriodDefinitionResolver.ordered(
        downtown!.servicePeriodDefinitions,
      );
      expect(downtownOrdered.map((d) => d.id).toList(),
          ['lunch', 'dinner', 'late_night']);
    });
  });

  group('B — 60-day closed cohort covers all four configured periods', () {
    test('every configured period has closed shift candidates, keyed by '
        'the configured period id', () async {
      final db = await SqliteDatabase.instance.database;

      // Distinct closed periods present for the proof location.
      final rows = await db.query(
        'shift_records',
        columns: ['daypart', 'service_period_key'],
        where: "restaurant_id = ? AND status = 'closed'",
        whereArgs: [_fourPeriodRestaurantId],
      );
      expect(rows, isNotEmpty);

      final periods =
          rows.map((r) => r['daypart'] as String).toSet();
      expect(periods, {'breakfast', 'lunch', 'dinner', 'late_night'},
          reason: 'all four configured periods must have candidates');

      // Period key column mirrors the daypart (configured period id) —
      // no fixed-3 / hardcoded key path.
      for (final r in rows) {
        expect(r['service_period_key'], r['daypart']);
      }

      // Each period has candidates spread across the window (not a
      // single day) — at least one row each is the floor; assert a
      // realistic spread for the all-week periods.
      Future<int> countFor(String p) async {
        final c = await db.query(
          'shift_records',
          where: "restaurant_id = ? AND status = 'closed' AND daypart = ?",
          whereArgs: [_fourPeriodRestaurantId, p],
        );
        return c.length;
      }

      // Breakfast/Lunch/Dinner serve every weekday → ~60 rows each.
      expect(await countFor('breakfast'), greaterThan(50));
      expect(await countFor('lunch'), greaterThan(50));
      expect(await countFor('dinner'), greaterThan(50));
      // Late night serves Thu–Sun only → present but fewer.
      final lnCount = await countFor('late_night');
      expect(lnCount, greaterThan(20));
      expect(lnCount, lessThan(await countFor('dinner')));
    });

    test('closed cohort sits inside a 60-day window (baseline-candidate '
        'read window)', () async {
      final db = await SqliteDatabase.instance.database;
      final rows = await db.query(
        'shift_records',
        columns: ['business_date'],
        where: "restaurant_id = ? AND status = 'closed'",
        whereArgs: [_fourPeriodRestaurantId],
        orderBy: 'business_date ASC',
      );
      expect(rows, isNotEmpty);
      final first =
          DateTime.parse(rows.first['business_date'] as String);
      final last =
          DateTime.parse(rows.last['business_date'] as String);
      final span = last.difference(first).inDays;
      // 60-day trailing window (offsets 59..0 inclusive).
      expect(span, lessThanOrEqualTo(59));
      expect(span, greaterThanOrEqualTo(40));
    });
  });
}
