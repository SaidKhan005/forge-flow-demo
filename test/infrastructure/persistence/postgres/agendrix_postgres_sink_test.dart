// Phase 8 Wave B `8.spine-bridge-sink-fanout.AG` — Agendrix Postgres
// sink test suite.
//
// Coverage mirrors the QBT sink suite (slice `.1.QBT`):
//
//   A. Round-trip with `agendrix_punches_fixture.sampleAgendrixTimeEntry`.
//   B. Idempotency replay (second upsert returns false).
//   C. Watermark per batch (advanceWatermark UPSERT shape; resource =
//      'labor_punches'; `connectionId` widened — bespoke caller path
//      resolves via connector_connection lookup).
//   D. Demo-mode flip (evaluateDemoFlip writes the demo_mode_state row
//      with category='labor'; idempotent SQL shape preserves original
//      triggering connection).
//   E. RLS + tenancy (every public method runs through `withTenant`
//      → SET LOCAL `app.operator_id` / `app.location_id`).
//   F. Disconnect / credential wipe — `wipeCredentialsPreserveWatermark`
//      wipes `vendor_credentials` + flips `connector_connection` to
//      disconnected, leaving `connector_sync_watermark` rows intact.
//      (Replaces QBT's module disambiguation test — Agendrix is a
//      single-product vendor with no module split.)
//   G. Existing `agendrix_labor_adapter_test.dart` smoke-runs — verified
//      separately by running the adapter suite via `flutter test`; no
//      new assertion in this file.
//   H. Banned-items grep on sink source (V1 lean cut 2 ledger).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/agendrix_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/labor/fixtures/agendrix_punches_fixture.dart'
    as fixture;

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _connId = '33333333-3333-3333-3333-333333333333';
const String _connIdResolved = '55555555-5555-5555-5555-555555555555';

/// Translate the fixture record into the canonical-fact dict shape the
/// Agendrix adapter would produce. Mirrors
/// `AgendrixLaborAdapter._mapTimeEntryToCanonical` field-for-field so
/// the sink test exercises the same dict the adapter hands the sink in
/// production.
Map<String, Object?> _canonicalFromFixture(Map<String, Object?> record) {
  final position = record['position'];
  final positionName = position is Map ? position['name'] : null;
  return <String, Object?>{
    'vendor_id': 'agendrix',
    'vendor_entity_id': record['id']!.toString(),
    'shift_start': record['start_time']! as String,
    'shift_end':
        record['end_time'] is String ? record['end_time'] as String : null,
    'role_name': positionName?.toString(),
    'employee_id': record['user_id']?.toString(),
    'vendor_modified_at': record['updated_at']! as String,
    'covers_source': 'not_applicable',
    'wage_source': 'app_fallback',
    'raw_payload': record,
  };
}

