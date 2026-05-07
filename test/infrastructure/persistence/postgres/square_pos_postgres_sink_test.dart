// Phase 8 / Wave B `8.spine-bridge.1.SQ` — Square POS Postgres-backed
// canonical sink test suite.
//
// Tests cover the eight contract bindings for `8.spine-bridge.1.SQ`
// (per `docs/contracts/integration_spine_architecture_contract.md`):
//
//   A. Round-trip with the documented Square Order shape: the adapter
//      builds a `SquareCanonicalFact`, the sink converts to the
//      canonical `cover_facts` Map shape and writes one row.
//   B. Idempotency replay: the same canonical fact written twice
//      produces 1 INSERT + 1 conflict-no-op (per the framework
//      migration partial UNIQUE on `(operator_id, vendor_id,
//      vendor_entity_id, vendor_modified_at)`).
//   C. Watermark advance per batch — the sink writes one
//      `connector_sync_watermark` row per `persistWatermark` /
//      `advanceWatermark` call. Resource = `'pos.orders'`.
//   D. Demo-mode flip on first batch with records >= 1; idempotent on
//      second flip.
//   E. RLS + tenancy isolation — every write transaction injects the
//      tenant via `set_config('app.operator_id', ...)`; operator A's
//      write does not surface under operator B's tenant context.
//   F. Existing `square_pos_adapter_test.dart` smoke-runs against this
//      sink: the sink composes cleanly with the adapter via the
//      bespoke `SquarePosFactWriter` + `SquareWatermarkStore`
//      interfaces; running the adapter's `pollIncremental` writes one
//      cover_facts row + one watermark + one demo flip on first batch.
//   G. Covers-null invariant: every cover_facts row written by the
//      sink carries `covers = null` regardless of canonical-fact
//      input (Square's documented Order schema exposes no guest
//      count). Field-access audit pins the sink source against
//      `numberOfGuests` / `guestCount` / `numOfGst` so a future
//      refactor cannot silently regress to a covers-positive shape.
//   H. Banned-items grep across the sink source per
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/square_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/square_pos_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _opB = '22222222-2222-4222-8222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String _connA = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String _connB = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

/// One closed Square Order shaped exactly as the documented
/// SearchOrders response. Used by tests A / B / E / F / G — they all
/// need a closed order so the sink writes a row (still-open orders
/// drop per the file header).
const Map<String, Object?> _sampleClosedOrder = <String, Object?>{
  'id': 'sq_ord_001',
  'location_id': 'L_RESTAURANT_A',
  'created_at': '2026-05-03T17:30:00Z',
  'updated_at': '2026-05-03T18:45:00Z',
  'closed_at': '2026-05-03T18:45:00Z',
  'total_money': <String, Object?>{
    'amount': 4250, // cents → 42.50
    'currency': 'CAD',
  },
  'state': 'COMPLETED',
};

SquareCanonicalFact _factFromOrder(
  Map<String, Object?> order, {
  required String operatorId,
  required String locationId,
  String coversSource = 'forecast_fallback',
}) {
  final amount = (order['total_money'] as Map)['amount'] as int;
  return SquareCanonicalFact(
    operatorId: operatorId,
    locationId: locationId,
    vendorEntityId: order['id'] as String,
    vendorModifiedAt: DateTime.parse(order['updated_at'] as String).toUtc(),
    openedAt: DateTime.parse(order['created_at'] as String).toUtc(),
    closedAt: order['closed_at'] == null
        ? null
        : DateTime.parse(order['closed_at'] as String).toUtc(),
    actualSales: amount / 100.0,
    covers: null,
    coversSource: coversSource,
    vendorPayload: order,
  );
}

