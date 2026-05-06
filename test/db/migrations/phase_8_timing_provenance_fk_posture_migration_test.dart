import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605080000_phase_8_timing_provenance_fk_posture.sql';

const String _lane0MigrationPath =
    'db/migrations/202605061700_phase_8_timing_provenance_shift_records.sql';

/// Strips SQL `--` line comments so assertions only run against executable
/// SQL, not the migration header context.
String _stripLineComments(String input) {
  final buffer = StringBuffer();
  for (final line in const LineSplitter().convert(input)) {
    if (line.trimLeft().startsWith('--')) {
      continue;
    }
    buffer.writeln(line);
  }
  return buffer.toString();
}

void main() {
  final rawMigration = File(_migrationPath).readAsStringSync();
  final migration = _stripLineComments(rawMigration);
  final normalized = migration.toLowerCase();
  final compact =
      migration.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  final lane0 = File(_lane0MigrationPath).readAsStringSync();
  final lane0Compact =
      lane0.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

  group('Phase 8 timing provenance FK posture migration', () {
    test('wraps the change in a single transaction', () {
      expect(normalized, contains('begin;'));
      expect(normalized, contains('commit;'));
    });

    test('drops then re-adds all three timing-provenance FKs', () {
      for (final fk in <String>[
        'shift_records_business_timing_profile_fk',
        'shift_records_business_timing_profile_version_fk',
        'open_shift_snapshots_profile_version_fk',
      ]) {
        expect(
          normalized,
          contains('drop constraint $fk'),
          reason: '$fk should be dropped before re-add',
        );
        expect(
          normalized,
          contains('add constraint $fk'),
          reason: '$fk should be re-added with new posture',
        );
      }
    });

    test('re-adds each FK with on delete set null and not valid', () {
      // shift_records timing profile FK
      expect(
        compact,
        contains(
          'add constraint shift_records_business_timing_profile_fk '
          'foreign key (operator_id, business_timing_profile_id) '
          'references public.business_timing_profiles(operator_id, profile_id) '
          'on delete set null '
          'not valid',
        ),
      );

      // shift_records timing version FK
      expect(
        compact,
        contains(
          'add constraint shift_records_business_timing_profile_version_fk '
          'foreign key (operator_id, business_timing_profile_version_id) '
          'references public.business_timing_profiles(operator_id, profile_id) '
          'on delete set null '
          'not valid',
        ),
      );

      // open_shift_snapshots version FK
      expect(
        compact,
        contains(
          'add constraint open_shift_snapshots_profile_version_fk '
          'foreign key (operator_id, business_timing_profile_version_id) '
          'references public.business_timing_profiles(operator_id, profile_id) '
          'on delete set null '
          'not valid',
        ),
      );
    });

    test('uses idempotent guards on every drop and re-add', () {
      // Each FK has an `if exists` drop guard and an `if not exists` add guard.
      final dropGuards = RegExp(
        r"if exists \(\s*select 1\s+from pg_constraint\s+where conname = '",
      ).allMatches(normalized).length;
      final addGuards = RegExp(
        r"if not exists \(\s*select 1\s+from pg_constraint\s+where conname = '",
      ).allMatches(normalized).length;

      expect(
        dropGuards,
        3,
        reason: 'expected 3 drop guards (one per FK)',
      );
      expect(
        addGuards,
        3,
        reason: 'expected 3 add guards (one per FK)',
      );
    });

    test('does not validate the new FKs in this migration', () {
      // Defer validation to a future maintenance window.
      expect(normalized, isNot(contains('validate constraint')));
    });

    test('does not touch the version-equals-profile CHECKs', () {
      // Phase 8R divergence drop is a separate follow-up.
      expect(
        normalized,
        isNot(contains('shift_records_timing_version_profile_match_check')),
      );
      expect(
        normalized,
        isNot(
          contains('open_shift_snapshots_timing_version_profile_match_check'),
        ),
      );
    });

    test('does not touch the service-period key check or indexes', () {
      expect(
        normalized,
        isNot(contains('shift_records_service_period_key_format_check')),
      );
      expect(normalized, isNot(contains('create index')));
      expect(normalized, isNot(contains('drop index')));
    });

    test('does not introduce timezone-naive timestamps', () {
      expect(normalized, isNot(contains('timestamp without time zone')));
    });

    test('Lane 0 still owns the version-equals-profile CHECKs', () {
      // Sanity guard: this follow-up must not have inadvertently moved or
      // duplicated the CHECK constraints. Lane 0 stays the owner until the
      // Phase 8R drop migration lands.
      expect(
        lane0Compact,
        contains('shift_records_timing_version_profile_match_check'),
      );
      expect(
        lane0Compact,
        contains('open_shift_snapshots_timing_version_profile_match_check'),
      );
      expect(
        lane0Compact,
        contains(
          'business_timing_profile_version_id is not distinct from '
          'business_timing_profile_id',
        ),
      );
    });
  });
}
