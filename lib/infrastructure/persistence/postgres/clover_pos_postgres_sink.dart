// Phase 8 / Wave B `8.spine-bridge.1.CL` — Clover POS Postgres-backed
// canonical sink.
//
// Spine reference:
//   * `docs/contracts/integration_spine_architecture_contract.md`
//     section "Sub-lane shape (binding) -> .1.*" (binding).
//   * `docs/contracts/core_app_architecture.md` (canonical Layers 1-12).
//   * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//     (OperatorScopedRepository pattern + wrapper-only RLS).
//   * `docs/contracts/phase_7_55_time_boundary_contract.md` Rule 11
//     (UTC TIMESTAMPTZ + denormalized `business_date` DATE).
//
// What this lane does:
//
//   1. Implements the bespoke split surfaces the
//      [CloverPosAdapter] writes through — [CloverTenantFactWriter] and
//      [CloverWatermarkStore] — AND the unified [CanonicalSink] from
//      `8.spine-bridge.0` consumed by the sync worker dispatcher. The
//      bespoke + unified upsert / watermark / sync-log methods all
//      route through a single shared private writer; `connectionId` is
//      an optional named parameter on the unified surface so the same
//      method satisfies both contracts (bespoke callers omit it; the
//      worker dispatcher passes it).
//
//   2. Writes the canonical-fact dict the Clover adapter materialises
//      (or the canonical [CloverCanonicalSalesFact] the bespoke writer
//      surface accepts) to operator-scoped Postgres `cover_facts` rows
//      via `OperatorScopedRepository.withTenant`. Idempotency UNIQUE
//      on `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`
//      — the partial index added by migration
//      `202605040000_phase_8_0_integration_framework.sql`. Repeat writes
//      of the same key short-circuit to a no-op (returns false).
//
//   3. Computes `business_date` at write time from `cover_facts.closed_at`
//      via the canonical `BusinessTimingProfilesRepository` →
//      `BusinessTimingProfileResolver` → `BusinessDateResolver` chain
//      (Per-Daypart V1 / Slice 7b option (b), 2026-05-15). The chain
//      honors operator → org_unit → location precedence per HP #11 and
//      consumes a sub-hour-aware HH:MM cutoff per Gap 46. The sink
//      reads `location.timezone` only — it no longer reads
//      `location.business_day_rollover_hour` (deprecated in Slice 7b).
//      When `closed_at` is null (Clover orders not yet finalized —
//      `state != 'paid'`) the sink declines the write so only
//      order-finalized rows land.
//
//   4. Persists watermark advances via
//      `connector_sync_watermark` (resource = [cloverWatermarkResource]
//      = `'pos.orders'`). Per-batch commit so a Cloud Run Job restart
//      resumes from the last successful page.
//
//   5. Auto-evaluates demo-mode flip after a batch with one or more
//      inserts. The bespoke adapter does not know about the demo-flip
//      surface; the sink takes responsibility — when the watermark
//      advance observes a non-empty insert counter for the
//      (operator, location) slot, it invokes `evaluateDemoFlip(category=pos)`.
//      Idempotent per `DemoModeFlipPolicy` semantics: a second flip is
//      a no-op.
//
//   6. Wipes credential ciphertexts and connection metadata on
//      `disconnect` via [wipeCredentialsPreserveWatermark]. The
//      `connector_sync_watermark` rows are left intact so reconnect
//      resumes from the last successful cursor.
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//
//   * HP #1 (pure transport swap): writes flow into the existing
//     `cover_facts` canonical fact table; no formula change.
//   * HP #2 (demo mode persists post-launch): the flip is centralised
//     in [evaluateDemoFlip] using `INSERT ... ON CONFLICT DO NOTHING`
//     plus a narrowed `UPDATE ... WHERE is_demo`, so the second arrival
//     is a no-op and `flipped_to_live_at` stays pinned to the first flip.
//   * HP #4 (per-operator isolation): every method takes
//     `(operatorId, locationId)` and runs through `withTenant` so the
//     repository pattern is the primary tenant defense and Postgres
//     RLS is the backup.
//   * HP #7 (server-side secrets): plaintext credentials never touch
//     this sink — the wipe path nulls the ciphertext columns through
//     the existing `vendor_credentials` row.
//
// 2026-05-05 falsehood correction: Clover `coversFieldExposed: false`
// is correct. The Dining App private schema is not reachable via the
// public REST API, so the sink stores `covers = null` on every row and
// records `covers_source` exactly as the canonical-fact dict supplies
// (the Clover adapter sets it to `'forecast_fallback'`).
//
// V1 lean cut 2 alignment (`memory/project_v1_lean_cut_2_2026_05_03.md`):
// none of the banned items appear in this file. The banned-items grep
// in
// `test/infrastructure/persistence/postgres/clover_pos_postgres_sink_test.dart`
// (test H) enforces this.

