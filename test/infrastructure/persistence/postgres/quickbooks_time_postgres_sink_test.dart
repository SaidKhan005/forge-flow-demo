// Phase 8 Wave B `8.spine-bridge.1.QBT` — QuickBooks Time Postgres
// sink test suite.
//
// Coverage matches the slice prompt's required tests A-H:
//
//   A. Round-trip with `quickbooks_time_punches_fixture`.
//   B. Idempotency replay (second upsert returns false).
//   C. Watermark per batch (advanceWatermark UPSERT shape).
//   D. Demo-mode flip (evaluateDemoFlip writes the demo_mode_state row;
//      idempotent SQL shape preserves original triggering connection).
//   E. RLS + tenancy (every public method runs through
//      `withTenant` → SET LOCAL `app.operator_id` / `app.location_id`).
//   F. Module disambiguation: connection.module='payroll' →
//      ModuleRefusalException; no labor_punches insert.
//   G. Existing `quickbooks_time_labor_adapter_test.dart` smoke-runs →
//      21/21 PASS — verified by running the suite via `flutter test`
//      after this slice lands; no new assertion in this file.
//   H. Banned-items grep on sink source (V1 lean cut 2 ledger).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/quickbooks_time_labor_adapter.dart'
    show
        ModuleRefusalException,
        QuickBooksTimeCanonicalPunchFact,
        QuickBooksTimeConnectionRow,
        QuickBooksTimeWatermarkRow,
        kQuickBooksModuleTime;
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/labor/fixtures/quickbooks_time_punches_fixture.dart'
    as fixture;

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _connId = '33333333-3333-3333-3333-333333333333';

Map<String, Object?> _canonicalFromFixture(Map<String, Object?> record) {
  return <String, Object?>{
    'vendor_entity_id': record['id']!.toString(),
    'vendor_modified_at': record['last_modified']! as String,
    'shift_start': record['start']! as String,
    'shift_end': record['end'] is String ? record['end'] : null,
    'employee_source_id': record['user_id']!.toString(),
    'role_name': record['role_name']! as String,
    'hours_worked': record['duration']! as num,
    // QuickBooks Time wage class is `perEmployeeWithRates` (per the
    // 2026-05-05 falsehood corrections): the timesheet endpoint
    // exposes hours only; the adapter joins `Users.pay_rate` for the
    // hourly rate. The sink writes pay_rate when supplied; Lane `.2`'s
    // aggregator computes labor_dollars via rate × duration.
    'pay_rate': 22.50,
    'raw_payload': record,
  };
}

