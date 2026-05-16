// Phase 8 / Wave B `8.spine-bridge.1.LSK` — Lightspeed Restaurant
// K-Series Postgres-backed canonical sink.
//
// Spine reference:
//   * `docs/contracts/integration_spine_architecture_contract.md`
//     section "8.spine-bridge.1.LSK" (binding).
//   * `docs/contracts/core_app_architecture.md` (canonical Layers 1-12).
//   * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//     (OperatorScopedRepository pattern + wrapper-only RLS).
//   * `docs/contracts/phase_7_55_time_boundary_contract.md` Rule 11
//     (UTC TIMESTAMPTZ + denormalized `business_date` DATE).
//
// What this lane does:
//
//   1. Implements both the bespoke `LightspeedLskGateway` (consumed by
//      `LightspeedLskPosAdapter`) AND the unified `CanonicalSink` from
//      `8.spine-bridge.0` (consumed by the sync worker dispatcher). The
//      two interfaces collide on `appendSyncLog`; the class widens the
//      collision by relaxing `operatorId` / `locationId` from required
//      (CanonicalSink) to optional named (so bespoke callers can omit
//      them and unified callers pass them through). The bespoke path
//      resolves tenant from `connection_id` via a system-scoped
//      `connector_connection` lookup; the unified path uses the
//      tenant the dispatcher already carries.
//
//   2. Writes canonical-fact dicts to operator-scoped Postgres
//      `cover_facts` rows via `OperatorScopedRepository.withTenant`.
//      Idempotency UNIQUE on `(operator_id, vendor_id,
//      vendor_entity_id, vendor_modified_at)` — the partial index added
//      by migration `202605040000_phase_8_0_integration_framework.sql`.
//      Repeat writes of the same key short-circuit to a no-op (returns
//      false). The vendor-shape sale payload — preserved on the
//      canonical-fact dict's `raw_payload` key — lands in the
//      `raw_payload` JSONB column for forensic re-derivation.
//
//   3. Computes `business_date` at write time from
//      `cover_facts.closed_at` (projected from canonical `closed_at`,
//      in turn projected from the K-Series `timeClosed` field) via the
//      canonical `BusinessTimingProfilesRepository` →
//      `BusinessTimingProfileResolver` → `BusinessDateResolver` chain
//      (Per-Daypart V1 / Slice 7b option (b), 2026-05-15). The chain
//      honors operator → org_unit → location precedence per HP #11 and
//      consumes a sub-hour-aware HH:MM cutoff per Gap 46. The sink
//      reads `location.timezone` only — it no longer reads
//      `location.business_day_rollover_hour` (deprecated in Slice 7b).
//      The denormalized DATE never re-derives at read (Phase 7.55
//      Rule 11). The bespoke `writeSalesFact` seam carries
//      `restaurantTimezone` and `businessDayRolloverHour` parameters;
//      the sink ignores `businessDayRolloverHour` in favor of the
//      canonical timing chain so multiple writers cannot disagree on
//      the projection inputs.
//
//   4. Persists watermark advances via `connector_sync_watermark`
//      (resource = `'pos.guest_checks'`). Per-batch commit so a Cloud
//      Run Job restart resumes from the last cursor. Lightspeed
//      K-Series is webhook-first; `pos.guest_checks` covers both the
//      backfill / poll path and the webhook delivery path because the
//      sink does not care which transport produced the canonical-fact
//      row.
//
//   5. Auto-evaluates demo-mode flip after a batch with one or more
//      inserts. The bespoke adapter does not know about the demo-flip
//      surface; the sink takes responsibility — when `updateWatermark`
//      (bespoke) or `advanceWatermark` (unified) observes a non-empty
//      insert counter for the (operator, location) slot, it invokes
//      `evaluateDemoFlip(category=pos)`. Idempotent per
//      `DemoModeFlipPolicy` semantics: a second flip is a no-op.
//
//   6. Wipes credential ciphertexts and connection metadata on
//      disconnect via `wipeCredentialsAndDisconnect`. The
//      `connector_sync_watermark` rows are left intact so reconnect
//      resumes from the last successful cursor.
//
// V1 lean cut 2 alignment (`memory/project_v1_lean_cut_2_2026_05_03.md`):
// none of the banned items appear in this file. The sink stays at the
// same size as the per-vendor wave-B contract; the spine bridge is not
// the place to grow new surfaces. The banned-items grep in
// `test/infrastructure/persistence/postgres/lightspeed_lsk_pos_postgres_sink_test.dart`
// (test H) enforces this.

import 'dart:convert';

import '../../../integrations/pos/lightspeed_lsk_pos_adapter.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/sink_business_date_projector.dart';

