// Phase 8 Wave B `8.spine-bridge.1.HM` — Humanity (TCP) Postgres sink.
//
// Authority (read in this order):
//
//   1. `docs/contracts/core_app_architecture.md` (Layers 1-12 binding;
//      Layer 2 Canonical Facts owns `labor_punches`).
//   2. `docs/contracts/integration_spine_architecture_contract.md`
//      sections "The canonical chain (binding)" and
//      "Sub-lane shape (binding)" / `.1.HM`.
//   3. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//      — every fact-row write runs inside
//      `OperatorScopedRepository.withTenant`; RLS is the backup defense.
//   4. `lib/services/integration/canonical_sink.dart` — the unified
//      interface this sink implements.
//   5. `lib/services/integration/demo_mode_state.dart` — the flip
//      policy this sink composes for demo->live transition.
//   6. `lib/integrations/labor/humanity_labor_adapter.dart` — the
//      Wave B adapter that produces the canonical-fact dicts this
//      sink consumes (and the home of `HumanityGateway`,
//      `HumanityCanonicalShiftFact`, `HumanityWatermarkRow`,
//      `VendorCredentialHandle`, `kHumanityVendorId`).
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//
//   * HP #1 (pure transport swap): writes flow into the existing
//     `labor_punches` canonical fact table; no formula change, no
//     read-service contract drift.
//   * HP #2 (demo mode persists post-launch): [evaluateDemoFlip]
//     centralises the (operator, location, category) flip rule via
//     `INSERT ... ON CONFLICT DO UPDATE WHERE is_demo`, so the same
//     code path runs whether the operator is in demo or live; the
//     idempotent flip policy preserves the original triggering
//     `flipped_to_live_at` and `flipped_by_connection_id`.
//   * HP #4 (per-operator isolation): every method takes
//     `(operatorId, locationId)` and runs through `withTenant` so the
//     repository pattern is the primary tenant defense and Postgres
//     RLS is the backup.
//   * HP #7 (server-side secrets): the proxy posts to Humanity's
//     legacy `/oauth2/token` (`grant_type=password`) and stashes the
//     issued bearer in `vendor_credentials` (pgcrypto envelope). This
//     sink is auth-shape agnostic — [wipeCredentials] issues the same
//     `delete from public.vendor_credentials` SQL whether the stored
//     ciphertext is an OAuth bearer (every other Wave B labor sink) or
//     a Humanity legacy session token. The credential-store schema is
//     uniform; the connect-time exchange differs in the adapter, not
//     here.
//
// Banned items (V1 lean cut 2): the
// `lib/integrations/labor/humanity_labor_adapter.dart` test already
// asserts the adapter source is clean of every banned token from
// `memory/project_v1_lean_cut_2_2026_05_03.md`; the per-file banned
// grep in this slice's test pins the same ledger against this sink
// source so the lean cut stays enforced lane-by-lane.
//
// Wage-source classification: Humanity is a scheduling-only product;
// the documented v1 API exposes no pay-rate field. `pay_rate` and
// `labor_dollars` are left NULL on every Humanity row — the worker
// (or Phase 7.58 aggregator) joins payroll-side facts when present.
// `hours_worked` is derived as `(shift_end - shift_start).inSeconds`
// when both sides are populated, mirroring the canonical labor_punches
// units the QBT sink writes.

import 'dart:convert';

import '../../../integrations/labor/humanity_labor_adapter.dart'
    show
        HumanityCanonicalShiftFact,
        HumanityGateway,
        HumanityWatermarkRow,
        VendorCredentialHandle,
        kHumanityVendorId;
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
/// for Humanity. Matches the canonical fact table the sink drains
/// into so the worker can read back the cursor by resource without a
/// vendor-side join.
const String humanityWatermarkResource = 'labor_punches';

