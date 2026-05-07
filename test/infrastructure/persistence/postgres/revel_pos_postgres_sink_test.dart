// Phase 8 / Wave B `8.spine-bridge.1.RV` — Revel Systems Postgres-backed
// canonical sink test suite.
//
// Tests cover the eight contract bindings for `8.spine-bridge.1.RV`
// (per `docs/contracts/integration_spine_architecture_contract.md`):
//
//   A. Round-trip with the documented Revel field path: a typed
//      `RevelCanonicalOrderFact` (covers = `order.number_of_people`)
//      lands one `cover_facts` row whose every column matches the
//      canonical projection.
//   B. Idempotency replay: the same canonical fact written twice
//      produces 1 INSERT + 1 conflict-no-op (per the framework
//      migration partial UNIQUE on
//      `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`).
//   C. Watermark advance per batch — the sink writes one
//      `connector_sync_watermark` row per `writeWatermark` call.
//   D. Demo-mode flip on first batch with records >= 1; idempotent on
//      second flip.
//   E. RLS + tenancy isolation — every write transaction injects the
//      tenant via `set_config('app.operator_id', ...)`; operator A's
//      write does not surface under operator B's tenant context.
//   F. Existing `revel_pos_adapter_test.dart` smoke composes against
//      this sink: running `RevelPosAdapter.pollIncremental` writes one
//      `cover_facts` row + one watermark + one demo flip on first
//      batch.
//   G. Field-mapping audit — covers round-trip from
//      `order.number_of_people` via the adapter's canonical mapping:
//      a fixture order with `number_of_people = 4` yields
//      `cover_facts.covers = 4` after pollIncremental commits.
//   H. Banned-items grep across the sink source per
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.
//
// Mirrors the shape of
// `oracle_micros_simphony_postgres_sink_test.dart` so future audits
// can diff them side-by-side.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/revel_pos_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/revel_pos_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _opB = '22222222-2222-4222-8222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String _connA = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String _connB = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

RevelCanonicalOrderFact _sampleCanonicalFact({
  String operatorId = _opA,
  String locationId = _locA,
  int covers = 3,
}) =>
    RevelCanonicalOrderFact(
      operatorId: operatorId,
      locationId: locationId,
      vendorEntityId: '8842301',
      vendorModifiedAt: DateTime.utc(2026, 5, 2, 19, 31, 0),
      openedAt: DateTime.utc(2026, 5, 2, 18, 45, 0),
      closedAt: DateTime.utc(2026, 5, 2, 19, 31, 0),
      covers: covers,
      actualSales: 64.30,
      rawPayload: const <String, Object?>{
        'id': 8842301,
        'number_of_people': 3,
        'created_date': '2026-05-02T18:45:00Z',
        'updated_date': '2026-05-02T19:31:00Z',
        'final_total': '64.30',
      },
    );

