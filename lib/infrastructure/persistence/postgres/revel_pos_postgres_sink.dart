// Phase 8 / Wave B `8.spine-bridge.1.RV` — Revel Systems Postgres-backed
// canonical sink.
//
// Spine reference:
//   * `docs/contracts/integration_spine_architecture_contract.md`
//     section "8.spine-bridge.1.RV" (binding).
//   * `docs/contracts/core_app_architecture.md` (canonical Layers 1-12).
//   * `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//     (OperatorScopedRepository pattern + wrapper-only RLS).
//   * `docs/contracts/phase_7_55_time_boundary_contract.md` Rule 11
//     (UTC TIMESTAMPTZ + denormalized `business_date` DATE).
//
// What this lane does:
//
//   1. Implements both the bespoke `RevelGateway` (consumed by
//      `RevelPosAdapter`) AND the unified `CanonicalSink` from
//      `8.spine-bridge.0` (consumed by the sync worker dispatcher).
//      The two interfaces overlap on watermark advance / sync log
//      append; the class widens the collision by making `connectionId`
//      an optional named parameter on `advanceWatermark` /
//      `appendSyncLog`, so bespoke callers omit it (the sink resolves
//      the connection id from `connector_connection`) and unified
//      callers pass it directly.
//
//   2. Writes canonical-fact dicts to operator-scoped Postgres
//      `cover_facts` rows via `OperatorScopedRepository.withTenant`.
//      The shared private writer is reached from BOTH
//      `RevelGateway.writeOrderFact` (typed `RevelCanonicalOrderFact`
//      input) and `CanonicalSink.upsertCoverFact` (`Map<String,
//      Object?>` input). Idempotency UNIQUE on `(operator_id,
//      vendor_id, vendor_entity_id, vendor_modified_at)` — the partial
//      index added by migration
//      `202605040000_phase_8_0_integration_framework.sql`. Repeat
//      writes of the same key short-circuit to a no-op (returns
//      false). The raw vendor-shape order envelope is preserved in
//      the `raw_payload` JSONB column for forensic re-derivation.
//
//   3. Computes `business_date` at write time from the canonical
//      `closed_at` (projected from Revel's `order.updated_date`) plus
//      `location.timezone` / `location.business_day_rollover_hour` via
//      the IANA-backed converter. The denormalized DATE never
//      re-derives at read (Phase 7.55 Rule 11).
//
//   4. Persists watermark advances via `connector_sync_watermark`
//      (resource = `'pos.guest_checks'`). Per-batch commit so a
//      Cloud Run Job restart resumes from the last cursor.
//
//   5. Auto-evaluates demo-mode flip after a batch with one or more
//      inserts. The bespoke adapter does not know about the demo-flip
//      surface; the sink takes responsibility — when `writeWatermark`
//      / `advanceWatermark` observes a non-empty insert counter for
//      the (operator, location) slot, it invokes `evaluateDemoFlip`
//      with `category = pos`. Idempotent per `DemoModeFlipPolicy`
//      semantics: a second flip is a no-op.
//
//   6. Wipes credential ciphertexts and connection metadata on
//      `wipeCredentials`. The `connector_sync_watermark` rows are left
//      intact so reconnect resumes from the last successful cursor.
//
//   7. Covers truth: Revel's `order.number_of_people` is the
//      operator-facing covers count — the adapter's `_canonicalize`
//      projects it directly into the canonical `covers` field with
//      `covers_source = 'direct'`. The sink writes the projection
//      unmodified.
//
// V1 lean cut 2 alignment (`memory/project_v1_lean_cut_2_2026_05_03.md`):
// none of the banned items appear in this file. The sink stays at the
// per-vendor wave-B contract size; the spine bridge is not the place
// to grow new surfaces. The banned-items grep in
// `test/infrastructure/persistence/postgres/revel_pos_postgres_sink_test.dart`
// (test H) enforces this.

import 'dart:convert';

import '../../../integrations/pos/revel_pos_adapter.dart';
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'tenant_context.dart';

/// `connector_sync_watermark.resource` value the RV sink writes under.
/// Mirrors the OR sink's resource string so the framework treats POS
/// `guest_checks` uniformly across vendors. The framework uses this
/// to disambiguate when the same connection later acquires a second
/// resource (e.g. `paid_in_outs`) without a schema change.
const String revelWatermarkResource = 'pos.guest_checks';