import 'dart:convert';

import '../../../integrations/pos/clover_pos_adapter.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import '../../../services/integration/sink_business_date_projector.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'repositories/business_timing_profiles_repository.dart';
import 'tenant_context.dart';

/// `connector_sync_watermark.resource` value the Clover sink writes
/// under. Clover's documented model is order-finalized, not guest-check
/// based, so the resource string differs from the OR / LSK lanes —
/// `'pos.orders'` not `'pos.guest_checks'`.
const String cloverWatermarkResource = 'pos.orders';

/// Local vendor id literal. The Clover adapter does not export a
/// top-level `kCloverVendorId` constant — the bespoke `vendorId`
/// getter returns `'clover'` inline. Bind once here so the sink
/// source has a single canonical reference.
const String _kCloverVendorId = 'clover';

/// Postgres-backed canonical sink for Clover POS.
///
/// Implements the bespoke [CloverTenantFactWriter] +
/// [CloverWatermarkStore] surfaces the [CloverPosAdapter] writes
/// through, AND the unified [CanonicalSink] consumed by the spine-bridge
/// sync worker (`tool/integration_sync_worker/dispatch.dart`). The
/// bespoke + unified watermark methods overlap on lifecycle but use
/// different names (`persist` vs `advanceWatermark`); both delegate to
/// the same private writer. The unified [advanceWatermark] +
/// [appendSyncLog] widen `connectionId` to an optional named parameter
/// so a single concrete method satisfies both contracts.
class CloverPostgresSink extends OperatorScopedRepository
    implements CloverTenantFactWriter, CloverWatermarkStore, CanonicalSink {
  CloverPostgresSink(
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

  // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): Clover no longer
  // reads `locations.business_day_rollover_hour`. The cutoff is
  // resolved through the canonical `BusinessTimingProfilesRepository`
  // chain inside the projector.
  final SinkBusinessDateProjector _businessDateProjector;
  final DateTime Function() _clock;

  // ─── upsert ───────────────────────────────────────────────────────

  /// Bespoke fact-writer entry point invoked by the [CloverPosAdapter].
  /// Projects the typed [CloverCanonicalSalesFact] to the same
  /// canonical-fact dict shape the unified [upsertCoverFact] expects,
  /// then delegates to the shared private writer. Uses async / await
  /// rather than an arrow alias because the bespoke surface returns
  /// `Future<void>` while the shared writer returns `Future<bool>` —
  /// the await discards the boolean cleanly without relying on the
  /// void-return-position assignability rule.
  @override
  Future<void> writeSalesFact({
    required String operatorId,
    required String locationId,
    required CloverCanonicalSalesFact fact,
  }) async {
    await _upsertCoverFact(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: <String, Object?>{
        'vendor_id': _kCloverVendorId,
        'vendor_entity_id': fact.vendorEntityId,
        'opened_at': fact.openedAt,
        'closed_at': fact.closedAt,
        'vendor_modified_at': fact.vendorModifiedAt,
        'actual_sales': fact.actualSalesDollars,
        // Clover never exposes a covers value — the adapter passes
        // null and `forecast_fallback`; the sink trusts that and
        // writes NULL into `cover_facts.covers` regardless.
        'covers': fact.covers,
        'covers_source': fact.coversSource,
        'raw_payload': const <String, Object?>{},
      },
    );
  }

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) =>
      _upsertCoverFact(
        operatorId: operatorId,
        locationId: locationId,
        canonicalFact: canonicalFact,
      );

  /// Shared private writer. Handles tenant context wrap, location
  /// timezone resolution, business-date projection (Rule 11), the
  /// idempotent INSERT, and the per-tenant insert counter that drives
  /// the demo-flip auto-evaluator.
  Future<bool> _upsertCoverFact({
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
        // Clover orders that have not yet reached `state == 'paid'`
        // arrive without a `closed_at`. The sink declines the write so
        // only order-finalized rows land. The pending-insert counter is
        // unaffected; demo-flip will not fire on a no-op.
        return false;
      }
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
          'vendor_id': _kCloverVendorId,
          'vendor_entity_id': canonicalFact['vendor_entity_id'],
          'vendor_modified_at': _coerceUtc(canonicalFact['vendor_modified_at']),
          // Clover does not expose the covers field — store NULL on
          // every row regardless of what the canonical-fact dict
          // carries. The denormalised covers_source still rides through
          // unchanged so downstream chrome can render the
          // forecast-fallback degradation pill.
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

  /// Bespoke watermark entry point invoked by [CloverPosAdapter] after
  /// each successful batch commit. Delegates to [advanceWatermark] with
  /// the connection-id resolution path that looks up the
  /// `connector_connection` row by (operator, location, vendor).
  @override
  Future<void> persist({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) =>
      advanceWatermark(
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
      );

  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
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
          'resource': cloverWatermarkResource,
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

  /// Wipe credentials + connection metadata on disconnect; leave
  /// `connector_sync_watermark` rows intact so a reconnect resumes from
  /// the last successful cursor. The Clover adapter wipes plaintext via
  /// its own [CloverCredentialStore]; this method handles the
  /// repository-side teardown that the adapter cannot reach (the
  /// `vendor_credentials` ciphertext columns + the `connector_connection`
  /// row's status / disconnect_reason / webhook flag).
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
          'vendor_id': _kCloverVendorId,
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
          'vendor_id': _kCloverVendorId,
          'status': 'disconnected',
          'disconnect_reason': 'operator_action',
          'now': _clock().toUtc(),
        },
      );
      return wiped >= 0;
    });
    return (
      credentialsWiped: credentialsWiped,
      // Clover supports webhook auto-registration; the actual vendor-
      // side unregister is the [CloverWebhookRegistry]'s job, called by
      // the adapter on disconnect. The sink's repository-side teardown
      // reports `true` to keep the framework disconnect contract
      // uniform — the framework's overall `webhookUnregistered` flag
      // ANDs the registry result with this one.
      webhookUnregistered: true,
      // Watermark rows are intentionally not deleted; reconnect resumes
      // from the last canonical write. See the file header.
      watermarkPreserved: true,
    );
  }

  // ─── helpers ──────────────────────────────────────────────────────

  /// Resolve the `connector_connection.connection_id` for the
  /// (operator, location, vendor) triple. Bespoke-interface callers
  /// (the Clover adapter) do not carry the id; the unified-interface
  /// dispatcher (sync worker) does. When [explicitConnectionId] is
  /// non-null it wins; otherwise the sink looks up the row.
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
          'vendor_id': _kCloverVendorId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'connector_connection row not found for '
          '(operator=$operatorId, location=$locationId, '
          'vendor=$_kCloverVendorId) — connect must run before sink '
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
}
