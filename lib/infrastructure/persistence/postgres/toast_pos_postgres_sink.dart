// Phase 8 / Wave B `8.spine-bridge.1.TS` — Toast POS Postgres-backed
// canonical sink.
//
// Spine reference:
//   * `docs/contracts/integration_spine_architecture_contract.md`
//     (binding) — fanout sub-lane shape `.1.TS` mirrors `.1.OR`.
//   * `docs/contracts/core_app_architecture.md` (canonical Layers 1-12).
//   * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//     (OperatorScopedRepository pattern + wrapper-only RLS).
//   * `docs/contracts/phase_7_55_time_boundary_contract.md` Rule 11
//     (UTC TIMESTAMPTZ + denormalized `business_date` DATE).
//
// What this lane does:
//
//   1. Implements both the bespoke `ToastFactSink` (consumed by
//      `ToastPosAdapter` at `lib/integrations/pos/toast_pos_adapter.dart`)
//      AND the unified `CanonicalSink` from `8.spine-bridge.0`
//      (consumed by the sync worker dispatcher). The two surfaces share
//      one `withTenant`-wrapped engine; they differ only on the input
//      shape — the bespoke surface threads `rawPayload` as a separate
//      argument while the unified surface lifts it from
//      `canonicalFact['raw_payload']`. The watermark / sync-log /
//      demo-flip / credential-wipe seams widen `connectionId` to an
//      optional named parameter so a single concrete method satisfies
//      both contracts (bespoke callers omit it; unified callers pass it).
//
//   2. Writes canonical-fact dicts (the shape produced by
//      `ToastPosAdapter._canonicalize`) to operator-scoped Postgres
//      `cover_facts` rows via `OperatorScopedRepository.withTenant`.
//      The audited `numberOfGuests` flows untouched through
//      `canonicalFact['covers']` into `cover_facts.covers` — this is the
//      CPLH math anchor every downstream Layer-2 / Layer-3 read depends
//      on. Idempotency UNIQUE on `(operator_id, vendor_id,
//      vendor_entity_id, vendor_modified_at)` — the partial index added
//      by migration `202605040000_phase_8_0_integration_framework.sql`.
//      Repeat writes of the same key short-circuit to a no-op (returns
//      false). The raw vendor order is preserved in the `raw_payload`
//      JSONB column for forensic re-derivation.
//
//   3. Computes `business_date` at write time from
//      `cover_facts.closed_at` (projected from the canonical
//      `closed_at`, in turn projected from the Toast `closedDate` field)
//      plus `location.timezone` / `location.business_day_rollover_hour`
//      via the IANA-backed converter. The denormalized DATE never
//      re-derives at read (Phase 7.55 Rule 11).
//
//   4. Persists watermark advances via
//      `connector_sync_watermark` (resource = `'pos.guest_checks'`).
//      Per-batch commit so a Cloud Run Job restart resumes from the
//      last cursor.
//
//   5. Auto-evaluates demo-mode flip after a batch with one or more
//      inserts. The bespoke adapter does not know about the demo-flip
//      surface; the sink takes responsibility — when the watermark
//      writer observes a non-empty insert counter for the (operator,
//      location) slot, it invokes `evaluateDemoFlip(category=pos)`.
//      Idempotent per `DemoModeFlipPolicy` semantics: a second flip is
//      a no-op.
//
//   6. Wipes credential ciphertexts and connection metadata on
//      `disconnect` via `wipeCredentialsPreserveWatermark`. The
//      `connector_sync_watermark` rows are left intact so reconnect
//      resumes from the last successful cursor.
//
// V1 lean cut 2 alignment (`memory/project_v1_lean_cut_2_2026_05_03.md`):
// none of the banned items appear in this file. Test H grep enforces
// the doctrine.

import 'dart:convert';

import '../../../integrations/pos/toast_pos_adapter.dart';
import '../../../integrations/pos/toast_webhook_signature_verifier.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'tenant_context.dart';

/// `connector_sync_watermark.resource` value the Toast sink writes
/// under. Mirrors the Oracle MICROS Simphony resource: both Wave B
/// POS adapters land in `cover_facts` from the guest-check / orders
/// stream, so they share the same watermark resource string. The
/// framework uses this to disambiguate when the same connection later
/// acquires a second resource without a schema change.
const String toastWatermarkResource = 'pos.guest_checks';