void main() {
  group('SquarePosPostgresSink — A. round-trip', () {
    test(
        'writes one cover_facts row from a SquareCanonicalFact with '
        'covers hard-NULLed and covers_source threaded through', () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final fact = _factFromOrder(
        _sampleClosedOrder,
        operatorId: _opA,
        locationId: _locA,
      );

      final inserted = await sink.upsertSalesFact(fact);

      expect(inserted, isTrue);
      expect(pool.coverFacts, hasLength(1));
      final row = pool.coverFacts.values.single;
      expect(row['vendor_id'], 'square');
      expect(row['vendor_entity_id'], 'sq_ord_001');
      expect(row['covers'], isNull,
          reason: 'Square exposes no covers field — sink hard-NULLs it');
      expect(row['covers_source'], 'forecast_fallback',
          reason: 'sink threads adapter-supplied covers_source through');
      expect(row['opened_at'], DateTime.utc(2026, 5, 3, 17, 30, 0));
      expect(row['closed_at'], DateTime.utc(2026, 5, 3, 18, 45, 0));
      expect(row['vendor_modified_at'], DateTime.utc(2026, 5, 3, 18, 45, 0));
      expect((row['actual_sales'] as num).toDouble(), closeTo(42.50, 0.001));
      expect(row['operator_id'], _opA);
      expect(row['location_id'], _locA);

      // raw_payload is JSONB; the fake stores the encoded string so
      // the test asserts on a structural round-trip.
      final rawJson = jsonDecode(row['raw_payload'] as String) as Map<String, Object?>;
      expect(rawJson['id'], 'sq_ord_001');
      expect(rawJson['closed_at'], '2026-05-03T18:45:00Z');
    });

    test(
        'unified upsertCoverFact accepts whatever covers_source the '
        'adapter supplies and still hard-NULLs covers', () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final inserted = await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'sq_ord_xyz',
          'vendor_modified_at': DateTime.utc(2026, 5, 3, 18, 45, 0),
          // Adapter could supply 'reservation_plus_walkin' under Lane
          // `.2`'s logic; sink threads it through.
          'covers_source': 'reservation_plus_walkin',
          // Even if a stray covers value sneaks in, sink hard-NULLs.
          'covers': 7,
          'opened_at': DateTime.utc(2026, 5, 3, 17, 30, 0),
          'closed_at': DateTime.utc(2026, 5, 3, 18, 45, 0),
          'actual_sales': 42.5,
          'raw_payload': const <String, Object?>{'id': 'sq_ord_xyz'},
        },
      );

      expect(inserted, isTrue);
      final row = pool.coverFacts.values.single;
      expect(row['covers'], isNull,
          reason: 'sink hard-NULLs covers regardless of canonical input');
      expect(row['covers_source'], 'reservation_plus_walkin');
    });

    test(
        'still-open Square order (closed_at absent) drops without write — '
        '`cover_facts` represents finalized orders only', () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      final openOrder = Map<String, Object?>.from(_sampleClosedOrder)
        ..remove('closed_at');
      final fact = _factFromOrder(
        openOrder,
        operatorId: _opA,
        locationId: _locA,
      );

      final inserted = await sink.upsertSalesFact(fact);

      expect(inserted, isFalse);
      expect(pool.coverFacts, isEmpty);
    });
  });

  group('SquarePosPostgresSink — B. idempotency replay', () {
    test('same canonical fact upserted twice -> 1 INSERT + 1 conflict-no-op',
        () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
      );
      final fact = _factFromOrder(
        _sampleClosedOrder,
        operatorId: _opA,
        locationId: _locA,
      );

      final firstWrite = await sink.upsertSalesFact(fact);
      final secondWrite = await sink.upsertSalesFact(fact);

      expect(firstWrite, isTrue);
      expect(secondWrite, isFalse, reason: 'conflict-no-op on replay');
      expect(pool.coverFacts, hasLength(1));
    });
  });

  group('SquarePosPostgresSink — C. watermark per batch', () {
    test(
        'persistWatermark (bespoke) writes connector_sync_watermark with '
        'the resolved connection_id and resource = pos.orders', () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.persistWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-after-batch-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 3, 18, 45, 0),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['connection_id'], _connA);
      expect(wm['resource'], squareWatermarkResource);
      expect(wm['cursor_token'], 'cursor-after-batch-1');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 3, 18, 45, 0));
    });

    test(
        'advanceWatermark (unified) accepts an explicit connection_id and '
        'writes the same UPSERT shape as the bespoke path', () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.advanceWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-from-dispatcher',
        lastModifiedSeen: DateTime.utc(2026, 5, 3, 18, 45, 0),
        connectionId: _connB,
      );

      final wm = pool.watermarks.values.single;
      expect(wm['connection_id'], _connB,
          reason: 'explicit connection_id wins over lookup');
      expect(wm['resource'], squareWatermarkResource);
      expect(wm['cursor_token'], 'cursor-from-dispatcher');
    });

    test(
        'second persistWatermark on the same connection updates in place '
        '(per the connector_sync_watermark UNIQUE on (connection_id, '
        'resource))', () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      await sink.persistWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 3, 18, 45, 0),
      );
      await sink.persistWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: null, // null cursor → end-of-pagination
        lastModifiedSeen: DateTime.utc(2026, 5, 3, 19, 0, 0),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['cursor_token'], isNull,
          reason: 'bespoke surface threads null cursor through unchanged');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 3, 19, 0, 0));
    });
  });

  group('SquarePosPostgresSink — D. demo-mode flip', () {
    test(
        'first batch with records >= 1 flips demo_mode_state.is_demo to false',
        () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
      final fact = _factFromOrder(
        _sampleClosedOrder,
        operatorId: _opA,
        locationId: _locA,
      );

      await sink.upsertSalesFact(fact);
      // persistWatermark drains the per-tenant pending counter and
      // auto-evaluates the flip — see the sink file header.
      await sink.persistWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: null,
        lastModifiedSeen: DateTime.utc(2026, 5, 3, 18, 45, 0),
      );

      expect(pool.demoModeState, hasLength(1));
      final flip = pool.demoModeState.values.single;
      expect(flip['is_demo'], isFalse);
      expect(flip['flipped_to_live_at'], DateTime.utc(2026, 5, 4, 12, 0, 0));
      expect(flip['flipped_by_connection_id'], _connA);
      expect(flip['category'], 'pos');
    });

    test(
        'second flip is idempotent: flipped_to_live_at + connection_id '
        'are preserved', () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      var clockTick = 0;
      DateTime tickingClock() {
        clockTick += 1;
        return DateTime.utc(2026, 5, 4, 12, clockTick, 0);
      }

      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: tickingClock,
      );

      // First flip.
      await sink.evaluateDemoFlip(
        operatorId: _opA,
        locationId: _locA,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 3,
        connectionId: _connA,
      );
      final firstFlip = pool.demoModeState.values.single;
      final firstFlippedAt = firstFlip['flipped_to_live_at'];
      final firstConn = firstFlip['flipped_by_connection_id'];

      // Second flip — pretend a new connection tries to re-flip.
      await sink.evaluateDemoFlip(
        operatorId: _opA,
        locationId: _locA,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 5,
        connectionId: _connB,
      );

      expect(pool.demoModeState, hasLength(1));
      final secondFlip = pool.demoModeState.values.single;
      expect(secondFlip['is_demo'], isFalse);
      expect(secondFlip['flipped_to_live_at'], firstFlippedAt,
          reason: 'flipped_to_live_at must not be re-stamped');
      expect(secondFlip['flipped_by_connection_id'], firstConn,
          reason: 'flipped_by_connection_id must not be overwritten');
    });

    test('gates fail (status / first-backfill / records=0) → no INSERT issued',
        () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      await sink.evaluateDemoFlip(
        operatorId: _opA,
        locationId: _locA,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.disconnected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 5,
        connectionId: _connA,
      );
      await sink.evaluateDemoFlip(
        operatorId: _opA,
        locationId: _locA,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: false,
        backfillRecordsWritten: 5,
        connectionId: _connA,
      );
      await sink.evaluateDemoFlip(
        operatorId: _opA,
        locationId: _locA,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 0,
        connectionId: _connA,
      );

      expect(pool.demoModeState, isEmpty,
          reason: 'gate failures must short-circuit BEFORE any flip insert');
    });
  });

  group('SquarePosPostgresSink — E. RLS + tenancy isolation', () {
    test('every write transaction injects app.operator_id via set_config',
        () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      final fact = _factFromOrder(
        _sampleClosedOrder,
        operatorId: _opA,
        locationId: _locA,
      );
      await sink.upsertSalesFact(fact);

      expect(pool.transactions, isNotEmpty);
      for (final tx in pool.transactions) {
        expect(tx.setConfigCalls['app.operator_id'], _opA,
            reason: 'tenant SET LOCAL must run on every transaction');
        expect(tx.setConfigCalls['app.location_id'], _locA);
        expect(tx.committed, isTrue);
      }
    });

    test(
        'operator A cover_facts row does not surface under operator B '
        'tenant context (the fake uses operator_id as the row key)',
        () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedLocation(operatorId: _opB, locationId: _locB)
        ..seedConnection(operatorId: _opB, locationId: _locB, connectionId: _connB);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      final factA = _factFromOrder(
        _sampleClosedOrder,
        operatorId: _opA,
        locationId: _locA,
      );
      await sink.upsertSalesFact(factA);

      // Operator B side: the same vendor_entity_id +
      // vendor_modified_at should not collide with operator A's row
      // because the UNIQUE includes operator_id. Simulate by writing
      // the same canonical fact under operator B and asserting both
      // rows coexist with distinct operator_ids.
      final factB = _factFromOrder(
        _sampleClosedOrder,
        operatorId: _opB,
        locationId: _locB,
      );
      await sink.upsertSalesFact(factB);

      expect(pool.coverFacts, hasLength(2));
      final operatorIds = pool.coverFacts.values
          .map((row) => row['operator_id'] as String)
          .toSet();
      expect(operatorIds, <String>{_opA, _opB});
    });
  });

  group('SquarePosPostgresSink — F. adapter smoke', () {
    test(
        'SQ adapter pollIncremental composes with the postgres sink: '
        'one batch -> 1 cover_facts row + 1 watermark + 1 demo flip',
        () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
      final apiClient = _FakeSquareApiClient(
        searchPages: <SquareSearchOrdersResponse>[
          SquareSearchOrdersResponse(
            orders: <Map<String, Object?>>[
              Map<String, Object?>.from(_sampleClosedOrder),
            ],
            cursor: null,
          ),
        ],
      );
      final adapter = SquarePosAdapter(
        apiClient: apiClient,
        factWriter: sink,
        watermarkStore: sink,
        notificationUrlForConnection: ({
          required String operatorId,
          required String locationId,
        }) async =>
            'https://example.invalid/sq',
        now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      Future<bool> alwaysAllow({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async =>
          true;

      final result = await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: 'usr_owner',
          vendorId: 'square',
          lastModifiedSeen: DateTime.utc(2026, 5, 3),
          sanityHook: alwaysAllow,
        ),
      );

      expect(result.recordsWritten, 1);
      expect(pool.coverFacts, hasLength(1));
      expect(pool.watermarks, hasLength(1));
      expect(pool.demoModeState, hasLength(1));
      expect(pool.demoModeState.values.single['is_demo'], isFalse);
    });
  });

  group('SquarePosPostgresSink — G. covers-null invariant + field audit', () {
    test(
        'every cover_facts row written by the sink carries covers = null, '
        'regardless of canonical-fact input', () async {
      final pool = _FakeSquarePool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = SquarePosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      // Path 1: bespoke upsertSalesFact with the typed fact.
      final fact = _factFromOrder(
        _sampleClosedOrder,
        operatorId: _opA,
        locationId: _locA,
      );
      await sink.upsertSalesFact(fact);

      // Path 2: unified upsertCoverFact with a stray covers=42 in the
      // map. The sink MUST hard-NULL it.
      await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: <String, Object?>{
          'vendor_id': 'square',
          'vendor_entity_id': 'sq_ord_002',
          'vendor_modified_at': DateTime.utc(2026, 5, 3, 19, 30, 0),
          'covers': 42, // sneaks in via misuse — sink must NULL it
          'covers_source': 'manual_fallback',
          'opened_at': DateTime.utc(2026, 5, 3, 19, 0, 0),
          'closed_at': DateTime.utc(2026, 5, 3, 19, 30, 0),
          'actual_sales': 19.0,
          'raw_payload': const <String, Object?>{'id': 'sq_ord_002'},
        },
      );

      expect(pool.coverFacts, hasLength(2));
      for (final row in pool.coverFacts.values) {
        expect(row['covers'], isNull,
            reason: 'covers-null invariant — Square exposes no guest count');
      }
    });

    test(
        'sink source contains zero references to numberOfGuests / '
        'guestCount / numOfGst as field-access tokens', () async {
      final source = await File(
        'lib/infrastructure/persistence/postgres/square_pos_postgres_sink.dart',
      ).readAsString();
      // The Square Order schema exposes no guest-count field; this
      // pin prevents a future refactor from silently regressing the
      // covers-null invariant by reaching for a non-existent field.
      // The forbidden tokens are the field-access shapes
      // `numberOfGuests` / `guestCount` / `numOfGst` (and the
      // bracket-quoted form `['guestCount']`). Plain text mentions
      // (e.g. doc comments) are allowed; field-access tokens are not.
      expect(
        RegExp(r"['\.\[]numberOfGuests").hasMatch(source),
        isFalse,
        reason: 'numberOfGuests must not appear as a field-access token',
      );
      expect(
        RegExp(r"['\.\[]guestCount").hasMatch(source),
        isFalse,
        reason: 'guestCount must not appear as a field-access token',
      );
      expect(
        RegExp(r"['\.\[]numOfGst").hasMatch(source),
        isFalse,
        reason: 'numOfGst (Gen1 OR field) must not appear in Square sink',
      );
    });
  });

  group('SquarePosPostgresSink — H. banned-items grep', () {
    test('sink source contains zero V1 lean cut 2 banned items', () async {
      final source = await File(
        'lib/infrastructure/persistence/postgres/square_pos_postgres_sink.dart',
      ).readAsString();

      const banned = <String>[
        'KMS',
        'pgp_sym_encrypt_kms',
        'rotateSigningKey',
        'parse_warnings',
        'parse_partial',
        'kStrictReplayFiveMinute',
        'pg_try_advisory_lock',
        'pg_advisory_lock',
        'sigtermDrainHandler',
        'inboundWebhookDLQTile',
        'raw_payload_partition',
        'pg_partman_raw',
      ];

      for (final token in banned) {
        expect(
          source.toLowerCase().contains(token.toLowerCase()),
          isFalse,
          reason: 'banned item present in sink source: $token',
        );
      }
    });
  });
}

