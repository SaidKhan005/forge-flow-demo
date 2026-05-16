// Phase 8 / Wave B `8.spine-bridge.1.CL` — Clover POS Postgres-backed
// canonical sink test suite.
//
// Tests cover the eight contract bindings for `8.spine-bridge.1.CL`
// (per `docs/contracts/integration_spine_architecture_contract.md`):
//
//   A. Round-trip: a [CloverCanonicalSalesFact] from
//      `sampleCloverOrder` writes one `cover_facts` row whose mapped
//      columns match the canonical shape; covers stays NULL.
//   B. Idempotency replay: the same canonical fact written twice
//      produces 1 INSERT + 1 conflict-no-op (per the framework
//      migration partial UNIQUE on
//      `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`).
//   C. Watermark advance per batch — the sink writes one
//      `connector_sync_watermark` row per `advanceWatermark` /
//      `persist` call with `resource = 'pos.orders'`.
//   D. Demo-mode flip on first batch with records >= 1; idempotent on
//      second flip.
//   E. RLS + tenancy isolation — every write transaction injects the
//      tenant via `set_config('app.operator_id', ...)`; operator A's
//      write does not surface under operator B's tenant context.
//   F. Existing `clover_pos_adapter_test.dart` smoke-runs against this
//      sink: the sink composes cleanly with the adapter via the
//      bespoke `CloverTenantFactWriter` + `CloverWatermarkStore`
//      interfaces; running the adapter's pollIncremental writes one
//      cover_facts row + one watermark + one demo flip on first batch.
//   G. Covers-null invariant: every fixture round-trip carries
//      `covers = null`; sink stores NULL without throwing; banned-grep
//      confirms no `numberOfGuests` / `guestCount` / `guests`
//      field-access tokens leaked into the sink source.
//   H. Banned-items grep across the sink source per
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/clover_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/clover_pos_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/pos/fixtures/clover_orders_fixture.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _opB = '22222222-2222-4222-8222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String _connA = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String _connB = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

CloverCanonicalSalesFact _factFromSample() {
  final opened = DateTime.fromMillisecondsSinceEpoch(
    sampleCloverOrder['createdTime']! as int,
    isUtc: true,
  );
  final modified = DateTime.fromMillisecondsSinceEpoch(
    sampleCloverOrder['modifiedTime']! as int,
    isUtc: true,
  );
  return CloverCanonicalSalesFact(
    vendorEntityId: sampleCloverOrder['id']! as String,
    openedAt: opened,
    closedAt: modified,
    actualSalesDollars: (sampleCloverOrder['total']! as int) / 100.0,
    vendorModifiedAt: modified,
    businessDate: DateTime.utc(opened.year, opened.month, opened.day),
  );
}

