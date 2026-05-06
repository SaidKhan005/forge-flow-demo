// Phase 8 Wave B `8.spine-bridge.7S` — 7shifts Postgres sink.
//
// Authority (read in this order):
//
//   1. `docs/contracts/core_app_architecture.md` (Layers 1-12 binding)
//   2. `docs/contracts/integration_spine_architecture_contract.md`
//      sections "The canonical chain (binding)" + "Sub-lane shape"
//      (`.7S`); 2026-05-05 falsehood corrections #6 (wage class).
//   3. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//      — every fact-row write runs inside
//      `OperatorScopedRepository.withTenant`; RLS is the backup defense.
//   4. `lib/services/integration/canonical_sink.dart` — the unified
//      interface this sink implements.
//   5. `lib/services/integration/demo_mode_state.dart` — the flip
//      policy this sink composes for demo->live transition.
//   6. `lib/integrations/labor/seven_shifts_labor_adapter.dart` — the
//      Wave B adapter that produces the canonical-fact shapes this
//      sink consumes (`SevenShiftsCanonicalTimePunchFact`,
//      `SevenShiftsCanonicalPayrollPeriodClosedFact`,
//      `SevenShiftsConnectionRow`, `SevenShiftsWatermarkRow`).
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//
//   * HP #1 (pure transport swap): writes flow into the existing
//     `labor_punches` canonical fact table; no formula change, no
//     read-service contract drift.
//   * HP #2 (demo mode persists post-launch): [evaluateDemoFlip]
//     centralises the (operator, location, category) flip rule using
//     `INSERT ... ON CONFLICT DO UPDATE WHERE is_demo`, so the same
//     code path runs whether the operator is in demo or live. The
//     idempotent flip policy preserves the original triggering
//     `flipped_to_live_at` and `flipped_by_connection_id`.
//   * HP #4 (per-operator isolation): every method takes
//     `(operatorId, locationId)` and runs through `withTenant` so the
//     repository pattern is the primary tenant defense and Postgres
//     RLS is the backup.
//   * HP #7 (server-side secrets): credential ciphertext is read
//     opaquely; this sink does NOT decrypt. Production decryption is
//     a separate hardening lane (the V1 stub returns the raw column
//     value so test harnesses can populate it directly).
//
// Banned items (V1 lean cut 2): the
// `lib/integrations/labor/seven_shifts_labor_adapter.dart` test
// already asserts the adapter source is clean of every banned token
// from `memory/project_v1_lean_cut_2_2026_05_03.md`; the per-file
// banned grep in this slice's test pins the same ledger against this
// sink source.
//
// 2026-05-05 wage-source clarification (falsehood correction #6):
// 7shifts at V1 is classified `perEmployeeWithRates` (NOT
// `perEmployeeWithDollars`). The vendor's `/reports/hours_and_wages`
// endpoint that exposes per-shift dollar totals is gated to the
// Gourmet plan tier and lands in lane `.7S.upgrade`; until that lane
// ships, this sink writes [pay_rate] (USD/hr) when the canonical-fact
// dict carries it and leaves `labor_dollars` NULL — Lane `.2`'s
// aggregator computes dollars via rate × duration. The vendor-side
// per-shift wage column lives behind that report and is intentionally
// not referenced here; the slice's banned-items grep test rejects any
// occurrence of that token in this source until lane `.7S.upgrade`
// extends the contract.

import 'dart:convert';

import '../../../integrations/labor/seven_shifts_labor_adapter.dart'
    show
        SevenShiftsCanonicalPayrollPeriodClosedFact,
        SevenShiftsCanonicalTimePunchFact,
        SevenShiftsConnectionRow,
        SevenShiftsGateway,
        SevenShiftsWatermarkRow,
        kSevenShiftsVendorId;
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/demo_mode_state.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// Resource string written into `connector_sync_watermark.resource`
/// for 7shifts. Matches the canonical fact table the sink drains into
/// so the worker can read back the cursor by resource without a
/// vendor-side join.
const String sevenShiftsWatermarkResource = 'labor_punches';

