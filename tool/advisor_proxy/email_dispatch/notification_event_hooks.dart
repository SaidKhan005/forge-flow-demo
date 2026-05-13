// Forge & Flow advisor proxy - notification event hooks.
//
// Phase 8 W2.B fanout wiring. Builds per-event
// [NotificationEventEnvelope]s for the events whose triggers exist
// today and dispatches them through [NotificationEventFanout].
//
// Wired events:
//
//   * notif.backfill.complete  -- first-connect backfill markSucceeded
//   * notif.backfill.failed    -- first-connect backfill terminal failure
//   * notif.audit.anchor_failure -- audit chain anchor cron failure
//
// The hooks live in this file (not in the trigger sites' files) so
// the dispatcher's NotificationEventFanout dependency is the only
// place a trigger site needs to import. Trigger sites pass a
// reference to this file's helpers; tests can mock the helpers.
//
// Each helper:
//
//   * Composes a stable `dedupeKeyPrefix` so retries collapse on
//     the channel-side UNIQUE indexes.
//   * Uses operator-facing copy aligned with the catalog title +
//     description (no engineering jargon, no em-dashes).
//   * Tolerates fanout failures by catching and logging; the
//     trigger site's primary work (the backfill or anchor result)
//     is never blocked by a notification-side error.

import 'notification_event_fanout.dart';

/// Shape of the helper a trigger site calls. Tests can mock this
/// type without touching the underlying [NotificationEventFanout].
typedef NotificationEventHook = Future<void> Function({
  required String operatorId,
  required Map<String, Object?> payload,
});

/// Narrow seam the hook helpers call into. Production binds this to
/// `NotificationEventFanout.fanOut`; tests pass a closure that
/// records the call. Keeps the helpers testable without forcing
/// callers to construct a full [NotificationEventFanout].
typedef FanOutEnvelope = Future<NotificationFanoutOutcome> Function({
  required String operatorId,
  required NotificationEventEnvelope envelope,
});

/// Catalog event_key for backfill-complete events. Constants live
/// here so the trigger sites import a single symbol per event
/// rather than re-typing the wire string.
const String kNotifBackfillCompleteKey = 'notif.backfill.complete';

/// Catalog event_key for backfill-failed events.
const String kNotifBackfillFailedKey = 'notif.backfill.failed';

/// Catalog event_key for audit chain anchor failure events.
const String kNotifAuditAnchorFailureKey = 'notif.audit.anchor_failure';

/// Email template id for the backfill-complete copy. The on-disk
/// template lives at `tool/advisor_proxy/email_templates/<id>.md`.
const String kBackfillCompleteEmailTemplateId = 'backfill_complete';
const String kBackfillFailedEmailTemplateId = 'backfill_failed';
const String kAuditAnchorFailureEmailTemplateId = 'audit_anchor_failure';

/// Hook seam for the first-connect backfill worker. Bind to
/// [emitBackfillComplete] in production. Trigger site: the
/// backfill dispatcher's `markSucceeded` path (currently
/// `tool/integration_sync_worker/backfill_dispatch.dart`'s
/// `dispatchNext` after `appendSyncLog('backfill_success')`).
Future<void> emitBackfillComplete({
  required FanOutEnvelope fanout,
  required String operatorId,
  required String locationId,
  required String connectionId,
  required String vendorId,
  required String jobId,
  String? deeplink,
}) async {
  try {
    await fanout(
      operatorId: operatorId,
      envelope: NotificationEventEnvelope(
        eventKey: kNotifBackfillCompleteKey,
        dedupeKeyPrefix:
            '$kNotifBackfillCompleteKey:$operatorId:$jobId',
        pushTitle: 'Historical sync complete',
        pushBody:
            'Your 60-day historical seed has finished and the '
            'connector is now live.',
        emailTemplateId: kBackfillCompleteEmailTemplateId,
        emailTemplateData: <String, String>{
          'vendorId': vendorId,
          'connectionId': connectionId,
          'locationId': locationId,
        },
        deeplink: deeplink,
        pushData: <String, Object?>{
          'vendor_id': vendorId,
          'connection_id': connectionId,
          'job_id': jobId,
        },
      ),
    );
  } catch (_) {
    // Notification-side failures never block the backfill path.
  }
}

/// Hook seam for the first-connect backfill terminal-failure path.
/// Bind to [emitBackfillFailed] in production. Trigger site:
/// `tool/first_connect_backfill_worker/main.dart`'s
/// `RetryCappingBackfillJobStore.markFailed` once the cap fires.
Future<void> emitBackfillFailed({
  required FanOutEnvelope fanout,
  required String operatorId,
  required String locationId,
  required String connectionId,
  required String vendorId,
  required String jobId,
  required String reason,
  String? deeplink,
}) async {
  try {
    await fanout(
      operatorId: operatorId,
      envelope: NotificationEventEnvelope(
        eventKey: kNotifBackfillFailedKey,
        dedupeKeyPrefix: '$kNotifBackfillFailedKey:$operatorId:$jobId',
        pushTitle: 'Historical sync needs attention',
        pushBody:
            'Your 60-day historical seed could not finish. We will '
            'retry automatically and let you know if it needs you.',
        emailTemplateId: kBackfillFailedEmailTemplateId,
        emailTemplateData: <String, String>{
          'vendorId': vendorId,
          'connectionId': connectionId,
          'locationId': locationId,
          'reason': reason,
        },
        deeplink: deeplink,
        pushData: <String, Object?>{
          'vendor_id': vendorId,
          'connection_id': connectionId,
          'job_id': jobId,
          'reason': reason,
        },
      ),
    );
  } catch (_) {}
}

/// Hook seam for the daily audit-anchor cron's failure path. Bind
/// to [emitAuditAnchorFailure] in production. Trigger site:
/// `tool/audit_anchor/main.dart`'s `_runAnchorMode` /
/// `_runSweepMode` failure branches (`AnchorOutcome.chainHashMismatch`,
/// `AnchorOutcome.recoveredFailed`, blob-unavailable catch).
Future<void> emitAuditAnchorFailure({
  required FanOutEnvelope fanout,
  required String operatorId,
  required String chainDateIso,
  required String reason,
}) async {
  try {
    await fanout(
      operatorId: operatorId,
      envelope: NotificationEventEnvelope(
        eventKey: kNotifAuditAnchorFailureKey,
        dedupeKeyPrefix:
            '$kNotifAuditAnchorFailureKey:$operatorId:$chainDateIso',
        pushTitle: 'Audit chain anchor needs review',
        pushBody:
            'A daily audit-log integrity anchor did not land. This '
            'never blocks operations, but the team should know.',
        emailTemplateId: kAuditAnchorFailureEmailTemplateId,
        emailTemplateData: <String, String>{
          'chainDate': chainDateIso,
          'reason': reason,
        },
        pushData: <String, Object?>{
          'chain_date': chainDateIso,
          'reason': reason,
        },
      ),
    );
  } catch (_) {}
}
