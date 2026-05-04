// Phase 8.0.lifecycle — migration shape test for
// `db/migrations/202605040400_phase_8_0_lifecycle_add_vendor_lifecycle_notification.sql`.
//
// Pattern mirrors `test/db/migrations/auth_login_attempts_index_rekey_test.dart`:
// SQL is read as text and substring-asserted. The test does NOT spin
// up a Postgres instance; it locks the migration shape (table cols,
// UNIQUE constraint, RLS posture, wrapper-only policy, index lead
// column, TIMESTAMPTZ usage) so review can fail fast if the
// migration is edited away from the contract.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String sql;

  setUpAll(() {
    sql = File(
      'db/migrations/202605040400_phase_8_0_lifecycle_add_vendor_lifecycle_notification.sql',
    ).readAsStringSync().replaceAll('\r\n', '\n').toLowerCase();
  });

  group('vendor_lifecycle_notification table', () {
    test('table is created idempotently', () {
      expect(
        sql,
        contains(
          'create table if not exists public.vendor_lifecycle_notification',
        ),
      );
    });

    test('declares the binding columns from the contract', () {
      expect(sql, contains('notification_id uuid primary key'));
      expect(sql, contains('default gen_random_uuid()'));
      expect(sql, contains('operator_id uuid not null'));
      expect(sql, contains('vendor_id text not null'));
      expect(sql, contains('email text not null'));
      expect(sql, contains('requested_at timestamptz not null default now()'));
      expect(sql, contains('notified_at timestamptz'));
    });

    test(
      'foreign-keys operator_id to public.operators per RLS-Ready Schema',
      () {
        expect(
          sql,
          contains('references public.operators(operator_id)'),
          reason:
              'operator_id must FK to operators(operator_id) so '
              'cascade-delete cleans up notification rows when an '
              'operator is purged.',
        );
        expect(sql, contains('on delete cascade'));
      },
    );

    test(
      'uses TIMESTAMPTZ (UTC) per Phase 7.55 time boundary contract — '
      'TIMESTAMP WITHOUT TIME ZONE is banned in operator-scoped tables',
      () {
        expect(sql, isNot(contains('timestamp without time zone')));
        // Spot-check there is no bare `timestamp` column (every
        // timestamp column must carry the `tz` suffix).
        final tzMatches = 'timestamptz'.allMatches(sql).length;
        expect(tzMatches, greaterThanOrEqualTo(2));
      },
    );
  });

  group('UNIQUE constraint + indexes', () {
    test(
      'UNIQUE on (operator_id, vendor_id, email) per the slice contract',
      () {
        expect(
          sql,
          contains(
            'create unique index if not exists vendor_lifecycle_notification_uniq\n'
            '  on public.vendor_lifecycle_notification (operator_id, vendor_id, email)',
          ),
          reason:
              'Same email signing up twice for the same vendor on the '
              'same operator must be a no-op.',
        );
      },
    );

    test(
      'primary B-tree leads with operator_id (RLS-Ready Schema rule)',
      () {
        // The UNIQUE serves as the primary B-tree per CLAUDE.md /
        // 9.0Σ.b item 4. Lock the lead column.
        expect(
          sql,
          contains(
            'on public.vendor_lifecycle_notification (operator_id, vendor_id, email)',
          ),
        );
      },
    );

    test('cron-lookup index is partial on notified_at IS NULL', () {
      expect(
        sql,
        contains(
          'create index if not exists vendor_lifecycle_notification_pending_idx\n'
          '  on public.vendor_lifecycle_notification (operator_id, vendor_id)\n'
          '  where notified_at is null',
        ),
      );
    });
  });

  group('RLS policy stub', () {
    test('row-level security is enabled', () {
      expect(
        sql,
        contains(
          'alter table public.vendor_lifecycle_notification enable row level security',
        ),
      );
    });

    test('policy is dropped before being recreated (idempotent)', () {
      expect(
        sql,
        contains(
          'drop policy if exists "vendor_lifecycle_notification_per_tenant"',
        ),
      );
    });

    test(
      'policy uses the wrapper function app_current_operator() — bare '
      'current_setting() is banned by the wrapper-only RLS posture',
      () {
        expect(
          sql,
          contains('using (operator_id = public.app_current_operator())'),
        );
        expect(
          sql,
          contains(
            'with check (operator_id = public.app_current_operator())',
          ),
        );
        expect(
          sql,
          isNot(contains("current_setting('app.")),
          reason:
              'Wrapper-only RLS posture forbids bare current_setting() reads.',
        );
      },
    );

    test('policy is scoped to the service_role', () {
      expect(
        sql,
        contains(
          'create policy "vendor_lifecycle_notification_per_tenant"\n'
          '  on public.vendor_lifecycle_notification for all to service_role',
        ),
      );
    });
  });

  group('Grants', () {
    test('public is revoked, service_role + forge_admin granted', () {
      expect(
        sql,
        contains('revoke all on public.vendor_lifecycle_notification from public'),
      );
      expect(
        sql,
        contains(
          'grant select, insert, update on public.vendor_lifecycle_notification\n'
          '  to service_role',
        ),
      );
      expect(
        sql,
        contains(
          'grant select, insert, update on public.vendor_lifecycle_notification\n'
          '  to forge_admin',
        ),
      );
    });

    test('delete is NOT granted (notifications are append/update only)', () {
      expect(
        sql,
        isNot(contains(
          'grant select, insert, update, delete on public.vendor_lifecycle_notification',
        )),
        reason:
            'Notifications log a subscription request + the notify '
            'fan-out timestamp; rows are never explicitly deleted. '
            'Cascade from operators(operator_id) cleans them up on '
            'operator purge.',
      );
    });
  });

  group('Migration hygiene', () {
    test('wraps the migration body in a transaction', () {
      expect(sql, contains('begin;'));
      expect(sql, contains('commit;'));
    });

    test(
      'comment on table cites the surface-design doc for the "Notify '
      'me when ready" flow',
      () {
        expect(
          sql,
          contains(
            'docs/phases/phase_8/vendor_connections_admin_surface.md',
          ),
        );
      },
    );
  });
}
