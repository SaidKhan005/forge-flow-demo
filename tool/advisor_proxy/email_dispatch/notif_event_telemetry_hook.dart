// Forge & Flow advisor proxy — notification event telemetry hooks.
//
// Wave 2 EN-3 (debug.md:315-316): the three internal-only events
// (backfill complete, backfill failed, audit anchor failure) have
// fully wired Markdown templates, registered template ids
// (`EmailTemplateIds.backfillComplete` etc.), and per-event hook
// helpers in `notification_event_hooks.dart`. They are NOT yet
// dispatched in production because the worker `main()` paths do not
// construct a `NotificationEventFanout` (Postgres-backed user
// directory, preference reader, and push outbox seams are still
// pending). The hook seam (`onTerminalOutcome` on the backfill
// dispatcher, `onAnchorFailure` on the audit_anchor CLI) defaults to
// `null` in production, which means the operator never learns the
// notification path was a no-op.
//
// This file ships the smallest production-visible mitigation per the
// EN-3 prompt's "ship the smallest possible mitigation + escalation
// note" guidance: a telemetry-only hook that emits a structured
// `notif.event.unwired` warning on every terminal outcome the
// fanout would have handled. The full `NotificationEventFanout`
// production wire-up (one Postgres user-directory query + one
// preference-reader query + the push-outbox INSERT seam) is tracked
// as the EN-3 follow-up in the PR body's "Operator decision"
// section.
//
// Once the full fanout is bound in production these helpers should
// be removed (or kept as a fallback for events the fanout itself
// short-circuits, e.g. operators with no admin user); test coverage
// in `test/services/email/notif_event_telemetry_hook_test.dart`
// pins the JSON envelope so a future migration is mechanical.

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
/// Routes:
///   * [BackfillDispatchOutcome.succeeded] → emits with
///     `event_kind = 'notif.backfill.complete'` and
///     `template_id = 'backfill_complete'`.
///   * [BackfillDispatchOutcome.failed] → emits with
///     `event_kind = 'notif.backfill.failed'` and
///     `template_id = 'backfill_failed'`.
///   * [BackfillDispatchOutcome.resumable] / `noJob` → no emit
///     (the catalog only fires email on terminal states).
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
/// Always emits with `event_kind = 'notif.audit.anchor_failure'`
/// and `template_id = 'audit_anchor_failure'`. The audit-anchor CLI
/// already swallows hook exceptions so a failure in the log emit
/// never changes the anchor exit code. The returned closure is
/// shape-compatible with `AuditAnchorFailureHook` (same parameter
/// names and types).
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
  };
}
