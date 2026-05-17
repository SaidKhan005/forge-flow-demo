// Per-Daypart V1 Slice R7a — covers-source per-period hierarchy view +
// scoped-overrides re-key proving tests.
//
// R7a is PURELY ADDITIVE: a new jsonb column on the HP #11
// scoped-overrides table + a new jsonb output on
// `public.effective_data_accuracy_settings_v`, with every existing
// view output and every existing column left byte-unchanged.
//
// These are static SQL-text shape tests (no live Postgres), the same
// approach as test/per_daypart_v1_r5_covers_source_de_hardcode_test.dart
// and test/services/data_accuracy/data_accuracy_migration_test.dart.
//
// They prove:
//
//   (a) ADDITIVE COLUMN — the migration adds
//       `covers_source_per_service_period jsonb` to
//       `public.data_accuracy_scoped_overrides` with `if not exists`,
//       and does NOT drop or alter any existing covers_source_*
//       column on either the scoped-overrides table or the legacy
//       per-location table.
//
//   (b) VIEW SCALARS UNCHANGED — the redefined view still emits the
//       three scalar outputs (`covers_source_lunch` /
//       `covers_source_dinner` / `covers_source_late_night`) with the
//       exact same coalesce(location → org → business → legacy →
//       'vendor') chain backed by the legacy columns, so every
//       current consumer keeps working unchanged.
//
//   (c) NEW PER-PERIOD OUTPUT + HP #11 PRECEDENCE — the view adds a
//       `covers_source_per_service_period` jsonb output that resolves
//       per service_period_key with most-specific-scope-wins
//       precedence (keyed legacy effective rows → business → org-unit
//       via the SAME ltree lateral → location), reusing the existing
//       HP #11 org-unit lateral (`loc.org_unit_path <@ ou.path`,
//       deepest ancestor wins), mirroring the canonical
//       DISTINCT ON … at-or-before keyed-row projection. Covers a
//       4-period operator and an org-unit-level override.
//
//   (d) COMPLIANCE — idempotent, BEGIN/COMMIT wrapped, no
//       `TIMESTAMP WITHOUT TIME ZONE`, no bare `current_setting`, no
//       new index missing an operator-leading column (no new index
//       added), no down migration needed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationFilename =
    '202605170100_per_daypart_v1_r7a_covers_source_per_period_hierarchy.sql';