// ─── Test doubles ────────────────────────────────────────────────────

class _FakeSquareApiClient implements SquareApiClient {
  _FakeSquareApiClient({
    List<SquareSearchOrdersResponse>? searchPages,
    List<Map<String, Object?>>? locations,
  })  : searchPages = searchPages ?? <SquareSearchOrdersResponse>[],
        _locations = locations ??
            <Map<String, Object?>>[
              <String, Object?>{
                'id': 'L_RESTAURANT_A',
                'name': 'Restaurant A',
                'timezone': 'America/Toronto',
                'currency': 'CAD',
              },
            ];

  final List<SquareSearchOrdersResponse> searchPages;
  final List<Map<String, Object?>> _locations;
  int _idx = 0;

  @override
  Future<SquareSearchOrdersResponse> searchOrders({
    required SquareCredentialHandle credential,
    required DateTime updatedAtMin,
    required DateTime updatedAtMax,
    required List<String> locationIds,
    String? cursor,
    int pageSize = 200,
  }) async {
    if (_idx >= searchPages.length) {
      return const SquareSearchOrdersResponse(
        orders: <Map<String, Object?>>[],
      );
    }
    return searchPages[_idx++];
  }

  @override
  Future<Map<String, Object?>> retrieveOrder({
    required SquareCredentialHandle credential,
    required String orderId,
    required String squareLocationId,
  }) async =>
      const <String, Object?>{};

