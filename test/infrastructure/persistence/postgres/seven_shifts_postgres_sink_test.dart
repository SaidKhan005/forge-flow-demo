// Phase 8 Wave B `8.spine-bridge.7S` — 7shifts Postgres sink test
// suite.
//
// Coverage matches the slice prompt's required tests A-H:
//
//   A. Round-trip with `seven_shifts_punches_fixture` — labor_punches
//      row carries the fixture-shape fact columns and a serialized
//      raw_payload.
//   B. Idempotency replay (second upsert returns false).
//   C. Watermark per batch (advanceWatermark UPSERT shape).
//   D. Demo-mode flip (evaluateDemoFlip writes the demo_mode_state row;
//      idempotent SQL shape preserves original triggering connection;
//      `category=labor` is bound).
//   E. RLS + tenancy (every public method runs through `withTenant` →
//      SET LOCAL `app.operator_id` / `app.location_id`).
//   F. Adapter pollIncremental smoke — drives `SevenShiftsLaborAdapter`
//      against the production sink (sink == SevenShiftsGateway) and
//      asserts at least one labor_punches INSERT lands when the
//      transport returns a single time punch + a closed payroll
//      period.
//   G. Wage-class invariant — every labor_punches INSERT issued by
//      the sink omits `labor_dollars` (V1 wage class is
//      `perEmployeeWithRates`); pay_rate is bound when supplied and
//      bound NULL otherwise.
//   H. Banned-items grep on sink source (V1 lean cut 2 ledger +
//      explicit `total_pay` rejection — that field belongs to lane
//      `.7S.upgrade`).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/labor/fixtures/seven_shifts_punches_fixture.dart'
    as fixture;

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _connId = '33333333-3333-3333-3333-333333333333';

/// Map a fixture record onto the canonical-sink dict shape. The shape
/// matches what the dispatcher hands `CanonicalSink.upsertLaborPunch`:
/// the typed fact's `toCanonicalDict()` plus the fields the labor
/// punch insert needs (employee_source_id, hours_worked, pay_rate).
Map<String, Object?> _canonicalFromFixture(
  Map<String, Object?> record, {
  num? payRate = 18.50,
}) {
  final clockedIn = DateTime.parse(record['clocked_in']! as String).toUtc();
  final clockedOutRaw = record['clocked_out'];
  DateTime? clockedOut;
  if (clockedOutRaw is String && clockedOutRaw.isNotEmpty) {
    clockedOut = DateTime.parse(clockedOutRaw).toUtc();
  }
  final durationSeconds =
      clockedOut == null ? 0 : clockedOut.difference(clockedIn).inSeconds;
  final role = record['role'] as Map<String, Object?>;
  return <String, Object?>{
    'vendor_entity_id': record['id']!.toString(),
    'vendor_modified_at': record['modified']! as String,
    'shift_start': record['clocked_in']! as String,
    'shift_end': clockedOutRaw is String && clockedOutRaw.isNotEmpty
        ? clockedOutRaw
        : null,
    'employee_source_id': record['user_id']!.toString(),
    'role_name': (role['name']! as String).toLowerCase(),
    'hours_worked': durationSeconds,
    if (payRate != null) 'pay_rate': payRate,
    'raw_payload': record,
  };
}

