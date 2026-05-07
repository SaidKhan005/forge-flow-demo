// Phase 8 Wave B `8.spine-bridge-sink-fanout.OT` — OpenTable reservation
// Postgres sink.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// "The canonical chain (binding)" / "Postgres-backed CanonicalSink".
// Mirrors the SevenRooms (`.SR`) and Tock (`.TC`) reservation sink
// shape: the sink IS the per-vendor [OpenTableGateway] implementation
// the existing Wave B `OpenTableReservationAdapter` writes through, AND
// composes the unified [CanonicalSink] surface from `.0` so the sync
// worker can dispatch through a category-uniform method.
//
// Layer authority (CLAUDE.md Authority Order):
//   * core_app_architecture.md Layer 2 (Canonical Facts) —
//     `reservation_facts` is the per-vendor canonical fact row that
//     aggregates into the `ReservationBookSnapshot` shape.
//   * integration_spine_architecture_contract.md "Postgres-backed
//     CanonicalSink" — operator-scoped writes via
//     [OperatorScopedRepository.withTenant], idempotency UNIQUE on
//     `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`,
//     watermark advance after each batch commit, demo-mode flip on the
//     first batch with records >= 1.
//   * hardening_rls_and_repository_pattern_contract.md — repository
//     pattern is the primary tenant defense, RLS the backup.
//
// Hard-Promise alignment (CLAUDE.md):
//   * HP #1 (pure transport swap): writes hit the existing
//     `reservation_facts` columns plus the framework-added vendor
//     columns (`vendor_id` / `vendor_entity_id` / `vendor_modified_at`
//     / `raw_payload`) from migration `202605040000`. No business-logic
//     mutation.
//   * HP #4 (per-operator isolation): every public method opens a
//     tenant-scoped transaction via
//     [OperatorScopedRepository.withTenant], which issues
//     `select set_config('app.operator_id', ..., true)` +
//     `app.location_id` so RLS engages as the backup defense.
//   * HP #2 (demo mode persists post-launch): [markReservationsLive]
//     uses an idempotent `INSERT ... ON CONFLICT DO UPDATE WHERE
//     is_demo` so the second arrival is a no-op and `flipped_to_live_at`
//     stays pinned to the first flip. Disconnect does NOT auto-revert.
//
// 2026-05-04 falsehood correction (mirrors the Tock `.TC` policy):
// OpenTable's documented Partner reservation envelope (and the
// industry-standard reservation envelope F&F engineers against until
// partnership clears — see
// `lib/integrations/reservation/opentable_reservation_adapter.dart`
// `documentedPerOpentableV1FieldMapping`) carries one `status` enum
// per reservation but does NOT expose per-status transition
// timestamps (`seated_at`, `cancelled_at`). The adapter's
// `_canonicalize` does not project them and
// [OpenTableCanonicalReservationFact] does not carry them. The sink
// therefore writes the `seated_at` and `cancelled_at` columns as SQL
// `null` literals, never reading a synthesised value from the
// canonical-fact map. Test G grep enforces; the column names appear
// only inside the SQL string of the INSERT statement.
//
// V1 lean cut 2 alignment (memory/project_v1_lean_cut_2_2026_05_03.md):
// no KMS / production-key rotation surface, no `parse_warnings` /
// `parse_partial` columns, no 5-minute replay window, no advisory
// locks, no SIGTERM graceful drain, no dead-letter UI surface, no
// raw-payload sibling tables / pg_partman registration, no 5-second
// test SLA. Banned-grep in
// `opentable_reservation_postgres_sink_test.dart` enforces.

import 'dart:convert';

import '../../../integrations/reservation/opentable_reservation_adapter.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// Stable resource string written to `connector_sync_watermark.resource`
/// for the OpenTable reservations stream. Aligns with the OpenTable
/// adapter's pull endpoint family (`/v1/reservations/search`).
const String kOpenTableWatermarkResource = 'reservation.reservations';

