// Phase 8 Wave B `8.spine-bridge.1.QBT` — QuickBooks Time Postgres
// sink.
//
// Authority (read in this order):
//
//   1. `docs/contracts/core_app_architecture.md` (Layers 1-12 binding)
//   2. `docs/contracts/integration_spine_architecture_contract.md`
//      sections "The canonical chain (binding)" and
//      "Sub-lane shape (binding)" / `.1.QBT`.
//   3. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//      — every fact-row write runs inside
//      `OperatorScopedRepository.withTenant`; RLS is the backup defense.
//   4. `lib/services/integration/canonical_sink.dart` — the unified
//      interface this sink implements.
//   5. `lib/services/integration/demo_mode_state.dart` — the flip
//      policy this sink composes for demo->live transition.
//   6. `lib/integrations/labor/quickbooks_time_labor_adapter.dart` —
//      the Wave B adapter that produces the canonical-fact dicts this
//      sink consumes (and the home of [ModuleRefusalException], the
//      shared module-refusal type re-thrown by this sink when the
//      operator's connector_connection row carries a non-`time`
//      module).
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
//   * HP #7 (server-side secrets): credentials / refresh tokens are
//     NOT touched here. The Wave B QBT adapter owns its own
//     credential gateway; this sink's only role is canonical-fact
//     persistence, watermark advance, sync log append, and demo flip.
//
// Banned items (V1 lean cut 2): the
// `lib/integrations/labor/quickbooks_time_labor_adapter.dart` test
// already asserts the adapter source is clean of every banned token
// from `memory/project_v1_lean_cut_2_2026_05_03.md`; the per-file
// banned grep in this slice's test pins the same ledger against this
// sink source so the lean cut stays enforced lane-by-lane.
//
// 2026-05-05 wage-source clarification: QuickBooks Time is classified
// `perEmployeeWithRates` (NOT `perEmployeeWithDollars`). The vendor
// timesheet endpoint exposes hours only; the wage rate lives on
// `Users.pay_rate`. This sink writes [pay_rate] (USD/hr) when the
// canonical-fact dict carries it; `labor_dollars` is left NULL —
// Lane `.2`'s aggregator computes dollars via rate x duration. See
// `docs/contracts/integration_spine_architecture_contract.md`
// 2026-05-05 falsehood corrections #6.

import 'dart:convert';

import '../../../integrations/labor/quickbooks_time_labor_adapter.dart'
    show
        ModuleRefusalException,
        QuickBooksTimeCanonicalPunchFact,
        QuickBooksTimeConnectionRow,
        QuickBooksTimeGateway,
        QuickBooksTimeWatermarkRow,
        kQuickBooksModuleTime,
        kQuickBooksTimeVendorId;
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/demo_mode_state.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import '../../../services/integration/projecting_canonical_sink.dart';
import '../../../services/integration/sink_business_date_projector.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'repositories/business_timing_profiles_repository.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// Resource string written into `connector_sync_watermark.resource`
/// for QuickBooks Time. Matches the canonical fact table the sink
/// drains into so the worker can read back the cursor by resource
/// without a vendor-side join.
const String kQuickBooksTimeWatermarkResource = 'labor_punches';

