// Demo-data Slice F — HP #11 scope-level overrides + variance-breach
// notification regression.
//
// Authority: docs/_audits/per_daypart_v1/full_demo_data_spec.md Slice F
//            (§2c lines 140-144, §1.6 line 80, Gap G9/G10);
//            CLAUDE.md HP #11 / HP #2 / HP #4.
//
// What this guards (fails if):
//   (a) any scope-level override is missing or not distinct from the
//       business default (Region timing / Location wage / District
//       data-accuracy),
//   (b) an "inherits" location wrongly carries an override row,
//   (c) the Notifications surface is empty OR its alert is fabricated
//       (its dollar figure must equal a real seeded over-plan week —
//       Metric Honesty),
//   (d) two reseeds are not byte-identical (determinism / NO RNG),
//   (e) an override leaks across (operator, location) (HP #4),
//   (f) the operator-web wage scope fixture stops mirroring the mobile
//       HP #11 story.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/sqlite/sqlite_database.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_wage_authority_gateway.dart';

double _blend(List<Map<String, Object?>> rows, String bucket) {
  final cohort = rows.where((r) => r['labor_bucket'] == bucket).toList();
  var sum = 0.0;
  var den = 0.0;
  for (final r in cohort) {
    final rate = (r['hourly_rate'] as num).toDouble();
    final hrs = (r['weighted_hours'] as num).toDouble();
    sum += rate * hrs;
    den += hrs;
  }
  return den == 0 ? 0 : sum / den;
}