/// Postgres-backed sink for OpenTable reservations.
///
/// Implements [OpenTableGateway] (the bespoke seam the Wave B
/// `OpenTableReservationAdapter` writes through) and exposes a composed
/// [CanonicalSink] view via [asCanonicalSink] for the sync worker
/// dispatch from `.0`.
///
/// Both surfaces share one tenant-wrapped engine: a single private SQL
/// writer drives the `reservation_facts` upsert, and the bespoke
/// gateway methods translate domain types into the same writer the
/// CanonicalSink view drives from a `Map<String, Object?>`.
class OpenTableReservationPostgresSink extends OperatorScopedRepository
    implements OpenTableGateway {
  OpenTableReservationPostgresSink({
    required TenantTransactionWrapper tenantWrapper,
    IanaTimezoneConverter? timezoneConverter,
    DateTime Function()? now,
  })  : _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared,
        _now = now ?? DateTime.now,
        super(tenantWrapper);

  final IanaTimezoneConverter _timezoneConverter;
  final DateTime Function() _now;

  // ─── OpenTableGateway: connect lifecycle ─────────────────────────────

  @override
  Future<OpenTableConnectionRow> upsertConnection({
    required OpenTableConnectionRow row,
  }) {
    final ctx = TenantContext(
      operatorId: row.operatorId,
      locationId: row.locationId,
    );
    return withTenant<OpenTableConnectionRow>(ctx, (exec) async {
      // vendor_credentials is intentionally NOT written here. The
      // OpenTableGateway interface carries no credential ciphertext and
      // `vendor_credentials.credential_id` is a `uuid` primary key that
      // requires a real proxy-issued id. The credential row is written
      // by the adapter's connect path through the credential gateway
      // (proxy + KMS envelope), not by this sink — mirroring SR / Tock,
      // which take `accessTokenCredentialId` as an explicit parameter
      // when they do touch vendor_credentials.
      await exec.execute(
        'insert into public.connector_connection ('
        'operator_id, location_id, vendor_id, category, status, '
        'metadata, created_at, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, @category, '
        '@status, @metadata::jsonb, now(), now()'
        ') '
        'on conflict (operator_id, location_id, vendor_id) do update set '
        '  status = excluded.status, '
        '  metadata = excluded.metadata, '
        '  updated_at = now()',
        parameters: <String, Object?>{
          'operator_id': row.operatorId,
          'location_id': row.locationId,
          'vendor_id': kOpenTableVendorId,
          'category': IntegrationCategory.reservation.name,
          'status': row.status.name,
          'metadata': json.encode(row.toMetadata()),
        },
      );
      return row;
    });
  }

  // ─── OpenTableGateway: watermark read / write ────────────────────────

  @override
  Future<OpenTableWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<OpenTableWatermarkRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select w.cursor_token, w.last_modified_seen '
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
          'resource': kOpenTableWatermarkResource,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final cursor = row['cursor_token'] as String?;
      final lastModified = row['last_modified_seen'] as DateTime?;
      if (lastModified == null) return null;
      return OpenTableWatermarkRow(
        cursorToken: cursor ?? '',
        lastModifiedSeen: lastModified.toUtc(),
      );
    });
  }

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required OpenTableWatermarkRow row,
  }) async {
    final tenant = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(tenant, (exec) async {
      final connectionId = await _resolveConnectionIdInTx(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
      );
      await _writeWatermark(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        resource: kOpenTableWatermarkResource,
        cursorToken: row.cursorToken,
        lastModifiedSeen: row.lastModifiedSeen.toUtc(),
      );
    });
  }

  Future<void> _writeWatermark({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String resource,
    required String? cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    await exec.execute(
      'insert into public.connector_sync_watermark ('
      'operator_id, location_id, connection_id, resource, '
      'cursor_token, last_modified_seen, last_synced_at, updated_at'
      ') values ('
      '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
      '@resource, @cursor_token, @last_modified_seen, now(), now()'
      ') '
      'on conflict (connection_id, resource) do update set '
      '  cursor_token = excluded.cursor_token, '
      '  last_modified_seen = excluded.last_modified_seen, '
      '  last_synced_at = now(), '
      '  updated_at = now()',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'resource': resource,
        'cursor_token': cursorToken,
        'last_modified_seen': lastModifiedSeen,
      },
    );
  }

  // ─── OpenTableGateway: canonical-fact write ──────────────────────────

  @override
  Future<bool> writeReservationFact(
    OpenTableCanonicalReservationFact fact,
  ) {
    final tenant = TenantContext(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
    );
    return withTenant<bool>(tenant, (exec) async {
      // Resolve the per-restaurant timezone + rollover hour from
      // `public.locations`. The sink mirrors the Tock / SR pattern of
      // pulling the projection settings inside the same tenant
      // transaction as the write so a tenant cannot read another
      // operator's location settings.
      final locationRows = await exec.query(
        'select timezone, business_day_rollover_hour '
        'from public.locations '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': fact.operatorId,
          'location_id': fact.locationId,
        },
      );
      final restaurantTimezone = locationRows.isNotEmpty
          ? ((locationRows.single['timezone'] as String?) ?? 'UTC')
          : 'UTC';
      final rolloverHour = locationRows.isNotEmpty
          ? ((locationRows.single['business_day_rollover_hour'] as int?) ?? 0)
          : 0;
      final businessDate = _timezoneConverter.toBusinessDate(
        restaurantTimezone: restaurantTimezone,
        businessDayRolloverHour: rolloverHour,
        instant: fact.reservationAt.toUtc(),
      );

      final connectionId = await _resolveConnectionIdInTx(
        exec: exec,
        operatorId: fact.operatorId,
        locationId: fact.locationId,
      );

      // OpenTable's documented envelope carries one `status` enum but
      // no per-status transition timestamps. The sink writes both
      // status-transition columns as SQL `null` literals (mirrored
      // from the Tock policy) — never as Dart parameter-map values.
      // The canonical fact's `rawPayload` round-trips intact for the
      // dashboard read path.
      final affected = await exec.execute(
        'insert into public.reservation_facts ('
        'operator_id, location_id, connection_id, '
        'vendor_id, vendor_entity_id, vendor_modified_at, '
        'reservation_at, business_date, party_size, status, '
        'seated_at, cancelled_at, raw_payload'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@vendor_id, @vendor_entity_id, @vendor_modified_at::timestamptz, '
        '@reservation_at::timestamptz, @business_date::date, @party_size, '
        '@status, null, null, @raw_payload::jsonb'
        ') '
        'on conflict (operator_id, vendor_id, vendor_entity_id, vendor_modified_at) '
        'do nothing',
        parameters: <String, Object?>{
          'operator_id': fact.operatorId,
          'location_id': fact.locationId,
          'connection_id': connectionId,
          'vendor_id': kOpenTableVendorId,
          'vendor_entity_id': fact.vendorEntityId,
          'vendor_modified_at': fact.vendorModifiedAt.toUtc(),
          'reservation_at': fact.reservationAt.toUtc(),
          'business_date': _formatDate(businessDate),
          'party_size': fact.partySize,
          'status': _columnStatusFor(fact.status),
          'raw_payload': json.encode(fact.rawPayload),
        },
      );
      return affected >= 1;
    });
  }

  // ─── OpenTableGateway: credential wipe (no status flip here) ─────────

  /// Wipe the credential ciphertext only. The OpenTable gateway
  /// interface separates credential wipe from the
  /// `connector_connection.status` flip — the adapter's `disconnect`
  /// path orchestrates revoke + unregister-webhook + this wipe, and
  /// the connector status flip is handled by the framework (mirrors
  /// the SR/SR-style separation but keeps the connection row intact
  /// so reconnect resumes from the last persisted cursor).
  @override
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      // Look up the connection ids tied to (operator, location, vendor)
      // and wipe ciphertext for each. Watermark survives by design.
      final rows = await exec.query(
        'select connection_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kOpenTableVendorId,
        },
      );
      for (final row in rows) {
        final connectionId = row['connection_id'] as String?;
        if (connectionId == null) continue;
        await exec.execute(
          'delete from public.vendor_credentials '
          'where connection_id = @connection_id::uuid '
          '  and operator_id = @operator_id::uuid',
          parameters: <String, Object?>{
            'connection_id': connectionId,
            'operator_id': operatorId,
          },
        );
      }
    });
  }

  // ─── OpenTableGateway: read paths used by adapter ────────────────────

  @override
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'select vc.credential_id '
        'from public.vendor_credentials vc '
        'join public.connector_connection cc '
        '  on cc.connection_id = vc.connection_id '
        'where cc.operator_id = @operator_id::uuid '
        '  and cc.location_id = @location_id::uuid '
        '  and cc.vendor_id = @vendor_id '
        "  and cc.status = 'connected' "
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kOpenTableVendorId,
        },
      );
      if (rows.isEmpty) return null;
      return rows.single['credential_id'] as String?;
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
      final metadata = _coerceJsonObject(rows.single['metadata']);
      final rid = metadata['restaurant_id'];
      return rid?.toString();
    });
  }

  // ─── connector_sync_log append (used by the unified view) ────────────

  Future<void> _writeSyncLog({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
    Map<String, Object?>? payloadPreview,
  }) async {
    await exec.execute(
      'insert into public.connector_sync_log ('
      'operator_id, location_id, connection_id, event_kind, '
      'records_count, error_message, payload_preview, occurred_at'
      ') values ('
      '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
      '@event_kind, @records_count, @error_message, '
      '@payload_preview::jsonb, now()'
      ')',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'event_kind': eventKind,
        'records_count': recordsCount,
        'error_message': errorMessage,
        'payload_preview': encodePayloadPreviewForSyncLog(payloadPreview),
      },
    );
  }

  // ─── Demo-mode flip (reservation category) ───────────────────────────

  /// Idempotent demo→live flip on the reservation channel. The
  /// `WHERE public.demo_mode_state.is_demo` guard on the update branch
  /// makes the second call a no-op: `flipped_to_live_at` stays pinned
  /// to the first flip and `flipped_by_connection_id` is preserved
  /// per the policy contract in
  /// `lib/services/integration/demo_mode_state.dart`. Disconnect does
  /// NOT call this method (no auto-revert by design).
  Future<void> markReservationsLive({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.demo_mode_state ('
        'operator_id, location_id, category, is_demo, '
        'flipped_to_live_at, flipped_by_connection_id, '
        'created_at, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @category, false, '
        '@flipped_at, @connection_id::uuid, now(), now()'
        ') '
        'on conflict (operator_id, location_id, category) do update set '
        '  is_demo = false, '
        '  flipped_to_live_at = case '
        '    when public.demo_mode_state.is_demo then excluded.flipped_to_live_at '
        '    else public.demo_mode_state.flipped_to_live_at end, '
        '  flipped_by_connection_id = case '
        '    when public.demo_mode_state.is_demo then excluded.flipped_by_connection_id '
        '    else public.demo_mode_state.flipped_by_connection_id end, '
        '  updated_at = now() '
        'where public.demo_mode_state.is_demo',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': IntegrationCategory.reservation.name,
          'flipped_at': _now().toUtc(),
          'connection_id': connectionId,
        },
      );
    });
  }

  // ─── Internal: tenant resolution from connection-id ──────────────────

  /// Resolve the `(operator_id, location_id)` tuple bound to
  /// [connectionId] via a system-scoped lookup against
  /// `public.connector_connection`. Mirrors the SR sink's shape so
  /// future bespoke surfaces that only carry a `connectionId` (e.g.
  /// once the OpenTable adapter widens its watermark/sync-log seams)
  /// can recover the tenant pair before the actual write runs under
  /// [OperatorScopedRepository.withTenant]. Reserved for that future
  /// seam; the V1 `OpenTableGateway` carries `(operatorId, locationId)`
  /// on every call so the helper is kept for symmetry with the spine
  /// fanout family.
  // ignore: unused_element
  Future<TenantContext> _resolveTenantForConnection(
    String connectionId,
  ) async {
    return withSystem<TenantContext>(
      (exec) async {
        final rows = await exec.query(
          'select operator_id, location_id from public.connector_connection '
          'where connection_id = @connection_id::uuid '
          '  and vendor_id = @vendor_id '
          'limit 1',
          parameters: <String, Object?>{
            'connection_id': connectionId,
            'vendor_id': kOpenTableVendorId,
          },
        );
        if (rows.isEmpty) {
          throw StateError(
            'OpenTableReservationPostgresSink could not resolve tenant for '
            'connection_id=$connectionId; the connector_connection row is '
            'missing or not bound to vendor_id=$kOpenTableVendorId.',
          );
        }
        final row = rows.single;
        return TenantContext(
          operatorId: row['operator_id']! as String,
          locationId: row['location_id']! as String,
        );
      },
      reason: 'opentable.sink.resolve_tenant_for_connection',
    );
  }

  /// Resolve the `connector_connection.connection_id` bound to
  /// `(operatorId, locationId, vendor=opentable)` inside the caller's
  /// tenant transaction. Mirrors the Tock pattern: the SELECT runs
  /// under the same `set_config('app.operator_id', ...)` scope as the
  /// subsequent write so RLS engages as the backup defense.
  Future<String> _resolveConnectionIdInTx({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
  }) async {
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
      throw StateError('connector_connection.connection_id is malformed');
    }
    return id;
  }

  // ─── CanonicalSink composition view ──────────────────────────────────

  /// Expose the unified [CanonicalSink] surface the sync worker
  /// dispatch (from `.0`) speaks. The same tenant-wrapped engine backs
  /// both the bespoke [OpenTableGateway] surface and this view; they
  /// differ only in the input shape.
  CanonicalSink asCanonicalSink({
    required String Function(String operatorId, String locationId)
        connectionIdResolver,
  }) {
    return _OpenTableCanonicalSinkView(
      sink: this,
      connectionIdResolver: connectionIdResolver,
    );
  }
}

