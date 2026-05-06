import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql';

void main() {
  final migration = File(_migrationPath).readAsStringSync();
  final normalized = migration.toLowerCase();
  final compact = migration.replaceAll(RegExp(r'\s+'), ' ');

  group('Phase 8 timing provenance migration', () {
    test('does not create or query a missing timing version table', () {
      expect(
        normalized,
        isNot(contains('create table public.business_timing_profile_versions')),
      );
      expect(
        normalized,
        isNot(
          contains(
            'create table if not exists public.business_timing_profile_versions',
          ),
        ),
      );
      expect(
        normalized,
        isNot(contains('from public.business_timing_profile_versions')),
      );
      expect(
        normalized,
        isNot(contains('join public.business_timing_profile_versions')),
      );
    });

    test('adds nullable closed shift timing triplet', () {
      expect(
        migration,
        contains('add column if not exists business_timing_profile_id uuid'),
      );
      expect(
        migration,
        contains(
          'add column if not exists business_timing_profile_version_id uuid',
        ),
      );
      expect(
        migration,
        contains('add column if not exists service_period_key text'),
      );
    });

    test('uses existing profiles table as the version authority', () {
      expect(migration, contains('shift_records_business_timing_profile_fk'));
      expect(
        migration,
        contains('shift_records_business_timing_profile_version_fk'),
      );
      expect(
        migration,
        contains(
          'references public.business_timing_profiles(operator_id, profile_id)',
        ),
      );
      expect(
        compact,
        contains(
          'business_timing_profile_version_id is not distinct from business_timing_profile_id',
        ),
      );
      expect(compact, contains('not valid'));
    });

    test('keeps indexes tenant leading', () {
      for (final indexShape in <String>[
        'on public.shift_records ( operator_id, location_id, business_date desc, service_period_key',
        'on public.shift_records ( operator_id, location_id, business_timing_profile_id, business_timing_profile_version_id',
        'on public.open_shift_snapshots ( operator_id, location_id, business_timing_profile_version_id',
      ]) {
        expect(compact, contains(indexShape));
      }
    });

    test('extends open snapshots with the same version key', () {
      expect(
        compact,
        contains(
          'alter table public.open_shift_snapshots add column if not exists business_timing_profile_version_id uuid',
        ),
      );
      expect(
        compact,
        contains(
          'update public.open_shift_snapshots set business_timing_profile_version_id = business_timing_profile_id where business_timing_profile_version_id is null',
        ),
      );
      expect(migration, contains('open_shift_snapshots_profile_version_fk'));
    });

    test('does not introduce timezone-naive timestamps', () {
      expect(normalized, isNot(contains('timestamp without time zone')));
    });
  });
}
