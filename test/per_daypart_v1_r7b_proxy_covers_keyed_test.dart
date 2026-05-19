// Per-Daypart V1 Slice R7b — proxy covers-source onto the per-period
// keyed table / R7a view jsonb proving tests.
//
// R7b stops the PROXY from reading or writing the three legacy SQL
// columns
//   public.data_accuracy_settings.covers_source_{lunch,dinner,
//   late_night}
// (and the matching legacy scalar columns on
// public.data_accuracy_scoped_overrides). Covers source is routed
// through the keyed table
// public.data_accuracy_service_period_settings and resolved through
// the HP #11 hierarchy by public.effective_data_accuracy_settings_v's
// covers_source_per_service_period jsonb output (added in R7a). The
// three legacy JSON wire keys are still accepted on writes (mapped to
// their service_period_key) and still emitted in responses (derived
// from the keyed data) so no mobile/admin client breaks.
//
// These tests prove:
//
//   (a) NO LEGACY-COLUMN SQL — no SQL string in
//       tool/advisor_proxy/proxy_bootstrap.dart reads or writes the
//       legacy covers_source_{lunch,dinner,late_night} columns; the
//       proxy reads the view's covers_source_per_service_period jsonb
//       and writes the keyed table / the scoped-overrides jsonb.
//
//   (b) WIRE COMPAT — the three legacy JSON keys are still accepted on
//       writes (routed to the keyed table) and still emitted in
//       responses sourced from the keyed data; the per-period shape is
//       emitted alongside.
//
//   (c) PER-PERIOD + HP #11 — the per-period shape works for a
//       4-period operator including an org-unit-level admin scoped
//       override written to the R7a
//       data_accuracy_scoped_overrides.covers_source_per_service_period
//       jsonb.
//
//   (d) IDEMPOTENCY — every keyed / scoped covers write uses an
//       ON CONFLICT … DO UPDATE on the keyed/scoped UNIQUE identity so
//       a retried write is a no-op (idempotency contract preserved).
//
// Harness: the real proxy gateways over an in-test stub
// PostgresPool that records every SQL string + parameters, the same
// approach as test/proxy/closed_row_proxy_timing_provenance_test.dart
// and test/proxy/cache_invalidation_test.dart. Static SQL-text shape
// assertions follow test/per_daypart_v1_r5_covers_source_de_hardcode
// _test.dart / test/per_daypart_v1_r7a_covers_source_per_period
// _hierarchy_test.dart.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/auth_events_audit_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import '../tool/advisor_proxy/proxy_bootstrap.dart';

const String _opId = '22222222-2222-4222-8222-222222222222';
const String _locId = '33333333-3333-4333-8333-333333333333';
const String _userId = '11111111-1111-4111-8111-111111111111';

String _readProxyBootstrap() {
  final file = File('tool/advisor_proxy/proxy_bootstrap.dart');
  expect(
    file.existsSync(),
    isTrue,
    reason:
        'tests must run from repository root; expected '
        'tool/advisor_proxy/proxy_bootstrap.dart to exist',
  );
  return file.readAsStringSync().replaceAll('\r\n', '\n');
}

// Strip Dart line + block comments and single-quoted-with-double-quote
// edge cases are irrelevant here: every proxy SQL string is a single
// or adjacent-concatenated single-quoted string literal, so we keep
// the source verbatim and assert on SQL fragments that only appear
// inside query()/execute() string literals (e.g. "insert into
// public.data_accuracy_*", "from public.effective_data_accuracy_*").
// We additionally strip `//` line comments so the R7b explanatory
// comments (which legitimately mention the legacy column names in
// prose) do not produce false positives for the no-legacy-SQL guard.
String _stripLineComments(String src) {
  final out = StringBuffer();
  for (final line in src.split('\n')) {
    final idx = line.indexOf('//');
    if (idx >= 0) {
      // Keep anything before an inline `//`. Proxy SQL literals never
      // contain `//`, so this cannot truncate a SQL fragment.
      out.writeln(line.substring(0, idx));
    } else {
      out.writeln(line);
    }
  }
  return out.toString();
}

