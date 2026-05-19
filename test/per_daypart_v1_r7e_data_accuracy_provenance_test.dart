// Per-Daypart V1 R7f - data accuracy provenance precedence.
//
// Proves the effective data-accuracy view emits source metadata with
// the same hierarchy winner as the effective value, and the shared
// model parses it without breaking older payloads.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/domain/models/data_accuracy_settings.dart';

const String _migrationFilename =
    '202605191000_per_daypart_v1_r7f_data_accuracy_precedence_fix.sql';

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
  group('R7f migration', () {
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

    test('scoped overrides win over keyed service-period base maps', () {
      final sql = _readMigration().toLowerCase();
      final valueOrder = _extractMergeOrder(
        sql,
        startNeedle: ') as setting_id,',
        endNeedle: ') as covers_source_per_service_period,',
      );
      final sourceOrder = _extractMergeOrder(
        sql,
        startNeedle: ') as updated_by,',
        endNeedle: ') as covers_source_per_service_period_source,',
      );

      expect(sourceOrder, equals(valueOrder));
      expect(
        _mergeCoversSources(valueOrder),
        containsPair('afternoon', 'keyed_manual'),
      );
      expect(
        _mergeCoversSources(valueOrder),
        containsPair('brunch', 'business_forecast'),
      );
      expect(
        _mergeCoversSources(valueOrder),
        containsPair('breakfast', 'org_manual'),
      );
      expect(
        _mergeCoversSources(valueOrder),
        containsPair('lunch', 'location_forecast'),
      );
      expect(
        _mergeCoversSources(valueOrder),
        containsPair('dinner', 'location_manual'),
      );
      expect(
        _mergeProvenanceSources(sourceOrder),
        containsPair('afternoon', 'keyed_service_period_setting'),
      );
      expect(
        _mergeProvenanceSources(sourceOrder),
        containsPair('brunch', 'business_scoped_override'),
      );
      expect(
        _mergeProvenanceSources(sourceOrder),
        containsPair('breakfast', 'org_scoped_override'),
      );
      expect(
        _mergeProvenanceSources(sourceOrder),
        containsPair('lunch', 'location_scoped_override'),
      );
      expect(
        _mergeProvenanceSources(sourceOrder),
        containsPair('dinner', 'location_scoped_override'),
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

enum _MergeSource { business, orgUnit, location, keyed }

List<_MergeSource> _extractMergeOrder(
  String sql, {
  required String startNeedle,
  required String endNeedle,
}) {
  final start = sql.indexOf(startNeedle);
  expect(start, isNonNegative, reason: 'start marker missing');
  final end = sql.indexOf(endNeedle, start);
  expect(end, isNonNegative, reason: 'end marker missing');
  final block = sql.substring(start, end);
  final tokens = <({int index, _MergeSource source})>[];
  void add(String pattern, _MergeSource source) {
    final index = block.indexOf(pattern);
    expect(index, isNonNegative, reason: 'merge source $source missing');
    tokens.add((index: index, source: source));
  }

  add('business_scope.covers_source_per_service_period', _MergeSource.business);
  add('org_scope.covers_source_per_service_period', _MergeSource.orgUnit);
  add('location_scope.covers_source_per_service_period', _MergeSource.location);
  add(
    'from public.data_accuracy_service_period_settings sp',
    _MergeSource.keyed,
  );
  tokens.sort((a, b) => a.index.compareTo(b.index));
  return tokens.map((token) => token.source).toList(growable: false);
}

Map<String, String> _mergeCoversSources(List<_MergeSource> order) {
  return _mergeByExtractedSqlOrder(
    order,
    const <_MergeSource, Map<String, String>>{
      _MergeSource.business: <String, String>{
        'breakfast': 'business_manual',
        'lunch': 'business_forecast',
        'brunch': 'business_forecast',
      },
      _MergeSource.orgUnit: <String, String>{
        'breakfast': 'org_manual',
        'dinner': 'org_forecast',
      },
      _MergeSource.location: <String, String>{
        'lunch': 'location_forecast',
        'dinner': 'location_manual',
      },
      _MergeSource.keyed: <String, String>{
        'afternoon': 'keyed_manual',
        'breakfast': 'keyed_forecast',
        'lunch': 'keyed_vendor',
        'brunch': 'keyed_vendor',
      },
    },
  );
}

Map<String, String> _mergeProvenanceSources(List<_MergeSource> order) {
  return _mergeByExtractedSqlOrder(
    order,
    const <_MergeSource, Map<String, String>>{
      _MergeSource.business: <String, String>{
        'breakfast': 'business_scoped_override',
        'lunch': 'business_scoped_override',
        'brunch': 'business_scoped_override',
      },
      _MergeSource.orgUnit: <String, String>{
        'breakfast': 'org_scoped_override',
        'dinner': 'org_scoped_override',
      },
      _MergeSource.location: <String, String>{
        'lunch': 'location_scoped_override',
        'dinner': 'location_scoped_override',
      },
      _MergeSource.keyed: <String, String>{
        'afternoon': 'keyed_service_period_setting',
        'breakfast': 'keyed_service_period_setting',
        'lunch': 'keyed_service_period_setting',
        'brunch': 'keyed_service_period_setting',
      },
    },
  );
}

Map<String, String> _mergeByExtractedSqlOrder(
  List<_MergeSource> order,
  Map<_MergeSource, Map<String, String>> sourceMaps,
) {
  final merged = <String, String>{};
  for (final source in order) {
    merged.addAll(sourceMaps[source]!);
  }
  return merged;
}
