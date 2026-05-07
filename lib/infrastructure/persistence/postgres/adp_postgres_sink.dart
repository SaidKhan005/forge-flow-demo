// Phase 8 Wave B `8.spine-bridge.1.ADP` — ADP Workforce Now /
// Workforce Manager Postgres sink.
//
// Authority (read in this order):
//
//   1. `docs/contracts/core_app_architecture.md` (Layers 1-12 binding)
//   2. `docs/contracts/integration_spine_architecture_contract.md`
//      sections "The canonical chain (binding)" and
//      "Sub-lane shape (binding)" / `.1.ADP`. The 2026-05-05
//      falsehood corrections #1 (ADP webhook = autoRegister; sink is
//      webhook-vs-poll agnostic and does NOT register/unregister
//      subscriptions itself) and #7 (V1 wage class = `hoursOnly`;
//      labor_punches rows store hours only) are load-bearing.
//   3. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//      — every fact-row write runs inside
//      `OperatorScopedRepository.withTenant`; RLS is the backup
//      defense.
//   4. `lib/services/integration/canonical_sink.dart` — the unified
//      interface this sink implements.
//   5. `lib/services/integration/demo_mode_state.dart` — the flip
//      policy this sink composes for demo->live transition.
//   6. `lib/integrations/labor/adp_labor_adapter.dart` — the Wave B
//      adapter that produces the canonical-fact dicts this sink
//      consumes. Module disambiguation (Workforce Now / Workforce
//      Manager / RUN refusal) is the adapter's responsibility per
//      `connect`; this sink is module-agnostic and writes the same
//      labor_punches row shape regardless of ADP module on the
//      connection.
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//
//   * HP #1 (pure transport swap): writes flow into the existing
//     `labor_punches` canonical fact table; no formula change, no
//     read-service contract drift.
//   * HP #2 (demo mode persists post-launch): [evaluateDemoFlip]
//     centralises the (operator, location, category) flip rule using
//     `INSERT ... ON CONFLICT DO UPDATE WHERE is_demo`, so the same
//     code path runs whether the operator is in demo or live; the
//     idempotent flip policy preserves the original triggering
//     `flipped_to_live_at` and `flipped_by_connection_id`.
//   * HP #4 (per-operator isolation): every method takes
//     `(operatorId, locationId)` and runs through `withTenant` so the
//     repository pattern is the primary tenant defense and Postgres
//     RLS is the backup.
//   * HP #7 (server-side secrets): the bespoke ADP gateway path
//     reads/writes credential ciphertext through the `withTenant`
//     transaction; plaintext never appears here.
//
// 2026-05-05 falsehood corrections binding into the sink shape:
//
//   * #1 ADP webhook is `autoRegister` (NOT pollOnly). The sink is
//     webhook-vs-poll agnostic — it consumes the canonical-fact dict
//     regardless of the source path. Subscription registration and
//     deregistration are the adapter's / connect-flow's territory.
//   * #7 V1 wage class is `hoursOnly`. The sink writes hours and
//     start/end timestamps only; the wage-dollar columns on
//     labor_punches are NOT supplied by this sink at V1. The slice's
//     test suite (Test G) pins the hours-only invariant per fixture
//     row, and the banned-grep (Test H) rejects every wage-dollar
//     write-side token from this source file.
//
// Banned items (V1 lean cut 2): the per-file banned grep in this
// slice's test pins the V1 lean cut 2 ledger against this sink
// source so the lean cut stays enforced lane-by-lane (mirrors the
// QBT lane suite).

import 'dart:convert';

import '../../../integrations/labor/adp_labor_adapter.dart'
    show
        AdpCanonicalTimePunchFact,
        AdpConnectionRow,
        AdpGateway,
        AdpWatermarkRow,
        kAdpVendorId;
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/demo_mode_state.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// Resource string written into `connector_sync_watermark.resource`
/// for ADP. Matches the canonical fact table the sink drains into so
/// the worker can read back the cursor by resource without a
/// vendor-side join.
const String adpWatermarkResource = 'labor_punches';

