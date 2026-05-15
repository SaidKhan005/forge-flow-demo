// Phase 8 Wave B `8.spine-bridge.1.PU` — Push Operations Postgres
// canonical sink.
//
// Authority (read in this order):
//
//   1. `docs/contracts/core_app_architecture.md` (Layers 1-12 binding).
//   2. `docs/contracts/integration_spine_architecture_contract.md`
//      sections "The canonical chain (binding)" and "Sub-lane shape
//      (binding)" — including the 2026-05-05 falsehood correction #8
//      that pins Push Operations at V1 wage class `hoursOnly` (the
//      vendor's documented `shifts[]` payload exposes start_at and
//      end_at only; hourly wage / dollars are NOT modeled in V1).
//   3. `docs/contracts/hardening_rls_and_repository_pattern_contract.md`
//      — every fact-row write runs inside
//      `OperatorScopedRepository.withTenant`; RLS is the backup defense.
//   4. `lib/services/integration/canonical_sink.dart` — the unified
//      interface this sink implements.
//   5. `lib/integrations/labor/push_operations_labor_adapter.dart` —
//      the Wave B adapter that produces the canonical-fact dicts this
//      sink consumes (and the home of [PushOperationsCanonicalSink],
//      the bespoke interface this sink also implements).
//
// What this lane does:
//
//   1. Implements both the bespoke [PushOperationsCanonicalSink]
//      (consumed by `PushOperationsLaborAdapter`) AND the unified
//      [CanonicalSink] from `8.spine-bridge.0` (consumed by the spine-
//      bridge sync worker dispatcher). The two interfaces collide on
//      `advanceWatermark` / `appendSyncLog`; the class widens the
//      collision by making `connectionId` an optional named parameter,
//      which satisfies both contracts (bespoke callers omit it; unified
//      callers pass it).
//
//   2. Writes canonical-fact dicts (the shape produced by
//      `PushOperationsLaborAdapter._mapShiftToCanonical`) to operator-
//      scoped Postgres `labor_punches` rows via
//      `OperatorScopedRepository.withTenant`. Idempotency UNIQUE on
//      `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`
//      — the partial index added by migration
//      `202605040000_phase_8_0_integration_framework.sql`. Repeat writes
//      of the same key short-circuit to a no-op (returns false). The
//      raw vendor `shifts[]` element is preserved in the `raw_payload`
//      JSONB column for forensic re-derivation.
//
//   3. Computes `business_date` at write time from `shift_start` via
//      the canonical `BusinessTimingProfilesRepository` →
//      `BusinessTimingProfileResolver` → `BusinessDateResolver` chain
//      (Per-Daypart V1 / Slice 7b option (b), 2026-05-15). The chain
//      honors operator → org_unit → location precedence per HP #11 and
//      consumes a sub-hour-aware HH:MM cutoff per Gap 46. The sink
//      reads `location.timezone` only — it no longer reads
//      `location.business_day_rollover_hour` (deprecated in Slice 7b).
//      The denormalized DATE never re-derives at read (Phase 7.55
//      Rule 11).
//
//   4. Persists watermark advances via `connector_sync_watermark`
//      (resource = `'labor_punches'`). Per-batch commit so a Cloud Run
//      Job restart resumes from the last cursor.
//
//   5. Wipes credential ciphertexts and connection metadata on
//      `disconnect` via `wipeCredentialsPreserveWatermark`. The
//      `connector_sync_watermark` rows are left intact so reconnect
//      resumes from the last successful cursor.
//
// V1 hours-only invariant (2026-05-05 falsehood correction #8): Push
// Operations is classified `hoursOnly` for V1. The vendor's documented
// `shifts[]` payload exposes start / end / role / employee only — the
// adapter does not surface a wage rate, and Lane `.2`'s aggregator
// does not compute wage dollars for this vendor in V1. The sink writes
// hours only into `labor_punches`; the wage-rate column and the wage-
// dollars column are intentionally OMITTED from the INSERT column list
// so the Postgres defaults leave them NULL. The Test H banned-grep
// pins those tokens out of this sink's source so a future refactor
// cannot silently introduce a wage write.
//
// V1 lean cut 2 alignment (`memory/project_v1_lean_cut_2_2026_05_03.md`):
// none of the banned items appear in this file. The banned-items grep
// in `test/infrastructure/persistence/postgres/push_operations_postgres_sink_test.dart`
// (Test H) enforces this.

import 'dart:convert';

import '../../../integrations/labor/push_operations_labor_adapter.dart'
    show PushOperationsCanonicalSink, pushOperationsVendorId;
import '../../../services/integration/canonical_sink.dart';
import '../../../services/integration/iana_timezone_converter.dart';
import '../../../services/integration/integration_adapter_common.dart';
import '../../../services/integration/sink_business_date_projector.dart';
import '_postgres_sink_log_helpers.dart';
import 'operator_scoped_repository.dart';
import 'postgres_executor.dart';
import 'repositories/business_timing_profiles_repository.dart';
import 'tenant_context.dart';
import 'tenant_transaction.dart';

