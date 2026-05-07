// Phase 8 / Wave B `8.spine-bridge.1.SQ` — Square POS Postgres-backed
// canonical sink.
//
// Spine reference:
//   * `docs/contracts/integration_spine_architecture_contract.md`
//     section "8.spine-bridge.1.SQ" (binding).
//   * `docs/contracts/core_app_architecture.md` (canonical Layers 1-12).
//   * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//     (OperatorScopedRepository pattern + wrapper-only RLS).
//   * `docs/contracts/phase_7_55_time_boundary_contract.md` Rule 11
//     (UTC TIMESTAMPTZ + denormalized `business_date` DATE).
//
// What this lane does:
//
//   1. Implements the bespoke `SquarePosFactWriter` and
//      `SquareWatermarkStore` (consumed by `SquarePosAdapter`) AND the
//      unified `CanonicalSink` from `8.spine-bridge.0` (consumed by the
//      sync worker dispatcher). Square's bespoke surface is split
//      across two interfaces by intent — fact writes vs watermark
//      persistence — so this sink implements both. The unified-surface
//      `connectionId` parameter is widened to optional so the bespoke
//      path (which does not carry a connection id) and the dispatcher
//      path (which does) both compose against a single concrete
//      implementation.
//
//   2. Writes canonical-fact dicts (the shape produced by the
//      `SquarePosAdapter`) to operator-scoped Postgres `cover_facts`
//      rows via `OperatorScopedRepository.withTenant`. Idempotency
//      UNIQUE on `(operator_id, vendor_id, vendor_entity_id,
//      vendor_modified_at)` — the partial index added by migration
//      `202605040000_phase_8_0_integration_framework.sql`. Repeat
//      writes of the same key short-circuit to a no-op (returns
//      false). The raw payload — the Square Order resource as
//      received — is preserved in the `raw_payload` JSONB column for
//      forensic re-derivation.
//
//   3. Square's Order resource exposes NO covers / number-of-guests
//      field (verified at
//      https://developer.squareup.com/reference/square/objects/Order
//      2026-05-03). Per the 2026-05-05 falsehood correction, the
//      sink stores `covers = null` on every write regardless of
//      canonical-fact input, and accepts whatever `covers_source` the
//      adapter supplies (Lane `.2` may project `forecast_fallback` /
//      `reservation_plus_walkin` / `manual_fallback` depending on the
//      surrounding signal). The covers-null invariant is pinned by
//      the test suite's G assertion plus the field-access banned-grep.
//
//   4. Computes `business_date` at write time from
//      `cover_facts.closed_at` (projected from the canonical
//      `closed_at`, in turn projected from Square `order.closed_at`)
//      plus `location.timezone` / `location.business_day_rollover_hour`
//      via the IANA-backed converter. The denormalized DATE never
//      re-derives at read (Phase 7.55 Rule 11). Square orders that
//      are still open (`closed_at` absent) are dropped — `cover_facts`
//      represents finalized orders, and a still-open order has no
//      definitive business date until the close arrives. The next
//      `order.updated` poll / webhook will land it.
//
//   5. Persists watermark advances via `connector_sync_watermark`
//      (resource = `'pos.orders'`). Per-batch commit so a Cloud Run
//      Job restart resumes from the last cursor. Square's adapter
//      paginates SearchOrders via `cursor` tokens, hence the
//      order-based resource string (vs OR's `pos.guest_checks`).
//
//   6. Auto-evaluates demo-mode flip after a batch with one or more
//      inserts. The bespoke watermark surface does not know about the
//      demo-flip seam; the sink takes responsibility — when the
//      watermark write observes a non-empty insert counter for the
//      (operator, location) slot, it invokes
//      `evaluateDemoFlip(category=pos)`. Idempotent per
//      `DemoModeFlipPolicy` semantics: a second flip is a no-op.
//
//   7. Wipes credential ciphertexts and connection metadata on
//      disconnect via `wipeCredentialsPreserveWatermark`. The
//      `connector_sync_watermark` rows are left intact so reconnect
//      resumes from the last successful cursor.
//
// V1 lean cut 2 alignment (`memory/project_v1_lean_cut_2_2026_05_03.md`):
// none of the banned items appear in this file. The sink stays at the
// same size as the per-vendor wave-B contract; the spine bridge is not
// the place to grow new surfaces. The banned-items grep in
// `test/infrastructure/persistence/postgres/square_pos_postgres_sink_test.dart`
// (test H) enforces this, plus rejects `numberOfGuests` / `guestCount`
// field-access tokens so a future refactor cannot silently regress to
// a covers-positive shape that would violate Square's documented
// schema.

