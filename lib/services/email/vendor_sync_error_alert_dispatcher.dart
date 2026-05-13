// Lane C C-2-D — VendorSyncErrorAlertDispatcher.
//
// The companion dispatcher to `VendorSyncOutageDetector`. The
// detector is a pure state machine that decides "first failure
// of outage, time to email"; the dispatcher resolves the
// per-operator recipient + vendor metadata and inserts the row
// into `public.email_outbox`.
//
// Architecture
// ------------
// The dispatcher mirrors `VendorLifecycleNotificationDispatcher`:
// every dependency is a seam (recipient lookup, vendor catalog
// lookup, outbox writer) so production binds Postgres-backed
// implementations and tests pass in-memory fakes. The dispatcher
// itself owns NO Postgres / SQLite / HTTP code — it is a pure
// composition layer.
//
// Recipient resolution
// --------------------
// One email per outage per operator. The recipient is the
// operator's admin contact email (resolved via the injected
// [OperatorAdminEmailLookup]). The seam returns null when the
// operator has not yet been provisioned with an admin email
// (early-onboarding window before the first user lands); the
// dispatcher treats that as a soft-skip and the caller stamps
// notified_at = NULL elsewhere by NOT calling the detector
// enqueue at all. To avoid double-stamping (detector wins), the
// dispatcher returns a structured outcome so the caller can
// honour the skip.
//
// In production the lookup is the same operator-admin resolver
// used by the Phase 8 `vendor_now_available` fan-out — the
// admin Connected services console addressee.
//
// Vendor catalog resolution
// -------------------------
// The email body references `{{vendorName}}` (display name) +
// `{{integrationConsoleUrl}}` (deeplink to the operator-web
// Connected services screen for the connection). Production
// binds [VendorSyncAlertVendorMetadataLookup] to the same vendor
// catalog the lifecycle fan-out uses; tests pin a fixed map.
//
// Idempotency
// -----------
// The detector enforces "one email per outage window" via
// `vendor_sync_outage_state.notified_at`. The dispatcher's
// idempotency posture is "no row that crashed mid-flight stays
// pending": the email_outbox INSERT and the notified_at stamp
// run inside the SAME tenant transaction the polling tick
// already established, so a crash rolls both back.
//
// Additionally, the dispatcher computes a stable
// `outage_window_idempotency_key` per
// `(operator_id, connection_id, outage_started_at)` and threads
// it through the template_data so log search can correlate the
// detector decision with the eventual SendGrid send. The key is
// purely observational; the load-bearing dedupe is notified_at.
//
// Audit trail
// -----------
// Each enqueue writes one row to `public.audit_logs` with
// `action = 'vendor.sync_outage.alerted'` so the operator-facing
// audit timeline records the outage email. The audit row uses
// the same tenant transaction so the email + audit are atomic.
//
// Banned items posture (CLAUDE.md / Hard Promises):
//   * No raw `package:postgres` import here — production seams
//     bind to repository implementations under
//     `lib/infrastructure/persistence/postgres/`.
//   * No `tool/advisor_proxy/advisor_proxy.dart` touch.
//   * Operator-facing copy lives in the template Markdown.

import 'package:meta/meta.dart';

import 'email_template_renderer.dart';

/// Resolves the recipient email for an operator's admin contact.
/// Production binds this to a Postgres-backed lookup that reads
/// the operator's primary admin user (typically the first invited
/// user, stamped on the operator row at onboarding); tests pin a
/// fixed map.
///
/// Returns `null` when no admin contact has been provisioned yet
/// (early-onboarding window before the first user lands). The
/// dispatcher treats that as a soft-skip.
typedef OperatorAdminEmailLookup = Future<OperatorAdminContact?> Function({
  required String operatorId,
});

/// One admin contact for the operator. The recipient display name
/// is optional — the email template falls back to a friendly
/// salutation derived from the email local-part when null.
@immutable
class OperatorAdminContact {
  const OperatorAdminContact({
    required this.recipientEmail,
    required this.operatorBusinessName,
    this.recipientDisplayName,
  });

  /// Becomes `email_outbox.recipient_email`.
  final String recipientEmail;

  /// Renders into `{{businessName}}`. Production resolves from
  /// `operators.business_name`.
  final String operatorBusinessName;

  /// Optional. Threaded into the email salutation
  /// (`{{recipientName}}`).
  final String? recipientDisplayName;
}

/// Resolves vendor-side metadata for the email body. Production
/// binds this to the vendor catalog used by the lifecycle fan-out;
/// tests pin a fixed map.
typedef VendorSyncAlertVendorMetadataLookup
    = Future<VendorSyncAlertVendorMetadata?> Function({
  required String operatorId,
  required String locationId,
  required String connectionId,
});

@immutable
class VendorSyncAlertVendorMetadata {
  const VendorSyncAlertVendorMetadata({
    required this.vendorDisplayName,
    required this.integrationConsoleUrl,
  });