/// Adapter that exposes [OpenTableReservationPostgresSink] through the
/// unified [CanonicalSink] surface declared in `.0`.
///
/// Cover / labor methods return `false`: the OpenTable adapter's
/// category is [IntegrationCategory.reservation] only and the registry
/// never routes a non-reservation fact to this sink. Per the fanout
/// slice contract, [upsertCoverFact] and [upsertLaborPunch] return
/// `false` (the dispatcher's category gate is the primary router; this
/// sink simply refuses to absorb the misrouted batch).
class _OpenTableCanonicalSinkView implements CanonicalSink {
  _OpenTableCanonicalSinkView({
    required this.sink,
    required this.connectionIdResolver,
  });

  final OpenTableReservationPostgresSink sink;
  final String Function(String operatorId, String locationId)
      connectionIdResolver;

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
  }) {
    final vendorEntityId =
        canonicalReservation['vendor_entity_id']! as String;
    final vendorModifiedAt =
        _coerceInstant(canonicalReservation['vendor_modified_at'])!;
    final reservationAt =
        _coerceInstant(canonicalReservation['reservation_at'])!;
    final partySize =
        (canonicalReservation['party_size']! as num).toInt();
    final status =
        (canonicalReservation['status'] as String?) ?? '';
    final rawPayloadRaw = canonicalReservation['raw_payload'];
    final rawPayload = rawPayloadRaw is Map
        ? rawPayloadRaw.cast<String, Object?>()
        : const <String, Object?>{};
    return sink.writeReservationFact(
      OpenTableCanonicalReservationFact(
        operatorId: operatorId,
        locationId: locationId,
        vendorEntityId: vendorEntityId,
        vendorModifiedAt: vendorModifiedAt,
        reservationAt: reservationAt,
        partySize: partySize,
        status: status,
        rawPayload: rawPayload,
      ),
    );
  }

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return sink.withTenant<void>(ctx, (exec) async {
      await sink._writeWatermark(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        resource: kOpenTableWatermarkResource,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen.toUtc(),
      );
    });
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
    return sink.withTenant<void>(ctx, (exec) async {
      await sink._writeSyncLog(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        eventKind: eventKind,
        recordsCount: recordsCount,
        errorMessage: errorMessage,
        payloadPreview: payloadPreview,
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
  }) async {
    if (category != IntegrationCategory.reservation) return;
    if (connectionStatus != ConnectionStatus.connected) return;
    if (!firstBackfillCommitted) return;
    if (backfillRecordsWritten < 1) return;
    await sink.markReservationsLive(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
  }
}

// ─── Internal helpers ────────────────────────────────────────────────

/// Project the canonical OpenTable status string to the V1 storage
/// vocabulary on `reservation_facts.status`. The adapter's
/// `_canonicalize` lower-cases the vendor `status` enum; vendor values
/// that fall outside the V1 column vocabulary land on `'unknown'` so
/// the dashboard renders a `MetricCardNotYetAvailable`-equivalent
/// state without inventing a wrong terminal state. `cancelled`
/// round-trips intact even though the column does not carry a
/// per-transition timestamp.
String _columnStatusFor(String canonicalStatus) {
  switch (canonicalStatus) {
    case 'booked':
    case 'confirmed':
      return 'confirmed';
    case 'seated':
      return 'seated';
    case 'cancelled':
    case 'canceled':
      return 'cancelled';
    case 'no_show':
      return 'no_show';
    case 'completed':
      return 'unknown';
  }
  return 'unknown';
}

DateTime? _coerceInstant(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.toUtc();
  if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw)?.toUtc();
  return null;
}

Map<String, Object?> _coerceJsonObject(Object? raw) {
  if (raw == null) return const <String, Object?>{};
  if (raw is Map<String, Object?>) return raw;
  if (raw is Map) return raw.cast<String, Object?>();
  if (raw is String && raw.isNotEmpty) {
    final decoded = json.decode(raw);
    if (decoded is Map) return decoded.cast<String, Object?>();
  }
  return const <String, Object?>{};
}

String _formatDate(DateTime value) {
  final utc = value.toUtc();
  final yyyy = utc.year.toString().padLeft(4, '0');
  final mm = utc.month.toString().padLeft(2, '0');
  final dd = utc.day.toString().padLeft(2, '0');
  return '$yyyy-$mm-$dd';
}
