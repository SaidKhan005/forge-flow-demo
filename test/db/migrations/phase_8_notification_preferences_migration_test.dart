import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migration =
    'db/migrations/202605070400_phase_8_notification_preferences.sql';

void main() {
  group('phase 8 notification preferences migration', () {
    late String sql;

    setUpAll(() {
      final file = File(_migration);
      expect(file.existsSync(), isTrue);
      sql = file.readAsStringSync().replaceAll('\r\n', '\n').toLowerCase();
    });

    test('creates notification_preferences table with synthetic UUID PK', () {
      expect(
        sql,
        contains('create table if not exists public.notification_preferences'),
      );
      expect(
        sql,
        contains('id          uuid primary key default gen_random_uuid()'),
      );
      // No client-side UUIDs - the only PK strategy is server-side
      // gen_random_uuid().
      expect(sql, isNot(contains('uuid_generate_v4')));
    });

    test('pins operator_id, user_id, event_key, channel, scope_kind columns',
        () {
      expect(sql, contains('operator_id uuid not null'));
      expect(sql, contains('user_id     uuid not null'));
      expect(sql, contains('event_key   text not null'));
      expect(sql, contains("channel     text not null check (channel in ('push', 'email', 'inbox'))"));
      expect(
        sql,
        contains(
            "scope_kind  text not null check (scope_kind in ('operator', 'location'))"),
      );
      expect(sql, contains('scope_id    uuid null'));
      expect(sql, contains('enabled     boolean not null default true'));
    });

    test('creates UNIQUE NULLS NOT DISTINCT on the 6-tuple', () {
      // PK is the synthetic id; UNIQUE handles the (op, user, event,
      // channel, scope_kind, scope_id) collapse.
      expect(
        sql,
        contains('notification_preferences_unique_event_channel_scope_idx'),
      );
      expect(
        sql,
        contains(
            'on public.notification_preferences (\n    operator_id, user_id, event_key, channel, scope_kind, scope_id\n  )'),
      );
      expect(sql, contains('nulls not distinct'));
    });

    test('creates operator-leading B-tree indexes (CI lint)', () {
      expect(
        sql,
        contains('notification_preferences_operator_user_idx'),
      );
      expect(
        sql,
        contains('notification_preferences_operator_event_idx'),
      );
      // Both lead with operator_id.
      expect(sql, contains('on public.notification_preferences (operator_id, user_id)'));
      expect(sql, contains('on public.notification_preferences (operator_id, event_key)'));
    });

    test('enables RLS with wrapper-only per-tenant per-user policy', () {
      expect(
        sql,
        contains('alter table public.notification_preferences enable row level security'),
      );
      expect(
        sql,
        contains('create policy "notification_preferences_per_operator_per_user"'),
      );
      // Wrapper-only - no bare current_setting() reads.
      expect(sql, contains('public.app_current_operator()'));
      expect(sql, contains('public.app_current_actor_user()'));
      expect(
        sql,
        isNot(contains("current_setting('app.")),
        reason:
            'Phase 9.0Σ.b item 4 forbids bare current_setting() in policy bodies',
      );
      expect(
        sql,
        contains(
            'using (\n    operator_id = public.app_current_operator()\n    and user_id = public.app_current_actor_user()'),
      );
      expect(
        sql,
        contains(
            'with check (\n    operator_id = public.app_current_operator()\n    and user_id = public.app_current_actor_user()'),
      );
    });

    test('grants service_role + forge_admin and revokes from public', () {
      expect(sql, contains('revoke all on public.notification_preferences from public'));
      expect(
        sql,
        contains(
            'grant select, insert, update, delete\n  on public.notification_preferences to service_role'),
      );
      expect(
        sql,
        contains(
            'grant select, insert, update, delete\n  on public.notification_preferences to forge_admin'),
      );
    });

    test('runs in one transaction', () {
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
    });
  });
}