  /// Renders into `{{vendorName}}`.
  final String vendorDisplayName;

  /// Renders into `{{integrationConsoleUrl}}`. Production binds
  /// this to the operator-web Connected services deeplink for the
  /// specific connection.
  final String integrationConsoleUrl;
}

/// Writer seam — INSERT one row into `public.email_outbox`.
/// Production binds to a Postgres-backed implementation that runs
/// inside the caller's tenant transaction; tests pass an in-memory
/// fake.
abstract class VendorSyncErrorAlertOutboxWriter {
  /// INSERT one row.
  ///
  /// Production query:
  ///
  ///     INSERT INTO public.email_outbox (
  ///       email_id, operator_id, recipient_email,
  ///       recipient_display_name, template_id, template_data,
  ///       scheduled_for, status, attempt_count
  ///     ) VALUES (
  ///       gen_random_uuid(), @operator_id, @recipient_email,
  ///       @recipient_display_name, @template_id, @template_data,
  ///       now(), 'pending', 0
  ///     );
  ///
  /// The dispatcher does not block on the dispatcher pickup; the
  /// `email_outbox_notify_trg` trigger fires `pg_notify` and the
  /// existing `EmailOutboxDispatcher` claims the row.
  Future<void> enqueue({
    required String operatorId,
    required String recipientEmail,
    required String? recipientDisplayName,
    required String templateId,
    required Map<String, String> templateData,
  });
}

/// Writer seam — INSERT one row into `public.audit_logs`.
/// Production binds this to `AuditLogsRepository.writeRow`; tests
/// pass an in-memory fake.
typedef VendorSyncErrorAlertAuditWriter = Future<void> Function({
  required String operatorId,
  required String locationId,
  required String action,
  required Map<String, Object?> payload,
});

/// Outcome of a `dispatch` call. The detector treats every outcome
/// as terminal (the state machine never retries the email enqueue
/// inside the same observation), but tests + observability logs
/// use the outcome to assert what happened.
enum VendorSyncErrorAlertDispatchOutcome {
  /// Email enqueued + audit row written.
  enqueued,

  /// No admin contact provisioned for the operator. Soft skip — the
  /// detector's notified_at stays NULL so the NEXT failure retries
  /// the dispatch after the operator's onboarding lands.
  skippedNoRecipient,

  /// Vendor metadata lookup returned null. Soft skip with same
  /// retry posture as [skippedNoRecipient]. Production rarely sees
  /// this because the polling tier already verified the vendor is
  /// registered before the connection row exists.
  skippedNoVendorMetadata,
}

/// Pure orchestrator. Construction is dependency-injected so tests
/// can pass fakes for every seam without touching disk or Postgres.
class VendorSyncErrorAlertDispatcher {
  VendorSyncErrorAlertDispatcher({
    required OperatorAdminEmailLookup recipientLookup,
    required VendorSyncAlertVendorMetadataLookup vendorMetadataLookup,
    required VendorSyncErrorAlertOutboxWriter outboxWriter,
    required VendorSyncErrorAlertAuditWriter auditWriter,
    Duration escalationWindow = kDefaultEscalationWindow,
    DateTime Function()? now,
  })  : _recipientLookup = recipientLookup,
        _vendorMetadataLookup = vendorMetadataLookup,
        _outboxWriter = outboxWriter,
        _auditWriter = auditWriter,
        _escalationWindow = escalationWindow,
        _now = now ?? DateTime.now;

  /// V1 default: the body copy says "if the issue persists for more
  /// than {{escalationWindowHumanReadable}}, reply to this email".
  /// Two hours after the first detected failure is enough room for
  /// vendor-side incidents to self-recover (typical SaaS rolling
  /// outage window) while keeping the escalation path actionable.
  static const Duration kDefaultEscalationWindow = Duration(hours: 2);

  /// Action key recorded in `audit_logs.action` for every successful
  /// enqueue. Stable so log search can correlate the audit row with
  /// the outage state row + the eventual SendGrid send.
  static const String kAuditAction = 'vendor.sync_outage.alerted';

  final OperatorAdminEmailLookup _recipientLookup;
  final VendorSyncAlertVendorMetadataLookup _vendorMetadataLookup;
  final VendorSyncErrorAlertOutboxWriter _outboxWriter;
  final VendorSyncErrorAlertAuditWriter _auditWriter;
  final Duration _escalationWindow;
  final DateTime Function() _now;

