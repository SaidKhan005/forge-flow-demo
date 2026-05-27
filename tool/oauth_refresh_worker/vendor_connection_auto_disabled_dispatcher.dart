// Forge & Flow OAuth refresh worker — VendorConnectionAutoDisabledDispatcher.
//
// C-2-F lane (Path b — direct outbox enqueue mirror of
// VendorLifecycleNotificationDispatcher). When the OAuth refresh worker
// trips the 3-strike auto-disable cap on a vendor credential
// (`tool/oauth_refresh_worker/main.dart` lines 1196 + 1226), this
// dispatcher enqueues one `email_outbox` row with template id
// `vendor_connection_auto_disabled` (per
// `tool/advisor_proxy/email_templates/vendor_connection_auto_disabled.md`).
// The existing `EmailOutboxDispatcher` (`lib/services/email/`) picks the
// row up on the next claim tick and hands it to SendGrid.
//
// Decision provenance:
//   * `docs/archive/_decisions/c_2_email_template_wire_or_delete_decisions.md`
//     Draft F — operator picked WIRE on 2026-05-13, worker pre-
//     recommended Path (b) `~400 LoC outbox enqueue` over Path (a)
//     `~600 LoC full fanout` for lower scope and a narrower blast
//     radius (no `NotificationEventFanout` bootstrap in the Cloud Run
//     worker required).
//   * `docs/archive/_indices/wave_1_closed_2026_05_13/WAVE_EXECUTION_LEDGER.md` row C-2-F.
//   * Reference pattern:
//     `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart`
//     (V1.E lane Notify-me fanout). The shape mirrors it (abstract
//     enqueue seam + resolver seam + dispatcher class) so future
//     auto-disable email surfaces extend the same idiom.
//
// Why a parallel seam (not extending VendorLifecycleNotificationDispatcher):
//   * The reference dispatcher is driven by a proxy admin route inside
//     the advisor proxy binary (HTTP request → fan-out across N pending
//     Notify-me subscriptions per operator). This dispatcher is driven
//     by the OAuth refresh worker (a separate Cloud Run binary) on a
//     per-credential trigger (1 enqueue per cap trip).
//   * The reference walks `vendor_lifecycle_notification` (a picker-side
//     opt-in table); this dispatcher resolves the recipient from
//     `public.operators.owner_email` because auto-disable is a
//     security-adjacent system notice to the operator's primary admin,
//     not a per-user opt-in.
//   * The reference computes idempotency from the pending-row primary
//     key (`vendor_lifecycle_notification.notification_id`); this
//     dispatcher uses a stable `(operator_id, credential_id,
//     disabled_at)` triple so retries within the same cap-trip window
//     collapse to one outbox row.
//
// Tenant isolation: every write rides through `OperatorScopedRepository`
// — the recipient lookup uses `withSystem` (the worker has no
// per-tenant context until it claims a row; the `owner_email` read is
// cross-tenant scope work mirroring `claimNearExpiryRows`'s posture);
// the outbox + audit writes use `withTenant` so `SET LOCAL
// app.operator_id / location_id` engages the per-tenant RLS index on
// `email_outbox` and the `audit_logs_actor_shape_check` constraint.
//
// Banned items posture (CLAUDE.md / Hard Promises):
//   * No raw `package:postgres` import here — the worker file already
//     stays Postgres-agnostic (it depends only on the
//     `lib/infrastructure/persistence/postgres/` seams). CI lint
//     (`tool/postgres_import_lint.dart`) enforces.
//   * No new permission key, no new migration. The audit row uses the
//     existing `vendor_credential_auto_disabled_email_enqueue` action;
//     `audit_logs.actor_kind = 'service'` (legacy posture matching the
//     companion `vendor_credential_auto_disabled` audit row written by
//     the worker on the same cap trip).
//   * Operator-facing copy lives in
//     `tool/advisor_proxy/email_templates/vendor_connection_auto_disabled.md`;
//     this file does not modify it.

import 'dart:convert';