// Proxy SQL is built from adjacent single-quoted string literals
// (`'... '` newline `'...'`). To assert on a SQL fragment that spans a
// literal boundary, splice those seams together: collapse a closing
// quote followed by whitespace/newlines and a re-opening quote (with
// no `,`/`+` operator between, i.e. pure Dart string-literal
// adjacency concatenation) into nothing. This reconstructs the runtime
// SQL string without executing the code.
String _spliceAdjacentStringLiterals(String src) {
  // Matches: <single-quote> <any ws incl newlines> <single-quote>
  // i.e. the join between two adjacent string literals.
  return src.replaceAll(RegExp(r"'\s+'"), '');
}

void main() {
  group('R7b (a) — no legacy covers-column SQL in the proxy', () {
    test('proxy_bootstrap.dart contains zero SQL referencing the legacy '
        'covers_source_{lunch,dinner,late_night} columns; covers source '
        'is read from the view jsonb and written to the keyed / scoped '
        'tables', () {
      final code = _spliceAdjacentStringLiterals(
        _stripLineComments(_readProxyBootstrap()),
      );

      // No legacy covers column appears in any SQL projection /
      // INSERT column list / RETURNING / ON CONFLICT assignment.
      // After stripping `//` prose comments the only remaining
      // occurrences of these tokens are Dart JSON wire keys
      // (quoted map keys) and validation field labels — never a SQL
      // column reference. Assert the SQL-shaped forms are absent.
      for (final col in const <String>[
        'covers_source_lunch',
        'covers_source_dinner',
        'covers_source_late_night',
      ]) {
        // SELECT / RETURNING projection of a bare legacy column.
        expect(
          code.contains('s.$col'),
          isFalse,
          reason:
              'view-aliased legacy column $col must not be '
              'projected (use covers_source_per_service_period)',
        );
        // INSERT-target / ON CONFLICT assignment / coalesce against
        // the legacy column on either legacy table.
        expect(
          code.contains('data_accuracy_settings.$col'),
          isFalse,
          reason:
              'no proxy SQL may reference '
              'data_accuracy_settings.$col',
        );
        expect(
          code.contains('data_accuracy_scoped_overrides.$col'),
          isFalse,
          reason:
              'no proxy SQL may reference '
              'data_accuracy_scoped_overrides.$col',
        );
        expect(
          code.contains('$col = excluded.$col'),
          isFalse,
          reason: 'no proxy SQL may upsert the legacy column $col',
        );
      }

      // Reads go through the R7a view jsonb output.
      expect(
        code.contains('covers_source_per_service_period'),
        isTrue,
        reason: 'proxy must read/write the per-period jsonb',
      );
      expect(
        code.contains('public.effective_data_accuracy_settings_v'),
        isTrue,
        reason: 'covers source is read via the R7a hierarchy view',
      );
      // Writes go through the keyed table.
      expect(
        code.contains(
          'insert into public.data_accuracy_service_period_settings',
        ),
        isTrue,
        reason: 'legacy covers writes are routed to the keyed table',
      );
      // Scoped-override write targets the R7a jsonb column.
      expect(
        code.contains('covers_source_per_service_period = coalesce('),
        isTrue,
        reason: 'scoped override writes the R7a jsonb column',
      );
    });

    test('(d) keyed covers writes are idempotent via ON CONFLICT DO UPDATE '
        'on the keyed UNIQUE identity (scoped-jsonb merge idempotency is '
        'proven behaviorally in the admin org-unit test below)', () {
      final code = _spliceAdjacentStringLiterals(
        _stripLineComments(_readProxyBootstrap()),
      );
      // Keyed table ON CONFLICT identity (covers the legacy-key
      // route + the dedicated per-period route).
      expect(
        code.contains(
          'on conflict (operator_id, location_id, service_period_key, '
          'effective_at_business_date) do update set',
        ),
        isTrue,
        reason: 'keyed covers write must be idempotent',
      );
    });
  });

  group('R7b (b)+(c) — mobile read/write wire compat + per-period', () {
    test('fetchDataAccuracySettings reads the view per-period jsonb (no '
        'legacy column SELECT) and emits the legacy keys derived from it '
        'plus the per-period map (4-period operator)', () async {
      final pool = _StubPool(
        rowsByContains: <String, List<PostgresRow>>{
          // The effective view carries final values plus provenance.
          'from public.effective_data_accuracy_settings_v': <PostgresRow>[
            <String, Object?>{
              'setting_id': 'set-1',
              'operator_id': _opId,
              'location_id': _locId,
              'covers_source_per_service_period': <String, Object?>{
                'lunch': 'manual',
                'dinner': 'forecast',
                'late_night': 'vendor',
                'brunch': 'reservation_plus_walkin',
              },
              'covers_source_per_service_period_source': <String, Object?>{
                'lunch': <String, Object?>{
                  'scope_type': 'location',
                  'source_kind': 'service_period_setting',
                  'setting_id': 'sp-lunch',
                },
              },
              'covers_manual_entries': <String, Object?>{},
              'wage_source': 'vendor',
              'wage_source_source': <String, Object?>{
                'scope_type': 'business',
                'source_kind': 'scoped_override',
                'override_id': 'ovr-wage',
              },
              'walk_in_handling_mode': 'reservations_only',
              'walk_in_handling_mode_source': <String, Object?>{
                'scope_type': 'default',
                'source_kind': 'default',
              },
              'walk_in_manual_entries': <String, Object?>{},
              'created_at': DateTime.utc(2026, 5, 17),
              'updated_at': DateTime.utc(2026, 5, 17),
              'updated_by': _userId,
            },
          ],
        },
      );
      final gateway = RepositoryMobileOperationalSyncProxyGateway(
        tenantWrapper: TenantTransactionWrapper(pool),
      );

      final result = await gateway.fetchDataAccuracySettings(
        scope: const OperatorContext(
          userId: _userId,
          operatorId: _opId,
          locationId: _locId,
          roles: <String>['operator_owner'],
        ),
        operatorId: _opId,
        locationId: _locId,
      );

      // The SELECT must not name a legacy covers column and must
      // pull the effective view's per-period jsonb.
      final selectSql = pool.lastTx!.calls
          .map((c) => c.sql)
          .firstWhere(
            (s) => s.contains('from public.effective_data_accuracy_settings_v'),
          );
      expect(selectSql.contains('covers_source_lunch'), isFalse);
      expect(selectSql.contains('covers_source_dinner'), isFalse);
      expect(selectSql.contains('covers_source_late_night'), isFalse);
      expect(
        selectSql.contains('from public.effective_data_accuracy_settings_v'),
        isTrue,
      );
      expect(
        selectSql.contains('covers_source_per_service_period_source'),
        isTrue,
      );
      expect(selectSql.contains('wage_source_source'), isTrue);
      expect(selectSql.contains('walk_in_handling_mode_source'), isTrue);

      final data = result['data']! as Map<String, Object?>;
      // (b) legacy wire keys still emitted, sourced from keyed data.
      expect(data['covers_source_lunch'], 'manual');
      expect(data['covers_source_dinner'], 'forecast');
      expect(data['covers_source_late_night'], 'vendor');
      // (c) per-period map emitted alongside incl the 4th period.
      final perPeriod =
          data['covers_source_per_service_period']! as Map<String, Object?>;
      expect(perPeriod['lunch'], 'manual');
      expect(perPeriod['dinner'], 'forecast');
      expect(perPeriod['late_night'], 'vendor');
      expect(perPeriod['brunch'], 'reservation_plus_walkin');
      final sourceMap =
          data['covers_source_per_service_period_source']!
              as Map<String, Object?>;
      expect(sourceMap['lunch'], isA<Map<String, Object?>>());
      final wageSource = data['wage_source_source'] as Map<String, Object?>;
      expect(wageSource['scope_type'], 'business');
    });

    test('fetch emits vendor defaults for legacy keys when the keyed map '
        'has no row (unchanged default behavior)', () async {
      final pool = _StubPool(
        rowsByContains: <String, List<PostgresRow>>{
          'from public.effective_data_accuracy_settings_v': <PostgresRow>[
            <String, Object?>{
              'setting_id': 'set-1',
              'operator_id': _opId,
              'location_id': _locId,
              'covers_source_per_service_period': null,
              'covers_manual_entries': <String, Object?>{},
              'wage_source': 'vendor',
              'walk_in_handling_mode': 'reservations_only',
              'walk_in_manual_entries': <String, Object?>{},
              'created_at': DateTime.utc(2026, 5, 17),
              'updated_at': DateTime.utc(2026, 5, 17),
              'updated_by': _userId,
            },
          ],
        },
      );
      final gateway = RepositoryMobileOperationalSyncProxyGateway(
        tenantWrapper: TenantTransactionWrapper(pool),
      );

      final result = await gateway.fetchDataAccuracySettings(
        scope: const OperatorContext(
          userId: _userId,
          operatorId: _opId,
          locationId: _locId,
          roles: <String>['operator_owner'],
        ),
        operatorId: _opId,
        locationId: _locId,
      );
      final data = result['data']! as Map<String, Object?>;
      expect(data['covers_source_lunch'], 'vendor');
      expect(data['covers_source_dinner'], 'vendor');
      expect(data['covers_source_late_night'], 'vendor');
    });

    test('upsertDataAccuracySettings accepts the legacy JSON keys, routes '
        'them to the keyed table (no legacy-column INSERT), and emits '
        'the legacy keys back sourced from the keyed view jsonb', () async {
      final pool = _StubPool(
        rowsByContains: <String, List<PostgresRow>>{
          'insert into public.data_accuracy_settings': <PostgresRow>[
            <String, Object?>{
              'setting_id': 'set-1',
              'operator_id': _opId,
              'location_id': _locId,
              'covers_manual_entries': <String, Object?>{},
              'wage_source': 'vendor',
              'walk_in_handling_mode': 'reservations_only',
              'walk_in_manual_entries': <String, Object?>{},
              'created_at': DateTime.utc(2026, 5, 17),
              'updated_at': DateTime.utc(2026, 5, 17),
              'updated_by': _userId,
            },
          ],
          // Post-write re-read via the effective view.
          'from public.effective_data_accuracy_settings_v': <PostgresRow>[
            <String, Object?>{
              'setting_id': 'set-1',
              'operator_id': _opId,
              'location_id': _locId,
              'covers_source_per_service_period': <String, Object?>{
                'lunch': 'forecast',
                'dinner': 'forecast',
                'late_night': 'vendor',
                'breakfast': 'manual',
              },
              'covers_manual_entries': <String, Object?>{},
              'wage_source': 'vendor',
              'walk_in_handling_mode': 'reservations_only',
              'walk_in_manual_entries': <String, Object?>{},
              'created_at': DateTime.utc(2026, 5, 17),
              'updated_at': DateTime.utc(2026, 5, 17),
              'updated_by': _userId,
            },
          ],
        },
      );
      final gateway = RepositoryMobileOperationalSyncProxyGateway(
        tenantWrapper: TenantTransactionWrapper(pool),
      );

      final result = await gateway.upsertDataAccuracySettings(
        scope: const OperatorContext(
          userId: _userId,
          operatorId: _opId,
          locationId: _locId,
          roles: <String>['operator_owner'],
        ),
        operatorId: _opId,
        locationId: _locId,
        body: <String, Object?>{
          // Legacy wire keys still accepted (no breaking change).
          'covers_source_lunch': 'forecast',
          'covers_source_dinner': 'manual',
          'covers_source_late_night': 'vendor',
          'covers_source_per_service_period': <String, Object?>{
            'breakfast': 'manual',
            // Explicit keyed values win when both shapes provide
            // the same service period.
            'dinner': 'forecast',
          },
          'wage_source': 'vendor',
          'walk_in_handling_mode': 'reservations_only',
        },
      );

      final calls = pool.lastTx!.calls;
      // The data_accuracy_settings INSERT must not write a legacy
      // covers column.
      final settingsInsert = calls
          .map((c) => c.sql)
          .firstWhere(
            (s) => s.contains('insert into public.data_accuracy_settings'),
          );
      expect(settingsInsert.contains('covers_source_lunch'), isFalse);
      expect(settingsInsert.contains('covers_source_dinner'), isFalse);
      expect(settingsInsert.contains('covers_source_late_night'), isFalse);

      // Four keyed-table writes: the three legacy dayparts plus a
      // custom keyed period, all with the 1970-01-01 sentinel +
      // idempotent ON CONFLICT.
      final keyedWrites = calls
          .where(
            (c) => c.sql.contains(
              'insert into public.data_accuracy_service_period_settings',
            ),
          )
          .toList();
      expect(keyedWrites, hasLength(4));
      final writtenPeriods = keyedWrites
          .map((c) => c.parameters['service_period_key'])
          .toSet();
      expect(
        writtenPeriods,
        equals(<String>{'lunch', 'dinner', 'late_night', 'breakfast'}),
      );
      for (final w in keyedWrites) {
        expect(
          w.sql.contains(
            'on conflict (operator_id, location_id, '
            'service_period_key, effective_at_business_date) '
            'do update set',
          ),
          isTrue,
        );
        expect(w.sql.contains("date '1970-01-01'"), isTrue);
      }
      // covers param routed by daypart.
      final byPeriod = <Object?, Object?>{
        for (final w in keyedWrites)
          w.parameters['service_period_key']: w.parameters['covers_source'],
      };
      expect(byPeriod['lunch'], 'forecast');
      expect(byPeriod['dinner'], 'forecast');
      expect(byPeriod['late_night'], 'vendor');
      expect(byPeriod['breakfast'], 'manual');

      // Response still carries the legacy keys, now sourced from
      // the keyed view jsonb (no breaking wire change).
      final data = result['data']! as Map<String, Object?>;
      expect(data['covers_source_lunch'], 'forecast');
      expect(data['covers_source_dinner'], 'forecast');
      expect(data['covers_source_late_night'], 'vendor');
      expect(
        data['covers_source_per_service_period'],
        equals(<String, Object?>{
          'lunch': 'forecast',
          'dinner': 'forecast',
          'late_night': 'vendor',
          'breakfast': 'manual',
        }),
      );
    });

    test('upsertDataAccuracySettings does not synthesize legacy dayparts '
        'for keyed-only clients', () async {
      final pool = _StubPool(
        rowsByContains: <String, List<PostgresRow>>{
          'insert into public.data_accuracy_settings': <PostgresRow>[
            <String, Object?>{
              'setting_id': 'set-1',
              'operator_id': _opId,
              'location_id': _locId,
              'covers_manual_entries': <String, Object?>{},
              'wage_source': 'vendor',
              'walk_in_handling_mode': 'reservations_only',
              'walk_in_manual_entries': <String, Object?>{},
              'created_at': DateTime.utc(2026, 5, 19),
              'updated_at': DateTime.utc(2026, 5, 19),
              'updated_by': _userId,
            },
          ],
          'from public.effective_data_accuracy_settings_v': <PostgresRow>[
            <String, Object?>{
              'setting_id': 'set-1',
              'operator_id': _opId,
              'location_id': _locId,
              'covers_source_per_service_period': <String, Object?>{
                'breakfast': 'vendor',
                'lunch': 'manual',
                'dinner': 'forecast',
                'late_service': 'manual',
              },
              'covers_manual_entries': <String, Object?>{},
              'wage_source': 'vendor',
              'walk_in_handling_mode': 'reservations_only',
              'walk_in_manual_entries': <String, Object?>{},
              'created_at': DateTime.utc(2026, 5, 19),
              'updated_at': DateTime.utc(2026, 5, 19),
              'updated_by': _userId,
            },
          ],
        },
      );
      final gateway = RepositoryMobileOperationalSyncProxyGateway(
        tenantWrapper: TenantTransactionWrapper(pool),
      );

      await gateway.upsertDataAccuracySettings(
        scope: const OperatorContext(
          userId: _userId,
          operatorId: _opId,
          locationId: _locId,
          roles: <String>['operator_owner'],
        ),
        operatorId: _opId,
        locationId: _locId,
        body: <String, Object?>{
          'covers_source_per_service_period': <String, Object?>{
            'breakfast': 'vendor',
            'lunch': 'manual',
            'dinner': 'forecast',
            'late_service': 'manual',
          },
          'wage_source': 'vendor',
          'walk_in_handling_mode': 'reservations_only',
        },
      );

      final keyedWrites = pool.lastTx!.calls
          .where(
            (c) => c.sql.contains(
              'insert into public.data_accuracy_service_period_settings',
            ),
          )
          .toList();
      final writtenPeriods = keyedWrites
          .map((c) => c.parameters['service_period_key'])
          .toSet();
      expect(
        writtenPeriods,
        equals(<String>{'breakfast', 'lunch', 'dinner', 'late_service'}),
      );
      expect(writtenPeriods.contains('late_night'), isFalse);
    });
  });

  group('R7b (c) — admin org-unit scoped override → per-period jsonb', () {
    test('overrideDataAccuracyScope writes the supplied dayparts into the '
        'R7a covers_source_per_service_period jsonb (no legacy scalar '
        'columns) on an org_unit scope, idempotent + non-destructive '
        'merge', () async {
      final pool = _StubPool(
        rowsByContains: <String, List<PostgresRow>>{
          // _assertScopeExists for org_unit.
          'from org_units where operator_id': <PostgresRow>[
            <String, Object?>{'?column?': 1},
          ],
          'insert into data_accuracy_scoped_overrides': <PostgresRow>[
            <String, Object?>{'override_id': 'ovr-1'},
          ],
          // _dataAccuracyRowsForScope (view read) returns one row.
          'from operators o': <PostgresRow>[
            <String, Object?>{
              'operator_id': _opId,
              'business_name': 'Acme',
              'location_id': _locId,
              'location_name': 'North Loop',
              'setting_id': 'set-1',
              'covers_source_per_service_period': <String, Object?>{
                'lunch': 'forecast',
                'dinner': 'forecast',
                'breakfast': 'manual',
              },
              'covers_manual_entries': <String, Object?>{},
              'wage_source': 'vendor',
              'walk_in_handling_mode': 'reservations_only',
              'walk_in_manual_entries': <String, Object?>{},
              'created_at': DateTime.utc(2026, 5, 17),
              'updated_at': DateTime.utc(2026, 5, 17),
              'updated_by': _userId,
            },
          ],
          'insert into auth_events_audit': <PostgresRow>[
            <String, Object?>{
              'event_id': '99999999-9999-4999-8999-999999999999',
            },
          ],
        },
      );
      final wrapper = TenantTransactionWrapper(pool);
      final gateway = RepositoryDataAccuracyAdminProxyGateway(
        adminWrapper: wrapper,
        auditRepository: AuthEventsAuditRepository(wrapper),
      );

      final result = await gateway.overrideDataAccuracyScope(
        actorUserId: _userId,
        operatorId: _opId,
        scopeType: 'org_unit',
        orgUnitId: '44444444-4444-4444-8444-444444444444',
        coversSourceLunch: 'manual',
        coversSourceDinner: 'forecast',
        coversSourcePerServicePeriod: <String, String>{
          'breakfast': 'manual',
          'lunch': 'forecast',
        },
        adminReason: 'admin.test.scope_override',
      );

      final calls = pool.lastTx!.calls;
      final scopedInsert = calls
          .map((c) => c.sql)
          .firstWhere(
            (s) => s.contains('insert into data_accuracy_scoped_overrides'),
          );
      // No legacy scalar covers column written.
      expect(scopedInsert.contains('covers_source_lunch'), isFalse);
      expect(scopedInsert.contains('covers_source_dinner'), isFalse);
      expect(scopedInsert.contains('covers_source_late_night'), isFalse);
      // Writes the R7a jsonb column with a non-destructive,
      // idempotent merge of the supplied dayparts only.
      expect(
        scopedInsert.contains('covers_source_per_service_period, wage_source'),
        isTrue,
      );
      expect(
        scopedInsert.contains(
          "data_accuracy_scoped_overrides.covers_source_per_service_period, "
          "'{}'::jsonb) || @covers_per_period::jsonb",
        ),
        isTrue,
      );
      final scopedCall = calls.firstWhere(
        (c) => c.sql.contains('insert into data_accuracy_scoped_overrides'),
      );
      // Supplied keyed dayparts are merged with legacy inputs;
      // explicit keyed values win for duplicate periods. late_night
      // (null) is omitted so its existing scoped value is preserved
      // by the `existing || new` merge.
      final coversParam =
          jsonDecode(scopedCall.parameters['covers_per_period']! as String)
              as Map<String, Object?>;
      expect(
        coversParam,
        equals(<String, Object?>{
          'lunch': 'forecast',
          'dinner': 'forecast',
          'breakfast': 'manual',
        }),
      );

      // The affected-rows read surfaces the per-period jsonb (the
      // view resolves HP #11 precedence; here the org-unit scope's
      // lunch/dinner show through).
      final rows = result['rows']! as List<Object?>;
      final settings =
          (rows.single as Map<String, Object?>)['settings']!
              as Map<String, Object?>;
      expect(settings['covers_source_lunch'], 'forecast');
      expect(settings['covers_source_dinner'], 'forecast');
      expect(
        settings['covers_source_per_service_period'],
        equals(<String, Object?>{
          'lunch': 'forecast',
          'dinner': 'forecast',
          'breakfast': 'manual',
        }),
      );
    });
  });
}

// Records every query/execute SQL + parameters against the real proxy
// gateways. Mirrors the stub-pool harness in
// test/proxy/closed_row_proxy_timing_provenance_test.dart and
// test/proxy/cache_invalidation_test.dart.
class _StubPool implements PostgresPool {
  _StubPool({this.rowsByContains = const <String, List<PostgresRow>>{}});

  final Map<String, List<PostgresRow>> rowsByContains;
  _StubTx? lastTx;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _StubTx(rowsByContains: rowsByContains);
    lastTx = tx;
    return tx;
  }
}

class _StubCall {
  _StubCall(this.sql, this.parameters);
  final String sql;
  final PostgresParameters parameters;
}

class _StubTx implements PostgresTransaction {
  _StubTx({required this.rowsByContains});

  final Map<String, List<PostgresRow>> rowsByContains;
  final List<_StubCall> calls = <_StubCall>[];

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    calls.add(_StubCall(sql, parameters));
    for (final entry in rowsByContains.entries) {
      if (sql.contains(entry.key)) return entry.value;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    calls.add(_StubCall(sql, parameters));
    return 0;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
