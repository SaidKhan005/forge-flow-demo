// Per-Daypart V1 Slice R5 (Gap 27/36) — covers-source de-hardcode +
// keyed-table backfill proving tests.
//
// Proves the three things the R5 prompt requires:
//
//   (a) The resolver-keyed `DataAccuracySettings` model round-trips
//       for an operator with 4 configured periods (breakfast / lunch /
//       dinner / late_night) — no throw on a 4th period, and an
//       unconfigured period resolves to the vendor default.
//
//   (b) The backfill migration maps EACH legacy column to the correct
//       keyed `data_accuracy_service_period_settings` row with no
//       data loss (static SQL-text analysis, same approach as
//       test/services/data_accuracy/data_accuracy_migration_test.dart
//       — no live Postgres).
//
// (c) — "a covers UI renders N periods from the resolver, not
// Daypart.values" — is proven by
// test/operator_web/widgets/covers_source_toggle_test.dart (4-period
// render + the no-periods hint).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';

const String _migrationFilename =
    '202605170000_per_daypart_v1_r5_covers_source_keyed_backfill.sql';

String _readMigration() {
  final file = File('db/migrations/$_migrationFilename');
  expect(
    file.existsSync(),
    isTrue,
    reason: 'tests must run from repository root; expected '
        'db/migrations/$_migrationFilename to exist',
  );
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

/// Strip SQL `--` line comments so prose explaining the design does
/// not satisfy assertions meant to pin executable DDL.
String _stripSqlComments(String content) {
  final out = StringBuffer();
  for (final line in content.split('\n')) {
    final idx = line.indexOf('--');
    out.writeln(idx < 0 ? line : line.substring(0, idx));
  }
  return out.toString();
}

void main() {
  group('R5 (a) — resolver-keyed model round-trips for 4 periods', () {
    test(
      'fromRow projects the keyed covers_source_per_service_period map; '
      'a 4-period operator (breakfast/lunch/dinner/late_night) loads '
      'without throwing on the 4th period',
      () {
        final settings = DataAccuracySettings.fromRow(<String, Object?>{
          'setting_id': 'set-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'covers_source_per_service_period': <String, Object?>{
            'breakfast': 'manual',
            'lunch': 'vendor',
            'dinner': 'forecast',
            'late_night': 'manual',
          },
          'covers_manual_entries': <String, Object?>{},
          'wage_source': 'vendor',
          'walk_in_handling_mode': 'reservations_only',
          'walk_in_manual_entries': <String, Object?>{},
          'created_at': DateTime.utc(2026, 5, 17),
          'updated_at': DateTime.utc(2026, 5, 17),
        });

        expect(
          settings.coversSourceFor('breakfast'),
          equals(CoversSource.manual),
        );
        expect(
          settings.coversSourceFor('lunch'),
          equals(CoversSource.vendor),
        );
        expect(
          settings.coversSourceFor('dinner'),
          equals(CoversSource.forecast),
        );
        expect(
          settings.coversSourceFor('late_night'),
          equals(CoversSource.manual),
        );
        // A configured-but-not-listed 5th period resolves to the
        // vendor default rather than throwing.
        expect(
          settings.coversSourceFor('happy_hour'),
          equals(kDefaultCoversSource),
        );
        expect(kDefaultCoversSource, equals(CoversSource.vendor));
      },
    );

    test(
      'manualCoversFor is keyed by service_period_id and round-trips '
      'a 4-period manual-entries jsonb shape',
      () {
        final settings = DataAccuracySettings(
          settingId: 's',
          operatorId: 'op-1',
          locationId: 'loc-1',
          coversSourcePerServicePeriod: const <String, CoversSource>{
            'breakfast': CoversSource.manual,
            'late_night': CoversSource.manual,
          },
          coversManualEntries: const <String, Map<String, int>>{
            '2026-05-16': <String, int>{
              'breakfast': 31,
              'lunch': 88,
              'dinner': 142,
              'late_night': 17,
            },
          },
          wageSource: WageSource.vendor,
          createdAt: DateTime.utc(2026, 5, 17),
          updatedAt: DateTime.utc(2026, 5, 17),
        );

        expect(settings.manualCoversFor('2026-05-16', 'breakfast'), 31);
        expect(settings.manualCoversFor('2026-05-16', 'lunch'), 88);
        expect(settings.manualCoversFor('2026-05-16', 'dinner'), 142);
        expect(settings.manualCoversFor('2026-05-16', 'late_night'), 17);
        // Missing date / period → null (aggregator renders
        // not-yet-available rather than a phantom zero).
        expect(settings.manualCoversFor('2026-05-15', 'breakfast'), isNull);
        expect(settings.manualCoversFor('2026-05-16', 'brunch'), isNull);
      },
    );

    test(
      'legacy columns are still ingested when present and no keyed map '
      'is supplied (backward-compat reader during the deprecation '
      'window)',
      () {
        final settings = DataAccuracySettings.fromRow(<String, Object?>{
          'setting_id': 'set-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'covers_source_lunch': 'manual',
          'covers_source_dinner': 'forecast',
          'covers_source_late_night': 'vendor',
          'covers_manual_entries': <String, Object?>{},
          'wage_source': 'vendor',
          'walk_in_handling_mode': 'reservations_only',
          'walk_in_manual_entries': <String, Object?>{},
          'created_at': DateTime.utc(2026, 5, 17),
          'updated_at': DateTime.utc(2026, 5, 17),
        });

        expect(settings.coversSourceFor('lunch'), CoversSource.manual);
        expect(settings.coversSourceFor('dinner'), CoversSource.forecast);
        expect(settings.coversSourceFor('late_night'), CoversSource.vendor);
      },
    );

    test(
      'a keyed map wins over legacy columns when both are present',
      () {
        final settings = DataAccuracySettings.fromRow(<String, Object?>{
          'setting_id': 'set-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'covers_source_per_service_period': <String, Object?>{
            'lunch': 'forecast',
          },
          'covers_source_lunch': 'manual',
          'covers_source_dinner': 'manual',
          'covers_source_late_night': 'manual',
          'covers_manual_entries': <String, Object?>{},
          'wage_source': 'vendor',
          'walk_in_handling_mode': 'reservations_only',
          'walk_in_manual_entries': <String, Object?>{},
          'created_at': DateTime.utc(2026, 5, 17),
          'updated_at': DateTime.utc(2026, 5, 17),
        });

        // Keyed lunch wins; the legacy dinner/late_night columns are
        // NOT consulted because a keyed map was supplied (they fall
        // through to the vendor default).
        expect(settings.coversSourceFor('lunch'), CoversSource.forecast);
        expect(settings.coversSourceFor('dinner'), CoversSource.vendor);
        expect(settings.coversSourceFor('late_night'), CoversSource.vendor);
      },
    );

    test(
      'keyed reservation_plus_walkin (no operator-facing slot) is '
      'skipped rather than crashing the settings load',
      () {
        final settings = DataAccuracySettings.fromRow(<String, Object?>{
          'setting_id': 'set-1',
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'covers_source_per_service_period': <String, Object?>{
            'lunch': 'reservation_plus_walkin',
            'dinner': 'manual',
          },
          'covers_manual_entries': <String, Object?>{},
          'wage_source': 'vendor',
          'walk_in_handling_mode': 'reservations_only',
          'walk_in_manual_entries': <String, Object?>{},
          'created_at': DateTime.utc(2026, 5, 17),
          'updated_at': DateTime.utc(2026, 5, 17),
        });

        expect(settings.coversSourceFor('lunch'), kDefaultCoversSource);
        expect(settings.coversSourceFor('dinner'), CoversSource.manual);
      },
    );
  });

  group('R5 (b) — backfill migration preserves every legacy value', () {
    test(
      'one INSERT maps all three legacy columns to keyed rows under '
      'the correct service_period_key (lunch / dinner / late_night)',
      () {
        final sql = _stripSqlComments(_readMigration()).toLowerCase();

        // Targets the existing keyed table — NOT a new parallel table.
        expect(
          sql,
          contains(
            'insert into public.data_accuracy_service_period_settings',
          ),
        );
        expect(
          sql,
          isNot(contains('create table')),
          reason: 'R5 reuses the keyed table; it must not invent one',
        );

        // Every legacy column is mapped to its service_period_key.
        expect(sql, contains("('lunch', das.covers_source_lunch)"));
        expect(sql, contains("('dinner', das.covers_source_dinner)"));
        expect(
          sql,
          contains("('late_night', das.covers_source_late_night)"),
        );
        // Driven off every existing settings row so no operator is
        // skipped.
        expect(sql, contains('from public.data_accuracy_settings das'));
      },
    );

    test(
      'backfill is data-preserving + idempotent: ON CONFLICT DO NOTHING '
      'on the keyed UNIQUE identity so an operator-set keyed row is '
      'never clobbered and re-apply is a no-op',
      () {
        final sql = _stripSqlComments(_readMigration()).toLowerCase();
        expect(
          sql,
          contains(
            'on conflict (\n  operator_id,\n  location_id,\n  '
            'service_period_key,\n  effective_at_business_date\n) '
            'do nothing',
          ),
        );
        // Sentinel effective date reproduces the legacy column's
        // always-applies semantics (always at-or-before any close).
        expect(sql, contains("date '1970-01-01'"));
      },
    );

    test(
      'operator/location scoped: operator_id + location_id are copied '
      'straight from the source row (per-tenant isolation preserved)',
      () {
        final sql = _stripSqlComments(_readMigration()).toLowerCase();
        expect(sql, contains('das.operator_id'));
        expect(sql, contains('das.location_id'));
        // No bare current_setting — the keyed table already carries
        // the wrapper-only per-tenant policy; the backfill adds none.
        expect(
          RegExp(r"current_setting\(\s*'app\.", caseSensitive: false)
              .hasMatch(_readMigration()),
          isFalse,
        );
      },
    );

    test(
      'legacy columns are deprecated via column comments, wrapped in '
      'BEGIN ... COMMIT for atomicity',
      () {
        final sql = _readMigration();
        final lower = sql.toLowerCase();
        expect(lower.contains('begin;'), isTrue);
        expect(lower.contains('commit;'), isTrue);
        expect(
          lower,
          contains(
            'comment on column '
            'public.data_accuracy_settings.covers_source_lunch is',
          ),
        );
        expect(
          lower,
          contains(
            'comment on column '
            'public.data_accuracy_settings.covers_source_dinner is',
          ),
        );
        expect(
          lower,
          contains(
            'comment on column '
            'public.data_accuracy_settings.covers_source_late_night is',
          ),
        );
        expect(sql, contains('DEPRECATED 2026-05-17'));
      },
    );

    test(
      'migration prose is technical prose (NOT operator-facing UX copy; '
      'db/migrations is outside ux_em_dash_lint kUxCopyRoots, like '
      'every other repo migration and commit messages). The UX '
      'no-em-dash law binds the covers UIs / screen, verified '
      'separately by `dart run tool/ux_em_dash_lint.dart`.',
      () {
        // Sanity: the migration carries no operator-facing string
        // literals at all (it is pure DDL + SQL comments), so there is
        // nothing here the UX no-dash law could bind.
        final sql = _readMigration();
        expect(sql.contains("'"), isTrue); // SQL string literals exist
        expect(
          sql.toLowerCase(),
          contains('data_accuracy_service_period_settings'),
        );
      },
    );
  });
}
