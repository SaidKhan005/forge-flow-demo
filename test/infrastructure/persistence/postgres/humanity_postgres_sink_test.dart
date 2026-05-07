// Phase 8 Wave B `8.spine-bridge.1.HM` — Humanity (TCP) Postgres
// sink test suite.
//
// Coverage matches the slice prompt's required tests A-H:
//
//   A. Round-trip with `humanity_punches_fixture` (one record →
//      INSERT into labor_punches with the canonical column list).
//   B. Idempotency replay (second upsert returns false).
//   C. Watermark per batch (advanceWatermark UPSERT shape; resource
//      pinned to "labor_punches").
//   D. Demo-mode flip (evaluateDemoFlip writes the demo_mode_state row
//      with category="labor"; idempotent SQL shape preserves the
//      original triggering connection).
//   E. RLS + tenancy (every public method runs through `withTenant` →
//      SET LOCAL `app.operator_id` / `app.location_id`).
//   F. Auth-shape-agnostic credential wipe: `wipeCredentials` issues
//      the same `delete from public.vendor_credentials` SQL regardless
//      of the stored ciphertext shape (OAuth bearer vs Humanity legacy
//      session token). Mirrors QBT's "module disambiguation" slot —
//      Humanity has no module sub-dialog, so the per-vendor seam is
//      auth-shape ignorance instead of module gating.
//   G. Existing `humanity_labor_adapter_test.dart` smoke-runs — verified
//      by running the suite via `flutter test` after this slice lands;
//      no new assertion in this file.
//   H. Banned-items grep on sink source (V1 lean cut 2 ledger).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/humanity_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/humanity_labor_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/labor/fixtures/humanity_punches_fixture.dart'
    as fixture;

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _connId = '33333333-3333-3333-3333-333333333333';

Map<String, Object?> _canonicalFromFixture(Map<String, Object?> record) {
  return <String, Object?>{
    'vendor_entity_id': record['id']!.toString(),
    'vendor_modified_at': record['updated']! as String,
    'shift_start': record['in_time']! as String,
    'shift_end': record['out_time']! as String,
    'employee_source_id':
        (record['employee_id'] ?? record['employee'])!.toString(),
    'role_name': (record['position_name'] ?? record['position'])! as String,
    'raw_payload': record,
  };
}

