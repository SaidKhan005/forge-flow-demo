// Phase 8 Wave B `8.spine-bridge.1.ADP` — ADP Postgres sink test
// suite.
//
// Coverage matches the slice prompt's required tests A-H:
//
//   A. Round-trip with `adp_punches_fixture` (canonical-fact dict
//      input + AdpGateway / writeTimePunchFact path).
//   B. Idempotency replay (second upsert returns false).
//   C. Watermark per batch (advanceWatermark UPSERT shape).
//   D. Demo-mode flip (evaluateDemoFlip writes the demo_mode_state
//      row; idempotent SQL shape preserves original triggering
//      connection).
//   E. RLS + tenancy (every public method runs through `withTenant`
//      → SET LOCAL `app.operator_id` / `app.location_id`).
//   F. Module-agnostic invariant: the sink does NOT issue a
//      `connector_connection.module` SELECT inside `upsertLaborPunch`;
//      both supported modules write through the same shared private
//      writer. Module disambiguation lives in the adapter at
//      `connect`, not here (per the 2026-05-05 spine-contract
//      falsehood correction #1 — sink is webhook-vs-poll agnostic
//      and module-agnostic).
//   G. V1 hours-only invariant: every fixture row commits with the
//      wage-dollar columns absent from the INSERT (left NULL). Per
//      the 2026-05-05 spine-contract falsehood correction #7 — V1
//      wage class for ADP is `hoursOnly`.
//   H. Banned-items grep on sink source (V1 lean cut 2 ledger plus
//      the wage-dollar write-side tokens forbidden by the V1
//      hours-only invariant).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/adp_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/adp_labor_adapter.dart'
    show
        AdpCanonicalTimePunchFact,
        kAdpModuleWorkforceManager,
        kAdpModuleWorkforceNow;
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/labor/fixtures/adp_punches_fixture.dart'
    as fixture;

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _connId = '33333333-3333-3333-3333-333333333333';

Map<String, Object?> _canonicalFromFixture(Map<String, Object?> record) {
  final timeEvent =
      Map<String, Object?>.from(record['time_event']! as Map<dynamic, dynamic>);
  final worker =
      Map<String, Object?>.from(record['worker']! as Map<dynamic, dynamic>);
  String? roleName;
  final positionRaw = worker['position'];
  if (positionRaw is Map) {
    final position = Map<String, Object?>.from(positionRaw);
    final title = position['position_title'];
    if (title is String && title.isNotEmpty) roleName = title;
  }
  if (roleName == null) {
    final assignmentRaw = worker['workAssignment'];
    if (assignmentRaw is Map) {
      final assignment = Map<String, Object?>.from(assignmentRaw);
      final jobTitle = assignment['jobTitle'];
      if (jobTitle is String && jobTitle.isNotEmpty) roleName = jobTitle;
    }
  }
  final entry = timeEvent['entry_date_time']! as String;
  final exitRaw = timeEvent['exit_date_time'];
  final shiftEnd = exitRaw is String && exitRaw.isNotEmpty ? exitRaw : null;
  return <String, Object?>{
    'vendor_entity_id': timeEvent['id']!.toString(),
    'vendor_modified_at': timeEvent['last_modified_date_time']! as String,
    'shift_start': entry,
    'shift_end': shiftEnd,
    'employee_source_id': worker['associate_oid']!.toString(),
    'role_name': roleName!,
    'raw_payload': record,
  };
}