/// Postgres-backed canonical sink for Revel Systems POS.
///
/// Implements both the bespoke [RevelGateway] (consumed by the adapter
/// at `lib/integrations/pos/revel_pos_adapter.dart`) AND the unified
/// [CanonicalSink] (consumed by the spine-bridge sync worker
/// dispatcher). The two interfaces overlap on the watermark / sync log
/// surfaces with different parameter sets; the class widens those
/// signatures so a single concrete method satisfies both.
class RevelPosPostgresSink extends OperatorScopedRepository
    implements RevelGateway, CanonicalSink {
  RevelPosPostgresSink(
    super.tenantWrapper, {
    IanaTimezoneConverter? timezoneConverter,
    DateTime Function()? clock,
  })  : _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared,
        _clock = clock ?? DateTime.now;

  final IanaTimezoneConverter _timezoneConverter;
  final DateTime Function() _clock;

  /// In-memory per-(operator, location) counter of inserts since the
  /// last `writeWatermark` / `advanceWatermark`. Drives the demo-mode
  /// flip auto-evaluator per item 5 in the file header.
  final Map<String, int> _pendingInsertsByTenant = <String, int>{};

  String _tenantKey(String operatorId, String locationId) =>
      '$operatorId|$locationId';

  // ─── RevelGateway: connection upsert ──────────────────────────────

  @override
  Future<RevelConnectionRow> upsertConnection({
    required RevelConnectionRow row,
  }) async {
    final ctx = TenantContext(
      operatorId: row.operatorId,
      locationId: row.locationId,
    );
    return withTenant<RevelConnectionRow>(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_connection ('
        'connection_id, operator_id, location_id, vendor_id, '
        'category, status, metadata, webhook_url_provisioned, '
        'created_at, updated_at'
        ') values ('
        '@connection_id::uuid, @operator_id::uuid, @location_id::uuid, '
        '@vendor_id, @category::public.connector_category, '
        '@status::public.connector_status, '
        '@metadata::jsonb, @webhook_url_provisioned, '
        '@now::timestamptz, @now::timestamptz'
        ') on conflict (operator_id, location_id, vendor_id) do update set '
        'status = excluded.status, '
        'metadata = excluded.metadata, '
        'webhook_url_provisioned = excluded.webhook_url_provisioned, '
        'updated_at = excluded.updated_at '
        'where excluded.last_synced_at >= '
        'public.connector_sync_watermark.last_synced_at',
        parameters: <String, Object?>{
          'connection_id': row.connectionId,
          'operator_id': row.operatorId,
          'location_id': row.locationId,
          'vendor_id': kRevelVendorId,
          'category': 'pos',
          'status': _connectionStatusToDb(row.status),
          'metadata': jsonEncode(row.toMetadata()),
          'webhook_url_provisioned': row.subscriptionId != null,
          'now': _clock().toUtc(),
        },
      );
      return row;
    });
  }

  // ─── RevelGateway: watermark read ─────────────────────────────────

  @override
  Future<RevelWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<RevelWatermarkRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select w.cursor_token, w.last_modified_seen '
        'from public.connector_sync_watermark w '
        'join public.connector_connection c '
        '  on c.connection_id = w.connection_id '
        'where c.operator_id = @operator_id::uuid '
        'and c.location_id = @location_id::uuid '
        'and c.vendor_id = @vendor_id '
        'and w.resource = @resource '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kRevelVendorId,
          'resource': revelWatermarkResource,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final cursor = row['cursor_token'];
      final last = row['last_modified_seen'];
      if (cursor is! String || last is! DateTime) return null;
      return RevelWatermarkRow(
        cursorToken: cursor,
        lastModifiedSeen: last.toUtc(),
      );
    });
  }

  // ─── RevelGateway: watermark write (bespoke shape) ────────────────

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required RevelWatermarkRow row,
  }) =>
      advanceWatermark(
        operatorId: operatorId,
        locationId: locationId,
        cursorToken: row.cursorToken,
        lastModifiedSeen: row.lastModifiedSeen,
      );

  // ─── Cover-fact upsert (shared writer for both interfaces) ────────

  @override
  Future<bool> writeOrderFact(RevelCanonicalOrderFact fact) =>
      upsertCoverFact(
        operatorId: fact.operatorId,
        locationId: fact.locationId,
        canonicalFact: <String, Object?>{
          'vendor_id': kRevelVendorId,
          'vendor_entity_id': fact.vendorEntityId,
          'vendor_modified_at': fact.vendorModifiedAt,
          'covers': fact.covers,
          'covers_source': 'direct',
          'opened_at': fact.openedAt,
          'closed_at': fact.closedAt,
          'actual_sales': fact.actualSales,
          'raw_payload': fact.rawPayload,
        },
      );

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
        // The adapter's sanity hook already drops opened-without-closed
        // rows; this branch is a defense-in-depth assertion in case a
        // future caller bypasses the adapter. No write; counter
        // unaffected.
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
          'vendor_id': canonicalFact['vendor_id'] ?? kRevelVendorId,
          'vendor_entity_id': canonicalFact['vendor_entity_id'],
          'vendor_modified_at':
              _coerceUtc(canonicalFact['vendor_modified_at']),
          'covers': canonicalFact['covers'],
          'covers_source': canonicalFact['covers_source'] ?? 'direct',
          'opened_at': _coerceUtc(canonicalFact['opened_at']),
          'closed_at': closedAt,
          'business_date': businessDate,
          'actual_sales': canonicalFact['actual_sales'],
          'raw_payload': jsonEncode(
              canonicalFact['raw_payload'] ?? const <String, Object?>{}),
        },
      );
      return rows.isNotEmpty;
    });

    if (inserted) {
      final key = _tenantKey(operatorId, locationId);
      _pendingInsertsByTenant[key] = (_pendingInsertsByTenant[key] ?? 0) + 1;
    }
    return inserted;
  }

  /// POS sink — labor punches are the QBT lane's job. Returning false
  /// without a write keeps the [CanonicalSink] surface uniform across
  /// every vendor sink; the dispatcher routes by category so this
  /// path is unreachable in production.
  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async =>
      false;

  /// POS sink — reservations are the LB lane's job. See [upsertLaborPunch].
  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async =>
      false;

  // ─── Watermark advance + demo-flip auto-eval ──────────────────────

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
        'updated_at = excluded.updated_at',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': resolvedConnectionId,
          'resource': revelWatermarkResource,
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

  // ─── RevelGateway: credential wipe (preserves watermark) ──────────

  @override
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    await withTenant<void>(ctx, (exec) async {
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
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kRevelVendorId,
          'now': _clock().toUtc(),
        },
      );
      await exec.execute(
        'update public.connector_connection set '
        'status = @status::public.connector_status, '
        'disconnect_reason = '
        '  @disconnect_reason::public.connector_disconnect_reason, '
        'webhook_url_provisioned = false, '
        'updated_at = @now::timestamptz '
        'where operator_id = @operator_id::uuid '
        'and location_id = @location_id::uuid '
        'and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kRevelVendorId,
          'status': 'disconnected',
          'disconnect_reason': 'operator_action',
          'now': _clock().toUtc(),
        },
      );
    });
  }

  // ─── RevelGateway: access token read ──────────────────────────────

  @override
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'select access_token_ciphertext '
        'from public.vendor_credentials '
        'where operator_id = @operator_id::uuid '
        'and (location_id = @location_id::uuid or location_id is null) '
        'and vendor_id = @vendor_id '
        'and is_active = true '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kRevelVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final value = rows.single['access_token_ciphertext'];
      if (value is String) return value;
      if (value is List<int>) return utf8.decode(value);
      return null;
    });
  }

  // ─── helpers ──────────────────────────────────────────────────────

  /// Resolve the `connector_connection.connection_id` for the
  /// (operator, location, vendor) triple. Bespoke-interface callers
  /// (the Revel adapter) do not carry the id; the unified-interface
  /// dispatcher (sync worker) does. When [explicitConnectionId] is
  /// non-null and non-empty it wins; otherwise the sink looks up the
  /// row in `connector_connection`.
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
          'vendor_id': kRevelVendorId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'connector_connection row not found for '
          '(operator=$operatorId, location=$locationId, '
          'vendor=$kRevelVendorId) — connect must run before sink writes',
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

  static String _connectionStatusToDb(ConnectionStatus status) {
    switch (status) {
      case ConnectionStatus.connected:
        return 'connected';
      case ConnectionStatus.disconnected:
        return 'disconnected';
      case ConnectionStatus.error:
        return 'error';
    }
  }
}
