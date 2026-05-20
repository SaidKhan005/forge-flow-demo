import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('org-unit account overrides migration', () {
    late String migration;
    late String executableSql;

    setUpAll(() {
      migration = File(
        'db/migrations/202605201000_org_unit_account_overrides.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      executableSql = migration
          .split('\n')
          .map((line) {
            final commentIdx = line.indexOf('--');
            return commentIdx == -1 ? line : line.substring(0, commentIdx);
          })
          .join('\n');
    });

    test('creates an org-unit keyed override table', () {
      expect(
        executableSql,
        contains(
          'create table if not exists public.org_unit_account_overrides',
        ),
      );
      expect(executableSql, contains('primary key (operator_id, org_unit_id)'));
      expect(executableSql, contains('foreign key (operator_id, org_unit_id)'));
      expect(
        executableSql,
        contains('references public.org_units(operator_id, id)'),
      );
    });

    test('stores only scoped account fields', () {
      for (final field in <String>[
        'iana_timezone',
        'locale_code',
        'currency_code',
        'contact_email',
        'contact_phone',
      ]) {
        expect(executableSql, contains(field));
      }
      for (final excluded in <String>[
        'business_name',
        'logo_url',
        'business_day_rollover_hour',
        'data_accuracy',
        'vendor',
      ]) {
        expect(executableSql, isNot(contains(excluded)));
      }
    });

    test('uses RLS, grants, trigger, and operator-leading index', () {
      expect(
        executableSql,
        contains(
          'alter table public.org_unit_account_overrides enable row level security',
        ),
      );
      expect(executableSql, contains('public.app_current_operator()'));
      expect(
        executableSql,
        contains(
          'create index if not exists idx_org_unit_account_overrides_operator',
        ),
      );
      expect(
        executableSql.replaceAll(RegExp(r'\s+'), ' '),
        contains(
          'on public.org_unit_account_overrides (operator_id, org_unit_id)',
        ),
      );
      expect(executableSql, contains('to service_role'));
      expect(executableSql, contains('to forge_admin'));
      expect(
        executableSql,
        contains('execute function public.cloud_foundation_set_updated_at()'),
      );
    });

    test('is wrapped in one transaction', () {
      final body = executableSql.trim();
      expect(body, startsWith('begin;'));
      expect(body, endsWith('commit;'));
    });
  });
}
