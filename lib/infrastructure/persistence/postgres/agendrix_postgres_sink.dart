// Phase 8 Wave B `8.spine-bridge-sink-fanout.AG` — Agendrix Postgres
// canonical sink.
//
// Authority (read in this order):
//
//   1. `docs/contracts/core_app_architecture.md` (Layers 1-12 binding,
//      Layer 2 source-truth fact tables).
//   2. `docs/contracts/integration_spine_architecture_contract.md`
//      sections "The canonical chain (binding)" and the labor sub-lane
//      shape (mirrors `.1.QBT`).
//   3. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//      — every fact-row write runs inside
//      `OperatorScopedRepository.withTenant`; RLS is the backup defense.
//   4. `lib/services/integration/canonical_sink.dart` — the unified
//      interface this sink implements alongside the bespoke
//      `AgendrixCanonicalSink` adapter-side interface.
//   5. `lib/integrations/labor/agendrix_labor_adapter.dart` — the Wave
//      B adapter that produces the canonical-fact dicts this sink
//      consumes; defines the bespoke `AgendrixCanonicalSink` interface
//      this file implements alongside `CanonicalSink`.
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//
//   * HP #1 (pure transport swap): writes flow into the existing
//     `labor_punches` canonical fact table; no formula change, no
//     read-service contract drift.
//   * HP #2 (demo mode persists post-launch): [evaluateDemoFlip]
//     centralises the (operator, location, category=labor) flip rule
//     using `INSERT ... ON CONFLICT DO UPDATE WHERE is_demo`, so the
//     same code path runs whether the operator is in demo or live; the
//     idempotent flip policy preserves the original triggering
//     `flipped_to_live_at` and `flipped_by_connection_id`.
//   * HP #4 (per-operator isolation): every method takes
//     `(operatorId, locationId)` and runs through `withTenant` so the
//     repository pattern is the primary tenant defense and Postgres
//     RLS is the backup.
//   * HP #7 (server-side secrets): credential ciphertexts are touched
//     only on disconnect via [wipeCredentialsPreserveWatermark]; the
//     adapter's own credential gateway owns refresh-token rotation.
//
// Dual-interface widening: this sink implements both
// [AgendrixCanonicalSink] (consumed by the labor adapter at
// `lib/integrations/labor/agendrix_labor_adapter.dart`) AND the
// unified [CanonicalSink] (consumed by the spine-bridge sync worker).
// The two surfaces collide on `advanceWatermark` / `appendSyncLog`
// with different parameter sets — the bespoke interface omits
// `connectionId`, the unified interface requires it. The class widens
// the collision by treating `connectionId` as an optional named
// parameter; bespoke callers omit it (the sink resolves it from
// `connector_connection`), unified callers pass it through.
//
// Banned items (V1 lean cut 2): the per-file banned grep in this
// slice's test pins the same ledger that
// `lib/integrations/labor/agendrix_labor_adapter.dart` already pins
// against the adapter source, so the lean cut stays enforced
// lane-by-lane.
//
// Wage-source posture: Agendrix is classified `app_fallback` for
// wage data — the documented Public API exposes per-position pay,
// not per-shift. The sink writes [pay_rate] as NULL; the aggregator
// at Lane `.2` falls back to the wage-authority service when this
// column is NULL, per `data_accuracy_settings_contract.md`.
//
// Hours-worked projection: Agendrix `time_entries[]` records carry
// `start_time` + `end_time` but no duration field. The sink computes
// `hours_worked` (in seconds, matching the QBT `duration` shape) as
// `(shift_end - shift_start).inSeconds` when both endpoints are
// present; an open timesheet (employee clocked in but not out yet)
// binds NULL so the aggregator can detect the in-progress state.

import 'dart:convert';

import '../../../integrations/labor/agendrix_labor_adapter.dart'
    show AgendrixCanonicalSink, agendrixVendorId;
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/demo_mode_state.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// Resource string written into `connector_sync_watermark.resource`
/// for Agendrix. Matches the canonical fact table the sink drains
/// into so the worker can read back the cursor by resource without
/// a vendor-side join.
const String agendrixWatermarkResource = 'labor_punches';

