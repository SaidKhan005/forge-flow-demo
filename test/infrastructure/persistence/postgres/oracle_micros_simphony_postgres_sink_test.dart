// Phase 8 / Wave B `8.spine-bridge.1.OR` — Oracle MICROS Simphony
// Postgres-backed canonical sink test suite.
//
// Tests cover the eight contract bindings for `8.spine-bridge.1.OR`
// (per `docs/contracts/integration_spine_architecture_contract.md`):
//
//   A. Round-trip with the Gen2 corrected field path: fixture
//      canonical-fact dict from `items[].header.guestCount` →
//      `cover_facts` row matches.
//   B. Idempotency replay: the same canonical fact written twice
//      produces 1 INSERT + 1 conflict-no-op (per the framework migration
//      partial UNIQUE on
//      `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`).
//   C. Watermark advance per batch — the sink writes one
//      `connector_sync_watermark` row per `advanceWatermark` call.
//   D. Demo-mode flip on first batch with records >= 1; idempotent on
//      second flip.
//   E. RLS + tenancy isolation — every write transaction injects the
//      tenant via `set_config('app.operator_id', ...)`; operator A's
//      write does not surface under operator B's tenant context.
//   F. Existing `oracle_micros_simphony_pos_adapter_test.dart` smoke-
//      runs against this sink: the sink composes cleanly with the
//      adapter via the bespoke `OracleMicrosSimphonyCanonicalSink`
//      interface; running the adapter's pollIncremental writes one
//      cover_facts row + one watermark + one demo flip on first batch.
//   G. Field-path audit: the adapter source contains zero references
//      to `numOfGst` or `numberOfGuests` as field-access tokens.
//   H. Banned-items grep across the sink source per
//      `memory/project_v1_lean_cut_2_2026_05_03.md`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/integrations/pos/oracle_micros_simphony_pos_adapter.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../integrations/pos/fixtures/oracle_micros_simphony_checks_fixture.dart';

const String _opA = '11111111-1111-4111-8111-111111111111';
const String _opB = '22222222-2222-4222-8222-222222222222';
const String _locA = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _locB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const String _connA = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const String _connB = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';

