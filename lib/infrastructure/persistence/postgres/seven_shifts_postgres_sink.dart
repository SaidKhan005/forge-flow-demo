// Phase 8 Wave B `8.spine-bridge-sink-fanout.7S` — 7shifts Postgres
// canonical sink.
//
// Authority (read in this order):
//
//   1. `docs/contracts/core_app_architecture.md` (Layers 1-12 binding,
//      Layer 2 source-truth fact tables).
//   2. `docs/contracts/integration_spine_architecture_contract.md`
//      sections "The canonical chain (binding)" and the labor sub-lane
//      shape (mirrors `.1.QBT` for the rate-bearing column write path,
//      mirrors `.AG` / `.PU` for the optional dual-interface widening).
//   3. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//      — every fact-row write runs inside
//      `OperatorScopedRepository.withTenant`; RLS is the backup defense.
//   4. `docs/contracts/vendor_adapter_slice_contract.md` — idempotency
//      UNIQUE on `(vendor_id, operator_id, vendor_entity_id,
//      vendor_modified_at)`.
//   5. `lib/services/integration/canonical_sink.dart` — the unified
//      interface this sink implements alongside the bespoke
//      [SevenShiftsGateway] adapter-side interface.
//   6. `lib/integrations/labor/seven_shifts_labor_adapter.dart` — the
//      Wave B adapter that produces the canonical-fact dicts this sink
//      consumes; defines the bespoke [SevenShiftsGateway] interface
//      this file implements alongside [CanonicalSink].
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//
//   * HP #1 (pure transport swap): writes flow into the existing
//     `labor_punches` canonical fact table; no formula change, no
//     read-service contract drift.
//   * HP #2 (demo mode persists post-launch): both [evaluateDemoFlip]
//     and the alias-shape [markLaborLive] centralise the
//     (operator, location, category=labor) flip rule using
//     `INSERT ... ON CONFLICT DO UPDATE WHERE is_demo`, so the same
//     code path runs whether the operator is in demo or live; the
//     idempotent flip policy preserves the original triggering
//     `flipped_to_live_at` and `flipped_by_connection_id`.
//   * HP #4 (per-operator isolation): every method takes
//     `(operatorId, locationId)` and runs through `withTenant` so the
//     repository pattern is the primary tenant defense and Postgres
//     RLS is the backup.
//   * HP #7 (server-side secrets): credential ciphertexts are touched
//     only on disconnect via [wipeCredentials]; the adapter's own
//     credential gateway owns refresh-token rotation.
//
// Dual-interface widening: this sink implements both
// [SevenShiftsGateway] (consumed by the labor adapter at
// `lib/integrations/labor/seven_shifts_labor_adapter.dart`) AND the
// unified [CanonicalSink] (consumed by the spine-bridge sync worker).
// The two surfaces collide on `advanceWatermark` / `appendSyncLog`
// with different parameter sets — the bespoke gateway omits these
// two methods entirely (the adapter does not call them), but the
// unified interface requires them. The bespoke gateway DOES require
// per-fact `writeTimePunchFact` / `writePayrollPeriodClosedFact`
// / `recordHoursAndWagesReportGated`. The class widens the collision
// where it overlaps (covers / reservations are unsupported on a
// labor sink and throw [UnsupportedError] from the [CanonicalSink]
// surface; `upsertLaborPunch` delegates to the same private writer
// `writeTimePunchFact` uses).
//
// Wage-source posture: 7shifts is `LaborWageSourceClass.perEmployeeWithDollars`
// post-`8.spine-bridge.7S.upgrade` — the adapter additively merges the
// `/reports/hours_and_wages` report onto each canonical fact, so the
// canonical-fact dict carries `actual_labor_dollars`, `regular_pay`,
// `overtime_pay`, `wage_provenance`, and `shift_id` when the report
// covers the (employee_id, shift_id) tuple.
//
// The Phase 8 `labor_punches` schema (per
// `db/migrations/202605040000_phase_8_0_integration_framework.sql`
// + the existing AG / QBT / ADP / PU sinks confirming column shape)
// exposes `pay_rate` but does NOT (V1 lean cut 2) expose dedicated
// wage-dollar columns (`actual_labor_dollars`, `regular_pay`,
// `overtime_pay`). Per the slice prompt and the `8.spine-bridge.7S.upgrade`
// commit's wage-class posture: this sink derives `pay_rate` from
// `actualLaborDollars / hoursWorked` when both are present (else NULL)
// and stashes the full wage payload (`actual_labor_dollars`,
// `regular_pay`, `overtime_pay`, `wage_provenance`, `shift_id`)
// inside `raw_payload` JSONB so Lane `.2`'s aggregator can re-derive
// without a schema migration. Test H banned-grep enforces zero zombie
// wage-dollar column tokens in the INSERT column list — only the
// `raw_payload` `jsonEncode` payload may carry them.
//
// Hours-worked projection: `time_punch.clocked_in` + `time_punch.clocked_out`
// project to `shift_start` + `shift_end` on the canonical fact. The
// sink computes `hours_worked` (in seconds, matching the QBT / AG
// `duration` shape) as `(shift_end - shift_start).inSeconds` when
// both endpoints are present; an open punch (employee clocked in but
// not out yet — 7shifts surfaces this as `clocked_out = null`) binds
// NULL so the aggregator can detect the in-progress state.
//
// Payroll-period-closed write target: the V1 lean cut 2 schema does
// not yet ship a dedicated `payroll_period_closed` fact table.
// [writePayrollPeriodClosedFact] therefore writes a
// `connector_sync_log` row with
// `event_kind = 'payroll_period_closed'` and `payload_preview`
// carrying the `payroll_period_closed_at` instant; idempotency is
// enforced in-process by stamping the closed-at value onto a
// `vendor_credentials.payroll_period_last_seen_at`-style anchor read
// + compared per call. Phase 7.58 Primary Driver audit consumes the
// `connector_sync_log` rows directly; when a dedicated fact table
// lands, the writer can re-target without affecting the adapter
// surface.
//
// Banned items (V1 lean cut 2): the per-file banned grep in this
// slice's test pins the same ledger that
// `lib/integrations/labor/seven_shifts_labor_adapter_test.dart`
// already pins against the adapter source, so the lean cut stays
// enforced lane-by-lane. Plus a wage-dollar zombie-token guard
// pinning that the INSERT column list does NOT carry
// `actual_labor_dollars`, `regular_pay`, or `overtime_pay` outside
// the `jsonEncode(rawPayload)` call.

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
/// vendor-side join. Mirrors `agendrixWatermarkResource` /
/// `kQuickBooksTimeWatermarkResource` /
/// `pushOperationsWatermarkResource`.
const String kSevenShiftsWatermarkResource = 'labor_punches';

