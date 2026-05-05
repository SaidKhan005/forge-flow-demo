// Phase 8 Wave B `8.spine-bridge.1.LB` — Libro reservation Postgres sink.
//
// Spine reference: docs/contracts/integration_spine_architecture_contract.md
// (binding) sub-lane `.1.LB`. Same shape as `.1.OR` (Oracle MICROS Simphony
// POS) and `.1.QBT` (QuickBooks Time labor): the sink IS the per-vendor
// gateway implementation the existing Wave B adapter writes through, AND
// composes the unified [CanonicalSink] interface from `.0` so the sync
// worker can dispatch through a category-uniform surface.
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
//   * HP #4 (per-operator isolation): every method opens a tenant-
//     scoped transaction via [OperatorScopedRepository.withTenant], which
//     issues `set_config('app.operator_id', ..., true)` +
//     `app.location_id` so RLS policies on `reservation_facts` /
//     `connector_sync_watermark` / `connector_sync_log` /
//     `demo_mode_state` engage as the backup defense.
//   * HP #2 (demo mode persists post-launch): [markReservationsLive]
//     uses an idempotent `INSERT ... ON CONFLICT DO UPDATE WHERE is_demo`
//     so the second arrival is a no-op and `flipped_to_live_at` stays
//     pinned to the first flip. Disconnect does NOT auto-revert (this
//     code does not write `is_demo = true`).
//
// V1 lean cut 2 alignment (memory/project_v1_lean_cut_2_2026_05_03.md):
// no KMS / production-key rotation surface, no `parse_warnings` /
// `parse_partial` columns, no 5-minute replay window, no advisory locks,
// no SIGTERM graceful drain, no dead-letter UI surface, no raw-payload
// sibling tables / pg_partman registration, no 5-second test SLA.

import 'dart:convert';

import '../../../integrations/reservation/libro_reservation_adapter.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/integration_adapter_common.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// Stable resource string written to `connector_sync_watermark.resource`
/// for the Libro reservations stream. Mirrors
/// [kLibroReservationsResource] from the adapter so the registry / sync
/// worker / sink agree on the shared key.
const String _kLibroResource = kLibroReservationsResource;

