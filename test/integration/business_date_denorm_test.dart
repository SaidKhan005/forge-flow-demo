// Phase 8 — business_date denorm migration acceptance test.
//
// Verifies the schema shape that
// `db/migrations/202605050400_phase_8_business_date_denorm.sql`
// installs against a real Postgres instance:
//
//   * `business_date DATE NOT NULL` exists on connector_sync_log,
//     inbound_webhook_dead_letter, sanity_log.
//   * The new B-tree indexes lead with operator_id (CLAUDE.md /
//     9.0Σ.b item 4 — RLS performance discipline).
//   * The BEFORE INSERT trigger denormalizes business_date from the
//     row's source-truth TIMESTAMPTZ via the location's IANA
//     timezone whenever the inserter leaves business_date NULL.
//   * Trigger preserves caller-supplied business_date (no overwrite).
//   * Backfill values match the IANA conversion against a fixture
//     location whose timezone is `America/Los_Angeles`.
//
// PASSIVE BY DEFAULT. Mirrors the
// `phase_9_0sigma_rls_isolation_sweep_test.dart` pattern: skips
// silently unless `FORGE_FLOW_RUN_BUSINESS_DATE_DENORM_TEST=true` is
// set; with the flag set but `POSTGRES_URL` / `POSTGRES_ADMIN_URL`
// missing, fails fast with a BLOCKED preflight error that names the
// missing env vars (no values echoed). The dev-container env loader
// is `scripts/postgres_staging_setup.ps1`.
//
// CLAUDE.md binding: every Postgres call goes through
// `PackagePostgresPool` — no raw `package:postgres` imports leak
// into the test file. Admin-side seeds run as the deployment role
// (operators / org_units / locations are not RLS-denied to the owner).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/package_postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

const String _envFlag = 'FORGE_FLOW_RUN_BUSINESS_DATE_DENORM_TEST';
const String _envPostgresUrl = 'POSTGRES_URL';
const String _envPostgresAdminUrl = 'POSTGRES_ADMIN_URL';

// Fixture identifiers — `bd80…` namespace marks every row this test
// owns so manual cleanup on dev is recognizable at a glance.
const String _opId = 'bd800000-0000-0000-0000-0000000000a1';
const String _locId = 'bd800000-0000-0000-0000-0000000000a2';
const String _ouId = 'bd800000-0000-0000-0000-0000000000a3';
const String _connId = 'bd800000-0000-0000-0000-0000000000a4';
const String _fixtureMarker = 'bd80-business-date-denorm';

// Pacific restaurant. 2026-05-04T10:30:00Z = 03:30 PDT 2026-05-04.
// With business_day_rollover_hour = 4, 03:30 local is before the
// 04:00 rollover, so the event belongs to the PRIOR business date
// (2026-05-03). Mirrors the IANA converter at
// `lib/services/integration/iana_timezone_converter.dart`
// (`toBusinessDate`).
const String _tz = 'America/Los_Angeles';
const int _rolloverHour = 4;
final DateTime _occurredAtUtc = DateTime.utc(2026, 5, 4, 10, 30);
const String _expectedBusinessDate = '2026-05-03';

