// Phase 8 spine-bridge Lane .A — migration shape + grants tests.
//
// Covers acceptance items J + H from the lane prompt:
//
//   J. Migration idempotent (apply twice → no errors). Verified by
//      pinning the idempotency primitives in the SQL text:
//        * every `create table` carries `if not exists`
//        * every `create index` carries `if not exists`
//        * every `create policy` is preceded by a matching
//          `drop policy if exists`
//        * grants/revokes are statements that re-apply harmlessly
//
//   H. forge_admin role required for tier writes; service_role
//      read-only on the tier table. Verified by pinning the GRANT
//      statements:
//        * data_accuracy_settings: service_role + forge_admin both
//          have SELECT/INSERT/UPDATE
//        * forge_flow_polling_tier_assignment: service_role has
//          SELECT only; forge_admin has SELECT/INSERT/UPDATE
//
// All assertions are static SQL-text checks against the on-disk
// migration file — no live Postgres required.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _migrationFilename =
    '202605050000_phase_8_data_accuracy_settings.sql';
const String _pollingEventKindsMigrationFilename =
    '202605050100_phase_8_0a_polling_event_kinds.sql';

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

String _readPollingEventKindsMigration() {
  final file = File('db/migrations/$_pollingEventKindsMigrationFilename');
  expect(
    file.existsSync(),
    isTrue,
    reason: 'tests must run from repository root; expected '
        'db/migrations/$_pollingEventKindsMigrationFilename to exist',
  );
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

/// Strip SQL `--` line comments — prose explaining design intent
/// can mention banned terms ("no TIMESTAMP WITHOUT TIME ZONE") without
/// tripping a strict grep on executable DDL.
String _stripSqlComments(String content) {
  final out = StringBuffer();
  for (final line in content.split('\n')) {
    final idx = line.indexOf('--');
    out.writeln(idx < 0 ? line : line.substring(0, idx));
  }
  return out.toString();
}

void main() {
  group('Phase 8 spine-bridge Lane .A migration — idempotency (item J)', () {
    test(
      'every CREATE TABLE statement carries `if not exists` so '
      're-applying the migration is a no-op',
      () {
        final sql = _readMigration();
        // Grab every CREATE TABLE statement (case-insensitive).
        final pattern = RegExp(r'create\s+table\s+(if\s+not\s+exists\s+)?',
            caseSensitive: false);
        final matches = pattern.allMatches(sql).toList();
        expect(
          matches,
          isNotEmpty,
          reason: 'migration declares at least one CREATE TABLE',
        );
        for (final m in matches) {
          expect(
            m.group(1),
            isNotNull,
            reason: 'every CREATE TABLE must be `if not exists`; offending '
                'match at offset ${m.start}',
          );
        }
      },
    );

    test(
      'every CREATE INDEX statement carries `if not exists`',
      () {
        final sql = _readMigration();
        final pattern = RegExp(
          r'create\s+(unique\s+)?index\s+(if\s+not\s+exists\s+)?',
          caseSensitive: false,
        );
        final matches = pattern.allMatches(sql).toList();
        expect(matches, isNotEmpty);
        for (final m in matches) {
          expect(
            m.group(2),
            isNotNull,
            reason: 'every CREATE INDEX must be `if not exists`; offending '
                'match at offset ${m.start}',
          );
        }
      },
    );

    test(
      'every CREATE POLICY is preceded by a matching DROP POLICY IF EXISTS '
      'on the same table+name pair (otherwise re-apply throws '
      '`policy already exists`)',
      () {
        final sql = _readMigration();
        // Match: drop policy if exists "<name>" on <schema>.<table>
        // and:   create policy "<name>" on <schema>.<table>
        final dropPattern = RegExp(
          r'drop\s+policy\s+if\s+exists\s+"([^"]+)"\s+on\s+([\w\.]+)',
          caseSensitive: false,
        );
        final createPattern = RegExp(
          r'create\s+policy\s+"([^"]+)"\s+on\s+([\w\.]+)',
          caseSensitive: false,
        );
        final drops = dropPattern
            .allMatches(sql)
            .map((m) => '${m.group(2)}|${m.group(1)}')
            .toSet();
        final creates = createPattern
            .allMatches(sql)
            .map((m) => '${m.group(2)}|${m.group(1)}')
            .toList();
        expect(creates, isNotEmpty);
        for (final c in creates) {
          expect(
            drops,
            contains(c),
            reason: 'CREATE POLICY $c must be preceded by '
                'DROP POLICY IF EXISTS on the same table+name pair',
          );
        }
      },
    );

    test(
      'wrapped in a single BEGIN ... COMMIT — atomicity guarantees that '
      'a partial failure leaves the schema unchanged (no half-installed '
      'tables / policies)',
      () {
        final sql = _readMigration();
        expect(sql.toLowerCase().contains('begin;'), isTrue);
        expect(sql.toLowerCase().contains('commit;'), isTrue);
      },
    );
  });

  group('Phase 8 spine-bridge Lane .A migration — RLS posture', () {
    test(
      'both tables enable row level security',
      () {
        final sql = _readMigration().toLowerCase();
        expect(
          sql,
          contains(
            'alter table public.data_accuracy_settings enable row level security',
          ),
        );
        expect(
          sql,
          contains('alter table public.forge_flow_polling_tier_assignment '
              'enable row level security'),
        );
      },
    );

    test(
      'every RLS policy body uses the wrapper helpers '
      '`app_current_operator()` / `app_current_location()` — no bare '
      "current_setting('app.*', ...) reads (Phase 9.0Σ.b item 4)",
      () {
        final sql = _readMigration();
        // Bare current_setting calls in policy bodies are forbidden.
        // The wrapper functions are the only sanctioned read path.
        final bareReads = RegExp(
          r"current_setting\(\s*'app\.",
          caseSensitive: false,
        );
        expect(
          bareReads.hasMatch(sql),
          isFalse,
          reason: 'bare current_setting() in a policy body is forbidden — '
              'use public.app_current_operator() / app_current_location()',
        );
        // Sanity: wrappers are referenced.
        expect(sql, contains('public.app_current_operator()'));
        expect(sql, contains('public.app_current_location()'));
      },
    );
  });

  group('Phase 8 spine-bridge Lane .A migration — grants (item H)', () {
    test(
      'data_accuracy_settings: service_role + forge_admin both have '
      'SELECT / INSERT / UPDATE (operator-controlled overrides — both '
      'tenant runtime and admin override write paths)',
      () {
        final sql = _readMigration().toLowerCase();
        expect(
          sql,
          contains('revoke all on public.data_accuracy_settings from public'),
        );
        expect(
          sql,
          contains('grant select, insert, update on '
              'public.data_accuracy_settings to service_role'),
        );
        expect(
          sql,
          contains('grant select, insert, update on '
              'public.data_accuracy_settings to forge_admin'),
        );
      },
    );

    test(
      'forge_flow_polling_tier_assignment: service_role has SELECT only; '
      'forge_admin has SELECT/INSERT/UPDATE — F&F admin is the sole '
      'writer of tier rows; operator-side runtime is read-only',
      () {
        final sql = _readMigration().toLowerCase();
        expect(
          sql,
          contains(
            'revoke all on public.forge_flow_polling_tier_assignment '
            'from public',
          ),
        );
        // service_role: SELECT only.
        expect(
          sql,
          contains(
            'grant select on public.forge_flow_polling_tier_assignment '
            'to service_role',
          ),
        );
        // service_role must NOT receive insert/update on the tier table.
        expect(
          RegExp(
            r'grant\s+select\s*,\s*insert.*on\s+public\.forge_flow_polling_tier_assignment\s+to\s+service_role',
            caseSensitive: false,
          ).hasMatch(_readMigration()),
          isFalse,
          reason: 'service_role must be read-only on the tier table — '
              'tier writes go through forge_admin only',
        );
        // forge_admin: SELECT/INSERT/UPDATE.
        expect(
          sql,
          contains(
            'grant select, insert, update\n  '
            'on public.forge_flow_polling_tier_assignment to forge_admin',
          ),
        );
      },
    );
  });

  group('Phase 8 spine-bridge Lane .A migration — schema shape', () {
    test(
      'data_accuracy_settings carries the contract column set: covers '
      'source per daypart, sparse manual entries jsonb, wage source. '
      'NO polling cadence override columns (per F&F-controlled tier '
      'model — the tier table owns cadence).',
      () {
        final sql = _readMigration().toLowerCase();
        // Required columns.
        expect(sql, contains('covers_source_lunch text not null'));
        expect(sql, contains('covers_source_dinner text not null'));
        expect(sql, contains('covers_source_late_night text not null'));
        expect(sql, contains('covers_manual_entries jsonb not null'));
        expect(sql, contains('wage_source text not null'));
        // Polling cadence override columns are explicitly absent —
        // F&F admin controls cadence via the tier table, not here.
        expect(sql, isNot(contains('polling_cadence_override_seconds')));
        expect(sql, isNot(contains('polling_cost_acknowledged_at')));
      },
    );

    test(
      'forge_flow_polling_tier_assignment carries the contract column '
      'set: tier_key + jsonb cadence + price + cost basis + '
      'effective_at/until + admin actor',
      () {
        final sql = _readMigration().toLowerCase();
        expect(sql, contains('tier_key text not null'));
        expect(
          sql,
          contains('polling_cadence_per_vendor_seconds jsonb not null'),
        );
        expect(sql, contains('monthly_price_cents integer'));
        expect(
          sql,
          contains('vendor_api_cost_estimate_cents_monthly integer'),
        );
        expect(sql, contains('effective_at timestamptz not null'));
        expect(sql, contains('effective_until timestamptz'));
        expect(sql, contains('assigned_by_admin_user_id text'));
      },
    );

    test(
      'currently-effective uniqueness: a partial unique index on '
      '(operator_id, location_id) WHERE effective_until is null pins '
      'one active tier per (operator, location)',
      () {
        final sql = _readMigration().toLowerCase();
        expect(
          sql,
          contains('create unique index if not exists '
              'forge_flow_polling_tier_current_idx'),
        );
        expect(
          sql,
          contains('on public.forge_flow_polling_tier_assignment '
              '(operator_id, location_id)\n  where effective_until is null'),
        );
      },
    );

    test(
      'operator-leading B-tree index on every fact table per the '
      'RLS-Ready Schema rule (CI lint enforces; this test pins it up '
      'front so a refactor cannot regress)',
      () {
        final sql = _readMigration().toLowerCase();
        // data_accuracy_settings.
        expect(
          sql,
          contains(
            'create index if not exists data_accuracy_settings_operator_idx',
          ),
        );
        expect(
          sql,
          contains('on public.data_accuracy_settings '
              '(operator_id, location_id)'),
        );
        // forge_flow_polling_tier_assignment — the operator-leading
        // history index is `(operator_id, location_id, effective_at desc)`.
        expect(
          sql,
          contains(
            'create index if not exists forge_flow_polling_tier_operator_idx',
          ),
        );
      },
    );

    test(
      'TIMESTAMPTZ on every temporal column — TIMESTAMP WITHOUT TIME '
      'ZONE is banned in operator-scoped tables (CLAUDE.md / 7.55 Rule 11)',
      () {
        // Strip SQL comments first — design-intent prose can mention
        // banned column types without tripping the executable-DDL grep.
        final sql = _stripSqlComments(_readMigration());
        // `\btimestamp\b` only matches TIMESTAMP as a complete word
        // (the word boundary fires on the trailing whitespace before
        // the next column-type token). `timestamptz` does NOT match
        // because `tz` is a word continuation — no boundary between
        // `p` and `t`.
        final bareTimestamp = RegExp(
          r'\btimestamp\b',
          caseSensitive: false,
        ).allMatches(sql);
        expect(
          bareTimestamp,
          isEmpty,
          reason: 'use TIMESTAMPTZ everywhere; bare TIMESTAMP is banned. '
              'Found: ${bareTimestamp.map((m) => sql.substring(m.start, m.end + 5)).toList()}',
        );
      },
    );
  });

  group('Phase 8 spine-bridge Lane .0a migration — partial staging safety', () {
    test(
      'guards connector_sync_log constraint repair when the integration '
      'framework table is not present yet',
      () {
        final sql = _readPollingEventKindsMigration().toLowerCase();
        expect(
          sql,
          contains("to_regclass('public.connector_sync_log') is not null"),
        );
        expect(sql, contains('alter table public.connector_sync_log'));
        expect(sql, contains('connector_sync_log_event_kind_check'));
      },
    );

    test('keeps the polling tier event kinds in the repaired CHECK list', () {
      final sql = _readPollingEventKindsMigration().toLowerCase();
      expect(sql, contains("'tier_assignment_missing'"));
      expect(sql, contains("'cadence_clamped'"));
      expect(sql, contains("'custom_tier_vendor_unset'"));
      expect(sql, contains("'tier_assignment_lookup_failed'"));
      expect(sql, contains("'vendor_not_registered'"));
    });
  });
}
