// Phase 8 Wave B `8.spine-bridge.fanout.SR` — SevenRooms reservation
// Postgres sink.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// "The canonical chain (binding)" / "Postgres-backed CanonicalSink".
// Mirrors the sub-lane `.1.LB` (Libro reservation Postgres sink) shape:
// the sink IS the per-vendor gateway implementation the existing Wave B
// `SevenRoomsReservationAdapter` writes through, AND composes the
// unified [CanonicalSink] interface from `.0` so the sync worker can
// dispatch through a category-uniform surface.
//
// Layer authority (CLAUDE.md Authority Order):
//   * core_app_architecture.md Layer 2 (Canonical Facts) — `reservation_facts`
//     is the per-vendor canonical fact row that aggregates into the
//     `ReservationBookSnapshot` shape.
//   * integration_spine_architecture_contract.md "Postgres-backed
//     CanonicalSink" — operator-scoped writes via
//     [OperatorScopedRepository.withTenant], idempotency UNIQUE on
//     `(vendor_id, operator_id, vendor_entity_id, vendor_modified_at)`,
//     watermark advance after each batch commit, demo-mode flip on first
//     batch with records >= 1.
//   * hardening_rls_and_repository_pattern_contract.md — repository
//     pattern is the primary tenant defense, RLS the backup.
//
// Hard-Promise alignment (CLAUDE.md):
//   * HP #1 (pure transport swap): writes hit the existing
//     `reservation_facts` columns plus the framework-added vendor columns
//     (vendor_id / vendor_entity_id / vendor_modified_at / raw_payload)
//     from migration `202605040000`. No business-logic mutation.
//   * HP #4 (per-operator isolation): every fact-row / watermark /
//     sync-log / demo-flip write opens a tenant-scoped transaction via
//     [OperatorScopedRepository.withTenant], which issues
//     `set_config('app.operator_id', ..., true)` + `app.location_id`
//     so RLS policies on `reservation_facts` / `connector_sync_watermark`
//     / `connector_sync_log` / `demo_mode_state` engage as the backup
//     defense.
//   * HP #2 (demo mode persists post-launch): [markReservationsLive]
//     uses an idempotent `INSERT ... ON CONFLICT DO UPDATE WHERE is_demo`
//     so the second arrival is a no-op and `flipped_to_live_at` stays
//     pinned to the first flip. Disconnect does NOT auto-revert.
//
// Connection-id widening: the bespoke
// [SevenRoomsReservationGateway.updateWatermark] /
// [SevenRoomsReservationGateway.appendSyncLog] surfaces only carry
// `connectionId` (no operator/location). The sink resolves the
// `(operator_id, location_id)` tuple by reading the
// `public.connector_connection` row keyed on `connection_id` via a
// system-scoped lookup, then performs the actual write inside the
// tenant-scoped transaction so RLS engages as the backup defense.
//
// V1 lean cut 2 alignment (memory/project_v1_lean_cut_2_2026_05_03.md):
// no KMS / production-key rotation surface, no `parse_warnings` /
// `parse_partial` columns, no 5-minute replay window, no advisory locks,
// no SIGTERM graceful drain, no dead-letter UI surface, no raw-payload
// sibling tables / pg_partman registration, no 5-second test SLA.

import 'dart:convert';

import '../../../integrations/reservation/sevenrooms_reservation_adapter.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// Stable resource string written to `connector_sync_watermark.resource`
/// for the SevenRooms reservations stream. Aligns with the SevenRooms
/// adapter's pull endpoint family (`/2_2/reservations[/export]`).
const String sevenRoomsWatermarkResource = 'reservation.reservations';

