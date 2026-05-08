// ignore_for_file: file_names
//
// Filename intentionally mirrors the migration filename
// (`db/migrations/202605082000_user_pii_erasure_requests.sql`) so a
// reviewer can correlate test ↔ migration at a glance. The Dart
// `file_names` lint rejects digit-leading filenames; ignoring it here
// is the project convention for `test/migrations/<timestamp>_test.dart`.
//
// CODE_OPS_DEBT Theme B#1 — single-admin PII erasure migration shape
// coverage. Asserts the on-disk migration declares the durable
// erasure-request ledger, the operator-leading partial indexes, the
// RLS policy stub, the cron NOTIFY tick function + scheduled job, and
// the per-row CHECK constraints called out in the lane prompt.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migrationSql = _readSqlNormalized(
    'db/migrations/202605082000_user_pii_erasure_requests.sql',
  );

  group('CODE_OPS_DEBT Theme B#1 — user_pii_erasure_requests migration',
      () {
    test('declares the user_pii_erasure_requests ledger table', () {
      expect(
        migrationSql,
        contains(
          'create table if not exists public.user_pii_erasure_requests',
        ),
        reason:
            'the durable erasure ledger is the seam between the '
            'POST .../erase-pii route and the grace-window worker',
      );
      // Required columns (per lane prompt + repository):
      for (final column in const <String>[
        'erasure_id uuid primary key',
        'operator_id uuid not null',
        'user_id uuid not null',
        'requested_by_user_id uuid not null',
        'requested_at timestamptz',
        'business_date date not null',
        'grace_period_ends_at timestamptz not null',
        'applied_at timestamptz null',
        'reversed_at timestamptz null',
        'reversed_by_user_id uuid null',
        'reversal_reason text null',
        'pii_snapshot jsonb not null',
      ]) {
        expect(
          migrationSql,
          contains(column),
          reason: 'column declaration missing or renamed: `$column`',
        );
      }
    });

    test('captures the per-row CHECK constraints', () {
      // Grace window cannot be set in the past (sanity / clock-skew
      // guard); applied + reversed are mutually exclusive; reversal
      // requires a reverser actor.
      expect(
        migrationSql,
        contains('check (grace_period_ends_at >= requested_at)'),
        reason:
            'CHECK enforces non-negative grace window so a typo cannot '
            'set ends_at before requested_at',
      );
      expect(
        migrationSql,
        contains('check (applied_at is null or reversed_at is null)'),
        reason:
            'CHECK enforces mutual exclusion between apply / reverse '
            'terminal stamps',
      );
      expect(
        migrationSql,
        contains('reversed_at is null'),
        reason:
            'reversal CHECK guard depends on reversed_at being NULL '
            'when the row is still pending',
      );
    });

    test('declares the three operator-leading partial / sort indexes',
        () {
      // 1) pending-only uniqueness — at most one in-flight erasure per
      //    (operator_id, user_id).
      expect(
        migrationSql,
        contains(
          'create unique index if not exists user_pii_erasure_active_idx',
        ),
        reason:
            'partial unique index enforces single in-flight erasure '
            'per (operator_id, user_id); proxy maps UNIQUE violation '
            'to 409',
      );
      expect(
        migrationSql,
        contains('on public.user_pii_erasure_requests (operator_id, user_id)'),
        reason:
            'the active-idx must lead with (operator_id, user_id) per '
            'the RLS performance discipline',
      );
      expect(
        migrationSql,
        contains(
          'where applied_at is null and reversed_at is null',
        ),
        reason:
            'the partial predicate confines the index to active rows '
            'so a fresh erasure can be issued after a prior one '
            'terminates',
      );

      // 2) Worker claim path — operator-leading sort by
      //    grace_period_ends_at.
      expect(
        migrationSql,
        contains('user_pii_erasure_due_idx'),
        reason: 'worker claim index must exist',
      );

      // 3) Status-read path — operator+user with requested_at desc.
      expect(
        migrationSql,
        contains('user_pii_erasure_recent_idx'),
        reason: 'GET status read needs an operator+user+desc index',
      );
    });

    test('enables RLS and declares the per-tenant policy', () {
      expect(
        migrationSql.toLowerCase(),
        contains(
          'alter table public.user_pii_erasure_requests enable row level '
          'security',
        ),
        reason:
            'RLS must be enabled from creation per CLAUDE.md '
            '"RLS-Ready Schema" (no per-row policy is the default; '
            'the explicit ALTER pins the locked posture)',
      );
      expect(
        migrationSql,
        contains('user_pii_erasure_requests_per_operator'),
        reason:
            'per-operator RLS policy stub must exist with the '
            'wrapper-based predicate',
      );
      expect(
        migrationSql,
        contains('app_current_operator()'),
        reason:
            'policy must call the 9.0Σ.b STABLE LEAKPROOF wrapper '
            'function — never bare current_setting',
      );
    });

    test('registers the pg_cron tick function + scheduled job', () {
      expect(
        migrationSql,
        contains(
          'create or replace function public.pii_erasure_grace_expired_tick',
        ),
        reason:
            'cron-callable wake-up signal must be defined as a function '
            'so cron.schedule can fire it once per minute',
      );
      expect(
        migrationSql,
        contains(
          "pg_notify(\n    'pii_erasure_grace_expired_tick'",
        ),
        reason:
            'the function emits NOTIFY on the channel the proxy '
            'PgCronNotifyConsumer subscribes to',
      );
      expect(
        migrationSql,
        contains("'forge_pii_erasure_grace_expired_tick'"),
        reason:
            'the named cron job must exist so a re-apply can find + '
            'reschedule it',
      );
      expect(
        migrationSql,
        contains("'* * * * *'"),
        reason:
            'cron schedule must be every minute so a row that crosses '
            'its grace window does not wait > 60s for apply',
      );
    });
  });
}

/// Reads [path] and collapses CRLF to LF so multi-line `contains(...)`
/// assertions work on Windows checkouts (default `core.autocrlf=true`)
/// as well as on Linux/macOS CI runners.
String _readSqlNormalized(String path) {
  return File(path).readAsStringSync().replaceAll('\r\n', '\n');
}