/// Postgres-backed [CanonicalSink] + [QuickBooksTimeGateway] for
/// QuickBooks Time.
///
/// Composes the bespoke `QuickBooksTimeGateway` shape onto the
/// `labor_punches` canonical fact table and the framework's
/// `connector_sync_watermark` / `connector_sync_log` /
/// `demo_mode_state` tables. Mirrors `8.spine-bridge.1.OR` (Oracle
/// MICROS Simphony Postgres sink) in shape; only the fact table and
/// the module-disambiguation guard differ.
///
/// Cover and reservation writes are explicit non-goals on this sink:
/// labor adapters never produce them. [upsertCoverFact] and
/// [upsertReservationFact] both throw [UnsupportedError] — the
/// `tool/integration_sync_worker` dispatcher routes by category, so
/// these throws are defense-in-depth assertions against future
/// router refactors that could miswire a labor connection's tick to
/// a covers / reservation seam.
class QuickBooksTimePostgresSink extends OperatorScopedRepository
    implements CanonicalSink, QuickBooksTimeGateway {
  QuickBooksTimePostgresSink({
    required TenantTransactionWrapper tenantWrapper,
    IanaTimezoneConverter? timezoneConverter,
    SinkBusinessDateProjector? businessDateProjector,
    BusinessTimingProfilesRepository? profilesRepository,
    CanonicalFactProjectionTap? projectionTap,
    DateTime Function()? now,
  }) : _businessDateProjector =
           businessDateProjector ??
           SinkBusinessDateProjector(
             profilesRepository:
                 profilesRepository ??
                 BusinessTimingProfilesRepository(tenantWrapper),
             timezoneConverter:
                 timezoneConverter ?? IanaTimezoneConverter.shared,
           ),
       _projectionTap = projectionTap,
       _now = now ?? DateTime.now,
       super(tenantWrapper);

  // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): QuickBooks Time
  // no longer reads `locations.business_day_rollover_hour`. The cutoff
  // is resolved through the canonical `BusinessTimingProfilesRepository`
  // chain inside the projector.
  final SinkBusinessDateProjector _businessDateProjector;
  final CanonicalFactProjectionTap? _projectionTap;
  final DateTime Function() _now;

  // ─── CanonicalSink: covers / reservations are unsupported ─────────

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    throw UnsupportedError(
      'QuickBooksTimePostgresSink is a labor sink; cover writes are not '
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
      'QuickBooksTimePostgresSink is a labor sink; reservation writes are '
      'not supported. Routing bug — dispatcher must call the reservation '
      'sink for the reservation_facts category.',
    );
  }

  // ─── CanonicalSink: labor punch upsert ────────────────────────────

  /// Upsert one canonical punch row into `labor_punches`.
  ///
  /// Required keys on [canonicalPunch]:
  ///
  ///   * `vendor_entity_id` — string; QuickBooks Time `timesheets[].id`.
  ///   * `vendor_modified_at` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `shift_start` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `employee_source_id` — string; QuickBooks Time
  ///     `timesheets[].user_id` stringified.
  ///   * `role_name` — string.
  ///   * `hours_worked` — num seconds (matches QBT `duration` payload).
  ///
  /// Optional keys:
  ///
  ///   * `shift_end` — `DateTime` (UTC) or ISO-8601 string; null /
  ///     absent when the timesheet is still open (employee clocked
  ///     in but not out yet).
  ///   * `pay_rate` — num USD/hr from QBT `Users.pay_rate` join. Left
  ///     null when the connector did not request the pay-rate scope.
  ///   * `raw_payload` — vendor-shape Map preserved for forensic
  ///     re-derivation.
  ///
  /// Module disambiguation: this sink reads
  /// `connector_connection.module` for the `(operator_id,
  /// location_id, vendor_id='quickbooks_time')` triple. When the
  /// stored module is anything other than [kQuickBooksModuleTime]
  /// (e.g. `payroll` or `accounting`), the sink throws
  /// [ModuleRefusalException] BEFORE the labor_punches insert so the
  /// non-time module's payload never lands in canonical truth even
  /// if a router bug hands the sink a misrouted batch.
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
  }) async {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    final inserted = await withTenant<bool>(ctx, (exec) async {
      return _upsertLaborPunchInternal(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        canonicalPunch: canonicalPunch,
      );
    });
    if (inserted) {
      _projectionTap?.recordCommittedLaborPunch(
        operatorId: operatorId,
        locationId: locationId,
        canonicalPunch: canonicalPunch,
      );
    }
    return inserted;
  }

  // ─── QuickBooksTimeGateway: typed punch-fact write ────────────────

  /// Bespoke [QuickBooksTimeGateway.writePunchFact] entry — translates
  /// the typed canonical fact into the dict shape and delegates to the
  /// shared private writer. The fact carries hours only (QBT wage class
  /// is `perEmployeeWithRates`); `pay_rate` is sourced separately from
  /// the `Users` catalog and the dict shape's `pay_rate` key. The typed
  /// fact does not carry `pay_rate`, so the gateway path leaves the
  /// column NULL — Lane `.2`'s aggregator computes labor_dollars via
  /// rate × duration when both land.
  @override
  Future<bool> writePunchFact(QuickBooksTimeCanonicalPunchFact fact) async {
    final canonicalPunch = <String, Object?>{
      'vendor_entity_id': fact.vendorEntityId,
      'vendor_modified_at': fact.vendorModifiedAt,
      'shift_start': fact.shiftStart,
      'shift_end': fact.shiftEnd,
      'employee_source_id': fact.employeeId,
      'role_name': fact.roleName,
      'hours_worked': _deriveSeconds(fact.shiftStart, fact.shiftEnd),
      'raw_payload': fact.rawPayload,
    };
    final ctx = TenantContext(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
    );
    final inserted = await withTenant<bool>(ctx, (exec) async {
      return _upsertLaborPunchInternal(
        exec: exec,
        operatorId: fact.operatorId,
        locationId: fact.locationId,
        canonicalPunch: canonicalPunch,
      );
    });
    if (inserted) {
      _projectionTap?.recordCommittedLaborPunch(
        operatorId: fact.operatorId,
        locationId: fact.locationId,
        canonicalPunch: canonicalPunch,
      );
    }
    return inserted;
  }

  // ─── Shared private writer ────────────────────────────────────────

  Future<bool> _upsertLaborPunchInternal({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) async {
    final vendorEntityId = _requireString(canonicalPunch, 'vendor_entity_id');
    final vendorModifiedAt = _requireUtcInstant(
      canonicalPunch,
      'vendor_modified_at',
    );
    final shiftStart = _requireUtcInstant(canonicalPunch, 'shift_start');
    final shiftEnd = _readUtcInstant(canonicalPunch, 'shift_end');
    final employeeSourceId = _requireString(
      canonicalPunch,
      'employee_source_id',
    );
    final roleName = _requireString(canonicalPunch, 'role_name');
    final hoursWorked = _requireNumber(canonicalPunch, 'hours_worked');
    final payRate = _readNumber(canonicalPunch, 'pay_rate');
    final rawPayload = _readPayload(canonicalPunch, 'raw_payload');

    // Module disambiguation — refuse anything other than `time`.
    final module = await _readConnectionModule(exec);
    if (module != kQuickBooksModuleTime) {
      throw ModuleRefusalException(
        module: module ?? '',
        message:
            'QuickBooks Time sink received a punch row attributed to '
            'connector_connection.module="${module ?? ''}"; only the '
            '"time" module is supported. Reconnect from the QuickBooks '
            'Time tile in the Vendor integrations widget.',
      );
    }

    final businessDate = await _resolveBusinessDate(
      exec,
      operatorId,
      locationId,
      shiftStart,
    );
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
      'pay_rate = excluded.pay_rate, '
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
        'pay_rate': payRate,
        'vendor_id': kQuickBooksTimeVendorId,
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
  /// Resource is pinned to [kQuickBooksTimeWatermarkResource] so the
  /// watermark row is unique per `(connection_id, resource)` and
  /// other QBT resources (if added later) get their own row.
  @override
  Future<void> advanceWatermark({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String cursorToken,
    required DateTime lastModifiedSeen,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
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

  // ─── QuickBooksTimeGateway: watermark read / write ────────────────

  @override
  Future<QuickBooksTimeWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<QuickBooksTimeWatermarkRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select cursor_token, last_modified_seen '
        'from public.connector_sync_watermark '
        'where operator_id = public.app_current_operator() '
        'and location_id = public.app_current_location() '
        'and resource = @resource '
        'order by updated_at desc '
        'limit 1',
        parameters: <String, Object?>{
          'resource': kQuickBooksTimeWatermarkResource,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final cursor = row['cursor_token'];
      final modified = row['last_modified_seen'];
      if (cursor is! String || modified is! DateTime) return null;
      return QuickBooksTimeWatermarkRow(
        cursorToken: cursor,
        lastModifiedSeen: modified.toUtc(),
      );
    });
  }

  /// Sister-path to [advanceWatermark] for the bespoke gateway shape.
  /// The gateway-side signature does not carry `connection_id`; the
  /// sink resolves one from `connector_connection` for the (operator,
  /// location, vendor=quickbooks_time) triple, then delegates to the
  /// shared internal writer.
  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required QuickBooksTimeWatermarkRow row,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      final connectionId = await _resolveConnectionId(exec);
      if (connectionId == null) {
        throw StateError(
          'QuickBooksTimePostgresSink.writeWatermark could not resolve a '
          'connector_connection row for the active (operator, location, '
          'vendor=quickbooks_time) tenant context. The adapter should '
          'upsert the connection before any watermark write.',
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
        'resource': kQuickBooksTimeWatermarkResource,
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
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
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
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      // INSERT default-demo row when missing, then flip is_demo only
      // when the row is still demo. The WHERE clause on the UPDATE
      // path is what makes this idempotent — once flipped to live,
      // a second evaluate is a no-op (the WHERE filters out the row),
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

  // ─── QuickBooksTimeGateway: connection / credential lookup + wipe ─

  @override
  Future<QuickBooksTimeConnectionRow> upsertConnection({
    required QuickBooksTimeConnectionRow row,
  }) {
    final ctx = TenantContext(
      operatorId: row.operatorId,
      locationId: row.locationId,
    );
    return withTenant<QuickBooksTimeConnectionRow>(ctx, (exec) async {
      final returning = await exec.query(
        'insert into public.connector_connection ('
        'operator_id, location_id, vendor_id, category, status, '
        'module, metadata'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, '
        "'labor', @status, @module, @metadata::jsonb"
        ') on conflict (operator_id, location_id, vendor_id, '
        "coalesce(module, '')) do update set "
        'status = excluded.status, '
        'metadata = excluded.metadata, '
        'updated_at = now() '
        'returning connection_id',
        parameters: <String, Object?>{
          'operator_id': row.operatorId,
          'location_id': row.locationId,
          'vendor_id': kQuickBooksTimeVendorId,
          'status': row.status.name,
          'module': row.module,
          'metadata': jsonEncode(row.toMetadata()),
        },
      );
      final connectionId = returning.isEmpty
          ? row.connectionId
          : (returning.single['connection_id']?.toString() ?? row.connectionId);
      return QuickBooksTimeConnectionRow(
        connectionId: connectionId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        intuitRealmId: row.intuitRealmId,
        module: row.module,
        status: row.status,
      );
    });
  }

  @override
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
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
        parameters: <String, Object?>{'vendor_id': kQuickBooksTimeVendorId},
      );
    });
  }

  @override
  Future<String?> readAccessToken({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
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
        parameters: <String, Object?>{'vendor_id': kQuickBooksTimeVendorId},
      );
      if (rows.isEmpty) return null;
      final value = rows.single['access_token_ciphertext'];
      if (value is String) return value;
      return null;
    });
  }

  @override
  Future<String?> readIntuitRealmId({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        'select metadata from public.connector_connection '
        'where operator_id = public.app_current_operator() '
        'and location_id = public.app_current_location() '
        'and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{'vendor_id': kQuickBooksTimeVendorId},
      );
      if (rows.isEmpty) return null;
      final metadata = rows.single['metadata'];
      Map<Object?, Object?>? parsed;
      if (metadata is Map) {
        parsed = metadata;
      } else if (metadata is String && metadata.isNotEmpty) {
        try {
          final decoded = jsonDecode(metadata);
          if (decoded is Map) parsed = decoded;
        } catch (_) {
          return null;
        }
      }
      if (parsed == null) return null;
      final value = parsed['intuit_realm_id'];
      if (value is String && value.isNotEmpty) return value;
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
      parameters: <String, Object?>{'vendor_id': kQuickBooksTimeVendorId},
    );
    if (rows.isEmpty) return null;
    final value = rows.single['connection_id'];
    if (value is String) return value;
    return value?.toString();
  }

  Future<String?> _readConnectionModule(PostgresExecutor exec) async {
    final rows = await exec.query(
      'select module from public.connector_connection '
      'where operator_id = public.app_current_operator() '
      'and location_id = public.app_current_location() '
      'and vendor_id = @vendor_id '
      'limit 1',
      parameters: <String, Object?>{'vendor_id': kQuickBooksTimeVendorId},
    );
    if (rows.isEmpty) return null;
    final value = rows.single['module'];
    if (value is String) return value;
    return null;
  }

  static int _deriveSeconds(DateTime start, DateTime? end) {
    if (end == null) return 0;
    final delta = end.toUtc().difference(start.toUtc()).inSeconds;
    return delta < 0 ? 0 : delta;
  }

  /// Per-Daypart V1 / Slice 7b option (b) (2026-05-15): the SELECT
  /// returns `timezone` only — no `business_day_rollover_hour`. The
  /// cutoff itself is resolved through the canonical
  /// `BusinessTimingProfilesRepository` chain inside the projector.
  Future<DateTime> _resolveBusinessDate(
    PostgresExecutor exec,
    String operatorId,
    String locationId,
    DateTime shiftStartUtc,
  ) async {
    final rows = await exec.query(
      'select timezone from public.locations '
      'where operator_id = public.app_current_operator() '
      'and location_id = public.app_current_location() '
      'limit 1',
    );
    if (rows.isEmpty) {
      throw StateError(
        'QuickBooksTimePostgresSink could not resolve location timezone — '
        'the locations row is missing for the active tenant context.',
      );
    }
    final row = rows.single;
    final timezone = row['timezone'];
    if (timezone is! String || timezone.isEmpty) {
      throw StateError(
        'locations.timezone missing for the active tenant context; '
        'cannot bucket business_date.',
      );
    }
    return _businessDateProjector.projectBusinessDate(
      operatorId: operatorId,
      locationId: locationId,
      restaurantTimezone: timezone,
      instantUtc: shiftStartUtc,
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

  static num _requireNumber(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is num) return value;
    if (value is String) {
      final parsed = num.tryParse(value);
      if (parsed != null) return parsed;
    }
    throw ArgumentError.value(value, key, 'canonicalPunch.$key must be a num');
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