void main() {
  final flagRaw = Platform.environment[_envFlag] ?? '';
  final liveEnabled = flagRaw.toLowerCase() == 'true' || flagRaw == '1';

  if (!liveEnabled) {
    test(
      'Phase 8 business_date denorm — schema acceptance (passive default)',
      () {
        // Skip body intentionally empty.
      },
      skip:
          'Phase 8 business_date denorm acceptance is passive by '
          'default. To run against a local Postgres dev container, '
          'set $_envFlag=true and provide $_envPostgresUrl + '
          '$_envPostgresAdminUrl. Source the loader at '
          'scripts/postgres_staging_setup.ps1.',
    );
    return;
  }

  final pgUrl = Platform.environment[_envPostgresUrl];
  final pgAdminUrl = Platform.environment[_envPostgresAdminUrl];
  final missingEnv = <String>[
    if (pgUrl == null || pgUrl.isEmpty) _envPostgresUrl,
    if (pgAdminUrl == null || pgAdminUrl.isEmpty) _envPostgresAdminUrl,
  ];
  if (missingEnv.isNotEmpty) {
    test('Phase 8 business_date denorm — env preflight', () {
      fail(
        'BLOCKED: $_envFlag is true but required env names are '
        'missing: ${missingEnv.join(', ')}. Source the dev-container '
        'env loader (scripts/postgres_staging_setup.ps1) and re-run. '
        'No env values are echoed by this test.',
      );
    });
    return;
  }

  late PackagePostgresPool adminPool;

  setUpAll(() async {
    adminPool = PackagePostgresPool.fromUrl(pgAdminUrl!);
    await _runAdmin(adminPool, _cleanupFixtures);
    await _runAdmin(adminPool, _seedBaseFixtures);
  });

  tearDownAll(() async {
    await _runAdmin(adminPool, _cleanupFixtures);
  });

  group('Phase 8 business_date denorm — schema', () {
    test('column exists, NOT NULL on all three tables', () async {
      await _runAdmin(adminPool, (exec) async {
        for (final table in const <String>[
          'connector_sync_log',
          'inbound_webhook_dead_letter',
          'sanity_log',
        ]) {
          final rows = await exec.query(
            "select is_nullable, data_type "
            "  from information_schema.columns "
            " where table_schema = 'public' "
            "   and table_name = @table "
            "   and column_name = 'business_date'",
            parameters: <String, Object?>{'table': table},
          );
          expect(
            rows,
            hasLength(1),
            reason:
                '$table: business_date column missing — migration '
                'not applied or rolled back.',
          );
          expect(
            rows.single['data_type'],
            equals('date'),
            reason: '$table.business_date must be DATE.',
          );
          expect(
            rows.single['is_nullable'],
            equals('NO'),
            reason:
                '$table.business_date must be NOT NULL after migration '
                'completes.',
          );
        }
      });
    });

    test('new indexes exist and lead with operator_id', () async {
      await _runAdmin(adminPool, (exec) async {
        const expectedIndexes = <String, String>{
          'connector_sync_log_business_date_idx': 'connector_sync_log',
          'inbound_webhook_dead_letter_business_date_idx':
              'inbound_webhook_dead_letter',
          'sanity_log_business_date_idx': 'sanity_log',
        };
        for (final entry in expectedIndexes.entries) {
          final rows = await exec.query(
            "select indexdef "
            "  from pg_indexes "
            " where schemaname = 'public' "
            "   and indexname = @idx",
            parameters: <String, Object?>{'idx': entry.key},
          );
          expect(
            rows,
            hasLength(1),
            reason:
                '${entry.value}: index ${entry.key} missing — migration '
                'not applied.',
          );
          final def = (rows.single['indexdef'] as String).toLowerCase();
          expect(
            def,
            contains('btree'),
            reason: '${entry.key}: must be a B-tree index.',
          );
          // Leading-column check: the column list begins with operator_id.
          // Match `(operator_id` or `(operator_id, ` to be precise.
          final leadingMatch = RegExp(
            r'\(\s*operator_id\b',
          ).hasMatch(def);
          expect(
            leadingMatch,
            isTrue,
            reason:
                '${entry.key}: must lead with operator_id per '
                'CLAUDE.md / 9.0Σ.b item 4. indexdef=$def',
          );
        }
      });
    });

    test('triggers exist on all three tables', () async {
      await _runAdmin(adminPool, (exec) async {
        const expectedTriggers = <String, String>{
          'connector_sync_log_set_business_date': 'connector_sync_log',
          'inbound_webhook_dead_letter_set_business_date':
              'inbound_webhook_dead_letter',
          'sanity_log_set_business_date': 'sanity_log',
        };
        for (final entry in expectedTriggers.entries) {
          final rows = await exec.query(
            'select tgname '
            '  from pg_trigger '
            ' where tgname = @name '
            '   and not tgisinternal',
            parameters: <String, Object?>{'name': entry.key},
          );
          expect(
            rows,
            hasLength(1),
            reason:
                '${entry.value}: trigger ${entry.key} missing — '
                'migration not applied.',
          );
        }
      });
    });

    test('trigger function is SECURITY DEFINER, owned by forge_admin',
        () async {
      await _runAdmin(adminPool, (exec) async {
        final rows = await exec.query(
          "select p.prosecdef, r.rolname as owner "
          "  from pg_proc p "
          "  join pg_roles r on r.oid = p.proowner "
          " where p.proname = 'phase_8_set_business_date' "
          "   and p.pronamespace = 'public'::regnamespace",
        );
        expect(rows, hasLength(1));
        expect(
          rows.single['prosecdef'],
          isTrue,
          reason:
              'phase_8_set_business_date must be SECURITY DEFINER so '
              'the locations join succeeds across tenant contexts.',
        );
        expect(
          rows.single['owner'],
          equals('forge_admin'),
          reason:
              'phase_8_set_business_date must be owned by forge_admin '
              '(BYPASSRLS) so the RLS-enabled locations read works.',
        );
      });
    });
  });

  group('Phase 8 business_date denorm — write-side trigger', () {
    setUp(() async {
      // Clean per-test row noise; base fixtures (operator/org_unit/
      // location/connection) survive across tests.
      await _runAdmin(adminPool, (exec) async {
        for (final table in const <String>[
          'connector_sync_log',
          'inbound_webhook_dead_letter',
          'sanity_log',
        ]) {
          await exec.execute(
            'delete from public.$table '
            "where operator_id = '$_opId'::uuid",
          );
        }
      });
    });

    test('connector_sync_log: insert with business_date NULL '
        'denormalizes via location timezone + rollover', () async {
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'insert into public.connector_sync_log '
          '(operator_id, location_id, connection_id, event_kind, '
          ' occurred_at) '
          'values (@op::uuid, @loc::uuid, @conn::uuid, '
          "'poll_success', @ts::timestamptz)",
          parameters: <String, Object?>{
            'op': _opId,
            'loc': _locId,
            'conn': _connId,
            'ts': _occurredAtUtc,
          },
        );
        final rows = await exec.query(
          "select to_char(business_date, 'YYYY-MM-DD') as bd "
          '  from public.connector_sync_log '
          " where operator_id = '$_opId'::uuid",
        );
        expect(rows, hasLength(1));
        expect(rows.single['bd'], equals(_expectedBusinessDate));
      });
    });

    test(
      'inbound_webhook_dead_letter: insert with business_date NULL '
      'denormalizes via location timezone + rollover',
      () async {
        await _runAdmin(adminPool, (exec) async {
          await exec.execute(
            'insert into public.inbound_webhook_dead_letter '
            '(operator_id, location_id, vendor_id, vendor_event_id, '
            ' failure_kind, occurred_at) '
            'values (@op::uuid, @loc::uuid, @vendor, @evt, '
            "'signature_invalid', @ts::timestamptz)",
            parameters: <String, Object?>{
              'op': _opId,
              'loc': _locId,
              'vendor': 'lightspeed_lsk',
              'evt': '$_fixtureMarker:dl-1',
              'ts': _occurredAtUtc,
            },
          );
          final rows = await exec.query(
            "select to_char(business_date, 'YYYY-MM-DD') as bd "
            '  from public.inbound_webhook_dead_letter '
            " where operator_id = '$_opId'::uuid",
          );
          expect(rows, hasLength(1));
          expect(rows.single['bd'], equals(_expectedBusinessDate));
        });
      },
    );

    test('sanity_log: insert with business_date NULL denormalizes '
        'via location timezone + rollover', () async {
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'insert into public.sanity_log '
          '(operator_id, location_id, vendor_id, vendor_event_id, '
          ' rule, detected_at) '
          'values (@op::uuid, @loc::uuid, @vendor, @evt, '
          "'opened_in_future', @ts::timestamptz)",
          parameters: <String, Object?>{
            'op': _opId,
            'loc': _locId,
            'vendor': 'lightspeed_lsk',
            'evt': '$_fixtureMarker:sl-1',
            'ts': _occurredAtUtc,
          },
        );
        final rows = await exec.query(
          "select to_char(business_date, 'YYYY-MM-DD') as bd "
          '  from public.sanity_log '
          " where operator_id = '$_opId'::uuid",
        );
        expect(rows, hasLength(1));
        expect(rows.single['bd'], equals(_expectedBusinessDate));
      });
    });

    test('caller-supplied business_date is preserved (trigger no-op)',
        () async {
      // An explicit business_date passed on the INSERT must NOT be
      // overwritten by the trigger. This is the seam the spine-bridge
      // sink fanout relies on once it computes business_date Dart-
      // side.
      await _runAdmin(adminPool, (exec) async {
        await exec.execute(
          'insert into public.connector_sync_log '
          '(operator_id, location_id, connection_id, event_kind, '
          ' occurred_at, business_date) '
          'values (@op::uuid, @loc::uuid, @conn::uuid, '
          "'poll_success', @ts::timestamptz, '2025-01-01'::date)",
          parameters: <String, Object?>{
            'op': _opId,
            'loc': _locId,
            'conn': _connId,
            'ts': _occurredAtUtc,
          },
        );
        final rows = await exec.query(
          "select to_char(business_date, 'YYYY-MM-DD') as bd "
          '  from public.connector_sync_log '
          " where operator_id = '$_opId'::uuid",
        );
        expect(rows, hasLength(1));
        expect(
          rows.single['bd'],
          equals('2025-01-01'),
          reason:
              'Caller-supplied business_date was overwritten — the '
              'trigger must only fire on NULL.',
        );
      });
    });
  });
}

