import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mobile push notifications migration', () {
    late String sql;

    setUpAll(() {
      sql = File(
        'db/migrations/202605060000_mobile_push_notifications.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test(
      'creates encrypted token storage without a plaintext token column',
      () {
        expect(
          sql,
          contains('create table if not exists public.mobile_push_tokens'),
        );
        expect(sql, contains('token_hash text not null'));
        expect(sql, contains("token_hash ~ '^[0-9a-f]{64}\$'"));
        expect(sql, contains('token_ciphertext bytea not null'));
        expect(sql, isNot(contains('token_plaintext')));
        expect(sql, contains('MOBILE_PUSH_TOKEN_ENVELOPE_KEY'));
      },
    );

    test(
      'stores operator/user scope plus platform and app environment axes',
      () {
        expect(sql, contains('operator_id uuid not null'));
        expect(sql, contains('user_id uuid not null'));
        expect(sql, contains("platform in ('ios', 'android')"));
        expect(sql, contains("provider in ('fcm', 'apns')"));
        expect(sql, contains('app_variant text not null'));
        expect(sql, contains('app_environment text not null'));
        expect(sql, contains('mobile_push_tokens_operator_user_fk'));
        expect(sql, contains('references public.users(operator_id, user_id)'));
      },
    );

    test('adds durable push outbox sidecar linked to event_outbox', () {
      expect(
        sql,
        contains('create table if not exists public.mobile_push_outbox'),
      );
      expect(sql, contains('source_outbox_id bigint null'));
      expect(sql, contains('references public.event_outbox(id)'));
      expect(sql, contains('mobile_push_outbox_pending_idx'));
      expect(sql, contains("status in ('pending', 'partial_failed')"));
      expect(sql, contains('mobile_push_outbox_dedupe_uq'));
    });

    test('uses wrapper-only tenant RLS and operator-leading indexes', () {
      expect(
        sql,
        contains(
          'alter table public.mobile_push_tokens enable row level security',
        ),
      );
      expect(
        sql,
        contains(
          'alter table public.mobile_push_outbox enable row level security',
        ),
      );
      expect(sql, contains('operator_id = public.app_current_operator()'));
      expect(sql, isNot(contains('current_setting(')));
      expect(sql, contains('on public.mobile_push_tokens (\n    operator_id,'));
      expect(sql, contains('on public.mobile_push_outbox (\n    operator_id,'));
    });
  });
}