String _readMigration() {
  final file = File('db/migrations/$_migrationFilename');
  expect(
    file.existsSync(),
    isTrue,
    reason: 'tests must run from repository root; expected '
        'db/migrations/$_migrationFilename to exist',
  );
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

/// Strip SQL `--` line comments so prose explaining the design does
/// not satisfy assertions meant to pin executable DDL.
String _stripSqlComments(String content) {
  final out = StringBuffer();
  for (final line in content.split('\n')) {
    final idx = line.indexOf('--');
    out.writeln(idx < 0 ? line : line.substring(0, idx));
  }
  return out.toString();
}

/// The `select … from public.locations loc` view body, comments
/// stripped, lowercased, whitespace-collapsed — so output-shape
/// assertions pin executable DDL, not prose.
String _viewBody(String rawSql) {
  final ddl = _stripSqlComments(rawSql).toLowerCase();
  final start = ddl.indexOf(
    'create or replace view public.effective_data_accuracy_settings_v',
  );
  expect(start, greaterThanOrEqualTo(0),
      reason: 'R7a must redefine the effective view');
  final body = ddl.substring(start);
  return body.replaceAll(RegExp(r'\s+'), ' ');
}

void main() {
  group('R7a (a) — additive column, nothing dropped or altered', () {
    test(
      'adds covers_source_per_service_period jsonb to the HP #11 '
      'scoped-overrides table with IF NOT EXISTS (idempotent, additive)',
      () {
        final sql = _stripSqlComments(_readMigration()).toLowerCase();
        expect(
          sql.replaceAll(RegExp(r'\s+'), ' '),
          contains(
            'alter table public.data_accuracy_scoped_overrides '
            'add column if not exists '
            'covers_source_per_service_period jsonb',
          ),
        );
      },
    );

    test(
      'does NOT drop or alter any existing covers_source_* column on '
      'either the scoped-overrides table or the legacy per-location '
      'table (R7d owns the hard drop)',
      () {
        final sql = _stripSqlComments(_readMigration()).toLowerCase();
        expect(sql, isNot(contains('drop column')));
        expect(
          sql,
          isNot(contains('alter column covers_source')),
          reason: 'existing scalar covers columns must be untouched',
        );
        // No CREATE TABLE — R7a reuses the existing scoped-overrides
        // table; it must not invent a parallel scoped+keyed table.
        expect(
          sql,
          isNot(contains('create table')),
          reason: 'no parallel/duplicate hierarchy table',
        );
      },
    );

    test(
      'a jsonb shape CHECK guards the new column to the keyed table '
      'covers_source enum, added idempotently (guarded DO block)',
      () {
        final sql = _stripSqlComments(_readMigration()).toLowerCase();
        expect(
          sql,
          contains('data_accuracy_scoped_covers_per_period_ck'),
        );
        expect(sql, contains("jsonb_typeof(covers_source_per_service_period"));
        for (final v in const <String>[
          'vendor',
          'forecast',
          'manual',
          'reservation_plus_walkin',
        ]) {
          expect(sql, contains("'$v'"),
              reason: 'CHECK must admit keyed enum value $v');
        }
        // Guarded so re-applying the migration is a no-op.
        expect(sql, contains('from pg_constraint'));
      },
    );
  });

  group('R7a (b) — existing view scalar outputs byte-unchanged', () {
    test(
      'the three scalar covers_source_* outputs keep the exact '
      'coalesce(location → org → business → legacy → vendor) chain '
      'backed by the legacy columns',
      () {
        final view = _viewBody(_readMigration());
        for (final p in const <String>['lunch', 'dinner', 'late_night']) {
          expect(
            view,
            contains(
              'coalesce( location_scope.covers_source_$p, '
              'org_scope.covers_source_$p, '
              'business_scope.covers_source_$p, '
              'legacy.covers_source_$p, '
              "'vendor' ) as covers_source_$p"
                  .replaceAll(RegExp(r'\s+'), ' '),
            ),
            reason: 'scalar covers_source_$p output must be unchanged',
          );
        }
      },
    );

    test(
      'all other existing view outputs (manual entries / wage / walk-in '
      '/ timestamps / updated_by) are still present and unchanged',
      () {
        final view = _viewBody(_readMigration());
        for (final out in const <String>[
          'as setting_id',
          'as covers_manual_entries',
          'as wage_source',
          'as walk_in_handling_mode',
          'as walk_in_manual_entries',
          'as created_at',
          'as updated_at',
          'as updated_by',
        ]) {
          expect(view, contains(out));
        }
        // The legacy + scoped joins are intact, including the HP #11
        // org-unit ltree lateral, exactly as in 202605121200.
        expect(view, contains('from public.locations loc'));
        expect(
          view,
          contains('left join public.data_accuracy_settings legacy'),
        );
        expect(
          view,
          contains("scope_type = 'business'"),
        );
        expect(
          view,
          contains("scope_type = 'location'"),
        );
      },
    );
  });

  group('R7a (c) — new per-period output + HP #11 precedence', () {
    test(
      'view adds a covers_source_per_service_period jsonb output',
      () {
        final view = _viewBody(_readMigration());
        expect(
          view,
          contains(') as covers_source_per_service_period'),
          reason: 'the new per-period jsonb output must be emitted',
        );
      },
    );

    test(
      'keyed-table contribution mirrors the canonical effective-row '
      'projection: DISTINCT ON (service_period_key) ORDER BY '
      'service_period_key, effective_at_business_date DESC, at-or-before '
      'today UTC',
      () {
        final view = _viewBody(_readMigration());
        expect(
          view,
          contains('select distinct on (sp.service_period_key)'),
        );
        expect(
          view,
          contains(
            'from public.data_accuracy_service_period_settings sp',
          ),
        );
        expect(
          view,
          contains(
            'sp.effective_at_business_date <= '
            "(now() at time zone 'utc')::date",
          ),
        );
        expect(
          view,
          contains(
            'order by sp.service_period_key, '
            'sp.effective_at_business_date desc',
          ),
        );
        // Keyed rows are joined per (operator, location) of the view's
        // location row — per-tenant isolation preserved.
        expect(view, contains('sp.operator_id = loc.operator_id'));
        expect(view, contains('sp.location_id = loc.location_id'));
      },
    );

    test(
      'most-specific-scope-wins: jsonb merge ordered least → most '
      'specific (keyed legacy → business → org-unit → location) so a '
      'key set at a deeper scope overrides the same key at a higher '
      'scope (HP #11)',
      () {
        final view = _viewBody(_readMigration());
        // The merge expression concatenates the four contributions in
        // ascending-specificity order; `a || b` keeps b on collision.
        final mergeStart =
            view.indexOf("|| coalesce(business_scope.covers_source");
        final orgIdx =
            view.indexOf("|| coalesce(org_scope.covers_source");
        final locIdx =
            view.indexOf("|| coalesce(location_scope.covers_source");
        expect(mergeStart, greaterThanOrEqualTo(0));
        expect(orgIdx, greaterThan(mergeStart),
            reason: 'org-unit scope must override business scope');
        expect(locIdx, greaterThan(orgIdx),
            reason: 'location scope must override org-unit scope');
      },
    );

    test(
      'org-unit scope reuses the SAME HP #11 ltree lateral as the '
      'scalars (loc.org_unit_path <@ ou.path, deepest ancestor wins) — '
      'no parallel hierarchy logic',
      () {
        final view = _viewBody(_readMigration());
        expect(view, contains('loc.org_unit_path <@ ou.path'));
        expect(
          view,
          contains('order by nlevel(ou.path) desc, scoped.updated_at desc'),
        );
        // Exactly one org-unit lateral — reused for both scalar and
        // jsonb outputs, not duplicated.
        expect(
          'loc.org_unit_path <@ ou.path'.allMatches(view).length,
          1,
          reason: 'the HP #11 org-unit lateral must not be duplicated',
        );
      },
    );

    test(
      'HP #11 4-period + org-unit precedence is expressible: the merge '
      'carries every keyed period (e.g. breakfast/lunch/dinner/'
      'late_night) and lets an org-unit-level map override the keyed '
      'value while a location-level map overrides the org-unit value',
      () {
        // Static-shape proof: keyed rows feed jsonb_object_agg over
        // ALL service_period_key values (not a hardcoded 3), and the
        // org_scope/location_scope contributions concatenate ON TOP,
        // so any number of periods resolves with deeper-scope-wins.
        final view = _viewBody(_readMigration());
        expect(
          view,
          contains(
            'jsonb_object_agg(k.service_period_key, k.covers_source)',
          ),
          reason: 'every keyed period contributes (no hardcoded 3)',
        );
        // org-unit map overrides keyed; location map overrides org-unit
        // (proven by ordering above) — assert both scope contributions
        // are present in the per-period merge.
        expect(
          view,
          contains('|| coalesce(org_scope.covers_source_per_service_period'),
        );
        expect(
          view,
          contains(
            '|| coalesce(location_scope.covers_source_per_service_period',
          ),
        );
      },
    );
  });

  group('R7a (d) — compliance + scope discipline', () {
    test('idempotent + atomic: BEGIN/COMMIT, IF NOT EXISTS, guarded CHECK',
        () {
      final lower = _readMigration().toLowerCase();
      expect(lower.contains('begin;'), isTrue);
      expect(lower.contains('commit;'), isTrue);
      expect(lower.contains('add column if not exists'), isTrue);
      expect(lower.contains('create or replace view'), isTrue);
    });

    test(
      'no TIMESTAMP WITHOUT TIME ZONE; no bare current_setting; no new '
      'index (so no operator-leading-index obligation)',
      () {
        final raw = _readMigration();
        final lower = raw.toLowerCase();
        expect(
          lower.contains('timestamp without time zone'),
          isFalse,
        );
        expect(
          RegExp(r"current_setting\(\s*'app\.", caseSensitive: false)
              .hasMatch(raw),
          isFalse,
          reason: 'view is security-invoker over per-tenant tables; the '
              'existing wrapper-only RLS policy is unchanged',
        );
        // R7a adds no index; if a future revision does, it must lead
        // with operator_id. Assert none is added here.
        expect(
          _stripSqlComments(raw).toLowerCase().contains('create index'),
          isFalse,
          reason: 'R7a adds no index (column add + view replace only)',
        );
        expect(
          _stripSqlComments(raw)
              .toLowerCase()
              .contains('create unique index'),
          isFalse,
        );
      },
    );

    test(
      'does not weaken RLS: no policy / grant change beyond the view '
      'SELECT grants the prior migration already issued',
      () {
        final sql = _stripSqlComments(_readMigration()).toLowerCase();
        expect(sql, isNot(contains('create policy')));
        expect(sql, isNot(contains('drop policy')));
        expect(sql, isNot(contains('disable row level security')));
        // Only the same two view SELECT grants 202605121200 issued.
        expect(
          sql,
          contains(
            'grant select on public.effective_data_accuracy_settings_v '
            'to service_role',
          ),
        );
        expect(
          sql,
          contains(
            'grant select on public.effective_data_accuracy_settings_v '
            'to forge_admin',
          ),
        );
      },
    );

    test('no kDemoMode and no down migration block', () {
      final lower = _readMigration().toLowerCase();
      expect(lower.contains('kdemomode'), isFalse);
      expect(lower.contains('demo_'), isFalse);
      // Deferred-drop idiom: header states no down migration needed.
      expect(lower.contains('no down migration'), isTrue);
    });
  });
}
