// Regression test: A1 — vendor idempotency hardening
//
// Verifies that the migration
// `202605080600_phase_8_idempotency_location_id_rekey.sql` + the
// updated upsert semantics in every `*_postgres_sink.dart` file
// collectively fix two bugs:
//
//   Bug 1 — multi-location data loss: Two locations under one operator
//     sharing a vendor_entity_id (Toast check-id reuse, multi-store
//     POS) silently no-oped the second write because the OLD index
//     keyed on (operator_id, vendor_id, vendor_entity_id,
//     vendor_modified_at) and the second location's row conflicted.
//     Fix: add location_id to the key so rows from different locations
//     coexist.
//
//   Bug 2 — late-backfill shadows newer corrections: vendor_modified_at
//     was IN the key, so an older-timestamped correction inserted a
//     NEW row rather than being rejected. Fix: remove vendor_modified_at
//     from the key; use it in the upsert WHERE guard
//     (excluded.vendor_modified_at >= stored) so older arrivals are
//     ignored and newer arrivals update in-place.
//
// These tests use an in-memory fake pool (same approach as the vendor
// sink tests under `test/infrastructure/persistence/postgres/`) so
// they run without a real Postgres instance. The in-memory pool
// enforces the new unique key `(operator_id, location_id, vendor_id,
// vendor_entity_id)` and the vendor_modified_at >= guard directly,
// mirroring the SQL behaviour the migration installs in production.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart';
import 'package:forge_and_flow/integrations/pos/toast_webhook_signature_verifier.dart';

// ─── Constants ────────────────────────────────────────────────────────

const String _opA = 'aaaaaa00-0000-4000-8000-000000000001';
const String _locX = '11111100-0000-4000-8000-000000000001';
const String _locY = '22222200-0000-4000-8000-000000000002';
const String _connX = '33333300-0000-4000-8000-000000000001';
const String _connY = '44444400-0000-4000-8000-000000000002';

// The same vendor entity id used across all four writes — simulating a
// Toast check whose GUID reuses across two locations.
const String _checkId = 'check-idempotency-001';

final DateTime _t1 = DateTime.utc(2026, 5, 1, 10, 0, 0);
final DateTime _t2 = DateTime.utc(2026, 5, 2, 10, 0, 0);
final DateTime _t0 = DateTime.utc(2026, 4, 30, 10, 0, 0);

Map<String, Object?> _canonical({
  required DateTime modifiedAt,
  String entityId = _checkId,
}) =>
    <String, Object?>{
      'vendor_entity_id': entityId,
      'vendor_modified_at': modifiedAt,
      'opened_at': modifiedAt.subtract(const Duration(hours: 1)),
      'closed_at': modifiedAt,
      'covers': 3,
      'covers_source': 'direct',
      'actual_sales': 75.0,
      'raw_payload': const <String, Object?>{'source': 'test'},
    };

// ─── Tests ────────────────────────────────────────────────────────────

