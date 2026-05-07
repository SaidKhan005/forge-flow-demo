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
// Idempotency: pending rows are filtered on `notified_at IS NULL` and
// every successful enqueue stamps `notified_at = now()` in the same
// transactional flow. A retried call for the same `(operator_id,
// vendor_id, new_lifecycle_state)` finds zero pending rows and is a
// natural no-op. The dispatcher never inserts a second outbox row
// for a notification it already processed.
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
typedef VendorNotificationContextResolver = Future<VendorNotificationOperatorContext>
    Function({required String operatorId, required String vendorId});

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
  Future<List<String>> pendingOperatorIdsForVendor({
    required String vendorId,
  });

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

  /// Stamp `notified_at = now()` on the row whose primary key matches
  /// [notificationId]. The operator id is required so production can
  /// run the UPDATE inside an `OperatorScopedRepository.withTenant`
  /// transaction without a cross-tenant escape.
  Future<void> markNotified({
    required String operatorId,
    required String notificationId,
    required DateTime stampedAt,
  });
}

/// Repository seam — enqueue rows into `email_outbox`. Production
/// binds this to a Postgres INSERT that runs in the same transaction
/// as the matching [VendorLifecycleNotificationReadRepository.markNotified]
/// call so a partial failure rolls back both halves; tests pass an
/// in-memory fake.
abstract class EmailOutboxEnqueueRepository {
  /// Insert one row into `public.email_outbox`. The dispatcher fills
  /// every column required for the send + the per-tenant claim index.
  /// Production binds this to:
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
  /// The dispatcher does not block on the write; the
  /// `email_outbox_notify_trg` trigger on the table fires
  /// `pg_notify('email_outbox', ...)` and the existing
  /// [EmailOutboxDispatcher] picks up the row on the next claim.
  Future<void> enqueue({
    required String operatorId,
    required String templateId,
    required String recipientEmail,
    required String? recipientDisplayName,
    required Map<String, String> templateData,
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
class VendorLifecycleNotificationDispatcher {
  VendorLifecycleNotificationDispatcher({
    required VendorLifecycleNotificationReadRepository notificationRepository,
    required EmailOutboxEnqueueRepository outboxRepository,
    required VendorNotificationContextResolver contextResolver,
    DateTime Function()? now,
  })  : _notificationRepository = notificationRepository,
        _outboxRepository = outboxRepository,
        _contextResolver = contextResolver,
        _now = now ?? DateTime.now;

  final VendorLifecycleNotificationReadRepository _notificationRepository;
  final EmailOutboxEnqueueRepository _outboxRepository;
  final VendorNotificationContextResolver _contextResolver;
  final DateTime Function() _now;

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
      final pending =
          await _notificationRepository.fetchPendingForVendor(
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
        };

        try {
          await _outboxRepository.enqueue(
            operatorId: operatorId,
            templateId: EmailTemplateIds.vendorNowAvailable,
            recipientEmail: notification.recipientEmail,
            recipientDisplayName: notification.recipientDisplayName ??
                operatorContext.recipientDisplayName,
            templateData: perRowData,
          );
          await _notificationRepository.markNotified(
            operatorId: operatorId,
            notificationId: notification.notificationId,
            stampedAt: _now().toUtc(),
          );
          totalEnqueued += 1;
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
    final localPart =
        atIndex > 0 ? email.substring(0, atIndex) : email;
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
