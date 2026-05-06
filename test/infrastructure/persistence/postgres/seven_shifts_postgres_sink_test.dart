// Phase 8 Wave B `8.spine-bridge-sink-fanout.7S` — 7shifts Postgres
// sink test suite.
//
// Coverage mirrors the AG / QBT / ADP / PU sink suites:
//
//   A. Round-trip with the 7shifts time-punch fixture +
//      Hours & Wages report fixture: one canonical fact lands an
//      INSERT into `labor_punches` with operator-scoped columns and
//      `vendor_id = 'seven_shifts'`; `pay_rate` is derived from the
//      wage report (actual_labor_dollars / hours).
//   B. Idempotency replay (second writeTimePunchFact returns false).
//   C. Watermark per batch (advanceWatermark / writeWatermark UPSERT
//      shape; resource = 'labor_punches'; `connectionId` widened —
//      bespoke caller path resolves via `connector_connection`).
//   D. Demo-mode flip — `markLaborLive` writes a `demo_mode_state`
//      row with `category = 'labor'`; idempotent ON CONFLICT shape.
//   E. RLS + tenancy — every public method runs through `withTenant`.
//   F. Disconnect / credential wipe — `wipeCredentials` blanks
//      ciphertexts + flips connector_connection to disconnected;
//      watermark survives.
//   G. Hours-and-wages-gated log path — `recordHoursAndWagesReportGated`
//      appends a `connector_sync_log` row with the right `event_kind`
//      and `payload_preview` shape.
//   H. Banned-items grep on sink source — V1 lean cut 2 ledger plus
//      a wage-dollar zombie-token guard pinning that the INSERT
//      column list does NOT carry `actual_labor_dollars`, `regular_pay`,
//      `overtime_pay` outside the `jsonEncode(rawPayload)` call.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/seven_shifts_labor_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/labor/fixtures/seven_shifts_hours_and_wages_fixture.dart'
    as wages_fixture;
import '../../../integrations/labor/fixtures/seven_shifts_punches_fixture.dart'
    as punches_fixture;

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _connId = '33333333-3333-3333-3333-333333333333';
const String _connIdResolved = '55555555-5555-5555-5555-555555555555';

/// Build a canonical-fact dict from one fixture punch row + an
/// optional wage row keyed by (employeeId, shiftId). Mirrors the
/// adapter's `_canonicalizePunch` projection so the sink test
/// exercises the same dict shape the adapter produces.
Map<String, Object?> _canonicalFromPunch(
  Map<String, Object?> punch, {
  wages_fixture.SevenShiftsHoursAndWagesRow? wageRow,
}) {
  final role = punch['role'];
  final roleName = role is Map ? (role['name']?.toString() ?? '') : '';
  final shiftIdRaw = punch['shift_id'];
  final shiftId = shiftIdRaw?.toString();
  return <String, Object?>{
    'vendor_entity_id': punch['id']!.toString(),
    'vendor_modified_at': punch['modified']! as String,
    'employee_id': punch['user_id']!.toString(),
    'role_name': roleName.toLowerCase(),
    'shift_start': punch['clocked_in']! as String,
    'shift_end':
        punch['clocked_out'] is String ? punch['clocked_out'] as String : null,
    'is_approved': punch['approved'] as bool? ?? false,
    'shift_id': (shiftId == null || shiftId.isEmpty) ? null : shiftId,
    'actual_labor_dollars': wageRow?.totalPay,
    'regular_pay': wageRow?.regularPay,
    'overtime_pay': wageRow?.overtimePay,
    'wage_provenance': wageRow == null
        ? kSevenShiftsProvenanceDollarsUnavailableTargetSubstituted
        : kSevenShiftsProvenancePerEmployeeActualDollars,
    'raw_payload': punch,
  };
}