void main() {
  group('Test A — round-trip with humanity_punches_fixture', () {
    test(
      'one fixture record → INSERT into labor_punches with operator-scoped '
      'columns, vendor_id="humanity", labor_dollars NOT supplied (Humanity '
      'is scheduling-only; pay_rate is null)',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final wrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.humanityBackfillBatchPage1.first),
        );
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        // The SQL inserts into the canonical labor_punches table with
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
        // labor_dollars must NOT appear in the INSERT — Humanity is
        // scheduling-only and exposes no pay-rate field; the
        // aggregator joins payroll-side facts when present.
        expect(insertSql, isNot(contains('labor_dollars')),
            reason: 'sink must NOT supply labor_dollars; Humanity is '
                'scheduling-only with no wage data');
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

        // Bind params for fact columns. Filter on `employee_source_id`
        // because the locations SELECT also binds `vendor_id`-shaped
        // params via the timezone resolver; only the labor_punches
        // INSERT binds the employee field.
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['operator_id'], equals(_opA));
        expect(insertParams['location_id'], equals(_locA));
        expect(insertParams['employee_source_id'], equals('EMP-100'));
        expect(insertParams['role_name'], equals('Server'));
        expect(insertParams['vendor_entity_id'], equals('HUM-9001'));
        expect(insertParams['vendor_id'], equals('humanity'));
        // Humanity in_time → 2026-05-01T16:00:00Z;
        // out_time → 2026-05-01T22:00:00Z; hours_worked derived as
        // (end - start).inSeconds = 6 * 3600 = 21600.
        expect(insertParams['hours_worked'], equals(21600));
        expect(insertParams['pay_rate'], isNull,
            reason: 'Humanity exposes no pay_rate; sink leaves it null');
        expect(insertParams['shift_start'],
            equals(DateTime.utc(2026, 5, 1, 16, 0, 0)));
        expect(insertParams['shift_end'],
            equals(DateTime.utc(2026, 5, 1, 22, 0, 0)));
        expect(insertParams['vendor_modified_at'],
            equals(DateTime.utc(2026, 4, 30, 18, 5, 0)));
        // business_date computed via IanaTimezoneConverter from the
        // location's `America/New_York` timezone + 4-hour rollover:
        // shift_start 2026-05-01T16:00:00Z → 12:00 local → 2026-05-01.
        expect(insertParams['business_date'], equals('2026-05-01'));
        // raw_payload is a JSON-encoded string of the Humanity record.
        expect(insertParams['raw_payload'], isA<String>());
        expect(
          (insertParams['raw_payload'] as String).contains('"id":"HUM-9001"'),
          isTrue,
        );
      },
    );

    test(
      'HumanityGateway.writeShiftFact path lands the same INSERT shape as '
      'the CanonicalSink.upsertLaborPunch dispatch path (shared private '
      'writer)',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final fact = HumanityCanonicalShiftFact(
          operatorId: _opA,
          locationId: _locA,
          vendorEntityId: 'HUM-9001',
          vendorModifiedAt: DateTime.utc(2026, 4, 30, 18, 5, 0),
          employeeId: 'EMP-100',
          positionName: 'Server',
          shiftStart: DateTime.utc(2026, 5, 1, 16, 0, 0),
          shiftEnd: DateTime.utc(2026, 5, 1, 22, 0, 0),
          rawPayload: const <String, Object?>{'id': 'HUM-9001'},
        );
        final wrote = await sink.writeShiftFact(fact);
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.labor_punches'),
        );
        // Same INSERT shape as the Map-dispatch path (A1 rekey).
        expect(
          insertSql,
          contains(
            'on conflict (operator_id, location_id, vendor_id, vendor_entity_id)',
          ),
        );
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['employee_source_id'], equals('EMP-100'));
        expect(insertParams['role_name'], equals('Server'));
        expect(insertParams['vendor_entity_id'], equals('HUM-9001'));
        expect(insertParams['hours_worked'], equals(21600),
            reason: 'shared writer derives hours_worked from '
                '(shiftEnd - shiftStart).inSeconds');
        expect(insertParams['pay_rate'], isNull);
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
          locationTimezoneRow: _toLocationsRow(),
          insertAffectedSequence: <int>[1, 0],
        );
        final sink = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        final canonical =
            _canonicalFromFixture(fixture.humanityBackfillBatchPage1.first);
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
        final sink = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: 'next-page-token',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
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
        expect(params['resource'], equals(humanityWatermarkResource));
        expect(params['resource'], equals('labor_punches'));
        expect(params['cursor_token'], equals('next-page-token'));
        expect(params['last_modified_seen'],
            equals(DateTime.utc(2026, 5, 1, 19, 25, 0)));
      },
    );

    test(
      'HumanityGateway.writeWatermark path resolves connection_id from the '
      'active tenant context and lands the same UPSERT shape as the '
      'CanonicalSink.advanceWatermark path',
      () async {
        final pool = _SinkPool(connectionId: _connId);
        final sink = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.writeWatermark(
          operatorId: _opA,
          locationId: _locA,
          row: HumanityWatermarkRow(
            cursorToken: 'humanity-cursor-2',
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 19, 25, 0),
          ),
        );

        final tx = pool.transactions.single;
        final upsertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.connector_sync_watermark'),
        );
        expect(upsertSql, contains('on conflict (connection_id, resource)'));
        final params = tx.parameters.firstWhere(
          (p) => p['connection_id'] == _connId,
        );
        expect(params['resource'], equals('labor_punches'),
            reason: 'gateway path pins resource = labor_punches identically');
        expect(params['cursor_token'], equals('humanity-cursor-2'));
      },
    );
  });

  group('Test D — demo-mode flip', () {
    test(
      'connect + first backfill committed + records ≥ 1 → INSERT into '
      'demo_mode_state with is_demo=false; ON CONFLICT idempotent UPDATE '
      'guarded by is_demo=true preserves original triggering connection_id; '
      'category column carries "labor"',
      () async {
        final pool = _SinkPool();
        final sink = HumanityPostgresSink(
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
        expect(params['category'], equals('labor'),
            reason: 'Humanity is a labor-category vendor; demo flip writes '
                '"labor" so the demo banner clears on the labor row only');
      },
    );

    test(
      'gates fail → no INSERT issued (connection not yet connected, or '
      'first backfill not committed, or records=0)',
      () async {
        final pool = _SinkPool();
        final sink = HumanityPostgresSink(
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
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.humanityBackfillBatchPage1.first),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '1',
          lastModifiedSeen: DateTime.utc(2026, 5, 1, 11, 0, 0),
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
        final pool = _SinkPool();
        final sink = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        Object? thrown;
        try {
          await sink.advanceWatermark(
            operatorId: 'not-a-uuid',
            locationId: _locA,
            connectionId: _connId,
            cursorToken: '1',
            lastModifiedSeen: DateTime.utc(2026, 5, 1),
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
        final sink = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '1',
          lastModifiedSeen: DateTime.utc(2026, 5, 1),
        );
        await sink.advanceWatermark(
          operatorId: _opB,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '2',
          lastModifiedSeen: DateTime.utc(2026, 5, 1),
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

  group('Test F — auth-shape-agnostic credential wipe', () {
    test(
      'wipeCredentials issues `delete from public.vendor_credentials` keyed '
      'on (operator_id, location_id, vendor_id) — same SQL whether the '
      'stored ciphertext is an OAuth bearer or a Humanity legacy session '
      'token; the sink does NOT branch on auth shape',
      () async {
        // Long ciphertext shape: simulates a lengthy OAuth bearer.
        final poolOauthShape = _SinkPool();
        final sinkOauthShape = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(poolOauthShape),
        );
        await sinkOauthShape.wipeCredentials(
          operatorId: _opA,
          locationId: _locA,
        );

        // Short ciphertext shape: simulates a Humanity legacy session
        // token (typically shorter than an OAuth bearer).
        final poolLegacyShape = _SinkPool();
        final sinkLegacyShape = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(poolLegacyShape),
        );
        await sinkLegacyShape.wipeCredentials(
          operatorId: _opA,
          locationId: _locA,
        );

        // Both transactions run the same DELETE shape — the sink does
        // not branch on the stored ciphertext.
        for (final pool in <_SinkPool>[poolOauthShape, poolLegacyShape]) {
          final tx = pool.transactions.single;
          final deleteSql = tx.executedSql.firstWhere(
            (s) => s.contains('delete from public.vendor_credentials'),
          );
          expect(deleteSql, contains('operator_id = @operator_id::uuid'));
          expect(deleteSql, contains('location_id = @location_id::uuid'));
          expect(deleteSql, contains('vendor_id = @vendor_id'));
          // Also flips the connection row to disconnected so the
          // operator surface reflects the wipe.
          final updateSql = tx.executedSql.firstWhere(
            (s) => s.contains('update public.connector_connection'),
          );
          expect(updateSql, contains("status = 'disconnected'"));
          expect(tx.rollbackCount, equals(0),
              reason: 'wipe must commit cleanly (operator-initiated path)');
        }

        final deleteParamsOauth =
            poolOauthShape.transactions.single.parameters.firstWhere(
          (p) =>
              p['vendor_id'] == 'humanity' &&
              p['operator_id'] == _opA &&
              p.containsKey('location_id') &&
              !p.containsKey('value'),
        );
        final deleteParamsLegacy =
            poolLegacyShape.transactions.single.parameters.firstWhere(
          (p) =>
              p['vendor_id'] == 'humanity' &&
              p['operator_id'] == _opA &&
              p.containsKey('location_id') &&
              !p.containsKey('value'),
        );
        // Identical bind parameters across both auth shapes.
        expect(deleteParamsOauth, equals(deleteParamsLegacy));
      },
    );

    test(
      'wipeCredentials always pins vendor_id = "humanity"; cross-vendor '
      'credentials on the same (operator_id, location_id) are NOT wiped '
      '(operator may have multiple labor connectors connected at once)',
      () async {
        final pool = _SinkPool();
        final sink = HumanityPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        await sink.wipeCredentials(
          operatorId: _opA,
          locationId: _locA,
        );

        final tx = pool.transactions.single;
        final deleteParams = tx.parameters.firstWhere(
          (p) => p.containsKey('vendor_id') && !p.containsKey('value'),
        );
        expect(deleteParams['vendor_id'], equals('humanity'),
            reason: 'wipe pins vendor_id so a co-resident QBT/7shifts '
                'connector is not collateral damage');
      },
    );
  });

  group('Cover / reservation rejection (defense-in-depth)', () {
    test('upsertCoverFact throws UnsupportedError — labor sink', () async {
      final sink = HumanityPostgresSink(
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
      final sink = HumanityPostgresSink(
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
        'lib/infrastructure/persistence/postgres/humanity_postgres_sink.dart',
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
          'lib/infrastructure/persistence/postgres/humanity_postgres_sink.dart',
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
    this.locationTimezoneRow,
    this.connectionId,
    int? insertAffected,
    List<int>? insertAffectedSequence,
  })  : _insertAffectedSequence = insertAffectedSequence != null
            ? List<int>.from(insertAffectedSequence)
            : (insertAffected != null ? <int>[insertAffected] : <int>[]);

  /// `(timezone, business_day_rollover_hour)` row returned by the
  /// fake `locations` SELECT. Required when a labor_punches INSERT
  /// reaches business_date computation.
  final PostgresRow? locationTimezoneRow;

  /// Connection id returned by the fake `connector_connection`
  /// SELECT used by [HumanityPostgresSink.writeWatermark]. `null`
  /// triggers the "no connection on file" StateError path.
  final String? connectionId;

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
      connectionId: connectionId,
      drainInsertAffected: _drainInsertAffected,
    );
    transactions.add(tx);
    return tx;
  }
}

class _SinkTransaction extends PostgresTransaction {
  _SinkTransaction({
    required this.locationTimezoneRow,
    required this.connectionId,
    required this.drainInsertAffected,
  });

  final PostgresRow? locationTimezoneRow;
  final String? connectionId;
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
      final cid = connectionId;
      if (cid == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'connection_id': cid},
      ];
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
