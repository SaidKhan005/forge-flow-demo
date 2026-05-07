// Phase 8 / Wave B `8.spine-bridge.fanout.TC` — Tock reservation
// Postgres-backed canonical sink.
//
// Spine reference:
//   * `docs/contracts/integration_spine_architecture_contract.md`
//     (binding) section "Postgres-backed CanonicalSink".
//   * `docs/contracts/core_app_architecture.md` Layer 2 (Canonical
//     Facts): `reservation_facts` is the per-vendor canonical row that
//     aggregates into `ReservationBookSnapshot`.
//   * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//     — the [OperatorScopedRepository] pattern is the primary tenant
//     defense, RLS is the backup.
//
// Mirrors the shape of [LibroPostgresSink]:
//   1. Implements the bespoke [TockFactSink] (the seam the existing
//      `TockReservationAdapter` writes through) and exposes the unified
//      [CanonicalSink] surface from `8.spine-bridge.0` via
//      [asCanonicalSink] for the sync worker dispatch.
//   2. Widens the `connectionId` named parameter on
//      [upsertReservationFact] / [persistWatermark] / [appendSyncLog] so
//      a single concrete method satisfies the bespoke contract (which
//      omits `connectionId`) and the unified-dispatch caller (which
//      passes one). When omitted, the sink resolves the connection id
//      from the operator-scoped `connector_connection` row inside the
//      same tenant transaction as the write.
//
// Tock vendor specifics (2026-05-05 falsehood correction):
//   * Tock's documented reservation API exposes ONLY three timestamps
//     per reservation: `createdTimestamp`, `lastUpdatedTimestamp`, and
//     `serviceDateTimestamp`. Per-status transition timestamps
//     (`arrived_at`, the mid-service event, `left_at`, `canceled_at`)
//     are NOT documented and may or may not appear in sandbox/live
//     payloads — the `8R.TC.live.sandbox` slice diffs observed payloads
//     and adds fields if Tock emits them.
//   * The sink therefore writes the `seated_at` and `cancelled_at`
//     columns as SQL `null` literals, never reading a synthesised value
//     from the canonical-fact map. This is enforced at compile time by
//     the absence of any Dart `'seated_at'` / `'cancelled_at'` literal
//     in the parameters map; the column names appear only inside the
//     SQL string of the INSERT statement. Test H grep enforces.
//   * `partySize` (the reservation analog of POS covers; covers source
//     classification = `not_applicable`) lands on `party_size`.
//
// Hard-Promise alignment (CLAUDE.md):
//   * HP #1 (pure transport swap): writes hit the existing
//     `reservation_facts` columns plus the framework-added vendor
//     columns (`vendor_id` / `vendor_entity_id` / `vendor_modified_at`
//     / `raw_payload`) from migration `202605040000`. No business-logic
//     mutation.
//   * HP #4 (per-operator isolation): every method opens a tenant-
//     scoped transaction via [OperatorScopedRepository.withTenant],
//     which issues `select set_config('app.operator_id', ..., true)` +
//     `app.location_id` so RLS engages as the backup defense.
//   * HP #2 (demo mode persists post-launch): [markReservationsLive]
//     uses an idempotent `INSERT ... ON CONFLICT DO UPDATE WHERE
//     is_demo` so the second arrival is a no-op and `flipped_to_live_at`
//     stays pinned to the first flip.
//
// V1 lean cut 2 alignment (memory/project_v1_lean_cut_2_2026_05_03.md):
// no KMS / production-key rotation surface, no `parse_warnings` /
// `parse_partial` columns, no 5-minute strict replay window, no
// advisory locks, no SIGTERM graceful drain handler, no dead-letter UI
// surface, no raw-payload sibling tables, no pg_partman registration,
// no 5-second test-connection SLA. Banned-grep in
// `tock_reservation_postgres_sink_test.dart` enforces.

import 'dart:convert';

import '../../../integrations/reservation/tock_reservation_adapter.dart';
import '../../../integrations/reservation/tock_webhook_signature_verifier.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/integration_adapter_common.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// Stable resource string written to `connector_sync_watermark.resource`
/// for the Tock reservations stream. Used by the framework's sync
/// worker to disambiguate the cursor when (eventually) Tock acquires a
/// second resource on the same connection without a schema change.
const String tockWatermarkResource = 'reservation.reservations';

