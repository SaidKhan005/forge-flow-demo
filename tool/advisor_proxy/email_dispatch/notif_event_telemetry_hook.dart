// Forge & Flow advisor proxy — notification event telemetry hooks.
//
// SUPERSEDED by Wave 2 EN-3-FU (see
// `tool/advisor_proxy/email_dispatch/postgres_notification_fanout_bindings.dart`).
// The full `NotificationEventFanout` production wire-up landed in
// EN-3-FU, so the proxy / backfill worker / audit_anchor CLI now
// dispatch real push + email rows instead of emitting a
// `notif.event.unwired` warning.
//
// The two builder helpers in this file are kept for one release
// cycle so a fanout-regression failure mode still surfaces a
// structured Cloud Logging line. They are marked `@Deprecated` and
// emit an extra `notif.event.telemetry_fallback` line on every fire
// so log search can surface "fanout did not run; telemetry path
// fired instead" without operator intervention.
//
// Wave 2 EN-3 (debug.md:315-316) — original context: the three
// internal-only events (backfill complete, backfill failed, audit
// anchor failure) had fully wired Markdown templates, registered
// template ids (`EmailTemplateIds.backfillComplete` etc.), and
// per-event hook helpers in `notification_event_hooks.dart`. They
// were NOT yet dispatched in production because the worker `main()`
// paths did not construct a `NotificationEventFanout` (Postgres
// user directory, preference reader, and push outbox seams were
// pending). EN-3 shipped the smallest production-visible mitigation
// per the prompt's "ship the smallest possible mitigation +
// escalation note" guidance: a telemetry-only hook that emits a
// structured `notif.event.unwired` warning on every terminal outcome
// the fanout would have handled. EN-3-FU replaces the gap.
//
// Test coverage in `test/services/email/notif_event_telemetry_hook_test.dart`
// pins the JSON envelope of the deprecated path so any future
// removal is mechanical.

import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/observability/log.dart';

import '../../integration_sync_worker/backfill_dispatch.dart';

/// Structured-log emitter the telemetry hook calls. Production binds
/// this to the proxy's [log] function; tests pass a recording closure.
typedef NotifTelemetryLogSeam =
    void Function(
      LogSeverity severity,
      String event, {
      Map<String, Object?> fields,
    });

/// Default [NotifTelemetryLogSeam] — emits via the proxy's
/// structured [log] function. Production callers can omit the seam
/// in the factory helpers and inherit this binding; tests inject a
/// recording closure.
void _defaultLogSeam(
  LogSeverity severity,
  String event, {
  Map<String, Object?> fields = const <String, Object?>{},
}) {
  log(severity, event, fields: fields);
}

/// Builds a [BackfillTerminalHook] that emits one structured
/// `notif.event.unwired` warning per terminal backfill outcome.
///
/// Wave 2 EN-3-FU: this builder is a fallback for cases where the
/// fanout-backed dispatch path did not bind (degraded boot, test
/// harness that skipped `buildWorkerRuntime`). Every fire also emits
/// a `notif.event.telemetry_fallback` warning so log search can
/// surface "fanout did not run; telemetry path fired instead"
/// without operator intervention. Production callers should now
/// thread the real fanout through the worker runtime; see
/// `tool/first_connect_backfill_worker/main.dart` and the
/// `_buildFanoutBackedBackfillTerminalHook` helper.
///
/// Routes:
///   * [BackfillDispatchOutcome.succeeded] → emits with
///     `event_kind = 'notif.backfill.complete'` and
///     `template_id = 'backfill_complete'`.
///   * [BackfillDispatchOutcome.failed] → emits with
///     `event_kind = 'notif.backfill.failed'` and
///     `template_id = 'backfill_failed'`.
///   * [BackfillDispatchOutcome.resumable] / `noJob` → no emit
///     (the catalog only fires email on terminal states).
@Deprecated(
  'Use `NotificationEventFanout` via `buildPostgresNotificationEventFanout` '
  '(EN-3-FU). This helper is kept for one release cycle as a fallback for '
  'degraded boot only.',
)
BackfillTerminalHook buildBackfillTerminalTelemetryHook({
  NotifTelemetryLogSeam logSeam = _defaultLogSeam,
}) {
  return ({
    required FirstConnectionBackfillJob job,
    required BackfillDispatchOutcome outcome,
    String? errorMessage,
  }) async {
    final String eventKind;
    final String templateId;
    switch (outcome) {
      case BackfillDispatchOutcome.succeeded:
        eventKind = 'notif.backfill.complete';
        templateId = 'backfill_complete';
      case BackfillDispatchOutcome.failed:
        eventKind = 'notif.backfill.failed';
        templateId = 'backfill_failed';
      case BackfillDispatchOutcome.resumable:
      case BackfillDispatchOutcome.noJob:
        return;
    }
    logSeam(
      LogSeverity.warning,
      'notif.event.unwired',
      fields: <String, Object?>{
        'event_kind': eventKind,
        'template_id': templateId,
        'operator_id': job.operatorId,
        'location_id': job.locationId,
        'connection_id': job.connectionId,
        'vendor_id': job.vendorId,
        'job_id': job.jobId,
        if (errorMessage != null) 'error_message': errorMessage,
        'reason': 'fanout_not_bound_in_production',
        'recipient_address_for_review': 'support@forgeflow.org',
      },
    );
    // Wave 2 EN-3-FU - emit the deprecation-trip warning so log
    // search can surface "fanout did not run; telemetry path fired
    // instead" without operator intervention.
    logSeam(
      LogSeverity.warning,
      'notif.event.telemetry_fallback',
      fields: <String, Object?>{
        'event_kind': eventKind,
        'reason': 'fanout_unavailable_telemetry_fired',
        'remediation':
            'ensure buildPostgresNotificationEventFanout wired in worker '
            'runtime',
      },
    );
  };
}