import '../../../services/integration/integration_adapter_common.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'repositories/business_timing_profiles_repository.dart';
import 'tenant_context.dart';

/// `connector_sync_watermark.resource` value the LSK sink writes under.
/// The framework uses this to disambiguate when the same connection
/// later acquires a second resource (e.g. paid_in_outs) without a
/// schema change. K-Series exposes one resource at V1: guest checks /
/// sales — the same canonical-fact target whether the row arrives via
/// poll or webhook.
const String lightspeedLskWatermarkResource = 'pos.guest_checks';

/// Postgres-backed canonical sink for Lightspeed Restaurant K-Series.
///
/// Implements both the bespoke [LightspeedLskGateway] (consumed by the
/// adapter at `lib/integrations/pos/lightspeed_lsk_pos_adapter.dart`)
/// AND the unified [CanonicalSink] (consumed by the spine-bridge sync
/// worker at `tool/integration_sync_worker/dispatch.dart`). The two
/// interfaces overlap on `appendSyncLog`; the class widens that
/// signature so a single concrete method satisfies both.
class LightspeedLskPosPostgresSink extends OperatorScopedRepository
    implements LightspeedLskGateway, CanonicalSink {
  LightspeedLskPosPostgresSink(
    super.tenantWrapper, {
    IanaTimezoneConverter? timezoneConverter,
    SinkBusinessDateProjector? businessDateProjector,
    BusinessTimingProfilesRepository? profilesRepository,
    DateTime Function()? clock,
  })  : _businessDateProjector = businessDateProjector ??
            SinkBusinessDateProjector(
              profilesRepository: profilesRepository ??
                  BusinessTimingProfilesRepository(tenantWrapper),
              timezoneConverter:
                  timezoneConverter ?? IanaTimezoneConverter.shared,
            ),
        _clock = clock ?? DateTime.now;

  // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): Lightspeed K-Series
  // no longer reads `locations.business_day_rollover_hour`. The cutoff
  // is resolved through the canonical `BusinessTimingProfilesRepository`
  // chain inside the projector.
  final SinkBusinessDateProjector _businessDateProjector;
  final DateTime Function() _clock;

  // ─── LightspeedLskGateway: binding lookup ────────────────────────

  @override
  Future<LightspeedLskConnectionBinding?> lookupBinding({
    required String operatorId,
    required String locationId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<LightspeedLskConnectionBinding?>(ctx, (exec) async {
      final rows = await exec.query(
        'select connection_id::text as connection_id, '
        "metadata->>'business_id' as business_id, "
        'credential_id::text as credential_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and vendor_id = @vendor_id '
        "and status = 'connected' "
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kLightspeedLskVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      return LightspeedLskConnectionBinding(
        connectionId: row['connection_id'] as String,
        businessId: (row['business_id'] as String?) ?? '',
        accessTokenCredentialId: (row['credential_id'] as String?) ?? '',
      );
    });
  }

  @override
  Future<LightspeedLskDisconnectBinding?> lookupDisconnectBinding({
    required String operatorId,
    required String locationId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<LightspeedLskDisconnectBinding?>(ctx, (exec) async {
      final rows = await exec.query(
        'select connection_id::text as connection_id, '
        "metadata->>'business_id' as business_id, "
        "metadata->>'webhook_subscription_id' as webhook_subscription_id, "
        'credential_id::text as credential_id '
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kLightspeedLskVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      return LightspeedLskDisconnectBinding(
        connectionId: row['connection_id'] as String,
        businessId: (row['business_id'] as String?) ?? '',
        accessTokenCredentialId: (row['credential_id'] as String?) ?? '',
        webhookSubscriptionId:
            (row['webhook_subscription_id'] as String?) ?? '',
      );
    });
  }

  // ─── Cover-facts upsert (bespoke + unified) ──────────────────────

  @override
  Future<bool> writeSalesFact({
    required TenantContext tenant,
    required String connectionId,
    required String vendorEntityId,
    required DateTime openedAtUtc,
    required DateTime closedAtUtc,
    required int covers,
    required double actualSales,
    required String restaurantTimezone,
    required int businessDayRolloverHour,
    required DateTime vendorModifiedAtUtc,
  }) {
    return _upsertCoverFactInternal(
      operatorId: tenant.operatorId,
      locationId: tenant.locationId,
      vendorEntityId: vendorEntityId,
      openedAt: openedAtUtc.toUtc(),
      closedAt: closedAtUtc.toUtc(),
      covers: covers,
      actualSales: actualSales,
      vendorModifiedAt: vendorModifiedAtUtc.toUtc(),
      coversSource: 'direct',
      rawPayload: const <String, Object?>{},
    );
  }

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) {
    final closedAt = _coerceUtc(canonicalFact['closed_at']);
    if (closedAt == null) {
      return Future<bool>.value(false);
    }
    final openedAt = _coerceUtc(canonicalFact['opened_at']) ?? closedAt;
    final vendorModifiedAt =
        _coerceUtc(canonicalFact['vendor_modified_at']) ?? closedAt;
    final coversRaw = canonicalFact['covers'];
    final covers = coversRaw is int
        ? coversRaw
        : coversRaw is num
            ? coversRaw.round()
            : 0;
    final actualSalesRaw = canonicalFact['actual_sales'];
    final actualSales =
        actualSalesRaw is num ? actualSalesRaw.toDouble() : 0.0;
    final coversSource =
        (canonicalFact['covers_source'] as String?) ?? 'direct';
    final rawPayload = canonicalFact['raw_payload'] is Map<String, Object?>
        ? canonicalFact['raw_payload']! as Map<String, Object?>
        : const <String, Object?>{};
    return _upsertCoverFactInternal(
      operatorId: operatorId,
      locationId: locationId,
      vendorEntityId: (canonicalFact['vendor_entity_id'] ?? '').toString(),
      openedAt: openedAt,
      closedAt: closedAt,
      covers: covers,
      actualSales: actualSales,
      vendorModifiedAt: vendorModifiedAt,
      coversSource: coversSource,
      rawPayload: rawPayload,
    );
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

  Future<bool> _upsertCoverFactInternal({
    required String operatorId,
    required String locationId,
    required String vendorEntityId,
    required DateTime openedAt,
    required DateTime closedAt,
    required int covers,
    required double actualSales,
    required DateTime vendorModifiedAt,
    required String coversSource,
    required Map<String, Object?> rawPayload,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    final inserted = await withTenant<bool>(ctx, (exec) async {
      // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): the SELECT
      // returns `timezone` only — no `business_day_rollover_hour`.
      final locationRows = await exec.query(
        'select timezone '
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
      final businessDate = _formatDate(
        await _businessDateProjector.projectBusinessDate(
          operatorId: operatorId,
          locationId: locationId,
          restaurantTimezone: timezone,
          instantUtc: closedAt,
        ),
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
          'vendor_id': kLightspeedLskVendorId,
          'vendor_entity_id': vendorEntityId,
          'vendor_modified_at': vendorModifiedAt,
          'covers': covers,
          'covers_source': coversSource,
          'opened_at': openedAt,
          'closed_at': closedAt,
          'business_date': businessDate,
          'actual_sales': actualSales,
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

  // ─── Watermark + sync log ────────────────────────────────────────

  @override
  Future<void> updateWatermark({
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeenUtc,
  }) async {
    final tenant = await _resolveTenantFromConnection(connectionId);
    return _writeWatermarkAndMaybeFlip(
      operatorId: tenant.operatorId,
      locationId: tenant.locationId,
      connectionId: connectionId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeenUtc,
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
    return _writeWatermarkAndMaybeFlip(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

  Future<void> _writeWatermarkAndMaybeFlip({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
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
          'connection_id': connectionId,
          'resource': lightspeedLskWatermarkResource,
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
              'connection_id': connectionId,
            },
          );
        }
      }
    });
  }

  @override
  Future<void> appendSyncLog({
    String? operatorId,
    String? locationId,
    required String connectionId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
  }) async {
    final resolvedOp = operatorId;
    final resolvedLoc = locationId;
    final tenant = (resolvedOp != null && resolvedLoc != null)
        ? (operatorId: resolvedOp, locationId: resolvedLoc)
        : await _resolveTenantFromConnection(connectionId);
    final ctx = TenantContext(
      operatorId: tenant.operatorId,
      locationId: tenant.locationId,
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
          'operator_id': tenant.operatorId,
          'location_id': tenant.locationId,
          'connection_id': connectionId,
          'event_kind': eventKind,
          'records_count': recordsCount,
          'error_message': errorMessage,
          'payload_preview': encodePayloadPreviewForSyncLog(payloadPreview),
          'occurred_at': _clock().toUtc(),
        },
      );
    });
  }

  // ─── Demo flip ────────────────────────────────────────────────────

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
      // INSERT ... ON CONFLICT DO NOTHING is idempotent: if the row
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

  // ─── Connect + disconnect ────────────────────────────────────────

  @override
  Future<String> upsertConnection({
    required TenantContext tenant,
    required String vendorBusinessId,
    required String accessTokenCredentialId,
    required String refreshTokenCredentialId,
    required DateTime tokenExpiresAtUtc,
  }) async {
    return withTenant<String>(tenant, (exec) async {
      final rows = await exec.query(
        'insert into public.connector_connection ('
        'operator_id, location_id, vendor_id, category, status, '
        'metadata, credential_id, last_sync_at, '
        'webhook_url_provisioned, created_at, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, '
        "'pos', 'connected', "
        '@metadata::jsonb, @credential_id::uuid, '
        '@now::timestamptz, false, @now::timestamptz, @now::timestamptz'
        ') on conflict (operator_id, location_id, vendor_id, '
        "coalesce(module, '')) do update set "
        "status = 'connected', "
        'metadata = excluded.metadata, '
        'credential_id = excluded.credential_id, '
        'disconnect_reason = null, '
        'updated_at = excluded.updated_at '
        'returning connection_id::text as connection_id',
        parameters: <String, Object?>{
          'operator_id': tenant.operatorId,
          'location_id': tenant.locationId,
          'vendor_id': kLightspeedLskVendorId,
          'metadata': jsonEncode(<String, Object?>{
            'business_id': vendorBusinessId,
          }),
          'credential_id': accessTokenCredentialId,
          'now': _clock().toUtc(),
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'connector_connection upsert returned no rows for '
          '(operator=${tenant.operatorId}, location=${tenant.locationId})',
        );
      }
      return rows.single['connection_id'] as String;
    });
  }

  @override
  Future<void> wipeCredentialsAndDisconnect({
    required TenantContext tenant,
    required String connectionId,
    required DisconnectReason reason,
  }) async {
    await withTenant<void>(tenant, (exec) async {
      await exec.execute(
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
          'operator_id': tenant.operatorId,
          'location_id': tenant.locationId,
          'vendor_id': kLightspeedLskVendorId,
          'now': _clock().toUtc(),
        },
      );
      await exec.execute(
        'update public.connector_connection set '
        "status = 'disconnected', "
        'disconnect_reason = @disconnect_reason::public.connector_disconnect_reason, '
        'webhook_url_provisioned = false, '
        'updated_at = @now::timestamptz '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and connection_id = @connection_id::uuid '
        'and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': tenant.operatorId,
          'location_id': tenant.locationId,
          'connection_id': connectionId,
          'vendor_id': kLightspeedLskVendorId,
          'disconnect_reason': _disconnectReasonToDb(reason),
          'now': _clock().toUtc(),
        },
      );
    });
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  /// Resolve `(operator_id, location_id)` for [connectionId]. The
  /// bespoke gateway methods that carry only [connectionId]
  /// (`updateWatermark`, `appendSyncLog`) need tenant context to enter
  /// `withTenant`. The `connector_connection` table is operator-scoped
  /// with RLS; reading without tenant context requires the system
  /// path. Every system read is audited via the
  /// `app.bypass_rls_audit = 'system:...'` marker the wrapper sets.
  Future<({String operatorId, String locationId})>
      _resolveTenantFromConnection(String connectionId) {
    return withSystem<({String operatorId, String locationId})>(
      (exec) async {
        final rows = await exec.query(
          'select operator_id::text as operator_id, '
          'location_id::text as location_id '
          'from public.connector_connection '
          'where connection_id = @connection_id::uuid '
          'limit 1',
          parameters: <String, Object?>{
            'connection_id': connectionId,
          },
        );
        if (rows.isEmpty) {
          throw StateError(
            'connector_connection row not found for '
            'connection_id=$connectionId — bespoke gateway call '
            'arrived before connect, or the connection was deleted',
          );
        }
        final row = rows.single;
        return (
          operatorId: row['operator_id'] as String,
          locationId: row['location_id'] as String,
        );
      },
      reason: 'lightspeed_lsk_postgres_sink._resolveTenantFromConnection',
    );
  }

  static DateTime? _coerceUtc(Object? raw) {
    if (raw is DateTime) return raw.toUtc();
    if (raw is String && raw.isNotEmpty) {
      return DateTime.parse(raw).toUtc();
    }
    return null;
  }

  /// Format the projector's UTC-midnight `DateTime` as 'YYYY-MM-DD' for
  /// the `cover_facts.business_date::date` cast (Per-Daypart V1 / Slice
  /// 7b option (b)).
  static String _formatDate(DateTime value) {
    final utc = value.toUtc();
    final yyyy = utc.year.toString().padLeft(4, '0');
    final mm = utc.month.toString().padLeft(2, '0');
    final dd = utc.day.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd';
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

  static String _disconnectReasonToDb(DisconnectReason reason) {
    switch (reason) {
      case DisconnectReason.operatorAction:
        return 'operator_action';
      case DisconnectReason.vendorRevoked:
        return 'vendor_revoked';
      case DisconnectReason.vendorEndpointDeprecated:
        return 'vendor_endpoint_deprecated';
      case DisconnectReason.oauthTimeout:
        return 'oauth_timeout';
    }
  }
}