// ─── Admin helpers ───────────────────────────────────────────────────

Future<void> _runAdmin(
  PostgresPool pool,
  Future<void> Function(PostgresExecutor exec) body,
) async {
  final tx = await pool.beginTransaction();
  var finalized = false;
  try {
    await tx.execute(
      "select set_config('app.bypass_rls_audit', "
      "'system:phase_8_business_date_denorm_test', true)",
    );
    await body(tx);
    await tx.commit();
    finalized = true;
  } finally {
    if (!finalized) {
      try {
        await tx.rollback();
      } catch (_) {
        // Swallow rollback secondary failure; original error wins.
      }
    }
  }
}

Future<void> _cleanupFixtures(PostgresExecutor exec) async {
  // Order matters: per-test rows that cascade through the operator
  // delete are listed defensively even though the operator delete
  // would clean them up. Idempotent.
  Future<void> deleteFor(String table) async {
    await exec.execute(
      'delete from public.$table '
      "where operator_id = '$_opId'::uuid",
    );
  }

  const tables = <String>[
    'connector_sync_log',
    'inbound_webhook_dead_letter',
    'sanity_log',
    'connector_connection',
    'locations',
    'org_units',
    'operators',
  ];
  for (final table in tables) {
    await deleteFor(table);
  }
}

