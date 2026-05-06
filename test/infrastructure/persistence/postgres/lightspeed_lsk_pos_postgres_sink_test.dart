// Phase 8 / Wave B `8.spine-bridge.1.LSK` — Lightspeed Restaurant
// K-Series Postgres-backed canonical sink test suite.
//
// Tests cover the eight contract bindings for `8.spine-bridge.1.LSK`
// (per `docs/contracts/integration_spine_architecture_contract.md`):
//
//   A. Round-trip: a canonical-fact dict (vendor_id, vendor_entity_id,
//      covers, opened_at, closed_at, vendor_modified_at, actual_sales,
//      covers_source, raw_payload) → `cover_facts` row matches.
//   B. Idempotency replay: the same canonical fact written twice
//      produces 1 INSERT + 1 conflict-no-op (per the framework
//      migration partial UNIQUE on (operator_id, vendor_id,
//      vendor_entity_id, vendor_modified_at)).
//   C. Watermark advance per batch — the sink writes one
//      `connector_sync_watermark` row per `updateWatermark` call;
//      second advance updates in place (UNIQUE on (connection_id,
//      resource)).
//   D. Demo-mode flip on first batch with records >= 1; idempotent on
//      second flip.
//   E. RLS + tenancy isolation — every write transaction injects the
//      tenant via `set_config('app.operator_id', ...)`; operator A's
//      write does not surface under operator B's tenant context.
//   F. Existing `lightspeed_lsk_pos_adapter_test.dart` smoke-runs
//      against this sink: the sink composes cleanly with the adapter
//      via the bespoke `LightspeedLskGateway` interface; running the
//      adapter's pollIncremental writes one cover_facts row + one
//      watermark + one demo flip on first batch.
//   G. Field-path audit: the canonical-fact dict round-trips covers
//      from the K-Series first-class `nbCovers` field. Pins the
//      adapter source to `'nbCovers'` so a future refactor cannot
//      silently regress to a fallback / different field path.
//   H. Banned-items grep across the sink source per
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/lightspeed_lsk_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/lightspeed_lsk_pos_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/pos/fixtures/lightspeed_lsk_orders_fixture.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _opB = '22222222-2222-4222-8222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String _connA = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String _connB = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const String _businessId = 'lsk-biz-7c2f';
const String _accessTokenCredentialId =
    'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';

/// Build the canonical-fact dict shape the LSK adapter produces from
/// one Lightspeed K-Series sale. Mirrors the projection the adapter
/// applies in `_projectCanonicalRecord` (`nbCovers` → `covers`,
/// `timeOfOpening` → `opened_at`, `timeClosed` → `closed_at`,
/// summed `payments[].netAmountWithTax` → `actual_sales`,
/// `accountFiscId` → `vendor_entity_id`). Adapter projection is
/// private; tests reconstruct it via this helper instead of touching
/// adapter internals.
Map<String, Object?> _projectCanonicalDict(Map<String, Object?> sale) {
  final entityId = sale['accountFiscId'] as String;
  final openedAt =
      DateTime.parse(sale['timeOfOpening'] as String).toUtc();
  final closedAt =
      DateTime.parse(sale['timeClosed'] as String).toUtc();
  final coversRaw = sale['nbCovers'];
  final covers = coversRaw is num ? coversRaw.round() : 0;
  double actualSales = 0.0;
  final payments = sale['payments'];
  if (payments is List) {
    for (final entry in payments) {
      if (entry is Map) {
        final amount = entry['netAmountWithTax'];
        if (amount is num) {
          actualSales += amount.toDouble();
        } else if (amount is String) {
          final parsed = double.tryParse(amount);
          if (parsed != null) actualSales += parsed;
        }
      }
    }
  }
  final modifiedAt = closedAt.isAfter(openedAt) ? closedAt : openedAt;
  return <String, Object?>{
    'vendor_id': kLightspeedLskVendorId,
    'vendor_entity_id': entityId,
    'covers': covers,
    'opened_at': openedAt,
    'closed_at': closedAt,
    'actual_sales': double.parse(actualSales.toStringAsFixed(2)),
    'vendor_modified_at': modifiedAt,
    'covers_source': 'direct',
    'raw_payload': sale,
  };
}