/// Structural mirror of `tool/audit_anchor/main.dart`'s
/// `AuditAnchorFailureHook` typedef. Re-declared here (rather than
/// imported) so this helper does not transitively pull in the
/// audit_anchor runtime (Postgres pool factory, blob client). The
/// audit_anchor CLI accepts the closure positionally so the two
/// typedef declarations are interchangeable at the call site.
typedef AuditAnchorFailureTelemetryHook =
    Future<void> Function({
      required String operatorId,
      required String chainDateIso,
      required String reason,
    });

/// Builds an audit-anchor failure hook that emits one structured
/// `notif.event.unwired` warning per failure.
///
/// Wave 2 EN-3-FU: superseded by the fanout-backed
/// `_buildFanoutBackedAnchorFailureHook` in
/// `tool/audit_anchor/main.dart`. Kept for one release cycle as a
/// fallback for degraded boot only.
///
/// Always emits with `event_kind = 'notif.audit.anchor_failure'`
/// and `template_id = 'audit_anchor_failure'`. The audit-anchor CLI
/// already swallows hook exceptions so a failure in the log emit
/// never changes the anchor exit code. The returned closure is
/// shape-compatible with `AuditAnchorFailureHook` (same parameter
/// names and types).
@Deprecated(
  'Use `NotificationEventFanout` via `buildPostgresNotificationEventFanout` '
  '(EN-3-FU). This helper is kept for one release cycle as a fallback for '
  'degraded boot only.',
)
AuditAnchorFailureTelemetryHook buildAuditAnchorFailureTelemetryHook({
  NotifTelemetryLogSeam logSeam = _defaultLogSeam,
}) {
  return ({
    required String operatorId,
    required String chainDateIso,
    required String reason,
  }) async {
    logSeam(
      LogSeverity.warning,
      'notif.event.unwired',
      fields: <String, Object?>{
        'event_kind': 'notif.audit.anchor_failure',
        'template_id': 'audit_anchor_failure',
        'operator_id': operatorId,
        'chain_date': chainDateIso,
        'reason': reason,
        'fanout_status': 'not_bound_in_production',
        'recipient_address_for_review': 'support@forgeflow.org',
      },
    );
    // Wave 2 EN-3-FU - emit the deprecation-trip warning so log
    // search can surface "fanout did not run; telemetry path fired
    // instead" without operator intervention.
    logSeam(
      LogSeverity.warning,
      'notif.event.telemetry_fallback',
      fields: <String, Object?>{
        'event_kind': 'notif.audit.anchor_failure',
        'reason': 'fanout_unavailable_telemetry_fired',
        'remediation':
            'ensure buildPostgresNotificationEventFanout wired in audit_anchor '
            'runtime',
      },
    );
  };
}