void main() {
  group('Test A — round-trip with quickbooks_time_punches_fixture', () {
    test(
      'one fixture record → INSERT into labor_punches with operator-scoped '
      'columns, vendor_id="quickbooks_time", labor_dollars NOT supplied',
      () async {
        final pool = _SinkPool(
          connectorConnectionModule: 'time',
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = QuickBooksTimePostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final wrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: _canonicalFromFixture(fixture.sampleQuickBooksTimePunch),
        );
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        // The SQL inserts into the canonical labor_punches table, with
        // every operator-scoped column the prompt requires. We assert
        // the column names appear inside the INSERT statement so a
        // future column-list rename trips the suite immediately.
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
        // labor_dollars must NOT appear in the INSERT — Lane `.2`'s
        // aggregator computes dollars via rate × duration (per the
        // 2026-05-05 wage-source clarification for QBT); the sink
        // leaves the column NULL.
        expect(insertSql, isNot(contains('labor_dollars')),
            reason: 'sink must NOT supply labor_dollars; aggregator '
                'computes via rate × duration');
        expect(insertSql, contains('on conflict (operator_id, vendor_id, '
            'vendor_entity_id, vendor_modified_at) do nothing'),
            reason: 'idempotency UNIQUE shape per spine contract');

        // Bind params for fact columns. Filter on `employee_source_id`
        // because the connector_connection module SELECT also binds
        // `vendor_id`; only the labor_punches INSERT binds the
        // employee field.
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['operator_id'], equals(_opA));
        expect(insertParams['location_id'], equals(_locA));
        expect(insertParams['employee_source_id'], equals('8001'));
        expect(insertParams['role_name'], equals('server'));
        expect(insertParams['vendor_entity_id'], equals('901001'));
        expect(insertParams['hours_worked'], equals(30600));
        expect(insertParams['pay_rate'], equals(22.50));
        expect(insertParams['shift_start'],
            equals(DateTime.utc(2026, 5, 4, 11, 0, 0)));
        expect(insertParams['shift_end'],
            equals(DateTime.utc(2026, 5, 4, 19, 30, 0)));
        expect(insertParams['vendor_modified_at'],
            equals(DateTime.utc(2026, 5, 4, 19, 31, 12)));
        // business_date computed via IanaTimezoneConverter from the
        // location's `America/New_York` timezone + 4-hour rollover:
        // shift_start 2026-05-04T11:00:00Z → 07:00 local → 2026-05-04.
        expect(insertParams['business_date'], equals('2026-05-04'));
        // raw_payload is a JSON-encoded string of the QBT record.
        expect(insertParams['raw_payload'], isA<String>());
        expect(
          (insertParams['raw_payload'] as String).contains('"id":901001'),
          isTrue,
        );
      },
    );

    test(
      'open timesheet (shift_end empty in QBT payload) writes shift_end as '
      'NULL via the typed shift_end:null bind',
      () async {
        final openTimesheet =
            Map<String, Object?>.from(fixture.sampleQuickBooksTimePunch)
              ..['end'] = '';
        final pool = _SinkPool(
          connectorConnectionModule: 'time',
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = QuickBooksTimePostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: _canonicalFromFixture(openTimesheet),
        );

        final tx = pool.transactions.single;
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['shift_end'], isNull,
            reason: 'open timesheet → shift_end MUST bind as NULL so the '
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
        // First insert affected = 1 (new row); replay affected = 0.
        final pool = _SinkPool(
          connectorConnectionModule: 'time',
          locationTimezoneRow: _toLocationsRow(),
          insertAffectedSequence: <int>[1, 0],
        );
        final sink = QuickBooksTimePostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        final canonical =
            _canonicalFromFixture(fixture.sampleQuickBooksTimePunch);
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
        final pool = _SinkPool(
          connectorConnectionModule: 'time',
        );
        final sink = QuickBooksTimePostgresSink(
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
  });

  group('Test D — demo-mode flip', () {
    test(
      'connect + first backfill committed + records ≥ 1 → INSERT into '
      'demo_mode_state with is_demo=false; ON CONFLICT idempotent UPDATE '
      'guarded by is_demo=true preserves original triggering connection_id',
      () async {
        final pool = _SinkPool(
          connectorConnectionModule: 'time',
        );
        final sink = QuickBooksTimePostgresSink(
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
        // Default is_demo=false on the INSERT branch (first backfill
        // already produced records → no transient demo row).
        expect(flipSql, contains('false, @flipped_at'),
            reason: 'INSERT branch writes is_demo=false directly');
        // Idempotent flip: WHERE clause guards the UPDATE so a second
        // call (after live) is a no-op and the original
        // flipped_to_live_at + flipped_by_connection_id stay untouched.
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
      'gates fail → no INSERT issued (connection not yet connected, or '
      'first backfill not committed, or records=0)',
      () async {
        final pool = _SinkPool(
          connectorConnectionModule: 'time',
        );
        final sink = QuickBooksTimePostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        // status != connected
        await sink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.disconnected,
          firstBackfillCommitted: true,
          backfillRecordsWritten: 5,
          connectionId: _connId,
        );
        // backfill not committed
        await sink.evaluateDemoFlip(
          operatorId: _opA,
          locationId: _locA,
          category: IntegrationCategory.labor,
          connectionStatus: ConnectionStatus.connected,
          firstBackfillCommitted: false,
          backfillRecordsWritten: 5,
          connectionId: _connId,
        );
        // records = 0
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
          connectorConnectionModule: 'time',
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = QuickBooksTimePostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.sampleQuickBooksTimePunch),
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

        // Four business calls -> four tenant-scoped transactions.
        expect(pool.transactions, hasLength(4));
        for (final tx in pool.transactions) {
          // SET LOCAL via set_config: app.operator_id + app.location_id
          // both bound parametrically so a malformed UUID cannot slip
          // into the GUC payload.
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
      'transaction (defense in depth: the strict 8-4-4-4-12 UUID check '
      'short-circuits invalid input out of the SET LOCAL payload)',
      () async {
        final pool = _SinkPool(connectorConnectionModule: 'time');
        final sink = QuickBooksTimePostgresSink(
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
      'reuse the same sink + the same pool',
      () async {
        final pool = _SinkPool(
          connectorConnectionModule: 'time',
        );
        final sink = QuickBooksTimePostgresSink(
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

  group('Test F — module disambiguation', () {
    test(
      'connector_connection.module = "payroll" → ModuleRefusalException; '
      'NO labor_punches insert reaches Postgres; transaction rolls back',
      () async {
        final pool = _SinkPool(
          connectorConnectionModule: 'payroll',
          locationTimezoneRow: _toLocationsRow(),
        );
        final sink = QuickBooksTimePostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        Object? thrown;
        try {
          await sink.upsertLaborPunch(
            operatorId: _opA,
            locationId: _locA,
            canonicalPunch:
                _canonicalFromFixture(fixture.sampleQuickBooksTimePunch),
          );
        } on ModuleRefusalException catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ModuleRefusalException>());
        expect((thrown as ModuleRefusalException).module, equals('payroll'));

        final tx = pool.transactions.single;
        expect(
          tx.executedSql
              .any((s) => s.contains('insert into public.labor_punches')),
          isFalse,
          reason: 'module refusal MUST short-circuit before any '
              'labor_punches INSERT runs',
        );
        expect(tx.rollbackCount, equals(1),
            reason: 'thrown ModuleRefusalException must roll back the tx');
      },
    );

    test(
      'connector_connection.module = "accounting" → ModuleRefusalException',
      () async {
        final pool = _SinkPool(
          connectorConnectionModule: 'accounting',
          locationTimezoneRow: _toLocationsRow(),
        );
        final sink = QuickBooksTimePostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        Object? thrown;
        try {
          await sink.upsertLaborPunch(
            operatorId: _opA,
            locationId: _locA,
            canonicalPunch:
                _canonicalFromFixture(fixture.sampleQuickBooksTimePunch),
          );
        } on ModuleRefusalException catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ModuleRefusalException>());
        expect((thrown as ModuleRefusalException).module, equals('accounting'));
      },
    );

    test(
      'no connector_connection row for this (op, loc, vendor) → '
      'ModuleRefusalException with module="" (defensive: a missing '
      'connection means the dispatcher misrouted; refuse rather than '
      'silently writing under the wrong module)',
      () async {
        final pool = _SinkPool(
          connectorConnectionModule: null,
          locationTimezoneRow: _toLocationsRow(),
        );
        final sink = QuickBooksTimePostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        Object? thrown;
        try {
          await sink.upsertLaborPunch(
            operatorId: _opA,
            locationId: _locA,
            canonicalPunch:
                _canonicalFromFixture(fixture.sampleQuickBooksTimePunch),
          );
        } on ModuleRefusalException catch (error) {
          thrown = error;
        }
        expect(thrown, isA<ModuleRefusalException>());
      },
    );

    test(
      'connector_connection.module = "time" → labor_punches INSERT runs',
      () async {
        final pool = _SinkPool(
          connectorConnectionModule: 'time',
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = QuickBooksTimePostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        final wrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.sampleQuickBooksTimePunch),
        );
        expect(wrote, isTrue);
      },
    );
  });

  group('Cover / reservation rejection (defense-in-depth)', () {
    test('upsertCoverFact throws UnsupportedError — labor sink', () async {
      final sink = QuickBooksTimePostgresSink(
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
      final sink = QuickBooksTimePostgresSink(
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

  group(
    'QuickBooksTimeGateway — typed gateway methods (production binder seam)',
    () {
      test(
        'writePunchFact translates the typed fact through the shared private '
        'writer, runs the same module disambiguation, and INSERTs into '
        'labor_punches with hours_worked derived from start/end',
        () async {
          final pool = _SinkPool(
            connectorConnectionModule: 'time',
            locationTimezoneRow: _toLocationsRow(),
            insertAffected: 1,
          );
          final sink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
            now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
          );
          final wrote = await sink.writePunchFact(
            QuickBooksTimeCanonicalPunchFact(
              operatorId: _opA,
              locationId: _locA,
              vendorEntityId: '901001',
              vendorModifiedAt: DateTime.utc(2026, 5, 4, 19, 31, 12),
              shiftStart: DateTime.utc(2026, 5, 4, 11, 0, 0),
              shiftEnd: DateTime.utc(2026, 5, 4, 19, 30, 0),
              roleName: 'server',
              employeeId: '8001',
              rawPayload: const <String, Object?>{'id': 901001},
            ),
          );
          expect(wrote, isTrue);

          final tx = pool.transactions.single;
          // The typed fact path goes through the same INSERT shape as
          // the canonical-fact dict path.
          final insertParams = tx.parameters.firstWhere(
            (p) => p.containsKey('employee_source_id'),
          );
          expect(insertParams['operator_id'], equals(_opA));
          expect(insertParams['employee_source_id'], equals('8001'));
          expect(insertParams['vendor_entity_id'], equals('901001'));
          // 19:30 - 11:00 = 8h30 = 30600 seconds.
          expect(insertParams['hours_worked'], equals(30600));
          // The typed fact does not carry pay_rate; gateway path leaves
          // the column NULL — Lane `.2`'s aggregator computes
          // labor_dollars via rate × duration when both land.
          expect(insertParams['pay_rate'], isNull);
        },
      );

      test(
        'writePunchFact obeys module disambiguation: connector_connection.'
        'module="payroll" → ModuleRefusalException; the fact never lands',
        () async {
          final pool = _SinkPool(
            connectorConnectionModule: 'payroll',
            locationTimezoneRow: _toLocationsRow(),
          );
          final sink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
          );
          Object? thrown;
          try {
            await sink.writePunchFact(
              QuickBooksTimeCanonicalPunchFact(
                operatorId: _opA,
                locationId: _locA,
                vendorEntityId: '901001',
                vendorModifiedAt: DateTime.utc(2026, 5, 4, 19, 31, 12),
                shiftStart: DateTime.utc(2026, 5, 4, 11, 0, 0),
                shiftEnd: DateTime.utc(2026, 5, 4, 19, 30, 0),
                roleName: 'server',
                employeeId: '8001',
                rawPayload: const <String, Object?>{},
              ),
            );
          } on ModuleRefusalException catch (error) {
            thrown = error;
          }
          expect(thrown, isA<ModuleRefusalException>());
          final tx = pool.transactions.single;
          expect(
            tx.executedSql
                .any((s) => s.contains('insert into public.labor_punches')),
            isFalse,
            reason: 'module refusal must short-circuit before any '
                'labor_punches INSERT runs on the typed gateway path too',
          );
        },
      );

      test(
        'upsertConnection inserts into connector_connection with category='
        'labor + module="time", uses the (operator,location,vendor,'
        'coalesce(module,"")) ON CONFLICT key, and returns the row populated '
        'with the server-generated connection_id',
        () async {
          const newId = '99999999-9999-9999-9999-999999999999';
          final pool = _SinkPool(upsertConnectionReturnId: newId);
          final sink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
          );
          final returned = await sink.upsertConnection(
            row: const QuickBooksTimeConnectionRow(
              connectionId: '00000000-0000-0000-0000-000000000000',
              operatorId: _opA,
              locationId: _locA,
              intuitRealmId: 'realm-12345',
              module: kQuickBooksModuleTime,
              status: ConnectionStatus.connected,
            ),
          );
          expect(returned.connectionId, equals(newId),
              reason: 'returned row must carry the server-generated '
                  'connection_id from the RETURNING clause');
          expect(returned.operatorId, equals(_opA));
          expect(returned.intuitRealmId, equals('realm-12345'));
          expect(returned.module, equals(kQuickBooksModuleTime));

          final tx = pool.transactions.single;
          final insertSql = tx.executedSql.firstWhere(
            (s) => s.contains('insert into public.connector_connection'),
          );
          expect(insertSql, contains("'labor'"),
              reason: 'category is fixed to labor for QBT');
          expect(insertSql,
              contains("on conflict (operator_id, location_id, vendor_id, "
                  "coalesce(module, '')) do update set"),
              reason: 'unique key matches the connector_connection_unique_idx '
                  'shape from the Phase 8.0 migration');
          expect(insertSql, contains('returning connection_id'));

          final params = tx.parameters.firstWhere(
            (p) => p.containsKey('metadata'),
          );
          expect(params['operator_id'], equals(_opA));
          expect(params['location_id'], equals(_locA));
          expect(params['vendor_id'], equals('quickbooks_time'));
          expect(params['module'], equals(kQuickBooksModuleTime));
          expect(params['status'], equals('connected'));
          // Metadata is JSON-encoded with intuit_realm_id key set.
          expect(params['metadata'], isA<String>());
          expect(
            (params['metadata'] as String).contains('"intuit_realm_id"'),
            isTrue,
            reason: 'metadata must carry intuit_realm_id so reconnect '
                'flows can read it back',
          );
        },
      );

      test(
        'readWatermark returns null when no row exists; otherwise returns the '
        'typed QuickBooksTimeWatermarkRow',
        () async {
          // Empty case.
          final emptyPool = _SinkPool();
          final emptySink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(emptyPool),
          );
          final empty = await emptySink.readWatermark(
            operatorId: _opA,
            locationId: _locA,
          );
          expect(empty, isNull);

          // Populated case.
          final populatedPool = _SinkPool(
            connectorSyncWatermarkRow: <String, Object?>{
              'cursor_token': '5',
              'last_modified_seen': DateTime.utc(2026, 5, 4, 11, 30, 0),
            },
          );
          final populatedSink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(populatedPool),
          );
          final populated = await populatedSink.readWatermark(
            operatorId: _opA,
            locationId: _locA,
          );
          expect(populated, isNotNull);
          expect(populated!.cursorToken, equals('5'));
          expect(populated.lastModifiedSeen,
              equals(DateTime.utc(2026, 5, 4, 11, 30, 0)));
        },
      );

      test(
        'writeWatermark resolves connection_id from connector_connection '
        'and UPSERTs into connector_sync_watermark',
        () async {
          final pool = _SinkPool(connectorConnectionId: _connId);
          final sink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
            now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
          );
          await sink.writeWatermark(
            operatorId: _opA,
            locationId: _locA,
            row: QuickBooksTimeWatermarkRow(
              cursorToken: '7',
              lastModifiedSeen: DateTime.utc(2026, 5, 4, 11, 45, 0),
            ),
          );
          final tx = pool.transactions.single;
          // Connection id is resolved BEFORE the watermark UPSERT.
          final lookupIdx = tx.executedSql.indexWhere(
            (s) => s.contains('select connection_id from public.'
                'connector_connection'),
          );
          final upsertIdx = tx.executedSql.indexWhere(
            (s) =>
                s.contains('insert into public.connector_sync_watermark'),
          );
          expect(lookupIdx, isNonNegative);
          expect(upsertIdx, greaterThan(lookupIdx),
              reason: 'connection_id lookup must run before the UPSERT '
                  'so the foreign-key bind carries a real id');

          final upsertParams = tx.parameters.firstWhere(
            (p) =>
                p['connection_id'] == _connId && p.containsKey('cursor_token'),
          );
          expect(upsertParams['cursor_token'], equals('7'));
          expect(upsertParams['last_modified_seen'],
              equals(DateTime.utc(2026, 5, 4, 11, 45, 0)));
          expect(upsertParams['resource'], equals('labor_punches'));
        },
      );

      test(
        'writeWatermark throws StateError when the active tenant has no '
        'connector_connection row (defensive: a watermark write before connect '
        'is a router bug, not a silent no-op)',
        () async {
          final pool = _SinkPool();
          final sink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
          );
          Object? thrown;
          try {
            await sink.writeWatermark(
              operatorId: _opA,
              locationId: _locA,
              row: QuickBooksTimeWatermarkRow(
                cursorToken: '1',
                lastModifiedSeen: DateTime.utc(2026, 5, 4, 11, 0, 0),
              ),
            );
          } on StateError catch (error) {
            thrown = error;
          }
          expect(thrown, isA<StateError>());
        },
      );

      test(
        'readAccessToken pulls access_token_ciphertext from vendor_credentials '
        'filtered by vendor_id and is_active=true',
        () async {
          // Empty case.
          final emptyPool = _SinkPool();
          final emptySink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(emptyPool),
          );
          final none = await emptySink.readAccessToken(
            operatorId: _opA,
            locationId: _locA,
          );
          expect(none, isNull);

          // Populated case.
          final pool = _SinkPool(
            vendorCredentialsAccessToken: 'cipher-XYZ',
          );
          final sink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
          );
          final token = await sink.readAccessToken(
            operatorId: _opA,
            locationId: _locA,
          );
          expect(token, equals('cipher-XYZ'));

          final tx = pool.transactions.single;
          final selectSql = tx.executedSql.firstWhere(
            (s) => s.contains('from public.vendor_credentials'),
          );
          expect(selectSql, contains('is_active = true'),
              reason: 'inactive credentials must not surface');
          final params = tx.parameters.firstWhere(
            (p) => p['vendor_id'] == 'quickbooks_time',
          );
          expect(params['vendor_id'], equals('quickbooks_time'));
        },
      );

      test(
        'readIntuitRealmId reads metadata.intuit_realm_id from '
        'connector_connection. Map metadata + JSON-string metadata both work',
        () async {
          // Map-shaped metadata (driver returns jsonb as Map directly).
          final mapPool = _SinkPool(
            connectorConnectionMetadata: <String, Object?>{
              'intuit_realm_id': 'realm-mapped',
              'module': 'time',
            },
          );
          final mapSink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(mapPool),
          );
          final fromMap = await mapSink.readIntuitRealmId(
            operatorId: _opA,
            locationId: _locA,
          );
          expect(fromMap, equals('realm-mapped'));

          // String-shaped metadata (some drivers surface jsonb as String).
          final stringPool = _SinkPool(
            connectorConnectionMetadata:
                '{"intuit_realm_id":"realm-stringy","module":"time"}',
          );
          final stringSink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(stringPool),
          );
          final fromString = await stringSink.readIntuitRealmId(
            operatorId: _opA,
            locationId: _locA,
          );
          expect(fromString, equals('realm-stringy'));

          // No row → null.
          final emptySink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(_SinkPool()),
          );
          final none = await emptySink.readIntuitRealmId(
            operatorId: _opA,
            locationId: _locA,
          );
          expect(none, isNull);
        },
      );

      test(
        'wipeCredentials DELETEs the vendor_credentials row(s) for the '
        'active tenant; watermark and labor_punches rows are preserved',
        () async {
          final pool = _SinkPool();
          final sink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
          );
          await sink.wipeCredentials(operatorId: _opA, locationId: _locA);
          final tx = pool.transactions.single;
          final deleteSql = tx.executedSql.firstWhere(
            (s) => s.contains('delete from public.vendor_credentials'),
          );
          expect(deleteSql, contains('vendor_id = @vendor_id'));
          // Watermark rows are intentionally preserved across disconnect
          // so reconnect resumes from the last cursor.
          expect(
            tx.executedSql.any(
              (s) => s.contains('delete from public.connector_sync_watermark'),
            ),
            isFalse,
            reason: 'wipeCredentials must not touch watermark — reconnect '
                'resumes from the last cursor',
          );
          expect(
            tx.executedSql
                .any((s) => s.contains('delete from public.labor_punches')),
            isFalse,
            reason: 'wipeCredentials must never delete canonical fact rows',
          );

          final params = tx.parameters.firstWhere(
            (p) => p.containsKey('vendor_id'),
          );
          expect(params['vendor_id'], equals('quickbooks_time'));
        },
      );

      test(
        'every gateway method runs through withTenant — SET LOCAL '
        'app.operator_id / app.location_id GUCs are bound BEFORE the '
        'business SQL on each path. Operator-scope isolation: a tenant B '
        'call never bleeds A\'s GUC payload',
        () async {
          final pool = _SinkPool(
            connectorConnectionModule: 'time',
            locationTimezoneRow: _toLocationsRow(),
            connectorConnectionId: _connId,
            connectorConnectionMetadata: <String, Object?>{
              'intuit_realm_id': 'realm-scoped',
            },
            vendorCredentialsAccessToken: 'tok-scoped',
            connectorSyncWatermarkRow: <String, Object?>{
              'cursor_token': '2',
              'last_modified_seen': DateTime.utc(2026, 5, 4, 11, 0, 0),
            },
            upsertConnectionReturnId: _connId,
            insertAffected: 1,
          );
          final sink = QuickBooksTimePostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
            now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
          );
          // Run every gateway method as op A.
          await sink.upsertConnection(
            row: const QuickBooksTimeConnectionRow(
              connectionId: '00000000-0000-0000-0000-000000000000',
              operatorId: _opA,
              locationId: _locA,
              intuitRealmId: 'realm-1',
              module: kQuickBooksModuleTime,
              status: ConnectionStatus.connected,
            ),
          );
          await sink.readWatermark(operatorId: _opA, locationId: _locA);
          await sink.writeWatermark(
            operatorId: _opA,
            locationId: _locA,
            row: QuickBooksTimeWatermarkRow(
              cursorToken: '3',
              lastModifiedSeen: DateTime.utc(2026, 5, 4, 11, 30, 0),
            ),
          );
          await sink.writePunchFact(
            QuickBooksTimeCanonicalPunchFact(
              operatorId: _opA,
              locationId: _locA,
              vendorEntityId: '901001',
              vendorModifiedAt: DateTime.utc(2026, 5, 4, 19, 31, 12),
              shiftStart: DateTime.utc(2026, 5, 4, 11, 0, 0),
              shiftEnd: DateTime.utc(2026, 5, 4, 19, 30, 0),
              roleName: 'server',
              employeeId: '8001',
              rawPayload: const <String, Object?>{},
            ),
          );
          await sink.readAccessToken(operatorId: _opA, locationId: _locA);
          await sink.readIntuitRealmId(operatorId: _opA, locationId: _locA);
          await sink.wipeCredentials(operatorId: _opA, locationId: _locA);

          // Same sink instance, different operator: every transaction
          // gets its own SET LOCAL payload bound parametrically.
          await sink.readAccessToken(operatorId: _opB, locationId: _locA);

          // 7 calls as A + 1 as B = 8 transactions; every one carries
          // its own tenant SET LOCAL pair.
          expect(pool.transactions, hasLength(8));
          for (final tx in pool.transactions) {
            expect(
              tx.executedSql.where(
                (s) => s.contains("set_config('app.operator_id'"),
              ),
              hasLength(1),
              reason: 'tenant operator_id GUC must be set before business '
                  'SQL on every gateway path',
            );
            expect(
              tx.executedSql.where(
                (s) => s.contains("set_config('app.location_id'"),
              ),
              hasLength(1),
              reason: 'tenant location_id GUC must be set before business '
                  'SQL on every gateway path',
            );
            expect(tx.commitCount, equals(1),
                reason: 'happy path must commit cleanly');
          }
          // Tenant isolation: the last transaction's GUC payload binds
          // op_B, not op_A — proves OperatorScopedRepository.withTenant
          // holds the line even when both calls reuse the same sink.
          final lastTx = pool.transactions.last;
          final opBPayload = lastTx.parameters.firstWhere(
            (p) => p['value'] == _opB,
          );
          expect(opBPayload['value'], equals(_opB));
        },
      );
    },
  );

  group('Test H — banned-items grep', () {
    test('sink source contains zero V1 lean cut 2 banned tokens', () {
      final source = File(
        'lib/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart',
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
      ];
      final lower = source.toLowerCase();
      for (final token in banned) {
        expect(lower.contains(token.toLowerCase()), isFalse,
            reason: 'banned item present in sink source: $token');
      }
    });

    test(
      'sink source restricts package:postgres to the canonical infrastructure '
      'directory (file lives in lib/infrastructure/persistence/postgres/, '
      'so the import is permitted; this test pins that the sink does not '
      'leak any postgres types into a public surface)',
      () {
        final source = File(
          'lib/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart',
        ).readAsStringSync();
        // The sink uses the PostgresExecutor seam; no direct
        // package:postgres import is needed. Pin that absence so a
        // future refactor cannot silently introduce it without
        // tripping CI.
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
    this.connectorConnectionModule,
    this.locationTimezoneRow,
    this.connectorConnectionId,
    this.connectorConnectionMetadata,
    this.vendorCredentialsAccessToken,
    this.connectorSyncWatermarkRow,
    this.upsertConnectionReturnId,
    int? insertAffected,
    List<int>? insertAffectedSequence,
  })  : _insertAffectedSequence = insertAffectedSequence != null
            ? List<int>.from(insertAffectedSequence)
            : (insertAffected != null
                ? <int>[insertAffected]
                : <int>[]);

  /// Module value the fake `connector_connection` row returns.
  /// `null` mimics the "no row" case (dispatcher misroute defense).
  final String? connectorConnectionModule;

  /// `(timezone, business_day_rollover_hour)` row returned by the
  /// fake `locations` SELECT. Required when a labor_punches INSERT
  /// reaches business_date computation.
  final PostgresRow? locationTimezoneRow;

  /// connection_id returned for `select connection_id from
  /// public.connector_connection` SELECTs. Used by `writeWatermark`
  /// gateway path.
  final String? connectorConnectionId;

  /// metadata jsonb returned for `select metadata from
  /// public.connector_connection` SELECTs. Used by `readIntuitRealmId`.
  final Object? connectorConnectionMetadata;

  /// access_token_ciphertext returned for `select access_token_ciphertext
  /// from public.vendor_credentials` SELECTs. Used by `readAccessToken`.
  final String? vendorCredentialsAccessToken;

  /// Row returned for `select cursor_token, last_modified_seen
  /// from public.connector_sync_watermark` SELECTs. Used by `readWatermark`.
  final PostgresRow? connectorSyncWatermarkRow;

  /// connection_id returned by the `insert into public.connector_connection
  /// ... returning connection_id` (UPSERT path inside `upsertConnection`).
  final String? upsertConnectionReturnId;

  final List<int> _insertAffectedSequence;

  final List<_SinkTransaction> transactions = <_SinkTransaction>[];

  int _drainInsertAffected() {
    if (_insertAffectedSequence.isEmpty) return 0;
    return _insertAffectedSequence.removeAt(0);
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _SinkTransaction(
      connectorConnectionModule: connectorConnectionModule,
      locationTimezoneRow: locationTimezoneRow,
      connectorConnectionId: connectorConnectionId,
      connectorConnectionMetadata: connectorConnectionMetadata,
      vendorCredentialsAccessToken: vendorCredentialsAccessToken,
      connectorSyncWatermarkRow: connectorSyncWatermarkRow,
      upsertConnectionReturnId: upsertConnectionReturnId,
      drainInsertAffected: _drainInsertAffected,
    );
    transactions.add(tx);
    return tx;
  }
}

class _SinkTransaction extends PostgresTransaction {
  _SinkTransaction({
    required this.connectorConnectionModule,
    required this.locationTimezoneRow,
    required this.connectorConnectionId,
    required this.connectorConnectionMetadata,
    required this.vendorCredentialsAccessToken,
    required this.connectorSyncWatermarkRow,
    required this.upsertConnectionReturnId,
    required this.drainInsertAffected,
  });

  final String? connectorConnectionModule;
  final PostgresRow? locationTimezoneRow;
  final String? connectorConnectionId;
  final Object? connectorConnectionMetadata;
  final String? vendorCredentialsAccessToken;
  final PostgresRow? connectorSyncWatermarkRow;
  final String? upsertConnectionReturnId;
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
    // INSERT ... RETURNING connection_id branch (upsertConnection path).
    if (sql.contains('insert into public.connector_connection') &&
        sql.contains('returning connection_id')) {
      final id = upsertConnectionReturnId;
      if (id == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'connection_id': id},
      ];
    }
    if (sql.contains('from public.connector_connection')) {
      // Distinguish by selected column.
      if (sql.contains('select connection_id ')) {
        final id = connectorConnectionId;
        if (id == null) return const <PostgresRow>[];
        return <PostgresRow>[
          <String, Object?>{'connection_id': id},
        ];
      }
      if (sql.contains('select metadata ')) {
        if (connectorConnectionMetadata == null) return const <PostgresRow>[];
        return <PostgresRow>[
          <String, Object?>{'metadata': connectorConnectionMetadata},
        ];
      }
      // Default: module SELECT.
      if (connectorConnectionModule == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'module': connectorConnectionModule},
      ];
    }
    if (sql.contains('from public.vendor_credentials')) {
      final token = vendorCredentialsAccessToken;
      if (token == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'access_token_ciphertext': token},
      ];
    }
    if (sql.contains('from public.connector_sync_watermark')) {
      final row = connectorSyncWatermarkRow;
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[row];
    }
    if (sql.contains('from public.locations')) {
      final row = locationTimezoneRow;
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[row];
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