void main() {
  group('OracleMicrosSimphonyPostgresSink — A. round-trip', () {
    test('writes one cover_facts row from a canonical-fact dict whose '
        'covers came from items[].header.guestCount', () async {
      final pool = _FakeSimphonyPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = OracleMicrosSimphonyPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      final adapter = OracleMicrosSimphonyPosAdapter(
        apiClient: _FakeApi(),
        canonicalSink: sink,
      );
      final canonical = adapter.mapGuestCheckToCanonical(sampleSimphonyGuestCheck);

      final inserted = await sink.upsertGuestCheck(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );

      expect(inserted, isTrue);
      expect(pool.coverFacts, hasLength(1));
      final row = pool.coverFacts.values.single;
      expect(row['vendor_id'], 'oracle_micros_simphony');
      expect(row['vendor_entity_id'], '412901');
      expect(row['covers'], 5,
          reason: 'covers must round-trip from items[].header.guestCount');
      expect(
        row['opened_at'],
        DateTime.utc(2026, 5, 2, 22, 45, 0),
      );
      expect(
        row['closed_at'],
        DateTime.utc(2026, 5, 2, 23, 32, 14),
        reason: 'closed_at must round-trip from items[].header.cmplOrClsdUTC',
      );
      expect(
        row['vendor_modified_at'],
        DateTime.utc(2026, 5, 2, 23, 32, 14),
      );
      expect((row['actual_sales'] as num).toDouble(), closeTo(124.85, 0.001));
      expect(row['covers_source'], 'direct');
      expect(row['operator_id'], _opA);
      expect(row['location_id'], _locA);

      // raw_payload is JSONB; the fake stores the encoded string so
      // the test asserts on a structural round-trip.
      final rawJson = jsonDecode(row['raw_payload'] as String) as Map<String, Object?>;
      expect(rawJson['header'], isA<Map<String, Object?>>());
      final header = rawJson['header'] as Map<String, Object?>;
      expect(header['guestCount'], 5);
      expect(header['cmplOrClsdUTC'], '2026-05-02T23:32:14.000Z');
    });
  });

  group('OracleMicrosSimphonyPostgresSink — B. idempotency replay', () {
    test('same canonical fact upserted twice -> 1 INSERT + 1 conflict-no-op',
        () async {
      final pool = _FakeSimphonyPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = OracleMicrosSimphonyPostgresSink(
        TenantTransactionWrapper(pool),
      );
      final adapter = OracleMicrosSimphonyPosAdapter(
        apiClient: _FakeApi(),
        canonicalSink: sink,
      );
      final canonical = adapter.mapGuestCheckToCanonical(sampleSimphonyGuestCheck);

      final firstWrite = await sink.upsertGuestCheck(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );
      final secondWrite = await sink.upsertGuestCheck(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );

      expect(firstWrite, isTrue);
      expect(secondWrite, isFalse, reason: 'conflict-no-op on replay');
      expect(pool.coverFacts, hasLength(1));
    });
  });

  group('OracleMicrosSimphonyPostgresSink — C. watermark per batch', () {
    test('advanceWatermark writes connector_sync_watermark with the resolved '
        'connection_id and resource = pos.guest_checks', () async {
      final pool = _FakeSimphonyPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = OracleMicrosSimphonyPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );

      await sink.advanceWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-after-batch-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 23, 32, 14),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['connection_id'], _connA);
      expect(wm['resource'], oracleMicrosSimphonyWatermarkResource);
      expect(wm['cursor_token'], 'cursor-after-batch-1');
      expect(
        wm['last_modified_seen'],
        DateTime.utc(2026, 5, 2, 23, 32, 14),
      );
    });

    test('second advanceWatermark on the same connection updates in place '
        '(per the connector_sync_watermark UNIQUE on (connection_id, '
        'resource))', () async {
      final pool = _FakeSimphonyPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = OracleMicrosSimphonyPostgresSink(
        TenantTransactionWrapper(pool),
      );

      await sink.advanceWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-1',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 23, 32, 14),
      );
      await sink.advanceWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: 'cursor-2',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 23, 48, 1),
      );

      expect(pool.watermarks, hasLength(1));
      final wm = pool.watermarks.values.single;
      expect(wm['cursor_token'], 'cursor-2');
      expect(wm['last_modified_seen'], DateTime.utc(2026, 5, 2, 23, 48, 1));
    });
  });

  group('OracleMicrosSimphonyPostgresSink — D. demo-mode flip', () {
    test('first batch with records >= 1 flips demo_mode_state.is_demo to false',
        () async {
      final pool = _FakeSimphonyPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = OracleMicrosSimphonyPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
      final adapter = OracleMicrosSimphonyPosAdapter(
        apiClient: _FakeApi(),
        canonicalSink: sink,
      );

      final canonical = adapter.mapGuestCheckToCanonical(sampleSimphonyGuestCheck);
      await sink.upsertGuestCheck(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
      );
      // Watermark advance triggers the auto-flip when the per-tenant
      // pending counter is non-zero — see the sink file header.
      await sink.advanceWatermark(
        operatorId: _opA,
        locationId: _locA,
        cursorToken: '',
        lastModifiedSeen: DateTime.utc(2026, 5, 2, 23, 32, 14),
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
      final pool = _FakeSimphonyPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      var clockTick = 0;
      DateTime tickingClock() {
        clockTick += 1;
        return DateTime.utc(2026, 5, 4, 12, clockTick, 0);
      }

      final sink = OracleMicrosSimphonyPostgresSink(
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

  group('OracleMicrosSimphonyPostgresSink — E. RLS + tenancy isolation',
      () {
    test('every write transaction injects app.operator_id via set_config',
        () async {
      final pool = _FakeSimphonyPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = OracleMicrosSimphonyPostgresSink(
        TenantTransactionWrapper(pool),
      );

      final adapter = OracleMicrosSimphonyPosAdapter(
        apiClient: _FakeApi(),
        canonicalSink: sink,
      );
      final canonical =
          adapter.mapGuestCheckToCanonical(sampleSimphonyGuestCheck);
      await sink.upsertGuestCheck(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonical,
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
      final pool = _FakeSimphonyPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA)
        ..seedLocation(operatorId: _opB, locationId: _locB)
        ..seedConnection(operatorId: _opB, locationId: _locB, connectionId: _connB);
      final sink = OracleMicrosSimphonyPostgresSink(
        TenantTransactionWrapper(pool),
      );
      final adapter = OracleMicrosSimphonyPosAdapter(
        apiClient: _FakeApi(),
        canonicalSink: sink,
      );

      final canonicalA =
          adapter.mapGuestCheckToCanonical(sampleSimphonyGuestCheck);
      await sink.upsertGuestCheck(
        operatorId: _opA,
        locationId: _locA,
        canonicalFact: canonicalA,
      );

      // Operator B side: a request for the same vendor_entity_id +
      // vendor_modified_at should not collide with operator A's row
      // because the UNIQUE includes operator_id. We simulate by
      // writing the same canonical fact under operator B and asserting
      // both rows coexist with distinct operator_ids.
      await sink.upsertGuestCheck(
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

  group('OracleMicrosSimphonyPostgresSink — F. adapter smoke', () {
    test('OR adapter pollIncremental composes with the postgres sink: '
        'one batch -> 1 cover_facts row + 1 watermark + 1 demo flip',
        () async {
      final pool = _FakeSimphonyPool()
        ..seedLocation(operatorId: _opA, locationId: _locA)
        ..seedConnection(operatorId: _opA, locationId: _locA, connectionId: _connA);
      final sink = OracleMicrosSimphonyPostgresSink(
        TenantTransactionWrapper(pool),
        clock: () => DateTime.utc(2026, 5, 4, 12, 0, 0),
      );
      final apiClient = _FakeApi(
        sequencedPages: <SimphonyGuestCheckPage>[
          SimphonyGuestCheckPage(
            records: const <Map<String, Object?>>[sampleSimphonyGuestCheck],
            nextCursor: '',
            lastModifiedSeen: DateTime.utc(2026, 5, 2, 23, 32, 14),
          ),
        ],
      );
      final adapter = OracleMicrosSimphonyPosAdapter(
        apiClient: apiClient,
        canonicalSink: sink,
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
          vendorId: 'oracle_micros_simphony',
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

  group('OracleMicrosSimphonyPostgresSink — G. field-path audit', () {
    test('adapter source contains zero references to numOfGst or '
        'numberOfGuests as field-access tokens', () async {
      final source = await File(
        'lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart',
      ).readAsString();
      // The fixture and the doc-pack already prove the canonical truth
      // is `items[].header.guestCount`; this test pins the adapter
      // source so a future refactor cannot silently regress to Gen1.
      expect(source.contains('numOfGst'), isFalse,
          reason: 'Gen1 numOfGst must not appear in adapter source');
      expect(source.contains('numberOfGuests'), isFalse,
          reason: 'Wave B guess numberOfGuests must not appear');
      expect(source.contains("'guestCount'"), isTrue,
          reason: 'Gen2 guestCount must be the field path the adapter reads');
    });
  });

  group('OracleMicrosSimphonyPostgresSink — H. banned-items grep', () {
    test('sink source contains zero V1 lean cut 2 banned items', () async {
      final source = await File(
        'lib/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart',
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

class _FakeApi implements OracleMicrosSimphonyApiClient {
  _FakeApi({List<SimphonyGuestCheckPage>? sequencedPages})
      : _sequencedPages = sequencedPages ?? <SimphonyGuestCheckPage>[];

  final List<SimphonyGuestCheckPage> _sequencedPages;
  int _idx = 0;

  @override
  Future<SimphonyGuestCheckPage> fetchSampleGuestCheck({
    required String operatorId,
    required String locationId,
  }) async =>
      SimphonyGuestCheckPage(
        records: const <Map<String, Object?>>[],
        nextCursor: '',
        lastModifiedSeen: DateTime.utc(1970, 1, 1),
      );

  @override
  Future<SimphonyGuestCheckPage> fetchGuestChecks({
    required String operatorId,
    required String locationId,
    required DateTime sinceModified,
    required String? cursor,
    required bool isDeliberateBackfill,
  }) async {
    if (_idx >= _sequencedPages.length) {
      return SimphonyGuestCheckPage(
        records: const <Map<String, Object?>>[],
        nextCursor: '',
        lastModifiedSeen: sinceModified,
      );
    }
    final page = _sequencedPages[_idx];
    _idx += 1;
    return page;
  }
}

class _FakeSimphonyPool implements PostgresPool {
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

  /// Keyed by `(operator_id, location_id, vendor_id, module)`.
  final Map<String, Map<String, Object?>> credentials =
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
    _connectionsByTenant['$operatorId|$locationId|oracle_micros_simphony'] =
        connectionId;
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

  final _FakeSimphonyPool pool;
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
      // Append-only; we don't need to materialize rows for the
      // 8.spine-bridge.1.OR tests, but record the call so future
      // tests can grow.
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
