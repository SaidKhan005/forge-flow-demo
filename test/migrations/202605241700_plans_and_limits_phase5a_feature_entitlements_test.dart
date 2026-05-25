// ignore_for_file: file_names
//
// Filename intentionally mirrors the migration filename
// (`db/migrations/202605241700_plans_and_limits_phase5a_feature_entitlements.sql`)
// so a reviewer can correlate test <-> migration at a glance. The Dart
// `file_names` lint rejects digit-leading filenames; ignoring it here is
// the project convention for test/migrations/<timestamp>_test.dart
// (mirrors test/migrations/202605241600_operator_trial_mode_test.dart).
//
// Plans & Limits V1 Phase 5a — feature_entitlements migration test.
//
// Text-assertion coverage of the migration SQL (mirrors the Phase 3
// pricing_plan_catalog migration test): the table + CHECK + composite PK
// shape, the TIMESTAMPTZ column, the GLOBAL no-RLS / admin-pool grant
// posture, and the cumulative-ladder seed matching the plan summaries.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _path =
    'db/migrations/202605241700_plans_and_limits_phase5a_feature_entitlements.sql';

void main() {
  group('plans & limits phase 5a feature_entitlements migration', () {
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

    test('creates the GLOBAL feature_entitlements table (idempotent)', () {
      expect(
        lower,
        contains('create table if not exists public.feature_entitlements'),
      );
      // GLOBAL table: no operator_id / location_id COLUMN declaration. The
      // prose comment mentions the words in its no-RLS justification, so we
      // assert on the column-declaration shape, not the bare substring.
      expect(lower, isNot(contains('operator_id text')));
      expect(lower, isNot(contains('operator_id uuid')));
      expect(lower, isNot(contains('location_id text')));
      expect(lower, isNot(contains('location_id uuid')));
    });

    test('keys on the composite (tier_key, feature_slug) primary key', () {
      expect(
        lower,
        contains('primary key (tier_key, feature_slug)'),
      );
    });

    test('pins tier_key to exactly the six locked plan keys via CHECK', () {
      expect(lower, contains('feature_entitlements_tier_key_chk'));
      expect(
        lower,
        contains(
          "check (tier_key in ('pilot','starter','premium','elite','pro','enterprise'))",
        ),
      );
    });

    test('rejects junk tier keys (not in the CHECK list)', () {
      // The CHECK list is the only allowed set; a junk key like "free" or
      // "platinum" must not appear in the constraint.
      final checkLine = RegExp(
        r"check \(tier_key in \(([^)]*)\)\)",
      ).firstMatch(lower)?.group(1);
      expect(checkLine, isNotNull);
      expect(checkLine, isNot(contains('free')));
      expect(checkLine, isNot(contains('platinum')));
      expect(checkLine, isNot(contains('launch')));
    });

    test('carries the enabled flag + audit columns', () {
      expect(lower, contains('enabled       boolean not null default false'));
      expect(lower, contains('feature_slug  text not null'));
      expect(lower, contains('updated_by    text'));
    });

    test('uses timestamptz for updated_at and avoids naive timestamp', () {
      expect(
        lower,
        contains('updated_at    timestamptz not null default now()'),
      );
      expect(lower, isNot(contains('timestamp without time zone')));
    });

    test('is the admin-pool BYPASSRLS posture with no RLS policy', () {
      // GLOBAL catalog: no row-level security, mirrors pricing_plan_catalog.
      expect(lower, isNot(contains('enable row level security')));
      expect(lower, isNot(contains('create policy')));
      expect(
        lower,
        contains('revoke all on public.feature_entitlements from public'),
      );
      expect(
        lower,
        contains(
          'grant select\n  on public.feature_entitlements to service_role',
        ),
      );
      expect(
        lower,
        contains(
          'grant select, insert, update, delete\n  on public.feature_entitlements to forge_admin',
        ),
      );
    });

    test('seeds the cumulative ladder on conflict do nothing', () {
      expect(lower, contains('insert into public.feature_entitlements'));
      expect(
        lower,
        contains('on conflict (tier_key, feature_slug) do nothing'),
      );
      // advisor on for the free Pilot preview + every paid tier.
      for (final tier in <String>[
        'pilot',
        'starter',
        'premium',
        'elite',
        'pro',
        'enterprise',
      ]) {
        expect(
          lower,
          contains("('$tier',"),
          reason: 'seed must include the $tier plan',
        );
      }
      // The six known feature slugs all appear in the seed.
      for (final slug in <String>[
        'advisor',
        'lms',
        'scoreboard',
        'staff_coach',
        'sops',
        'workflows',
      ]) {
        expect(
          lower,
          contains("'$slug'"),
          reason: 'seed must reference the $slug feature',
        );
      }
    });

    test('seeds the ladder rows that match the plan summaries', () {
      // advisor: pilot + every paid tier.
      expect(lower, contains("('pilot',      'advisor',     true)"));
      expect(lower, contains("('enterprise', 'advisor',     true)"));
      // lms/scoreboard: premium and up (premium is the lowest that adds it).
      expect(lower, contains("('premium',    'lms',         true)"));
      expect(lower, contains("('premium',    'scoreboard',  true)"));
      // staff_coach/sops: elite and up.
      expect(lower, contains("('elite',      'staff_coach', true)"));
      expect(lower, contains("('elite',      'sops',        true)"));
      // workflows: pro and up.
      expect(lower, contains("('pro',        'workflows',   true)"));
      expect(lower, contains("('enterprise', 'workflows',   true)"));
    });

    test('does NOT seed below-ladder rows (cumulative, off by default)', () {
      // Starter does not include LMS / scoreboard / staff_coach / sops /
      // workflows in the default seed (those rows are simply absent and
      // therefore default to enabled=false). Assert the absence of the
      // explicit Starter rows for the higher features.
      expect(lower, isNot(contains("('starter',    'lms',")));
      expect(lower, isNot(contains("('starter',    'workflows',")));
      // Premium does not include staff_coach / sops / workflows by default.
      expect(lower, isNot(contains("('premium',    'staff_coach',")));
      expect(lower, isNot(contains("('premium',    'workflows',")));
    });

    test('bounds lock + statement timeouts', () {
      expect(lower, contains("set local statement_timeout = '30s'"));
      expect(lower, contains("set local lock_timeout = '5s'"));
    });
  });
}