/// Postgres-backed [CanonicalSink] + [AdpGateway] for ADP Workforce
/// Now / Workforce Manager.
///
/// Mirrors the `8.spine-bridge.1.QBT` (QuickBooks Time) sink shape;
/// the only intentional differences are:
///
///   * V1 wage class for ADP is `hoursOnly` (per the 2026-05-05
///     spine-contract falsehood correction #7). The labor_punches
///     INSERT lists hours and timestamp columns only; the wage-dollar
///     columns stay NULL.
///   * Module disambiguation lives in the adapter at `connect` time
///     (Workforce Now / Workforce Manager proceed; RUN refused via
///     `ModuleRefusalException`). The sink is module-agnostic — it
///     writes the same row shape regardless of ADP module.
///   * Webhook vs poll routing is the adapter's concern; this sink
///     consumes canonical-fact dicts identically from either path
///     (per falsehood correction #1).
///
/// Cover and reservation writes are explicit non-goals on this sink:
/// labor adapters never produce them. [upsertCoverFact] and
/// [upsertReservationFact] both throw [UnsupportedError] — the
/// `tool/integration_sync_worker` dispatcher routes by category, so
/// these throws are defense-in-depth assertions against future
/// router refactors that could miswire a labor connection's tick to
/// a covers / reservation seam.
class AdpPostgresSink extends OperatorScopedRepository
    implements CanonicalSink, AdpGateway {
  AdpPostgresSink({
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
      'AdpPostgresSink is a labor sink; cover writes are not supported. '
      'Routing bug — dispatcher must call the POS sink for the '
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
      'AdpPostgresSink is a labor sink; reservation writes are not '
      'supported. Routing bug — dispatcher must call the reservation '
      'sink for the reservation_facts category.',
    );
  }

  // ─── CanonicalSink: labor punch upsert ────────────────────────────

  /// Upsert one canonical punch row into `labor_punches`.
  ///
  /// Required keys on [canonicalPunch]:
  ///
  ///   * `vendor_entity_id` — string; ADP `time_event.id`.
  ///   * `vendor_modified_at` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `shift_start` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `employee_source_id` — string; ADP `worker.associate_oid`.
  ///   * `role_name` — string; resolved upstream from
  ///     `worker.position.position_title` (Workforce Now) or
  ///     `worker.workAssignment.jobTitle` (Workforce Manager).
  ///   * `hours_worked` — num seconds. When the canonical-fact dict
  ///     does not carry it, the sink derives it from
  ///     `shift_end - shift_start`; an open punch (no shift_end)
  ///     resolves to `0` and the aggregator surfaces the in-progress
  ///     state via the null `shift_end` instead.
  ///
  /// Optional keys:
  ///
  ///   * `shift_end` — `DateTime` (UTC) or ISO-8601 string; null /
  ///     absent when the time-event is still open (employee clocked
  ///     in but not out yet — ADP exposes this as
  ///     `time_event.exit_date_time = null`).
  ///   * `raw_payload` — vendor-shape Map preserved for forensic
  ///     re-derivation.
  ///
  /// Module disambiguation is intentionally NOT enforced here. The
  /// adapter's `connect` flow rejects RUN before any canonical-fact
  /// can be produced; both supported modules (Workforce Now /
  /// Workforce Manager) project into the same canonical-fact shape
  /// and the sink writes them identically.
  ///
  /// Returns `true` when a new row landed; `false` when the
  /// idempotency UNIQUE on
  /// `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`
  /// short-circuited the insert (replay arrived twice).
  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      return _upsertLaborPunchInternal(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        canonicalPunch: canonicalPunch,
      );
    });
  }

  // ─── AdpGateway: time-punch fact write ────────────────────────────

  /// Sister-path to [upsertLaborPunch] honouring the bespoke ADP
  /// gateway shape. Translates an [AdpCanonicalTimePunchFact] into
  /// the canonical-fact dict and shares the same private writer.
  @override
  Future<bool> writeTimePunchFact(AdpCanonicalTimePunchFact fact) {
    final ctx = TenantContext(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      return _upsertLaborPunchInternal(
        exec: exec,
        operatorId: fact.operatorId,
        locationId: fact.locationId,
        canonicalPunch: <String, Object?>{
          'vendor_entity_id': fact.vendorEntityId,
          'vendor_modified_at': fact.vendorModifiedAt,
          'shift_start': fact.shiftStart,
          'shift_end': fact.shiftEnd,
          'employee_source_id': fact.employeeId,
          'role_name': fact.roleName,
          'hours_worked': _deriveSeconds(fact.shiftStart, fact.shiftEnd),
          'raw_payload': fact.rawPayload,
        },
      );
    });
  }

  // ─── Shared private writer ────────────────────────────────────────

  Future<bool> _upsertLaborPunchInternal({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async {
    final vendorEntityId = _requireString(canonicalPunch, 'vendor_entity_id');
    final vendorModifiedAt =
        _requireUtcInstant(canonicalPunch, 'vendor_modified_at');
    final shiftStart = _requireUtcInstant(canonicalPunch, 'shift_start');
    final shiftEnd = _readUtcInstant(canonicalPunch, 'shift_end');
    final employeeSourceId =
        _requireString(canonicalPunch, 'employee_source_id');
    final roleName = _requireString(canonicalPunch, 'role_name');
    final hoursWorked = _readNumber(canonicalPunch, 'hours_worked') ??
        _deriveSeconds(shiftStart, shiftEnd);
    final rawPayload = _readPayload(canonicalPunch, 'raw_payload');

    final businessDate = await _resolveBusinessDate(exec, shiftStart);
    final affected = await exec.execute(
      // V1 wage class = hoursOnly (per spine-contract 2026-05-05
      // correction #7): the column list intentionally omits the
      // wage-dollar fields so they land NULL by default. The
      // aggregator does not synthesize wage dollars from ADP at V1.
      'insert into public.labor_punches ('
      'operator_id, location_id, '
      'employee_source_id, role_name, '
      'shift_start, shift_end, hours_worked, '
      'vendor_id, vendor_entity_id, vendor_modified_at, '
      'raw_payload, business_date'
      ') values ('
      '@operator_id::uuid, @location_id::uuid, '
      '@employee_source_id, @role_name, '
      '@shift_start::timestamptz, @shift_end::timestamptz, '
      '@hours_worked, '
      '@vendor_id, @vendor_entity_id, @vendor_modified_at::timestamptz, '
      '@raw_payload::jsonb, @business_date::date'
      ') '
      'on conflict (operator_id, location_id, vendor_id, vendor_entity_id) '
      'where vendor_id is not null '
      'and vendor_entity_id is not null '
      'do update set '
      'vendor_modified_at = excluded.vendor_modified_at, '
      'employee_source_id = excluded.employee_source_id, '
      'role_name = excluded.role_name, '
      'shift_start = excluded.shift_start, '
      'shift_end = excluded.shift_end, '
      'hours_worked = excluded.hours_worked, '
      'raw_payload = excluded.raw_payload, '
      'business_date = excluded.business_date '
      'where excluded.vendor_modified_at >= '
      'public.labor_punches.vendor_modified_at',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'employee_source_id': employeeSourceId,
        'role_name': roleName,
        'shift_start': shiftStart,
        'shift_end': shiftEnd,
        'hours_worked': hoursWorked,
        'vendor_id': kAdpVendorId,
        'vendor_entity_id': vendorEntityId,
        'vendor_modified_at': vendorModifiedAt,
        'raw_payload': jsonEncode(rawPayload),
        'business_date': _formatDate(businessDate),
      },
    );
    return affected > 0;
  }

  // ─── CanonicalSink: watermark advance ─────────────────────────────

  /// Persist `cursor_token` + `last_modified_seen` for the connection
  /// AFTER each batch commit. Cloud Run Job restart resilience: the
  /// next tick resumes from the persisted cursor even when the worker
  /// dies mid-window.
  ///
  /// Resource is pinned to [adpWatermarkResource] so the watermark
  /// row is unique per `(connection_id, resource)` and other ADP
  /// resources (if added later) get their own row.
  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      await _writeWatermarkInternal(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
      );
    });
  }

  // ─── AdpGateway: watermark read / write ───────────────────────────

  /// Sister-path to [advanceWatermark] for the bespoke gateway shape.
  /// The gateway-side signature widens the connection lookup: it
  /// resolves `connection_id` from the (operator, location,
  /// vendor='adp') triple in `connector_connection`, then delegates
  /// to the shared internal writer.
  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required AdpWatermarkRow row,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      final connectionId = await _resolveConnectionId(exec);
      if (connectionId == null) {
        throw StateError(
          'AdpPostgresSink.writeWatermark could not resolve a '
          'connector_connection row for the active (operator, '
          'location, vendor=adp) tenant context. The adapter '
          'should upsert the connection before any watermark write.',
        );
      }
      await _writeWatermarkInternal(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        cursorToken: row.cursorToken,
        lastModifiedSeen: row.lastModifiedSeen,
      );
    });
  }

  @override
  Future<AdpWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<AdpWatermarkRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select cursor_token, last_modified_seen '
        'from public.connector_sync_watermark '
        'where operator_id = public.app_current_operator() '
        'and location_id = public.app_current_location() '
        'and resource = @resource '
        'order by updated_at desc '
        'limit 1',
        parameters: <String, Object?>{
          'resource': adpWatermarkResource,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final cursor = row['cursor_token'];
      final modified = row['last_modified_seen'];
      if (cursor is! String || modified is! DateTime) return null;
      return AdpWatermarkRow(
        cursorToken: cursor,
        lastModifiedSeen: modified.toUtc(),
      );
    });
  }

  Future<void> _writeWatermarkInternal({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) async {
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
      'updated_at = now() '
      'where excluded.last_synced_at >= '
      'public.connector_sync_watermark.last_synced_at',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'resource': adpWatermarkResource,
        'last_synced_at': _now().toUtc(),
        'last_modified_seen': lastModifiedSeen.toUtc(),
        'cursor_token': cursorToken,
      },
    );
  }

  // ─── CanonicalSink: sync log append ───────────────────────────────

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
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
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
          'connection_id': connectionId,
          'event_kind': eventKind,
          'records_count': recordsCount,
          'error_message': errorMessage,
          'payload_preview': encodePayloadPreviewForSyncLog(payloadPreview),
          'occurred_at': _now().toUtc(),
        },
      );
    });
  }

  // ─── CanonicalSink: demo-mode flip ────────────────────────────────

  /// Evaluate the `(operatorId, locationId, category)` demo flip.
  /// Mirrors [DemoModeFlipPolicy.evaluateFlip] semantics: gates on
  /// `connectionStatus=connected ∧ firstBackfillCommitted ∧
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

  // ─── AdpGateway: connection / credential lookup + wipe ────────────

  @override
  Future<AdpConnectionRow> upsertConnection({
    required AdpConnectionRow row,
  }) {
    final ctx = TenantContext(
      operatorId: row.operatorId,
      locationId: row.locationId,
    );
    return withTenant<AdpConnectionRow>(ctx, (exec) async {
      final returning = await exec.query(
        'insert into public.connector_connection ('
        'operator_id, location_id, vendor_id, category, status, '
        'module, metadata, webhook_url_provisioned'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, '
        "'labor', @status, @module, @metadata::jsonb, true"
        ') on conflict (operator_id, location_id, vendor_id, '
        "coalesce(module, '')) do update set "
        'status = excluded.status, '
        'metadata = excluded.metadata, '
        'updated_at = now() '
        'returning connection_id',
        parameters: <String, Object?>{
          'operator_id': row.operatorId,
          'location_id': row.locationId,
          'vendor_id': kAdpVendorId,
          'status': row.status.name,
          'module': row.module,
          'metadata': jsonEncode(row.toMetadata()),
        },
      );
      final connectionId = returning.isEmpty
          ? row.connectionId
          : (returning.single['connection_id']?.toString() ?? row.connectionId);
      return AdpConnectionRow(
        connectionId: connectionId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        module: row.module,
        subscriptionId: row.subscriptionId,
        status: row.status,
      );
    });
  }

  @override
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      // Wipe the credential ciphertext only; the watermark and
      // canonical-fact rows are intentionally preserved so reconnect
      // resumes from the last cursor.
      await exec.execute(
        'delete from public.vendor_credentials '
        'where operator_id = public.app_current_operator() '
        'and (location_id = public.app_current_location() '
        '  or location_id is null) '
        'and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'vendor_id': kAdpVendorId,
        },
      );
    });
  }

  @override
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'select access_token_ciphertext '
        'from public.vendor_credentials '
        'where operator_id = public.app_current_operator() '
        'and (location_id = public.app_current_location() '
        '  or location_id is null) '
        'and vendor_id = @vendor_id '
        'and is_active = true '
        'order by updated_at desc '
        'limit 1',
        parameters: <String, Object?>{
          'vendor_id': kAdpVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final value = rows.single['access_token_ciphertext'];
      if (value is String) return value;
      return null;
    });
  }

  @override
  Future<String?> readModule({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'select module from public.connector_connection '
        'where operator_id = public.app_current_operator() '
        'and location_id = public.app_current_location() '
        'and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'vendor_id': kAdpVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final value = rows.single['module'];
      if (value is String) return value;
      return null;
    });
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<String?> _resolveConnectionId(PostgresExecutor exec) async {
    final rows = await exec.query(
      'select connection_id from public.connector_connection '
      'where operator_id = public.app_current_operator() '
      'and location_id = public.app_current_location() '
      'and vendor_id = @vendor_id '
      'order by updated_at desc '
      'limit 1',
      parameters: <String, Object?>{
        'vendor_id': kAdpVendorId,
      },
    );
    if (rows.isEmpty) return null;
    final value = rows.single['connection_id'];
    if (value is String) return value;
    return value?.toString();
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
        'AdpPostgresSink could not resolve location timezone — '
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

  static int _deriveSeconds(DateTime start, DateTime? end) {
    if (end == null) return 0;
    final delta = end.toUtc().difference(start.toUtc()).inSeconds;
    return delta < 0 ? 0 : delta;
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

  static num? _readNumber(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is num) return value;
    if (value is String) return num.tryParse(value);
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
