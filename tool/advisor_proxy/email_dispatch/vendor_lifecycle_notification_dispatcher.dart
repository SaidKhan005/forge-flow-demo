// Forge & Flow advisor proxy — VendorLifecycleNotificationDispatcher.
//
// Phase 8 V1.E lane (vendor-now-available fan-out). When a vendor
// promotes to `VendorLifecycle.productionCredentialed`, this
// dispatcher fans out one `email_outbox` row per matching pending
// row in `vendor_lifecycle_notification` (table from migration
// `db/migrations/202605040400_phase_8_0_lifecycle_add_vendor_lifecycle_notification.sql`).
//
// Trigger: the proxy admin route
// `POST /v1/admin/vendors/:vendor_id/lifecycle-promotion-notification`
// calls [dispatchForVendor]. The lifecycle promotion itself is owned
// by the live-rollout adapter slice (see
// `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`);
// this dispatcher only owns the email fan-out half.
//
// Idempotency: pending rows are filtered on `notified_at IS NULL`, and
// production claims each pending row and inserts its matching
// `email_outbox` row in one database transaction. A retried call for
// the same `(operator_id, vendor_id, new_lifecycle_state)` finds zero
// pending rows and is a natural no-op. A concurrent call with a
// different route idempotency key loses the row claim and also no-ops
// that row.
//
// Tenant isolation: notifications and outbox rows are read / written
// per operator. The dispatcher walks one operator at a time so the
// existing operator-leading indexes stay engaged. Cross-operator
// fan-out for a single vendor lifecycle flip is naturally handled by
// looping the operator list returned by [pendingOperatorIdsForVendor].
//
// Banned items posture (CLAUDE.md / Hard Promises):
//   * No raw `package:postgres` import here — the repository seams
//     keep this file SQLite-and-Postgres-agnostic. Only files under
//     `lib/infrastructure/persistence/postgres/` (plus the proxy
//     bootstrap shim) bind the seams to the Postgres pool. CI lint
//     (`tool/postgres_import_lint.dart`) enforces.
//   * No tracker updates — this lane only ships the fan-out wiring.
//   * Operator-facing copy lives in
//     `tool/advisor_proxy/email_templates/vendor_now_available.md`;
//     no jargon, no em-dashes per the UX writing standard.

import 'package:forge_and_flow/services/email/email_template_renderer.dart';
import 'package:forge_and_flow/domain/models/notification_preference.dart';

import 'notification_event_fanout.dart';

/// Narrow seam the dispatcher calls into for the `notif.vendor.now_available`
/// fanout. Production binds this to `NotificationEventFanout.fanOut`;
/// tests pass a recording closure to assert the dispatcher emits the
/// envelope without forcing tests to construct the full fanout.
typedef VendorLifecycleEventFanoutSeam =
    Future<NotificationFanoutOutcome> Function({
      required String operatorId,
      required NotificationEventEnvelope envelope,
    });

/// One pending Notify-me subscription returned by
/// [VendorLifecycleNotificationReadRepository.fetchPendingForVendor].
/// The dispatcher only needs the columns it stitches into the email
/// envelope and the primary-key seed for the fulfilment update.
class PendingVendorNotification {
  const PendingVendorNotification({
    required this.notificationId,
    required this.operatorId,
    required this.vendorId,
    required this.recipientEmail,
    this.recipientDisplayName,
  });

  /// `vendor_lifecycle_notification.notification_id` (uuid).
  final String notificationId;

  /// Owning operator. The dispatcher walks one operator at a time so
  /// the operator-leading index on `vendor_lifecycle_notification`
  /// stays engaged.
  final String operatorId;

  /// Vendor key matching `vendor_lifecycle_notification.vendor_id`.
  final String vendorId;

  /// `vendor_lifecycle_notification.email`. Becomes
  /// `email_outbox.recipient_email`.
  final String recipientEmail;

  /// Optional display name. The notification table does not store
  /// one today — the picker only captures email — so production
  /// always passes `null` here. The seam keeps the field for future
  /// `Notify me as Name` extensions without churn.
  final String? recipientDisplayName;
}

/// Per-operator context the dispatcher uses to render variables in
/// the `vendor_now_available` template. Production resolves this
/// from the operators table (display name) plus the vendor catalog
/// (display name + picker deeplink); tests pin a fixed value.
class VendorNotificationOperatorContext {
  const VendorNotificationOperatorContext({
    required this.operatorBusinessName,
    required this.vendorDisplayName,
    required this.integrationConsoleUrl,
    this.recipientDisplayName,
  });

