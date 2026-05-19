// Per-Daypart V1 R7e - data accuracy provenance.
//
// Proves the effective data-accuracy view now emits source metadata
// and the shared model parses it without breaking older payloads.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';

const String _migrationFilename =
    '202605190900_per_daypart_v1_r7e_data_accuracy_provenance.sql';

String _readMigration() {
  final file = File('db/migrations/$_migrationFilename');
  expect(
    file.existsSync(),
    isTrue,
    reason:
        'tests must run from repository root; expected '
        'db/migrations/$_migrationFilename to exist',
  );
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

void main() {
  group('R7e migration', () {
    test('appends provenance columns to the effective view', () {
      final sql = _readMigration().toLowerCase();

      expect(
        sql,
        contains(
          'create or replace view public.effective_data_accuracy_settings_v',
        ),
      );
      expect(sql, contains('as covers_source_per_service_period_source'));
      expect(sql, contains('as wage_source_source'));
      expect(sql, contains('as walk_in_handling_mode_source'));
      expect(sql, contains('jsonb_object_agg'));
      expect(sql, contains('jsonb_object_keys'));
      expect(sql, contains("'source_kind', 'service_period_setting'"));
      expect(sql, contains("'source_kind', 'scoped_override'"));
      expect(sql, contains("'source_kind', 'base_setting'"));
      expect(sql, contains("'source_kind', 'default'"));
      expect(
        sql,
        contains(
          'grant select on public.effective_data_accuracy_settings_v to service_role',
        ),
      );
      expect(
        sql,
        contains(
          'grant select on public.effective_data_accuracy_settings_v to forge_admin',
        ),
      );
    });

    test('keeps existing value precedence expressions', () {
      final sql = _readMigration().toLowerCase();

      expect(
        sql,
        contains(
          "|| coalesce(business_scope.covers_source_per_service_period, '{}'::jsonb)",
        ),
      );
      expect(
        sql,
        contains(
          "|| coalesce(org_scope.covers_source_per_service_period, '{}'::jsonb)",
        ),
      );
      expect(
        sql,
        contains(
          "|| coalesce(location_scope.covers_source_per_service_period, '{}'::jsonb)",
        ),
      );
      expect(sql, contains('coalesce(\n    location_scope.wage_source,'));
      expect(
        sql,
        contains('coalesce(\n    location_scope.walk_in_handling_mode,'),
      );
    });
  });

  group('DataAccuracySettings provenance parsing', () {
    test('parses source metadata and exposes plain labels', () {
      final settings = DataAccuracySettings.fromRow(<String, Object?>{
        'setting_id': 'set-1',
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'covers_source_per_service_period': <String, Object?>{
          'breakfast': 'manual',
        },
        'covers_source_per_service_period_source': <String, Object?>{
          'breakfast': <String, Object?>{
            'scope_type': 'business',
            'source_kind': 'scoped_override',
            'override_id': 'ovr-breakfast',
          },
        },
        'covers_manual_entries': <String, Object?>{},
        'wage_source': 'manual_mix',
        'wage_source_source': <String, Object?>{
          'scope_type': 'org_unit',
          'source_kind': 'scoped_override',
          'override_id': 'ovr-wage',
        },
        'walk_in_handling_mode': 'reservations_only',
        'walk_in_handling_mode_source': <String, Object?>{
          'scope_type': 'default',
          'source_kind': 'default',
        },
        'walk_in_manual_entries': <String, Object?>{},
        'created_at': DateTime.utc(2026, 5, 19),
        'updated_at': DateTime.utc(2026, 5, 19),
      });

      expect(settings.coversSourceSourceFor('breakfast')!.label, 'Business');
      expect(settings.coversSourceSourceFor('lunch'), isNull);
      expect(settings.wageSourceSource!.label, 'Org unit');
      expect(settings.walkInHandlingModeSource!.label, 'Default');
    });

    test('older responses without metadata stay compatible', () {
      final settings = DataAccuracySettings.fromRow(<String, Object?>{
        'setting_id': 'set-1',
        'operator_id': 'op-1',
        'location_id': 'loc-1',
        'covers_source_per_service_period': <String, Object?>{},
        'covers_manual_entries': <String, Object?>{},
        'wage_source': 'vendor',
        'walk_in_handling_mode': 'reservations_only',
        'walk_in_manual_entries': <String, Object?>{},
        'created_at': DateTime.utc(2026, 5, 19),
        'updated_at': DateTime.utc(2026, 5, 19),
      });

      expect(settings.coversSourcePerServicePeriodSources, isEmpty);
      expect(settings.wageSourceSource, isNull);
      expect(settings.walkInHandlingModeSource, isNull);
    });
  });
}
