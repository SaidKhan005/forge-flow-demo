// Phase 8 Wave B `8.spine-bridge.1.OT` — OpenTable reservation
// Postgres sink.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) sub-lane `.1.OT`. Same fanout shape as `.1.LB` (Libro
// reservations) and `.1.OR` (Oracle MICROS Simphony POS): the sink
// IS the per-vendor gateway implementation the existing Wave B
// `OpenTableReservationAdapter` writes through, AND directly
// implements the unified [CanonicalSink] interface from `.0` so the
// sync worker dispatcher can route through one category-uniform
// surface.
//
// Layer authority (CLAUDE.md Authority Order):
//   * core_app_architecture.md Layer 2 (Canonical Facts) —
//     `reservation_facts` is the per-vendor canonical fact row that
//     aggregates into the `ReservationBookSnapshot` shape.
//   * integration_spine_architecture_contract.md "Postgres-backed
//     CanonicalSink" — operator-scoped writes via
//     [OperatorScopedRepository.withTenant], idempotency UNIQUE on
//     `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`,
//     watermark advance after each batch commit, demo-mode flip on
//     first batch with records >= 1.
//   * hardening_rls_and_repository_pattern_contract.md — repository
//     pattern is the primary tenant defense, RLS the backup.
//
// Hard-Promise alignment (CLAUDE.md):
//   * HP #1 (pure transport swap): writes hit the existing
//     `reservation_facts` columns plus the framework-added vendor
//     columns (vendor_id / vendor_entity_id / vendor_modified_at /
//     raw_payload) from migration `202605040000`. No business-logic
//     mutation.
//   * HP #4 (per-operator isolation): every method opens a tenant-
//     scoped transaction via [OperatorScopedRepository.withTenant],
//     which issues `set_config('app.operator_id', ..., true)` +
//     `app.location_id` so RLS policies on `reservation_facts` /
//     `connector_sync_watermark` / `connector_sync_log` /
//     `demo_mode_state` engage as the backup defense.
//   * HP #2 (demo mode persists post-launch): [evaluateDemoFlip]
//     uses an idempotent `INSERT ... ON CONFLICT DO UPDATE WHERE
//     is_demo` so the second arrival is a no-op and
//     `flipped_to_live_at` stays pinned to the first flip. Disconnect
//     does NOT auto-revert (this code does not write `is_demo = true`).
//
// V1 lean cut 2 alignment (memory/project_v1_lean_cut_2_2026_05_03.md):
// no KMS / production-key rotation surface, no `parse_warnings` /
// `parse_partial` columns, no 5-minute replay window, no advisory
// locks, no SIGTERM graceful drain, no dead-letter UI surface, no
// raw-payload sibling tables / pg_partman registration, no 5-second
// test SLA. Banned-grep test pins the ledger at the source-file
// level.

import 'dart:convert';

import '../../../integrations/reservation/opentable_reservation_adapter.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/integration_adapter_common.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// Resource string written into `connector_sync_watermark.resource`
/// for OpenTable. Mirrors the adapter's reservation stream identity
/// so the registry / sync worker / sink agree on one shared key.
const String openTableWatermarkResource = 'reservation.reservations';