void main() {
  group('Test A — round-trip with agendrix_punches_fixture', () {
    test(
      'one fixture record → INSERT into labor_punches with operator-scoped '
      'columns, vendor_id="agendrix", pay_rate NULL (app_fallback wage '
      'source), hours_worked = (shift_end - shift_start).inSeconds',
      () async {
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final wrote = await sink.upsertTimePunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: _canonicalFromFixture(fixture.sampleAgendrixTimeEntry),
        );
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        // The SQL inserts into the canonical labor_punches table, with
        // every operator-scoped column the prompt requires.
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
        // aggregator computes dollars; the sink leaves the column NULL.
        expect(insertSql, isNot(contains('labor_dollars')),
            reason: 'sink must NOT supply labor_dollars; aggregator '
                'derives it via the wage-authority service');
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
        // because the locations SELECT also binds parameters; only the
        // labor_punches INSERT binds the employee field.
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['operator_id'], equals(_opA));
        expect(insertParams['location_id'], equals(_locA));
        expect(insertParams['employee_source_id'], equals('usr_98231'));
        expect(insertParams['role_name'], equals('Server'));
        expect(insertParams['vendor_id'], equals('agendrix'));
        expect(insertParams['vendor_entity_id'], equals('te_412901'));
        expect(insertParams['shift_start'],
            equals(DateTime.utc(2026, 5, 2, 15, 0, 0)));
        expect(insertParams['shift_end'],
            equals(DateTime.utc(2026, 5, 2, 22, 30, 0)));
        expect(insertParams['vendor_modified_at'],
            equals(DateTime.utc(2026, 5, 2, 22, 32, 14)));
        // hours_worked = (22:30 - 15:00) = 7.5h = 27000s.
        expect(insertParams['hours_worked'], equals(27000));
        // pay_rate is NULL — Agendrix wage source = app_fallback.
        expect(insertParams['pay_rate'], isNull,
            reason: 'pay_rate must bind NULL; wage_source=app_fallback '
                'means the aggregator falls back to wage-authority');
        // business_date computed via IanaTimezoneConverter from the
        // location's `America/New_York` timezone + 4-hour rollover:
        // shift_start 2026-05-02T15:00:00Z → 11:00 local → 2026-05-02.
        expect(insertParams['business_date'], equals('2026-05-02'));
        // raw_payload is a JSON-encoded string of the Agendrix record.
        expect(insertParams['raw_payload'], isA<String>());
        expect(
          (insertParams['raw_payload'] as String).contains('te_412901'),
          isTrue,
        );
      },
    );

    test(
      'open timesheet (shift_end null) writes shift_end=NULL and '
      'hours_worked=NULL via typed binds',
      () async {
        final openTimesheet =
            Map<String, Object?>.from(fixture.sampleAgendrixTimeEntry)
              ..['end_time'] = '';
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.upsertTimePunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: _canonicalFromFixture(openTimesheet),
        );

        final tx = pool.transactions.single;
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['shift_end'], isNull,
            reason: 'open timesheet → shift_end MUST bind as NULL so the '
                'aggregator can detect the in-progress state');
        expect(insertParams['hours_worked'], isNull,
            reason: 'open timesheet → hours_worked has no upper bound; '
                'bind NULL rather than fabricate a duration');
      },
    );

    test(
      'CanonicalSink.upsertLaborPunch entry hits the same shared writer '
      'as AgendrixCanonicalSink.upsertTimePunch (one INSERT, same column '
      'list, same params)',
      () async {
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        final wrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch:
              _canonicalFromFixture(fixture.sampleAgendrixTimeEntry),
        );
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.labor_punches'),
        );
        expect(insertSql, contains('vendor_id'));
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['vendor_id'], equals('agendrix'));
        expect(insertParams['vendor_entity_id'], equals('te_412901'));
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
          connectorConnectionId: _connIdResolved,
          locationTimezoneRow: _toLocationsRow(),
          insertAffectedSequence: <int>[1, 0],
        );
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        final canonical =
            _canonicalFromFixture(fixture.sampleAgendrixTimeEntry);
        final firstWrote = await sink.upsertTimePunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonical,
        );
        expect(firstWrote, isTrue);

        final secondWrote = await sink.upsertTimePunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonical,
        );
        expect(secondWrote, isFalse,
            reason: 'idempotency UNIQUE short-circuit must surface as '
                'upsertTimePunch == false on replay');
      },
    );
  });

  group('Test C — watermark per batch', () {
    test(
      'advanceWatermark UPSERTs into connector_sync_watermark with resource '
      '= "labor_punches" and (connection_id, resource) as the conflict key '
      '(unified-interface caller path: explicit connectionId)',
      () async {
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
        );
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: 'cursor-after-batch-3',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 22, 32, 14),
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
        expect(params['cursor_token'], equals('cursor-after-batch-3'));
        expect(params['last_modified_seen'],
            equals(DateTime.utc(2026, 5, 2, 22, 32, 14)));
      },
    );

    test(
      'bespoke-interface caller path: connectionId omitted → sink resolves '
      'connection_id from connector_connection (operator, location, '
      'vendor=agendrix) before the watermark UPSERT',
      () async {
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
        );
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          cursorToken: 'cursor-1',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 22, 32, 14),
        );

        final tx = pool.transactions.single;
        // The connector_connection SELECT runs before the INSERT.
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

  group('Test D — demo-mode flip', () {
    test(
      'connect + first backfill committed + records ≥ 1 → INSERT into '
      'demo_mode_state with category="labor", is_demo=false; ON CONFLICT '
      'idempotent UPDATE guarded by is_demo=true preserves the original '
      'triggering connection_id',
      () async {
        final pool = _SinkPool();
        final sink = AgendrixPostgresSink(
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
        final pool = _SinkPool();
        final sink = AgendrixPostgresSink(
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
      'upsertTimePunch + advanceWatermark + appendSyncLog + '
      'evaluateDemoFlip all inject app.operator_id and app.location_id '
      'via SET LOCAL (set_config(..., true)) before any business SQL runs',
      () async {
        final pool = _SinkPool(
          connectorConnectionId: _connIdResolved,
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        await sink.upsertTimePunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact:
              _canonicalFromFixture(fixture.sampleAgendrixTimeEntry),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '1',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 22, 0, 0),
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
        final pool = _SinkPool(connectorConnectionId: _connIdResolved);
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        Object? thrown;
        try {
          await sink.advanceWatermark(
            operatorId: 'not-a-uuid',
            locationId: _locA,
            connectionId: _connId,
            cursorToken: '1',
            lastModifiedSeen: DateTime.utc(2026, 5, 2),
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
        final pool = _SinkPool(connectorConnectionId: _connIdResolved);
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '1',
          lastModifiedSeen: DateTime.utc(2026, 5, 2),
        );
        await sink.advanceWatermark(
          operatorId: _opB,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: '2',
          lastModifiedSeen: DateTime.utc(2026, 5, 2),
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
      'wipeCredentialsPreserveWatermark UPDATEs vendor_credentials '
      '(ciphertexts NULL, is_active=false) and connector_connection '
      '(status=disconnected) for vendor_id="agendrix"; watermark rows '
      'are NOT touched',
      () async {
        final pool = _SinkPool();
        final sink = AgendrixPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
        );

        final outcome = await sink.wipeCredentialsPreserveWatermark(
          operatorId: _opA,
          locationId: _locA,
        );

        expect(outcome.credentialsWiped, isTrue);
        expect(outcome.webhookUnregistered, isTrue,
            reason: 'poll-only vendor — no webhook subscription to unregister; '
                'always reports true to keep the framework contract uniform');
        expect(outcome.watermarkPreserved, isTrue,
            reason: 'reconnect resumes from the last canonical write — '
                'watermark rows must NOT be deleted on disconnect');

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
              p['vendor_id'] == 'agendrix' &&
              p.containsKey('now') &&
              !p.containsKey('status'),
        );
        expect(credentialsParams['operator_id'], equals(_opA));
        expect(credentialsParams['location_id'], equals(_locA));

        final connectionParams = tx.parameters.firstWhere(
          (p) => p['vendor_id'] == 'agendrix' && p['status'] == 'disconnected',
        );
        expect(connectionParams['disconnect_reason'], equals('operator_action'));
      },
    );
  });

  group('Cover / reservation rejection (defense-in-depth)', () {
    test('upsertCoverFact throws UnsupportedError — labor sink', () async {
      final sink = AgendrixPostgresSink(
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
      final sink = AgendrixPostgresSink(
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
        'lib/infrastructure/persistence/postgres/agendrix_postgres_sink.dart',
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
      'sink source uses the PostgresExecutor seam — no direct '
      'package:postgres import (file lives under '
      'lib/infrastructure/persistence/postgres/, so the import would be '
      'permitted, but the sink composes only on the seam interfaces; '
      'this test pins that absence so a future refactor cannot silently '
      'add it)',
      () {
        final source = File(
          'lib/infrastructure/persistence/postgres/agendrix_postgres_sink.dart',
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