void main() {
  group('A1 idempotency hardening — cover_facts', () {
    test(
      'Bug 1 fix: same entity at different locations both survive '
      '(new key includes location_id)',
      () async {
        final pool = _FakePool()
          ..seedLocation(operatorId: _opA, locationId: _locX)
          ..seedLocation(operatorId: _opA, locationId: _locY)
          ..seedConnection(
            operatorId: _opA,
            locationId: _locX,
            connectionId: _connX,
          )
          ..seedConnection(
            operatorId: _opA,
            locationId: _locY,
            connectionId: _connY,
          );
        final sink = ToastPosPostgresSink(TenantTransactionWrapper(pool));

        // Write 1: op=A, loc=X, entity=check-1, modified=t1
        final insertedLocX = await sink.upsertCoverFact(
          operatorId: _opA,
          locationId: _locX,
          canonicalFact: _canonical(modifiedAt: _t1),
        );

        // Write 2: op=A, loc=Y, same entity id, same timestamp.
        // Under the OLD key (no location_id) this would conflict and
        // be silently dropped. Under the NEW key (with location_id)
        // it must land as a separate row.
        final insertedLocY = await sink.upsertCoverFact(
          operatorId: _opA,
          locationId: _locY,
          canonicalFact: _canonical(modifiedAt: _t1),
        );

        expect(insertedLocX, isTrue, reason: 'loc=X row must insert');
        expect(
          insertedLocY,
          isTrue,
          reason:
              'loc=Y row must insert; Bug 1 regression if false — '
              'loc=Y write was silently dropped by loc=X\'s conflict',
        );
        expect(
          pool.coverFacts,
          hasLength(2),
          reason: 'two distinct rows: one per location',
        );
        final locationIds = pool.coverFacts.values
            .map((r) => r['location_id'] as String)
            .toSet();
        expect(locationIds, containsAll(<String>[_locX, _locY]));
      },
    );

    test(
      'Newer correction updates in place (vendor_modified_at >= guard)',
      () async {
        final pool = _FakePool()
          ..seedLocation(operatorId: _opA, locationId: _locX)
          ..seedConnection(
            operatorId: _opA,
            locationId: _locX,
            connectionId: _connX,
          );
        final sink = ToastPosPostgresSink(TenantTransactionWrapper(pool));

        // Write 1: initial row with t1.
        await sink.upsertCoverFact(
          operatorId: _opA,
          locationId: _locX,
          canonicalFact: _canonical(modifiedAt: _t1),
        );

        // Write 3: same entity, newer modified (t2 > t1). Must update.
        final updatedNewer = await sink.upsertCoverFact(
          operatorId: _opA,
          locationId: _locX,
          canonicalFact: _canonical(modifiedAt: _t2),
        );

        expect(
          updatedNewer,
          isTrue,
          reason:
              'newer correction must fire the DO UPDATE and return '
              'RETURNING 1 (vendor_modified_at >= guard passes)',
        );
        expect(pool.coverFacts, hasLength(1), reason: 'still one row');
        final storedModified =
            pool.coverFacts.values.single['vendor_modified_at'] as DateTime;
        expect(
          storedModified,
          equals(_t2),
          reason: 'row must reflect the newer vendor_modified_at',
        );
      },
    );

    test(
      'Bug 2 fix: older backfill is rejected by the >= guard '
      '(closed truth is never overwritten by a stale correction)',
      () async {
        final pool = _FakePool()
          ..seedLocation(operatorId: _opA, locationId: _locX)
          ..seedConnection(
            operatorId: _opA,
            locationId: _locX,
            connectionId: _connX,
          );
        final sink = ToastPosPostgresSink(TenantTransactionWrapper(pool));

        // Write 1: initial row at t1.
        await sink.upsertCoverFact(
          operatorId: _opA,
          locationId: _locX,
          canonicalFact: _canonical(modifiedAt: _t1),
        );

        // Write 4: same entity, OLDER modified (t0 < t1). Must be ignored.
        final updatedOlder = await sink.upsertCoverFact(
          operatorId: _opA,
          locationId: _locX,
          canonicalFact: _canonical(modifiedAt: _t0),
        );

        expect(
          updatedOlder,
          isFalse,
          reason:
              'older backfill must be rejected; Bug 2 regression if true '
              '— late arrival rewrites the newer canonical truth',
        );
        expect(pool.coverFacts, hasLength(1), reason: 'still one row');
        final storedModified =
            pool.coverFacts.values.single['vendor_modified_at'] as DateTime;
        expect(
          storedModified,
          equals(_t1),
          reason: 'stored row must retain the original (newer) timestamp',
        );
      },
    );
  });
}

// ─── Fake Postgres pool ───────────────────────────────────────────────
//
// Enforces the NEW idempotency contract:
//   * Unique key: (operator_id, location_id, vendor_id, vendor_entity_id)
//   * On conflict: DO UPDATE SET ... WHERE excluded.vendor_modified_at >=
//     stored.vendor_modified_at
//     — returns RETURNING 1 when the update fires (>= passes)
//     — returns empty when the guard fails (< stored)

class _FakePool implements PostgresPool {
  final Map<String, Map<String, Object?>> _locations =
      <String, Map<String, Object?>>{};
  final Map<String, String> _connections = <String, String>{};

  /// Keyed by the NEW unique key:
  /// `(operator_id, location_id, vendor_id, vendor_entity_id)`.
  final Map<String, Map<String, Object?>> coverFacts =
      <String, Map<String, Object?>>{};

  final List<_FakeTransaction> _transactions = <_FakeTransaction>[];

