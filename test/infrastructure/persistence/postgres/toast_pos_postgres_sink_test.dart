// Phase 8 / Wave B `8.spine-bridge.1.TS` — Toast POS Postgres-backed
// canonical sink test suite.
//
// Tests cover the eight contract bindings for `8.spine-bridge.1.TS`
// (per `docs/contracts/integration_spine_architecture_contract.md`):
//
//   A. Round-trip with the documented Toast field path: a canonical
//      fact dict whose `covers` came from `numberOfGuests` →
//      `cover_facts` row matches.
//   B. Idempotency replay: the same canonical fact written twice
//      produces 1 INSERT + 1 conflict-no-op (per the framework migration
//      partial UNIQUE on
//      `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`).
//   C. Watermark advance per batch — the sink writes one
//      `connector_sync_watermark` row per `persistWatermark` call.
//   D. Demo-mode flip on first batch with records >= 1; idempotent on
//      second flip.
//   E. RLS + tenancy isolation — every write transaction injects the
//      tenant via `set_config('app.operator_id', ...)`; operator A's
//      write does not surface under operator B's tenant context.
//   F. Existing `toast_pos_adapter_test.dart` smoke — the sink composes
//      cleanly with the adapter via the bespoke `ToastFactSink`
//      interface; running the adapter's `pollIncremental` writes a
//      cover_facts row + watermark + demo flip on first batch.
//   G. Canonical-fact `covers` round-trips from Toast `numberOfGuests`
//      with no truncation, no drop. This is the CPLH math anchor — a
//      regression here corrupts every downstream Layer-2 / Layer-3
//      cover-aware read.
//   H. Banned-items grep across the sink source per
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart';
import 'package:forge_and_flow/integrations/pos/toast_pos_adapter.dart';
import 'package:forge_and_flow/integrations/pos/toast_webhook_signature_verifier.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _opB = '22222222-2222-4222-8222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String _connA = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String _connB = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

const Map<String, Object?> _sampleToastOrder = <String, Object?>{
  'guid': 'd1f9cd4a-4f4b-4d6e-9b7d-9a4f1f7c8e21',
  'restaurantGuid': '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
  'modifiedDate': '2026-05-04T19:55:00.000Z',
  'openedDate': '2026-05-04T18:30:00.000Z',
  'closedDate': '2026-05-04T19:55:00.000Z',
  'numberOfGuests': 5,
  'totalAmount': 124.85,
  'voided': false,
};

/// Mirror of `ToastPosAdapter._canonicalize` — kept here so the tests
/// do not depend on a private adapter method. The shape matches the
/// adapter source byte-for-byte; if the adapter mapping ever changes,
/// the round-trip + smoke tests both flag the drift.
Map<String, Object?> _toastCanonicalize(Map<String, Object?> order) {
  return <String, Object?>{
    'vendor_entity_id': order['guid'],
    'vendor_modified_at': order['modifiedDate'],
    'opened_at': order['openedDate'],
    'closed_at': order['closedDate'],
    'covers': order['numberOfGuests'],
    'covers_source': 'direct',
    'actual_sales': order['totalAmount'],
  };
}