void main() {
  group('Test A — round-trip with 7shifts fixtures + Hours & Wages merge',
      () {
    test(
      'one canonical fact (with wage row) → INSERT into labor_punches '
      'with operator-scoped columns, vendor_id="seven_shifts", '
      'pay_rate derived from actual_labor_dollars / hours_worked, '
      'wage_provenance = per_employee_actual_dollars stashed in raw_payload',
      () async {
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        // First punch + matching wage row from the fixture.
        final punch = wages_fixture.sevenShiftsTimePunchesWithShiftIds[0];
        final wageRow = wages_fixture.sevenShiftsHoursAndWagesReportRows[0];
        final canonical = _canonicalFromPunch(punch, wageRow: wageRow);
        final wrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: canonical,
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
        // Wage-dollar columns do NOT exist on labor_punches at V1 lean
        // cut 2 — the dollar payload lives in raw_payload only.
        expect(insertSql, isNot(contains('actual_labor_dollars')),
            reason: 'wage-dollar column must not appear in INSERT column list');
        expect(insertSql, isNot(contains('regular_pay')),
            reason: 'wage-dollar column must not appear in INSERT column list');
        expect(insertSql, isNot(contains('overtime_pay')),
            reason: 'wage-dollar column must not appear in INSERT column list');
        expect(
          insertSql,
          contains('on conflict (operator_id, vendor_id, '
              'vendor_entity_id, vendor_modified_at) do nothing'),
          reason: 'idempotency UNIQUE shape per spine contract',
        );

        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['operator_id'], equals(_opA));
        expect(insertParams['location_id'], equals(_locA));
        expect(insertParams['employee_source_id'], equals('99001'));
        expect(insertParams['role_name'], equals('server'));
        expect(insertParams['vendor_id'], equals(kSevenShiftsVendorId));
        expect(insertParams['vendor_id'], equals('seven_shifts'));
        expect(insertParams['vendor_entity_id'], equals('712301'));
        expect(insertParams['shift_start'],
            equals(DateTime.utc(2026, 5, 3, 18, 0, 0)));
        expect(insertParams['shift_end'],
            equals(DateTime.utc(2026, 5, 3, 23, 30, 0)));
        // hours_worked = (23:30 - 18:00) = 5.5h = 19800s.
        expect(insertParams['hours_worked'], equals(19800));
        // pay_rate derived: 137.50 USD / 5.5h ≈ 25.0 USD/hr.
        // Computed as actual_labor_dollars * 3600 / hours_worked_seconds.
        final payRate = insertParams['pay_rate'];
        expect(payRate, isA<num>());
        expect(payRate as num, closeTo(25.0, 1e-9));
        // raw_payload carries the wage-dollar payload + provenance.
        final rawPayloadJson = insertParams['raw_payload'] as String;
        final decoded = jsonDecode(rawPayloadJson) as Map<String, Object?>;
        expect(decoded['actual_labor_dollars'], equals(137.50));
        expect(decoded['regular_pay'], equals(110.00));
        expect(decoded['overtime_pay'], equals(27.50));
        expect(decoded['wage_provenance'],
            equals(kSevenShiftsProvenancePerEmployeeActualDollars));
        expect(decoded['shift_id'], equals('887701'));
        // business_date computed via IanaTimezoneConverter from the
        // location's `America/New_York` timezone + 4-hour rollover:
        // shift_start 2026-05-03T18:00:00Z → 14:00 local → 2026-05-03.
        expect(insertParams['business_date'], equals('2026-05-03'));
      },
    );

    test(
      'open punch (clocked_out null) → shift_end binds NULL and '
      'hours_worked binds NULL; pay_rate also NULL when no wage merge',
      () async {
        final openPunch = punches_fixture.sevenShiftsBackfillBatchPage2[1];
        // Sanity: the fixture's open-punch row has a null clocked_out.
        expect(openPunch['clocked_out'], isNull);
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
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
          canonicalPunch: _canonicalFromPunch(openPunch),
        );

        final tx = pool.transactions.single;
        final params = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(params['shift_end'], isNull,
            reason: 'open punch → shift_end MUST bind as NULL so the '
                'aggregator can detect the in-progress state');
        expect(params['hours_worked'], isNull,
            reason: 'open punch → hours_worked has no upper bound; '
                'bind NULL rather than fabricate a duration');
        expect(params['pay_rate'], isNull,
            reason: 'no wage merge / no hours → pay_rate must be NULL');
      },
    );

    test(
      'CanonicalSink.upsertLaborPunch and SevenShiftsGateway.writeTimePunchFact '
      'hit the same shared writer (one INSERT, same column list)',
      () async {
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final fact = SevenShiftsCanonicalTimePunchFact(
          operatorId: _opA,
          locationId: _locA,
          vendorEntityId: '712301',
          vendorModifiedAt: DateTime.utc(2026, 5, 3, 23, 35, 0),
          employeeId: '99001',
          roleName: 'server',
          shiftStart: DateTime.utc(2026, 5, 3, 18, 0, 0),
          shiftEnd: DateTime.utc(2026, 5, 3, 23, 30, 0),
          isApproved: true,
          rawPayload: const <String, Object?>{'id': 712301},
          wageProvenance: kSevenShiftsProvenancePerEmployeeActualDollars,
          shiftId: '887701',
          actualLaborDollars: 137.50,
          regularPay: 110.00,
          overtimePay: 27.50,
        );
        final wrote = await sink.writeTimePunchFact(fact);
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.labor_punches'),
        );
        expect(insertSql, contains('vendor_id'));
        final params = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(params['vendor_id'], equals('seven_shifts'));
        expect(params['vendor_entity_id'], equals('712301'));
      },
    );
  });

  group('Test B — idempotency replay', () {
    test(
      'second arrival of (vendor_id, operator_id, vendor_entity_id, '
      'vendor_modified_at) hits ON CONFLICT DO NOTHING; writeTimePunchFact '
      'returns false the second time',
      () async {
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
          locationTimezoneRow: _toLocationsRow(),
          insertAffectedSequence: <int>[1, 0],
        );
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final fact = SevenShiftsCanonicalTimePunchFact(
          operatorId: _opA,
          locationId: _locA,
          vendorEntityId: '712301',
          vendorModifiedAt: DateTime.utc(2026, 5, 3, 23, 35, 0),
          employeeId: '99001',
          roleName: 'server',
          shiftStart: DateTime.utc(2026, 5, 3, 18, 0, 0),
          shiftEnd: DateTime.utc(2026, 5, 3, 23, 30, 0),
          isApproved: true,
          rawPayload: const <String, Object?>{},
          wageProvenance:
              kSevenShiftsProvenanceDollarsUnavailableTargetSubstituted,
        );
        final firstWrote = await sink.writeTimePunchFact(fact);
        expect(firstWrote, isTrue);
        final secondWrote = await sink.writeTimePunchFact(fact);
        expect(secondWrote, isFalse,
            reason: 'idempotency UNIQUE short-circuit must surface as '
                'writeTimePunchFact == false on replay');
      },
    );
  });

  group('Test C — watermark per batch', () {
    test(
      'advanceWatermark UPSERTs into connector_sync_watermark with '
      'resource = "labor_punches" and (connection_id, resource) as the '
      'conflict key (unified-interface caller path: explicit connectionId)',
      () async {
        final pool = _SinkPool(connectorConnectionId: _connIdResolved);
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: 'cursor-after-batch-3',
          lastModifiedSeen: DateTime.utc(2026, 5, 3, 23, 35, 0),
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
        expect(params['resource'], equals(kSevenShiftsWatermarkResource));
        expect(params['cursor_token'], equals('cursor-after-batch-3'));
        expect(params['last_modified_seen'],
            equals(DateTime.utc(2026, 5, 3, 23, 35, 0)));
      },
    );

    test(
      'bespoke-interface caller path (writeWatermark): connectionId '
      'omitted → sink resolves connection_id from connector_connection '
      '(operator, location, vendor=seven_shifts) before the UPSERT',
      () async {
        final pool = _SinkPool(connectorConnectionId: _connIdResolved);
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.writeWatermark(
          operatorId: _opA,
          locationId: _locA,
          row: SevenShiftsWatermarkRow(
            cursorToken: 'cursor-1',
            lastModifiedSeen: DateTime.utc(2026, 5, 3, 23, 35, 0),
          ),
        );

        final tx = pool.transactions.single;
        final selectIdx = tx.executedSql.indexWhere(
          (s) => s.contains('from public.connector_connection'),
        );
        final insertIdx = tx.executedSql.indexWhere(
          (s) => s.contains('insert into public.connector_sync_watermark'),
        );
        expect(selectIdx, greaterThanOrEqualTo(0),
            reason: 'sink must read connector_connection when '
                'connectionId is omitted by the bespoke caller');
        expect(selectIdx < insertIdx, isTrue,
            reason: 'lookup must precede the watermark UPSERT');

        final upsertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('cursor_token'),
        );
        expect(upsertParams['connection_id'], equals(_connIdResolved));
        expect(upsertParams['resource'], equals('labor_punches'));
      },
    );
  });

  group('Test D — demo-mode flip (markLaborLive + evaluateDemoFlip)', () {
    test(
      'markLaborLive INSERTs into demo_mode_state with category="labor", '
      'is_demo=false; ON CONFLICT WHERE is_demo=true preserves the '
      'original triggering connection_id on a second call',
      () async {
        final pool = _SinkPool();
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.markLaborLive(
          operatorId: _opA,
          locationId: _locA,
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
        expect(params['category'], equals('labor'));
      },
    );

    test(
      'evaluateDemoFlip with gates met issues the same flip SQL as '
      'markLaborLive; gate failures short-circuit before opening a tx',
      () async {
        // Gates met → SQL flows.
        final goodPool = _SinkPool();
        final goodSink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(goodPool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await goodSink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 5,
          connectionId: _connId,
        );
        expect(goodPool.transactions, hasLength(1));
        final flipSql = goodPool.transactions.single.executedSql.firstWhere(
          (s) => s.contains('insert into public.demo_mode_state'),
        );
        expect(flipSql,
            contains('where public.demo_mode_state.is_demo = true'));

        // Gate failures → no transaction at all.
        final badPool = _SinkPool();
        final badSink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(badPool),
        );
        await badSink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.disconnected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 5,
          connectionId: _connId,
        );
        await badSink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: false,
          backfillRecordsWritten: 5,
          connectionId: _connId,
        );
        await badSink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 0,
          connectionId: _connId,
        );
        expect(badPool.transactions, isEmpty,
            reason: 'gate failures must short-circuit BEFORE opening a '
                'transaction; no SQL should reach Postgres');
      },
    );
  });

  group('Test E — RLS + tenancy', () {
    test(
      'every public method runs through `withTenant` → SET LOCAL '
      'app.operator_id / app.location_id before any business SQL runs',
      () async {
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
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
          canonicalPunch: _canonicalFromPunch(
            wages_fixture.sevenShiftsTimePunchesWithShiftIds[0],
            wageRow: wages_fixture.sevenShiftsHoursAndWagesReportRows[0],
          ),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '1',
          lastModifiedSeen: DateTime.utc(2026, 5, 3, 23, 35, 0),
        );
        await sink.appendSyncLog(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          eventKind: 'poll_success',
          recordsCount: 1,
        );
        await sink.markLaborLive(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
        );
        await sink.recordHoursAndWagesReportGated(
          operatorId: _opA,
          locationId: _locA,
          statusCode: 403,
        );

        // Five business calls -> five tenant-scoped transactions.
        expect(pool.transactions, hasLength(5));
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
      'transaction (defense in depth)',
      () async {
        final pool = _SinkPool(connectorConnectionId: _connIdResolved);
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
            lastModifiedSeen: DateTime.utc(2026, 5, 3),
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
      'op_B uses an isolated tenant context — SET LOCAL payload carries '
      'op_B, not op_A, even when both calls reuse the same sink + pool',
      () async {
        final pool = _SinkPool(connectorConnectionId: _connIdResolved);
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '1',
          lastModifiedSeen: DateTime.utc(2026, 5, 3),
        );
        await sink.advanceWatermark(
          operatorId: _opB,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '2',
          lastModifiedSeen: DateTime.utc(2026, 5, 3),
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

  group('Test F — disconnect / credential wipe', () {
    test(
      'wipeCredentials UPDATEs vendor_credentials (ciphertexts NULL, '
      'is_active=false) and connector_connection (status=disconnected) '
      'for vendor_id="seven_shifts"; watermark rows are NOT touched',
      () async {
        final pool = _SinkPool();
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        await sink.wipeCredentials(
          operatorId: _opA,
          locationId: _locA,
        );

        final tx = pool.transactions.single;
        final credentialsSql = tx.executedSql.firstWhere(
          (s) => s.contains('update public.vendor_credentials'),
        );
        expect(credentialsSql, contains('access_token_ciphertext = null'));
        expect(credentialsSql, contains('refresh_token_ciphertext = null'));
        expect(credentialsSql, contains('is_active = false'));

        final connectionSql = tx.executedSql.firstWhere(
          (s) => s.contains('update public.connector_connection'),
        );
        expect(connectionSql, contains('status = @status'));
        expect(connectionSql, contains('webhook_url_provisioned = false'));

        // No DELETE / UPDATE against connector_sync_watermark in the
        // wipe path — preserves the cursor for reconnect.
        for (final sql in tx.executedSql) {
          expect(sql.contains('connector_sync_watermark'), isFalse,
              reason: 'wipe path must NOT touch connector_sync_watermark');
        }

        final credentialsParams = tx.parameters.firstWhere(
          (p) =>
              p['vendor_id'] == 'seven_shifts' &&
              p.containsKey('now') &&
              !p.containsKey('status'),
        );
        expect(credentialsParams['operator_id'], equals(_opA));
        expect(credentialsParams['location_id'], equals(_locA));

        final connectionParams = tx.parameters.firstWhere(
          (p) =>
              p['vendor_id'] == 'seven_shifts' &&
              p['status'] == 'disconnected',
        );
        expect(connectionParams['disconnect_reason'], equals('operator_action'));
      },
    );
  });

  group('Test G — hours-and-wages-gated log path', () {
    test(
      'recordHoursAndWagesReportGated(statusCode: 403) appends a '
      'connector_sync_log row with event_kind = '
      '"hours_and_wages_report_gated" and payload_preview carrying '
      '{"status_code": 403}',
      () async {
        final pool = _SinkPool(connectorConnectionId: _connIdResolved);
        final sink = SevenShiftsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.recordHoursAndWagesReportGated(
          operatorId: _opA,
          locationId: _locA,
          statusCode: 403,
        );

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.connector_sync_log'),
        );
        expect(insertSql, contains('event_kind'));
        expect(insertSql, contains('payload_preview'));

        final params = tx.parameters.firstWhere(
          (p) => p['event_kind'] ==
              kSevenShiftsHoursAndWagesReportGatedSyncLogKind,
        );
        expect(params['event_kind'], equals('hours_and_wages_report_gated'));
        expect(params['operator_id'], equals(_opA));
        expect(params['location_id'], equals(_locA));
        expect(params['connection_id'], equals(_connIdResolved));

        final preview = jsonDecode(params['payload_preview'] as String)
            as Map<String, Object?>;
        expect(preview['status_code'], equals(403));
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

  group('Test H — banned-items grep', () {
    test('sink source contains zero V1 lean cut 2 banned tokens', () {
      final source = File(
        'lib/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart',
      ).readAsStringSync();
      const banned = <String>[
        // V1 lean cut 2 ledger.
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
        // Extra prompt-pinned tokens.
        'pgmq',
        'kms_key_id',
        'dead_letter',
        'graceful_drain',
        'signal_term',
        'replay_window',
        '5_minute_replay',
      ];
      final lower = source.toLowerCase();
      for (final token in banned) {
        expect(lower.contains(token.toLowerCase()), isFalse,
            reason: 'banned item present in sink source: $token');
      }
    });

    test(
      'wage-dollar zombie-token guard: actual_labor_dollars / regular_pay '
      '/ overtime_pay must NOT appear inside the labor_punches INSERT '
      'column list — they belong inside raw_payload JSONB only',
      () {
        final source = File(
          'lib/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart',
        ).readAsStringSync();
        // Locate the labor_punches INSERT column list. The sink's
        // INSERT lives inside a single Dart string literal — extract
        // the content between `insert into public.labor_punches (` and
        // the next `) values (`.
        final start =
            source.indexOf('insert into public.labor_punches (');
        expect(start, greaterThanOrEqualTo(0),
            reason: 'sink must contain the labor_punches INSERT');
        final valuesIdx = source.indexOf(') values (', start);
        expect(valuesIdx, greaterThan(start));
        final columnList = source.substring(start, valuesIdx);
        for (final token in <String>[
          'actual_labor_dollars',
          'regular_pay',
          'overtime_pay',
        ]) {
          expect(columnList.contains(token), isFalse,
              reason: 'wage-dollar column "$token" must NOT appear in '
                  'the labor_punches INSERT column list — it belongs '
                  'inside raw_payload JSONB only');
        }
      },
    );

    test(
      'sink source uses the PostgresExecutor seam — no direct '
      'package:postgres import',
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
}

// ─── Fakes ──────────────────────────────────────────────────────────

PostgresRow _toLocationsRow() => <String, Object?>{
      'timezone': 'America/New_York',
      'business_day_rollover_hour': 4,
    };

class _SinkPool implements PostgresPool {
  _SinkPool({
    this.connectorConnectionId,
    this.locationTimezoneRow,
    int? insertAffected,
    List<int>? insertAffectedSequence,
  })  : _insertAffectedSequence = insertAffectedSequence != null
            ? List<int>.from(insertAffectedSequence)
            : (insertAffected != null
                ? <int>[insertAffected]
                : <int>[]);

  /// connection_id value the fake `connector_connection` row returns.
  /// `null` mimics the "no row" case (forces sink to throw when the
  /// bespoke caller omits connectionId and no row exists yet).
  final String? connectorConnectionId;

  /// `(timezone, business_day_rollover_hour)` row returned by the fake
  /// `locations` SELECT. Required when a labor_punches INSERT reaches
  /// business_date computation.
  final PostgresRow? locationTimezoneRow;

  final List<int> _insertAffectedSequence;

  final List<_SinkTransaction> transactions = <_SinkTransaction>[];

  int _drainInsertAffected() {
    if (_insertAffectedSequence.isEmpty) return 0;
    return _insertAffectedSequence.removeAt(0);
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _SinkTransaction(
      connectorConnectionId: connectorConnectionId,
      locationTimezoneRow: locationTimezoneRow,
      drainInsertAffected: _drainInsertAffected,
    );
    transactions.add(tx);
    return tx;
  }
}

class _SinkTransaction extends PostgresTransaction {
  _SinkTransaction({
    required this.connectorConnectionId,
    required this.locationTimezoneRow,
    required this.drainInsertAffected,
  });

  final String? connectorConnectionId;
  final PostgresRow? locationTimezoneRow;
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
    if (sql.contains('from public.connector_connection')) {
      final id = connectorConnectionId;
      if (id == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'connection_id': id},
      ];
    }
    if (sql.contains('from public.locations')) {
      final row = locationTimezoneRow;
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[row];
    }
    if (sql.contains('from public.connector_sync_log')) {
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
    return 0;
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
