// Worker-layer audit emission for the demo→live flip event.
//
// PR #457 surfaced the CONTRACT GAP that the demo-flip audit row must
// be emitted exactly once even when the dispatcher's evaluateDemoFlip
// is called multiple times for the same (operator, location, category)
// triple. The flip itself is idempotent at the
// `demo_mode_state` row level (the production INSERT … ON CONFLICT
// DO UPDATE preserves the original `flipped_to_live_at` /
// `flipped_by_connection_id`), but the audit row must mirror that
// once-only semantic at the audit_logs layer.
//
// Architecture: this file decorates a [CanonicalSink]. Before
// delegating to `evaluateDemoFlip`, the wrapper reads the current
// `demo_mode_state.is_demo` value for the (operator, location,
// category) row. After the delegate call returns, it reads the value
// again. When the transition was demo→live (prior=true, post=false)
// the wrapper emits one `backfill_job.demo_flipped` audit row. Repeat
// invocations on an already-live row see prior=false → no emission,
// preserving the once-only contract.
//
// The `is_demo` reads run inside their own tenant-scoped transactions
// (the audit_logs writer's GUC probe requires this); they happen
// BEFORE and AFTER the delegate's evaluateDemoFlip transaction so the
// observed transition is the same one the production policy applied.

import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/services/integration/canonical_sink.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/observability/log.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';

import 'audit_emitting_backfill_job_store.dart'
    show
        BackfillAuditAction,
        kBackfillWorkerServicePrincipalId;

/// `CanonicalSink` decorator that emits a `backfill_job.demo_flipped`
/// audit row when (and only when) `evaluateDemoFlip` toggles the
/// `(operator, location, category)` row from demo to live. All other
/// sink methods (`upsert*Fact`, `advanceWatermark`, `appendSyncLog`)
/// pass through unchanged.
///
/// The decorator reads `demo_mode_state.is_demo` immediately before
/// and after the delegate call. The audit row carries `prior_state` and
/// `post_state` strings (`'demo'` / `'live'`), the connection that
/// drove the flip, and the row's job id when one is known (the worker
/// dispatch threads the in-flight `FirstConnectionBackfillJob.jobId`
/// through `decorateForJob` before calling evaluateDemoFlip; non-job
/// callsites simply omit the job id from the payload).
class AuditEmittingCanonicalSink implements CanonicalSink {
  AuditEmittingCanonicalSink({
    required this.delegate,
    required this.tenantWrapper,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    DateTime Function()? clock,
    String servicePrincipalId = kBackfillWorkerServicePrincipalId,
  }) : _audit = auditLogsRepository,
       _clock = clock ?? _defaultUtcClock,
       _servicePrincipalId = servicePrincipalId;

  final CanonicalSink delegate;
  final TenantTransactionWrapper tenantWrapper;
  final AuditLogsRepository _audit;
  final DateTime Function() _clock;
  final String _servicePrincipalId;

  /// In-flight job the dispatcher is currently driving, if any. The
  /// worker calls [withInFlightJob] when entering a per-job path so the
  /// demo-flip audit row's payload carries the job id and vendor id
  /// that triggered the flip; outside that scope the value is null
  /// and the payload omits those fields.
  FirstConnectionBackfillJob? _inFlightJob;

  static DateTime _defaultUtcClock() => DateTime.now().toUtc();

  /// Bind the [job]'s id as the in-flight job for the duration of
  /// [body]. The dispatcher wraps each per-job critical section in
  /// this so the audit row's payload identifies which backfill caused
  /// the flip. The binding is restored on exit even if [body] throws.
  Future<R> withInFlightJob<R>(
    FirstConnectionBackfillJob job,
    Future<R> Function() body,
  ) async {
    final prior = _inFlightJob;
    _inFlightJob = job;
    try {
      return await body();
    } finally {
      _inFlightJob = prior;
    }
  }

