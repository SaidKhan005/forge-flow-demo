// Per-Daypart V1 Slice R7d — FINAL covers-source step:
// drop the legacy scalar covers columns + trim the effective view's
// three legacy scalar outputs. SCHEMA-DESTRUCTIVE.
//
// R7d is the last covers-source migration. R5 keyed-backfilled +
// deprecated the legacy scalar columns, R7a added the
// `covers_source_per_service_period jsonb` replacement column + view
// output, R7b moved the proxy off legacy-column SQL onto the keyed
// table / view jsonb, R7c removed dead legacy-column Dart. With zero
// remaining SQL/view-scalar readers, R7d redefines the view to drop
// its three legacy scalar outputs and then hard-drops the six legacy
// scalar columns (3 on data_accuracy_settings, 3 on
// data_accuracy_scoped_overrides) inside one atomic transaction.
//
// These are static SQL-text shape tests (no live Postgres), the same
// approach as
// test/per_daypart_v1_r7a_covers_source_per_period_hierarchy_test.dart
// and test/services/data_accuracy/data_accuracy_migration_test.dart.
//
// They prove:
//
//   (a) DROP — the migration drops all six legacy scalar covers
//       columns with `drop column if exists` (idempotent), on both
//       data_accuracy_settings and data_accuracy_scoped_overrides, and
//       uses NO `cascade` and never drops the view.
//
//   (b) VIEW TRIMMED — the redefined view no longer emits the three
//       legacy scalar outputs (`covers_source_lunch` /
//       `covers_source_dinner` / `covers_source_late_night`) and no
//       longer reads the legacy scalar columns, while still emitting
//       `covers_source_per_service_period` with the same HP #11
//       most-specific-scope-wins precedence and the same RLS grants.
//
//   (c) PER-PERIOD OUTPUT + HP #11 PRECEDENCE PRESERVED — the retained
//       jsonb output keeps the keyed DISTINCT ON … at-or-before
//       projection and the least -> most specific merge
//       (keyed -> business -> org-unit via the SAME ltree lateral ->
//       location), so any number of periods resolves deeper-scope-wins
//       exactly as R7a defined it.
//
//   (d) COMPLIANCE — atomic BEGIN/COMMIT (view redefine + drops in one
//       txn so the drop is not blocked and no CASCADE is needed),
//       idempotent, no `TIMESTAMP WITHOUT TIME ZONE`, no bare
//       `current_setting`, no new index, no kDemoMode, no down
//       migration block (destructive final step).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationFilename =
    '202605170200_per_daypart_v1_r7d_drop_legacy_covers_columns.sql';

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

/// Comment-stripped, lowercased, whitespace-collapsed migration SQL so
/// assertions pin executable DDL, not prose.
String _executableSql(String rawSql) =>
    _stripSqlComments(rawSql).toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// The `select … from public.locations loc` view body, comments
/// stripped, lowercased, whitespace-collapsed.
String _viewBody(String rawSql) {
  final ddl = _stripSqlComments(rawSql).toLowerCase();
  final start = ddl.indexOf(
    'create or replace view public.effective_data_accuracy_settings_v',
  );
  expect(start, greaterThanOrEqualTo(0),
      reason: 'R7d must redefine the effective view');
  final body = ddl.substring(start);
  return body.replaceAll(RegExp(r'\s+'), ' ');
}