/// Postgres-backed sink for Libro reservations.
///
/// Implements [LibroReservationGateway] (the bespoke seam the existing
/// Wave B `LibroReservationAdapter` writes through) and exposes a
/// composed [CanonicalSink] view via [asCanonicalSink] for the sync
/// worker dispatch from `.0`.
///
/// The two surfaces share one `withTenant`-wrapped engine; they differ
/// only in the input shape:
///   * [LibroReservationGateway.upsertReservationFact] takes the typed
///     [CanonicalReservationFact] the adapter materialises.
///   * [CanonicalSink.upsertReservationFact] takes the same shape as a
///     `Map<String, Object?>` so the worker can dispatch any vendor's
///     output through one method.
class LibroPostgresSink extends OperatorScopedRepository
    implements LibroReservationGateway {
  LibroPostgresSink({
    required TenantTransactionWrapper tenantWrapper,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        super(tenantWrapper);

  final DateTime Function() _now;

  // ─── LibroReservationGateway: connect lifecycle ────────────────────

  @override
  Future<LibroConnectionContext?> lookupConnection({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      final rows = await exec.query(
        'select cc.connection_id, cc.metadata, vc.credential_id, '
        'loc.iana_timezone, loc.business_day_rollover_hour '
        'from public.connector_connection cc '
        'left join public.vendor_credentials vc '
        '  on vc.connection_id = cc.connection_id '
        'left join public.locations loc '
        '  on loc.operator_id = cc.operator_id '
        ' and loc.location_id = cc.location_id '
        'where cc.operator_id = @operator_id::uuid '
        '  and cc.location_id = @location_id::uuid '
        "  and cc.vendor_id = @vendor_id "
        "  and cc.status = 'connected' "
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kLibroVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final metadataRaw = row['metadata'];
      final metadata = _coerceJsonObject(metadataRaw);
      final credentialId = row['credential_id'] as String?;
      if (credentialId == null) return null;
      final venueId = metadata['venue_id'] as String?;
      if (venueId == null) return null;
      return LibroConnectionContext(
        connectionId: row['connection_id']! as String,
        venueId: venueId,
        credential: VendorCredentialHandle(credentialId: credentialId),
        webhookSubscriptionId:
            metadata['webhook_subscription_id'] as String?,
        restaurantTimezone:
            (row['iana_timezone'] as String?) ?? 'UTC',
        businessDayRolloverHour:
            (row['business_day_rollover_hour'] as int?) ?? 4,
      );
    });
  }

  @override
  Future<String> persistConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required VendorCredentialHandle credential,
    required Map<String, Object?> metadata,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant(ctx, (exec) async {
      final connectionRows = await exec.query(
        'insert into public.connector_connection ('
        'operator_id, location_id, vendor_id, category, status, '
        'metadata, connected_by_user_id, created_at, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, '
        "@category, 'connected', @metadata::jsonb, "
        '@actor_user_id::uuid, now(), now()'
        ') '
        'on conflict (operator_id, location_id, vendor_id) do update set '
        "  status = 'connected', "
        '  metadata = excluded.metadata, '
        '  connected_by_user_id = excluded.connected_by_user_id, '
        '  updated_at = now() '
        'returning connection_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kLibroVendorId,
          'category': IntegrationCategory.reservation.name,
          'metadata': json.encode(metadata),
          'actor_user_id': actorUserId,
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
          'credential_id': credential.credentialId,
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'vendor_id': kLibroVendorId,
        },
      );
      return connectionId;
    });
  }

  @override
  Future<void> wipeCredential({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      await exec.execute(
        'delete from public.vendor_credentials '
        'where connection_id = @connection_id::uuid '
        '  and operator_id = @operator_id::uuid',
        parameters: <String, Object?>{
          'connection_id': connectionId,
          'operator_id': operatorId,
        },
      );
      await exec.execute(
        'update public.connector_connection set '
        "  status = 'disconnected', "
        '  updated_at = now() '
        'where connection_id = @connection_id::uuid '
        '  and operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid',
        parameters: <String, Object?>{
          'connection_id': connectionId,
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
    });
  }

  // ─── LibroReservationGateway: canonical-fact write ─────────────────

  @override
  Future<ReservationUpsertOutcome> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required CanonicalReservationFact fact,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      return _insertReservationFact(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        fact: fact,
      );
    });
  }

  Future<ReservationUpsertOutcome> _insertReservationFact({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String connectionId,
    required CanonicalReservationFact fact,
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
        'vendor_id': fact.vendorId,
        'vendor_entity_id': fact.vendorEntityId,
        'vendor_modified_at': fact.vendorModifiedAt,
        'reservation_at': fact.reservationAt,
        'business_date':
            fact.businessDate.toIso8601String().substring(0, 10),
        'party_size': fact.partySize,
        'status': _columnStatusFor(fact.status),
        'seated_at':
            fact.statusTransitions[CanonicalReservationStatus.seated.name],
        'cancelled_at':
            fact.statusTransitions[CanonicalReservationStatus.canceled.name],
        'raw_payload': json.encode(fact.rawPayload),
      },
    );
    return ReservationUpsertOutcome(wrote: affected >= 1);
  }

  // ─── LibroReservationGateway: watermark + sync log ────────────────

  @override
  Future<void> recordWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String resource,
    required String? cursorToken,
    required DateTime lastModifiedSeen,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      await _writeWatermark(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        resource: resource,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
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
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String eventKind,
    int? recordsCount,
    String? errorMessage,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      await _writeSyncLog(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
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

  // ─── LibroReservationGateway: demo-mode flip ──────────────────────

  @override
  Future<void> markReservationsLive({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      await _flipDemoToLive(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
      );
    });
  }

  /// Idempotent demo-mode flip. The `WHERE public.demo_mode_state.is_demo`
  /// guard on the update branch makes the second call a no-op:
  /// `flipped_to_live_at` stays pinned to the first flip and
  /// `flipped_by_connection_id` is preserved per the policy contract in
  /// `lib/services/integration/demo_mode_state.dart`. Disconnect does
  /// NOT call this method (the gateway has no `revertReservationsLive`
  /// surface — by design).
  Future<void> _flipDemoToLive({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) async {
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
  }

  // ─── CanonicalSink composition view ───────────────────────────────

  /// Expose the unified [CanonicalSink] surface the sync worker dispatch
  /// (from `.0`) speaks. The same `withTenant`-wrapped engine backs both
  /// the bespoke [LibroReservationGateway] surface and this view.
  CanonicalSink asCanonicalSink({
    required String Function(String operatorId, String locationId)
        connectionIdResolver,
  }) {
    return _LibroCanonicalSinkView(
      sink: this,
      connectionIdResolver: connectionIdResolver,
    );
  }
}

/// Adapter that exposes the [LibroPostgresSink] through the unified
/// [CanonicalSink] surface declared in `.0`.
///
/// Cover / labor methods are unsupported: the reservation adapter's
/// category is [IntegrationCategory.reservation] only and the registry
/// never routes a non-reservation fact to this sink. The throw is a
/// defense-in-depth guard against future router refactors that might
/// forget the category gate.
class _LibroCanonicalSinkView implements CanonicalSink {
  _LibroCanonicalSinkView({
    required this.sink,
    required this.connectionIdResolver,
  });

  final LibroPostgresSink sink;
  final String Function(String operatorId, String locationId)
      connectionIdResolver;

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    throw UnsupportedError(
      'LibroPostgresSink only handles reservation facts; '
      'cover facts route through the POS-vendor sink.',
    );
  }

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async {
    throw UnsupportedError(
      'LibroPostgresSink only handles reservation facts; '
      'labor punches route through the labor-vendor sink.',
    );
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async {
    final fact = _materializeFromMap(canonicalReservation);
    final connectionId = connectionIdResolver(operatorId, locationId);
    final outcome = await sink.upsertReservationFact(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      fact: fact,
    );
    return outcome.wrote;
  }

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) {
    return sink.recordWatermark(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      resource: _kLibroResource,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
    );
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
    return sink.appendSyncLog(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      eventKind: eventKind,
      errorMessage: errorMessage,
      recordsCount: recordsCount,
    );
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

/// Map [CanonicalReservationStatus] to the canonical V1 storage
/// vocabulary on `reservation_facts.status`. Adapter values that fall
/// outside the V1 column vocabulary land on `'unknown'` so the dashboard
/// can render a `MetricCardNotYetAvailable`-equivalent state without
/// inventing a wrong terminal state.
String _columnStatusFor(CanonicalReservationStatus status) {
  switch (status) {
    case CanonicalReservationStatus.confirmed:
      return 'confirmed';
    case CanonicalReservationStatus.seated:
      return 'seated';
    case CanonicalReservationStatus.canceled:
      return 'cancelled';
    case CanonicalReservationStatus.noShow:
      return 'no_show';
    case CanonicalReservationStatus.expected:
    case CanonicalReservationStatus.arrived:
    case CanonicalReservationStatus.completed:
      return 'unknown';
  }
}

/// Re-materialise a [CanonicalReservationFact] from a `Map<String, Object?>`
/// shape the unified [CanonicalSink] dispatches. Mirrors the adapter's
/// `_materialize` output keys so the round-trip via worker dispatch is
/// loss-free.
CanonicalReservationFact _materializeFromMap(Map<String, Object?> map) {
  final transitionsRaw = map['status_transitions'];
  final transitions = <String, DateTime>{};
  if (transitionsRaw is Map) {
    transitionsRaw.forEach((key, value) {
      if (key is String && value is DateTime) {
        transitions[key] = value;
      } else if (key is String && value is String) {
        final parsed = DateTime.tryParse(value);
        if (parsed != null) transitions[key] = parsed;
      }
    });
  }
  return CanonicalReservationFact(
    vendorId: map['vendor_id']! as String,
    vendorEntityId: map['vendor_entity_id']! as String,
    vendorModifiedAt: _coerceInstant(map['vendor_modified_at'])!,
    reservationAt: _coerceInstant(map['reservation_at'])!,
    businessDate: _coerceInstant(map['business_date'])!,
    partySize: (map['party_size']! as num).toInt(),
    status: _statusFromName(map['status']! as String),
    statusTransitions: transitions,
    rawPayload: _coerceJsonObject(map['raw_payload']),
  );
}

DateTime? _coerceInstant(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.toUtc();
  if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw)?.toUtc();
  return null;
}

CanonicalReservationStatus _statusFromName(String name) {
  for (final value in CanonicalReservationStatus.values) {
    if (value.name == name) return value;
  }
  return CanonicalReservationStatus.expected;
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