import 'package:forge_and_flow/infrastructure/persistence/postgres/operator_scoped_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_context.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/email/email_template_renderer.dart';

import 'main.dart' show kOauthRefreshWorkerServicePrincipalId;

/// One recipient resolved for an auto-disable email. Production reads
/// `public.operators` for the row owning [operatorId] and returns
/// `(owner_email, business_name)`; tests pin a fixed value.
class AutoDisabledRecipient {
  const AutoDisabledRecipient({
    required this.recipientEmail,
    required this.businessName,
  });

  /// Becomes `email_outbox.recipient_email`. Must be a syntactically
  /// plausible email — the dispatcher does NOT re-validate here because
  /// `public.operators.owner_email` is already a CHECK-validated column
  /// at INSERT time on the parent table.
  final String recipientEmail;

  /// Operator-facing business name. Renders into `{{businessName}}`
  /// (kept for parity with `vendor_now_available`'s template variable
  /// shape even though the auto-disabled body does not currently
  /// reference it — keeping the template_data superset future-proofs
  /// the email when copy gets a salutation refresh).
  final String businessName;
}

/// Recipient resolver seam. Production binds this to a Postgres lookup
/// against `public.operators` via the admin pool; tests pass an
/// in-memory map.
typedef AutoDisabledRecipientResolver = Future<AutoDisabledRecipient?>
    Function({required String operatorId});

/// Vendor display-name resolver seam. Production binds this to
/// `lookupVendorCapability(vendorId)?.displayName` (mirrors how
/// `OperatorVendorLifecycleRecentlyAvailableRouter` wires its display-
/// name resolver in `proxy_bootstrap.dart`). Returns `null` for an
/// unknown vendor id — the dispatcher falls back to the raw vendor id
/// so the email never blocks on a catalog miss.
typedef AutoDisabledVendorDisplayNameResolver =
    String? Function(String vendorId);

/// Optional URL builder for the deeplink the template embeds. Production
/// binds this to the operator-web admin Connected services URL for the
/// given operator + location; tests pin a fixed URL.
typedef AutoDisabledConsoleUrlBuilder =
    String Function({
  required String operatorId,
  required String locationId,
  required String vendorId,
});

/// Default builder: the platform-wide admin integrations console. The
/// auto-disable email is a security-adjacent notice and intentionally
/// points the operator at the canonical Connected services card rather
/// than a per-location deeplink (which may not be accessible to the
/// operator's primary admin if hierarchy scopes the deeplink down).
String defaultAutoDisabledConsoleUrl({
  required String operatorId,
  required String locationId,
  required String vendorId,
}) {
  return 'https://app.forgeflow.app/admin/integrations';
}

/// Abstract enqueue seam — Postgres INSERT against
/// `public.email_outbox` PLUS the matching `public.audit_logs` row in
/// the same per-tenant transaction. Production binds this to
/// [PostgresAutoDisabledEmailEnqueueRepository]; tests pass an
/// in-memory fake.
///
/// The seam is intentionally split out (rather than reusing the
/// reference `EmailOutboxEnqueueRepository`) because the auto-disabled
/// write must commit atomically with the audit row inside a single
/// `withTenant` transaction. The reference seam takes neither operator
/// nor location for the audit write; this one needs both so RLS
/// engages and the audit chain accepts the row.
abstract class AutoDisabledEmailEnqueueRepository {
  /// Insert one row into `public.email_outbox` AND one row into
  /// `public.audit_logs` inside the same `withTenant` transaction. The
  /// idempotency-key constraint is enforced via a deterministic
  /// `template_data['idempotency_key']` value the caller supplies +
  /// the existing `(operator_id, recipient_email, template_id,
  /// scheduled_for)` partial index that a follow-up migration can
  /// promote to a UNIQUE constraint once enqueue volume justifies it.
  ///
  /// Returns the new `email_outbox.email_id` (UUID) so the audit
  /// payload can reference it, OR `null` when a duplicate key collapse
  /// short-circuits the insert (caller treats null as a skipped
  /// duplicate — the audit row still records the dedupe).
  Future<String?> enqueueAutoDisabledEmail({
    required String operatorId,
    required String locationId,
    required String credentialId,
    required String vendorId,
    required String templateId,
    required String recipientEmail,
    required String? recipientDisplayName,
    required Map<String, String> templateData,
    required String idempotencyKey,
    required DateTime occurredAt,
    required int consecutiveFailures,
    required String errorMessage,
  });
}