void main() {
  group('Test A — round-trip with adp_punches_fixture', () {
    test(
      'one fixture record → INSERT into labor_punches with operator-scoped '
      'columns, vendor_id="adp", and the V1 hours-only column list (no '
      'wage-dollar columns supplied)',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final wrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.adpBackfillBatchPage1[0]),
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
          'vendor_id',
          'vendor_entity_id',
          'vendor_modified_at',
          'raw_payload',
          'business_date',
        ]) {
          expect(insertSql, contains(column),
              reason: 'INSERT must list "$column" exactly once');
        }
        expect(
          insertSql,
          contains(
            'on conflict (operator_id, location_id, vendor_id, vendor_entity_id)',
          ),
          reason: 'idempotency UNIQUE shape per spine contract (A1 rekey)',
        );
        expect(
          insertSql,
          contains('do update set'),
          reason: 'A1: upsert uses DO UPDATE with >= guard, not DO NOTHING',
        );

        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['operator_id'], equals(_opA));
        expect(insertParams['location_id'], equals(_locA));
        expect(insertParams['employee_source_id'], equals('G3W001'));
        expect(insertParams['role_name'], equals('Server'));
        expect(insertParams['vendor_entity_id'], equals('ADP-TE-9001'));
        expect(insertParams['shift_start'],
            equals(DateTime.utc(2026, 4, 30, 18, 0, 0)));
        expect(insertParams['shift_end'],
            equals(DateTime.utc(2026, 5, 1, 2, 0, 0)));
        expect(insertParams['vendor_modified_at'],
            equals(DateTime.utc(2026, 5, 1, 2, 0, 30)));
        // Derived hours_worked: 2026-05-01T02:00:00Z - 2026-04-30T18:00:00Z
        // = 8 hours = 28800 seconds.
        expect(insertParams['hours_worked'], equals(28800));
        // business_date computed via IanaTimezoneConverter from the
        // location's `America/New_York` timezone + 4-hour rollover:
        // shift_start 2026-04-30T18:00:00Z → 14:00 local → 2026-04-30.
        expect(insertParams['business_date'], equals('2026-04-30'));
        expect(insertParams['raw_payload'], isA<String>());
        expect(
          (insertParams['raw_payload'] as String).contains('"id":"ADP-TE-9001"'),
          isTrue,
        );
      },
    );

    test(
      'AdpGateway.writeTimePunchFact path translates the bespoke fact into '
      'the same canonical INSERT (shared private writer)',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final wrote = await sink.writeTimePunchFact(
          AdpCanonicalTimePunchFact(
            operatorId: _opA,
            locationId: _locA,
            vendorEntityId: 'ADP-TE-9001',
            vendorModifiedAt: DateTime.utc(2026, 5, 1, 2, 0, 30),
            shiftStart: DateTime.utc(2026, 4, 30, 18, 0, 0),
            shiftEnd: DateTime.utc(2026, 5, 1, 2, 0, 0),
            roleName: 'Server',
            employeeId: 'G3W001',
            module: kAdpModuleWorkforceNow,
            rawPayload: const <String, Object?>{
              'id': 'ADP-TE-9001',
            },
          ),
        );
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['employee_source_id'], equals('G3W001'));
        expect(insertParams['role_name'], equals('Server'));
        expect(insertParams['vendor_entity_id'], equals('ADP-TE-9001'));
        expect(insertParams['hours_worked'], equals(28800));
      },
    );

    test(
      'open punch (exit_date_time absent in ADP payload) writes shift_end '
      'as NULL via the typed shift_end:null bind, and hours_worked falls '
      'back to 0 when neither dict supplies it nor an end timestamp exists',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        // adpBackfillBatchPage1[2] is the open-punch fixture row
        // (exit_date_time = null, WFM-style workAssignment.jobTitle).
        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.adpBackfillBatchPage1[2]),
        );

        final tx = pool.transactions.single;
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['shift_end'], isNull,
            reason: 'open punch → shift_end MUST bind as NULL so the '
                'aggregator can detect the in-progress state');
        expect(insertParams['hours_worked'], equals(0),
            reason: 'open punch with no dict-supplied hours falls back to 0');
        // WFM-style fixture: role_name resolved via workAssignment.jobTitle
        // fallback, proving the sink stays module-agnostic.
        expect(insertParams['role_name'], equals('Bartender'));
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
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        final canonical =
            _canonicalFromFixture(fixture.adpBackfillBatchPage1[0]);
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
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: 'page-3',
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
        expect(params['resource'], equals(adpWatermarkResource));
        expect(params['cursor_token'], equals('page-3'));
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
        final pool = _SinkPool();
        final sink = AdpPostgresSink(
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
            reason: 'demo-flip category for an ADP labor sink is "labor"');
      },
    );

    test(
      'gates fail → no INSERT issued (connection not yet connected, or '
      'first backfill not committed, or records=0)',
      () async {
        final pool = _SinkPool();
        final sink = AdpPostgresSink(
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
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.adpBackfillBatchPage1[0]),
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
      'transaction (defense in depth: the strict 8-4-4-4-12 UUID check '
      'short-circuits invalid input out of the SET LOCAL payload)',
      () async {
        final pool = _SinkPool();
        final sink = AdpPostgresSink(
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
        final pool = _SinkPool();
        final sink = AdpPostgresSink(
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

  group('Test F — module-agnostic invariant', () {
    test(
      'upsertLaborPunch does NOT issue a connector_connection module '
      'SELECT (module disambiguation lives in the adapter at connect; '
      'the sink writes the same row shape for any ADP module)',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.adpBackfillBatchPage1[0]),
        );

        final tx = pool.transactions.single;
        // No "select module from public.connector_connection" anywhere
        // in the labor-punch write path — the sink consumes the
        // canonical-fact dict regardless of source module.
        expect(
          tx.executedSql.any(
            (s) => s.contains('from public.connector_connection') &&
                s.contains('module'),
          ),
          isFalse,
          reason: 'sink must not query connector_connection.module on '
              'the labor-punch write path',
        );
      },
    );

    test(
      'AdpGateway.writeTimePunchFact accepts both Workforce Now and '
      'Workforce Manager modules without taking different code paths',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffectedSequence: <int>[1, 1],
        );
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        for (final module in <String>[
          kAdpModuleWorkforceNow,
          kAdpModuleWorkforceManager,
        ]) {
          await sink.writeTimePunchFact(
            AdpCanonicalTimePunchFact(
              operatorId: _opA,
              locationId: _locA,
              vendorEntityId: 'ADP-TE-90M-$module',
              vendorModifiedAt: DateTime.utc(2026, 5, 1, 2, 0, 30),
              shiftStart: DateTime.utc(2026, 4, 30, 18, 0, 0),
              shiftEnd: DateTime.utc(2026, 5, 1, 2, 0, 0),
              roleName: 'Server',
              employeeId: 'G3W001',
              module: module,
              rawPayload: const <String, Object?>{},
            ),
          );
        }
        expect(pool.transactions, hasLength(2),
            reason: 'one tx per writeTimePunchFact call, regardless of '
                'module — proves the sink is module-agnostic');
      },
    );
  });

  group('Test G — V1 hours-only invariant', () {
    test(
      'every fixture row commits with the wage-dollar columns absent from '
      'the INSERT (so the columns land NULL by default)',
      () async {
        final allRows = <Map<String, Object?>>[
          ...fixture.adpBackfillBatchPage1,
          ...fixture.adpBackfillBatchPage2,
        ];
        // The sink's labor_punches INSERT must never carry these
        // wage-dollar write tokens.
        const wageDollarTokens = <String>[
          'pay_rate',
          'labor_dollars',
          'total_pay',
        ];
        for (final record in allRows) {
          final pool = _SinkPool(
            locationTimezoneRow: _toLocationsRow(),
            insertAffected: 1,
          );
          final sink = AdpPostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
            now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
          );
          await sink.upsertLaborPunch(
            operatorId: _opA,
            locationId: _locA,
            canonicalPunch: _canonicalFromFixture(record),
          );

          final tx = pool.transactions.single;
          final insertSql = tx.executedSql.firstWhere(
            (s) => s.contains('insert into public.labor_punches'),
          );
          for (final token in wageDollarTokens) {
            expect(insertSql, isNot(contains(token)),
                reason: 'V1 hours-only invariant — INSERT must not '
                    'reference "$token" so the column lands NULL');
          }
          final insertParams = tx.parameters.firstWhere(
            (p) => p.containsKey('employee_source_id'),
          );
          for (final token in wageDollarTokens) {
            expect(insertParams.containsKey(token), isFalse,
                reason: 'V1 hours-only invariant — bind params must not '
                    'carry a "$token" key');
          }
          expect(insertParams['hours_worked'], isA<num>());
        }
      },
    );
  });

  group('Cover / reservation rejection (defense-in-depth)', () {
    test('upsertCoverFact throws UnsupportedError — labor sink', () async {
      final sink = AdpPostgresSink(
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
      final sink = AdpPostgresSink(
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
        'lib/infrastructure/persistence/postgres/adp_postgres_sink.dart',
      ).readAsStringSync();
      const banned = <String>[
        // V1 lean cut 2 ledger (mirror of the QBT lane).
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
        // V1 hours-only invariant: wage-dollar write-side tokens are
        // forbidden in the sink source. Per the 2026-05-05
        // spine-contract falsehood correction #7, ADP V1 wage class is
        // `hoursOnly` — labor_punches rows store hours only and the
        // wage-dollar columns are left NULL.
        'pay_rate',
        'labor_dollars',
        'total_pay',
      ];
      final lower = source.toLowerCase();
      for (final token in banned) {
        expect(lower.contains(token.toLowerCase()), isFalse,
            reason: 'banned item present in sink source: $token');
      }
    });

    test(
      'sink source restricts package:postgres to the canonical '
      'infrastructure directory (file lives in '
      'lib/infrastructure/persistence/postgres/, so the import is '
      'permitted; this test pins that the sink does not leak any '
      'postgres types into a public surface)',
      () {
        final source = File(
          'lib/infrastructure/persistence/postgres/adp_postgres_sink.dart',
        ).readAsStringSync();
        expect(source.contains("import 'package:postgres/"), isFalse,
            reason: 'sink uses PostgresExecutor seam; direct '
                'package:postgres import not required');
      },
    );
  });

  // Code Health LB#2 — `appendSyncLog` writes the `payload_preview`
  // JSONB column through the shared `encodePayloadPreviewForSyncLog`
  // helper, which redacts the payload via `redactWebhookPayload` BEFORE
  // JSON-encoding. Operator-scoped Postgres must never carry vendor
  // secrets / PII in the clear, so any sensitive field name supplied in
  // `payloadPreview` MUST be absent from the encoded INSERT row.
  group('Code Health LB#2 — appendSyncLog redacts payload_preview', () {
    test(
      'sensitive fields (password / api_key / refresh_token / email / '
      'phone / first_name / nested secret) are stripped from the '
      'connector_sync_log INSERT row',
      () async {
        final pool = _SinkPool();
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        await sink.appendSyncLog(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          eventKind: 'poll_success',
          recordsCount: 1,
          payloadPreview: <String, Object?>{
            'records_count': 1,
            'password': 'hunter2',
            'api_key': 'sk_live_abc123',
            'refresh_token': 'rt_def456',
            'email': 'guest@example.com',
            'phone': '+15551234567',
            'first_name': 'Casey',
            'nested': <String, Object?>{
              'secret': 'shhh',
              'safe_field': 'keep-me',
            },
            'tags': <Object?>[
              <String, Object?>{
                'access_token': 'leak',
                'kind': 'visible',
              },
            ],
          },
        );

        expect(pool.transactions, hasLength(1));
        final tx = pool.transactions.single;
        final insertIndex = tx.executedSql.indexWhere(
          (s) => s.contains('insert into public.connector_sync_log'),
        );
        expect(insertIndex, isNonNegative,
            reason: 'appendSyncLog must execute the connector_sync_log INSERT');
        final params = tx.parameters[insertIndex];
        final encoded = params['payload_preview'];
        expect(encoded, isA<String>(),
            reason: 'helper must JSON-encode the redacted preview before write');
        final decoded =
            jsonDecode(encoded! as String) as Map<String, Object?>;

        // Surface fields the redactor strips.
        for (final stripped in <String>[
          'password',
          'api_key',
          'refresh_token',
          'email',
          'phone',
          'first_name',
        ]) {
          expect(decoded.containsKey(stripped), isFalse,
              reason: '$stripped must be redacted out of payload_preview');
        }

        // Nested map: `secret` stripped, sibling preserved.
        expect(decoded['nested'], isA<Map<String, Object?>>());
        final nested = decoded['nested']! as Map<String, Object?>;
        expect(nested.containsKey('secret'), isFalse,
            reason: 'nested secret must be redacted recursively');
        expect(nested['safe_field'], 'keep-me',
            reason: 'non-sensitive nested fields must round-trip');

        // List of maps: token-bearing entry has the token field
        // stripped, neighbours preserved.
        expect(decoded['tags'], isA<List<Object?>>());
        final tags = decoded['tags']! as List<Object?>;
        expect(tags, hasLength(1));
        final tagEntry = tags.single as Map<String, Object?>;
        expect(tagEntry.containsKey('access_token'), isFalse,
            reason: 'access_token in nested list-of-maps must be redacted');
        expect(tagEntry['kind'], 'visible',
            reason: 'non-sensitive sibling in list-of-maps must survive');

        // Non-sensitive top-level field kept intact.
        expect(decoded['records_count'], 1);
      },
    );

    test(
      'null payloadPreview round-trips as a SQL NULL (no JSON literal '
      'on the wire)',
      () async {
        final pool = _SinkPool();
        final sink = AdpPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        await sink.appendSyncLog(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          eventKind: 'poll_success',
          recordsCount: 0,
        );

        final tx = pool.transactions.single;
        final insertIndex = tx.executedSql.indexWhere(
          (s) => s.contains('insert into public.connector_sync_log'),
        );
        expect(insertIndex, isNonNegative);
        expect(tx.parameters[insertIndex]['payload_preview'], isNull);
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
    this.locationTimezoneRow,
    int? insertAffected,
    List<int>? insertAffectedSequence,
  }) : _insertAffectedSequence = insertAffectedSequence != null
            ? List<int>.from(insertAffectedSequence)
            : (insertAffected != null
                ? <int>[insertAffected]
                : <int>[]);

  /// `(timezone, business_day_rollover_hour)` row returned by the
  /// fake `locations` SELECT. Required when a labor_punches INSERT
  /// reaches business_date computation.
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
      locationTimezoneRow: locationTimezoneRow,
      drainInsertAffected: _drainInsertAffected,
    );
    transactions.add(tx);
    return tx;
  }
}

class _SinkTransaction extends PostgresTransaction {
  _SinkTransaction({
    required this.locationTimezoneRow,
    required this.drainInsertAffected,
  });

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