  /// Renders into the `{{businessName}}` variable. The template
  /// reuses the existing `businessName` variable name so the locked
  /// `EmailTemplateRenderer` sample-data map does not need to grow.
  final String operatorBusinessName;

  /// Renders into `{{vendorName}}`. Same reason as above.
  final String vendorDisplayName;

  /// Renders into `{{integrationConsoleUrl}}`. Production binds this
  /// to the operator-web vendor-picker deeplink for the operator's
  /// home location.
  final String integrationConsoleUrl;

  /// Optional override for `email_outbox.recipient_display_name`.
  /// Falls back to the per-row [PendingVendorNotification.recipientDisplayName]
  /// when null.
  final String? recipientDisplayName;
}

/// Resolves the per-operator rendering context for a notification
/// fan-out. Production binds this to a Postgres-backed lookup that
/// reads the operator's business name + the vendor catalog entry
/// for the picker URL; tests pin a fixed map.
typedef VendorNotificationContextResolver =
    Future<VendorNotificationOperatorContext> Function({
      required String operatorId,
      required String vendorId,
    });

/// Repository seam — read pending notifications. Production binds
/// this to a Postgres query against `vendor_lifecycle_notification`
/// scoped to one operator (with `OperatorScopedRepository.withTenant`
/// keeping RLS engaged); tests pass an in-memory fake.
abstract class VendorLifecycleNotificationReadRepository {
  /// Returns the operator ids that have at least one pending
  /// notification for [vendorId]. Production query:
  ///
  ///     SELECT DISTINCT operator_id
  ///       FROM public.vendor_lifecycle_notification
  ///      WHERE vendor_id = @vendor_id
  ///        AND notified_at IS NULL
  ///      ORDER BY operator_id;
  ///
  /// The dispatcher walks one operator at a time so the operator-
  /// leading index on the table stays engaged.
  Future<List<String>> pendingOperatorIdsForVendor({required String vendorId});

  /// Returns every pending notification for `(operatorId, vendorId)`.
  /// Production query:
  ///
  ///     SELECT notification_id, operator_id, vendor_id, email
  ///       FROM public.vendor_lifecycle_notification
  ///      WHERE operator_id = @operator_id
  ///        AND vendor_id = @vendor_id
  ///        AND notified_at IS NULL
  ///      ORDER BY requested_at, notification_id;
  ///
  /// Idempotency: rows already stamped with `notified_at` are
  /// excluded by the WHERE clause; a retried fan-out will return
  /// fewer rows on each successive call until the result is empty.
  Future<List<PendingVendorNotification>> fetchPendingForVendor({
    required String operatorId,
    required String vendorId,
  });
}

/// Repository seam - claim a pending notification row and enqueue the
/// matching `email_outbox` row. Production does both operations inside
/// one transaction so concurrent promotion calls cannot duplicate an
/// email for the same pending row.
abstract class EmailOutboxEnqueueRepository {
  /// Claims [notification] by stamping `notified_at`, then inserts one
  /// row into `public.email_outbox`. Returns false when another
  /// concurrent caller already claimed the same pending notification.
  ///
  /// The dispatcher fills every column required for the send + the
  /// per-tenant claim index.
  /// Production binds this to:
  ///
  ///     UPDATE public.vendor_lifecycle_notification
  ///        SET notified_at = @notified_at
  ///      WHERE notification_id = @notification_id
  ///        AND operator_id = @operator_id
  ///        AND notified_at IS NULL
  ///      RETURNING notification_id;
  ///
  ///     INSERT INTO public.email_outbox (...)
  ///
  /// The dispatcher does not block on the write; the
  /// `email_outbox_notify_trg` trigger on the table fires
  /// `pg_notify('email_outbox', ...)` and the existing
  /// [EmailOutboxDispatcher] picks up the row on the next claim.
  Future<bool> claimAndEnqueue({
    required PendingVendorNotification notification,
    required String templateId,
    required String? recipientDisplayName,
    required Map<String, String> templateData,
    required DateTime stampedAt,
  });
}

/// Outcome of a `dispatchForVendor` call. Surfaces enqueue counts so
/// the proxy route can return a JSON envelope and tests can assert
/// the fan-out shape without re-querying the fake repositories.
class VendorLifecycleNotificationDispatchOutcome {
  const VendorLifecycleNotificationDispatchOutcome({
    required this.vendorId,
    required this.operatorsTouched,
    required this.notificationsEnqueued,
    required this.notificationsSkipped,
  });

  final String vendorId;