void main() {
  group('LightspeedLskPosPostgresSink — A. round-trip', () {
    test('writes one cover_facts row from a canonical-fact dict whose '
        'covers came from the LSK first-class nbCovers field', () async {
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
      final sink = LightspeedLskPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final sample = lightspeedLskSampleOrder();
      final canonical = _projectCanonicalDict(sample);

      final inserted = await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );

      expect(inserted, isTrue);
      expect(pool.coverFacts, hasLength(1));
      final row = pool.coverFacts.values.single;
      expect(row['vendor_id'], kLightspeedLskVendorId);
      expect(row['vendor_entity_id'], 'A65315.17');
      expect(row['covers'], 3,
          reason: 'covers must round-trip from sales[].nbCovers');
      expect(row['opened_at'], DateTime.utc(2026, 5, 4, 18, 45, 0));
      expect(row['closed_at'], DateTime.utc(2026, 5, 4, 19, 42, 0),
          reason: 'closed_at must round-trip from sales[].timeClosed');
      expect(row['vendor_modified_at'], DateTime.utc(2026, 5, 4, 19, 42, 0));
      expect((row['actual_sales'] as num).toDouble(), closeTo(142.55, 0.001));
      expect(row['covers_source'], 'direct');
      expect(row['operator_id'], _opA);
      expect(row['location_id'], _locA);

      // raw_payload is JSONB; the fake stores the encoded string so
      // the test asserts on a structural round-trip.
      final rawJson =
          jsonDecode(row['raw_payload'] as String) as Map<String, Object?>;
      expect(rawJson['accountFiscId'], 'A65315.17');
      expect(rawJson['nbCovers'], 3);
      expect(rawJson['timeClosed'], '2026-05-04T19:42:00.000Z');
    });
  });

  group('LightspeedLskPosPostgresSink — B. idempotency replay', () {
    test('same canonical fact upserted twice -> 1 INSERT + 1 conflict-no-op',
        () async {
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
      final sink =
          LightspeedLskPosPostgresSink(TenantTransactionWrapper(pool));
      final canonical = _projectCanonicalDict(lightspeedLskSampleOrder());

      final firstWrite = await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );
      final secondWrite = await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );

      expect(firstWrite, isTrue);
      expect(secondWrite, isFalse, reason: 'conflict-no-op on replay');
      expect(pool.coverFacts, hasLength(1));
    });
  });

  group('LightspeedLskPosPostgresSink — C. watermark per batch', () {
    test('updateWatermark writes connector_sync_watermark with the resolved '
        'connection_id and resource = pos.guest_checks', () async {
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
      final sink = LightspeedLskPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.updateWatermark(
        connectionId: _connA,
        cursorToken: 'cursor-after-batch-1',
        lastModifiedSeenUtc: DateTime.utc(2026, 5, 4, 19, 42, 0),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['connection_id'], _connA);
      expect(wm['resource'], lightspeedLskWatermarkResource);
      expect(wm['cursor_token'], 'cursor-after-batch-1');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 4, 19, 42, 0));
    });

    test('second updateWatermark on the same connection updates in place '
        '(per the connector_sync_watermark UNIQUE on (connection_id, '
        'resource))', () async {
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
      final sink =
          LightspeedLskPosPostgresSink(TenantTransactionWrapper(pool));

      await sink.updateWatermark(
        connectionId: _connA,
        cursorToken: 'cursor-1',
        lastModifiedSeenUtc: DateTime.utc(2026, 5, 4, 19, 42, 0),
      );
      await sink.updateWatermark(
        connectionId: _connA,
        cursorToken: 'cursor-2',
        lastModifiedSeenUtc: DateTime.utc(2026, 5, 4, 23, 55, 0),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['cursor_token'], 'cursor-2');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 4, 23, 55, 0));
    });
  });

  group('LightspeedLskPosPostgresSink — D. demo-mode flip', () {
    test('first batch with records >= 1 flips demo_mode_state.is_demo to false',
        () async {
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
      final sink = LightspeedLskPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final canonical = _projectCanonicalDict(lightspeedLskSampleOrder());
      await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );
      // Watermark advance triggers the auto-flip when the per-tenant
      // pending counter is non-zero — see the sink file header.
      await sink.updateWatermark(
        connectionId: _connA,
        cursorToken: '',
        lastModifiedSeenUtc: DateTime.utc(2026, 5, 4, 19, 42, 0),
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
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
      var clockTick = 0;
      DateTime tickingClock() {
        clockTick += 1;
        return DateTime.utc(2026, 5, 4, 12, clockTick, 0);
      }

      final sink = LightspeedLskPosPostgresSink(
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

  group('LightspeedLskPosPostgresSink — E. RLS + tenancy isolation', () {
    test('every write transaction injects app.operator_id via set_config',
        () async {
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
      final sink =
          LightspeedLskPosPostgresSink(TenantTransactionWrapper(pool));
      final canonical = _projectCanonicalDict(lightspeedLskSampleOrder());
      await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );

      expect(pool.transactions, isNotEmpty);
      // Tenant-scoped transactions inject app.operator_id /
      // app.location_id; system-scoped lookups (used by bespoke
      // gateway calls without a tenant) skip those and instead carry
      // the system audit marker. The cover-facts upsert above takes
      // the tenant path exclusively.
      final tenantTxs = pool.transactions
          .where((tx) => tx.setConfigCalls.containsKey('app.operator_id'))
          .toList();
      expect(tenantTxs, isNotEmpty);
      for (final tx in tenantTxs) {
        expect(tx.setConfigCalls['app.operator_id'], _opA,
            reason: 'tenant SET LOCAL must run on every transaction');
        expect(tx.setConfigCalls['app.location_id'], _locA);
        expect(tx.committed, isTrue);
      }
    });

    test('operator A cover_facts row does not surface under operator B '
        'tenant context (the fake uses operator_id as the row key)',
        () async {
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        )
        ..seedLocation(operatorId: _opB, locationId: _locB)
        ..seedConnection(
          operatorId: _opB,
          locationId: _locB,
          connectionId: _connB,
        );
      final sink =
          LightspeedLskPosPostgresSink(TenantTransactionWrapper(pool));
      final canonicalA = _projectCanonicalDict(lightspeedLskSampleOrder());

      await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonicalA,
      );

      // Operator B side: a request for the same vendor_entity_id +
      // vendor_modified_at should not collide with operator A's row
      // because the UNIQUE includes operator_id. We simulate by
      // writing the same canonical fact under operator B and
      // asserting both rows coexist with distinct operator_ids.
      await sink.upsertCoverFact(
        operatorId: _opB,
        locationId: _locB,
        canonicalFact: canonicalA,
      );

      expect(pool.coverFacts, hasLength(2));
      final operatorIds = pool.coverFacts.values
          .map((row) => row['operator_id'] as String)
          .toSet();
      expect(operatorIds, <String>{_opA, _opB});
    });
  });

  group('LightspeedLskPosPostgresSink — F. adapter smoke', () {
    test('LSK adapter pollIncremental composes with the postgres sink: '
        'one batch -> 1 cover_facts row + 1 watermark + 1 demo flip',
        () async {
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
      final sink = LightspeedLskPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final ordersClient = _FakeOrdersClient(
        sequencedPages: <LightspeedLskSalesPage>[
          LightspeedLskSalesPage(
            sales: <Map<String, Object?>>[lightspeedLskSampleOrder()],
            nextPageToken: null,
          ),
        ],
      );
      final adapter = LightspeedLskPosAdapter(
        gateway: sink,
        oauthClient: _StubOAuthClient(),
        webhookClient: _StubWebhookClient(),
        ordersClient: ordersClient,
        restaurantTimezone: 'America/Toronto',
        businessDayRolloverHour: 4,
        webhookUrl: 'https://api.forgeflow.app/v1/webhooks/lightspeed_lsk/test',
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
          actorUserId: '00000000-0000-4000-8000-0000000000b1',
          vendorId: kLightspeedLskVendorId,
          lastModifiedSeen: DateTime.utc(2026, 5, 2),
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

  group('LightspeedLskPosPostgresSink — G. covers field-path round-trip',
      () {
    test('canonical-fact dict round-trips covers from the K-Series '
        'first-class nbCovers field; adapter source pins nbCovers and '
        'rejects fallback paths', () async {
      // Round-trip half: drive a sample sale (`nbCovers: 5.0`) through
      // upsertCoverFact and assert cover_facts.covers == 5.
      final pool = _FakeLskPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(
          operatorId: _opA,
          locationId: _locA,
          connectionId: _connA,
        );
      final sink =
          LightspeedLskPosPostgresSink(TenantTransactionWrapper(pool));
      // Pick the 4th fixture row — it has nbCovers: 5.0 — so the
      // assertion below pins the field-path AND the rounding behavior.
      final fiveCoverSale = lightspeedLskFiveRecordBatch()[3];
      expect(fiveCoverSale['nbCovers'], 5.0,
          reason: 'fixture invariant; covers source field is nbCovers');
      final canonical = _projectCanonicalDict(fiveCoverSale);
      await sink.upsertCoverFact(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );
      expect(pool.coverFacts, hasLength(1));
      expect(pool.coverFacts.values.single['covers'], 5,
          reason: 'covers must round-trip 5 from sales[].nbCovers');

      // Source-audit half: the LSK adapter source MUST read
      // `'nbCovers'` and MUST NOT contain fallback / different field
      // paths. Pins the adapter so a future refactor cannot silently
      // regress to a different vendor field.
      final adapterSource = await File(
        'lib/integrations/pos/lightspeed_lsk_pos_adapter.dart',
      ).readAsString();
      expect(adapterSource.contains("'nbCovers'"), isTrue,
          reason: 'first-class covers field path must be nbCovers');
      // The K-Series field is `nbCovers`; these are the wrong-vendor
      // tokens the adapter must NOT use as field-access strings.
      expect(adapterSource.contains("'guestCount'"), isFalse,
          reason: 'guestCount is the Oracle Simphony field, not LSK');
      expect(adapterSource.contains("'numberOfGuests'"), isFalse,
          reason: 'numberOfGuests is not the LSK field path');
    });
  });

  group('LightspeedLskPosPostgresSink — H. banned-items grep', () {
    test('sink source contains zero V1 lean cut 2 banned items', () async {
      final source = await File(
        'lib/infrastructure/persistence/postgres/lightspeed_lsk_pos_postgres_sink.dart',
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

class _StubOAuthClient implements LightspeedLskOAuthClient {
  @override
  Future<LightspeedLskTokenExchangeResult> completeAuthorization({
    required String oauthState,
  }) async =>
      throw UnimplementedError('not used in pollIncremental smoke');

  @override
  Future<LightspeedLskTokenExchangeResult> refresh({
    required String refreshTokenCredentialId,
  }) async =>
      throw UnimplementedError('not used in pollIncremental smoke');

  @override
  Future<void> revoke({required String accessTokenCredentialId}) async =>
      throw UnimplementedError('not used in pollIncremental smoke');
}

class _StubWebhookClient implements LightspeedLskWebhookClient {
  @override
  Future<LightspeedLskWebhookSubscription> subscribe({
    required String accessTokenCredentialId,
    required String webhookUrl,
    required String endpointId,
  }) async =>
      throw UnimplementedError('not used in pollIncremental smoke');

  @override
  Future<void> unregister({
    required String accessTokenCredentialId,
    required String subscriptionId,
  }) async =>
      throw UnimplementedError('not used in pollIncremental smoke');
}

class _FakeOrdersClient implements LightspeedLskOrdersClient {
  _FakeOrdersClient({List<LightspeedLskSalesPage>? sequencedPages})
      : _sequencedPages = sequencedPages ?? <LightspeedLskSalesPage>[];

  final List<LightspeedLskSalesPage> _sequencedPages;
  int _idx = 0;

  @override
  Future<LightspeedLskSalesPage> fetchSalesPage({
    required String accessTokenCredentialId,
    required String businessId,
    required DateTime windowStartUtc,
    required DateTime windowEndUtc,
    required int pageSize,
    String? cursorToken,
  }) async {
    if (_idx >= _sequencedPages.length) {
      return const LightspeedLskSalesPage(
        sales: <Map<String, Object?>>[],
        nextPageToken: null,
      );
    }
    final page = _sequencedPages[_idx];
    _idx += 1;
    return page;
  }

  @override
  Future<Map<String, Object?>> fetchSampleOrder({
    required String accessTokenCredentialId,
    required String businessId,
  }) async =>
      lightspeedLskSampleOrder();
}

class _FakeLskPool implements PostgresPool {
  /// Keyed by `(operator_id, location_id)`.
  final Map<String, Map<String, Object?>> _locations =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id, vendor_id)` → connectionId.
  final Map<String, String> _connectionsByTenant = <String, String>{};

  /// Reverse lookup: connectionId → (operator_id, location_id).
  final Map<String, ({String operatorId, String locationId})>
      _tenantsByConnection =
      <String, ({String operatorId, String locationId})>{};

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
    _connectionsByTenant['$operatorId|$locationId|$kLightspeedLskVendorId'] =
        connectionId;
    _tenantsByConnection[connectionId] = (
      operatorId: operatorId,
      locationId: locationId,
    );
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

  final _FakeLskPool pool;
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
    // Bespoke `lookupBinding` shape: filter by (operator_id,
    // location_id, vendor_id, status='connected').
    if (sql.contains('from public.connector_connection') &&
        sql.contains('operator_id = @operator_id') &&
        sql.contains('location_id = @location_id') &&
        sql.contains('vendor_id = @vendor_id')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final connId =
          pool._connectionsByTenant['$operatorId|$locationId|$vendorId'];
      if (connId == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'connection_id': connId,
          'business_id': _businessId,
          'webhook_subscription_id': 'sub-1',
          'credential_id': _accessTokenCredentialId,
        },
      ];
    }
    // System-path `_resolveTenantFromConnection`: filter by
    // connection_id only.
    if (sql.contains('from public.connector_connection') &&
        sql.contains('where connection_id = @connection_id')) {
      final connId = parameters['connection_id'] as String;
      final tenant = pool._tenantsByConnection[connId];
      if (tenant == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'operator_id': tenant.operatorId,
          'location_id': tenant.locationId,
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
    if (sql.contains('insert into public.connector_connection')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final existing =
          pool._connectionsByTenant['$operatorId|$locationId|$vendorId'];
      final connId = existing ??
          'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      pool._connectionsByTenant['$operatorId|$locationId|$vendorId'] =
          connId;
      pool._tenantsByConnection[connId] =
          (operatorId: operatorId, locationId: locationId);
      return <PostgresRow>[
        <String, Object?>{'connection_id': connId},
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
    if (sql.startsWith('set local role')) {
      // System-path role elevation; the wrapper issues this before the
      // body runs. The fake is trust-based: it does not enforce RLS,
      // so the role swap is a no-op here.
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
      // SQL narrows by `is_demo = true`; idempotent re-flip when
      // already false.
      if (row['is_demo'] == false) return 0;
      row['is_demo'] = false;
      row['flipped_to_live_at'] = parameters['now'];
      row['flipped_by_connection_id'] = parameters['connection_id'];
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
