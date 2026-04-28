// Phase 9 live-closeout - audit actor attribution migration coverage.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('auth_events_audit actor attribution live repair', () {
    final sql = File(
      'db/migrations/202604280013_phase_9_audit_actor_kind_live_repair.sql',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    test('adds actor_kind and service-principal attribution columns', () {
      expect(
        sql,
        contains(
          'add column if not exists actor_kind text not null default '
          "'user'",
        ),
      );
      expect(
        sql,
        contains('add column if not exists actor_service_principal_id uuid'),
      );
      expect(sql, contains("check (actor_kind in ('user', 'service'))"));
    });

    test('keeps service-principal lookup tenant-leading', () {
      expect(
        sql,
        contains(
          'on public.auth_events_audit (\n'
          '    operator_id,\n'
          '    actor_service_principal_id,\n'
          '    occurred_at desc\n'
          '  )',
        ),
      );
    });
  });
}
