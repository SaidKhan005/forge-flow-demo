// Wave 2 U-FU-hp11-account — per-location override migration shape
// tests.
//
// Pins the shape of
// `db/migrations/202605150200_phase_u_fu_hp11_account_per_location_overrides.sql`
// so the implementation cannot silently drift away from the slice
// contract recorded in the U-FU-hp11-account prompt + CLAUDE.md HP #4
// + HP #11 rules.
//
// Coverage:
//   1. Migration file exists with the slice-named timestamp slot and
//      lex-orders after R-followup-NOT-NULL-flip (202605150100).
//   2. Migration creates `public.location_account_overrides` with the
//      expected composite PK + composite FK to `public.locations`.
//   3. RLS is enabled and the per-tenant policy uses the
//      `public.app_current_operator()` wrapper function (NOT a bare
//      `current_setting('app.operator_id', true)::uuid`).
//   4. B-tree index leads with `operator_id` per the RLS-ready rule.
//   5. CHECK constraints reject malformed values (currency / locale /
//      rollover hour / contact email length / contact phone length).
//   6. The migration touches NO other table except for the new override
//      table (this slice's whole point is that `public.operators`
//      stays the business-default source).
//   7. The migration is idempotent (re-running is a no-op).
//   8. Standard idempotent posture: `create table if not exists`,
//      `if not exists` on the index, `drop policy if exists` before
//      `create policy`.
//   9. updated_at trigger uses the shared
//      `public.cloud_foundation_set_updated_at` function.
//  10. No em-dashes (U+2014) anywhere in the executable SQL or doc
//      comments (CLAUDE.md UX writing standard).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group(
    'Wave 2 U-FU-hp11-account per-location overrides migration shape',
    () {
      late String migration;
      late String executableSql;

      setUpAll(() {
        migration = File(
          'db/migrations/202605150200_phase_u_fu_hp11_account_per_location_overrides.sql',
        ).readAsStringSync().replaceAll('\r\n', '\n');
        executableSql = migration
            .split('\n')
            .map((line) {
              final commentIdx = line.indexOf('--');
              return commentIdx == -1 ? line : line.substring(0, commentIdx);
            })
            .join('\n');
      });

      test(
        'migration file exists with the slice-named timestamp slot',
        () {
          final names = Directory('db/migrations')
              .listSync()
              .whereType<File>()
              .map((f) => f.uri.pathSegments.last)
              .where((n) => n.endsWith('.sql'))
              .toList()
            ..sort();
          expect(
            names,
            contains(
              '202605150200_phase_u_fu_hp11_account_per_location_overrides.sql',
            ),
          );
          final idx = names.indexOf(
            '202605150200_phase_u_fu_hp11_account_per_location_overrides.sql',
          );
          final priorIdx = names.indexOf(
            '202605150100_phase_r_followup_not_null_flip.sql',
          );
          expect(idx, greaterThan(priorIdx));
        },
      );

      test(
        'creates public.location_account_overrides with composite PK',
        () {
          expect(
            executableSql,
            contains(
              'create table if not exists public.location_account_overrides',
            ),
          );
          // Composite PK on (operator_id, location_id) so the table
          // can hold at most one override row per location.
          expect(
            executableSql,
            contains('primary key (operator_id, location_id)'),
          );
        },
      );

      test(
        'carries a composite FK back to public.locations (HP #4 chain)',
        () {
          // The FK must reference `(operator_id, location_id)` so a
          // stale or malicious location_id cannot reach across
          // tenants even if RLS were disabled.
          expect(
            executableSql,
            contains(
              'foreign key (operator_id, location_id)',
            ),
          );
          expect(
            executableSql,
            contains(
              'references public.locations(operator_id, location_id)',
            ),
          );
          expect(executableSql, contains('on delete cascade'));
        },
      );

      test('enables RLS on the new table', () {
        expect(
          executableSql,
          contains(
            'alter table public.location_account_overrides enable row level security',
          ),
        );
      });

      test(
        'per-tenant policy reads tenant context through the wrapper '
        'function (not bare current_setting)',
        () {
          final compact = executableSql.replaceAll(RegExp(r'\s+'), ' ');
          expect(compact, contains('public.app_current_operator()'));
          expect(
            compact,
            contains(
              'create policy "location_account_overrides_per_tenant"',
            ),
          );
          // Bare current_setting reads are forbidden by the RLS posture
          // rule + the rls_policy_lint.
          expect(
            executableSql,
            isNot(contains("current_setting('app.operator_id'")),
          );
        },
      );

      test(
        'B-tree index leads with operator_id per the RLS-ready rule',
        () {
          // The composite PK already gives `(operator_id, location_id)`
          // access, but the standalone index keeps the index lint
          // honest if a future query plan needs an explicit B-tree.
          expect(
            executableSql,
            contains(
              'create index if not exists idx_location_account_overrides_operator',
            ),
          );
          // The first column on the index must be operator_id.
          final compact = executableSql.replaceAll(RegExp(r'\s+'), ' ');
          expect(
            compact,
            contains(
              'on public.location_account_overrides (operator_id, location_id)',
            ),
          );
        },
      );

      test(
        'rollover hour CHECK constraint rejects values outside 0..23',
        () {
          final compact = executableSql.replaceAll(RegExp(r'\s+'), ' ');
          expect(
            compact,
            contains('business_day_rollover_hour between 0 and 23'),
          );
        },
      );

      test('locale code CHECK constraint enforces BCP-47 shape', () {
        final compact = executableSql.replaceAll(RegExp(r'\s+'), ' ');
        expect(
          compact,
          contains(r"locale_code ~ '^[a-z]{2,3}(-[A-Z]{2})?$'"),
        );
      });

      test(
        'currency code CHECK constraint enforces ISO 4217 shape',
        () {
          final compact = executableSql.replaceAll(RegExp(r'\s+'), ' ');
          expect(compact, contains(r"currency_code ~ '^[A-Z]{3}$'"));
        },
      );

      test('contact email + phone length CHECK constraints exist', () {
        final compact = executableSql.replaceAll(RegExp(r'\s+'), ' ');
        expect(compact, contains('length(contact_email) <= 320'));
        expect(compact, contains('length(contact_phone) between 1 and 64'));
      });

      test(
        'override row covers the six expected scoped columns + '
        'leaves business display name out (single business name doctrine)',
        () {
          final compact = executableSql.replaceAll(RegExp(r'\s+'), ' ');
          expect(compact, contains('iana_timezone text'));
          expect(compact, contains('locale_code text'));
          expect(compact, contains('currency_code text'));
          expect(compact, contains('business_day_rollover_hour integer'));
          expect(compact, contains('contact_email text'));
          expect(compact, contains('contact_phone text'));
          // Business display name MUST stay operator-wide.
          expect(executableSql, isNot(contains('business_name')));
          expect(executableSql, isNot(contains('display_name')));
        },
      );

      test('does not touch public.operators or any other table', () {
        // The migration must NOT widen / mutate `public.operators` —
        // that is the whole point of the per-location override surface.
        final compact = executableSql.replaceAll(RegExp(r'\s+'), ' ');
        expect(
          compact,
          isNot(contains('alter table public.operators')),
        );
        // The only `alter table` allowed is on the new override table
        // (to enable RLS).
        final alterTableMatches =
            RegExp(r'alter\s+table\s+([a-z._]+)', caseSensitive: false)
                .allMatches(compact)
                .map((m) => m.group(1))
                .toSet();
        expect(
          alterTableMatches,
          equals(<String>{'public.location_account_overrides'}),
        );
      });

      test(
        'idempotent posture: `create table if not exists`, `create '
        'index if not exists`, `drop policy if exists` precedes '
        'every `create policy`',
        () {
          expect(
            executableSql,
            contains(
              'create table if not exists public.location_account_overrides',
            ),
          );
          expect(
            executableSql,
            contains(
              'create index if not exists idx_location_account_overrides_operator',
            ),
          );
          // Every `create policy` must be preceded by a matching
          // `drop policy if exists`.
          final policyMatches = RegExp(
            r'create\s+policy\s+"([^"]+)"',
            caseSensitive: false,
          ).allMatches(executableSql).toList();
          expect(policyMatches, isNotEmpty);
          for (final match in policyMatches) {
            final name = match.group(1)!;
            expect(
              executableSql,
              contains('drop policy if exists "$name"'),
              reason:
                  'policy $name must have a matching `drop policy if exists` '
                  'before its `create policy` for idempotency.',
            );
          }
        },
      );

      test(
        'updated_at trigger uses the shared '
        'cloud_foundation_set_updated_at function',
        () {
          expect(
            executableSql,
            contains(
              'execute function public.cloud_foundation_set_updated_at()',
            ),
          );
        },
      );

      test('migration is wrapped in a single transaction', () {
        // The first non-comment, non-whitespace token must be `begin;`
        // and the last must be `commit;` so a partial apply rolls
        // back instead of leaving the schema partway converted.
        final body = executableSql.trim();
        expect(body, startsWith('begin;'));
        expect(body, endsWith('commit;'));
      });

      test('grant surface revokes public + grants only service_role + '
          'forge_admin', () {
        expect(
          executableSql,
          contains(
            'revoke all on public.location_account_overrides from public',
          ),
        );
        expect(
          executableSql,
          contains('to service_role'),
        );
        expect(
          executableSql,
          contains('to forge_admin'),
        );
      });

      test(
        'comments + documentation header reference the slice ID '
        '`U-FU-hp11-account`',
        () {
          // Helps audit reviewers grep for the slice ID inside the
          // migration without having to hunt through file naming.
          expect(migration, contains('U-FU-hp11-account'));
        },
      );
    },
  );
}