/// Postgres-backed implementation. Mirrors the
/// `PostgresOAuthRefreshWorkerGateway` posture in
/// `tool/oauth_refresh_worker/main.dart` (extends
/// `OperatorScopedRepository`; per-tenant write rides `withTenant`).
class PostgresAutoDisabledEmailEnqueueRepository
    extends OperatorScopedRepository
    implements AutoDisabledEmailEnqueueRepository {
  PostgresAutoDisabledEmailEnqueueRepository({
    required TenantTransactionWrapper tenantWrapper,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
  })  : _audit = auditLogsRepository,
        super(tenantWrapper);

  final AuditLogsRepository _audit;

  /// Audit-attribution `action` string for the `audit_logs` row that
  /// accompanies every email enqueue. Distinct from the
  /// `vendor_credential_auto_disabled` action the cap-trip path already
  /// writes (line ~1064 of `main.dart`) so log search can correlate
  /// the email-enqueue half independently. Stable string mirrors the
  /// reference dispatcher's `reason` discipline.
  static const String kAuditAction =
      'vendor_credential_auto_disabled_email_enqueue';

  @override
  Future<String?> enqueueAutoDisabledEmail({
    required String operatorId,
    required String locationId,
    required String credentialId,
    required String vendorId,
    required String templateId,
    required String recipientEmail,
    required String? recipientDisplayName,
    required Map<String, String> templateData,
    required String idempotencyKey,
    required DateTime occurredAt,
    required int consecutiveFailures,
    required String errorMessage,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
    );
    return withTenant<String?>(ctx, (exec) async {
      // Dedupe guard: a prior tick already enqueued an email with the
      // same idempotency key. The email_outbox table does not currently
      // carry an idempotency_key UNIQUE constraint, so we enforce
      // collapse here via a SELECT-then-INSERT inside the same
      // transaction. Concurrent ticks from a second pod would still
      // race here, but the autoDisableConnection path itself already
      // uses `FOR UPDATE SKIP LOCKED` on `vendor_credentials`, so two
      // pods cannot reach this path for the same (operator, vendor) in
      // the same tick.
      final existingRows = await exec.query(
        'select email_id::text as email_id '
        'from public.email_outbox '
        'where operator_id = @operator_id::uuid '
        '  and template_id = @template_id '
        "  and template_data ->> 'idempotency_key' = @idempotency_key "
        'limit 1',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'template_id': templateId,
          'idempotency_key': idempotencyKey,
        },
      );
      if (existingRows.isNotEmpty) {
        // Existing row found — record the dedupe in audit so a
        // post-incident review can match retries to the original
        // enqueue. Caller treats null as "duplicate collapsed".
        await _audit.writeRow(
          exec,
          operatorId: operatorId,
          locationId: locationId,
          occurredAt: occurredAt,
          actorKind: 'service',
          actorPrincipalId: kOauthRefreshWorkerServicePrincipalId,
          targetKind: 'email_outbox',
          targetId: existingRows.single['email_id']! as String,
          action: kAuditAction,
          payload: <String, Object?>{
            'vendor_id': vendorId,
            'credential_id': credentialId,
            'template_id': templateId,
            'idempotency_key': idempotencyKey,
            'consecutive_failures': consecutiveFailures,
            'duplicate_collapsed': true,
            'error_message': _truncateMessage(errorMessage),
          },
        );
        return null;
      }

      final inserted = await exec.query(
        'insert into public.email_outbox ('
        '  operator_id, recipient_email, recipient_display_name, '
        '  template_id, template_data, scheduled_for, status, '
        '  attempt_count'
        ') values ('
        '  @operator_id::uuid, @recipient_email, @recipient_display_name, '
        '  @template_id, @template_data::jsonb, now(), '
        "  'pending', 0"
        ') '
        'returning email_id::text as email_id',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'recipient_email': recipientEmail,
          'recipient_display_name': recipientDisplayName,
          'template_id': templateId,
          'template_data': jsonEncode(<String, Object?>{
            ...templateData,
            'idempotency_key': idempotencyKey,
          }),
        },
      );
      if (inserted.isEmpty) {
        // Should not happen — the INSERT either succeeds or the CHECK
        // constraints throw. Defensive guard.
        return null;
      }
      final emailId = inserted.single['email_id']! as String;
      await _audit.writeRow(
        exec,
        operatorId: operatorId,
        locationId: locationId,
        occurredAt: occurredAt,
        actorKind: 'service',
        actorPrincipalId: kOauthRefreshWorkerServicePrincipalId,
        targetKind: 'email_outbox',
        targetId: emailId,
        action: kAuditAction,
        payload: <String, Object?>{
          'vendor_id': vendorId,
          'credential_id': credentialId,
          'template_id': templateId,
          'idempotency_key': idempotencyKey,
          'consecutive_failures': consecutiveFailures,
          'duplicate_collapsed': false,
          'error_message': _truncateMessage(errorMessage),
        },
      );
      return emailId;
    });
  }

  /// Mirrors the worker's own _truncateMessage in main.dart. Kept
  /// privately here so the dispatcher can be unit tested without
  /// importing the worker's private helper.
  static String _truncateMessage(String raw) {
    const maxLen = 1024;
    return raw.length <= maxLen ? raw : raw.substring(0, maxLen);
  }
}