/// `connector_sync_watermark.resource` value the Push Operations sink
/// writes under. Matches the canonical fact table the sink drains into
/// so the worker reads back the cursor by resource without a vendor-
/// side join.
const String pushOperationsWatermarkResource = 'labor_punches';

/// Postgres-backed canonical sink for Push Operations scheduling.
///
/// Implements both the bespoke [PushOperationsCanonicalSink] (consumed
/// by the adapter at
/// `lib/integrations/labor/push_operations_labor_adapter.dart`) AND the
/// unified [CanonicalSink] (consumed by the spine-bridge sync worker at
/// `tool/integration_sync_worker/dispatch.dart`). The two interfaces
/// overlap on `advanceWatermark` / `appendSyncLog` with different
/// parameter sets; the class widens those signatures so a single
/// concrete method satisfies both.
///
/// Cover and reservation writes are explicit non-goals on this sink:
/// labor adapters never produce them. [upsertCoverFact] and
/// [upsertReservationFact] both throw [UnsupportedError] — the
/// `tool/integration_sync_worker` dispatcher routes by category, so
/// these throws are defense-in-depth assertions against future router
/// refactors that could miswire a labor connection's tick to a covers /
/// reservation seam.
class PushOperationsPostgresSink extends OperatorScopedRepository
    implements PushOperationsCanonicalSink, CanonicalSink {
  PushOperationsPostgresSink({
    required TenantTransactionWrapper tenantWrapper,
    IanaTimezoneConverter? timezoneConverter,
    SinkBusinessDateProjector? businessDateProjector,
    BusinessTimingProfilesRepository? profilesRepository,
    DateTime Function()? now,
  })  : _businessDateProjector = businessDateProjector ??
            SinkBusinessDateProjector(
              profilesRepository: profilesRepository ??
                  BusinessTimingProfilesRepository(tenantWrapper),
              timezoneConverter:
                  timezoneConverter ?? IanaTimezoneConverter.shared,
            ),
        _now = now ?? DateTime.now,
        super(tenantWrapper);

  // Per-Daypart V1 / Slice 7b option (b) (2026-05-15): Push Operations
  // no longer reads `locations.business_day_rollover_hour`. The cutoff
  // is resolved through the canonical `BusinessTimingProfilesRepository`
  // chain inside the projector.
  final SinkBusinessDateProjector _businessDateProjector;
  final DateTime Function() _now;

  // ─── CanonicalSink: covers / reservations are unsupported ─────────

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) async {
    throw UnsupportedError(
      'PushOperationsPostgresSink is a labor sink; cover writes are not '
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
      'PushOperationsPostgresSink is a labor sink; reservation writes are '
      'not supported. Routing bug — dispatcher must call the reservation '
      'sink for the reservation_facts category.',
    );
  }

  // ─── Bespoke + unified upsert ─────────────────────────────────────

  /// Bespoke [PushOperationsCanonicalSink] entry point. Consumed by
  /// `PushOperationsLaborAdapter` after each `_mapShiftToCanonical`
  /// projection. Delegates to the shared private writer.
  @override
  Future<bool> upsertShift({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) =>
      _upsert(
        operatorId: operatorId,
        locationId: locationId,
        canonicalFact: canonicalFact,
      );

  /// Unified [CanonicalSink] entry point. Consumed by the spine-bridge
  /// sync worker dispatcher when it routes a labor batch. Delegates to
  /// the shared private writer.
  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) =>
      _upsert(
        operatorId: operatorId,
        locationId: locationId,
        canonicalFact: canonicalPunch,
      );

  /// Shared writer behind [upsertShift] and [upsertLaborPunch].
  ///
  /// Required keys on [canonicalFact]:
  ///
  ///   * `vendor_entity_id` — string; Push Operations `shifts[].id`.
  ///   * `vendor_modified_at` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `shift_start` — `DateTime` (UTC) or ISO-8601 string.
  ///   * `employee_id` — string; Push Operations `shifts[].employee_id`
  ///     stringified.
  ///   * `role_name` — string.
  ///
  /// Optional keys:
  ///
  ///   * `shift_end` — `DateTime` (UTC) or ISO-8601 string; null /
  ///     absent when the schedule row has no end (rare for scheduling
  ///     vendors but tolerated for parity with the labor_punches shape).
  ///   * `raw_payload` — vendor-shape Map preserved for forensic
  ///     re-derivation.
  ///
  /// V1 hours-only: the INSERT column list intentionally OMITS the
  /// wage-rate and wage-dollars columns so the Postgres defaults leave
  /// them NULL. Lane `.2`'s aggregator handles wage modelling for
  /// vendors that surface a rate; Push Operations is not one of them
  /// in V1.
  ///
  /// Returns `true` when a new row landed; `false` when the
  /// idempotency UNIQUE on
  /// `(operator_id, vendor_id, vendor_entity_id, vendor_modified_at)`
  /// short-circuited the insert (replay arrived twice).
  Future<bool> _upsert({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) {
    final vendorEntityId = _requireString(canonicalFact, 'vendor_entity_id');
    final vendorModifiedAt =
        _requireUtcInstant(canonicalFact, 'vendor_modified_at');
    final shiftStart = _requireUtcInstant(canonicalFact, 'shift_start');
    final shiftEnd = _readUtcInstant(canonicalFact, 'shift_end');
    final employeeSourceId = _requireString(canonicalFact, 'employee_id');
    final roleName = _requireString(canonicalFact, 'role_name');
    final hoursWorked = _hoursWorkedSeconds(shiftStart, shiftEnd);
    final rawPayload = _readPayload(canonicalFact, 'raw_payload');

    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<bool>(ctx, (exec) async {
      final businessDate =
          await _resolveBusinessDate(exec, operatorId, locationId, shiftStart);
      final affected = await exec.execute(
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
          'vendor_id': pushOperationsVendorId,
          'vendor_entity_id': vendorEntityId,
          'vendor_modified_at': vendorModifiedAt,
          'raw_payload': jsonEncode(rawPayload),
          'business_date': _formatDate(businessDate),
        },
      );
      return affected > 0;
    });
  }

  // ─── Watermark advance ────────────────────────────────────────────

  /// Persist `cursor_token` + `last_modified_seen` for the connection
  /// AFTER each batch commit. Cloud Run Job restart resilience: the
  /// next tick resumes from the persisted cursor even when the worker
  /// dies mid-window.
  ///
  /// The `connectionId` parameter is widened to optional so the same
  /// concrete method satisfies both interfaces:
  ///
  ///   * Bespoke `PushOperationsCanonicalSink.advanceWatermark` (called
  ///     by the adapter) does not carry a connection id; the sink
  ///     looks one up from `connector_connection`.
  ///   * Unified `CanonicalSink.advanceWatermark` (called by the
  ///     spine-bridge dispatcher) passes the id explicitly; the sink
  ///     uses it directly.
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
          'connection_id': resolvedConnectionId,
          'resource': pushOperationsWatermarkResource,
          'last_synced_at': _now().toUtc(),
          'last_modified_seen': lastModifiedSeen.toUtc(),
          'cursor_token': cursorToken,
        },
      );
    });
  }

  // ─── Sync log append ──────────────────────────────────────────────

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
          'payload_preview': encodePayloadPreviewForSyncLog(payloadPreview),
          'occurred_at': _now().toUtc(),
        },
      );
    });
  }

  // ─── Demo-mode flip ───────────────────────────────────────────────

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
      // INSERT default-live row when missing, then flip is_demo only
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

  // ─── Disconnect ───────────────────────────────────────────────────

  /// Wipe credential ciphertexts and connection metadata on disconnect.
  /// `connector_sync_watermark` rows are intentionally preserved so
  /// reconnect resumes from the last successful cursor.
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
          'vendor_id': pushOperationsVendorId,
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
          'vendor_id': pushOperationsVendorId,
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
      // framework disconnect contract uniform across vendors.
      webhookUnregistered: true,
      // Watermark rows are intentionally not deleted; reconnect
      // resumes from the last canonical write. See the file header.
      watermarkPreserved: true,
    );
  }

  // ─── Helpers ──────────────────────────────────────────────────────

  /// Resolve the `connector_connection.connection_id` for the
  /// (operator, location, vendor) triple. Bespoke-interface callers
  /// (the Push adapter) do not carry the id; the unified-interface
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
          'vendor_id': pushOperationsVendorId,
        },
      );
      if (rows.isEmpty) {
        throw StateError(
          'connector_connection row not found for '
          '(operator=$operatorId, location=$locationId, '
          'vendor=$pushOperationsVendorId) — connect must run before '
          'sink writes',
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
        'PushOperationsPostgresSink could not resolve location timezone — '
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

  /// Compute the integer-seconds duration of a scheduled shift. The
  /// sink writes seconds (matching the `labor_punches.hours_worked`
  /// convention shared with the QBT lane). Returns 0 when [end] is
  /// null — Push Operations is a scheduling vendor; an absent end
  /// means the schedule row was malformed and the aggregator will
  /// surface the zero-hour shift to the operator for review rather
  /// than silently treating it as a worked-shift.
  static int _hoursWorkedSeconds(DateTime start, DateTime? end) {
    if (end == null) return 0;
    final delta = end.difference(start).inSeconds;
    return delta < 0 ? 0 : delta;
  }

  static String _requireString(Map<String, Object?> map, String key) {
    final value = map[key];
    if (value is String && value.isNotEmpty) return value;
    if (value is num) return value.toString();
    throw ArgumentError.value(
      value,
      key,
      'canonicalFact.$key must be a non-empty String',
    );
  }

  static DateTime _requireUtcInstant(Map<String, Object?> map, String key) {
    final value = _readUtcInstant(map, key);
    if (value == null) {
      throw ArgumentError.value(
        map[key],
        key,
        'canonicalFact.$key must be a UTC DateTime or ISO-8601 string',
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