/// Postgres-backed canonical sink for Agendrix.
///
/// Implements both the bespoke [AgendrixCanonicalSink] (consumed by
/// the labor adapter) AND the unified [CanonicalSink] (consumed by
/// the spine-bridge sync worker). Mirrors the `8.spine-bridge.1.QBT`
/// QuickBooks Time sink in shape; only the canonical-dict key
/// translation (Agendrix `employee_id` → `labor_punches.employee_source_id`)
/// and the absence of a module-disambiguation guard differ
/// (Agendrix is a single-product vendor with no module split).
///
/// Cover and reservation writes are explicit non-goals on this sink:
/// labor adapters never produce them. [upsertCoverFact] and
/// [upsertReservationFact] both throw [UnsupportedError] — the
/// `tool/integration_sync_worker` dispatcher routes by category, so
/// these throws are defense-in-depth assertions against future
/// router refactors that could miswire a labor connection's tick to
/// a covers / reservation seam.
class AgendrixPostgresSink extends OperatorScopedRepository
    implements AgendrixCanonicalSink, CanonicalSink {
  AgendrixPostgresSink({
    required TenantTransactionWrapper tenantWrapper,
    IanaTimezoneConverter? timezoneConverter,
    DateTime Function()? now,
  })  : _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared,
        _now = now ?? DateTime.now,
        super(tenantWrapper);

  final IanaTimezoneConverter _timezoneConverter;
  final DateTime Function() _now;

  // ─── CanonicalSink: covers / reservations are unsupported ─────────

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    throw UnsupportedError(
      'AgendrixPostgresSink is a labor sink; cover writes are not '
      'supported. Routing bug — dispatcher must call the POS sink for the '
      'cover_facts category.',
    );
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) async {
    throw UnsupportedError(
      'AgendrixPostgresSink is a labor sink; reservation writes are '
      'not supported. Routing bug — dispatcher must call the reservation '
      'sink for the reservation_facts category.',
    );
  }

  // ─── Labor punch upsert (both interfaces share one writer) ────────

  /// `AgendrixCanonicalSink.upsertTimePunch` entry — the labor
  /// adapter's canonical-fact dict shape, keyed on `employee_id`.
  @override
  Future<bool> upsertTimePunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) =>
      _upsertLaborPunch(
        operatorId: operatorId,
        locationId: locationId,
        canonicalPunch: canonicalFact,
      );

  /// `CanonicalSink.upsertLaborPunch` entry — the dispatcher passes
  /// the same dict shape; this method delegates to the shared writer.
  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) =>
      _upsertLaborPunch(
        operatorId: operatorId,
        locationId: locationId,
        canonicalPunch: canonicalPunch,
      );

  /// Shared writer for the labor_punches insert. Required keys on
  /// [canonicalPunch]:
  ///
  ///   * `vendor_entity_id` — string; Agendrix `time_entries[].id`.
  ///   * `vendor_modified_at` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `shift_start` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `role_name` — string.
  ///
  /// Optional keys:
  ///
  ///   * `shift_end` — `DateTime` (UTC) or ISO-8601 string; null /
  ///     absent when the timesheet is still open.
  ///   * `employee_id` — string; Agendrix `time_entries[].user_id`.
  ///     Maps to `labor_punches.employee_source_id`.
  ///   * `raw_payload` — vendor-shape Map preserved for forensic
  ///     re-derivation.
  ///
  /// `hours_worked` is computed as `(shift_end - shift_start).inSeconds`
  /// when both endpoints are present; NULL otherwise (open shift).
  /// `pay_rate` is bound NULL — Agendrix is `app_fallback`; the
  /// aggregator falls back to the wage-authority service.
  ///
  /// Returns `true` when a new row landed; `false` when the
  /// idempotency UNIQUE on
  /// `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`
  /// short-circuited the insert (replay arrived twice).
  Future<bool> _upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) {
    final vendorEntityId = _requireString(canonicalPunch, 'vendor_entity_id');
    final vendorModifiedAt =
        _requireUtcInstant(canonicalPunch, 'vendor_modified_at');
    final shiftStart = _requireUtcInstant(canonicalPunch, 'shift_start');
    final shiftEnd = _readUtcInstant(canonicalPunch, 'shift_end');
    final employeeSourceId = _readString(canonicalPunch, 'employee_id');
    final roleName = _requireString(canonicalPunch, 'role_name');
    final hoursWorked = (shiftEnd != null)
        ? shiftEnd.difference(shiftStart).inSeconds
        : null;
    final rawPayload = _readPayload(canonicalPunch, 'raw_payload');

    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      final businessDate = await _resolveBusinessDate(exec, shiftStart);
      final affected = await exec.execute(
        'insert into public.labor_punches ('
        'operator_id, location_id, '
        'employee_source_id, role_name, '
        'shift_start, shift_end, hours_worked, pay_rate, '
        'vendor_id, vendor_entity_id, vendor_modified_at, '
        'raw_payload, business_date'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, '
        '@employee_source_id, @role_name, '
        '@shift_start::timestamptz, @shift_end::timestamptz, '
        '@hours_worked, @pay_rate, '
        '@vendor_id, @vendor_entity_id, @vendor_modified_at::timestamptz, '
        '@raw_payload::jsonb, @business_date::date'
        ') '
        'on conflict (operator_id, vendor_id, vendor_entity_id, '
        'vendor_modified_at) do nothing',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'employee_source_id': employeeSourceId,
          'role_name': roleName,
          'shift_start': shiftStart,
          'shift_end': shiftEnd,
          'hours_worked': hoursWorked,
          'pay_rate': null,
          'vendor_id': agendrixVendorId,
          'vendor_entity_id': vendorEntityId,
          'vendor_modified_at': vendorModifiedAt,
          'raw_payload': jsonEncode(rawPayload),
          'business_date': _formatDate(businessDate),
        },
      );
      return affected > 0;
    });
  }

  // ─── Watermark advance (widened: connectionId optional) ───────────

  /// Persist `cursor_token` + `last_modified_seen` for the connection
  /// AFTER each batch commit. Cloud Run Job restart resilience: the
  /// next tick resumes from the persisted cursor even when the worker
  /// dies mid-window.
  ///
  /// `connectionId` is optional to satisfy both the bespoke
  /// [AgendrixCanonicalSink] surface (which omits it — the adapter
  /// does not carry the id) and the unified [CanonicalSink] surface
  /// (which requires it — the dispatcher does carry it). When omitted,
  /// the sink resolves the connection_id from `connector_connection`
  /// for the (operator, location, vendor=agendrix) triple.
  ///
  /// Resource is pinned to [agendrixWatermarkResource] so the
  /// watermark row is unique per `(connection_id, resource)`.
  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
    String? connectionId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      final resolvedConnectionId =
          await _resolveConnectionId(exec, explicit: connectionId);
      await exec.execute(
        'insert into public.connector_sync_watermark ('
        'operator_id, location_id, connection_id, resource, '
        'last_synced_at, last_modified_seen, cursor_token'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@resource, @last_synced_at::timestamptz, '
        '@last_modified_seen::timestamptz, @cursor_token'
        ') on conflict (connection_id, resource) do update set '
        'last_synced_at = excluded.last_synced_at, '
        'last_modified_seen = excluded.last_modified_seen, '
        'cursor_token = excluded.cursor_token, '
        'updated_at = now()',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': resolvedConnectionId,
          'resource': agendrixWatermarkResource,
          'last_synced_at': _now().toUtc(),
          'last_modified_seen': lastModifiedSeen.toUtc(),
          'cursor_token': cursorToken,
        },
      );
    });
  }

  // ─── Sync log append (widened: connectionId optional) ─────────────

  @override
  Future<void> appendSyncLog({
    required String operatorId,
    required String locationId,
    required String eventKind,
    String? errorMessage,
    int? recordsCount,
    Map<String, Object?>? payloadPreview,
    String? connectionId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      final resolvedConnectionId =
          await _resolveConnectionId(exec, explicit: connectionId);
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
          'connection_id': resolvedConnectionId,
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

  // ─── Demo-mode flip (mirror QBT — single INSERT ON CONFLICT) ──────

  /// Evaluate the `(operatorId, locationId, category=labor)` demo
  /// flip. Mirrors [DemoModeFlipPolicy.evaluateFlip] semantics: gates
  /// on `connectionStatus=connected ∧ firstBackfillCommitted ∧
  /// backfillRecordsWritten >= 1`; flips idempotently (a second call
  /// after the row already flipped to live preserves the original
  /// `flipped_to_live_at` and `flipped_by_connection_id`).
  ///
  /// Disconnect does NOT auto-revert.
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
    if (connectionStatus != ConnectionStatus.connected ||
        !firstBackfillCommitted ||
        backfillRecordsWritten < 1) {
      return Future<void>.value();
    }
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      // INSERT a live row when missing, then flip is_demo only when
      // the row is still demo. The WHERE clause on the UPDATE path
      // is what makes this idempotent — once flipped to live, a
      // second evaluate is a no-op (the WHERE filters out the row),
      // so `flipped_to_live_at` and `flipped_by_connection_id`
      // preserve the original triggering values.
      await exec.execute(
        'insert into public.demo_mode_state ('
        'operator_id, location_id, category, '
        'is_demo, flipped_to_live_at, flipped_by_connection_id'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @category, '
        'false, @flipped_at::timestamptz, @connection_id::uuid'
        ') on conflict (operator_id, location_id, category) do update set '
        'is_demo = false, '
        'flipped_to_live_at = excluded.flipped_to_live_at, '
        'flipped_by_connection_id = excluded.flipped_by_connection_id, '
        'updated_at = now() '
        'where public.demo_mode_state.is_demo = true',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'category': category.name,
          'flipped_at': _now().toUtc(),
          'connection_id': connectionId,
        },
      );
    });
  }

  // ─── Disconnect / credential wipe ─────────────────────────────────

  /// Wipe access / refresh ciphertexts on `vendor_credentials` and
  /// flip `connector_connection.status = 'disconnected'`. Watermark
  /// rows on `connector_sync_watermark` are intentionally preserved
  /// so a reconnect resumes from the last canonical write rather than
  /// re-walking the 60-day window.
  @override
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
          'vendor_id': agendrixVendorId,
          'now': _now().toUtc(),
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
          'vendor_id': agendrixVendorId,
          'status': 'disconnected',
          'disconnect_reason': 'operator_action',
          'now': _now().toUtc(),
        },
      );
      return wiped >= 0;
    });
    return (
      credentialsWiped: credentialsWiped,
      // Poll-only vendor — no webhook subscription exists at the
      // vendor side to unregister. Always reports true to keep the
      // framework disconnect contract uniform.
      webhookUnregistered: true,
      // Watermark rows are intentionally not deleted; reconnect
      // resumes from the last canonical write. See the file header.
      watermarkPreserved: true,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  /// Resolve the `connector_connection.connection_id` for the
  /// (operator, location, vendor=agendrix) triple. The bespoke
  /// adapter callers do not carry the id; the unified-interface
  /// dispatcher does. When [explicit] is non-null it wins; otherwise
  /// the sink looks up the row.
  Future<String> _resolveConnectionId(
    PostgresExecutor exec, {
    required String? explicit,
  }) async {
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final rows = await exec.query(
      'select connection_id::text as connection_id '
      'from public.connector_connection '
      'where operator_id = public.app_current_operator() '
      'and location_id = public.app_current_location() '
      'and vendor_id = @vendor_id '
      'limit 1',
      parameters: <String, Object?>{
        'vendor_id': agendrixVendorId,
      },
    );
    if (rows.isEmpty) {
      throw StateError(
        'AgendrixPostgresSink could not resolve connection_id — '
        'no connector_connection row for (operator, location, '
        'vendor=agendrix). Connect must run before sink writes.',
      );
    }
    final id = rows.single['connection_id'];
    if (id is! String || id.isEmpty) {
      throw StateError(
        'connector_connection.connection_id has unexpected shape',
      );
    }
    return id;
  }

  Future<DateTime> _resolveBusinessDate(
    PostgresExecutor exec,
    DateTime shiftStartUtc,
  ) async {
    final rows = await exec.query(
      'select timezone, business_day_rollover_hour from public.locations '
      'where operator_id = public.app_current_operator() '
      'and location_id = public.app_current_location() '
      'limit 1',
    );
    if (rows.isEmpty) {
      throw StateError(
        'AgendrixPostgresSink could not resolve location timezone — '
        'the locations row is missing for the active tenant context.',
      );
    }
    final row = rows.single;
    final timezone = row['timezone'];
    final rollover = row['business_day_rollover_hour'];
    if (timezone is! String || timezone.isEmpty) {
      throw StateError(
        'locations.timezone missing for the active tenant context; '
        'cannot bucket business_date.',
      );
    }
    final rolloverHour = rollover is int ? rollover : 0;
    return _timezoneConverter.toBusinessDate(
      restaurantTimezone: timezone,
      businessDayRolloverHour: rolloverHour,
      instant: shiftStartUtc,
    );
  }

  static String _requireString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is String && value.isNotEmpty) return value;
    if (value is num) return value.toString();
    throw ArgumentError.value(
      value,
      key,
      'canonicalPunch.$key must be a non-empty String',
    );
  }

  static String? _readString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is String) return value.isEmpty ? null : value;
    if (value is num) return value.toString();
    return null;
  }

  static DateTime _requireUtcInstant(Map<String, Object?> map, String key) {
    final value = _readUtcInstant(map, key);
    if (value == null) {
      throw ArgumentError.value(
        map[key],
        key,
        'canonicalPunch.$key must be a UTC DateTime or ISO-8601 string',
      );
    }
    return value;
  }

  static DateTime? _readUtcInstant(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is DateTime) return value.toUtc();
    if (value is String) {
      if (value.isEmpty) return null;
      return DateTime.parse(value).toUtc();
    }
    return null;
  }

  static Map<String, Object?> _readPayload(
    Map<String, Object?> map,
    String key,
  ) {
    final value = map[key];
    if (value is Map<String, Object?>) return value;
    if (value is Map) {
      return <String, Object?>{
        for (final entry in value.entries) entry.key.toString(): entry.value,
      };
    }
    return const <String, Object?>{};
  }

  static String _formatDate(DateTime value) {
    final utc = value.toUtc();
    final yyyy = utc.year.toString().padLeft(4, '0');
    final mm = utc.month.toString().padLeft(2, '0');
    final dd = utc.day.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd';
  }
}