/// Postgres-backed sink for SevenRooms reservations.
///
/// Implements [SevenRoomsReservationGateway] (the bespoke seam the Wave B
/// `SevenRoomsReservationAdapter` writes through) and exposes a composed
/// [CanonicalSink] view via [asCanonicalSink] for the sync worker
/// dispatch from `.0`.
///
/// The two surfaces share one tenant-wrapped engine: a single private
/// SQL writer drives the `reservation_facts` upsert, and the bespoke
/// gateway methods translate domain types into the same writer the
/// CanonicalSink view drives from a `Map<String, Object?>`.
class SevenRoomsReservationPostgresSink extends OperatorScopedRepository
    implements SevenRoomsReservationGateway {
  SevenRoomsReservationPostgresSink({
    required TenantTransactionWrapper tenantWrapper,
    IanaTimezoneConverter? timezoneConverter,
    DateTime Function()? now,
  })  : _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared,
        _now = now ?? DateTime.now,
        super(tenantWrapper);

  final IanaTimezoneConverter _timezoneConverter;
  final DateTime Function() _now;

  // ─── SevenRoomsReservationGateway: connection lookups ─────────────

  @override
  Future<SevenRoomsConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      final rows = await exec.query(
        'select cc.connection_id, cc.metadata, vc.credential_id '
        'from public.connector_connection cc '
        'left join public.vendor_credentials vc '
        '  on vc.connection_id = cc.connection_id '
        'where cc.operator_id = @operator_id::uuid '
        '  and cc.location_id = @location_id::uuid '
        '  and cc.vendor_id = @vendor_id '
        "  and cc.status = 'connected' "
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kSevenRoomsVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final credentialId = row['credential_id'] as String?;
      if (credentialId == null) return null;
      final metadata = _coerceJsonObject(row['metadata']);
      final venueId = metadata['venue_id'] as String?;
      if (venueId == null) return null;
      return SevenRoomsConnectionBinding(
        connectionId: row['connection_id']! as String,
        venueId: venueId,
        accessTokenCredentialId: credentialId,
      );
    });
  }

  @override
  Future<SevenRoomsDisconnectBinding?> lookupDisconnectBinding({
    required String operatorId,
    required String locationId,
  }) async {
    final binding =
        await lookupBinding(operatorId: operatorId, locationId: locationId);
    if (binding == null) return null;
    return SevenRoomsDisconnectBinding(
      connectionId: binding.connectionId,
      venueId: binding.venueId,
      accessTokenCredentialId: binding.accessTokenCredentialId,
    );
  }

  // ─── SevenRoomsReservationGateway: connect lifecycle ──────────────

  @override
  Future<String> upsertConnection({
    required TenantContext tenant,
    required String vendorVenueId,
    required String accessTokenCredentialId,
  }) {
    return withTenant<String>(tenant, (exec) async {
      final connectionRows = await exec.query(
        'insert into public.connector_connection ('
        'operator_id, location_id, vendor_id, category, status, '
        'metadata, connected_by_user_id, created_at, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, @category, '
        "'connected', @metadata::jsonb, @actor_user_id::uuid, now(), now()"
        ') '
        'on conflict (operator_id, location_id, vendor_id) do update set '
        "  status = 'connected', "
        '  metadata = excluded.metadata, '
        '  connected_by_user_id = excluded.connected_by_user_id, '
        '  updated_at = now() '
        'returning connection_id',
        parameters: <String, Object?>{
          'operator_id': tenant.operatorId,
          'location_id': tenant.locationId,
          'vendor_id': kSevenRoomsVendorId,
          'category': IntegrationCategory.reservation.name,
          'metadata': json.encode(<String, Object?>{
            'venue_id': vendorVenueId,
            'webhook_state': 'pending_paste',
          }),
          'actor_user_id': tenant.userId,
        },
      );
      final connectionId = connectionRows.first['connection_id']! as String;
      await exec.execute(
        'insert into public.vendor_credentials ('
        'credential_id, operator_id, location_id, connection_id, '
        'vendor_id, created_at, updated_at'
        ') values ('
        '@credential_id, @operator_id::uuid, @location_id::uuid, '
        '@connection_id::uuid, @vendor_id, now(), now()'
        ') '
        'on conflict (credential_id) do update set '
        '  connection_id = excluded.connection_id, '
        '  updated_at = now()',
        parameters: <String, Object?>{
          'credential_id': accessTokenCredentialId,
          'operator_id': tenant.operatorId,
          'location_id': tenant.locationId,
          'connection_id': connectionId,
          'vendor_id': kSevenRoomsVendorId,
        },
      );
      return connectionId;
    });
  }

  @override
  Future<void> wipeCredentialsAndDisconnect({
    required TenantContext tenant,
    required String connectionId,
    required DisconnectReason reason,
  }) {
    return withTenant<void>(tenant, (exec) async {
      await exec.execute(
        'delete from public.vendor_credentials '
        'where connection_id = @connection_id::uuid '
        '  and operator_id = @operator_id::uuid',
        parameters: <String, Object?>{
          'connection_id': connectionId,
          'operator_id': tenant.operatorId,
        },
      );
      await exec.execute(
        'update public.connector_connection set '
        "  status = 'disconnected', "
        '  disconnect_reason = @reason, '
        '  updated_at = now() '
        'where connection_id = @connection_id::uuid '
        '  and operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid',
        parameters: <String, Object?>{
          'connection_id': connectionId,
          'operator_id': tenant.operatorId,
          'location_id': tenant.locationId,
          'reason': reason.name,
        },
      );
    });
  }

  // ─── SevenRoomsReservationGateway: canonical-fact write ───────────

  @override
  Future<bool> writeReservationFact({
    required TenantContext tenant,
    required String connectionId,
    required String vendorEntityId,
    required DateTime reservationAtUtc,
    required int partySize,
    required SevenRoomsCanonicalStatus status,
    required Map<String, DateTime> statusTransitions,
    required String restaurantTimezone,
    required int businessDayRolloverHour,
    required DateTime vendorModifiedAtUtc,
  }) {
    final businessDate = _timezoneConverter.toBusinessDate(
      restaurantTimezone: restaurantTimezone,
      businessDayRolloverHour: businessDayRolloverHour,
      instant: reservationAtUtc,
    );
    final transitionsIso = statusTransitions.map(
      (key, value) => MapEntry<String, String>(key, value.toUtc().toIso8601String()),
    );
    final rawPayload = <String, Object?>{
      'vendor_id': kSevenRoomsVendorId,
      'vendor_entity_id': vendorEntityId,
      'reservation_at': reservationAtUtc.toUtc().toIso8601String(),
      'vendor_modified_at': vendorModifiedAtUtc.toUtc().toIso8601String(),
      'party_size': partySize,
      'status': status.name,
      'status_transitions': transitionsIso,
    };
    return withTenant<bool>(tenant, (exec) async {
      return _insertReservationFact(
        exec: exec,
        operatorId: tenant.operatorId,
        locationId: tenant.locationId,
        connectionId: connectionId,
        vendorEntityId: vendorEntityId,
        vendorModifiedAtUtc: vendorModifiedAtUtc.toUtc(),
        reservationAtUtc: reservationAtUtc.toUtc(),
        businessDate: businessDate,
        partySize: partySize,
        statusColumn: _columnStatusFor(status),
        seatedAt: statusTransitions['seated']?.toUtc(),
        cancelledAt: statusTransitions['cancelled']?.toUtc(),
        rawPayload: rawPayload,
      );
    });
  }

  Future<bool> _insertReservationFact({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String vendorEntityId,
    required DateTime vendorModifiedAtUtc,
    required DateTime reservationAtUtc,
    required DateTime businessDate,
    required int partySize,
    required String statusColumn,
    required DateTime? seatedAt,
    required DateTime? cancelledAt,
    required Map<String, Object?> rawPayload,
  }) async {
    final affected = await exec.execute(
      'insert into public.reservation_facts ('
      'operator_id, location_id, connection_id, '
      'vendor_id, vendor_entity_id, vendor_modified_at, '
      'reservation_at, business_date, party_size, status, '
      'seated_at, cancelled_at, raw_payload'
      ') values ('
      '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
      '@vendor_id, @vendor_entity_id, @vendor_modified_at, '
      '@reservation_at, @business_date::date, @party_size, @status, '
      '@seated_at, @cancelled_at, @raw_payload::jsonb'
      ') '
      'on conflict (operator_id, vendor_id, vendor_entity_id, vendor_modified_at) '
      'do nothing',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'vendor_id': kSevenRoomsVendorId,
        'vendor_entity_id': vendorEntityId,
        'vendor_modified_at': vendorModifiedAtUtc,
        'reservation_at': reservationAtUtc,
        'business_date': _formatDate(businessDate),
        'party_size': partySize,
        'status': statusColumn,
        'seated_at': seatedAt,
        'cancelled_at': cancelledAt,
        'raw_payload': json.encode(rawPayload),
      },
    );
    return affected >= 1;
  }

  // ─── SevenRoomsReservationGateway: watermark + sync log ───────────

  @override
  Future<void> updateWatermark({
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeenUtc,
  }) async {
    final tenant = await _resolveTenantForConnection(connectionId);
    return withTenant<void>(tenant, (exec) async {
      await _writeWatermark(
        exec: exec,
        operatorId: tenant.operatorId,
        locationId: tenant.locationId,
        connectionId: connectionId,
        resource: sevenRoomsWatermarkResource,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeenUtc.toUtc(),
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

  @override
  Future<void> appendSyncLog({
    required String connectionId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
  }) async {
    final tenant = await _resolveTenantForConnection(connectionId);
    return withTenant<void>(tenant, (exec) async {
      await _writeSyncLog(
        exec: exec,
        operatorId: tenant.operatorId,
        locationId: tenant.locationId,
        connectionId: connectionId,
        eventKind: eventKind,
        recordsCount: recordsCount,
        errorMessage: errorMessage,
        payloadPreview: null,
      );
    });
  }

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
        'payload_preview':
            payloadPreview == null ? null : json.encode(payloadPreview),
      },
    );
  }

  // ─── Demo-mode flip (reservation category) ────────────────────────

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

  // ─── Internal: resolve (operator_id, location_id) from connection ─

  /// Resolve the `(operator_id, location_id)` tuple bound to
  /// [connectionId] via a system-scoped lookup against
  /// `public.connector_connection`. The bespoke
  /// [SevenRoomsReservationGateway.updateWatermark] /
  /// [SevenRoomsReservationGateway.appendSyncLog] surfaces only carry a
  /// `connectionId`, so this lookup is the seam that recovers the
  /// tenant pair before the actual write runs under
  /// [OperatorScopedRepository.withTenant].
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
            'vendor_id': kSevenRoomsVendorId,
          },
        );
        if (rows.isEmpty) {
          throw StateError(
            'SevenRoomsReservationPostgresSink could not resolve tenant for '
            'connection_id=$connectionId; the connector_connection row is '
            'missing or not bound to vendor_id=$kSevenRoomsVendorId.',
          );
        }
        final row = rows.single;
        return TenantContext(
          operatorId: row['operator_id']! as String,
          locationId: row['location_id']! as String,
        );
      },
      reason: 'sevenrooms.sink.resolve_tenant_for_connection',
    );
  }

  // ─── CanonicalSink composition view ───────────────────────────────

  /// Expose the unified [CanonicalSink] surface the sync worker dispatch
  /// (from `.0`) speaks. The same tenant-wrapped engine backs both the
  /// bespoke [SevenRoomsReservationGateway] surface and this view.
  CanonicalSink asCanonicalSink({
    required String Function(String operatorId, String locationId)
        connectionIdResolver,
  }) {
    return _SevenRoomsCanonicalSinkView(
      sink: this,
      connectionIdResolver: connectionIdResolver,
    );
  }
}