void main() {
  const downtown = DemoScope.restaurantId; // business default
  const northLoop = DemoScope.northLoopRestaurantId; // East / Metro District
  const riverside = DemoScope.riversideRestaurantId; // location override
  const harbour = DemoScope.harbourRestaurantId; // inherits everything

  group('Demo-data Slice F — HP #11 scope overrides + notifications', () {
    setUp(() async {
      await SqliteDatabase.instance.reseedDemo();
    });

    test('Region scope — East Region overrides timing (week-start), '
        'Downtown stays business default, Riverside/Harbour inherit',
        () async {
      final db = await SqliteDatabase.instance.database;
      Future<List<Map<String, Object?>>> cfg(String rid) => db.query(
            'restaurant_timing_configs',
            where: 'restaurant_id = ?',
            whereArgs: [rid],
          );

      final dt = await cfg(downtown);
      expect(dt, isNotEmpty, reason: 'Downtown = business default timing');
      expect(dt.first['week_start_day'], DateTime.monday);

      final nl = await cfg(northLoop);
      expect(nl, isNotEmpty, reason: 'East Region timing override row');
      expect(nl.first['week_start_day'], DateTime.sunday,
          reason: 'override week-start ≠ business default Monday');

      // Inherit = ABSENCE of a per-location row (reader returns null →
      // caller falls back to the business default).
      expect(await cfg(riverside), isEmpty);
      expect(await cfg(harbour), isEmpty);
    });

    test('Location scope — Riverside overrides wages (location wins), '
        'Harbour/North Loop inherit business default', () async {
      final db = await SqliteDatabase.instance.database;
      Future<List<Map<String, Object?>>> wage(String rid) => db.query(
            'wage_role_rows',
            where: 'restaurant_id = ?',
            whereArgs: [rid],
          );

      final dt = await wage(downtown);
      expect(_blend(dt, 'foh'), closeTo(16.50, 1e-9),
          reason: 'business default FOH blend');
      expect(_blend(dt, 'boh'), closeTo(21.35, 1e-9));

      final rv = await wage(riverside);
      expect(rv, isNotEmpty, reason: 'Riverside location override rows');
      expect(_blend(rv, 'foh'), closeTo(17.50, 1e-9),
          reason: 'Riverside FOH override ≠ business default');
      expect(_blend(rv, 'boh'), closeTo(22.35, 1e-9));

      // Inherit = no wage rows → waterfall resolves to the business
      // default by construction.
      expect(await wage(harbour), isEmpty);
      expect(await wage(northLoop), isEmpty);
    });

    test('District scope — Metro District overrides dinner covers-source; '
        'business-default baseline seeded; Riverside/Harbour inherit',
        () async {
      final db = await SqliteDatabase.instance.database;
      Future<List<Map<String, Object?>>> das(String rid) => db.query(
            'data_accuracy_service_period_settings_cache',
            where: 'restaurant_id = ?',
            whereArgs: [rid],
            orderBy: 'service_period_key ASC',
          );

      final dt = await das(downtown);
      expect(dt.length, 3, reason: 'business default = 3 periods');
      expect(dt.every((r) => r['covers_source'] == 'vendor'), isTrue);

      final nl = await das(northLoop);
      expect(nl.length, 1, reason: 'only the overridden dinner row');
      expect(nl.first['service_period_key'], 'dinner');
      expect(nl.first['covers_source'], 'manual',
          reason: 'Metro District covers-source override ≠ vendor');

      expect(await das(riverside), isEmpty);
      expect(await das(harbour), isEmpty);
    });

    test('Notifications — variance-breach alert dollar figure equals the '
        'real worst over-plan seeded week (Metric Honesty)', () async {
      final db = await SqliteDatabase.instance.database;
      final weeks = await db.query(
        'week_records',
        columns: ['dollar_gap'],
        where: 'restaurant_id = ?',
        whereArgs: [downtown],
      );
      var maxGap = 0.0;
      for (final w in weeks) {
        final g = (w['dollar_gap'] as num?)?.toDouble() ?? 0.0;
        if (g > maxGap) maxGap = g;
      }

      final notes = await db.query(
        'app_notifications',
        where: 'restaurant_id = ? AND type = ?',
        whereArgs: [downtown, 'variance_breach'],
      );

      if (maxGap <= 0) {
        // Honest empty — no real breach, no fabricated alert.
        expect(notes, isEmpty);
        return;
      }
      expect(notes, isNotEmpty,
          reason: 'a real over-plan week exists → an alert must exist');
      final body = notes.first['body'] as String;
      expect(body, contains('\$${maxGap.round()}'),
          reason: 'alert dollar amount must equal the real seeded worst '
              'over-plan gap, not a fabricated number');
      expect(notes.first['read_at'], isNull, reason: 'seeded unread');
    });

    test('Determinism — two reseeds are byte-identical for the override '
        'rows + the variance-breach notification', () async {
      Future<List<Map<String, Object?>>> snap() async {
        final db = await SqliteDatabase.instance.database;
        final timing = await db.query('restaurant_timing_configs',
            where: 'restaurant_id = ?', whereArgs: [northLoop]);
        final wage = await db.query('wage_role_rows',
            where: 'restaurant_id = ?',
            whereArgs: [riverside],
            orderBy: 'role_name ASC');
        final das = await db.query(
            'data_accuracy_service_period_settings_cache',
            where: 'restaurant_id IN (?, ?)',
            whereArgs: [downtown, northLoop],
            orderBy: 'restaurant_id ASC, service_period_key ASC');
        final notes = await db.query('app_notifications',
            where: 'type = ?',
            whereArgs: ['variance_breach'],
            orderBy: 'notification_id ASC');
        return [...timing, ...wage, ...das, ...notes];
      }

      final first = (await snap()).toString();
      await SqliteDatabase.instance.reseedDemo();
      final second = (await snap()).toString();
      expect(second, equals(first));
    });

    test('HP #4 — overrides never leak across (operator, location)',
        () async {
      final db = await SqliteDatabase.instance.database;
      // Riverside's wage override must not appear under Downtown.
      final dtWage = await db.query('wage_role_rows',
          where: 'restaurant_id = ?', whereArgs: [downtown]);
      expect(_blend(dtWage, 'foh'), closeTo(16.50, 1e-9));
      // North Loop's timing override must not bleed to Downtown.
      final dtCfg = await db.query('restaurant_timing_configs',
          where: 'restaurant_id = ?', whereArgs: [downtown]);
      expect(dtCfg.first['week_start_day'], DateTime.monday);
      // No override row exists for a non-demo restaurant_id.
      for (final t in const [
        'restaurant_timing_configs',
        'wage_role_rows',
        'data_accuracy_service_period_settings_cache',
      ]) {
        final foreign = await db.query(t,
            where: 'restaurant_id = ?', whereArgs: ['not_a_demo_restaurant']);
        expect(foreign, isEmpty, reason: '$t leaked to a foreign scope');
      }
    });

    test('Operator-web wage scope fixture mirrors the mobile HP #11 story',
        () {
      // HP #11 hierarchy resolution: a location-scoped row wins; if no
      // location-scoped row exists for the bucket, fall back to the
      // operator-wide (business-default) cohort. The fixture stores
      // the business default with `locationId == ''`.
      double blendFor(String locationId, String bucket) {
        var rows = kDemoWageRoleRowScopeFixture
            .where((r) =>
                r.locationId == locationId && r.laborBucket == bucket)
            .toList();
        if (rows.isEmpty) {
          // Inherit from operator-wide business default (locationId='').
          rows = kDemoWageRoleRowScopeFixture
              .where((r) => r.locationId == '' && r.laborBucket == bucket)
              .toList();
        }
        var n = 0.0;
        var d = 0.0;
        for (final r in rows) {
          n += r.hourlyRate * r.weightedHours;
          d += r.weightedHours;
        }
        return d == 0 ? 0 : n / d;
      }

      // Business default.
      expect(blendFor('demo-loc-downtown', 'foh'), closeTo(16.50, 1e-9));
      expect(blendFor('demo-loc-downtown', 'boh'), closeTo(21.35, 1e-9));
      // Location override — Riverside differs (location wins).
      expect(blendFor('demo-loc-riverside', 'foh'), closeTo(17.50, 1e-9));
      expect(blendFor('demo-loc-riverside', 'boh'), closeTo(22.35, 1e-9));
      // Inherits — Harbour/North Loop equal the business default.
      expect(blendFor('demo-loc-harbour', 'foh'), closeTo(16.50, 1e-9));
      expect(blendFor('demo-loc-north-loop', 'boh'), closeTo(21.35, 1e-9));
      // Deterministic — ids are stable literals, every row unique, and
      // the router-owned default gateway is seeded from this fixture.
      final ids =
          kDemoWageRoleRowScopeFixture.map((r) => r.wageRoleRowId).toList();
      expect(ids.toSet().length, ids.length, reason: 'no duplicate ids');
      expect(ids, contains('demo-wage-demo-loc-riverside-server'));
      expect(
        kDemoWageRoleRowScopeFixture.every((r) => r.operatorId == 'demo-operator'),
        isTrue,
      );
    });
  });
}