  /// Distinct operator ids that had at least one pending notification.
  final int operatorsTouched;

  /// Count of `email_outbox` rows enqueued + matching
  /// `vendor_lifecycle_notification.notified_at` updates stamped.
  final int notificationsEnqueued;

  /// Pending rows the dispatcher skipped because the per-operator
  /// context resolver threw or the email failed validation. Skipped
  /// rows stay pending so the next dispatch call (or a manual
  /// re-trigger) picks them up.
  final int notificationsSkipped;

  Map<String, Object?> toJson() => <String, Object?>{
    'vendor_id': vendorId,
    'operators_touched': operatorsTouched,
    'notifications_enqueued': notificationsEnqueued,
    'notifications_skipped': notificationsSkipped,
  };
}

/// Pure orchestrator. Construction is dependency-injected so tests
/// can pass fakes for every seam without touching disk or Postgres.
///
/// Phase 8 W2.B refactor: when an [eventFanout] is supplied, the
/// dispatcher delegates `notif.vendor.now_available` non-email
/// channels to [NotificationEventFanout.fanOut] in addition to the
/// existing per-row email enqueue. The legacy email path stays
/// unchanged so the V1.E "Notify me" pending-row table remains the
/// source of truth for email recipients (those rows are picker-side
/// opt-ins, not preference rows). The fanout layers push/inbox on
/// top for users whose `notification_preferences` admit them without
/// generating a second generic email.
class VendorLifecycleNotificationDispatcher {
  VendorLifecycleNotificationDispatcher({
    required VendorLifecycleNotificationReadRepository notificationRepository,
    required EmailOutboxEnqueueRepository outboxRepository,
    required VendorNotificationContextResolver contextResolver,
    VendorLifecycleEventFanoutSeam? eventFanout,
    DateTime Function()? now,
  }) : _notificationRepository = notificationRepository,
       _outboxRepository = outboxRepository,
       _contextResolver = contextResolver,
       _eventFanout = eventFanout,
       _now = now ?? DateTime.now;

  final VendorLifecycleNotificationReadRepository _notificationRepository;
  final EmailOutboxEnqueueRepository _outboxRepository;
  final VendorNotificationContextResolver _contextResolver;
  final VendorLifecycleEventFanoutSeam? _eventFanout;
  final DateTime Function() _now;

  /// Catalog event_key the dispatcher fans out when
  /// [_eventFanout] is wired. Constant so the trigger site and the
  /// fanout share the same string verbatim.
  static const String kVendorNowAvailableEventKey =
      'notif.vendor.now_available';