/// Adapter that exposes the [SevenRoomsReservationPostgresSink] through
/// the unified [CanonicalSink] surface declared in `.0`.
///
/// Cover / labor methods are unsupported: the SevenRooms reservation
/// adapter's category is [IntegrationCategory.reservation] only and the
/// registry never routes a non-reservation fact to this sink. Per the
/// fanout slice contract, [upsertCoverFact] and [upsertLaborPunch]
/// return `false` (the dispatcher's category gate is the primary
/// router; this sink simply refuses to absorb the misrouted batch).
class _SevenRoomsCanonicalSinkView implements CanonicalSink {
  _SevenRoomsCanonicalSinkView({
    required this.sink,
    required this.connectionIdResolver,
  });

  final SevenRoomsReservationPostgresSink sink;
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
    final connectionId = connectionIdResolver(operatorId, locationId);
    final vendorEntityId =
        canonicalReservation['vendor_entity_id']! as String;
    final vendorModifiedAt =
        _coerceInstant(canonicalReservation['vendor_modified_at'])!;
    final reservationAt =
        _coerceInstant(canonicalReservation['reservation_at'])!;
    final partySize =
        (canonicalReservation['party_size']! as num).toInt();
    final status =
        _statusFromName(canonicalReservation['status']! as String);
    final transitions = <String, DateTime>{};
    final transitionsRaw = canonicalReservation['status_transitions'];
    if (transitionsRaw is Map) {
      transitionsRaw.forEach((key, value) {
        if (key is! String) return;
        final parsed = _coerceInstant(value);
        if (parsed != null) transitions[key] = parsed;
      });
    }
    final restaurantTimezone =
        (canonicalReservation['restaurant_timezone'] as String?) ?? 'UTC';
    final businessDayRolloverHour =
        (canonicalReservation['business_day_rollover_hour'] as int?) ?? 0;
    return sink.writeReservationFact(
      tenant:
          TenantContext(operatorId: operatorId, locationId: locationId),
      connectionId: connectionId,
      vendorEntityId: vendorEntityId,
      reservationAtUtc: reservationAt,
      partySize: partySize,
      status: status,
      statusTransitions: transitions,
      restaurantTimezone: restaurantTimezone,
      businessDayRolloverHour: businessDayRolloverHour,
      vendorModifiedAtUtc: vendorModifiedAt,
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
        resource: sevenRoomsWatermarkResource,
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

/// Map [SevenRoomsCanonicalStatus] to the canonical V1 storage
/// vocabulary on `reservation_facts.status`. Adapter values that fall
/// outside the V1 column vocabulary land on `'unknown'` so the dashboard
/// can render a `MetricCardNotYetAvailable`-equivalent state without
/// inventing a wrong terminal state. Cancellation maps to `'cancelled'`
/// so the `cancelled_at` column round-trips alongside the column status.
String _columnStatusFor(SevenRoomsCanonicalStatus status) {
  switch (status) {
    case SevenRoomsCanonicalStatus.booked:
      return 'confirmed';
    case SevenRoomsCanonicalStatus.seated:
      return 'seated';
    case SevenRoomsCanonicalStatus.cancelled:
      return 'cancelled';
    case SevenRoomsCanonicalStatus.noShow:
      return 'no_show';
    case SevenRoomsCanonicalStatus.arrived:
    case SevenRoomsCanonicalStatus.completed:
      return 'unknown';
  }
}

SevenRoomsCanonicalStatus _statusFromName(String name) {
  for (final value in SevenRoomsCanonicalStatus.values) {
    if (value.name == name) return value;
  }
  return SevenRoomsCanonicalStatus.booked;
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