  /// Enqueue the `vendor_sync_error_alert` email for the
  /// connection's current outage window. Called by the detector
  /// after it has determined the streak crossed the threshold AND
  /// no email has landed for this outage yet.
  ///
  /// [outageStartedAt] is threaded through the template body as
  /// `{{firstFailureHumanReadable}}` AND into the stable
  /// idempotency key (`outageWindowIdempotencyKey` in
  /// template_data) so log search can correlate the row with the
  /// detector state.
  Future<VendorSyncErrorAlertDispatchOutcome> dispatch({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required DateTime outageStartedAt,
    String? errorSummary,
  }) async {
    final recipient = await _recipientLookup(operatorId: operatorId);
    if (recipient == null) {
      return VendorSyncErrorAlertDispatchOutcome.skippedNoRecipient;
    }

    final vendorMetadata = await _vendorMetadataLookup(
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
    );
    if (vendorMetadata == null) {
      return VendorSyncErrorAlertDispatchOutcome.skippedNoVendorMetadata;
    }

    final templateData = <String, String>{
      'vendorName': vendorMetadata.vendorDisplayName,
      'businessName': recipient.operatorBusinessName,
      'recipientName':
          _resolveRecipientName(recipient: recipient),
      'firstFailureHumanReadable':
          _formatHumanReadable(outageStartedAt),
      'errorSummary': _clampErrorSummary(errorSummary),
      'integrationConsoleUrl': vendorMetadata.integrationConsoleUrl,
      'escalationWindowHumanReadable':
          _formatDuration(_escalationWindow),
      // Stable per-outage-window idempotency key. Threaded through
      // template_data so log search + admin tooling can correlate
      // the outbox row with the detector state. The dispatcher
      // does NOT use the key to short-circuit (the load-bearing
      // dedupe is the detector's notified_at flag); production
      // log search uses the key to confirm exactly one outbox row
      // per outage window.
      'outageWindowIdempotencyKey': _idempotencyKeyFor(
        operatorId: operatorId,
        connectionId: connectionId,
        outageStartedAt: outageStartedAt,
      ),
    };

    await _outboxWriter.enqueue(
      operatorId: operatorId,
      recipientEmail: recipient.recipientEmail,
      recipientDisplayName: recipient.recipientDisplayName,
      templateId: EmailTemplateIds.vendorSyncErrorAlert,
      templateData: templateData,
    );

    await _auditWriter(
      operatorId: operatorId,
      locationId: locationId,
      action: kAuditAction,
      payload: <String, Object?>{
        'connection_id': connectionId,
        'outage_started_at': outageStartedAt.toUtc().toIso8601String(),
        'notified_at': _now().toUtc().toIso8601String(),
        'recipient_email': recipient.recipientEmail,
        'vendor_display_name': vendorMetadata.vendorDisplayName,
        'idempotency_key': templateData['outageWindowIdempotencyKey'],
        'error_summary': templateData['errorSummary'],
      },
    );

    return VendorSyncErrorAlertDispatchOutcome.enqueued;
  }

  /// Stable per-outage-window key. The triple
  /// `(operator_id, connection_id, outage_started_at)` is invariant
  /// across detector retries within the same outage window, so the
  /// key is stable across replays.
  static String _idempotencyKeyFor({
    required String operatorId,
    required String connectionId,
    required DateTime outageStartedAt,
  }) {
    final isoStamp = outageStartedAt.toUtc().toIso8601String();
    return 'vendor_sync_outage:$operatorId:$connectionId:$isoStamp';
  }

  /// Best-effort recipient salutation. Mirrors the lifecycle
  /// dispatcher's fallback so the operator-facing tone is
  /// consistent across emails.
  static String _resolveRecipientName({
    required OperatorAdminContact recipient,
  }) {
    final supplied = recipient.recipientDisplayName?.trim();
    if (supplied != null && supplied.isNotEmpty) return supplied;
    final email = recipient.recipientEmail;
    final atIndex = email.indexOf('@');
    final localPart = atIndex > 0 ? email.substring(0, atIndex) : email;
    if (localPart.isEmpty) return 'there';
    return localPart;
  }

  /// Human-readable UTC stamp for the template body. Plain English
  /// per the UX writing standard — no engineering jargon, no time
  /// zone abbreviation the operator may not recognise.
  static String _formatHumanReadable(DateTime instant) {
    final utc = instant.toUtc();
    final yyyy = utc.year.toString().padLeft(4, '0');
    final mm = utc.month.toString().padLeft(2, '0');
    final dd = utc.day.toString().padLeft(2, '0');
    final hh = utc.hour.toString().padLeft(2, '0');
    final mi = utc.minute.toString().padLeft(2, '0');
    return '$yyyy-$mm-$dd $hh:$mi UTC';
  }

  /// Human-readable duration for the escalation window.
  static String _formatDuration(Duration d) {
    if (d.inHours >= 1) {
      final hours = d.inHours;
      return hours == 1 ? '1 hour' : '$hours hours';
    }
    final minutes = d.inMinutes;
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }

  /// Clamp + sanitise the error summary so it cannot blow up the
  /// email body. Vendor errors can be arbitrarily long;
  /// operator-facing copy reads as training so we bound the prefix.
  static String _clampErrorSummary(String? raw) {
    final trimmed = raw?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return 'The vendor did not respond as expected.';
    }
    const maxLength = 280;
    if (trimmed.length <= maxLength) return trimmed;
    return '${trimmed.substring(0, maxLength)}…';
  }
}
