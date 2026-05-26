// ignore_for_file: file_names
//
// Filename intentionally mirrors the migration filename
// (`db/migrations/202605251020_plans_and_limits_scoped_contract_windows.sql`)
// so a reviewer can correlate test <-> migration at a glance.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _path =
    'db/migrations/202605251020_plans_and_limits_scoped_contract_windows.sql';

void main() {
  group('plans & limits scoped contract windows migration', () {
    late String sql;
    late String lower;

    setUpAll(() {
      final file = File(_path);
      expect(file.existsSync(), isTrue, reason: 'migration must exist');
      sql = file.readAsStringSync().replaceAll('\r\n', '\n');
      lower = sql.toLowerCase();
    });

    test('replaces the all-time target uniqueness with window support', () {
      expect(
        lower,
        contains(
          'drop constraint if exists pricing_contract_overrides_target_uq',
        ),
      );
      expect(
        lower,
        contains(
          'create index if not exists pricing_contract_overrides_target_window_idx',
        ),
      );
      expect(lower, contains('operator_id'));
      expect(lower, contains('scope_type'));
      expect(lower, contains('effective_from'));
      expect(lower, contains('effective_until'));
    });

    test('prevents overlapping windows for the same hierarchy target', () {
      expect(
        lower,
        contains(
          'create or replace function public.pricing_contract_overrides_prevent_overlap()',
        ),
      );
      expect(lower, contains('existing.operator_id = new.operator_id'));
      expect(
        lower,
        contains('existing.org_unit_id is not distinct from new.org_unit_id'),
      );
      expect(
        lower,
        contains('existing.location_id is not distinct from new.location_id'),
      );
      expect(lower, contains('daterange('));
      expect(lower, contains("'[)'"));
      expect(lower, contains("using errcode = '23505'"));
    });

    test('installs the overlap trigger idempotently', () {
      expect(
        lower,
        contains(
          'drop trigger if exists pricing_contract_overrides_prevent_overlap',
        ),
      );
      expect(
        lower,
        contains('create trigger pricing_contract_overrides_prevent_overlap'),
      );
      expect(
        lower,
        contains(
          'before insert or update on public.pricing_contract_overrides',
        ),
      );
      expect(
        lower,
        contains(
          'for each row execute function public.pricing_contract_overrides_prevent_overlap()',
        ),
      );
    });

    test('bounds lock + statement timeouts', () {
      expect(lower, contains("set local statement_timeout = '30s'"));
      expect(lower, contains("set local lock_timeout = '5s'"));
    });
  });
}