/// `connector_sync_log.event_kind` written when the
/// `/reports/hours_and_wages` endpoint returned HTTP 403/404 for this
/// connection — the operator's 7shifts plan tier does not unlock
/// per-shift dollar totals. The substituted-wage provenance on the
/// canonical fact is the downstream aggregator signal; this log row
/// is the operator-facing surface Lane `.B`'s Data Accuracy tab can
/// read.
const String kSevenShiftsHoursAndWagesReportGatedSyncLogKind =
    'hours_and_wages_report_gated';

/// `connector_sync_log.event_kind` written when a closed payroll
/// period lands. V1 has no dedicated `payroll_periods` table — the
/// closed instant is recorded as a structured log row so the Phase
/// 7.58 Primary Driver audit can read it back without a new
/// migration. The dedicated table is a Phase 7.55+ concern.
const String kSevenShiftsPayrollPeriodClosedSyncLogKind =
    'payroll_period_closed';

/// Postgres-backed [CanonicalSink] + bespoke [SevenShiftsGateway]
/// implementation for 7shifts.
///
/// Mirrors `8.spine-bridge.1.QBT` (QuickBooks Time Postgres sink) in
/// shape; only the fact table-row mapping (no `actual_labor_dollars`
/// column at V1 — wage class is `perEmployeeWithRates`) and the
/// absent module-disambiguation guard differ. 7shifts has a single
/// module (`time`) so there is no second-module refusal seam.
///
/// Cover and reservation writes are explicit non-goals on this sink:
/// labor adapters never produce them. [upsertCoverFact] and
/// [upsertReservationFact] both throw [UnsupportedError] — the
/// `tool/integration_sync_worker` dispatcher routes by category, so
/// these throws are defense-in-depth assertions against future
/// router refactors that could miswire a labor connection's tick to
/// a covers / reservation seam.
class SevenShiftsPostgresSink extends OperatorScopedRepository
    implements CanonicalSink, SevenShiftsGateway {
  SevenShiftsPostgresSink({
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
      'SevenShiftsPostgresSink is a labor sink; cover writes are not '
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
      'SevenShiftsPostgresSink is a labor sink; reservation writes are '
      'not supported. Routing bug — dispatcher must call the reservation '
      'sink for the reservation_facts category.',
    );
  }

  // ─── CanonicalSink: labor punch upsert (Map shape) ────────────────

  /// Upsert one canonical punch row into `labor_punches` from a
  /// dictionary shape (the [CanonicalSink] entry point used by the
  /// dispatcher / aggregator).
  ///
  /// Required keys on [canonicalPunch]:
  ///
  ///   * `vendor_entity_id` — string; 7shifts `time_punches[].id`.
  ///   * `vendor_modified_at` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `shift_start` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `employee_source_id` (or `employee_id`) — string; 7shifts
  ///     `time_punches[].user_id` stringified.
  ///   * `role_name` — string.
  ///   * `hours_worked` — num seconds (matches the QBT contract; the
  ///     adapter computes shift_end - shift_start when shift_end is
  ///     populated, else passes 0).
  ///
  /// Optional keys:
  ///
  ///   * `shift_end` — `DateTime` (UTC) or ISO-8601 string; null /
  ///     absent when the punch is open (employee clocked in but not
  ///     out yet).
  ///   * `pay_rate` — num USD/hr from the 7shifts `Users.wage` /
  ///     `Roles.wage` join. Null when the operator's connector did not
  ///     request the wage scope OR the employee has no rate on file.
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
    final employeeSourceId = _requireEmployeeId(canonicalPunch);
    final roleName = _requireString(canonicalPunch, 'role_name');
    final hoursWorked = _requireNumber(canonicalPunch, 'hours_worked');
    final payRate = _readNumber(canonicalPunch, 'pay_rate');
    final rawPayload = _readPayload(canonicalPunch, 'raw_payload');

    return _insertLaborPunch(
      operatorId: operatorId,
      locationId: locationId,
      vendorEntityId: vendorEntityId,
      vendorModifiedAt: vendorModifiedAt,
      shiftStart: shiftStart,
      shiftEnd: shiftEnd,
      employeeSourceId: employeeSourceId,
      roleName: roleName,
      hoursWorked: hoursWorked,
      payRate: payRate,
      rawPayload: rawPayload,
    );
  }

  // ─── SevenShiftsGateway: connection upsert ────────────────────────

  @override
  Future<SevenShiftsConnectionRow> upsertConnection({
    required SevenShiftsConnectionRow row,
  }) {
    final ctx = TenantContext(
      operatorId: row.operatorId,
      locationId: row.locationId,
    );
    return withTenant<SevenShiftsConnectionRow>(ctx, (exec) async {
      await exec.execute(
        'insert into public.connector_connection ('
        'connection_id, operator_id, location_id, vendor_id, category, '
        'status, metadata'
        ') values ('
        '@connection_id::uuid, @operator_id::uuid, @location_id::uuid, '
        '@vendor_id, @category, @status, @metadata::jsonb'
        ') on conflict (operator_id, location_id, vendor_id, '
        "coalesce(module, '')) do update set "
        'status = excluded.status, '
        'metadata = excluded.metadata, '
        'updated_at = now()',
        parameters: <String, Object?>{
          'connection_id': row.connectionId,
          'operator_id': row.operatorId,
          'location_id': row.locationId,
          'vendor_id': kSevenShiftsVendorId,
          'category': IntegrationCategory.labor.name,
          'status': row.status.name,
          'metadata': jsonEncode(row.toMetadata()),
        },
      );
      return row;
    });
  }

  // ─── SevenShiftsGateway: bespoke watermark read/write ─────────────

  @override
  Future<SevenShiftsWatermarkRow?> readWatermark({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<SevenShiftsWatermarkRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select w.cursor_token, w.last_modified_seen '
        'from public.connector_sync_watermark w '
        'join public.connector_connection c '
        '  on c.connection_id = w.connection_id '
        'where c.operator_id = public.app_current_operator() '
        'and c.location_id = public.app_current_location() '
        'and c.vendor_id = @vendor_id '
        'and w.resource = @resource '
        'limit 1',
        parameters: <String, Object?>{
          'vendor_id': kSevenShiftsVendorId,
          'resource': sevenShiftsWatermarkResource,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final cursor = row['cursor_token'];
      final lastModified = row['last_modified_seen'];
      if (lastModified is! DateTime) return null;
      return SevenShiftsWatermarkRow(
        cursorToken: cursor is String ? cursor : '',
        lastModifiedSeen: lastModified.toUtc(),
      );
    });
  }

  @override
  Future<void> writeWatermark({
    required String operatorId,
    required String locationId,
    required SevenShiftsWatermarkRow row,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      final connectionId = await _readConnectionId(exec);
      if (connectionId == null) {
        // No connection on file — the dispatcher should never reach
        // this seam without one, but defensively no-op rather than
        // writing an orphan watermark.
        return;
      }
      await _advanceWatermarkInTx(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        cursorToken: row.cursorToken,
        lastModifiedSeen: row.lastModifiedSeen,
      );
    });
  }

  // ─── SevenShiftsGateway: typed labor punch upsert ─────────────────

  @override
  Future<bool> writeTimePunchFact(
    SevenShiftsCanonicalTimePunchFact fact,
  ) {
    // Compute hours_worked from clock_in/clock_out so the labor_punches
    // row stays comparable to the QBT contract. Open punches (no
    // shift_end) collapse to 0 — Lane `.2`'s aggregator filters
    // open-punch rows by shift_end IS NULL before computing dollars.
    final shiftEnd = fact.shiftEnd;
    final hoursWorkedSeconds = shiftEnd == null
        ? 0
        : shiftEnd.difference(fact.shiftStart).inSeconds;
    return _insertLaborPunch(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
      vendorEntityId: fact.vendorEntityId,
      vendorModifiedAt: fact.vendorModifiedAt,
      shiftStart: fact.shiftStart,
      shiftEnd: shiftEnd,
      employeeSourceId: fact.employeeId,
      roleName: fact.roleName,
      hoursWorked: hoursWorkedSeconds,
      // V1 wage class is `perEmployeeWithRates`. The typed canonical
      // fact does not carry a pay_rate field at V1 — Lane `.7S.upgrade`
      // adds the rate-aware materialization. Pass null so labor_dollars
      // remains NULL and Lane `.2`'s aggregator substitutes target wage.
      payRate: null,
      rawPayload: fact.rawPayload,
    );
  }

  // ─── SevenShiftsGateway: payroll period closed fact ───────────────

  /// Persist the latest closed payroll period as a structured
  /// `connector_sync_log` row. V1 has no dedicated `payroll_periods`
  /// table — the closed instant lives in
  /// `payload_preview.payroll_period_closed_at` so the Phase 7.58
  /// Primary Driver audit can read it back without a new migration.
  /// Idempotent: writing the same closed instant twice in a row is
  /// suppressed via the in-tx duplicate check.
  @override
  Future<bool> writePayrollPeriodClosedFact(
    SevenShiftsCanonicalPayrollPeriodClosedFact fact,
  ) {
    final ctx = TenantContext(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      final connectionId = await _readConnectionId(exec);
      if (connectionId == null) return false;
      final existing = await exec.query(
        'select payload_preview->>\'payroll_period_closed_at\' as closed_at '
        'from public.connector_sync_log '
        'where operator_id = public.app_current_operator() '
        'and location_id = public.app_current_location() '
        'and connection_id = @connection_id::uuid '
        'and event_kind = @event_kind '
        'order by occurred_at desc limit 1',
        parameters: <String, Object?>{
          'connection_id': connectionId,
          'event_kind': kSevenShiftsPayrollPeriodClosedSyncLogKind,
        },
      );
      if (existing.isNotEmpty) {
        final last = existing.single['closed_at'];
        if (last is String &&
            last == fact.payrollPeriodClosedAt.toIso8601String()) {
          return false;
        }
      }
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'payload_preview, occurred_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@event_kind, @payload_preview::jsonb, @occurred_at::timestamptz'
        ')',
        parameters: <String, Object?>{
          'operator_id': fact.operatorId,
          'location_id': fact.locationId,
          'connection_id': connectionId,
          'event_kind': kSevenShiftsPayrollPeriodClosedSyncLogKind,
          'payload_preview': jsonEncode(<String, Object?>{
            'payroll_period_closed_at':
                fact.payrollPeriodClosedAt.toIso8601String(),
            'raw_payload': fact.rawPayload,
          }),
          'occurred_at': _now().toUtc(),
        },
      );
      return true;
    });
  }

  // ─── SevenShiftsGateway: credential surface ───────────────────────

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
      await exec.execute(
        'delete from public.vendor_credentials '
        'where operator_id = public.app_current_operator() '
        'and (location_id = public.app_current_location() '
        '     or location_id is null) '
        'and vendor_id = @vendor_id',
        parameters: <String, Object?>{
          'vendor_id': kSevenShiftsVendorId,
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
        '     or location_id is null) '
        'and vendor_id = @vendor_id '
        'and is_active = true '
        'limit 1',
        parameters: <String, Object?>{
          'vendor_id': kSevenShiftsVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final ciphertext = rows.single['access_token_ciphertext'];
      // Production decryption (pgcrypto envelope -> plaintext) is a
      // separate hardening lane. V1 returns whatever the column
      // contains so the test harness can inject a stub access token
      // directly via the fake pool.
      if (ciphertext is String) return ciphertext;
      if (ciphertext is List<int>) {
        return String.fromCharCodes(ciphertext);
      }
      return null;
    });
  }

  @override
  Future<String?> readCompanyId({
    required String operatorId,
    required String locationId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<String?>(ctx, (exec) async {
      final rows = await exec.query(
        "select metadata->>'company_id' as company_id "
        'from public.connector_connection '
        'where operator_id = public.app_current_operator() '
        'and location_id = public.app_current_location() '
        'and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'vendor_id': kSevenShiftsVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final value = rows.single['company_id'];
      if (value is String && value.isNotEmpty) return value;
      return null;
    });
  }

  @override
  Future<void> recordHoursAndWagesReportGated({
    required String operatorId,
    required String locationId,
    required int statusCode,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      final connectionId = await _readConnectionId(exec);
      if (connectionId == null) return;
      await exec.execute(
        'insert into public.connector_sync_log ('
        'operator_id, location_id, connection_id, event_kind, '
        'payload_preview, occurred_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@event_kind, @payload_preview::jsonb, @occurred_at::timestamptz'
        ')',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'event_kind': kSevenShiftsHoursAndWagesReportGatedSyncLogKind,
          'payload_preview': jsonEncode(<String, Object?>{
            'status_code': statusCode,
          }),
          'occurred_at': _now().toUtc(),
        },
      );
    });
  }

  // ─── CanonicalSink: watermark advance ─────────────────────────────

  /// Persist `cursor_token` + `last_modified_seen` for the connection
  /// AFTER each batch commit. Cloud Run Job restart resilience: the
  /// next tick resumes from the persisted cursor even when the worker
  /// dies mid-window.
  ///
  /// Resource is pinned to [sevenShiftsWatermarkResource] so the
  /// watermark row is unique per `(connection_id, resource)` and any
  /// future 7shifts resource (if added) gets its own row.
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
      await _advanceWatermarkInTx(
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
          'payload_preview':
              payloadPreview == null ? null : jsonEncode(payloadPreview),
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

  // ─── Shared private writer (labor_punches insert) ─────────────────

  Future<bool> _insertLaborPunch({
    required String operatorId,
    required String locationId,
    required String vendorEntityId,
    required DateTime vendorModifiedAt,
    required DateTime shiftStart,
    required DateTime? shiftEnd,
    required String employeeSourceId,
    required String roleName,
    required num hoursWorked,
    required num? payRate,
    required Map<String, Object?> rawPayload,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      final businessDate = await _resolveBusinessDate(exec, shiftStart);
      // V1 wage class for 7shifts is `perEmployeeWithRates` — INSERT
      // omits `labor_dollars` so the column stays NULL and Lane `.2`'s
      // aggregator computes dollars via rate × duration.
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
          'vendor_id': kSevenShiftsVendorId,
          'vendor_entity_id': vendorEntityId,
          'vendor_modified_at': vendorModifiedAt,
          'raw_payload': jsonEncode(rawPayload),
          'business_date': _formatDate(businessDate),
        },
      );
      return affected > 0;
    });
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  Future<void> _advanceWatermarkInTx({
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
        'resource': sevenShiftsWatermarkResource,
        'last_synced_at': _now().toUtc(),
        'last_modified_seen': lastModifiedSeen.toUtc(),
        'cursor_token': cursorToken,
      },
    );
  }

  Future<String?> _readConnectionId(PostgresExecutor exec) async {
    final rows = await exec.query(
      'select connection_id from public.connector_connection '
      'where operator_id = public.app_current_operator() '
      'and location_id = public.app_current_location() '
      'and vendor_id = @vendor_id '
      'limit 1',
      parameters: <String, Object?>{
        'vendor_id': kSevenShiftsVendorId,
      },
    );
    if (rows.isEmpty) return null;
    final value = rows.single['connection_id'];
    if (value is String) return value;
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
        'SevenShiftsPostgresSink could not resolve location timezone — '
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

  static String _requireEmployeeId(Map<String, Object?> map) {
    // Accept either `employee_source_id` (canonical sink contract) or
    // `employee_id` (the 7shifts adapter's typed canonical fact dict
    // shape) so the dispatcher and the bespoke adapter path can share
    // the same sink without a key-rename layer.
    final source = map['employee_source_id'];
    if (source is String && source.isNotEmpty) return source;
    if (source is num) return source.toString();
    final employee = map['employee_id'];
    if (employee is String && employee.isNotEmpty) return employee;
    if (employee is num) return employee.toString();
    throw ArgumentError.value(
      source,
      'employee_source_id',
      'canonicalPunch.employee_source_id (or employee_id) must be a '
          'non-empty String',
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
    throw ArgumentError.value(
      value,
      key,
      'canonicalPunch.$key must be a num',
    );
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