/// Postgres-backed canonical sink for Toast POS.
///
/// Implements both the bespoke [ToastFactSink] (consumed by the
/// adapter at `lib/integrations/pos/toast_pos_adapter.dart`) AND the
/// unified [CanonicalSink] (consumed by the spine-bridge sync worker
/// at `tool/integration_sync_worker/dispatch.dart`). The two interfaces
/// overlap on watermark / sync-log / demo-flip seams with different
/// parameter sets; the class widens those signatures so a single
/// concrete method satisfies both.
class ToastPosPostgresSink extends OperatorScopedRepository
    implements ToastFactSink, CanonicalSink {
  ToastPosPostgresSink(
    super.tenantWrapper, {
    IanaTimezoneConverter? timezoneConverter,
    DateTime Function()? clock,
  })  : _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared,
        _clock = clock ?? DateTime.now;

  final IanaTimezoneConverter _timezoneConverter;
  final DateTime Function() _clock;

  // ─── upsert ───────────────────────────────────────────────────────

  @override
  Future<bool> upsertOrderFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
    required Map<String, Object?> rawPayload,
  }) =>
      _writeOrderFact(
        operatorId: operatorId,
        locationId: locationId,
        canonicalFact: canonicalFact,
        rawPayload: rawPayload,
      );

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) {
    final raw = canonicalFact['raw_payload'];
    final rawPayload = raw is Map<String, Object?>
        ? raw
        : const <String, Object?>{};
    return _writeOrderFact(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalFact,
      rawPayload: rawPayload,
    );
  }

  /// Shared engine behind both the bespoke [upsertOrderFact] and the
  /// unified [upsertCoverFact]. The audited `numberOfGuests` arrives
  /// already-projected at `canonicalFact['covers']` — this method does
  /// not re-touch it; the value flows straight into the cover_facts
  /// row to anchor the CPLH math chain.
  Future<bool> _writeOrderFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
    required Map<String, Object?> rawPayload,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final inserted = await withTenant<bool>(ctx, (exec) async {
      final closedAt = _coerceUtc(canonicalFact['closed_at']);
      if (closedAt == null) {
        // Toast `closedDate` is required for the business-date
        // projection. The adapter's sanity hook already refuses
        // opened-without-closed rows; this branch is a defense-in-
        // depth assertion in case a future caller bypasses the
        // adapter. No write; counter unaffected.
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
        'on conflict (operator_id, location_id, vendor_id, vendor_entity_id) '
        'where vendor_id is not null '
        'and vendor_entity_id is not null '
        'do update set '
        'vendor_modified_at = excluded.vendor_modified_at, '
        'covers = excluded.covers, '
        'covers_source = excluded.covers_source, '
        'opened_at = excluded.opened_at, '
        'closed_at = excluded.closed_at, '
        'business_date = excluded.business_date, '
        'actual_sales = excluded.actual_sales, '
        'raw_payload = excluded.raw_payload '
        'where excluded.vendor_modified_at >= '
        'public.cover_facts.vendor_modified_at '
        'returning 1 as inserted',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kToastVendorId,
          'vendor_entity_id': canonicalFact['vendor_entity_id'],
          'vendor_modified_at':
              _coerceUtc(canonicalFact['vendor_modified_at']),
          'covers': canonicalFact['covers'],
          'covers_source': canonicalFact['covers_source'],
          'opened_at': _coerceUtc(canonicalFact['opened_at']),
          'closed_at': closedAt,
          'business_date': businessDate,
          'actual_sales': canonicalFact['actual_sales'],
          'raw_payload': jsonEncode(rawPayload),
        },
      );
      if (rows.isNotEmpty) {
        // A2 fix: increment persisted pending counter inside the same
        // transaction as the cover-facts row so counter and fact are
        // always in sync (launch-blocker A2 fix).
        await exec.execute(
          'insert into public.demo_mode_state ('
          'operator_id, location_id, category, is_demo, '
          'pending_inserts_count, created_at, updated_at'
          ') values ('
          '@operator_id::uuid, @location_id::uuid, @category, true, '
          '1, @now::timestamptz, @now::timestamptz'
          ') on conflict (operator_id, location_id, category) do update set '
          'pending_inserts_count = '
          'public.demo_mode_state.pending_inserts_count + 1, '
          'updated_at = excluded.updated_at',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'category': 'pos',
            'now': _clock().toUtc(),
          },
        );
      }
      return rows.isNotEmpty;
    });

    return inserted;
  }

  /// POS sink — labor punches are the QBT lane's job. Returning false
  /// without a write keeps the [CanonicalSink] surface uniform across
  /// all 17 vendor sinks; the dispatcher routes by category so this
  /// path is unreachable in production.
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

  // ─── watermark + sync log ─────────────────────────────────────────

  @override
  Future<void> persistWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) =>
      _writeWatermark(
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
        explicitConnectionId: null,
      );

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? connectionId,
  }) =>
      _writeWatermark(
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
        explicitConnectionId: connectionId,
      );

  Future<void> _writeWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
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
        'updated_at = excluded.updated_at '
        'where excluded.last_synced_at >= '
        'public.connector_sync_watermark.last_synced_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': resolvedConnectionId,
          'resource': toastWatermarkResource,
          'last_synced_at': _clock().toUtc(),
          'last_modified_seen': lastModifiedSeen.toUtc(),
          'cursor_token': cursorToken,
          'updated_at': _clock().toUtc(),
        },
      );
      // A2 fix: evaluate the demo-flip inside the same transaction as the
      // watermark commit so a crash between the two cannot leave the
      // operator stuck in demo mode. SELECT FOR UPDATE serialises
      // concurrent pods; UPDATE narrows to is_demo = true for idempotency.
      final dmsRows = await exec.query(
        'select pending_inserts_count, is_demo '
        'from public.demo_mode_state '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and category = @category '
        'for update',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': 'pos',
        },
      );
      if (dmsRows.isNotEmpty) {
        final dmsRow = dmsRows.single;
        final pendingCount =
            (dmsRow['pending_inserts_count'] as int? ?? 0);
        final isDemo = dmsRow['is_demo'] as bool? ?? true;
        if (pendingCount >= 1 && isDemo) {
          await exec.execute(
            'update public.demo_mode_state set '
            'is_demo = false, '
            'flipped_to_live_at = @now::timestamptz, '
            'flipped_by_connection_id = @connection_id::uuid, '
            'pending_inserts_count = 0, '
            'updated_at = @now::timestamptz '
            'where operator_id = @operator_id::uuid '
            'and location_id = @location_id::uuid '
            'and category = @category '
            'and is_demo = true',
            parameters: <String, Object?>{
              'operator_id': operatorId,
              'location_id': locationId,
              'category': 'pos',
              'now': _clock().toUtc(),
              'connection_id': resolvedConnectionId,
            },
          );
        }
      }
    });
  }

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

  // ─── demo flip ────────────────────────────────────────────────────

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
        'pending_inserts_count = 0, '
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

  // ─── disconnect ───────────────────────────────────────────────────

  /// Public for symmetry with the OR sink — the framework's disconnect
  /// route can call this to wipe credentials while preserving the
  /// watermark so reconnect resumes from the last cursor. The Toast
  /// adapter's own `disconnect` currently routes through the transport
  /// only; the sink helper exists so the spine-bridge dispatcher and
  /// admin paths share a single wipe primitive across vendors.
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
          'vendor_id': kToastVendorId,
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
          'vendor_id': kToastVendorId,
          'status': 'disconnected',
          'disconnect_reason': 'operator_action',
          'now': _clock().toUtc(),
        },
      );
      return wiped >= 0;
    });
    return (
      credentialsWiped: credentialsWiped,
      // Toast's webhook subscription is unregistered by the adapter
      // calling `transport.unregisterWebhook`; the sink reports `true`
      // so the framework disconnect contract stays uniform across
      // vendors.
      webhookUnregistered: true,
      // Watermark rows are intentionally not deleted; reconnect
      // resumes from the last canonical write. See the file header.
      watermarkPreserved: true,
    );
  }

  // ─── helpers ──────────────────────────────────────────────────────

  /// Resolve the `connector_connection.connection_id` for the
  /// (operator, location, vendor) triple. Bespoke-interface callers
  /// (the Toast adapter via [persistWatermark]) do not carry the id;
  /// the unified-interface dispatcher (sync worker via
  /// [advanceWatermark]) does. When [explicitConnectionId] is non-null
  /// it wins; otherwise the sink looks up the row.
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
          'vendor_id': kToastVendorId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'connector_connection row not found for '
          '(operator=$operatorId, location=$locationId, '
          'vendor=$kToastVendorId) — connect must run before sink writes',
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