/// Recipient resolver — production reads `public.operators` via the
/// admin pool. The worker has cross-tenant scope (it walks every
/// operator that has a near-expiry credential), so the lookup uses
/// `withSystem` and audits as `'oauth_refresh_worker.auto_disabled_
/// recipient_lookup'` (the GUC `app.bypass_rls_audit` records the
/// reason).
class PostgresAutoDisabledRecipientResolver extends OperatorScopedRepository {
  PostgresAutoDisabledRecipientResolver({
    required TenantTransactionWrapper tenantWrapper,
  }) : super(tenantWrapper);

  /// Stable reason string passed to `withSystem` so log search can
  /// correlate the cross-tenant `operators` read with the cap-trip
  /// trigger.
  static const String kLookupReason =
      'oauth_refresh_worker.auto_disabled_recipient_lookup';

  Future<AutoDisabledRecipient?> resolve({
    required String operatorId,
  }) {
    return withSystem<AutoDisabledRecipient?>(
      (exec) async {
        final rows = await exec.query(
          'select owner_email, business_name '
          'from public.operators '
          'where operator_id = @operator_id::uuid '
          'limit 1',
          parameters: <String, Object?>{
            'operator_id': operatorId,
          },
        );
        if (rows.isEmpty) return null;
        final ownerEmail = rows.single['owner_email'];
        final businessName = rows.single['business_name'];
        if (ownerEmail is! String || ownerEmail.isEmpty) return null;
        if (businessName is! String || businessName.isEmpty) {
          return AutoDisabledRecipient(
            recipientEmail: ownerEmail,
            businessName: 'your business',
          );
        }
        return AutoDisabledRecipient(
          recipientEmail: ownerEmail,
          businessName: businessName,
        );
      },
      reason: kLookupReason,
    );
  }
}

/// Outcome of one [VendorConnectionAutoDisabledDispatcher.dispatchForAutoDisable]
/// call. The OAuth refresh worker logs this so a tick summary can
/// surface enqueue + skip counts alongside the existing
/// `WorkerTickResult.autoDisabled` count.
class AutoDisabledEmailDispatchOutcome {
  const AutoDisabledEmailDispatchOutcome({
    required this.enqueued,
    required this.skippedReason,
    required this.emailId,
  });