/// Postgres-backed sink for Humanity (TCP).
///
/// Implements both [HumanityGateway] (the bespoke seam the existing
/// Wave B `HumanityLaborAdapter` writes through) and the unified
/// [CanonicalSink] surface from `.0`. The two surfaces share one
/// `withTenant`-wrapped engine; they differ only in the input shape
/// and in whether `connection_id` is supplied directly
/// ([CanonicalSink.advanceWatermark] / [CanonicalSink.appendSyncLog])
/// or resolved from `connector_connection` ([HumanityGateway.writeWatermark]).
///
/// Cover and reservation writes are explicit non-goals on this sink:
/// labor adapters never produce them. [upsertCoverFact] and
/// [upsertReservationFact] both throw [UnsupportedError] — the
/// `tool/integration_sync_worker` dispatcher routes by category, so
/// these throws are defense-in-depth assertions against future router
/// refactors that could miswire a labor connection's tick to a covers
/// / reservation seam.
class HumanityPostgresSink extends OperatorScopedRepository
    implements HumanityGateway, CanonicalSink {
  HumanityPostgresSink({
    required TenantTransactionWrapper tenantWrapper,
    IanaTimezoneConverter? timezoneConverter,
    DateTime Function()? now,
  })  : _timezoneConverter = timezoneConverter ?? IanaTimezoneConverter.shared,
        _now = now ?? DateTime.now,
        super(tenantWrapper);

  final IanaTimezoneConverter _timezoneConverter;
  final DateTime Function() _now;

  // ─── HumanityGateway: connect lifecycle ───────────────────────────

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
    return withTenant<String>(ctx, (exec) async {
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
          'vendor_id': kHumanityVendorId,
          'category': IntegrationCategory.labor.name,
          'metadata': jsonEncode(metadata),
          'actor_user_id': actorUserId,
        },
      );
      final connectionId = connectionRows.first['connection_id']! as String;
      // Auth-shape-agnostic credential persist: the proxy already
      // exchanged username/password for the bearer at the connect
      // route; the handle id IS the credential id stored under
      // `vendor_credentials`. The same UPSERT shape applies whether
      // the original auth was OAuth or legacy username/password.
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
          'vendor_id': kHumanityVendorId,
        },
      );
      return connectionId;
    });
  }

  @override
  Future<VendorCredentialHandle?> readCredential({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<VendorCredentialHandle?>(ctx, (exec) async {
      final rows = await exec.query(
        'select vc.credential_id '
        'from public.vendor_credentials vc '
        'join public.connector_connection cc '
        '  on cc.connection_id = vc.connection_id '
        'where cc.operator_id = @operator_id::uuid '
        '  and cc.location_id = @location_id::uuid '
        '  and cc.vendor_id = @vendor_id '
        "  and cc.status = 'connected' "
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kHumanityVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final credentialId = rows.first['credential_id'];
      if (credentialId is! String || credentialId.isEmpty) return null;
      return VendorCredentialHandle(credentialId: credentialId);
    });
  }

  @override
  Future<HumanityWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<HumanityWatermarkRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select w.cursor_token, w.last_modified_seen '
        'from public.connector_sync_watermark w '
        'join public.connector_connection cc '
        '  on cc.connection_id = w.connection_id '
        'where cc.operator_id = @operator_id::uuid '
        '  and cc.location_id = @location_id::uuid '
        '  and cc.vendor_id = @vendor_id '
        '  and w.resource = @resource '
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kHumanityVendorId,
          'resource': humanityWatermarkResource,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.first;
      final cursor = row['cursor_token'];
      final lastModified = row['last_modified_seen'];
      if (cursor is! String || lastModified is! DateTime) return null;
      return HumanityWatermarkRow(
        cursorToken: cursor,
        lastModifiedSeen: lastModified.toUtc(),
      );
    });
  }

  // ─── HumanityGateway: watermark write (gateway path; resolves
  // connection_id from the active tenant) ───────────────────────────

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required HumanityWatermarkRow row,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      final connectionId = await _resolveConnectionId(exec);
      if (connectionId == null) {
        throw StateError(
          'HumanityPostgresSink.writeWatermark could not resolve a '
          'connector_connection.connection_id for the active tenant '
          '(operator=$operatorId, location=$locationId, vendor='
          '$kHumanityVendorId); the gateway path requires a connected '
          'row. Reconnect from the Humanity tile in the Vendor '
          'Connections widget.',
        );
      }
      await _writeWatermark(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        cursorToken: row.cursorToken,
        lastModifiedSeen: row.lastModifiedSeen,
      );
    });
  }

  // ─── HumanityGateway: shift-fact write (gateway path, typed) ─────

  @override
  Future<bool> writeShiftFact(HumanityCanonicalShiftFact fact) {
    final ctx = TenantContext(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      return _upsertLaborPunch(
        exec: exec,
        operatorId: fact.operatorId,
        locationId: fact.locationId,
        vendorEntityId: fact.vendorEntityId,
        vendorModifiedAt: fact.vendorModifiedAt,
        employeeSourceId: fact.employeeId,
        roleName: fact.positionName,
        shiftStart: fact.shiftStart,
        shiftEnd: fact.shiftEnd,
        hoursWorked: _deriveHoursWorked(fact.shiftStart, fact.shiftEnd),
        payRate: null,
        rawPayload: fact.rawPayload,
      );
    });
  }

  // ─── HumanityGateway: credential wipe (auth-shape agnostic) ──────

  @override
  Future<void> wipeCredentials({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(operatorId: operatorId, locationId: locationId);
    return withTenant<void>(ctx, (exec) async {
      // Auth-shape agnostic: same DELETE shape whether the stored
      // ciphertext is an OAuth bearer (every other Wave B labor sink)
      // or a Humanity legacy session token. The credential-store
      // schema is uniform.
      await exec.execute(
        'delete from public.vendor_credentials '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kHumanityVendorId,
        },
      );
      await exec.execute(
        'update public.connector_connection set '
        "  status = 'disconnected', "
        '  updated_at = now() '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        '  and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': kHumanityVendorId,
        },
      );
    });
  }

  // ─── CanonicalSink: covers / reservations are unsupported ────────

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    throw UnsupportedError(
      'HumanityPostgresSink is a labor sink; cover writes are not '
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
      'HumanityPostgresSink is a labor sink; reservation writes are '
      'not supported. Routing bug — dispatcher must call the reservation '
      'sink for the reservation_facts category.',
    );
  }

  // ─── CanonicalSink: labor punch upsert (Map dispatch path) ───────

  /// Upsert one canonical Humanity shift row into `labor_punches`.
  ///
  /// Required keys on [canonicalPunch]:
  ///
  ///   * `vendor_entity_id` — string; Humanity `shifts.id`.
  ///   * `vendor_modified_at` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `shift_start` — `DateTime` (UTC) or ISO-8601 string;
  ///     Humanity `shifts.in_time`.
  ///   * `shift_end` — `DateTime` (UTC) or ISO-8601 string;
  ///     Humanity `shifts.out_time`.
  ///   * `employee_source_id` — string; Humanity `employees.id`.
  ///   * `role_name` — string; Humanity `positions.name`.
  ///
  /// Optional keys:
  ///
  ///   * `hours_worked` — num seconds. Derived from
  ///     `shift_end - shift_start` when absent (Humanity does not
  ///     publish a discrete duration field).
  ///   * `pay_rate` — left null on every Humanity row; Humanity is a
  ///     scheduling-only product and its v1 API exposes no pay-rate
  ///     field. The aggregator joins payroll-side facts when present.
  ///   * `raw_payload` — vendor-shape Map preserved for forensic
  ///     re-derivation.
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
    final vendorEntityId = _requireString(canonicalPunch, 'vendor_entity_id');
    final vendorModifiedAt =
        _requireUtcInstant(canonicalPunch, 'vendor_modified_at');
    final shiftStart = _requireUtcInstant(canonicalPunch, 'shift_start');
    final shiftEnd = _readUtcInstant(canonicalPunch, 'shift_end');
    final employeeSourceId =
        _requireString(canonicalPunch, 'employee_source_id');
    final roleName = _requireString(canonicalPunch, 'role_name');
    final hoursWorked = _readNumber(canonicalPunch, 'hours_worked') ??
        _deriveHoursWorked(shiftStart, shiftEnd);
    final payRate = _readNumber(canonicalPunch, 'pay_rate');
    final rawPayload = _readPayload(canonicalPunch, 'raw_payload');

    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      return _upsertLaborPunch(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        vendorEntityId: vendorEntityId,
        vendorModifiedAt: vendorModifiedAt,
        employeeSourceId: employeeSourceId,
        roleName: roleName,
        shiftStart: shiftStart,
        shiftEnd: shiftEnd,
        hoursWorked: hoursWorked,
        payRate: payRate,
        rawPayload: rawPayload,
      );
    });
  }

  // ─── CanonicalSink: watermark advance ─────────────────────────────

  /// Persist `cursor_token` + `last_modified_seen` for the connection
  /// AFTER each batch commit. Cloud Run Job restart resilience: the
  /// next tick resumes from the persisted cursor even when the worker
  /// dies mid-window.
  ///
  /// Resource is pinned to [humanityWatermarkResource] so the
  /// watermark row is unique per `(connection_id, resource)` and
  /// other Humanity resources (if added later) get their own row.
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
      await _writeWatermark(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
      );
    });
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

  // ─── CanonicalSink: demo-mode flip (category=labor) ──────────────

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

  // ─── Shared private writers ───────────────────────────────────────

  Future<bool> _upsertLaborPunch({
    required PostgresExecutor exec,
    required String operatorId,
    required String locationId,
    required String vendorEntityId,
    required DateTime vendorModifiedAt,
    required String employeeSourceId,
    required String roleName,
    required DateTime shiftStart,
    required DateTime? shiftEnd,
    required num? hoursWorked,
    required num? payRate,
    required Map<String, Object?> rawPayload,
  }) async {
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
        'pay_rate': payRate,
        'vendor_id': kHumanityVendorId,
        'vendor_entity_id': vendorEntityId,
        'vendor_modified_at': vendorModifiedAt,
        'raw_payload': jsonEncode(rawPayload),
        'business_date': _formatDate(businessDate),
      },
    );
    return affected > 0;
  }

  Future<void> _writeWatermark({
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
      'updated_at = now()',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'resource': humanityWatermarkResource,
        'last_synced_at': _now().toUtc(),
        'last_modified_seen': lastModifiedSeen.toUtc(),
        'cursor_token': cursorToken,
      },
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<String?> _resolveConnectionId(PostgresExecutor exec) async {
    final rows = await exec.query(
      'select connection_id from public.connector_connection '
      'where operator_id = public.app_current_operator() '
      'and location_id = public.app_current_location() '
      'and vendor_id = @vendor_id '
      'limit 1',
      parameters: <String, Object?>{
        'vendor_id': kHumanityVendorId,
      },
    );
    if (rows.isEmpty) return null;
    final value = rows.single['connection_id'];
    if (value is String && value.isNotEmpty) return value;
    return null;
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
        'HumanityPostgresSink could not resolve location timezone — '
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

  static num? _deriveHoursWorked(DateTime shiftStart, DateTime? shiftEnd) {
    if (shiftEnd == null) return null;
    return shiftEnd.difference(shiftStart).inSeconds;
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