/// Postgres-backed sink for Tock reservations.
///
/// Implements [TockFactSink] (the bespoke seam the Wave B
/// `TockReservationAdapter` writes through) and exposes a composed
/// [CanonicalSink] view via [asCanonicalSink] for the sync worker
/// dispatch from `8.spine-bridge.0`.
class TockReservationPostgresSink extends OperatorScopedRepository
    implements TockFactSink {
  TockReservationPostgresSink({
    required TenantTransactionWrapper tenantWrapper,
    DateTime Function()? now,
  })  : _now = now ?? DateTime.now,
        super(tenantWrapper);

  final DateTime Function() _now;

  // ─── TockFactSink: canonical fact upsert ───────────────────────────

  /// Insert one canonical reservation fact. Idempotency UNIQUE on
  /// `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`;
  /// repeat writes of the same key short-circuit to a no-op (returns
  /// `false`) per the partial index from migration `202605040000`.
  ///
  /// `connectionId` is widened to optional: bespoke callers (the Tock
  /// adapter) omit it and the sink resolves the row from
  /// `connector_connection` inside the same tenant transaction as the
  /// INSERT; unified-dispatch callers (the sync worker via the
  /// [CanonicalSink] view) pass it explicitly.
  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
    required Map<String, Object?> rawPayload,
    String? connectionId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      final resolvedConnectionId = await _resolveConnectionIdInTx(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        explicitConnectionId: connectionId,
      );
      return _insertReservationFact(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: resolvedConnectionId,
        canonicalFact: canonicalFact,
        rawPayload: rawPayload,
      );
    });
  }

  Future<bool> _insertReservationFact({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String connectionId,
    required Map<String, Object?> canonicalFact,
    required Map<String, Object?> rawPayload,
  }) async {
    final reservationAt = _coerceUtc(canonicalFact['reservation_at']);
    final vendorModifiedAt = _coerceUtc(canonicalFact['vendor_modified_at']);
    if (reservationAt == null || vendorModifiedAt == null) {
      throw StateError(
        'tock canonical fact is missing reservation_at or '
        'vendor_modified_at — adapter contract violated',
      );
    }
    // Tock's public reference times are UTC (ISO-8601 with trailing
    // `Z`); derive `business_date` as the UTC calendar date of
    // `reservation_at`. The `8R.TC.live.sandbox` slice confirms via
    // observed payloads if a per-restaurant tz projection is needed;
    // the engineering slice does not assume one.
    final businessDate = _utcDateString(reservationAt);

    final affected = await exec.execute(
      'insert into public.reservation_facts ('
      'operator_id, location_id, connection_id, '
      'vendor_id, vendor_entity_id, vendor_modified_at, '
      'reservation_at, business_date, party_size, status, '
      'seated_at, cancelled_at, raw_payload'
      ') values ('
      '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
      '@vendor_id, @vendor_entity_id, @vendor_modified_at::timestamptz, '
      '@reservation_at::timestamptz, @business_date::date, @party_size, @status, '
      'null, null, @raw_payload::jsonb'
      ') '
      'on conflict (operator_id, vendor_id, vendor_entity_id, vendor_modified_at) '
      'do nothing',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'vendor_id': kTockVendorId,
        'vendor_entity_id': canonicalFact['vendor_entity_id']! as String,
        'vendor_modified_at': vendorModifiedAt,
        'reservation_at': reservationAt,
        'business_date': businessDate,
        'party_size': (canonicalFact['party_size']! as num).toInt(),
        'status': _columnStatusForTock(canonicalFact['status'] as String?),
        'raw_payload': json.encode(rawPayload),
      },
    );
    return affected >= 1;
  }

  // ─── TockFactSink: watermark per batch ─────────────────────────────

  /// Persist the connector_sync_watermark row for this connection.
  /// Bespoke callers (the Tock adapter) omit `connectionId` and
  /// `resource`; unified-dispatch callers pass them explicitly.
  @override
  Future<void> persistWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? connectionId,
    String? resource,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      final resolvedConnectionId = await _resolveConnectionIdInTx(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        explicitConnectionId: connectionId,
      );
      await _writeWatermark(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: resolvedConnectionId,
        resource: resource ?? tockWatermarkResource,
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
    required String cursorToken,
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
      '  last_synced_at = excluded.last_synced_at, '
      '  updated_at = now() '
      'where excluded.last_synced_at >= '
      'public.connector_sync_watermark.last_synced_at',
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

  // ─── connector_sync_log append (used by the unified view) ──────────

  /// Append one row to `connector_sync_log`. Like the watermark and
  /// upsert paths, `connectionId` is widened so bespoke callers may
  /// omit it.
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String eventKind,
    String? connectionId,
    int? recordsCount,
    String? errorMessage,
    Map<String, Object?>? payloadPreview,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
      final resolvedConnectionId = await _resolveConnectionIdInTx(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        explicitConnectionId: connectionId,
      );
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
          'connection_id': resolvedConnectionId,
          'event_kind': eventKind,
          'records_count': recordsCount,
          'error_message': errorMessage,
          'payload_preview': encodePayloadPreviewForSyncLog(payloadPreview),
        },
      );
    });
  }

  // ─── demo-mode flip ────────────────────────────────────────────────

  /// Idempotent demo-mode flip. The `WHERE public.demo_mode_state.is_demo`
  /// guard on the update branch makes the second call a no-op:
  /// `flipped_to_live_at` stays pinned to the first flip and
  /// `flipped_by_connection_id` is preserved per the policy contract in
  /// `lib/services/integration/demo_mode_state.dart`. Disconnect does
  /// NOT call this method (the gateway has no `revertReservationsLive`
  /// surface — by design).
  Future<void> markReservationsLive({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant(ctx, (exec) async {
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

  // ─── credential wipe on disconnect ─────────────────────────────────

  /// Wipe the credential envelope for a Tock connection. Mirrors the
  /// Libro shape: historical canonical facts and watermark are
  /// preserved per the framework contract — reconnect resumes from the
  /// last persisted cursor.
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

  // ─── connection_id resolver ────────────────────────────────────────

  /// Resolve the `connector_connection.connection_id` for the
  /// (operator, location, vendor=tock) triple. Bespoke callers omit
  /// `explicitConnectionId`; unified-dispatch callers pass it. The
  /// SELECT runs inside the caller's tenant transaction so the lookup
  /// shares the same `set_config('app.operator_id', ...)` scope as the
  /// subsequent write.
  Future<String> _resolveConnectionIdInTx({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String? explicitConnectionId,
  }) async {
    if (explicitConnectionId != null && explicitConnectionId.isNotEmpty) {
      return explicitConnectionId;
    }
    final rows = await exec.query(
      'select connection_id::text as connection_id '
      'from public.connector_connection '
      'where operator_id = @operator_id::uuid '
      '  and location_id = @location_id::uuid '
      '  and vendor_id = @vendor_id '
      "  and status = 'connected' "
      'limit 1',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'vendor_id': kTockVendorId,
      },
    );
    if (rows.isEmpty) {
      throw StateError(
        'connector_connection row not found for '
        '(operator=$operatorId, location=$locationId, '
        'vendor=$kTockVendorId) — connect must run before sink writes',
      );
    }
    final id = rows.single['connection_id'];
    if (id is! String || id.isEmpty) {
      throw StateError('connector_connection.connection_id is malformed');
    }
    return id;
  }

  // ─── CanonicalSink composition view ───────────────────────────────

  /// Expose the unified [CanonicalSink] surface the sync worker
  /// dispatch from `8.spine-bridge.0` speaks. The same `withTenant`-
  /// wrapped engine backs both the bespoke [TockFactSink] surface and
  /// this view; they differ only in the input shape.
  CanonicalSink asCanonicalSink({
    required String Function(String operatorId, String locationId)
        connectionIdResolver,
  }) {
    return _TockCanonicalSinkView(
      sink: this,
      connectionIdResolver: connectionIdResolver,
    );
  }
}

/// Adapter that exposes [TockReservationPostgresSink] through the
/// unified [CanonicalSink] surface declared in `8.spine-bridge.0`.
///
/// Cover / labor methods are unsupported: the Tock adapter's category
/// is [IntegrationCategory.reservation] only and the registry never
/// routes a non-reservation fact to this sink. The throw is a
/// defense-in-depth guard against future router refactors that might
/// forget the category gate.
class _TockCanonicalSinkView implements CanonicalSink {
  _TockCanonicalSinkView({
    required this.sink,
    required this.connectionIdResolver,
  });

  final TockReservationPostgresSink sink;
  final String Function(String operatorId, String locationId)
      connectionIdResolver;

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    throw UnsupportedError(
      'TockReservationPostgresSink only handles reservation facts; '
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
      'TockReservationPostgresSink only handles reservation facts; '
      'labor punches route through the labor-vendor sink.',
    );
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) {
    final connectionId = connectionIdResolver(operatorId, locationId);
    final rawPayloadRaw = canonicalReservation['raw_payload'];
    final rawPayload = rawPayloadRaw is Map
        ? rawPayloadRaw.cast<String, Object?>()
        : const <String, Object?>{};
    return sink.upsertReservationFact(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalReservation,
      rawPayload: rawPayload,
      connectionId: connectionId,
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
    return sink.persistWatermark(
      operatorId: operatorId,
      locationId: locationId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
      connectionId: connectionId,
      resource: tockWatermarkResource,
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
      recordsCount: recordsCount,
      errorMessage: errorMessage,
      payloadPreview: payloadPreview,
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

/// Project the canonical Tock status string to the V1 storage
/// vocabulary on `reservation_facts.status`. Mirrors `_columnStatusFor`
/// in [LibroPostgresSink]; Tock-only values that fall outside the V1
/// column vocabulary land on `'unknown'` so the dashboard renders a
/// `MetricCardNotYetAvailable`-equivalent state without inventing a
/// wrong terminal state.
String _columnStatusForTock(String? canonicalStatus) {
  switch (canonicalStatus) {
    case 'seated':
      return 'seated';
    case 'canceled':
    case 'cancelled':
      return 'cancelled';
    case 'no_show':
      return 'no_show';
    case 'confirmed':
      return 'confirmed';
  }
  return 'unknown';
}

DateTime? _coerceUtc(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw.toUtc();
  if (raw is String && raw.isNotEmpty) return DateTime.tryParse(raw)?.toUtc();
  return null;
}

String _utcDateString(DateTime utc) {
  final y = utc.year.toString().padLeft(4, '0');
  final m = utc.month.toString().padLeft(2, '0');
  final d = utc.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