  @override
  Future<List<Map<String, Object?>>> listLocations({
    required SquareCredentialHandle credential,
  }) async =>
      _locations;

  @override
  Future<SquareOauthTokens> refreshOauthToken({
    required String refreshToken,
  }) async =>
      SquareOauthTokens(
        accessToken: 'tok',
        refreshToken: 'refr',
        expiresAt: DateTime.utc(2099, 1, 1),
        merchantId: 'M_TEST',
      );

  @override
  Future<String> registerWebhook({
    required SquareCredentialHandle credential,
    required String notificationUrl,
    required List<String> events,
  }) async =>
      'sub_test';

  @override
  Future<void> unregisterWebhook({
    required SquareCredentialHandle credential,
    required String subscriptionId,
  }) async {}

  @override
  Future<void> revokeOauth({
    required SquareCredentialHandle credential,
  }) async {}
}

class _FakeSquarePool implements PostgresPool {
  /// Keyed by `(operator_id, location_id)`.
  final Map<String, Map<String, Object?>> _locations =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id, vendor_id)`.
  final Map<String, String> _connectionsByTenant = <String, String>{};

  /// Keyed by the canonical UNIQUE
  /// `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`.
  final Map<String, Map<String, Object?>> coverFacts =
      <String, Map<String, Object?>>{};

  /// Keyed by `(connection_id, resource)`.
  final Map<String, Map<String, Object?>> watermarks =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id, category)`.
  final Map<String, Map<String, Object?>> demoModeState =
      <String, Map<String, Object?>>{};

  final List<_FakeTransaction> transactions = <_FakeTransaction>[];

  void seedLocation({required String operatorId, required String locationId}) {
    _locations['$operatorId|$locationId'] = <String, Object?>{
      'timezone': 'America/Toronto',
      'business_day_rollover_hour': 4,
    };
  }

  void seedConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    _connectionsByTenant['$operatorId|$locationId|square'] = connectionId;
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction(this.pool);

  final _FakeSquarePool pool;
  final Map<String, String> setConfigCalls = <String, String>{};
  bool committed = false;

  void _captureSetConfig(String sql, PostgresParameters parameters) {
    final regex = RegExp(r"set_config\('(?<name>[a-zA-Z0-9_.]+)'");
    final match = regex.firstMatch(sql);
    if (match == null) return;
    final name = match.namedGroup('name')!;
    final value = parameters['value'];
    if (value is String) {
      setConfigCalls[name] = value;
    }
  }

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) {
      _captureSetConfig(sql, parameters);
      return const <PostgresRow>[];
    }
    if (sql.contains(
        'select timezone, business_day_rollover_hour from public.locations')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final row = pool._locations['$operatorId|$locationId'];
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'timezone': row['timezone'],
          'business_day_rollover_hour': row['business_day_rollover_hour'],
        },
      ];
    }
    if (sql.contains(
        'select connection_id::text as connection_id from public.connector_connection')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final connId =
          pool._connectionsByTenant['$operatorId|$locationId|$vendorId'];
      if (connId == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'connection_id': connId},
      ];
    }
    if (sql.contains('from public.demo_mode_state') &&
        sql.contains('for update')) {
      // A2 fix: SELECT FOR UPDATE on demo_mode_state — used by the
      // watermark advance to read the pending counter before flipping.
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      final row = pool.demoModeState[key];
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'pending_inserts_count': row['pending_inserts_count'] ?? 0,
          'is_demo': row['is_demo'] ?? true,
        },
      ];
    }
    if (sql.contains('insert into public.cover_facts')) {
      final operatorId = parameters['operator_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final vendorEntityId = parameters['vendor_entity_id'] as String;
      final vendorModifiedAt = parameters['vendor_modified_at'] as DateTime;
      final key = '$operatorId|$vendorId|$vendorEntityId|'
          '${vendorModifiedAt.toIso8601String()}';
      if (pool.coverFacts.containsKey(key)) {
        // Idempotency UNIQUE collapses → conflict-no-op → empty
        // RETURNING.
        return const <PostgresRow>[];
      }
      pool.coverFacts[key] = <String, Object?>{
        'operator_id': operatorId,
        'location_id': parameters['location_id'],
        'vendor_id': vendorId,
        'vendor_entity_id': vendorEntityId,
        'vendor_modified_at': vendorModifiedAt,
        // The sink hard-NULLs covers; capture the bound value so the
        // G test can read it back and assert null.
        'covers': parameters['covers'],
        'covers_source': parameters['covers_source'],
        'opened_at': parameters['opened_at'],
        'closed_at': parameters['closed_at'],
        'business_date': parameters['business_date'],
        'actual_sales': parameters['actual_sales'],
        'raw_payload': parameters['raw_payload'],
      };
      return <PostgresRow>[
        <String, Object?>{'inserted': 1},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) {
      _captureSetConfig(sql, parameters);
      return 0;
    }
    if (sql.contains('insert into public.connector_sync_watermark')) {
      final connectionId = parameters['connection_id'] as String;
      final resource = parameters['resource'] as String;
      final key = '$connectionId|$resource';
      pool.watermarks[key] = <String, Object?>{
        'operator_id': parameters['operator_id'],
        'location_id': parameters['location_id'],
        'connection_id': connectionId,
        'resource': resource,
        'cursor_token': parameters['cursor_token'],
        'last_modified_seen': parameters['last_modified_seen'],
        'last_synced_at': parameters['last_synced_at'],
        'updated_at': parameters['updated_at'],
      };
      return 1;
    }
    if (sql.contains('insert into public.connector_sync_log')) {
      // Append-only; no materialization needed for this slice.
      return 1;
    }
    if (sql.contains('insert into public.demo_mode_state')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      // A2 fix: ON CONFLICT DO UPDATE increments pending_inserts_count.
      if (pool.demoModeState.containsKey(key)) {
        // ON CONFLICT DO UPDATE SET pending_inserts_count = pending_inserts_count + 1
        final existing = pool.demoModeState[key]!;
        existing['pending_inserts_count'] =
            (existing['pending_inserts_count'] as int? ?? 0) + 1;
      } else {
        pool.demoModeState[key] = <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': category,
          'is_demo': true,
          'pending_inserts_count': 1,
          'flipped_to_live_at': null,
          'flipped_by_connection_id': null,
        };
      }
      return 1;
    }
    if (sql.contains('update public.demo_mode_state')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      final row = pool.demoModeState[key];
      if (row == null) return 0;
      // The SQL narrows by `is_demo = true`; idempotent re-flip when
      // already false.
      if (row['is_demo'] == false) return 0;
      row['is_demo'] = false;
      row['flipped_to_live_at'] = parameters['now'];
      row['flipped_by_connection_id'] = parameters['connection_id'];
      row['pending_inserts_count'] = 0;
      return 1;
    }
    if (sql.contains('update public.vendor_credentials')) {
      // No-op for these tests; the wipe path returns true regardless
      // of affected-row count.
      return 0;
    }
    if (sql.contains('update public.connector_connection')) {
      return 1;
    }
    return 0;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {}
}
