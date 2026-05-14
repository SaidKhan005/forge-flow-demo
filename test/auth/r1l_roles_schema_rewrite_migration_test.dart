// Wave 2 R-1L — Roles schema rewrite migration shape tests.
//
// Pins the shape of
// `db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql`
// so the implementation cannot silently drift away from the slice
// contract.
//
// Coverage:
//   1. The migration file lex-orders after the current cutoff
//      (`202605131900_c_2_d_vendor_sync_outage_state.sql`).
//   2. The migration adds the four new columns to
//      `public.permission_keys` as NULLABLE (expand-only; NOT NULL
//      flip deferred to R-1L-FU follow-up).
//   3. The CHECK constraint on scope_kind covers exactly
//      `org_wide` / `location_scoped` / `either`.
//   4. The backfill is fail-loud (the DO block raises if any row is
//      left without product_label / category_label / scope_kind).
//   5. The seed for the existing 103 keys covers every product_label
//      / category_label / scope_kind value that the Dart metadata
//      mirror requires.
//   6. The migration carries the standard local statement / lock
//      timeouts.
//   7. The migration is idempotent (`add column if not exists`
//      everywhere).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Wave 2 R-1L roles schema rewrite migration shape', () {
    late String migration;

    setUpAll(() {
      migration = File(
        'db/migrations/202605142100_phase_R_1L_roles_schema_rewrite.sql',
      ).readAsStringSync().replaceAll('\r\n', '\n');
    });

    test('migration file exists with the slice-named timestamp slot', () {
      final names = Directory('db/migrations')
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.sql'))
          .toList()
        ..sort();
      expect(
        names,
        contains('202605142100_phase_R_1L_roles_schema_rewrite.sql'),
      );
      // Lex-orders after C-2-D.
      final idx = names.indexOf(
        '202605142100_phase_R_1L_roles_schema_rewrite.sql',
      );
      final cdIdx = names.indexOf(
        '202605131900_c_2_d_vendor_sync_outage_state.sql',
      );
      expect(idx, greaterThan(cdIdx));
    });

    test('adds the four R-1L columns idempotently', () {
      for (final stmt in const <String>[
        'add column if not exists product_label text',
        'add column if not exists category_label text',
        'add column if not exists scope_kind text',
        // `implies` is added with a NOT NULL DEFAULT '{}' on this
        // small frozen catalog — safe because the DEFAULT carries
        // through to existing rows without a heap rewrite (PG12+).
        "add column if not exists implies text[] not null default '{}'::text[]",
      ]) {
        expect(
          migration,
          contains(stmt),
          reason: 'missing `$stmt`',
        );
      }
    });

    test(
      'product_label / category_label / scope_kind ship NULLABLE — '
      'NOT NULL flip deferred to R-1L-FU follow-up',
      () {
        // Defense-in-depth: confirm no SET NOT NULL on these columns
        // appears in the file. The drift scanner's expand-contract
        // lint also enforces this for migrations after the
        // grandfather cutoff.
        expect(
          migration,
          isNot(contains('alter column product_label set not null')),
        );
        expect(
          migration,
          isNot(contains('alter column category_label set not null')),
        );
        expect(
          migration,
          isNot(contains('alter column scope_kind set not null')),
        );
      },
    );

    test('scope_kind CHECK constraint covers exactly the three values', () {
      // Compact-whitespace match so multi-line formatting does not
      // break the assertion.
      final compact = migration.replaceAll(RegExp(r'\s+'), ' ');
      expect(
        compact,
        contains(
          "check (scope_kind is null or scope_kind in "
          "('org_wide', 'location_scoped', 'either'))",
        ),
      );
    });

    test('backfill is fail-loud on coverage gaps', () {
      expect(
        migration,
        contains(
          "raise exception\n      'R-1L backfill left % "
          'permission_keys rows without product_label / ',
        ),
      );
    });

    test('every existing catalog key category appears in the backfill', () {
      // Spot-check one key per category — if these are missing then
      // the backfill cannot have populated all rows and the fail-loud
      // DO block above would have tripped at migration apply time.
      // We still pin them at the unit-test layer so the assertion
      // catches accidental seed deletions in PR review before apply.
      const sampleCategoriesToProductLabel = <String, String>{
        'product': 'product',
        'forgeflow': 'forgeflow',
        'barrio': 'barrio',
        'admin': 'admin',
        'team': 'team',
        'account': 'account',
        'business_timing': 'business_timing',
        'billing': 'billing',
        'integration': 'integration',
        'integrations': 'integration',
        'workflow': 'workflow',
      };
      for (final entry in sampleCategoriesToProductLabel.entries) {
        expect(
          migration,
          contains("when '${entry.key}'"),
          reason: 'category ${entry.key} missing from product_label CASE',
        );
        expect(
          migration,
          contains("then '${entry.value}'"),
          reason: 'product_label ${entry.value} missing from CASE',
        );
      }
    });

    test('org_wide backfill covers the org-wide subset', () {
      // Pin a representative subset (one per group from
      // kOrgWidePermissionKeys). Catches accidental deletions in PR
      // review.
      const sampleOrgWideKeys = <String>[
        "'account.configure'",
        "'business_timing.configure'",
        "'billing.invoice.view'",
        "'admin.pricing_tier.view'",
        "'integrations.configure'",
        "'integration.toast.connect'",
        "'integration.key_rotate'",
      ];
      for (final key in sampleOrgWideKeys) {
        expect(
          migration,
          contains(key),
          reason: 'org_wide backfill missing key $key',
        );
      }
    });

    test('implies backfill covers the view-required-for-write pairs', () {
      // Pin a representative subset. The Dart-side mirror test in
      // `permission_key_metadata_test.dart` covers full
      // kViewRequiredForWrite coverage; this test catches gross
      // deletions in PR review.
      const samples = <String, String>{
        "where key = 'forgeflow.shift.edit'":
            "array['forgeflow.shift.view']",
        "where key = 'team.users.invite'": "array['team.users.view']",
        "where key = 'team.session.force_logout'":
            "array['team.users.view']",
        "where key = 'admin.audit_log.export'":
            "array['admin.audit_log.view']",
      };
      samples.forEach((whereClause, impliesArray) {
        expect(
          migration,
          contains(impliesArray),
          reason: 'implies array $impliesArray missing',
        );
        expect(
          migration,
          contains(whereClause),
          reason: 'implies WHERE clause `$whereClause` missing',
        );
      });
    });

    test('carries the standard local statement / lock timeouts', () {
      expect(migration, contains("set local statement_timeout = '30s'"));
      expect(migration, contains("set local lock_timeout = '5s'"));
    });
  });
}