  /// True when this call inserted a new `email_outbox` row.
  final bool enqueued;

  /// Non-null when [enqueued] is false. One of:
  ///   * `'recipient_not_found'` — the operator's `owner_email` is
  ///     missing or empty.
  ///   * `'duplicate_collapsed'` — an existing outbox row with the
  ///     same idempotency key already exists.
  ///   * `'enqueue_error'` — the INSERT or audit write threw. The
  ///     worker swallows the throw so the per-row cap path is not
  ///     poisoned; a follow-up tick can retry.
  final String? skippedReason;

  /// `email_outbox.email_id` UUID when [enqueued] is true; null
  /// otherwise.
  final String? emailId;

  bool get skipped => !enqueued;
}

/// Pure orchestrator. Dependency-injected so tests pass fakes for
/// every seam without touching disk or Postgres.
class VendorConnectionAutoDisabledDispatcher {
  VendorConnectionAutoDisabledDispatcher({
    required AutoDisabledEmailEnqueueRepository enqueueRepository,
    required AutoDisabledRecipientResolver recipientResolver,
    AutoDisabledVendorDisplayNameResolver? vendorDisplayNameResolver,
    AutoDisabledConsoleUrlBuilder? consoleUrlBuilder,
    DateTime Function()? now,
  })  : _enqueueRepository = enqueueRepository,
        _recipientResolver = recipientResolver,
        _vendorDisplayNameResolver = vendorDisplayNameResolver,
        _consoleUrlBuilder = consoleUrlBuilder ?? defaultAutoDisabledConsoleUrl,
        _now = now ?? DateTime.now;

  final AutoDisabledEmailEnqueueRepository _enqueueRepository;
  final AutoDisabledRecipientResolver _recipientResolver;
  final AutoDisabledVendorDisplayNameResolver? _vendorDisplayNameResolver;
  final AutoDisabledConsoleUrlBuilder _consoleUrlBuilder;
  final DateTime Function() _now;

  /// Enqueue one `vendor_connection_auto_disabled` email + matching
  /// audit row for the just-tripped cap on `(operatorId, credentialId)`.
  /// Caller (the worker tick) treats every outcome as advisory: any
  /// throw is swallowed so the cap trip itself (status flip + first
  /// audit row) is never blocked.
  Future<AutoDisabledEmailDispatchOutcome> dispatchForAutoDisable({
    required String operatorId,
    required String locationId,
    required String credentialId,
    required String vendorId,
    required int consecutiveFailures,
    required String errorMessage,
    DateTime? disabledAt,
  }) async {
    final occurredAt = (disabledAt ?? _now()).toUtc();
    final recipient = await _recipientResolver(operatorId: operatorId);
    if (recipient == null) {
      return const AutoDisabledEmailDispatchOutcome(
        enqueued: false,
        skippedReason: 'recipient_not_found',
        emailId: null,
      );
    }

    final vendorDisplayName =
        _vendorDisplayNameResolver?.call(vendorId) ?? vendorId;
    final consoleUrl = _consoleUrlBuilder(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    );

    // Template data — every variable referenced by
    // `tool/advisor_proxy/email_templates/vendor_connection_auto_disabled.md`
    // MUST be present here or the renderer throws
    // `MissingTemplateVariableError` at dispatch time. The template
    // references:
    //   * vendorName, recipientName, disabledAtHumanReadable,
    //     strikeCount, lastErrorSummary, integrationConsoleUrl.
    // We also carry businessName for parity with the
    // `vendor_now_available` template's variable shape (future copy
    // refresh may use it).
    final templateData = <String, String>{
      'vendorName': vendorDisplayName,
      'recipientName': _resolveRecipientName(recipient.recipientEmail),
      'businessName': recipient.businessName,
      'disabledAtHumanReadable': _formatHumanReadable(occurredAt),
      'strikeCount': consecutiveFailures.toString(),
      'lastErrorSummary': _summarizeError(errorMessage),
      'integrationConsoleUrl': consoleUrl,
    };

    final idempotencyKey = _buildIdempotencyKey(
      operatorId: operatorId,
      credentialId: credentialId,
      disabledAt: occurredAt,
    );

    try {
      final emailId = await _enqueueRepository.enqueueAutoDisabledEmail(
        operatorId: operatorId,
        locationId: locationId,
        credentialId: credentialId,
        vendorId: vendorId,
        templateId: EmailTemplateIds.vendorConnectionAutoDisabled,
        recipientEmail: recipient.recipientEmail,
        recipientDisplayName: null,
        templateData: templateData,
        idempotencyKey: idempotencyKey,
        occurredAt: occurredAt,
        consecutiveFailures: consecutiveFailures,
        errorMessage: errorMessage,
      );
      if (emailId == null) {
        return const AutoDisabledEmailDispatchOutcome(
          enqueued: false,
          skippedReason: 'duplicate_collapsed',
          emailId: null,
        );
      }
      return AutoDisabledEmailDispatchOutcome(
        enqueued: true,
        skippedReason: null,
        emailId: emailId,
      );
    } catch (_) {
      // Swallow — the cap-trip path's own audit row + status flip have
      // already committed (the worker calls this dispatcher AFTER
      // `gateway.autoDisableConnection`). A future tick can retry the
      // email when the operator-row resolver heals.
      return const AutoDisabledEmailDispatchOutcome(
        enqueued: false,
        skippedReason: 'enqueue_error',
        emailId: null,
      );
    }
  }