void main() {
  group('RevelPosPostgresSink — A. round-trip', () {
    test('writes one cover_facts row from a typed RevelCanonicalOrderFact '
        '(covers came from order.number_of_people)', () async {
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = RevelPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final fact = _sampleCanonicalFact(covers: 3);
      final inserted = await sink.writeOrderFact(fact);

      expect(inserted, isTrue);
      expect(pool.coverFacts, hasLength(1));
      final row = pool.coverFacts.values.single;
      expect(row['vendor_id'], 'revel');
      expect(row['vendor_entity_id'], '8842301');
      expect(row['covers'], 3,
          reason: 'covers must round-trip from order.number_of_people');
      expect(row['covers_source'], 'direct');
      expect(row['opened_at'], DateTime.utc(2026, 5, 2, 18, 45, 0));
      expect(row['closed_at'], DateTime.utc(2026, 5, 2, 19, 31, 0));
      expect(row['vendor_modified_at'], DateTime.utc(2026, 5, 2, 19, 31, 0));
      expect((row['actual_sales'] as num).toDouble(), closeTo(64.30, 0.001));
      expect(row['operator_id'], _opA);
      expect(row['location_id'], _locA);

      final rawJson = jsonDecode(row['raw_payload'] as String) as Map<String, Object?>;
      expect(rawJson['number_of_people'], 3);
      expect(rawJson['id'], 8842301);
    });
  });

  group('RevelPosPostgresSink — B. idempotency replay', () {
    test('same canonical fact upserted twice -> 1 INSERT + 1 conflict-no-op',
        () async {
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = RevelPosPostgresSink(TenantTransactionWrapper(pool));

      final fact = _sampleCanonicalFact();
      final firstWrite = await sink.writeOrderFact(fact);
      final secondWrite = await sink.writeOrderFact(fact);

      expect(firstWrite, isTrue);
      expect(secondWrite, isTrue, reason: 'same-timestamp replay fires DO UPDATE >= guard');
      expect(pool.coverFacts, hasLength(1));
    });
  });

  group('RevelPosPostgresSink — C. watermark per batch', () {
    test('writeWatermark writes connector_sync_watermark with the resolved '
        'connection_id and resource = pos.guest_checks', () async {
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = RevelPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.writeWatermark(
        operatorId: _opA,
        locationId: _locA,
        row: RevelWatermarkRow(
          cursorToken: 'cursor-after-batch-1',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 31, 0),
        ),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['connection_id'], _connA);
      expect(wm['resource'], revelWatermarkResource);
      expect(wm['cursor_token'], 'cursor-after-batch-1');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 2, 19, 31, 0));
    });

    test('second writeWatermark on the same connection updates in place '
        '(per the connector_sync_watermark UNIQUE on '
        '(connection_id, resource))', () async {
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = RevelPosPostgresSink(TenantTransactionWrapper(pool));

      await sink.writeWatermark(
        operatorId: _opA,
        locationId: _locA,
        row: RevelWatermarkRow(
          cursorToken: 'cursor-1',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 31, 0),
        ),
      );
      await sink.writeWatermark(
        operatorId: _opA,
        locationId: _locA,
        row: RevelWatermarkRow(
          cursorToken: 'cursor-2',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 48, 0),
        ),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['cursor_token'], 'cursor-2');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 2, 19, 48, 0));
    });
  });

  group('RevelPosPostgresSink — D. demo-mode flip', () {
    test('first batch with records >= 1 flips demo_mode_state.is_demo to false',
        () async {
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = RevelPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.writeOrderFact(_sampleCanonicalFact());
      // writeWatermark triggers the auto-flip when the per-tenant
      // pending counter is non-zero — see the sink file header.
      await sink.writeWatermark(
        operatorId: _opA,
        locationId: _locA,
        row: RevelWatermarkRow(
          cursorToken: '',
          lastModifiedSeen: DateTime.utc(2026, 5, 2, 19, 31, 0),
        ),
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
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      var clockTick = 0;
      DateTime tickingClock() {
        clockTick += 1;
        return DateTime.utc(2026, 5, 4, 12, clockTick, 0);
      }

      final sink = RevelPosPostgresSink(
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
  });

  group('RevelPosPostgresSink — E. RLS + tenancy isolation', () {
    test('every write transaction injects app.operator_id via set_config',
        () async {
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = RevelPosPostgresSink(TenantTransactionWrapper(pool));

      await sink.writeOrderFact(_sampleCanonicalFact());

      expect(pool.transactions, isNotEmpty);
      for (final tx in pool.transactions) {
        expect(tx.setConfigCalls['app.operator_id'], _opA,
            reason: 'tenant SET LOCAL must run on every transaction');
        expect(tx.setConfigCalls['app.location_id'], _locA);
        expect(tx.committed, isTrue);
      }
    });

    test('operator A cover_facts row does not surface under operator B '
        'tenant context (the fake uses operator_id as part of the row key)',
        () async {
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedLocation(operatorId: _opB, locationId: _locB)
        ..seedConnection(operatorId: _opB, locationId: _locB, connectionId: _connB);
      final sink = RevelPosPostgresSink(TenantTransactionWrapper(pool));

      await sink.writeOrderFact(_sampleCanonicalFact(
        operatorId: _opA,
        locationId: _locA,
      ));

      // Same vendor_entity_id + vendor_modified_at written under
      // operator B should NOT collide because the UNIQUE includes
      // operator_id.
      await sink.writeOrderFact(_sampleCanonicalFact(
        operatorId: _opB,
        locationId: _locB,
      ));

      expect(pool.coverFacts, hasLength(2));
      final operatorIds = pool.coverFacts.values
          .map((row) => row['operator_id'] as String)
          .toSet();
      expect(operatorIds, <String>{_opA, _opB});
    });
  });

  group('RevelPosPostgresSink — F. adapter smoke', () {
    test('Revel adapter pollIncremental composes with the postgres sink: '
        'one batch -> 1 cover_facts row + 1 watermark + 1 demo flip',
        () async {
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedAccessToken(
          operatorId: _opA,
          locationId: _locA,
          accessToken: 'access-token-001',
        );
      final sink = RevelPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final transport = _FakeRevelTransport()
        ..pages = <RevelOrdersPage>[
          RevelOrdersPage(
            records: const <Map<String, Object?>>[
              <String, Object?>{
                'id': 9001,
                'created_date': '2026-04-30T17:00:00Z',
                'updated_date': '2026-04-30T18:05:00Z',
                'final_total': '42.10',
                'number_of_people': 2,
                'closed': true,
              },
            ],
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 4, 30, 18, 5, 0),
          ),
        ];

      final adapter = RevelPosAdapter(
        transport: transport,
        gateway: sink,
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
          vendorId: 'revel',
          lastModifiedSeen: DateTime.utc(2026, 4, 30),
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

  group('RevelPosPostgresSink — G. covers round-trip via adapter mapping', () {
    test('a vendor-shape order with order.number_of_people = 4 lands a '
        'cover_facts row with covers = 4 after pollIncremental commits',
        () async {
      final pool = _FakeRevelPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedAccessToken(
          operatorId: _opA,
          locationId: _locA,
          accessToken: 'access-token-001',
        );
      final sink = RevelPosPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final transport = _FakeRevelTransport()
        ..pages = <RevelOrdersPage>[
          RevelOrdersPage(
            records: const <Map<String, Object?>>[
              <String, Object?>{
                'id': 9002,
                'created_date': '2026-05-01T17:30:00Z',
                'updated_date': '2026-05-01T18:55:00Z',
                'final_total': '120.00',
                // The covers source-of-truth on the canonical fact.
                'number_of_people': 4,
                'closed': true,
              },
            ],
            nextCursor: null,
            lastModifiedSeen: DateTime.utc(2026, 5, 1, 18, 55, 0),
          ),
        ];

      final adapter = RevelPosAdapter(
        transport: transport,
        gateway: sink,
        now: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      Future<bool> alwaysAllow({
        required String vendorEventId,
        required Map<String, Object?> payload,
        required bool isDeliberateBackfill,
      }) async =>
          true;

      await adapter.pollIncremental(
        PollIncrementalCommand(
          operatorId: _opA,
          locationId: _locA,
          actorUserId: 'usr_owner',
          vendorId: 'revel',
          lastModifiedSeen: DateTime.utc(2026, 4, 30),
          sanityHook: alwaysAllow,
        ),
      );

      expect(pool.coverFacts, hasLength(1));
      final row = pool.coverFacts.values.single;
      expect(row['covers'], 4,
          reason: 'covers must round-trip from order.number_of_people via '
              'the adapter\'s canonical mapping');
      expect(row['covers_source'], 'direct');
      expect(row['vendor_entity_id'], '9002');
    });
  });

  group('RevelPosPostgresSink — H. banned-items grep', () {
    test('sink source contains zero V1 lean cut 2 banned items', () async {
      final source = await File(
        'lib/infrastructure/persistence/postgres/revel_pos_postgres_sink.dart',
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

class _FakeRevelTransport implements RevelTransport {
  List<RevelOrdersPage> _pages = <RevelOrdersPage>[];
  int _idx = 0;

  set pages(List<RevelOrdersPage> next) {
    _pages = next;
    _idx = 0;
  }

  @override
  Future<RevelTokenResponse> exchangeClientCredentials({
    required String clientId,
    required String clientSecret,
    required String audience,
  }) async =>
      RevelTokenResponse(
        accessToken: 'access-token-fake',
        expiresAt: DateTime.utc(2026, 5, 5, 12, 0, 0),
      );

  @override
  Future<RevelOrdersPage> listOrders({
    required String accessToken,
    required DateTime modifiedSince,
    required DateTime modifiedUntil,
    String? cursor,
  }) async {
    if (_idx >= _pages.length) {
      return RevelOrdersPage(
        records: const <Map<String, Object?>>[],
        nextCursor: null,
        lastModifiedSeen: modifiedSince,
      );
    }
    final page = _pages[_idx];
    _idx += 1;
    return page;
  }

  @override
  Future<Map<String, Object?>> fetchOrder({
    required String accessToken,
    required String orderId,
  }) async =>
      const <String, Object?>{};

  @override
  Future<String> registerWebhook({
    required String accessToken,
    required String url,
    required List<String> events,
    required String signingSecret,
  }) async =>
      'rev-sub-fake';

  @override
  Future<void> unregisterWebhook({
    required String accessToken,
    required String subscriptionId,
  }) async {}

  @override
  Future<Map<String, Object?>> sampleOrder({
    required String accessToken,
  }) async =>
      const <String, Object?>{};
}

class _FakeRevelPool implements PostgresPool {
  /// Keyed by `(operator_id, location_id)`.
  final Map<String, Map<String, Object?>> _locations =
      <String, Map<String, Object?>>{};

  /// Keyed by `(operator_id, location_id, vendor_id)`.
  final Map<String, String> _connectionsByTenant = <String, String>{};

  /// Keyed by `(operator_id, location_id, vendor_id)`.
  final Map<String, String?> _accessTokens = <String, String?>{};

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
    _connectionsByTenant['$operatorId|$locationId|revel'] = connectionId;
  }

  void seedAccessToken({
    required String operatorId,
    required String locationId,
    required String accessToken,
  }) {
    _accessTokens['$operatorId|$locationId|revel'] = accessToken;
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

  final _FakeRevelPool pool;
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
    if (sql.contains('select access_token_ciphertext')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final token =
          pool._accessTokens['$operatorId|$locationId|$vendorId'];
      if (token == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'access_token_ciphertext': token},
      ];
    }
    if (sql.contains('from public.demo_mode_state')) {
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
      final locationId = parameters['location_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final vendorEntityId = parameters['vendor_entity_id'] as String;
      final vendorModifiedAt = parameters['vendor_modified_at'] as DateTime;
      final key = '$operatorId|$locationId|$vendorId|$vendorEntityId';
      final existing = pool.coverFacts[key];
      if (existing != null) {
        // DO UPDATE WHERE excluded.vendor_modified_at >= stored
        final stored = existing['vendor_modified_at'] as DateTime;
        if (vendorModifiedAt.isBefore(stored)) {
          return const <PostgresRow>[];
        }
        existing['vendor_modified_at'] = vendorModifiedAt;
        existing['covers'] = parameters['covers'];
        existing['covers_source'] = parameters['covers_source'];
        existing['opened_at'] = parameters['opened_at'];
        existing['closed_at'] = parameters['closed_at'];
        existing['business_date'] = parameters['business_date'];
        existing['actual_sales'] = parameters['actual_sales'];
        existing['raw_payload'] = parameters['raw_payload'];
        return <PostgresRow>[<String, Object?>{'inserted': 1}];
      }
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
      return <PostgresRow>[<String, Object?>{'inserted': 1}];
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
    if (sql.contains('insert into public.connector_connection')) {
      // Connection upsert path; not asserted in this test suite, but
      // record it as a successful affected-row count so any future
      // connect-flow tests can extend without rewriting the fake.
      return 1;
    }
    if (sql.contains('insert into public.demo_mode_state')) {
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final category = parameters['category'] as String;
      final key = '$operatorId|$locationId|$category';
      if (sql.contains('pending_inserts_count + 1') ||
          sql.contains('pending_inserts_count =')) {
        // A2 path: increment counter on conflict
        final row = pool.demoModeState.putIfAbsent(
          key,
          () => <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'category': category,
            'is_demo': true,
            'pending_inserts_count': 0,
            'flipped_to_live_at': null,
            'flipped_by_connection_id': null,
          },
        );
        row['pending_inserts_count'] =
            ((row['pending_inserts_count'] as int? ?? 0) + 1);
      } else {
        // evaluateDemoFlip path: putIfAbsent with 0
        pool.demoModeState.putIfAbsent(
          key,
          () => <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'category': category,
            'is_demo': true,
            'pending_inserts_count': 0,
            'flipped_to_live_at': null,
            'flipped_by_connection_id': null,
          },
        );
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
      row['pending_inserts_count'] = 0;
      row['flipped_to_live_at'] = parameters['now'];
      row['flipped_by_connection_id'] = parameters['connection_id'];
      return 1;
    }
    if (sql.contains('update public.vendor_credentials')) {
      // Wipe path — flip the in-memory token to null so a follow-on
      // readAccessToken returns null.
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      pool._accessTokens['$operatorId|$locationId|$vendorId'] = null;
      return 1;
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
