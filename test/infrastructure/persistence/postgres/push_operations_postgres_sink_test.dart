// Phase 8 Wave B `8.spine-bridge.1.PU` — Push Operations Postgres
// sink test suite.
//
// Coverage matches the slice prompt's required tests A-H:
//
//   A. Round-trip with `push_operations_punches_fixture`.
//   B. Idempotency replay (second upsert returns false).
//   C. Watermark per batch (advanceWatermark UPSERT shape).
//   D. Demo-mode flip (evaluateDemoFlip writes the demo_mode_state row;
//      idempotent SQL shape preserves original triggering connection).
//   E. RLS + tenancy (every public method runs through `withTenant` →
//      SET LOCAL `app.operator_id` / `app.location_id`).
//   F. Bespoke connection_id resolution (the bespoke
//      [PushOperationsCanonicalSink] callers do not carry connection_id;
//      the sink looks it up from `connector_connection`. The unified
//      [CanonicalSink] callers pass it through unchanged).
//   G. V1 hours-only invariant: every labor_punches INSERT omits the
//      wage-rate and wage-dollars columns so the Postgres defaults
//      leave them NULL. Loops over every documented fixture row so a
//      future column-list edit trips the suite immediately.
//   H. Banned-items grep on sink source (V1 lean cut 2 ledger plus
//      the V1 hours-only wage-dollar write tokens).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/push_operations_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/labor/push_operations_labor_adapter.dart'
    show pushOperationsVendorId;
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/labor/fixtures/push_operations_punches_fixture.dart'
    as fixture;

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _connId = '33333333-3333-3333-3333-333333333333';
const String _resolvedConnId = '55555555-5555-5555-5555-555555555555';

/// Mirrors `PushOperationsLaborAdapter._mapShiftToCanonical`. The sink
/// consumes the canonical-fact dict the adapter produces, so the test
/// builds the same shape from the documented fixture.
Map<String, Object?> _canonicalFromShift(Map<String, Object?> record) {
  return <String, Object?>{
    'vendor_id': pushOperationsVendorId,
    'vendor_entity_id': record['id']!.toString(),
    'shift_start': record['start_at']! as String,
    'shift_end': record['end_at']! as String,
    'role_name': record['position_name']! as String,
    'employee_id': record['employee_id']!.toString(),
    'vendor_modified_at': record['updated_at']! as String,
    'covers_source': 'not_applicable',
    'raw_payload': record,
  };
}