void main() {
  group('R7d (a) — hard drop of the six legacy scalar covers columns',
      () {
    test(
      'drops covers_source_lunch / _dinner / _late_night from '
      'public.data_accuracy_settings with drop column if exists '
      '(idempotent)',
      () {
        final sql = _executableSql(_readMigration());
        for (final col in const <String>[
          'covers_source_lunch',
          'covers_source_dinner',
          'covers_source_late_night',
        ]) {
          expect(
            sql,
            contains(
              'alter table public.data_accuracy_settings '
              'drop column if exists $col',
            ),
            reason: 'must idempotently drop $col on data_accuracy_settings',
          );
        }
      },
    );

    test(
      'drops covers_source_lunch / _dinner / _late_night from '
      'public.data_accuracy_scoped_overrides with drop column if exists '
      '(idempotent)',
      () {
        final sql = _executableSql(_readMigration());
        for (final col in const <String>[
          'covers_source_lunch',
          'covers_source_dinner',
          'covers_source_late_night',
        ]) {
          expect(
            sql,
            contains(
              'alter table public.data_accuracy_scoped_overrides '
              'drop column if exists $col',
            ),
            reason:
                'must idempotently drop $col on data_accuracy_scoped_overrides',
          );
        }
      },
    );

    test(
      'NO cascade anywhere and the view is never dropped (the drop is '
      'unblocked solely by redefining the view first in the same txn)',
      () {
        final sql = _executableSql(_readMigration());
        expect(sql, isNot(contains('cascade')),
            reason: 'CASCADE would silently drop the dependent view');
        expect(sql, isNot(contains('drop view')),
            reason: 'the effective view must be replaced, never dropped');
      },
    );
  });

  group('R7d (b) — effective view trimmed of the legacy scalar outputs',
      () {
    test('redefines the view via CREATE OR REPLACE (never DROP)', () {
      final sql = _executableSql(_readMigration());
      expect(
        sql,
        contains(
          'create or replace view '
          'public.effective_data_accuracy_settings_v as',
        ),
      );
    });

    test(
      'the redefined view emits NO covers_source_lunch / _dinner / '
      '_late_night scalar output and reads NO legacy scalar column',
      () {
        final view = _viewBody(_readMigration());
        for (final col in const <String>[
          'covers_source_lunch',
          'covers_source_dinner',
          'covers_source_late_night',
        ]) {
          expect(
            view,
            isNot(contains(') as $col')),
            reason: 'the legacy scalar output $col must be removed',
          );
          // No coalesce chain reading the dropped legacy scalar column
          // from any scope (location/org/business/legacy).
          expect(
            view,
            isNot(contains('.$col')),
            reason: 'the view must not read the dropped legacy column $col',
          );
        }
      },
    );

    test('RLS posture unchanged: same SELECT grants on the view', () {
      final sql = _executableSql(_readMigration());
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
    });
  });

  group('R7d (c) — per-period jsonb output + HP #11 precedence preserved',
      () {
    test('view still emits covers_source_per_service_period jsonb', () {
      final view = _viewBody(_readMigration());
      expect(
        view,
        contains(') as covers_source_per_service_period'),
        reason: 'the R7a per-period jsonb output must be retained',
      );
    });

    test(
      'keyed-table contribution still mirrors the canonical effective-row '
      'projection (DISTINCT ON service_period_key, at-or-before today UTC, '
      'effective_at_business_date DESC, per-tenant scoped)',
      () {
        final view = _viewBody(_readMigration());
        expect(view, contains('select distinct on (sp.service_period_key)'));
        expect(
          view,
          contains('from public.data_accuracy_service_period_settings sp'),
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
        expect(view, contains('sp.operator_id = loc.operator_id'));
        expect(view, contains('sp.location_id = loc.location_id'));
      },
    );

    test(
      'most-specific-scope-wins merge order unchanged: keyed -> business '
      '-> org-unit -> location (HP #11), reusing the SAME ltree lateral '
      '(loc.org_unit_path <@ ou.path, deepest ancestor wins, not '
      'duplicated)',
      () {
        final view = _viewBody(_readMigration());
        final businessIdx =
            view.indexOf('|| coalesce(business_scope.covers_source');
        final orgIdx = view.indexOf('|| coalesce(org_scope.covers_source');
        final locIdx =
            view.indexOf('|| coalesce(location_scope.covers_source');
        expect(businessIdx, greaterThanOrEqualTo(0));
        expect(orgIdx, greaterThan(businessIdx),
            reason: 'org-unit scope must override business scope');
        expect(locIdx, greaterThan(orgIdx),
            reason: 'location scope must override org-unit scope');
        expect(view, contains('loc.org_unit_path <@ ou.path'));
        expect(
          view,
          contains('order by nlevel(ou.path) desc, scoped.updated_at desc'),
        );
        expect(
          'loc.org_unit_path <@ ou.path'.allMatches(view).length,
          1,
          reason: 'the HP #11 org-unit lateral must not be duplicated',
        );
        expect(
          view,
          contains('jsonb_object_agg(k.service_period_key, k.covers_source)'),
          reason: 'every keyed period contributes (no hardcoded 3)',
        );
      },
    );
  });

  group('R7d (d) — compliance: atomic, idempotent, no temporal/policy '
      'change, no down block', () {
    test(
      'atomic: BEGIN … COMMIT wraps the view redefine + the six drops so '
      'a partial failure leaves the schema unchanged',
      () {
        final sql = _stripSqlComments(_readMigration()).toLowerCase();
        expect(sql.contains('begin;'), isTrue);
        expect(sql.contains('commit;'), isTrue);
        // The view redefine appears before the column drops within the
        // single transaction (so Postgres does not block the drop).
        final exec = sql.replaceAll(RegExp(r'\s+'), ' ');
        final viewIdx = exec.indexOf(
          'create or replace view '
          'public.effective_data_accuracy_settings_v',
        );
        final firstDropIdx = exec.indexOf('drop column if exists');
        expect(viewIdx, greaterThanOrEqualTo(0));
        expect(firstDropIdx, greaterThan(viewIdx),
            reason: 'view must be redefined before the column drops');
      },
    );

    test(
      'no temporal column added/altered and no RLS policy change '
      '(drop-only + view replace): no TIMESTAMP WITHOUT TIME ZONE, no '
      'bare current_setting, no create/alter policy, no new index',
      () {
        final sql = _executableSql(_readMigration());
        expect(sql, isNot(contains('timestamp without time zone')));
        expect(sql, isNot(contains('current_setting(')));
        expect(sql, isNot(contains('create policy')));
        expect(sql, isNot(contains('alter policy')));
        expect(sql, isNot(contains('create index')));
        expect(sql, isNot(contains('create unique index')));
      },
    );

    test('no kDemoMode and no down/rollback migration block', () {
      final raw = _readMigration();
      expect(raw.contains('kDemoMode'), isFalse);
      final sql = _executableSql(raw);
      // Destructive final step: intentionally irreversible. No add-back
      // of the dropped scalar columns and no view restoring the legacy
      // scalar outputs.
      expect(sql, isNot(contains('add column covers_source_lunch')));
      expect(sql, isNot(contains('add column if not exists covers_source_lunch')));
    });
  });
}