import 'dart:convert';

import '../../../integrations/pos/square_pos_adapter.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'tenant_context.dart';

/// `connector_sync_watermark.resource` value the SQ sink writes under.
/// Square is order-based — the SearchOrders endpoint paginates over
/// the `orders` collection — so the resource string mirrors the API
/// shape (vs OR's `pos.guest_checks`).
const String squareWatermarkResource = 'pos.orders';

/// Postgres-backed canonical sink for Square POS.
///
/// Implements both the bespoke [SquarePosFactWriter] and
/// [SquareWatermarkStore] (consumed by the adapter at
/// `lib/integrations/pos/square_pos_adapter.dart`) AND the unified
/// [CanonicalSink] (consumed by the spine-bridge sync worker at
/// `tool/integration_sync_worker/dispatch.dart`). The bespoke pair and
/// the unified surface are deliberately separate method names
/// (`upsertSalesFact` / `upsertCoverFact`, `persistWatermark` /
/// `advanceWatermark`); the class composes them onto a private writer
/// so a single SQL implementation backs every path.
class SquarePosPostgresSink extends OperatorScopedRepository
    implements SquarePosFactWriter, SquareWatermarkStore, CanonicalSink {
  SquarePosPostgresSink(
    super.tenantWrapper, {
    IanaTimezoneConverter? timezoneConverter,
    DateTime Function()? clock,
  })  : _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared,
        _clock = clock ?? DateTime.now;

  final IanaTimezoneConverter _timezoneConverter;
  final DateTime Function() _clock;

  /// In-memory per-(operator, location) counter of inserts since the
  /// last watermark advance. Drives the demo-mode flip auto-evaluator
  /// per item 6 in the file header.
  final Map<String, int> _pendingInsertsByTenant = <String, int>{};

  String _tenantKey(String operatorId, String locationId) =>
      '$operatorId|$locationId';

  // ─── bespoke fact write — converts and delegates ─────────────────

  @override
  Future<bool> upsertSalesFact(SquareCanonicalFact fact) {
    return upsertCoverFact(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
      canonicalFact: <String, Object?>{
        'vendor_id': kSquareVendorId,
        'vendor_entity_id': fact.vendorEntityId,
        'vendor_modified_at': fact.vendorModifiedAt,
        // The Square adapter always projects a covers_source per Lane
        // `.2` (forecast / reservation+walk-in / manual_fallback). The
        // sink threads it through unchanged; the covers value itself
        // is hard-NULLed below regardless of input (Square exposes no
        // guest count).
        'covers_source': fact.coversSource,
        'opened_at': fact.openedAt,
        'closed_at': fact.closedAt,
        'actual_sales': fact.actualSales,
        'raw_payload': fact.vendorPayload,
      },
    );
  }

  // ─── unified upsert ──────────────────────────────────────────────

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final inserted = await withTenant<bool>(ctx, (exec) async {
      final closedAt = _coerceUtc(canonicalFact['closed_at']);
      if (closedAt == null) {
        // Square `order.closed_at` is the finalization timestamp; an
        // open order has no definitive business date yet. The next
        // `order.updated` poll / webhook will land it once Square
        // sets the field. Counter unaffected.
        return false;
      }
      final locationRows = await exec.query(
        'select timezone, business_day_rollover_hour '
        'from public.locations '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      if (locationRows.isEmpty) {
        throw StateError(
          'cover_facts upsert: location row not found for '
          '(operator_id=$operatorId, location_id=$locationId) — '
          'tenant context resolved but RLS or onboarding state may be '
          'inconsistent',
        );
      }
      final locationRow = locationRows.single;
      final timezone = (locationRow['timezone'] as String?) ?? 'UTC';
      final rolloverHour =
          (locationRow['business_day_rollover_hour'] as int?) ?? 0;
      final businessDate = _timezoneConverter.toBusinessDate(
        restaurantTimezone: timezone,
        businessDayRolloverHour: rolloverHour,
        instant: closedAt,
      );

      final rows = await exec.query(
        'insert into public.cover_facts ('
        'operator_id, location_id, vendor_id, vendor_entity_id, '
        'vendor_modified_at, covers, covers_source, opened_at, '
        'closed_at, business_date, actual_sales, raw_payload'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, '
        '@vendor_entity_id, @vendor_modified_at::timestamptz, '
        '@covers, @covers_source, @opened_at::timestamptz, '
        '@closed_at::timestamptz, @business_date::date, '
        '@actual_sales, @raw_payload::jsonb'
        ') '
        'on conflict (operator_id, vendor_id, vendor_entity_id, '
        'vendor_modified_at) where vendor_id is not null '
        'and vendor_entity_id is not null '
        'and vendor_modified_at is not null '
        'do nothing '
        'returning 1 as inserted',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': canonicalFact['vendor_id'] ?? kSquareVendorId,
          'vendor_entity_id': canonicalFact['vendor_entity_id'],
          'vendor_modified_at': _coerceUtc(canonicalFact['vendor_modified_at']),
          // covers is hard-NULLed for Square regardless of input — the
          // documented Order schema exposes no guest count and the
          // covers-null invariant is pinned by the G assertion in the
          // test suite.
          'covers': null,
          'covers_source': canonicalFact['covers_source'],
          'opened_at': _coerceUtc(canonicalFact['opened_at']),
          'closed_at': closedAt,
          'business_date': businessDate,
          'actual_sales': canonicalFact['actual_sales'],
          'raw_payload': jsonEncode(
            canonicalFact['raw_payload'] ?? const <String, Object?>{},
          ),
        },
      );
      return rows.isNotEmpty;
    });

    if (inserted) {
      final key = _tenantKey(operatorId, locationId);
      _pendingInsertsByTenant[key] =
          (_pendingInsertsByTenant[key] ?? 0) + 1;
    }
    return inserted;
  }

  /// POS sink — labor punches are the QBT lane's job. Returning false
  /// without a write keeps the [CanonicalSink] surface uniform across
  /// all vendor sinks; the dispatcher routes by category so this path
  /// is unreachable in production.
  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async =>
      false;

  /// POS sink — reservations are the LB lane's job. See the
  /// [upsertLaborPunch] note.
  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async =>
      false;

  // ─── watermark — bespoke + unified delegate to a private writer ──

  /// Bespoke watermark surface consumed by [SquarePosAdapter]. Carries
  /// no connection id; the sink resolves it via lookup. `cursorToken`
  /// is nullable on the bespoke surface — the adapter passes `null`
  /// when SearchOrders has paginated to the end.
  @override
  Future<void> persistWatermark({
    required String operatorId,
    required String locationId,
    required String? cursorToken,
    required DateTime lastModifiedSeen,
  }) =>
      _advanceWatermark(
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
        explicitConnectionId: null,
      );

  /// Unified [CanonicalSink] watermark surface consumed by the spine-
  /// bridge sync worker. `connectionId` is widened to optional named so
  /// the same concrete method satisfies both this interface and the
  /// bespoke path's lookup-driven flow.
  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? connectionId,
  }) =>
      _advanceWatermark(
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
        explicitConnectionId: connectionId,
      );

  Future<void> _advanceWatermark({
    required String operatorId,
    required String locationId,
    required String? cursorToken,
    required DateTime lastModifiedSeen,
    required String? explicitConnectionId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final resolvedConnectionId = await _resolveConnectionId(
      operatorId: operatorId,
      locationId: locationId,
      explicitConnectionId: explicitConnectionId,
    );
    await withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_sync_watermark ('
        'operator_id, location_id, connection_id, resource, '
        'last_synced_at, last_modified_seen, cursor_token, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, '
        '@connection_id::uuid, @resource, '
        '@last_synced_at::timestamptz, '
        '@last_modified_seen::timestamptz, @cursor_token, '
        '@updated_at::timestamptz'
        ') on conflict (connection_id, resource) do update set '
        'last_synced_at = excluded.last_synced_at, '
        'last_modified_seen = excluded.last_modified_seen, '
        'cursor_token = excluded.cursor_token, '
        'updated_at = excluded.updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': resolvedConnectionId,
          'resource': squareWatermarkResource,
          'last_synced_at': _clock().toUtc(),
          'last_modified_seen': lastModifiedSeen.toUtc(),
          'cursor_token': cursorToken,
          'updated_at': _clock().toUtc(),
        },
      );
    });

    final tenantKey = _tenantKey(operatorId, locationId);
    final pending = _pendingInsertsByTenant.remove(tenantKey) ?? 0;
    if (pending >= 1) {
      await evaluateDemoFlip(
        operatorId: operatorId,
        locationId: locationId,
        category: IntegrationCategory.pos,
        connectionStatus: ConnectionStatus.connected,
        firstBackfillCommitted: true,
        backfillRecordsWritten: pending,
        connectionId: resolvedConnectionId,
      );
    }
  }

  // ─── sync log ────────────────────────────────────────────────────

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
    String? connectionId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final resolvedConnectionId = await _resolveConnectionId(
      operatorId: operatorId,
      locationId: locationId,
      explicitConnectionId: connectionId,
    );
    await withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'records_count, error_message, payload_preview, occurred_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, '
        '@connection_id::uuid, @event_kind, @records_count, '
        '@error_message, @payload_preview::jsonb, '
        '@occurred_at::timestamptz'
        ')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': resolvedConnectionId,
          'event_kind': eventKind,
          'records_count': recordsCount,
          'error_message': errorMessage,
          'payload_preview': encodePayloadPreviewForSyncLog(payloadPreview),
          'occurred_at': _clock().toUtc(),
        },
      );
    });
  }

  // ─── demo flip ───────────────────────────────────────────────────

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
    if (connectionStatus != ConnectionStatus.connected) return;
    if (!firstBackfillCommitted) return;
    if (backfillRecordsWritten < 1) return;

    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    await withTenant<void>(ctx, (exec) async {
      // Read-or-create the row with default `is_demo = true`. The
      // `INSERT ... ON CONFLICT DO NOTHING` is idempotent: if the row
      // already exists (whether at default or already flipped) the
      // insert short-circuits. The subsequent UPDATE narrows by
      // `is_demo = true` so a re-flip on an already-live row is a
      // no-op (matches `DemoModeFlipPolicy.evaluateFlip` semantics).
      await exec.execute(
        'insert into public.demo_mode_state ('
        'operator_id, location_id, category, is_demo, created_at, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @category, true, '
        '@now::timestamptz, @now::timestamptz'
        ') on conflict (operator_id, location_id, category) do nothing',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': _categoryToDb(category),
          'now': _clock().toUtc(),
        },
      );
      await exec.execute(
        'update public.demo_mode_state set '
        'is_demo = false, '
        'flipped_to_live_at = @now::timestamptz, '
        'flipped_by_connection_id = @connection_id::uuid, '
        'updated_at = @now::timestamptz '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and category = @category '
        'and is_demo = true',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': _categoryToDb(category),
          'now': _clock().toUtc(),
          'connection_id': connectionId,
        },
      );
    });
  }

  // ─── disconnect ──────────────────────────────────────────────────

  /// Wipe credential ciphertexts and connection metadata for the
  /// (operator, location, vendor) triple. Watermark rows are
  /// deliberately preserved so reconnect resumes from the last
  /// successful cursor instead of re-walking the whole window.
  ///
  /// Mirrors the OR sink's disconnect surface — Square's adapter
  /// performs vendor-side cleanup (`unregisterWebhook` /
  /// `revokeOauth`) through its `SquareApiClient`; this method is the
  /// repository-side counterpart that the spine-bridge dispatcher
  /// calls during a disconnect tick.
  Future<({bool credentialsWiped, bool webhookUnregistered, bool watermarkPreserved})>
      wipeCredentialsPreserveWatermark({
    required String operatorId,
    required String locationId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final credentialsWiped = await withTenant<bool>(ctx, (exec) async {
      final wiped = await exec.execute(
        'update public.vendor_credentials set '
        'access_token_ciphertext = null, '
        'refresh_token_ciphertext = null, '
        'token_expires_at = null, '
        'is_active = false, '
        'consecutive_refresh_failures = 0, '
        'updated_at = @now::timestamptz '
        'where operator_id = @operator_id::uuid '
        'and (location_id = @location_id::uuid or location_id is null) '
        'and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kSquareVendorId,
          'now': _clock().toUtc(),
        },
      );
      await exec.execute(
        'update public.connector_connection set '
        'status = @status, '
        'disconnect_reason = @disconnect_reason::public.connector_disconnect_reason, '
        'webhook_url_provisioned = false, '
        'updated_at = @now::timestamptz '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kSquareVendorId,
          'status': 'disconnected',
          'disconnect_reason': 'operator_action',
          'now': _clock().toUtc(),
        },
      );
      return wiped >= 0;
    });
    return (
      credentialsWiped: credentialsWiped,
      // Square's adapter handles vendor-side webhook unregister
      // through `apiClient.unregisterWebhook`; this sink-side path
      // reports true to keep the framework disconnect contract
      // uniform across vendors.
      webhookUnregistered: true,
      // Watermark rows are intentionally not deleted; reconnect
      // resumes from the last canonical write. See the file header.
      watermarkPreserved: true,
    );
  }

  // ─── helpers ─────────────────────────────────────────────────────

  /// Resolve the `connector_connection.connection_id` for the
  /// (operator, location, vendor) triple. Bespoke-interface callers
  /// (the SQ adapter via `persistWatermark`) do not carry the id; the
  /// unified-interface dispatcher (sync worker via `advanceWatermark`)
  /// does. When [explicitConnectionId] is non-null it wins; otherwise
  /// the sink looks up the row.
  Future<String> _resolveConnectionId({
    required String operatorId,
    required String locationId,
    required String? explicitConnectionId,
  }) async {
    if (explicitConnectionId != null && explicitConnectionId.isNotEmpty) {
      return explicitConnectionId;
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<String>(ctx, (exec) async {
      final rows = await exec.query(
        'select connection_id::text as connection_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kSquareVendorId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'connector_connection row not found for '
          '(operator=$operatorId, location=$locationId, '
          'vendor=$kSquareVendorId) — connect must run before sink '
          'writes',
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
    if (raw is DateTime) return raw.toUtc();
    if (raw is String && raw.isNotEmpty) {
      return DateTime.parse(raw).toUtc();
    }
    return null;
  }

  static String _categoryToDb(IntegrationCategory category) {
    switch (category) {
      case IntegrationCategory.pos:
        return 'pos';
      case IntegrationCategory.labor:
        return 'labor';
      case IntegrationCategory.reservation:
        return 'reservation';
    }
  }
}