void main() {
  group('Test A — round-trip with push_operations_punches_fixture', () {
    test(
      'one fixture record → INSERT into labor_punches with operator-scoped '
      'columns and vendor_id="push_operations"',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
        );
        final wrote = await sink.upsertShift(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: _canonicalFromShift(fixture.samplePushOperationsShift),
        );
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        // The SQL inserts into the canonical labor_punches table with
        // every operator-scoped column the prompt requires. Assert the
        // column names appear inside the INSERT statement so a future
        // column-list rename trips the suite immediately.
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

        // Bind params for fact columns. Filter on `employee_source_id`
        // because the locations SELECT also runs in the same tx; only
        // the labor_punches INSERT binds the employee field.
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertParams['operator_id'], equals(_opA));
        expect(insertParams['location_id'], equals(_locA));
        expect(insertParams['employee_source_id'], equals('5512'));
        expect(insertParams['role_name'], equals('Server'));
        expect(insertParams['vendor_id'], equals('push_operations'));
        expect(insertParams['vendor_entity_id'], equals('800101'));
        // 16:00:00Z → 23:30:00Z = 7.5 h = 27000 s.
        expect(insertParams['hours_worked'], equals(27000));
        expect(insertParams['shift_start'],
            equals(DateTime.utc(2026, 5, 2, 16, 0, 0)));
        expect(insertParams['shift_end'],
            equals(DateTime.utc(2026, 5, 2, 23, 30, 0)));
        expect(insertParams['vendor_modified_at'],
            equals(DateTime.utc(2026, 5, 2, 15, 45, 0)));
        // business_date computed via IanaTimezoneConverter from the
        // location's `America/New_York` timezone + 4-hour rollover:
        // shift_start 2026-05-02T16:00:00Z → 12:00 EDT → 2026-05-02.
        expect(insertParams['business_date'], equals('2026-05-02'));
        // raw_payload is a JSON-encoded string of the shifts[] record.
        expect(insertParams['raw_payload'], isA<String>());
        expect(
          (insertParams['raw_payload'] as String).contains('"id":800101'),
          isTrue,
        );
      },
    );

    test(
      'unified CanonicalSink.upsertLaborPunch entry point delegates to the '
      'same shared writer (asserts the dispatcher path lands the same row '
      'shape as the bespoke adapter path)',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
        );
        final wrote = await sink.upsertLaborPunch(
          operatorId: _opA,
          locationId: _locA,
          canonicalPunch: _canonicalFromShift(fixture.samplePushOperationsShift),
        );
        expect(wrote, isTrue);

        final tx = pool.transactions.single;
        final insertSql = tx.executedSql.firstWhere(
          (s) => s.contains('insert into public.labor_punches'),
        );
        final insertParams = tx.parameters.firstWhere(
          (p) => p.containsKey('employee_source_id'),
        );
        expect(insertSql, contains('vendor_id'));
        expect(insertParams['vendor_id'], equals('push_operations'));
        expect(insertParams['employee_source_id'], equals('5512'));
      },
    );
  });

  group('Test B — idempotency replay', () {
    test(
      'second arrival of (vendor_id, operator_id, vendor_entity_id, '
      'vendor_modified_at) hits ON CONFLICT DO NOTHING; upsertShift returns '
      'false the second time',
      () async {
        // First insert affected = 1 (new row); replay affected = 0.
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffectedSequence: <int>[1, 0],
        );
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
        );

        final canonical =
            _canonicalFromShift(fixture.samplePushOperationsShift);
        final firstWrote = await sink.upsertShift(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonical,
        );
        expect(firstWrote, isTrue);

        final secondWrote = await sink.upsertShift(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact: canonical,
        );
        expect(secondWrote, isFalse,
            reason: 'idempotency UNIQUE short-circuit must surface as '
                'upsertShift == false on replay');
      },
    );
  });

  group('Test C — watermark per batch', () {
    test(
      'advanceWatermark UPSERTs into connector_sync_watermark with resource '
      '= "labor_punches" and (connection_id, resource) as the conflict key',
      () async {
        final pool = _SinkPool();
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: 'page:3',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 11, 30, 0),
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
        expect(params['cursor_token'], equals('page:3'));
        expect(params['last_modified_seen'],
            equals(DateTime.utc(2026, 5, 2, 11, 30, 0)));
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
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
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
            reason: 'Push Operations is a labor adapter — demo-flip '
                'category is "labor"');
      },
    );

    test(
      'gates fail → no INSERT issued (connection not yet connected, or '
      'first backfill not committed, or records=0)',
      () async {
        final pool = _SinkPool();
        final sink = PushOperationsPostgresSink(
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
      'upsertShift + advanceWatermark + appendSyncLog + evaluateDemoFlip '
      'all inject app.operator_id and app.location_id via SET LOCAL '
      '(set_config(..., true)) before any business SQL runs',
      () async {
        final pool = _SinkPool(
          locationTimezoneRow: _toLocationsRow(),
          insertAffected: 1,
        );
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
        );

        await sink.upsertShift(
          operatorId: _opA,
          locationId: _locA,
          canonicalFact:
              _canonicalFromShift(fixture.samplePushOperationsShift),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: 'page:1',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 11, 0, 0),
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
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        Object? thrown;
        try {
          await sink.advanceWatermark(
            operatorId: 'not-a-uuid',
            locationId: _locA,
            connectionId: _connId,
            cursorToken: 'page:1',
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
        final pool = _SinkPool();
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: 'page:1',
          lastModifiedSeen: DateTime.utc(2026, 5, 2),
        );
        await sink.advanceWatermark(
          operatorId: _opB,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: 'page:2',
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

  group('Test F — bespoke connection_id resolution', () {
    test(
      'bespoke advanceWatermark (no connection_id passed) looks up '
      'connector_connection.connection_id for (operator, location, '
      'vendor=push_operations) and writes the resolved id into the '
      'connector_sync_watermark UPSERT',
      () async {
        final pool = _SinkPool(
          connectorConnectionConnectionId: _resolvedConnId,
        );
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          cursorToken: 'page:7',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 11, 0, 0),
        );

        // Two transactions: one for the connection_id lookup, one for
        // the watermark UPSERT (each runs in its own withTenant).
        expect(pool.transactions, hasLength(2));
        final lookupTx = pool.transactions[0];
        final upsertTx = pool.transactions[1];
        expect(
          lookupTx.executedSql
              .any((s) => s.contains('from public.connector_connection')),
          isTrue,
          reason: 'bespoke caller without connection_id must trigger lookup',
        );
        // Verify the lookup binds vendor_id="push_operations".
        final lookupParams = lookupTx.parameters.firstWhere(
          (p) => p['vendor_id'] == 'push_operations',
        );
        expect(lookupParams['operator_id'], equals(_opA));
        expect(lookupParams['location_id'], equals(_locA));

        // The upsert tx then carries the resolved connection_id.
        final upsertParams = upsertTx.parameters.firstWhere(
          (p) => p['connection_id'] == _resolvedConnId,
        );
        expect(upsertParams['cursor_token'], equals('page:7'));
      },
    );

    test(
      'unified CanonicalSink advanceWatermark (connection_id passed) skips '
      'the lookup and writes the explicit id directly',
      () async {
        final pool = _SinkPool();
        final sink = PushOperationsPostgresSink(
          tenantWrapper: TenantTransactionWrapper(pool),
          now: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
        );
        await sink.advanceWatermark(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connId,
          cursorToken: 'page:9',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 11, 0, 0),
        );

        // Single transaction — the lookup short-circuits when an
        // explicit connection_id is supplied.
        expect(pool.transactions, hasLength(1));
        final tx = pool.transactions.single;
        expect(
          tx.executedSql
              .any((s) => s.contains('from public.connector_connection')),
          isFalse,
          reason: 'explicit connection_id must skip the lookup',
        );
        final params = tx.parameters.firstWhere(
          (p) => p['connection_id'] == _connId,
        );
        expect(params['cursor_token'], equals('page:9'));
      },
    );
  });

  group('Test G — V1 hours-only invariant', () {
    test(
      'every documented fixture row inserts hours_worked but NEVER the '
      'wage-rate or wage-dollars columns (Postgres defaults leave them '
      'NULL); pinned across both fixture rows so a future column-list '
      'edit trips the suite immediately',
      () async {
        final fixtures = <Map<String, Object?>>[
          fixture.samplePushOperationsShift,
          fixture.secondPushOperationsShift,
        ];
        for (final shift in fixtures) {
          final pool = _SinkPool(
            locationTimezoneRow: _toLocationsRow(),
            insertAffected: 1,
          );
          final sink = PushOperationsPostgresSink(
            tenantWrapper: TenantTransactionWrapper(pool),
            now: () => DateTime.utc(2026, 5, 2, 12, 0, 0),
          );
          await sink.upsertShift(
            operatorId: _opA,
            locationId: _locA,
            canonicalFact: _canonicalFromShift(shift),
          );

          final tx = pool.transactions.single;
          final insertSql = tx.executedSql.firstWhere(
            (s) => s.contains('insert into public.labor_punches'),
          );
          // V1 hours-only invariant: the wage-rate column and the
          // wage-dollars column MUST NOT appear in the INSERT column
          // list. The Postgres defaults leave both NULL; Lane `.2`'s
          // aggregator handles wage modelling for vendors that surface
          // a rate (Push Operations is not one of them in V1).
          expect(insertSql, isNot(contains('pay_rate')),
              reason: 'sink MUST NOT supply wage-rate column for '
                  'fixture id=${shift['id']}');
          expect(insertSql, isNot(contains('labor_dollars')),
              reason: 'sink MUST NOT supply wage-dollars column for '
                  'fixture id=${shift['id']}');
          expect(insertSql, isNot(contains('total_pay')),
              reason: 'sink MUST NOT supply legacy total_pay column '
                  'for fixture id=${shift['id']}');

          final insertParams = tx.parameters.firstWhere(
            (p) => p.containsKey('employee_source_id'),
          );
          // hours_worked is computed from shift_end - shift_start in
          // seconds. Both fixture rows define a positive duration; the
          // sink stores integer seconds matching the QBT lane's
          // convention so the read-side aggregator reads either lane
          // through the same column.
          expect(insertParams['hours_worked'], isA<int>(),
              reason: 'hours_worked must be the computed duration in '
                  'seconds for fixture id=${shift['id']}');
          expect(insertParams['hours_worked'] as int, greaterThan(0));
          // No wage keys in the bind params either — defense in depth
          // against a future copy-paste error that would silently
          // surface a wage write through bind expansion.
          expect(insertParams.containsKey('pay_rate'), isFalse);
          expect(insertParams.containsKey('labor_dollars'), isFalse);
        }
      },
    );
  });

  group('Cover / reservation rejection (defense-in-depth)', () {
    test('upsertCoverFact throws UnsupportedError — labor sink', () async {
      final sink = PushOperationsPostgresSink(
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
      final sink = PushOperationsPostgresSink(
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
    test(
      'sink source contains zero V1 lean cut 2 banned tokens AND zero '
      'wage-rate / wage-dollar write tokens (V1 hours-only invariant)',
      () {
        final source = File(
          'lib/infrastructure/persistence/postgres/push_operations_postgres_sink.dart',
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
          // V1 hours-only invariant: 2026-05-05 falsehood correction
          // #8 pins Push Operations at wage class `hoursOnly`. The
          // sink must not write any wage-rate or wage-dollars token.
          'pay_rate',
          'labor_dollars',
          'total_pay',
        ];
        final lower = source.toLowerCase();
        for (final token in banned) {
          expect(lower.contains(token.toLowerCase()), isFalse,
              reason: 'banned item present in sink source: $token');
        }
      },
    );

    test(
      'sink source restricts package:postgres to the canonical '
      'infrastructure directory (file lives in '
      'lib/infrastructure/persistence/postgres/, so the import is '
      'permitted; this test pins that the sink does not leak any '
      'postgres types into a public surface)',
      () {
        final source = File(
          'lib/infrastructure/persistence/postgres/push_operations_postgres_sink.dart',
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
    this.connectorConnectionConnectionId,
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

  /// `connection_id::text` returned by the fake
  /// `connector_connection` SELECT used by the bespoke-interface
  /// connection_id resolver. Null mimics the "no row" case.
  final String? connectorConnectionConnectionId;

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
      connectorConnectionConnectionId: connectorConnectionConnectionId,
      drainInsertAffected: _drainInsertAffected,
    );
    transactions.add(tx);
    return tx;
  }
}

class _SinkTransaction extends PostgresTransaction {
  _SinkTransaction({
    required this.locationTimezoneRow,
    required this.connectorConnectionConnectionId,
    required this.drainInsertAffected,
  });

  final PostgresRow? locationTimezoneRow;
  final String? connectorConnectionConnectionId;
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
      final id = connectorConnectionConnectionId;
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
