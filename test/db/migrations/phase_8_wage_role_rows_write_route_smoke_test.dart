// Phase 8 W5.A.1 — write-route smoke test for wage_role_rows.
//
// The Postgres write surface (POST/DELETE) added in W5.A.1 depends on
// specific properties of the migration that landed via
// `db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql`:
//
//   * UUID PK (`wage_role_row_id`) so the proxy upsert RETURNING
//     surfaces a server-generated id.
//   * UNIQUE on (operator_id, location_id, restaurant_id, role_name)
//     so `INSERT … ON CONFLICT (…)` collapses cleanly without a
//     client-side UUID.
//   * CHECK constraints on `labor_bucket` / `source` / numeric ranges
//     that the route's body validator must mirror.
//   * `is_active boolean default true` so soft-delete ("set is_active
//     = false") hides rows from the read path.
//   * RLS posture matches the rest of the operator-scoped fact tables
//     so `withTenant` admits the row.
//
// This file is text-assertion only — it pins the migration's surface
// area against what the route handler expects so a future migration
// edit that drops the unique key, relaxes the CHECK list, or removes
// the soft-delete column breaks here BEFORE production drops the
// guarantee.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationPath =
    'db/migrations/202605080200_phase_8_wage_role_rows_server_truth.sql';

String _stripLineComments(String input) {
  final buffer = StringBuffer();
  for (final line in const LineSplitter().convert(input)) {
    if (line.trimLeft().startsWith('--')) continue;
    buffer.writeln(line);
  }
  return buffer.toString();
}

void main() {
  final raw = File(_migrationPath).readAsStringSync();
  final migration = _stripLineComments(raw);
  final normalized = migration.toLowerCase();
  final compact = normalized.replaceAll(RegExp(r'\s+'), ' ');

  group('Phase 8 wage_role_rows write-route smoke', () {
    test(
      'migration carries the UUID PK + natural-key UNIQUE the upsert '
      'route depends on',
      () {
        // Server-generated UUID PK so the proxy never hands a
        // client-side id to the table (CLAUDE.md hard rule).
        expect(
          normalized,
          contains('wage_role_row_id uuid primary key default gen_random_uuid()'),
        );
        // Natural-key UNIQUE for the ON CONFLICT target. The order
        // of columns in the unique index is what the route's
        // ON CONFLICT clause names verbatim.
        expect(
          compact,
          contains(
            'on public.wage_role_rows ( operator_id, location_id, '
            'restaurant_id, role_name )',
          ),
        );
      },
    );

    test('CHECK constraints match the route body validator', () {
      // labor_bucket — the route rejects anything outside this set
      // with `invalid_labor_bucket` 400.
      expect(
        normalized,
        contains("labor_bucket in ('foh', 'boh', 'manager')"),
      );
      // source — the route rejects anything outside this set with
      // `invalid_source` 400.
      for (final allowed in <String>[
        "'operator_manual'",
        "'vendor_per_position'",
        "'admin_seed'",
        "'migration_seed'",
      ]) {
        expect(normalized, contains(allowed));
      }
      // hourly_rate / weighted_hours — the route rejects values
      // outside [0, 10000] with `invalid_*` 400.
      expect(
        normalized,
        contains('check (hourly_rate >= 0 and hourly_rate <= 10000)'),
      );
      expect(
        normalized,
        contains('check (weighted_hours >= 0 and weighted_hours <= 10000)'),
      );
    });

    test('soft-delete column shape matches the DELETE route', () {
      // The DELETE route flips `is_active = false`; the read path
      // (`fetchWageRoleRows`) filters `is_active is true`. Both
      // require the boolean column with a default of true.
      expect(normalized, contains('is_active boolean not null default true'));
      // updated_by carries the actor id the route SETs when soft-
      // deleting.
      expect(normalized, contains('updated_by text'));
      // updated_at must be a TIMESTAMPTZ so `now()` in the UPDATE
      // produces a UTC instant (Time guardrail: TIMESTAMP WITHOUT
      // TIME ZONE banned in operator-scoped tables).
      expect(normalized, contains('updated_at timestamptz not null default now()'));
    });

    test('RLS posture admits operator-scoped writes', () {
      // The route resolves operator + location from the JWT and the
      // repository runs through `withTenant`. The migration's policy
      // body must read the same SET LOCAL keys via the wrapper
      // functions (no bare `current_setting()` per CLAUDE.md).
      expect(
        normalized,
        contains('alter table public.wage_role_rows enable row level security'),
      );
      expect(
        normalized,
        contains('operator_id = public.app_current_operator()'),
      );
      expect(
        normalized,
        contains('location_id = public.app_current_location()'),
      );
      expect(normalized, isNot(contains('current_setting(')));
      // The route updates rows; the migration must grant UPDATE to
      // service_role (the proxy's Postgres role).
      expect(
        normalized,
        contains(
          'grant select, insert, update on public.wage_role_rows to service_role',
        ),
      );
      // No DELETE grant — the route's DELETE handler is a soft delete
      // (UPDATE), never a row-removal DELETE. A future grant of DELETE
      // would imply a hard-delete path the route does not implement.
      expect(normalized, isNot(contains('grant delete')));
    });

    test(
      'route depends on these column names appearing exactly as the '
      'repository SELECT list expects (cast aliases stay on the '
      'repository side, not the migration)',
      () {
        for (final column in <String>[
          'wage_role_row_id',
          'operator_id',
          'location_id',
          'restaurant_id',
          'role_name',
          'labor_bucket',
          'hourly_rate',
          'weighted_hours',
          'job_code',
          'vendor_id',
          'vendor_role_id',
          'source',
          'is_active',
          'effective_at',
          'metadata',
          'created_at',
          'updated_at',
          'updated_by',
        ]) {
          expect(
            normalized,
            contains(column),
            reason:
                'migration must declare $column for the repository SELECT '
                'list to project it through `WageRoleRowRecord.fromRow`',
          );
        }
      },
    );
  });
}