  /// Fan out the `vendor_now_available` email to every operator that
  /// has at least one pending row in `vendor_lifecycle_notification`
  /// for [vendorId]. The dispatcher walks one operator at a time so
  /// the operator-leading index stays engaged.
  ///
  /// Idempotent on retry: pending rows are filtered on
  /// `notified_at IS NULL`, and every successful enqueue stamps the
  /// notification fulfilment timestamp. A retried call for the same
  /// vendor finds zero pending rows.
  ///
  /// The dispatcher only fires when [newLifecycleState] is
  /// `productionCredentialed` — earlier promotions
  /// (`documented` -> `sandboxVerified`) are picker-chrome-only and
  /// must not trigger emails. Calling with any other state is a
  /// no-op so the proxy route can pass the new state through without
  /// branching.
  Future<VendorLifecycleNotificationDispatchOutcome> dispatchForVendor({
    required String vendorId,
    required String newLifecycleState,
  }) async {
    if (newLifecycleState != _kProductionCredentialedStateName) {
      return VendorLifecycleNotificationDispatchOutcome(
        vendorId: vendorId,
        operatorsTouched: 0,
        notificationsEnqueued: 0,
        notificationsSkipped: 0,
      );
    }

    final operatorIds = await _notificationRepository
        .pendingOperatorIdsForVendor(vendorId: vendorId);

    var totalEnqueued = 0;
    var totalSkipped = 0;

    for (final operatorId in operatorIds) {
      final pending = await _notificationRepository.fetchPendingForVendor(
        operatorId: operatorId,
        vendorId: vendorId,
      );
      if (pending.isEmpty) continue;

      VendorNotificationOperatorContext operatorContext;
      try {
        operatorContext = await _contextResolver(
          operatorId: operatorId,
          vendorId: vendorId,
        );
      } catch (_) {
        // Context resolver failure leaves the rows pending so a
        // retry can pick them up after the operator / vendor catalog
        // is healed.
        totalSkipped += pending.length;
        continue;
      }

      final templateData = <String, String>{
        'vendorName': operatorContext.vendorDisplayName,
        'businessName': operatorContext.operatorBusinessName,
        'integrationConsoleUrl': operatorContext.integrationConsoleUrl,
      };

      // Phase 8 W2.B: invoke the multi-channel fanout once per
      // operator before walking the pending email rows. Email is
      // intentionally suppressed here because the pending rows below
      // are the source of truth for "Notify me" email recipients.
      // Failures from the fanout do not block the email path:
      // preferences are an enrichment, not a gate, for the V1.E rows.
      final fanout = _eventFanout;
      if (fanout != null) {
        try {
          await fanout(
            operatorId: operatorId,
            envelope: NotificationEventEnvelope(
              eventKey: kVendorNowAvailableEventKey,
              dedupeKeyPrefix:
                  'notif.vendor.now_available:$operatorId:$vendorId',
              pushTitle:
                  '${operatorContext.vendorDisplayName} is now '
                  'available',
              pushBody:
                  'You can connect '
                  '${operatorContext.vendorDisplayName} from the '
                  'integrations console.',
              emailTemplateId: EmailTemplateIds.vendorNowAvailable,
              emailTemplateData: <String, String>{
                'vendorName': operatorContext.vendorDisplayName,
                'businessName': operatorContext.operatorBusinessName,
                'integrationConsoleUrl': operatorContext.integrationConsoleUrl,
              },
              deeplink: operatorContext.integrationConsoleUrl,
              pushData: <String, Object?>{'vendor_id': vendorId},
              suppressedChannels: const <NotificationChannel>{
                NotificationChannel.email,
              },
            ),
          );
        } catch (_) {
          // Fanout failures are tolerated -- the V1.E email path
          // still runs below. A retry of the route picks up missed
          // push/inbox rows.
        }
      }

      for (final notification in pending) {
        final recipientName = _resolveRecipientName(
          notification: notification,
          operatorContext: operatorContext,
        );
        // The vendor_now_available template references {{recipientName}}
        // alongside the per-operator vars. Compose the final
        // template_data per-row so the recipient salutation is
        // personal even when the operator context is shared.
        final perRowData = <String, String>{
          ...templateData,
          'recipientName': recipientName,
          'idempotency_key':
              'vendor_lifecycle_notification:${notification.notificationId}',
        };

        try {
          final enqueued = await _outboxRepository.claimAndEnqueue(
            notification: notification,
            templateId: EmailTemplateIds.vendorNowAvailable,
            recipientDisplayName:
                notification.recipientDisplayName ??
                operatorContext.recipientDisplayName,
            templateData: perRowData,
            stampedAt: _now().toUtc(),
          );
          if (enqueued) {
            totalEnqueued += 1;
          }
        } catch (_) {
          // Any enqueue failure leaves notified_at NULL so the next
          // tick / call retries the row. A single bad row does not
          // poison the rest of the operator's batch.
          totalSkipped += 1;
        }
      }
    }

    return VendorLifecycleNotificationDispatchOutcome(
      vendorId: vendorId,
      operatorsTouched: operatorIds.length,
      notificationsEnqueued: totalEnqueued,
      notificationsSkipped: totalSkipped,
    );
  }

  /// Best-effort recipient salutation. The notification table only
  /// stores the email, so we derive a friendly-but-non-presumptuous
  /// salutation from the email local-part. Operator-supplied
  /// override (when present on the operator context) takes priority.
  String _resolveRecipientName({
    required PendingVendorNotification notification,
    required VendorNotificationOperatorContext operatorContext,
  }) {
    final fromContext = operatorContext.recipientDisplayName?.trim();
    if (fromContext != null && fromContext.isNotEmpty) {
      return fromContext;
    }
    final fromRow = notification.recipientDisplayName?.trim();
    if (fromRow != null && fromRow.isNotEmpty) {
      return fromRow;
    }
    final email = notification.recipientEmail;
    final atIndex = email.indexOf('@');
    final localPart = atIndex > 0 ? email.substring(0, atIndex) : email;
    if (localPart.isEmpty) return 'there';
    return localPart;
  }
}

/// Canonical name of the `VendorLifecycle.productionCredentialed`
/// enum value as it appears on the wire / in the proxy route body.
/// Kept as a constant here so the dispatcher does not import the
/// `lib/services/integration` enum (which would broaden the seam to
/// the integration layer; the dispatcher must stay
/// integration-agnostic so future vendor classes plug in without
/// import churn).
const String _kProductionCredentialedStateName = 'productionCredentialed';