  /// Builds a deterministic key for the `(operator_id, credential_id,
  /// disabled_at)` triple. The minute-truncated timestamp lets a
  /// retried cap trip within the same minute collapse to one outbox
  /// row; longer-spaced retries enqueue a fresh email so the operator
  /// is reminded if the original send bounced.
  String _buildIdempotencyKey({
    required String operatorId,
    required String credentialId,
    required DateTime disabledAt,
  }) {
    final minute = DateTime.utc(
      disabledAt.year,
      disabledAt.month,
      disabledAt.day,
      disabledAt.hour,
      disabledAt.minute,
    );
    return 'auto_disable:$operatorId:$credentialId:'
        '${minute.toIso8601String()}';
  }

  /// Salutation fallback. Mirrors the reference dispatcher's
  /// `_resolveRecipientName` for parity — the recipient row carries
  /// only `owner_email`, so we derive a non-presumptuous salutation
  /// from the email local-part.
  String _resolveRecipientName(String email) {
    final atIndex = email.indexOf('@');
    final localPart = atIndex > 0 ? email.substring(0, atIndex) : email;
    if (localPart.isEmpty) return 'there';
    return localPart;
  }

  /// Plain-English UTC formatter for the `{{disabledAtHumanReadable}}`
  /// variable. Operator-facing copy avoids ambiguous date shapes; the
  /// `YYYY-MM-DD HH:mm UTC` form is unambiguous across locales and
  /// matches the reference dispatcher's stylistic posture.
  String _formatHumanReadable(DateTime instant) {
    final utc = instant.toUtc();
    final year = utc.year.toString().padLeft(4, '0');
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    final hour = utc.hour.toString().padLeft(2, '0');
    final minute = utc.minute.toString().padLeft(2, '0');
    return '$year-$month-$day $hour:$minute UTC';
  }

  /// Trims the raw error message to a single line suitable for the
  /// template's `{{lastErrorSummary}}` slot. The renderer HTML-escapes
  /// the value at render time, so we only need to collapse whitespace
  /// and cap length here.
  String _summarizeError(String raw) {
    final collapsed =
        raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (collapsed.isEmpty) return 'unknown';
    const maxLen = 200;
    if (collapsed.length <= maxLen) return collapsed;
    return '${collapsed.substring(0, maxLen)}...';
  }
}
