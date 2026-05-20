import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('operator account contact fields migration', () {
    late String executableSql;

    setUpAll(() {
      final migration = File(
        'db/migrations/202605201100_operator_account_contact_fields.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      executableSql = migration
          .split('\n')
          .map((line) {
            final commentIdx = line.indexOf('--');
            return commentIdx == -1 ? line : line.substring(0, commentIdx);
          })
          .join('\n');
    });

    test('adds nullable contact defaults to public.operators', () {
      expect(executableSql, contains('alter table public.operators'));
      expect(
        executableSql,
        contains('add column if not exists contact_email text'),
      );
      expect(
        executableSql,
        contains('add column if not exists contact_phone text'),
      );
    });

    test('guards email and phone format without changing RLS', () {
      expect(executableSql, contains('operators_contact_email_format_check'));
      expect(executableSql, contains("contact_email like '%@%'"));
      expect(executableSql, contains('operators_contact_phone_length_check'));
      expect(executableSql, contains('length(contact_phone) between 1 and 64'));
      expect(executableSql, isNot(contains('disable row level security')));
    });

    test('is wrapped in one transaction', () {
      final body = executableSql.trim();
      expect(body, startsWith('begin;'));
      expect(body, endsWith('commit;'));
    });
  });
}