  void seedLocation({
    required String operatorId,
    required String locationId,
  }) {
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
    _connections['$operatorId|$locationId|$kToastVendorId'] = connectionId;
  }

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeTransaction(this);
    _transactions.add(tx);
    return tx;
  }
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction(this._pool);

  final _FakePool _pool;
  bool committed = false;

  // ─── query ─────────────────────────────────────────────────────────

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) return const <PostgresRow>[];

    // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): the projector's
    // BusinessTimingProfilesRepository SELECT joins `from public.locations`
    // inside a CTE, so the projector handler MUST run BEFORE the
    // generic `from public.locations` handler.
    if (sql.contains('from public.business_timing_profiles p')) {
      return const <PostgresRow>[];
    }
    if (sql.contains('from public.locations')) {
      final opId = parameters['operator_id'] as String;
      final locId = parameters['location_id'] as String;
      final row = _pool._locations['$opId|$locId'];
      if (row == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'timezone': row['timezone'],
        },
      ];
    }

    if (sql.contains('from public.connector_connection')) {
      final opId = parameters['operator_id'] as String;
      final locId = parameters['location_id'] as String;
      final vendId = parameters['vendor_id'] as String;
      final connId = _pool._connections['$opId|$locId|$vendId'];
      if (connId == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{'connection_id': connId},
      ];
    }

    if (sql.contains('insert into public.cover_facts')) {
      // NEW conflict key: (operator_id, location_id, vendor_id, vendor_entity_id)
      final operatorId = parameters['operator_id'] as String;
      final locationId = parameters['location_id'] as String;
      final vendorId = parameters['vendor_id'] as String;
      final vendorEntityId = parameters['vendor_entity_id'] as String;
      final vendorModifiedAt = _parseUtc(parameters['vendor_modified_at']);
      final key = '$operatorId|$locationId|$vendorId|$vendorEntityId';

      final existing = _pool.coverFacts[key];
      if (existing == null) {
        // Fresh insert.
        _pool.coverFacts[key] = <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'vendor_entity_id': vendorEntityId,
          'vendor_modified_at': vendorModifiedAt,
          'covers': parameters['covers'],
          'covers_source': parameters['covers_source'],
          'opened_at': _parseUtc(parameters['opened_at']),
          'closed_at': _parseUtc(parameters['closed_at']),
          'business_date': parameters['business_date'],
          'actual_sales': parameters['actual_sales'],
          'raw_payload': parameters['raw_payload'],
        };
        return <PostgresRow>[
          <String, Object?>{'inserted': 1},
        ];
      }

      // Conflict — apply DO UPDATE WHERE excluded.vendor_modified_at >= stored.
      final storedModified = existing['vendor_modified_at'] as DateTime;
      if (vendorModifiedAt != null &&
          vendorModifiedAt.compareTo(storedModified) >= 0) {
        // Guard passes: update in place.
        existing['vendor_modified_at'] = vendorModifiedAt;
        existing['covers'] = parameters['covers'];
        existing['covers_source'] = parameters['covers_source'];
        existing['opened_at'] = _parseUtc(parameters['opened_at']);
        existing['closed_at'] = _parseUtc(parameters['closed_at']);
        existing['business_date'] = parameters['business_date'];
        existing['actual_sales'] = parameters['actual_sales'];
        existing['raw_payload'] = parameters['raw_payload'];
        return <PostgresRow>[
          <String, Object?>{'inserted': 1},
        ];
      }

      // Guard fails: older or null timestamp — reject silently (DO
      // UPDATE WHERE clause evaluates to false → no row touched →
      // RETURNING returns empty).
      return const <PostgresRow>[];
    }

    return const <PostgresRow>[];
  }

  // ─── execute ───────────────────────────────────────────────────────

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (sql.contains('select set_config(')) return 0;
    // Watermark, sync log, demo mode — no-op for this test.
    if (sql.contains('insert into public.connector_sync_watermark')) return 1;
    if (sql.contains('insert into public.connector_sync_log')) return 1;
    if (sql.contains('insert into public.demo_mode_state')) return 1;
    if (sql.contains('update public.demo_mode_state')) return 0;
    if (sql.contains('update public.vendor_credentials')) return 0;
    if (sql.contains('update public.connector_connection')) return 1;
    return 0;
  }

  // ─── transaction lifecycle ─────────────────────────────────────────

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {}

  // ─── helper ────────────────────────────────────────────────────────

  static DateTime? _parseUtc(Object? raw) {
    if (raw is DateTime) return raw.toUtc();
    if (raw is String && raw.isNotEmpty) {
      return DateTime.parse(raw).toUtc();
    }
    return null;
  }
}
