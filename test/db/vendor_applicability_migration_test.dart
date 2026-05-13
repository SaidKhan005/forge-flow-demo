import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('vendor_applicability migration', () {
    late String sql;

    setUpAll(() {
      sql = File(
        'db/migrations/202605131500_b10_1_vendor_applicability.sql',
      ).readAsStringSync().toLowerCase().replaceAll('\r\n', '\n');
    });

    test('creates the temporal vendor_applicability table shape', () {
      expect(
        sql,
        contains('create table if not exists public.vendor_applicability'),
      );
      expect(
        sql,
        contains('operator_id uuid null references public.operators'),
      );
      expect(sql, contains('setting_kind text not null'));
      expect(sql, contains('setting_key text not null'));
      expect(sql, contains('vendor_slug text not null'));
      expect(sql, contains('enabled boolean not null default true'));
      expect(sql, contains("metadata jsonb not null default '{}'::jsonb"));
      expect(
        sql,
        contains('effective_from timestamptz not null default now()'),
      );
      expect(sql, contains('effective_until timestamptz'));
      expect(sql, contains('created_by uuid not null'));
    });

    test('pins split current-row and history uniqueness indexes', () {
      expect(sql, contains('vendor_applicability_history_operator_uq'));
      expect(sql, contains('vendor_applicability_history_global_uq'));
      expect(sql, contains('vendor_applicability_current_operator_uq'));
      expect(sql, contains('vendor_applicability_current_global_uq'));
      expect(
        sql,
        contains(
          'on public.vendor_applicability (\n'
          '    operator_id,\n'
          '    setting_kind,\n'
          '    setting_key,\n'
          '    vendor_slug,\n'
          '    effective_from',
        ),
      );
      expect(sql, contains('where operator_id is not null;'));
      expect(sql, contains('where operator_id is null;'));
      expect(
        sql,
        contains('where operator_id is not null and effective_until is null;'),
      );
      expect(
        sql,
        contains('where operator_id is null and effective_until is null;'),
      );
      expect(sql, isNot(contains('coalesce(operator_id')));
      expect(sql, contains('vendor_applicability_current_tenant_lookup_idx'));
      expect(sql, contains('vendor_applicability_current_global_lookup_idx'));
    });

    test('enables RLS through app_current_operator wrapper semantics', () {
      expect(
        sql,
        contains(
          'alter table public.vendor_applicability enable row level security',
        ),
      );
      expect(sql, contains('vendor_applicability_service_role_select'));
      expect(sql, contains('operator_id = public.app_current_operator()'));
      expect(sql, contains('operator_id is null'));
    });

    test('does not mutate existing audit log tables', () {
      expect(sql, isNot(contains('update public.audit_logs')));
      expect(sql, isNot(contains('update public.auth_events_audit')));
      expect(sql, isNot(contains('delete from public.audit_logs')));
      expect(sql, isNot(contains('delete from public.auth_events_audit')));
    });
  });
}