/// Postgres-backed sink for OpenTable reservations.
///
/// Implements [OpenTableGateway] (the bespoke seam the Wave B
/// `OpenTableReservationAdapter` writes through) AND the unified
/// [CanonicalSink] (the sync-worker dispatch surface from `.0`). The
/// two surfaces share one tenant-scoped writer behind
/// [_insertReservationFact]; they differ only in the input shape:
///
///   * [OpenTableGateway.writeReservationFact] takes the typed
///     [OpenTableCanonicalReservationFact] the adapter materialises.
///   * [CanonicalSink.upsertReservationFact] takes the same shape as
///     a `Map<String, Object?>` so the worker can dispatch any
///     vendor's output through one method.
///
/// `connectionId` is widened where the bespoke and unified contracts
/// disagree on parameter sets. The bespoke gateway methods do not
/// carry a `connectionId` — the sink resolves it via
/// [_resolveConnectionId] from `connector_connection`. The unified
/// CanonicalSink methods receive an explicit `connectionId` from the
/// dispatcher and use it directly.
class OpenTableReservationPostgresSink extends OperatorScopedRepository
    implements OpenTableGateway, CanonicalSink {
  OpenTableReservationPostgresSink({
    required TenantTransactionWrapper tenantWrapper,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        super(tenantWrapper);

  final DateTime Function() _now;

  /// Per-(operator, location) counter of new fact-row inserts since
  /// the last watermark advance. Drives the auto demo-flip evaluator
  /// on watermark commit so the bespoke gateway path (which does not
  /// know about [evaluateDemoFlip]) still flips demo->live the first
  /// time a real reservation lands.
  final Map<String, int> _pendingInsertsByTenant = <String, int>{};

  String _tenantKey(String operatorId, String locationId) =>
      '$operatorId|$locationId';

  // ─── OpenTableGateway: connection lifecycle ───────────────────────

  @override
  Future<OpenTableConnectionRow> upsertConnection({
    required OpenTableConnectionRow row,
  }) {
    final ctx = TenantContext(
      operatorId: row.operatorId,
      locationId: row.locationId,
    );
    return withTenant<OpenTableConnectionRow>(ctx, (exec) async {
      final returned = await exec.query(
        'insert into public.connector_connection ('
        'operator_id, location_id, vendor_id, category, status, '
        'metadata, created_at, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, '
        '@category, @status, @metadata::jsonb, '
        '@now::timestamptz, @now::timestamptz'
        ') '
        'on conflict (operator_id, location_id, vendor_id) do update set '
        '  status = excluded.status, '
        '  metadata = excluded.metadata, '
        '  updated_at = excluded.updated_at '
        'returning connection_id::text as connection_id',
        parameters: <String, Object?>{
          'operator_id': row.operatorId,
          'location_id': row.locationId,
          'vendor_id': kOpenTableVendorId,
          'category': IntegrationCategory.reservation.name,
          'status': _statusToDb(row.status),
          'metadata': jsonEncode(row.toMetadata()),
          'now': _now().toUtc(),
        },
      );
      final storedId = returned.isEmpty
          ? row.connectionId
          : (returned.first['connection_id'] as String? ?? row.connectionId);
      return OpenTableConnectionRow(
        connectionId: storedId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        restaurantId: row.restaurantId,
        subscriptionId: row.subscriptionId,
        status: row.status,
      );
    });
  }

  @override
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'update public.vendor_credentials set '
        '  access_token_ciphertext = null, '
        '  refresh_token_ciphertext = null, '
        '  token_expires_at = null, '
        '  is_active = false, '
        '  updated_at = @now::timestamptz '
        'where operator_id = @operator_id::uuid '
        '  and (location_id = @location_id::uuid or location_id is null) '
        '  and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kOpenTableVendorId,
          'now': _now().toUtc(),
        },
      );
      await exec.execute(
        'update public.connector_connection set '
        "  status = 'disconnected', "
        '  updated_at = @now::timestamptz '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kOpenTableVendorId,
          'now': _now().toUtc(),
        },
      );
    });
  }

  @override
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'select access_token_ciphertext '
        'from public.vendor_credentials '
        'where operator_id = @operator_id::uuid '
        '  and (location_id = @location_id::uuid or location_id is null) '
        '  and vendor_id = @vendor_id '
        '  and is_active = true '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kOpenTableVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final value = rows.first['access_token_ciphertext'];
      if (value is String && value.isNotEmpty) return value;
      return null;
    });
  }

  @override
  Future<String?> readRestaurantId({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'select metadata '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kOpenTableVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final metadata = _coerceJsonObject(rows.first['metadata']);
      final value = metadata['restaurant_id'];
      if (value is String && value.isNotEmpty) return value;
      return null;
    });
  }

  // ─── OpenTableGateway: watermark read/write ───────────────────────

  @override
  Future<OpenTableWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<OpenTableWatermarkRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select cursor_token, last_modified_seen '
        'from public.connector_sync_watermark w '
        'join public.connector_connection cc '
        '  on cc.connection_id = w.connection_id '
        'where cc.operator_id = @operator_id::uuid '
        '  and cc.location_id = @location_id::uuid '
        '  and cc.vendor_id = @vendor_id '
        '  and w.resource = @resource '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kOpenTableVendorId,
          'resource': openTableWatermarkResource,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final cursor = row['cursor_token'] as String? ?? '';
      final lastSeen = row['last_modified_seen'];
      if (lastSeen is! DateTime) return null;
      return OpenTableWatermarkRow(
        cursorToken: cursor,
        lastModifiedSeen: lastSeen.toUtc(),
      );
    });
  }

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required OpenTableWatermarkRow row,
  }) async {
    final connectionId = await _resolveConnectionId(
      operatorId: operatorId,
      locationId: locationId,
    );
    await advanceWatermark(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      cursorToken: row.cursorToken,
      lastModifiedSeen: row.lastModifiedSeen,
    );
  }

  // ─── OpenTableGateway: canonical-fact write ───────────────────────

  @override
  Future<bool> writeReservationFact(
    OpenTableCanonicalReservationFact fact,
  ) async {
    final connectionId = await _resolveConnectionId(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
    );
    final ctx = TenantContext(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
    );
    final wrote = await withTenant<bool>(ctx, (exec) {
      return _insertReservationFact(
        exec: exec,
        operatorId: fact.operatorId,
        locationId: fact.locationId,
        connectionId: connectionId,
        vendorEntityId: fact.vendorEntityId,
        vendorModifiedAt: fact.vendorModifiedAt,
        reservationAt: fact.reservationAt,
        partySize: fact.partySize,
        rawStatus: fact.status,
        rawPayload: fact.rawPayload,
      );
    });
    if (wrote) {
      final key = _tenantKey(fact.operatorId, fact.locationId);
      _pendingInsertsByTenant[key] = (_pendingInsertsByTenant[key] ?? 0) + 1;
    }
    return wrote;
  }

  // ─── CanonicalSink: covers/labor unsupported, reservation upsert ──

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async =>
      false;

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async =>
      false;

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async {
    final connectionId = (canonicalReservation['connection_id'] as String?) ??
        await _resolveConnectionId(
          operatorId: operatorId,
          locationId: locationId,
        );
    final vendorEntityId =
        canonicalReservation['vendor_entity_id'] as String? ?? '';
    final vendorModifiedAt = _coerceUtc(canonicalReservation['vendor_modified_at']);
    final reservationAt = _coerceUtc(canonicalReservation['reservation_at']);
    final partySizeRaw = canonicalReservation['party_size'];
    final rawStatus = canonicalReservation['status'] as String? ?? '';
    if (vendorEntityId.isEmpty ||
        vendorModifiedAt == null ||
        reservationAt == null ||
        partySizeRaw is! num) {
      return false;
    }
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    final wrote = await withTenant<bool>(ctx, (exec) {
      return _insertReservationFact(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        vendorEntityId: vendorEntityId,
        vendorModifiedAt: vendorModifiedAt,
        reservationAt: reservationAt,
        partySize: partySizeRaw.toInt(),
        rawStatus: rawStatus,
        rawPayload: _coerceJsonObject(canonicalReservation['raw_payload']),
      );
    });
    if (wrote) {
      final key = _tenantKey(operatorId, locationId);
      _pendingInsertsByTenant[key] = (_pendingInsertsByTenant[key] ?? 0) + 1;
    }
    return wrote;
  }

  // ─── Shared private writer ────────────────────────────────────────

  /// One canonical reservation_facts insert. Idempotent on the partial
  /// UNIQUE `(operator_id, vendor_id, vendor_entity_id,
  /// vendor_modified_at)` from migration `202605040000`. Returns
  /// `true` when a new row landed, `false` when the upsert
  /// short-circuited.
  Future<bool> _insertReservationFact({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String vendorEntityId,
    required DateTime vendorModifiedAt,
    required DateTime reservationAt,
    required int partySize,
    required String rawStatus,
    required Map<String, Object?> rawPayload,
  }) async {
    final canonicalStatus = _normalizeStatus(rawStatus);
    final affected = await exec.execute(
      'insert into public.reservation_facts ('
      'operator_id, location_id, connection_id, '
      'vendor_id, vendor_entity_id, vendor_modified_at, '
      'reservation_at, business_date, party_size, status, '
      'seated_at, cancelled_at, raw_payload'
      ') values ('
      '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
      '@vendor_id, @vendor_entity_id, @vendor_modified_at::timestamptz, '
      '@reservation_at::timestamptz, @business_date::date, '
      '@party_size, @status, '
      '@seated_at, @cancelled_at, @raw_payload::jsonb'
      ') '
      'on conflict (operator_id, vendor_id, vendor_entity_id, '
      'vendor_modified_at) do nothing',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'vendor_id': kOpenTableVendorId,
        'vendor_entity_id': vendorEntityId,
        'vendor_modified_at': vendorModifiedAt.toUtc(),
        'reservation_at': reservationAt.toUtc(),
        'business_date': _formatDate(reservationAt.toUtc()),
        'party_size': partySize,
        'status': canonicalStatus,
        'seated_at':
            canonicalStatus == 'seated' ? vendorModifiedAt.toUtc() : null,
        'cancelled_at':
            canonicalStatus == 'cancelled' ? vendorModifiedAt.toUtc() : null,
        'raw_payload': jsonEncode(rawPayload),
      },
    );
    return affected >= 1;
  }

  // ─── CanonicalSink: watermark / sync log / demo flip ──────────────

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    await withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_sync_watermark ('
        'operator_id, location_id, connection_id, resource, '
        'cursor_token, last_modified_seen, last_synced_at, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@resource, @cursor_token, '
        '@last_modified_seen::timestamptz, '
        '@last_synced_at::timestamptz, @updated_at::timestamptz'
        ') '
        'on conflict (connection_id, resource) do update set '
        '  cursor_token = excluded.cursor_token, '
        '  last_modified_seen = excluded.last_modified_seen, '
        '  last_synced_at = excluded.last_synced_at, '
        '  updated_at = excluded.updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'resource': openTableWatermarkResource,
          'cursor_token': cursorToken,
          'last_modified_seen': lastModifiedSeen.toUtc(),
          'last_synced_at': _now().toUtc(),
          'updated_at': _now().toUtc(),
        },
      );
    });

    final key = _tenantKey(operatorId, locationId);
    final pending = _pendingInsertsByTenant.remove(key) ?? 0;
    if (pending >= 1) {
      await evaluateDemoFlip(
        operatorId: operatorId,
        locationId: locationId,
        category: IntegrationCategory.reservation,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: pending,
        connectionId: connectionId,
      );
    }
  }

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'records_count, error_message, payload_preview, occurred_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@event_kind, @records_count, @error_message, '
        '@payload_preview::jsonb, @occurred_at::timestamptz'
        ')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'event_kind': eventKind,
          'records_count': recordsCount,
          'error_message': errorMessage,
          'payload_preview':
              payloadPreview == null ? null : jsonEncode(payloadPreview),
          'occurred_at': _now().toUtc(),
        },
      );
    });
  }

  @override
  Future<void> evaluateDemoFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required ConnectionStatus connectionStatus,
    required bool firstBackfillCommitted,
    required int backfillRecordsWritten,
    required String connectionId,
  }) {
    if (category != IntegrationCategory.reservation) {
      return Future<void>.value();
    }
    if (connectionStatus != ConnectionStatus.connected ||
        !firstBackfillCommitted ||
        backfillRecordsWritten < 1) {
      return Future<void>.value();
    }
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.demo_mode_state ('
        'operator_id, location_id, category, is_demo, '
        'flipped_to_live_at, flipped_by_connection_id, '
        'created_at, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @category, false, '
        '@flipped_at::timestamptz, @connection_id::uuid, '
        '@now::timestamptz, @now::timestamptz'
        ') '
        'on conflict (operator_id, location_id, category) do update set '
        '  is_demo = false, '
        '  flipped_to_live_at = case '
        '    when public.demo_mode_state.is_demo then excluded.flipped_to_live_at '
        '    else public.demo_mode_state.flipped_to_live_at end, '
        '  flipped_by_connection_id = case '
        '    when public.demo_mode_state.is_demo then excluded.flipped_by_connection_id '
        '    else public.demo_mode_state.flipped_by_connection_id end, '
        '  updated_at = excluded.updated_at '
        'where public.demo_mode_state.is_demo',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': IntegrationCategory.reservation.name,
          'flipped_at': _now().toUtc(),
          'connection_id': connectionId,
          'now': _now().toUtc(),
        },
      );
    });
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  /// Resolve `connector_connection.connection_id` for the
  /// `(operator_id, location_id, vendor_id='opentable')` triple.
  /// Bespoke gateway methods do not carry the id; the production
  /// dispatcher path passes it in. Throws when no row exists — connect
  /// must run before sink writes.
  Future<String> _resolveConnectionId({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'select connection_id::text as connection_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kOpenTableVendorId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'connector_connection row not found for '
          '(operator=$operatorId, location=$locationId, '
          'vendor=$kOpenTableVendorId) — connect must run before sink writes',
        );
      }
      final id = rows.single['connection_id'];
      if (id is! String || id.isEmpty) {
        throw StateError(
          'connector_connection.connection_id has unexpected shape',
        );
      }
      return id;
    });
  }

  static DateTime? _coerceUtc(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return raw.toUtc();
    if (raw is String && raw.isNotEmpty) {
      return DateTime.tryParse(raw)?.toUtc();
    }
    return null;
  }

  static Map<String, Object?> _coerceJsonObject(Object? raw) {
    if (raw == null) return const <String, Object?>{};
    if (raw is Map<String, Object?>) return raw;
    if (raw is Map) return raw.cast<String, Object?>();
    if (raw is String && raw.isNotEmpty) {
      final decoded = json.decode(raw);
      if (decoded is Map) return decoded.cast<String, Object?>();
    }
    return const <String, Object?>{};
  }

  /// Map the OpenTable vendor status string to V1 storage vocabulary
  /// on `reservation_facts.status`. OpenTable enum (assumed,
  /// `verify_in_live_sandbox: true`): {booked, seated, completed,
  /// no_show, cancelled}. Anything outside the V1 column vocabulary
  /// lands on `'unknown'` so the dashboard renders a not-yet-available
  /// state instead of inventing a wrong terminal status.
  static String _normalizeStatus(String raw) {
    switch (raw.toLowerCase()) {
      case 'booked':
      case 'confirmed':
        return 'confirmed';
      case 'seated':
        return 'seated';
      case 'cancelled':
      case 'canceled':
        return 'cancelled';
      case 'no_show':
      case 'noshow':
        return 'no_show';
      default:
        return 'unknown';
    }
  }

  static String _statusToDb(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return 'connected';
      case ConnectionStatus.disconnected:
        return 'disconnected';
      case ConnectionStatus.error:
        return 'error';
    }
  }

  static String _formatDate(DateTime value) {
    final utc = value.toUtc();
    final yyyy = utc.year.toString().padLeft(4, '0');
    final mm = utc.month.toString().padLeft(2, '0');
    final dd = utc.day.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd';
  }
}