Future<void> _seedBaseFixtures(PostgresExecutor exec) async {
  await exec.execute(
    'insert into public.operators '
    '(operator_id, business_name, owner_email) '
    'values (@op::uuid, @name, @email) '
    'on conflict (operator_id) do nothing',
    parameters: <String, Object?>{
      'op': _opId,
      'name': 'Phase 8 business_date denorm fixture',
      'email': '$_opId@$_fixtureMarker.invalid',
    },
  );

  await exec.execute(
    'insert into public.org_units '
    '(id, operator_id, parent_id, unit_type, path, name) '
    "values (@id::uuid, @op::uuid, null, 'corp', "
    '@path::ltree, @name) '
    'on conflict (id) do nothing',
    parameters: <String, Object?>{
      'id': _ouId,
      'op': _opId,
      'path': 'bd80_root',
      'name': 'bd80 root',
    },
  );

  await exec.execute(
    'insert into public.locations '
    '(location_id, operator_id, parent_org_unit_id, name, timezone, '
    ' business_day_rollover_hour) '
    'values (@loc::uuid, @op::uuid, @ou::uuid, @name, @tz, '
    ' @rollover) '
    'on conflict (location_id) do nothing',
    parameters: <String, Object?>{
      'loc': _locId,
      'op': _opId,
      'ou': _ouId,
      'name': 'bd80 fixture location',
      'tz': _tz,
      'rollover': _rolloverHour,
    },
  );

  await exec.execute(
    'insert into public.connector_connection '
    '(connection_id, operator_id, location_id, vendor_id, category, '
    ' status) '
    "values (@conn::uuid, @op::uuid, @loc::uuid, 'lightspeed_lsk', "
    "'pos', 'connected') "
    'on conflict (connection_id) do nothing',
    parameters: <String, Object?>{
      'conn': _connId,
      'op': _opId,
      'loc': _locId,
    },
  );
}