void main() {
  group('CloverPostgresSink — A. round-trip', () {
    test('writeSalesFact lands one cover_facts row with covers null + '
        'covers_source forecast_fallback', () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.writeSalesFact(
        operatorId: _opA,
        locationId: _locA,
        fact: _factFromSample(),
      );

      expect(pool.coverFacts, hasLength(1));
      final row = pool.coverFacts.values.single;
      expect(row['vendor_id'], 'clover');
      expect(row['vendor_entity_id'], 'CLV-ORDER-7HXJ-2026-05-02-001');
      expect(row['covers'], isNull,
          reason: 'Clover never exposes a covers field — sink writes NULL');
      expect(row['covers_source'], 'forecast_fallback');
      expect(row['opened_at'], DateTime.utc(2026, 5, 2, 18, 45, 0));
      expect(row['closed_at'], DateTime.utc(2026, 5, 2, 19, 43, 0));
      expect(row['vendor_modified_at'], DateTime.utc(2026, 5, 2, 19, 43, 0));
      expect((row['actual_sales'] as num).toDouble(), closeTo(31.40, 0.001));
      expect(row['operator_id'], _opA);
      expect(row['location_id'], _locA);

      // raw_payload is JSONB; the bespoke writer ships an empty object
      // (the adapter does not currently route the source order through
      // the sink). Round-trip parse to assert it stayed JSON.
      final rawJson = jsonDecode(row['raw_payload'] as String) as Map<String, Object?>;
      expect(rawJson, isEmpty);
    });

    test('upsertCoverFact accepts the unified Map shape and lands a row',
        () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final inserted = await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: <String, Object?>{
          'vendor_id': 'clover',
          'vendor_entity_id': 'CLV-ORDER-DICT-A',
          'opened_at': DateTime.utc(2026, 5, 2, 18, 45),
          'closed_at': DateTime.utc(2026, 5, 2, 19, 43),
          'vendor_modified_at': DateTime.utc(2026, 5, 2, 19, 43),
          'actual_sales': 31.40,
          'covers': null,
          'covers_source': 'forecast_fallback',
          'raw_payload': const <String, Object?>{'state': 'paid'},
        },
      );

      expect(inserted, isTrue);
      expect(pool.coverFacts, hasLength(1));
      expect(pool.coverFacts.values.single['vendor_id'], 'clover');
      expect(pool.coverFacts.values.single['covers'], isNull);
    });

    test('upsertCoverFact with closed_at null short-circuits to no-op',
        () async {
      // Clover orders that have not reached state == 'paid' arrive with
      // closed_at = null. The sink declines the write so only
      // order-finalized rows land — mirrors the OR sink invariant.
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(
        TenantTransactionWrapper(pool),
      );

      final inserted = await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: <String, Object?>{
          'vendor_id': 'clover',
          'vendor_entity_id': 'CLV-ORDER-OPEN',
          'opened_at': DateTime.utc(2026, 5, 2, 18, 45),
          'closed_at': null,
          'vendor_modified_at': DateTime.utc(2026, 5, 2, 19, 43),
          'actual_sales': 0.0,
          'covers': null,
          'covers_source': 'forecast_fallback',
        },
      );

      expect(inserted, isFalse);
      expect(pool.coverFacts, isEmpty);
    });
  });

  group('CloverPostgresSink — B. idempotency replay', () {
    test('same canonical fact upserted twice -> 1 INSERT + 1 conflict-no-op',
        () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(TenantTransactionWrapper(pool));
      final fact = _factFromSample();

      await sink.writeSalesFact(
        operatorId: _opA,
        locationId: _locA,
        fact: fact,
      );
      await sink.writeSalesFact(
        operatorId: _opA,
        locationId: _locA,
        fact: fact,
      );

      expect(pool.coverFacts, hasLength(1),
          reason: 'second write collapses on the framework UNIQUE');
    });
  });

  group('CloverPostgresSink — C. watermark per batch', () {
    test('persist writes connector_sync_watermark with resource = pos.orders',
        () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.persist(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-after-batch-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 43, 0),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['connection_id'], _connA);
      expect(wm['resource'], cloverWatermarkResource);
      expect(wm['resource'], 'pos.orders',
          reason: 'Clover lane lands on pos.orders, NOT pos.guest_checks');
      expect(wm['cursor_token'], 'cursor-after-batch-1');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 2, 19, 43, 0));
    });

    test('second persist on the same connection updates in place', () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(TenantTransactionWrapper(pool));

      await sink.persist(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 43, 0),
      );
      await sink.persist(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-2',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 20, 12, 0),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['cursor_token'], 'cursor-2');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 2, 20, 12, 0));
    });

    test('advanceWatermark with explicit connection_id wins over lookup',
        () async {
      // Unified-interface callers (the sync worker dispatcher) carry
      // the connection_id; the sink uses it directly without looking up
      // connector_connection. Mirrors OR sink behaviour.
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(TenantTransactionWrapper(pool));

      await sink.advanceWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-explicit',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 43, 0),
        connectionId: _connB,
      );

      expect(pool.watermarks.values.single['connection_id'], _connB);
    });
  });

  group('CloverPostgresSink — D. demo-mode flip', () {
    test('first batch with records >= 1 flips demo_mode_state.is_demo to false',
        () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.writeSalesFact(
        operatorId: _opA,
        locationId: _locA,
        fact: _factFromSample(),
      );
      await sink.persist(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: '',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 43, 0),
      );

      expect(pool.demoModeState, hasLength(1));
      final flip = pool.demoModeState.values.single;
      expect(flip['is_demo'], isFalse);
      expect(flip['flipped_to_live_at'], DateTime.utc(2026, 5, 4, 12, 0, 0));
      expect(flip['flipped_by_connection_id'], _connA);
      expect(flip['category'], 'pos');
    });

    test('second flip is idempotent: flipped_to_live_at + connection_id '
        'are preserved', () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      var clockTick = 0;
      DateTime tickingClock() {
        clockTick += 1;
        return DateTime.utc(2026, 5, 4, 12, clockTick, 0);
      }

      final sink = CloverPostgresSink(
        TenantTransactionWrapper(pool),
        clock: tickingClock,
      );

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

    test('disconnected connection status does not flip', () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(TenantTransactionWrapper(pool));

      await sink.evaluateDemoFlip(
        operatorId: _opA,
        locationId: _locA,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.disconnected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: 5,
        connectionId: _connA,
      );

      expect(pool.demoModeState, isEmpty);
    });
  });

  group('CloverPostgresSink — E. RLS + tenancy isolation', () {
    test('every write transaction injects app.operator_id via set_config',
        () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(TenantTransactionWrapper(pool));

      await sink.writeSalesFact(
        operatorId: _opA,
        locationId: _locA,
        fact: _factFromSample(),
      );

      expect(pool.transactions, isNotEmpty);
      for (final tx in pool.transactions) {
        expect(tx.setConfigCalls['app.operator_id'], _opA,
            reason: 'tenant SET LOCAL must run on every transaction');
        expect(tx.setConfigCalls['app.location_id'], _locA);
        expect(tx.committed, isTrue);
      }
    });

    test('operator A cover_facts row does not surface under operator B '
        'tenant context (the fake uses operator_id as the row key)',
        () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedLocation(operatorId: _opB, locationId: _locB)
        ..seedConnection(operatorId: _opB, locationId: _locB, connectionId: _connB);
      final sink = CloverPostgresSink(TenantTransactionWrapper(pool));
      final fact = _factFromSample();

      await sink.writeSalesFact(
        operatorId: _opA,
        locationId: _locA,
        fact: fact,
      );
      await sink.writeSalesFact(
        operatorId: _opB,
        locationId: _locB,
        fact: fact,
      );

      expect(pool.coverFacts, hasLength(2));
      final operatorIds = pool.coverFacts.values
          .map((row) => row['operator_id'] as String)
          .toSet();
      expect(operatorIds, <String>{_opA, _opB});
    });

    test('wipeCredentialsPreserveWatermark preserves connector_sync_watermark',
        () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.persist(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-pre-disconnect',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 43, 0),
      );
      expect(pool.watermarks, hasLength(1));

      final outcome = await sink.wipeCredentialsPreserveWatermark(
        operatorId: _opA,
        locationId: _locA,
      );

      expect(outcome.credentialsWiped, isTrue);
      expect(outcome.watermarkPreserved, isTrue);
      expect(pool.watermarks, hasLength(1),
          reason: 'watermark rows must survive disconnect for resume');
      expect(pool.watermarks.values.single['cursor_token'],
          'cursor-pre-disconnect');
    });
  });

  group('CloverPostgresSink — F. adapter smoke', () {
    test('CloverPosAdapter.pollIncremental composes with the postgres sink: '
        'one batch -> 1 cover_facts row + 1 watermark + 1 demo flip',
        () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
      final api = _FakeCloverApiClient(
        pages: <CloverOrdersPage>[
          const CloverOrdersPage(
            elements: <Map<String, Object?>>[sampleCloverOrder],
            nextOffset: null,
          ),
        ],
      );
      final adapter = CloverPosAdapter(
        api: api,
        factWriter: sink,
        watermarkStore: sink,
        webhookRegistry: _StubWebhookRegistry(),
        credentials: _StubCredentialStore(merchantId: fixtureMerchantId),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
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
          vendorId: 'clover',
          lastModifiedSeen: DateTime.utc(2026, 5, 1),
          sanityHook: alwaysAllow,
        ),
      );

      expect(result.recordsWritten, 1);
      expect(pool.coverFacts, hasLength(1));
      expect(pool.coverFacts.values.single['covers'], isNull);
      expect(pool.coverFacts.values.single['covers_source'],
          'forecast_fallback');
      expect(pool.watermarks, hasLength(1));
      expect(pool.watermarks.values.single['resource'], 'pos.orders');
      expect(pool.demoModeState, hasLength(1));
      expect(pool.demoModeState.values.single['is_demo'], isFalse);
    });
  });

  group('CloverPostgresSink — G. covers-null invariant', () {
    test('even when a Map dict supplies a non-null covers value, the sink '
        'persists NULL — Clover does not expose the field', () async {
      final pool = _FakeCloverPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = CloverPostgresSink(TenantTransactionWrapper(pool));

      await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: <String, Object?>{
          'vendor_id': 'clover',
          'vendor_entity_id': 'CLV-ORDER-LEAK-A',
          'opened_at': DateTime.utc(2026, 5, 2, 18, 45),
          'closed_at': DateTime.utc(2026, 5, 2, 19, 43),
          'vendor_modified_at': DateTime.utc(2026, 5, 2, 19, 43),
          'actual_sales': 31.40,
          // Hypothetical leak — a future caller passes a non-null
          // covers value. The sink MUST coerce to NULL because Clover
          // never exposes the field; trusting the dict would silently
          // misrepresent forecast data as direct.
          'covers': 5,
          'covers_source': 'forecast_fallback',
        },
      );

      expect(pool.coverFacts, hasLength(1));
      expect(pool.coverFacts.values.single['covers'], isNull,
          reason: 'sink coerces covers to NULL for the Clover lane');
    });

    test('sink source contains no guest-count field-access tokens',
        () async {
      final source = await File(
        'lib/infrastructure/persistence/postgres/clover_pos_postgres_sink.dart',
      ).readAsString();
      // The Dining App private schema is not reachable via the public
      // REST API; any reference to a guest-count field path would
      // imply the sink reads one. Pin the absence so a future refactor
      // cannot silently re-introduce the falsehood.
      expect(source.contains('numberOfGuests'), isFalse,
          reason: 'numberOfGuests must not appear in sink source');
      expect(source.contains('guestCount'), isFalse,
          reason: 'guestCount must not appear in sink source');
      expect(source.contains("'guests'"), isFalse,
          reason: "'guests' field-access token must not appear in sink source");
    });
  });

  group('CloverPostgresSink — H. banned-items grep', () {
    test('sink source contains zero V1 lean cut 2 banned items', () async {
      final source = await File(
        'lib/infrastructure/persistence/postgres/clover_pos_postgres_sink.dart',
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

  // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): static-source
  // regression — sink no longer reads `business_day_rollover_hour`.
  // Mirrors the I.4 group in square_pos_postgres_sink_test (Slice 7b.1).
  // Behavioural tests (I.1–I.3) live in the POS exemplar
  // aloha_ncr_voyix_pos_postgres_sink_test (Slice 7b.2 POS exemplar);
  // the inline-pattern shape is identical, so the static check is the
  // load-bearing per-sink regression here.
  group(
      'CloverPostgresSink — I. Per-Daypart V1 Slice 7b business_date '
      'projection via canonical timing chain (Gap 47 static)', () {
    test(
      'I.4 sink source contains zero references to '
      'business_day_rollover_hour as live code',
      () async {
        final source = await File(
          'lib/infrastructure/persistence/postgres/clover_pos_postgres_sink.dart',
        ).readAsString();
        final executableLines = source
            .split('\n')
            .where((line) {
              final trimmed = line.trimLeft();
              return !trimmed.startsWith('//') && !trimmed.startsWith('*');
            })
            .join('\n');
        expect(
          executableLines.contains('business_day_rollover_hour'),
          isFalse,
          reason: 'business_day_rollover_hour must not appear as live '
              'code in the Clover sink — Per-Daypart V1 Slice 7b option (b).',
        );
      },
    );
  });
}

// ─── Test doubles ────────────────────────────────────────────────────

class _FakeCloverPool implements PostgresPool {
  /// Keyed by `(operator_id, location_id)`.
  final Map<String, Map<String, Object?>> _locations =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id, vendor_id)`.
  final Map<String, String> _connectionsByTenant = <String, String>{};

  /// Keyed by the NEW canonical UNIQUE
  /// `(operator_id, location_id, vendor_id, vendor_entity_id)`.
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
    _connectionsByTenant['$operatorId|$locationId|clover'] = connectionId;
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

  final _FakeCloverPool pool;
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
    // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): the projector's
    // BusinessTimingProfilesRepository SELECT joins `from public.locations`
    // inside a CTE, so the projector handler MUST run BEFORE the
    // generic `from public.locations` handler.
    if (sql.contains('from public.business_timing_profiles p')) {
      // Returning empty triggers the projector's `'04:00'` fallback,
      // which projects identically to the legacy
      // `(timezone='America/Toronto', business_day_rollover_hour=4)`
      // path — preserving every existing A–H assertion.
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.locations')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final row = pool._locations['$operatorId|$locationId'];
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'timezone': row['timezone'],
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
    if (sql.contains('from public.demo_mode_state')) {
      // SELECT FOR UPDATE on demo_mode_state — used by the
      // watermark advance to read the pending counter before flipping.
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String? ?? 'pos';
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
      final locationId = parameters['location_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final vendorEntityId = parameters['vendor_entity_id'] as String;
      final vendorModifiedAt = parameters['vendor_modified_at'] as DateTime;
      final key = '$operatorId|$locationId|$vendorId|$vendorEntityId';

      final existing = pool.coverFacts[key];
      if (existing == null) {
        pool.coverFacts[key] = <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'vendor_entity_id': vendorEntityId,
          'vendor_modified_at': vendorModifiedAt,
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
      final storedModified = existing['vendor_modified_at'] as DateTime;
      if (vendorModifiedAt.compareTo(storedModified) >= 0) {
        existing['vendor_modified_at'] = vendorModifiedAt;
        existing['covers'] = parameters['covers'];
        existing['covers_source'] = parameters['covers_source'];
        existing['opened_at'] = parameters['opened_at'];
        existing['closed_at'] = parameters['closed_at'];
        existing['business_date'] = parameters['business_date'];
        existing['actual_sales'] = parameters['actual_sales'];
        existing['raw_payload'] = parameters['raw_payload'];
        return <PostgresRow>[
          <String, Object?>{'inserted': 1},
        ];
      }
      return const <PostgresRow>[];
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
      if (row['is_demo'] == false) return 0;
      row['is_demo'] = false;
      row['flipped_to_live_at'] = parameters['now'];
      row['flipped_by_connection_id'] = parameters['connection_id'];
      row['pending_inserts_count'] = 0;
      return 1;
    }
    if (sql.contains('update public.vendor_credentials')) {
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

// ─── Adapter test doubles (reused for test F) ───────────────────────

class _FakeCloverApiClient implements CloverApiClient {
  _FakeCloverApiClient({List<CloverOrdersPage>? pages})
      : pages = List<CloverOrdersPage>.from(pages ?? <CloverOrdersPage>[]);

  final List<CloverOrdersPage> pages;

  @override
  Future<CloverOrdersPage> listOrders({
    required String merchantId,
    required DateTime modifiedFrom,
    required DateTime modifiedTo,
    required int offset,
    required int limit,
  }) async {
    if (pages.isEmpty) {
      return const CloverOrdersPage(
        elements: <Map<String, Object?>>[],
        nextOffset: null,
      );
    }
    return pages.removeAt(0);
  }

  @override
  Future<Map<String, Object?>> getOrder({
    required String merchantId,
    required String orderId,
  }) async =>
      throw StateError('not used in this test');

  @override
  Future<String> registerWebhook({
    required String merchantId,
    required String callbackUrl,
    required List<String> eventTypes,
  }) async =>
      'CLV-WHSUB-FAKE';

  @override
  Future<void> unregisterWebhook({
    required String merchantId,
    required String subscriptionId,
  }) async {}
}

class _StubWebhookRegistry implements CloverWebhookRegistry {
  @override
  Future<String> register({
    required String operatorId,
    required String locationId,
    required String merchantId,
  }) async =>
      'CLV-WHSUB-STUB';

  @override
  Future<bool> unregister({
    required String operatorId,
    required String locationId,
    required String merchantId,
    required String subscriptionId,
  }) async =>
      true;
}

class _StubCredentialStore implements CloverCredentialStore {
  _StubCredentialStore({required String merchantId})
      : _merchantId = merchantId;

  String? _merchantId;

  @override
  Future<bool> wipe({
    required String operatorId,
    required String locationId,
  }) async {
    _merchantId = null;
    return true;
  }

  @override
  Future<String?> readMerchantId({
    required String operatorId,
    required String locationId,
  }) async =>
      _merchantId;

  @override
  Future<String?> readWebhookSubscriptionId({
    required String operatorId,
    required String locationId,
  }) async =>
      null;
}
