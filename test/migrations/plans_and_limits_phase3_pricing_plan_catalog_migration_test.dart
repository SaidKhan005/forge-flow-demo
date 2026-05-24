// Plans & Limits V1 Phase 3 — pricing_plan_catalog migration test.
//
// Text-assertion coverage of the migration SQL (mirrors the repo's other
// migration tests, e.g. benchmark_overrides_hierarchy_migration_test.dart):
// the table + CHECK shape, the TIMESTAMPTZ column, the GLOBAL no-RLS /
// admin-pool grant posture, and the six-row seed matching the reconciled
// pricing model.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _path =
    'db/migrations/202605241100_plans_and_limits_phase3_pricing_plan_catalog.sql';

void main() {
  group('plans & limits phase 3 pricing_plan_catalog migration', () {
    late String sql;
    late String lower;

    setUpAll(() {
      final file = File(_path);
      expect(file.existsSync(), isTrue, reason: 'migration must exist');
      // Normalize CRLF -> LF so the `contains('...\n')` assertions hold on a
      // Windows autocrlf checkout (`.gitattributes` only forces eol=lf for
      // *.sh, not *.sql). Mirrors test/migrations/202605021500_rls_depth_test.dart.
      sql = file.readAsStringSync().replaceAll('\r\n', '\n');
      lower = sql.toLowerCase();
    });

    test('creates the GLOBAL pricing_plan_catalog table (idempotent)', () {
      expect(
        lower,
        contains('create table if not exists public.pricing_plan_catalog'),
      );
      expect(lower, contains('tier_key             text primary key'));
      // GLOBAL table: no operator_id / location_id COLUMN declaration. The
      // prose comment mentions the words in its no-RLS justification, so we
      // assert on the column-declaration shape (a leading column name +
      // type), not on the bare substring.
      expect(lower, isNot(contains('operator_id  ')));
      expect(lower, isNot(contains('location_id  ')));
      expect(lower, isNot(contains('operator_id text')));
      expect(lower, isNot(contains('operator_id uuid')));
    });

    test('pins tier_key to exactly the six locked plan keys via CHECK', () {
      expect(lower, contains('pricing_plan_catalog_tier_key_chk'));
      expect(
        lower,
        contains(
          "check (tier_key in ('pilot','starter','premium','elite','pro','enterprise'))",
        ),
      );
    });

    test('carries the editable pricing columns', () {
      expect(lower, contains('monthly_usd          numeric'));
      expect(lower, contains('first_n_seats        integer'));
      expect(lower, contains('first_seat_usd       numeric'));
      expect(lower, contains('additional_seat_usd  numeric'));
      expect(lower, contains('onboarding_min_usd   numeric'));
      expect(lower, contains('onboarding_max_usd   numeric'));
      expect(lower, contains('updated_by           text'));
    });

    test('uses timestamptz for updated_at and avoids naive timestamp', () {
      expect(
        lower,
        contains('updated_at           timestamptz not null default now()'),
      );
      expect(lower, isNot(contains('timestamp without time zone')));
    });

    test('is the admin-pool BYPASSRLS posture with no RLS policy', () {
      // GLOBAL catalog: no row-level security, mirrors
      // default_role_catalog_versions.
      expect(lower, isNot(contains('enable row level security')));
      expect(lower, isNot(contains('create policy')));
      expect(lower, contains('revoke all on public.pricing_plan_catalog from public'));
      expect(
        lower,
        contains('grant select\n  on public.pricing_plan_catalog to service_role'),
      );
      expect(
        lower,
        contains(
          'grant select, insert, update, delete\n  on public.pricing_plan_catalog to forge_admin',
        ),
      );
    });

    test('seeds all six plans on conflict do nothing', () {
      expect(lower, contains('insert into public.pricing_plan_catalog'));
      expect(lower, contains('on conflict (tier_key) do nothing'));
      for (final key in <String>[
        'pilot',
        'starter',
        'premium',
        'elite',
        'pro',
        'enterprise',
      ]) {
        expect(
          lower,
          contains("'$key'"),
          reason: 'seed must include the $key plan',
        );
      }
    });

    test('seed numbers match the reconciled pricing model', () {
      // Elite seat $10/$5, onboarding $1,500 to $3,500.
      expect(lower, contains("('elite',      250,  20,   10,   5,    1500, 3500)"));
      // Premium seat $5/$3, onboarding $750 to $2,000.
      expect(lower, contains("('premium',    250,  20,   5,    3,    750,  2000)"));
      // Pro seat $15/$8, onboarding $2,500 to $5,000.
      expect(lower, contains("('pro',        500,  20,   15,   8,    2500, 5000)"));
      // Starter $250/mo, no seat fee, onboarding $500 to $1,000.
      expect(lower, contains("('starter',    250,  null, null, null, 500,  1000)"));
      // Pilot free, self-serve.
      expect(lower, contains("('pilot',      0,    null, null, null, 0,    0)"));
      // Enterprise custom: all null.
      expect(
        lower,
        contains("('enterprise', null, null, null, null, null, null)"),
      );
    });

    test('bounds lock + statement timeouts', () {
      expect(lower, contains("set local statement_timeout = '30s'"));
      expect(lower, contains("set local lock_timeout = '5s'"));
    });
  });
}