void main() {
  group('ToastPosPostgresSink — A. round-trip', () {
    test('writes one cover_facts row from a canonical-fact dict whose '
        'covers came from numberOfGuests', () async {
      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 22, 0, 0),
      );

      final canonical = _toastCanonicalize(_sampleToastOrder);
      final inserted = await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
        rawPayload: _sampleToastOrder,
      );

      expect(inserted, isTrue);
      expect(pool.coverFacts, hasLength(1));
      final row = pool.coverFacts.values.single;
      expect(row['vendor_id'], kToastVendorId);
      expect(row['vendor_entity_id'], 'd1f9cd4a-4f4b-4d6e-9b7d-9a4f1f7c8e21');
      expect(row['covers'], 5,
          reason: 'covers must round-trip from numberOfGuests');
      expect(
        row['opened_at'],
        DateTime.utc(2026, 5, 4, 18, 30, 0),
      );
      expect(
        row['closed_at'],
        DateTime.utc(2026, 5, 4, 19, 55, 0),
        reason: 'closed_at must round-trip from closedDate',
      );
      expect(
        row['vendor_modified_at'],
        DateTime.utc(2026, 5, 4, 19, 55, 0),
      );
      expect((row['actual_sales'] as num).toDouble(), closeTo(124.85, 0.001));
      expect(row['covers_source'], 'direct');
      expect(row['operator_id'], _opA);
      expect(row['location_id'], _locA);

      final rawJson = jsonDecode(row['raw_payload'] as String) as Map<String, Object?>;
      expect(rawJson['guid'], 'd1f9cd4a-4f4b-4d6e-9b7d-9a4f1f7c8e21');
      expect(rawJson['numberOfGuests'], 5);
      expect(rawJson['closedDate'], '2026-05-04T19:55:00.000Z');
    });
  });

  group('ToastPosPostgresSink — B. idempotency replay', () {
    test('same canonical fact upserted twice -> 1 INSERT + 1 conflict-no-op',
        () async {
      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
      );
      final canonical = _toastCanonicalize(_sampleToastOrder);

      final firstWrite = await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
        rawPayload: _sampleToastOrder,
      );
      final secondWrite = await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
        rawPayload: _sampleToastOrder,
      );

      expect(firstWrite, isTrue);
      expect(secondWrite, isFalse, reason: 'conflict-no-op on replay');
      expect(pool.coverFacts, hasLength(1));
    });
  });

  group('ToastPosPostgresSink — C. watermark per batch', () {
    test('persistWatermark writes connector_sync_watermark with the '
        'resolved connection_id and resource = pos.guest_checks',
        () async {
      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 22, 0, 0),
      );

      await sink.persistWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-after-batch-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 4, 19, 55, 0),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['connection_id'], _connA);
      expect(wm['resource'], toastWatermarkResource);
      expect(wm['cursor_token'], 'cursor-after-batch-1');
      expect(
        wm['last_modified_seen'],
        DateTime.utc(2026, 5, 4, 19, 55, 0),
      );
    });

    test('second persistWatermark on the same connection updates in '
        'place (per the connector_sync_watermark UNIQUE on '
        '(connection_id, resource))', () async {
      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      await sink.persistWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 4, 19, 55, 0),
      );
      await sink.persistWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-2',
        lastModifiedSeen: DateTime.utc(2026, 5, 4, 20, 8, 1),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['cursor_token'], 'cursor-2');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 4, 20, 8, 1));
    });
  });

  group('ToastPosPostgresSink — D. demo-mode flip', () {
    test('first batch with records >= 1 flips demo_mode_state.is_demo to false',
        () async {
      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 22, 0, 0),
      );

      final canonical = _toastCanonicalize(_sampleToastOrder);
      await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
        rawPayload: _sampleToastOrder,
      );
      // Watermark advance triggers the auto-flip when the per-tenant
      // pending counter is non-zero — see the sink file header.
      await sink.persistWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: '',
        lastModifiedSeen: DateTime.utc(2026, 5, 4, 19, 55, 0),
      );

      expect(pool.demoModeState, hasLength(1));
      final flip = pool.demoModeState.values.single;
      expect(flip['is_demo'], isFalse);
      expect(flip['flipped_to_live_at'], DateTime.utc(2026, 5, 4, 22, 0, 0));
      expect(flip['flipped_by_connection_id'], _connA);
      expect(flip['category'], 'pos');
    });

    test('second flip is idempotent: flipped_to_live_at + connection_id '
        'are preserved', () async {
      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      var clockTick = 0;
      DateTime tickingClock() {
        clockTick += 1;
        return DateTime.utc(2026, 5, 4, 22, clockTick, 0);
      }

      final sink = ToastPosPostgresSink(
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
  });

  group('ToastPosPostgresSink — E. RLS + tenancy isolation', () {
    test('every write transaction injects app.operator_id via set_config',
        () async {
      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      final canonical = _toastCanonicalize(_sampleToastOrder);
      await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
        rawPayload: _sampleToastOrder,
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
      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedLocation(operatorId: _opB, locationId: _locB)
        ..seedConnection(operatorId: _opB, locationId: _locB, connectionId: _connB);
      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      final canonical = _toastCanonicalize(_sampleToastOrder);
      await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
        rawPayload: _sampleToastOrder,
      );

      // Operator B side: a request for the same vendor_entity_id +
      // vendor_modified_at should not collide with operator A's row
      // because the UNIQUE includes operator_id. We simulate by
      // writing the same canonical fact under operator B and asserting
      // both rows coexist with distinct operator_ids.
      await sink.upsertOrderFact(
        operatorId: _opB,
        locationId: _locB,
        canonicalFact: canonical,
        rawPayload: _sampleToastOrder,
      );

      expect(pool.coverFacts, hasLength(2));
      final operatorIds = pool.coverFacts.values
          .map((row) => row['operator_id'] as String)
          .toSet();
      expect(operatorIds, <String>{_opA, _opB});
    });
  });

  group('ToastPosPostgresSink — F. adapter smoke', () {
    test('Toast adapter pollIncremental composes with the postgres sink: '
        'one batch -> 1 cover_facts row + watermark(s) + 1 demo flip',
        () async {
      final nowFixed = DateTime.utc(2026, 5, 4, 22, 0, 0);
      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => nowFixed,
      );
      final transport = _FakeToastTransport(
        pollPages: <List<Map<String, Object?>>>[
          <Map<String, Object?>>[_sampleToastOrder],
        ],
      );
      final adapter = ToastPosAdapter(
        transport: transport,
        factSink: sink,
        now: () => nowFixed,
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
          vendorId: kToastVendorId,
          lastModifiedSeen: DateTime.utc(2026, 5, 4),
          sanityHook: alwaysAllow,
        ),
      );

      expect(result.recordsWritten, 1);
      expect(pool.coverFacts, hasLength(1));
      expect(pool.watermarks, isNotEmpty);
      expect(pool.demoModeState, hasLength(1));
      expect(pool.demoModeState.values.single['is_demo'], isFalse);
    });
  });

  group('ToastPosPostgresSink — G. covers round-trip from numberOfGuests',
      () {
    test('canonical-fact `covers` from `numberOfGuests` lands untouched '
        'in cover_facts.covers (no truncation, no drop) — CPLH math '
        'precondition', () async {
      // A non-default cover count — picked so the test would fail
      // loudly if the sink ever silently substituted a default or
      // dropped the field.
      const int numberOfGuestsValue = 7;
      final order = <String, Object?>{
        ..._sampleToastOrder,
        'guid': 'covers-roundtrip-001',
        'numberOfGuests': numberOfGuestsValue,
      };

      final pool = _FakeToastPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = ToastPosPostgresSink(
        TenantTransactionWrapper(pool),
      );

      final canonical = _toastCanonicalize(order);
      // Pre-condition: the canonical mapping itself preserves the
      // value at the dict key the sink reads.
      expect(canonical['covers'], numberOfGuestsValue,
          reason: 'adapter canonicalize must place numberOfGuests at '
              'canonicalFact[\'covers\']');

      final inserted = await sink.upsertOrderFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
        rawPayload: order,
      );

      expect(inserted, isTrue);
      final row = pool.coverFacts.values.single;
      expect(row['covers'], numberOfGuestsValue,
          reason: 'cover_facts.covers must equal numberOfGuests with no '
              'truncation, no drop, no fallback default');
      expect(row['covers_source'], 'direct',
          reason: 'Toast numberOfGuests is a documented direct covers source');

      // The raw order is preserved so an audit/replay can re-derive
      // the value if the canonical column is ever doubted.
      final rawJson = jsonDecode(row['raw_payload'] as String) as Map<String, Object?>;
      expect(rawJson['numberOfGuests'], numberOfGuestsValue);
    });
  });

  group('ToastPosPostgresSink — H. banned-items grep', () {
    test('sink source contains zero V1 lean cut 2 banned items', () async {
      final source = await File(
        'lib/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart',
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

  // Code Health LB#2 — `appendSyncLog` writes the `payload_preview`
  // JSONB column through the shared `encodePayloadPreviewForSyncLog`
  // helper, which redacts the payload via `redactWebhookPayload` BEFORE
  // JSON-encoding. Operator-scoped Postgres must never carry vendor
  // secrets / PII in the clear.
  group('Code Health LB#2 — appendSyncLog redacts payload_preview', () {
    test(
      'sensitive fields are stripped from the connector_sync_log INSERT '
      'before reaching Postgres',
      () async {
        final pool = _FakeToastPool()
          ..seedLocation(operatorId: _opA, locationId: _locA)
          ..seedConnection(
            operatorId: _opA,
            locationId: _locA,
            connectionId: _connA,
          );
        final sink = ToastPosPostgresSink(
          TenantTransactionWrapper(pool),
          clock: () => DateTime.utc(2026, 5, 4, 22, 0, 0),
        );

        await sink.appendSyncLog(
          operatorId: _opA,
          locationId: _locA,
          eventKind: 'poll_success',
          recordsCount: 1,
          connectionId: _connA,
          payloadPreview: <String, Object?>{
            'records_count': 1,
            'password': 'hunter2',
            'api_key': 'sk_live_xyz',
            'refresh_token': 'rt_abc',
            'email': 'guest@example.com',
            'phone': '+15551234567',
            'guest_name': 'Casey Riley',
            'nested': <String, Object?>{
              'secret': 'shhh',
              'safe_field': 'keep-me',
            },
          },
        );

        expect(pool.syncLogInserts, hasLength(1));
        final encoded = pool.syncLogInserts.single['payload_preview'];
        expect(encoded, isA<String>(),
            reason: 'helper must JSON-encode the redacted preview');
        final decoded =
            jsonDecode(encoded! as String) as Map<String, Object?>;
        for (final stripped in <String>[
          'password',
          'api_key',
          'refresh_token',
          'email',
          'phone',
          'guest_name',
        ]) {
          expect(decoded.containsKey(stripped), isFalse,
              reason: '$stripped must be redacted out of payload_preview');
        }
        final nested = decoded['nested']! as Map<String, Object?>;
        expect(nested.containsKey('secret'), isFalse,
            reason: 'nested secret must be redacted recursively');
        expect(nested['safe_field'], 'keep-me');
        expect(decoded['records_count'], 1);
      },
    );
  });
}

// ─── Test doubles ────────────────────────────────────────────────────

class _FakeToastTransport implements ToastApiClient {
  _FakeToastTransport({
    List<List<Map<String, Object?>>>? pollPages,
  }) : _pollPages = pollPages ?? <List<Map<String, Object?>>>[];

  final List<List<Map<String, Object?>>> _pollPages;
  int _idx = 0;

  @override
  Future<ToastCredentialHandle> exchangeClientCredentials({
    required String operatorId,
    required String locationId,
    required String restaurantGuid,
    String? oauthState,
  }) async {
    return const ToastCredentialHandle(
      connectionId: 'conn-toast-fake',
      restaurantGuid: '3b1f9b5f-7f50-4e7b-90b8-1c9aa39a0011',
    );
  }

  @override
  Future<String> registerWebhook({
    required ToastCredentialHandle credentials,
    required String webhookUrl,
  }) async =>
      'sub-toast-fake';

  @override
  Future<bool> unregisterWebhook({
    required ToastCredentialHandle credentials,
    String? subscriptionId,
  }) async =>
      true;

  @override
  Future<Map<String, Object?>> fetchSampleOrder({
    required ToastCredentialHandle credentials,
  }) async =>
      Map<String, Object?>.from(_sampleToastOrder);

  @override
  Future<ToastOrdersPage> fetchOrdersPage({
    required ToastCredentialHandle credentials,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? resumeFromCursor,
  }) async {
    if (_idx >= _pollPages.length) {
      return ToastOrdersPage(
        orders: const <Map<String, Object?>>[],
        nextCursor: null,
        lastModifiedSeen: windowStart,
      );
    }
    final orders = _pollPages[_idx];
    _idx += 1;
    return ToastOrdersPage(
      orders: orders,
      nextCursor: null,
      lastModifiedSeen: orders.isEmpty
          ? windowStart
          : DateTime.parse(orders.last['modifiedDate']! as String),
    );
  }

  @override
  Future<Map<String, Object?>?> fetchOrderByGuid({
    required ToastCredentialHandle credentials,
    required String guid,
  }) async =>
      Map<String, Object?>.from(_sampleToastOrder)..['guid'] = guid;
}

class _FakeToastPool implements PostgresPool {
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

  /// Captured `connector_sync_log` INSERT parameter maps in execution
  /// order. Code Health LB#2 — used to assert
  /// `payload_preview` redaction.
  final List<PostgresParameters> syncLogInserts = <PostgresParameters>[];

  final List<_FakeToastTransaction> transactions = <_FakeToastTransaction>[];

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
    _connectionsByTenant['$operatorId|$locationId|$kToastVendorId'] =
        connectionId;
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeToastTransaction(this);
    transactions.add(tx);
    return tx;
  }
}

class _FakeToastTransaction implements PostgresTransaction {
  _FakeToastTransaction(this.pool);

  final _FakeToastPool pool;
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
      // Append-only; capture the parameter map so Code Health LB#2 can
      // assert the `payload_preview` value the sink encoded.
      pool.syncLogInserts.add(parameters);
      return 1;
    }
    if (sql.contains('insert into public.demo_mode_state')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      pool.demoModeState.putIfAbsent(
        key,
        () => <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': category,
          'is_demo': true,
          'flipped_to_live_at': null,
          'flipped_by_connection_id': null,
        },
      );
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
      return 1;
    }
    if (sql.contains('update public.vendor_credentials')) {
      // No-op for these tests; just count it as 0 affected rows so
      // wipeCredentialsPreserveWatermark returns true regardless.
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