  @override
  Future<bool> upsertCoverFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalFact,
  }) {
    return delegate.upsertCoverFact(
      operatorId: operatorId,
      locationId: locationId,
      canonicalFact: canonicalFact,
    );
  }

  @override
  Future<bool> upsertLaborPunch({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalPunch,
  }) {
    return delegate.upsertLaborPunch(
      operatorId: operatorId,
      locationId: locationId,
      canonicalPunch: canonicalPunch,
    );
  }

  @override
  Future<bool> upsertReservationFact({
    required String operatorId,
    required String locationId,
    required Map<String, Object?> canonicalReservation,
  }) {
    return delegate.upsertReservationFact(
      operatorId: operatorId,
      locationId: locationId,
      canonicalReservation: canonicalReservation,
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
    return delegate.advanceWatermark(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      cursorToken: cursorToken,
      lastModifiedSeen: lastModifiedSeen,
    );
  }

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
    return delegate.appendSyncLog(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      eventKind: eventKind,
      errorMessage: errorMessage,
      recordsCount: recordsCount,
      payloadPreview: payloadPreview,
    );
  }

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
    final priorIsDemo = await _readIsDemo(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
    );
    await delegate.evaluateDemoFlip(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
      connectionStatus: connectionStatus,
      firstBackfillCommitted: firstBackfillCommitted,
      backfillRecordsWritten: backfillRecordsWritten,
      connectionId: connectionId,
    );
    final postIsDemo = await _readIsDemo(
      operatorId: operatorId,
      locationId: locationId,
      category: category,
    );
    // Emit only on the once-only demo→live transition. A repeat call
    // after the row is already live observes prior=false and skips the
    // emission, preserving the "exactly once" contract from PR #457.
    if (priorIsDemo == true && postIsDemo == false) {
      await _emitDemoFlipped(
        operatorId: operatorId,
        locationId: locationId,
        connectionId: connectionId,
        category: category,
      );
    }
  }

  Future<bool?> _readIsDemo({
    required String operatorId,
    required String locationId,
    required IntegrationCategory category,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    try {
      return await tenantWrapper.runInTenantContext<bool?>(ctx, (exec) async {
        final rows = await exec.query(
          'select is_demo from public.demo_mode_state '
          'where operator_id = @operator_id::uuid '
          'and location_id = @location_id::uuid '
          'and category = @category '
          'limit 1',
          parameters: <String, Object?>{
            'operator_id': operatorId,
            'location_id': locationId,
            'category': category.backfillWire,
          },
        );
        if (rows.isEmpty) return null;
        final raw = rows.single['is_demo'];
        if (raw is bool) return raw;
        return null;
      });
    } catch (error, stackTrace) {
      // Best-effort observation — if the read fails we still let the
      // delegate evaluateDemoFlip run; the audit emission is just
      // skipped because we cannot prove the transition fired.
      log(
        LogSeverity.warning,
        'backfill_audit_emission.read_is_demo_failed',
        fields: <String, Object?>{
          'operator_id': operatorId,
          'category': category.backfillWire,
          'error': error.toString(),
          'stack_first_frame': firstStackFrame(stackTrace),
        },
      );
      return null;
    }
  }

  Future<void> _emitDemoFlipped({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required IntegrationCategory category,
  }) async {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    final job = _inFlightJob;
    try {
      await tenantWrapper.runInTenantContext<void>(ctx, (exec) async {
        await _audit.writeRow(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          occurredAt: _clock(),
          actorKind: 'service',
          actorPrincipalId: _servicePrincipalId,
          targetKind: 'connector_backfill_job',
          targetId: job?.jobId ?? connectionId,
          action: BackfillAuditAction.demoFlipped,
          payload: <String, Object?>{
            if (job != null) 'job_id': job.jobId,
            if (job != null) 'vendor_id': job.vendorId,
            'connection_id': connectionId,
            'category': category.backfillWire,
            'prior_state': 'demo',
            'post_state': 'live',
          },
        );
      });
    } catch (error, stackTrace) {
      log(
        LogSeverity.warning,
        'backfill_audit_emission.demo_flip_emit_failed',
        fields: <String, Object?>{
          'operator_id': operatorId,
          'connection_id': connectionId,
          'error': error.toString(),
          'stack_first_frame': firstStackFrame(stackTrace),
        },
      );
    }
  }
}