/// `connector_sync_log.event_kind` value [recordHoursAndWagesReportGated]
/// writes when the `/reports/hours_and_wages` endpoint returns 403/404
/// (lower 7shifts plan tier). The Lane `.B` Data Accuracy tab reads
/// rows with this kind to surface the degradation note
/// ("Wage data unavailable on your current 7shifts plan tier").
const String kSevenShiftsHoursAndWagesReportGatedSyncLogKind =
    'hours_and_wages_report_gated';

/// `connector_sync_log.event_kind` value
/// [writePayrollPeriodClosedFact] writes per closed payroll period.
/// V1 lean cut 2 does not ship a dedicated payroll-period-closed fact
/// table; the audit reads `connector_sync_log` rows of this kind. See
/// the file header for the migration-direction note.
const String kSevenShiftsPayrollPeriodClosedSyncLogKind =
    'payroll_period_closed';

/// Postgres-backed canonical sink for 7shifts.
///
/// Implements both the bespoke [SevenShiftsGateway] (consumed by the
/// labor adapter) AND the unified [CanonicalSink] (consumed by the
/// spine-bridge sync worker). Mirrors the `8.spine-bridge.1.QBT`
/// QuickBooks Time sink shape for the rate-bearing column write path
/// and the `.AG` / `.PU` shape for the dual-interface widening.
///
/// Cover and reservation writes are explicit non-goals on this sink:
/// labor adapters never produce them. [upsertCoverFact] and
/// [upsertReservationFact] both throw [UnsupportedError] — the
/// `tool/integration_sync_worker` dispatcher routes by category, so
/// these throws are defense-in-depth assertions against future
/// router refactors that could miswire a labor connection's tick to
/// a covers / reservation seam.
class SevenShiftsPostgresSink extends OperatorScopedRepository
    implements SevenShiftsGateway, CanonicalSink {
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

  // ─── CanonicalSink: labor punch upsert (delegated) ────────────────

  /// `CanonicalSink.upsertLaborPunch` entry — the dispatcher passes the
  /// canonical-fact dict shape; this method delegates to the shared
  /// private writer that [writeTimePunchFact] also calls.
  ///
  /// Required keys on [canonicalPunch]:
  ///
  ///   * `vendor_entity_id` — string; 7shifts `time_punch.id` stringified.
  ///   * `vendor_modified_at` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `shift_start` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `employee_id` — string; 7shifts `time_punch.user_id`.
  ///     Maps to `labor_punches.employee_source_id`.
  ///   * `role_name` — string.
  ///
  /// Optional keys (Hours & Wages report enrichment per
  /// `8.spine-bridge.7S.upgrade`):
  ///
  ///   * `shift_end` — `DateTime` (UTC) or ISO-8601 string; null /
  ///     absent when the punch is open (employee clocked in but not
  ///     out yet).
  ///   * `shift_id` — string; 7shifts `time_punch.shift_id` stringified.
  ///   * `actual_labor_dollars` / `regular_pay` / `overtime_pay` —
  ///     num USD; `pay_rate` is derived as
  ///     `actual_labor_dollars / (hours_worked / 3600)` when both
  ///     are present, NULL otherwise.
  ///   * `wage_provenance` — string from the adapter's
  ///     `kSevenShiftsProvenance*` constants.
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
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      return _upsertLaborPunchFromDict(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        canonicalPunch: canonicalPunch,
      );
    });
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
      final returning = await exec.query(
        'insert into public.connector_connection ('
        'operator_id, location_id, vendor_id, category, status, '
        'metadata, webhook_url_provisioned'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @vendor_id, '
        "'labor', @status, @metadata::jsonb, @webhook_provisioned"
        ') on conflict (operator_id, location_id, vendor_id, '
        "coalesce(module, '')) do update set "
        'status = excluded.status, '
        'metadata = excluded.metadata, '
        'webhook_url_provisioned = excluded.webhook_url_provisioned, '
        'updated_at = now() '
        'returning connection_id',
        parameters: <String, Object?>{
          'operator_id': row.operatorId,
          'location_id': row.locationId,
          'vendor_id': kSevenShiftsVendorId,
          'status': row.status.name,
          'metadata': jsonEncode(row.toMetadata()),
          'webhook_provisioned': row.webhookId != null,
        },
      );
      final connectionId = returning.isEmpty
          ? row.connectionId
          : (returning.single['connection_id']?.toString() ?? row.connectionId);
      return SevenShiftsConnectionRow(
        connectionId: connectionId,
        operatorId: row.operatorId,
        locationId: row.locationId,
        companyId: row.companyId,
        planTier: row.planTier,
        webhookId: row.webhookId,
        status: row.status,
      );
    });
  }

  // ─── SevenShiftsGateway: watermark read / write ───────────────────

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
        'select cursor_token, last_modified_seen '
        'from public.connector_sync_watermark '
        'where operator_id = public.app_current_operator() '
        'and location_id = public.app_current_location() '
        'and resource = @resource '
        'order by updated_at desc '
        'limit 1',
        parameters: <String, Object?>{
          'resource': kSevenShiftsWatermarkResource,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final cursor = row['cursor_token'];
      final modified = row['last_modified_seen'];
      if (cursor is! String || modified is! DateTime) return null;
      return SevenShiftsWatermarkRow(
        cursorToken: cursor,
        lastModifiedSeen: modified.toUtc(),
      );
    });
  }

  /// Bespoke [SevenShiftsGateway.writeWatermark] entry — the adapter
  /// does not carry a connection id; the sink resolves one from
  /// `connector_connection` for the (operator, location,
  /// vendor=seven_shifts) triple, then delegates to the shared
  /// internal writer.
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
      final connectionId = await _resolveConnectionId(
        explicit: null,
        exec: exec,
      );
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

  // ─── CanonicalSink: watermark advance (widened) ───────────────────

  /// Persist `cursor_token` + `last_modified_seen` for the connection
  /// AFTER each batch commit. Cloud Run Job restart resilience: the
  /// next tick resumes from the persisted cursor even when the worker
  /// dies mid-window.
  ///
  /// Resource is pinned to [kSevenShiftsWatermarkResource] so the
  /// watermark row is unique per `(connection_id, resource)`.
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
      final resolvedConnectionId = await _resolveConnectionId(
        explicit: connectionId,
        exec: exec,
      );
      await _writeWatermarkInternal(
        exec: exec,
        operatorId: operatorId,
        locationId: locationId,
        connectionId: resolvedConnectionId,
        cursorToken: cursorToken,
        lastModifiedSeen: lastModifiedSeen,
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
      'updated_at = now()',
      parameters: <String, Object?>{
        'operator_id': operatorId,
        'location_id': locationId,
        'connection_id': connectionId,
        'resource': kSevenShiftsWatermarkResource,
        'last_synced_at': _now().toUtc(),
        'last_modified_seen': lastModifiedSeen.toUtc(),
        'cursor_token': cursorToken,
      },
    );
  }

  // ─── SevenShiftsGateway: time-punch fact write ────────────────────

  /// Bespoke [SevenShiftsGateway.writeTimePunchFact] entry — translates
  /// the typed canonical fact into the dict shape and delegates to the
  /// shared private writer.
  @override
  Future<bool> writeTimePunchFact(SevenShiftsCanonicalTimePunchFact fact) {
    final ctx = TenantContext(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      return _upsertLaborPunchFromDict(
        exec: exec,
        operatorId: fact.operatorId,
        locationId: fact.locationId,
        canonicalPunch: fact.toCanonicalDict(),
      );
    });
  }

  // ─── SevenShiftsGateway: payroll-period-closed write ──────────────

  /// Append a `connector_sync_log` row recording the latest closed
  /// payroll period. V1 lean cut 2 has no dedicated fact table; the
  /// Phase 7.58 Primary Driver audit consumes these rows directly.
  /// Idempotency: the writer queries the latest existing row for this
  /// (operator, location, kind) and skips when the closed-at instant
  /// matches the new value, so replays on the same closed instant
  /// land as no-ops returning `false`.
  @override
  Future<bool> writePayrollPeriodClosedFact(
    SevenShiftsCanonicalPayrollPeriodClosedFact fact,
  ) {
    final ctx = TenantContext(
      operatorId: fact.operatorId,
      locationId: fact.locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      final connectionId = await _resolveConnectionId(
        explicit: null,
        exec: exec,
      );
      // Idempotency check: skip when the most recent closed-at value
      // already on file matches the inbound value. Same closed-at on
      // a replay path is a no-op.
      final existing = await exec.query(
        'select payload_preview '
        'from public.connector_sync_log '
        'where operator_id = public.app_current_operator() '
        'and location_id = public.app_current_location() '
        'and connection_id = @connection_id::uuid '
        'and event_kind = @event_kind '
        'order by occurred_at desc '
        'limit 1',
        parameters: <String, Object?>{
          'connection_id': connectionId,
          'event_kind': kSevenShiftsPayrollPeriodClosedSyncLogKind,
        },
      );
      final inboundIso = fact.payrollPeriodClosedAt.toUtc().toIso8601String();
      if (existing.isNotEmpty) {
        final preview = existing.single['payload_preview'];
        if (preview is Map) {
          final stored = preview['payroll_period_closed_at'];
          if (stored is String && stored == inboundIso) {
            return false;
          }
        } else if (preview is String) {
          // Some drivers surface jsonb as String — defensive parse.
          try {
            final decoded = jsonDecode(preview);
            if (decoded is Map &&
                decoded['payroll_period_closed_at'] == inboundIso) {
              return false;
            }
          } catch (_) {
            // Fall through to write.
          }
        }
      }

      final payloadPreview = <String, Object?>{
        'payroll_period_closed_at': inboundIso,
        'source': fact.rawPayload['source'],
      };
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
          'operator_id': fact.operatorId,
          'location_id': fact.locationId,
          'connection_id': connectionId,
          'event_kind': kSevenShiftsPayrollPeriodClosedSyncLogKind,
          'records_count': 1,
          'error_message': null,
          'payload_preview': jsonEncode(payloadPreview),
          'occurred_at': _now().toUtc(),
        },
      );
      return true;
    });
  }

  // ─── SevenShiftsGateway: hours-and-wages-gated log path ───────────

  /// Append one `connector_sync_log` row signalling the
  /// `/reports/hours_and_wages` endpoint returned 403/404 for this
  /// connection. The Lane `.B` Data Accuracy tab reads these rows.
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
      final connectionId = await _resolveConnectionId(
        explicit: null,
        exec: exec,
      );
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
          'event_kind': kSevenShiftsHoursAndWagesReportGatedSyncLogKind,
          'records_count': null,
          'error_message': null,
          'payload_preview': jsonEncode(<String, Object?>{
            'status_code': statusCode,
          }),
          'occurred_at': _now().toUtc(),
        },
      );
    });
  }

  // ─── CanonicalSink: sync log append (widened) ─────────────────────

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
      final resolvedConnectionId = await _resolveConnectionId(
        explicit: connectionId,
        exec: exec,
      );
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

  // ─── CanonicalSink: demo-mode flip ────────────────────────────────

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
    return _writeDemoLiveFlip(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
      connectionId: connectionId,
    );
  }

  /// Idempotent demo-flip alias for `category = labor`. Mirrors
  /// `evaluateDemoFlip` shape exactly but bypasses the gate-check
  /// preamble — callers (admin tooling, e.g. the admin "force live"
  /// path in `lib/admin/...`) invoke this when the flip gates are
  /// already known to have passed elsewhere. The underlying SQL is
  /// the same `INSERT ... ON CONFLICT DO UPDATE WHERE is_demo`
  /// shape, so a second call preserves the original triggering
  /// `flipped_to_live_at` and `flipped_by_connection_id`.
  Future<void> markLaborLive({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    return _writeDemoLiveFlip(
      operatorId: operatorId,
      locationId: locationId,
      category: IntegrationCategory.labor,
      connectionId: connectionId,
    );
  }

  Future<void> _writeDemoLiveFlip({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
    required String connectionId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<void>(ctx, (exec) async {
      // INSERT a live row when missing, then flip is_demo only when
      // the row is still demo. The WHERE clause on the UPDATE path is
      // what makes this idempotent — once flipped to live, a second
      // evaluate is a no-op (the WHERE filters out the row), so
      // `flipped_to_live_at` and `flipped_by_connection_id` preserve
      // the original triggering values.
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

  // ─── SevenShiftsGateway: credential read + wipe ───────────────────

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
          'vendor_id': kSevenShiftsVendorId,
        },
      );
      if (rows.isEmpty) return null;
      final value = rows.single['access_token_ciphertext'];
      if (value is String) return value;
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
        'select metadata from public.connector_connection '
        'where operator_id = public.app_current_operator() '
        'and location_id = public.app_current_location() '
        'and vendor_id = @vendor_id '
        'limit 1',
        parameters: <String, Object?>{
          'vendor_id': kSevenShiftsVendorId,
        },
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
      final value = parsed['company_id'];
      if (value is String && value.isNotEmpty) return value;
      return null;
    });
  }

  /// Wipe access / refresh ciphertexts on `vendor_credentials` and
  /// flip `connector_connection.status = 'disconnected'`. Watermark
  /// rows on `connector_sync_watermark` are intentionally preserved
  /// so a reconnect resumes from the last canonical write rather than
  /// re-walking the 60-day window.
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
          'vendor_id': kSevenShiftsVendorId,
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
          'vendor_id': kSevenShiftsVendorId,
          'status': 'disconnected',
          'disconnect_reason': 'operator_action',
          'now': _now().toUtc(),
        },
      );
    });
  }

  // ─── Shared private labor-punch writer ────────────────────────────

  /// Shared writer for the `labor_punches` insert. Both the bespoke
  /// [writeTimePunchFact] and the unified [upsertLaborPunch] funnel
  /// through here.
  ///
  /// `pay_rate` is derived as
  /// `actual_labor_dollars / (hours_worked / 3600)` when both values
  /// are present (and `hours_worked > 0`), else NULL. The wage-dollar
  /// fields (`actual_labor_dollars`, `regular_pay`, `overtime_pay`)
  /// and the `wage_provenance` + `shift_id` fields live ONLY inside
  /// the `raw_payload` JSONB blob — the V1 lean cut 2 schema does not
  /// expose dedicated wage-dollar columns on `labor_punches`. The
  /// banned-grep test pins those tokens out of the INSERT column list.
  Future<bool> _upsertLaborPunchFromDict({
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
    final employeeSourceId = _requireString(canonicalPunch, 'employee_id');
    final roleName = _requireString(canonicalPunch, 'role_name');
    final hoursWorked = (shiftEnd != null)
        ? shiftEnd.difference(shiftStart).inSeconds
        : null;

    // Wage-dollar payload is preserved inside raw_payload; pay_rate is
    // derived when actual_labor_dollars is present and hours_worked > 0.
    final actualLaborDollars = _readNumber(canonicalPunch, 'actual_labor_dollars');
    final num? payRate;
    if (actualLaborDollars != null &&
        hoursWorked != null &&
        hoursWorked > 0) {
      payRate = actualLaborDollars * 3600.0 / hoursWorked;
    } else {
      payRate = null;
    }

    final rawPayloadInput = _readPayload(canonicalPunch, 'raw_payload');
    // Stash the wage payload + shift_id + provenance inside the raw
    // payload blob so Lane `.2`'s aggregator can re-derive without a
    // schema migration. The dedicated columns do NOT exist on
    // `labor_punches` at V1 lean cut 2.
    final mergedRawPayload = <String, Object?>{
      ...rawPayloadInput,
      if (canonicalPunch.containsKey('shift_id'))
        'shift_id': canonicalPunch['shift_id'],
      if (canonicalPunch.containsKey('actual_labor_dollars'))
        'actual_labor_dollars': canonicalPunch['actual_labor_dollars'],
      if (canonicalPunch.containsKey('regular_pay'))
        'regular_pay': canonicalPunch['regular_pay'],
      if (canonicalPunch.containsKey('overtime_pay'))
        'overtime_pay': canonicalPunch['overtime_pay'],
      if (canonicalPunch.containsKey('wage_provenance'))
        'wage_provenance': canonicalPunch['wage_provenance'],
      if (canonicalPunch.containsKey('is_approved'))
        'is_approved': canonicalPunch['is_approved'],
    };

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
        'vendor_id': kSevenShiftsVendorId,
        'vendor_entity_id': vendorEntityId,
        'vendor_modified_at': vendorModifiedAt,
        'raw_payload': jsonEncode(mergedRawPayload),
        'business_date': _formatDate(businessDate),
      },
    );
    return affected > 0;
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  /// Resolve the `connector_connection.connection_id` for the
  /// (operator, location, vendor=seven_shifts) triple. The bespoke
  /// gateway callers do not carry the id; the unified-interface
  /// dispatcher does. When [explicit] is non-null and non-empty it
  /// wins; otherwise the sink looks up the row.
  Future<String> _resolveConnectionId({
    required String? explicit,
    required PostgresExecutor exec,
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
        'vendor_id': kSevenShiftsVendorId,
      },
    );
    if (rows.isEmpty) {
      throw StateError(
        'SevenShiftsPostgresSink could not resolve connection_id — '
        'no connector_connection row for (operator, location, '
        'vendor=seven_shifts). Connect must run before sink writes.',
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