void main() {
  group('Test A — round-trip with seven_shifts_punches_fixture', () {
    test(
      'one fixture record → INSERT into labor_punches with operator-scoped '
      'columns, vendor_id="seven_shifts", pay_rate present, labor_dollars '
      'NOT supplied',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final wrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: _canonicalFromFixture(fixture.sevenShiftsSamplePunch),
        );
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.labor_punches'),
        );
        for (final column in <String>[
          'operator_id',
          'location_id',
          'employee_source_id',
          'role_name',
          'shift_start',
          'shift_end',
          'hours_worked',
          'pay_rate',
          'vendor_id',
          'vendor_entity_id',
          'vendor_modified_at',
          'raw_payload',
          'business_date',
        ]) {
          expect(insertSql, contains(column),
              reason: 'INSERT must list "$column" exactly once');
        }
        // labor_dollars must NOT appear in the INSERT — V1 wage class
        // `perEmployeeWithRates` leaves the column NULL; Lane `.2`'s
        // aggregator computes dollars via rate × duration until lane
        // `.7S.upgrade` plumbs vendor-side dollars through.
        expect(insertSql, isNot(contains('labor_dollars')),
            reason: 'sink must NOT supply labor_dollars; aggregator '
                'computes via rate × duration at V1');
        expect(insertSql, contains('on conflict (operator_id, vendor_id, '
            'vendor_entity_id, vendor_modified_at) do nothing'),
            reason: 'idempotency UNIQUE shape per spine contract');

        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['operator_id'], equals(_opA));
        expect(insertParams['location_id'], equals(_locA));
        expect(insertParams['employee_source_id'], equals('99001'));
        expect(insertParams['role_name'], equals('server'));
        expect(insertParams['vendor_entity_id'], equals('712001'));
        expect(insertParams['hours_worked'], equals(18900));
        expect(insertParams['pay_rate'], equals(18.50));
        expect(insertParams['vendor_id'], equals('seven_shifts'));
        expect(insertParams['shift_start'],
            equals(DateTime.utc(2026, 5, 3, 18, 30, 0)));
        expect(insertParams['shift_end'],
            equals(DateTime.utc(2026, 5, 3, 23, 45, 0)));
        expect(insertParams['vendor_modified_at'],
            equals(DateTime.utc(2026, 5, 4, 0, 5, 0)));
        // business_date computed via IanaTimezoneConverter from the
        // location's `America/New_York` timezone + 4-hour rollover:
        // shift_start 2026-05-03T18:30Z → 14:30 local → 2026-05-03.
        expect(insertParams['business_date'], equals('2026-05-03'));
        expect(insertParams['raw_payload'], isA<String>());
        expect(
          (insertParams['raw_payload'] as String).contains('"id":712001'),
          isTrue,
        );
      },
    );

    test(
      'open punch (clocked_out null in 7shifts payload) writes shift_end '
      'as NULL via the typed shift_end:null bind',
      () async {
        final openPunch =
            Map<String, Object?>.from(fixture.sevenShiftsSamplePunch)
              ..['clocked_out'] = null;
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: _canonicalFromFixture(openPunch),
        );

        final tx = pool.transactions.single;
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['shift_end'], isNull,
            reason: 'open punch → shift_end MUST bind as NULL so the '
                'aggregator can detect the in-progress state');
      },
    );
  });

  group('Test B — idempotency replay', () {
    test(
      'second arrival of (vendor_id, operator_id, vendor_entity_id, '
      'vendor_modified_at) hits ON CONFLICT DO NOTHING; upsert returns '
      'false the second time',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffectedSequence: <int>[1, 0],
        );
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        final canonical =
            _canonicalFromFixture(fixture.sevenShiftsSamplePunch);
        final firstWrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: canonical,
        );
        expect(firstWrote, isTrue);

        final secondWrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: canonical,
        );
        expect(secondWrote, isFalse,
            reason: 'idempotency UNIQUE short-circuit must surface as '
                'upsertLaborPunch == false on replay');
      },
    );
  });

  group('Test C — watermark per batch', () {
    test(
      'advanceWatermark UPSERTs into connector_sync_watermark with resource '
      '= "labor_punches" and (connection_id, resource) as the conflict key',
      () async {
        final pool = _SinkPool();
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '3',
          lastModifiedSeen: DateTime.utc(2026, 5, 4, 11, 30, 0),
        );

        final tx = pool.transactions.single;
        final upsertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.connector_sync_watermark'),
        );
        expect(upsertSql, contains('on conflict (connection_id, resource)'));
        expect(upsertSql, contains('do update set'));
        expect(upsertSql, contains('cursor_token = excluded.cursor_token'));
        expect(upsertSql,
            contains('last_modified_seen = excluded.last_modified_seen'));

        final params = tx.parameters.firstWhere(
          (p) => p['connection_id'] == _connId,
        );
        expect(params['resource'], equals('labor_punches'));
        expect(params['cursor_token'], equals('3'));
        expect(params['last_modified_seen'],
            equals(DateTime.utc(2026, 5, 4, 11, 30, 0)));
      },
    );

    test(
      'sevenShiftsWatermarkResource exported constant is the literal '
      '"labor_punches" string',
      () {
        expect(sevenShiftsWatermarkResource, equals('labor_punches'));
      },
    );
  });

  group('Test D — demo-mode flip (category=labor)', () {
    test(
      'connect + first backfill committed + records ≥ 1 → INSERT into '
      'demo_mode_state with is_demo=false; ON CONFLICT idempotent UPDATE '
      'guarded by is_demo=true preserves original triggering connection_id; '
      'category bound = "labor"',
      () async {
        final pool = _SinkPool();
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 5,
          connectionId: _connId,
        );

        final tx = pool.transactions.single;
        final flipSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.demo_mode_state'),
        );
        expect(flipSql, contains('false, @flipped_at'),
            reason: 'INSERT branch writes is_demo=false directly');
        expect(flipSql,
            contains('where public.demo_mode_state.is_demo = true'),
            reason: 'WHERE is_demo=true guards the UPDATE branch so the '
                'original triggering values are preserved on replay');

        final params = tx.parameters.firstWhere(
          (p) => p['connection_id'] == _connId,
        );
        expect(params['operator_id'], equals(_opA));
        expect(params['category'], equals('labor'),
            reason: '7shifts is a labor connector; demo flip MUST bind '
                'category=labor (not pos / reservation)');
      },
    );

    test(
      'gates fail → no INSERT issued (connection not yet connected, or '
      'first backfill not committed, or records=0)',
      () async {
        final pool = _SinkPool();
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        await sink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.disconnected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 5,
          connectionId: _connId,
        );
        await sink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: false,
          backfillRecordsWritten: 5,
          connectionId: _connId,
        );
        await sink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 0,
          connectionId: _connId,
        );

        expect(pool.transactions, isEmpty,
            reason: 'gate failures must short-circuit BEFORE opening a '
                'transaction; no SQL should reach Postgres');
      },
    );
  });

  group('Test E — RLS + tenancy', () {
    test(
      'upsertLaborPunch + advanceWatermark + appendSyncLog + '
      'evaluateDemoFlip all inject app.operator_id and app.location_id '
      'via SET LOCAL (set_config(..., true)) before any business SQL runs',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.sevenShiftsSamplePunch),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '1',
          lastModifiedSeen: DateTime.utc(2026, 5, 4, 11, 0, 0),
        );
        await sink.appendSyncLog(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          eventKind: 'poll_success',
          recordsCount: 1,
        );
        await sink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 1,
          connectionId: _connId,
        );

        expect(pool.transactions, hasLength(4));
        for (final tx in pool.transactions) {
          expect(
            tx.executedSql.where(
              (s) => s.contains("set_config('app.operator_id'"),
            ),
            hasLength(1),
            reason: 'tenant operator_id GUC must be set before business SQL',
          );
          expect(
            tx.executedSql.where(
              (s) => s.contains("set_config('app.location_id'"),
            ),
            hasLength(1),
            reason: 'tenant location_id GUC must be set before business SQL',
          );
          expect(tx.commitCount, equals(1),
              reason: 'tenant transaction must commit cleanly');
          expect(tx.rollbackCount, equals(0),
              reason: 'happy path must not roll back');
        }
      },
    );

    test(
      'TenantContext rejects malformed operator_id BEFORE opening a '
      'transaction',
      () async {
        final pool = _SinkPool();
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        Object? thrown;
        try {
          await sink.advanceWatermark(
            operatorId: 'not-a-uuid',
            locationId: _locA,
            connectionId: _connId,
            cursorToken: '1',
            lastModifiedSeen: DateTime.utc(2026, 5, 4),
          );
        } on TenantContextValidationError catch (error) {
          thrown = error;
        }
        expect(thrown, isA<TenantContextValidationError>());
        expect(pool.transactions, isEmpty,
            reason: 'no tx opened when operator_id fails strict UUID check');
      },
    );

    test(
      'a different operator (op_B) uses an isolated tenant context — the '
      'SET LOCAL payload carries op_B, not op_A, even when both calls '
      'reuse the same sink + pool',
      () async {
        final pool = _SinkPool();
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '1',
          lastModifiedSeen: DateTime.utc(2026, 5, 4),
        );
        await sink.advanceWatermark(
          operatorId: _opB,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '2',
          lastModifiedSeen: DateTime.utc(2026, 5, 4),
        );

        final txA = pool.transactions[0];
        final txB = pool.transactions[1];
        final paramsA = txA.parameters.firstWhere(
          (p) => p['value'] == _opA,
        );
        final paramsB = txB.parameters.firstWhere(
          (p) => p['value'] == _opB,
        );
        expect(paramsA['value'], equals(_opA));
        expect(paramsB['value'], equals(_opB));
      },
    );
  });

  group('Test F — adapter pollIncremental smoke', () {
    test(
      'SevenShiftsLaborAdapter.pollIncremental drives the production sink '
      '→ at least one labor_punches INSERT lands; payroll_period.closed '
      'instant is recorded via connector_sync_log',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          accessTokenRow: <String, Object?>{
            'access_token_ciphertext': 'fake-access-token',
          },
          companyIdRow: <String, Object?>{
            'company_id': 'co-7s-12345',
          },
          connectionIdRow: <String, Object?>{
            'connection_id': _connId,
          },
          insertAffected: 1,
        );
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        final transport = _SmokeTransport(
          punches: <Map<String, Object?>>[fixture.sevenShiftsSamplePunch],
          payrollPeriodClosedAt: DateTime.utc(2026, 5, 4, 8, 0, 0),
          // Lower plan tier — adapter falls back to the substituted-wage
          // provenance branch, which exercises the
          // recordHoursAndWagesReportGated path on the sink.
          hoursAndWagesGatedStatusCode: 403,
        );
        final adapter = SevenShiftsLaborAdapter(
          transport: transport,
          gateway: sink,
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        final result = await adapter.pollIncremental(
          PollIncrementalCommand(
            operatorId: _opA,
            locationId: _locA,
            actorUserId: '00000000-0000-4000-8000-000000000099',
            vendorId: 'seven_shifts',
            lastModifiedSeen: DateTime.utc(2026, 5, 1),
            sanityHook: (
                {required String vendorEventId,
                required Map<String, Object?> payload,
                required bool isDeliberateBackfill}) async =>
                true,
          ),
        );

        expect(result.recordsWritten, equals(1),
            reason: 'one fixture punch → exactly one labor_punches row');
        // At least one transaction issued the labor_punches INSERT.
        final inserts = pool.transactions
            .expand((tx) => tx.executedSql)
            .where((s) => s.contains('insert into public.labor_punches'))
            .toList();
        expect(inserts, isNotEmpty,
            reason: 'adapter→sink composition must issue the INSERT '
                'into public.labor_punches');
        // The closed payroll period got logged via connector_sync_log
        // with the `payroll_period_closed` event_kind.
        final payrollLogged = pool.transactions
            .expand((tx) => tx.parameters)
            .any(
              (p) => p['event_kind'] ==
                  kSevenShiftsPayrollPeriodClosedSyncLogKind,
            );
        expect(payrollLogged, isTrue,
            reason: 'payroll_period.closed instant must surface via '
                'connector_sync_log for the Phase 7.58 audit');
        // Hours-and-wages gating got logged exactly once.
        final gatedLogged = pool.transactions
            .expand((tx) => tx.parameters)
            .where((p) => p['event_kind'] ==
                kSevenShiftsHoursAndWagesReportGatedSyncLogKind)
            .toList();
        expect(gatedLogged, hasLength(1),
            reason: 'lower plan tier → exactly one '
                'hours_and_wages_report_gated log row per tick');
      },
    );
  });

  group('Test G — wage-class invariant (perEmployeeWithRates)', () {
    test(
      'every labor_punches INSERT issued by the sink omits labor_dollars; '
      'pay_rate is bound when supplied and bound NULL when absent from '
      'the canonical dict',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffectedSequence: <int>[1, 1],
        );
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        // Path 1 — canonical dict carries pay_rate.
        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: _canonicalFromFixture(
            fixture.sevenShiftsSamplePunch,
            payRate: 21.75,
          ),
        );
        // Path 2 — canonical dict has NO pay_rate key (employee row
        // has no rate on file). Bind null, NEVER fabricate a default.
        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: _canonicalFromFixture(
            // Use a different vendor_entity_id so the second INSERT
            // is not a replay short-circuit.
            <String, Object?>{
              ...fixture.sevenShiftsSamplePunch,
              'id': 712999,
              'modified': '2026-05-04T01:00:00Z',
            },
            payRate: null,
          ),
        );

        final allInserts = pool.transactions
            .expand((tx) => tx.executedSql)
            .where((s) => s.contains('insert into public.labor_punches'))
            .toList();
        expect(allInserts, hasLength(2));
        for (final sql in allInserts) {
          expect(sql, isNot(contains('labor_dollars')),
              reason: 'V1 wage class is `perEmployeeWithRates`; sink '
                  'MUST NOT supply labor_dollars in any INSERT');
          expect(sql, contains('pay_rate'),
              reason: 'pay_rate column must be in the column list so the '
                  'aggregator can compute dollars via rate × duration');
        }

        final laborInsertParams = pool.transactions
            .expand((tx) => tx.parameters)
            .where((p) => p.containsKey('employee_source_id'))
            .toList();
        expect(laborInsertParams, hasLength(2));
        expect(laborInsertParams[0]['pay_rate'], equals(21.75),
            reason: 'first INSERT carries the supplied pay_rate');
        expect(laborInsertParams[1]['pay_rate'], isNull,
            reason: 'second INSERT (no rate on file) binds pay_rate as '
                'NULL — never fabricated');
      },
    );
  });

  group('Test H — banned-items grep', () {
    test('sink source contains zero V1 lean cut 2 banned tokens', () {
      final source = File(
        'lib/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart',
      ).readAsStringSync();
      const banned = <String>[
        'kms.encrypt',
        'pgp_sym_encrypt_kms',
        'rotateSigningKey',
        'rotate_signing_key',
        'parse_warnings',
        'parse_partial',
        'kStrictReplayFiveMinute',
        'replay_strict_5min',
        'pg_try_advisory_lock',
        'pg_advisory_lock',
        'sigtermDrainHandler',
        'inboundWebhookDLQTile',
        'raw_payload_partition',
        'pg_partman_raw',
        // Lane `.7S.upgrade` adds /reports/hours_and_wages -> total_pay
        // plumbing. Until then this sink MUST NOT reference the
        // total_pay token in any form (column literal, string, comment
        // — none of it). The substring grep below is intentionally
        // case-insensitive so even a TODO comment trips it.
        'total_pay',
      ];
      final lower = source.toLowerCase();
      for (final token in banned) {
        expect(lower.contains(token.toLowerCase()), isFalse,
            reason: 'banned item present in sink source: $token');
      }
    });

    test(
      'sink source does not import package:postgres directly — uses the '
      'PostgresExecutor seam',
      () {
        final source = File(
          'lib/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart',
        ).readAsStringSync();
        expect(source.contains("import 'package:postgres/"), isFalse,
            reason: 'sink uses PostgresExecutor seam; direct '
                'package:postgres import not required');
      },
    );
  });

  group('Cover / reservation rejection (defense-in-depth)', () {
    test('upsertCoverFact throws UnsupportedError — labor sink', () async {
      final sink = SevenShiftsPostgresSink(
        tenantWrapper: TenantTransactionWrapper(_SinkPool()),
      );
      expect(
        () => sink.upsertCoverFact(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: const <String, Object?>{'vendor_entity_id': 'cv-1'},
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('upsertReservationFact throws UnsupportedError — labor sink',
        () async {
      final sink = SevenShiftsPostgresSink(
        tenantWrapper: TenantTransactionWrapper(_SinkPool()),
      );
      expect(
        () => sink.upsertReservationFact(
          operatorId: _opA,
          locationId: _locA,
          canonicalReservation: const <String, Object?>{
            'vendor_entity_id': 'r-1',
          },
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}

// ─── Fakes ──────────────────────────────────────────────────────────

PostgresRow _toLocationsRow() => <String, Object?>{
      'timezone': 'America/New_York',
      'business_day_rollover_hour': 4,
    };

class _SinkPool implements PostgresPool {
  _SinkPool({
    this.locationTimezoneRow,
    this.accessTokenRow,
    this.companyIdRow,
    this.connectionIdRow,
    int? insertAffected,
    List<int>? insertAffectedSequence,
  })  : _insertAffectedSequence = insertAffectedSequence != null
            ? List<int>.from(insertAffectedSequence)
            : (insertAffected != null
                ? <int>[insertAffected]
                : <int>[]);

  /// `(timezone, business_day_rollover_hour)` row returned by the
  /// fake `locations` SELECT. Required when a labor_punches INSERT
  /// reaches business_date computation.
  final PostgresRow? locationTimezoneRow;

  /// Row returned by `vendor_credentials` SELECT (used by the smoke
  /// test to feed the adapter an access token).
  final PostgresRow? accessTokenRow;

  /// Row returned by `connector_connection.metadata->>'company_id'`
  /// SELECT (used by the smoke test).
  final PostgresRow? companyIdRow;

  /// Row returned by `connector_connection.connection_id` SELECT.
  final PostgresRow? connectionIdRow;

  final List<int> _insertAffectedSequence;

  final List<_SinkTransaction> transactions = <_SinkTransaction>[];

  int _drainInsertAffected() {
    if (_insertAffectedSequence.isEmpty) return 0;
    return _insertAffectedSequence.removeAt(0);
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _SinkTransaction(
      locationTimezoneRow: locationTimezoneRow,
      accessTokenRow: accessTokenRow,
      companyIdRow: companyIdRow,
      connectionIdRow: connectionIdRow,
      drainInsertAffected: _drainInsertAffected,
    );
    transactions.add(tx);
    return tx;
  }
}

class _SinkTransaction extends PostgresTransaction {
  _SinkTransaction({
    required this.locationTimezoneRow,
    required this.accessTokenRow,
    required this.companyIdRow,
    required this.connectionIdRow,
    required this.drainInsertAffected,
  });

  final PostgresRow? locationTimezoneRow;
  final PostgresRow? accessTokenRow;
  final PostgresRow? companyIdRow;
  final PostgresRow? connectionIdRow;
  final int Function() drainInsertAffected;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  int commitCount = 0;
  int rollbackCount = 0;
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('select set_config')) {
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.locations')) {
      final row = locationTimezoneRow;
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[row];
    }
    if (sql.contains('from public.vendor_credentials')) {
      final row = accessTokenRow;
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[row];
    }
    if (sql.contains('from public.connector_connection')) {
      // Disambiguate between the company_id metadata SELECT and the
      // connection_id SELECT by inspecting the projection.
      if (sql.contains("metadata->>'company_id'")) {
        final row = companyIdRow;
        if (row == null) return const <PostgresRow>[];
        return <PostgresRow>[row];
      }
      final row = connectionIdRow;
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[row];
    }
    if (sql.contains('from public.connector_sync_log')) {
      // No prior payroll-period log row.
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.connector_sync_watermark')) {
      return const <PostgresRow>[];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('insert into public.labor_punches')) {
      return drainInsertAffected();
    }
    return 1;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
    commitCount += 1;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
    rollbackCount += 1;
  }
}

// ─── Smoke-test transport for Test F ────────────────────────────────

class _SmokeTransport implements SevenShiftsTransport {
  _SmokeTransport({
    required this.punches,
    required this.payrollPeriodClosedAt,
    this.hoursAndWagesGatedStatusCode,
  });

  final List<Map<String, Object?>> punches;
  final DateTime? payrollPeriodClosedAt;
  final int? hoursAndWagesGatedStatusCode;
  bool _delivered = false;

  @override
  Future<SevenShiftsTokenResponse> exchangeAuthorizationCode({
    required String authorizationCode,
    required String redirectUri,
  }) async =>
      SevenShiftsTokenResponse(
        accessToken: 'unused-in-poll-smoke',
        refreshToken: 'unused',
        expiresAt: DateTime.utc(2026, 5, 5),
      );

  @override
  Future<SevenShiftsTokenResponse> refresh({
    required String refreshToken,
  }) async =>
      SevenShiftsTokenResponse(
        accessToken: 'unused',
        refreshToken: 'unused',
        expiresAt: DateTime.utc(2026, 5, 5),
      );

  @override
  Future<void> revoke({required String accessToken}) async {}

  @override
  Future<SevenShiftsCompanyInfo> fetchCompanyInfo({
    required String accessToken,
  }) async =>
      const SevenShiftsCompanyInfo(
        companyId: 'co-7s-12345',
        planTier: 'entree',
      );

  @override
  Future<SevenShiftsTimePunchPage> listTimePunches({
    required String accessToken,
    required String companyId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    if (_delivered) {
      return SevenShiftsTimePunchPage(
        records: const <Map<String, Object?>>[],
        nextCursor: null,
        lastModifiedSeen: modifiedSince,
      );
    }
    _delivered = true;
    return SevenShiftsTimePunchPage(
      records: punches,
      nextCursor: null,
      lastModifiedSeen: DateTime.utc(2026, 5, 4, 0, 5, 0),
    );
  }

  @override
  Future<DateTime?> fetchLatestPayrollPeriodClosedAt({
    required String accessToken,
    required String companyId,
  }) async =>
      payrollPeriodClosedAt;

  @override
  Future<SevenShiftsHoursAndWagesPage> fetchHoursAndWagesReport({
    required String accessToken,
    required String companyId,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    required bool isDeliberateBackfill,
    String? cursor,
  }) async {
    final gated = hoursAndWagesGatedStatusCode;
    if (gated != null) {
      throw SevenShiftsHoursAndWagesReportGatedException(
        statusCode: gated,
        message: 'smoke-test fake transport: lower plan tier',
      );
    }
    return const SevenShiftsHoursAndWagesPage(
      rows: <SevenShiftsHoursAndWagesRow>[],
      nextCursor: null,
    );
  }

  @override
  Future<String> registerWebhook({
    required String accessToken,
    required String companyId,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async =>
      'unused-in-poll-smoke';

  @override
  Future<void> unregisterWebhook({
    required String accessToken,
    required String companyId,
    required String webhookId,
  }) async {}

  @override
  Future<Map<String, Object?>> samplePunch({
    required String accessToken,
    required String companyId,
  }) async =>
      const <String, Object?>{};
}
