// Forge & Flow — MfaFactorChangedNoticeDispatcher.
//
// C-2-C wire (operator pick 2026-05-13): when the MFA removal worker
// completes a 24-hour revocation, this dispatcher enqueues one
// `email_outbox` row addressed to the user whose factor was removed.
// The catalog event_key is `notif.mfa.factor_changed` (see
// `lib/domain/models/notification_event_catalog.dart`); the template
// id is `EmailTemplateIds.mfaFactorChangedNotice`.
//
// Why a direct dispatcher (not `NotificationEventFanout`):
//
//   The MFA-factor-changed email is single-recipient (the user whose
//   factor changed), not operator-wide. The existing fanout worker
//   walks every user in an operator and filters by role gate;
//   wedging a "self-only" gate into the fanout would broaden the
//   role-gate machinery for one event. The single-recipient seam
//   mirrors `VendorLifecycleNotificationDispatcher`'s shape: a small
//   orchestrator with dependency-injected repository seams plus an
//   on-executor `enqueue` so the email enqueue commits atomically
//   with the worker's completion transaction.
//
// Idempotency:
//
//   The worker calls into this dispatcher inside its
//   `MfaFactorRemovalRequestsRepository.withTenant` body, after
//   `markCompletedInTransaction` returns >0. That guard is the
//   primary idempotency boundary: a parallel-writer race against the
//   same request short-circuits before the dispatcher runs. The
//   dispatcher also stamps a stable `idempotency_key` shape in the
//   audit + template_data payloads
//   (`notif.mfa.factor_changed:<userId>:<factorId>:<removedAtIso>`)
//   so future reconciliation tooling can grep for retried emits.
//
// CLAUDE.md compliance:
//
//   * No raw `package:postgres` import here — the dispatcher accepts a
//     `PostgresExecutor` from the caller's transaction; only
//     `lib/infrastructure/persistence/postgres/**` and the proxy
//     bootstrap shim bind the executor to the Postgres pool.
//   * No new permission key — the read of the user's email runs
//     pre-transaction through `UsersRepository.emailForUser` (admin
//     pool, system-pool read) which already exists.
//   * The trigger site (`mfa_removal_worker.dart`) writes an audit row
//     for the email enqueue via the existing
//     `AuthEventsAuditRepository.insertSystemEventOn` so the SOC-2
//     hash chain stays intact.

import 'dart:convert';

import '../../infrastructure/persistence/postgres/postgres_executor.dart';

/// Catalog event_key the dispatcher emits. Constant so the trigger
/// site and the catalog entry share the same string verbatim.
const String kMfaFactorChangedNoticeEventKey = 'notif.mfa.factor_changed';

/// Email template id resolved by `EmailTemplateIds.mfaFactorChangedNotice`.
/// Hard-coded here so the dispatcher does not import the renderer
/// (which would broaden the seam to the email-render layer; the
/// dispatcher only enqueues a row, the dispatcher of `email_outbox`
/// renders later).
const String kMfaFactorChangedNoticeTemplateId = 'mfa_factor_changed_notice';

/// Seam: enqueue one `email_outbox` row inside the caller's tenant
/// transaction. Production binds this to an INSERT against
/// `public.email_outbox` against the caller's [PostgresExecutor];
/// tests pass a closure that records the call.
typedef MfaFactorChangedNoticeOutboxEnqueueSeam = Future<void> Function(
  PostgresExecutor exec, {
  required String operatorId,
  required String userId,
  required String recipientEmail,
  required String? recipientDisplayName,
  required String templateId,
  required Map<String, String> templateData,
});

/// Default production binding for [MfaFactorChangedNoticeOutboxEnqueueSeam].
/// Issues the INSERT inline against the caller-supplied executor so the
/// email enqueue commits atomically with the worker's completion
/// transaction. The trigger fires `pg_notify('email_outbox', …)` on
/// commit so the dispatcher picks the row up on the next claim.
///
/// Visible for the worker bootstrap; tests substitute a recording
/// closure that captures `(operatorId, userId, recipientEmail,
/// templateData)` without touching disk.
Future<void> postgresMfaFactorChangedNoticeEnqueue(
  PostgresExecutor exec, {
  required String operatorId,
  required String userId,
  required String recipientEmail,
  required String? recipientDisplayName,
  required String templateId,
  required Map<String, String> templateData,
}) async {
  await exec.execute(
    'insert into public.email_outbox ('
    '  operator_id, user_id, recipient_email, recipient_display_name, '
    '  template_id, template_data, scheduled_for, status, attempt_count'
    ') values ('
    '  @operator_id::uuid, @user_id::uuid, @recipient_email, '
    '  @recipient_display_name, @template_id, @template_data::jsonb, '
    "  now(), 'pending', 0"
    ')',
    parameters: <String, Object?>{
      'operator_id': operatorId,
      'user_id': userId,
      'recipient_email': recipientEmail,
      'recipient_display_name': recipientDisplayName,
      'template_id': templateId,
      'template_data': jsonEncode(templateData),
    },
  );
}

/// Seam: emit one audit row stamping that the email was enqueued.
/// Mirrors `AuthEventsAuditRepository.insertSystemEventOn`'s shape so
/// production can bind this to `_auditRepository.insertSystemEventOn`
/// inline; tests pass a closure that records the call.
typedef MfaFactorChangedNoticeAuditSeam = Future<void> Function(
  PostgresExecutor exec, {
  required String operatorId,
  required String locationId,
  required String userId,
  required String eventType,
  required Map<String, Object?> payload,
});

/// Shape of the dispatch outcome — returned from
/// [MfaFactorChangedNoticeDispatcher.dispatchForRemoval] so the worker
/// can log per-tick stats without re-querying the recording seams.
class MfaFactorChangedNoticeDispatchOutcome {
  const MfaFactorChangedNoticeDispatchOutcome({
    required this.enqueued,
    required this.skippedReason,
  });

  /// True when one `email_outbox` row was enqueued + an audit row
  /// emitted. False when the dispatcher short-circuited (missing
  /// email, opt-out, etc.).
  final bool enqueued;

  /// Plain-English reason the dispatcher short-circuited. Null when
  /// [enqueued] is true.
  final String? skippedReason;

  static const MfaFactorChangedNoticeDispatchOutcome enqueuedOk =
      MfaFactorChangedNoticeDispatchOutcome(
    enqueued: true,
    skippedReason: null,
  );

  static MfaFactorChangedNoticeDispatchOutcome skipped(String reason) =>
      MfaFactorChangedNoticeDispatchOutcome(
        enqueued: false,
        skippedReason: reason,
      );
}

/// Pure orchestrator. Construction is dependency-injected so tests
/// can pass fakes for every seam without touching disk or Postgres.
class MfaFactorChangedNoticeDispatcher {
  MfaFactorChangedNoticeDispatcher({
    required MfaFactorChangedNoticeOutboxEnqueueSeam outboxEnqueue,
    required MfaFactorChangedNoticeAuditSeam auditEmit,
    required String accountSecurityUrl,
    DateTime Function()? now,
  })  : _outboxEnqueue = outboxEnqueue,
        _auditEmit = auditEmit,
        _accountSecurityUrl = accountSecurityUrl,
        _now = now ?? DateTime.now;

  final MfaFactorChangedNoticeOutboxEnqueueSeam _outboxEnqueue;
  final MfaFactorChangedNoticeAuditSeam _auditEmit;
  final String _accountSecurityUrl;
  final DateTime Function() _now;

  /// Enqueue the `mfa_factor_changed_notice` email for the user whose
  /// factor was just removed. Runs inside the caller's transaction
  /// (the worker's `markCompletedInTransaction` body) so the email
  /// enqueue + audit row commit or roll back atomically with the
  /// completion update.
  ///
  /// Returns [MfaFactorChangedNoticeDispatchOutcome.enqueuedOk] when
  /// the dispatcher wrote one outbox row + one audit row. Returns a
  /// skipped outcome when the recipient email is empty or the
  /// dispatcher decided to no-op (e.g. the caller passed a blank
  /// email after redaction).
  Future<MfaFactorChangedNoticeDispatchOutcome> dispatchForRemoval(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String userId,
    required String factorId,
    required String factorKind,
    required String factorLabel,
    required String recipientEmail,
    required String? recipientDisplayName,
    required DateTime removedAt,
  }) async {
    final trimmedEmail = recipientEmail.trim();
    if (trimmedEmail.isEmpty) {
      // Defense-in-depth: a missing email here means the upstream
      // user lookup returned a redacted value. Skip silently rather
      // than crashing the completion transaction; the audit + outbox
      // writes the worker does upstream still land.
      return MfaFactorChangedNoticeDispatchOutcome.skipped(
        'recipient_email_blank',
      );
    }
    final removedAtUtc = removedAt.toUtc();
    final removedAtIso = removedAtUtc.toIso8601String();
    final idempotencyKey =
        '$kMfaFactorChangedNoticeEventKey:$userId:$factorId:$removedAtIso';
    final changeDescription = _changeDescriptionFor(
      factorKind: factorKind,
      factorLabel: factorLabel,
    );
    final templateData = <String, String>{
      'recipientName': _resolveRecipientName(
        recipientDisplayName: recipientDisplayName,
        recipientEmail: trimmedEmail,
      ),
      'occurredAtHumanReadable': _formatOccurredAt(removedAtUtc),
      'changeDescription': changeDescription,
      'accountSecurityUrl': _accountSecurityUrl,
    };
    await _outboxEnqueue(
      exec,
      operatorId: operatorId,
      userId: userId,
      recipientEmail: trimmedEmail,
      recipientDisplayName: recipientDisplayName,
      templateId: kMfaFactorChangedNoticeTemplateId,
      templateData: templateData,
    );
    await _auditEmit(
      exec,
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      eventType: 'mfa_factor_changed_email_enqueued',
      payload: <String, Object?>{
        'event_key': kMfaFactorChangedNoticeEventKey,
        'template_id': kMfaFactorChangedNoticeTemplateId,
        'factor_id': factorId,
        'factor_kind': factorKind,
        'change_description': changeDescription,
        'idempotency_key': idempotencyKey,
        'recipient_email_present': true,
        'occurred_at': removedAtIso,
        'enqueued_at': _now().toUtc().toIso8601String(),
      },
    );
    return MfaFactorChangedNoticeDispatchOutcome.enqueuedOk;
  }

  /// Build the `{{changeDescription}}` substitution from the factor
  /// shape. The MFA worker only ships the removal-side path today
  /// (per C-2-C operator pick: "wire from removal only — lower
  /// scope"); enrollment-side wire would extend this with
  /// "{{factorLabel}} added" copy under a separate hook. The string
  /// is plain-English per the UX writing standard — no jargon, no
  /// engineering tokens.
  static String _changeDescriptionFor({
    required String factorKind,
    required String factorLabel,
  }) {
    final label = factorLabel.trim();
    switch (factorKind) {
      case 'totp':
        return label.isEmpty
            ? 'Authenticator app removed'
            : 'Authenticator app removed ($label)';
      case 'recovery_code':
        return 'Recovery codes were revoked';
      default:
        return label.isEmpty
            ? 'A two-factor method was removed'
            : 'A two-factor method was removed ($label)';
    }
  }

  /// Best-effort salutation. Matches the
  /// `VendorLifecycleNotificationDispatcher._resolveRecipientName`
  /// pattern: prefer the supplied display name, fall back to the
  /// email local-part, and finally to "there".
  String _resolveRecipientName({
    required String? recipientDisplayName,
    required String recipientEmail,
  }) {
    final trimmedName = recipientDisplayName?.trim();
    if (trimmedName != null && trimmedName.isNotEmpty) return trimmedName;
    final atIndex = recipientEmail.indexOf('@');
    if (atIndex <= 0) {
      // No '@' in the email, OR '@' is the first character (an
      // unaddressable local-part). The email shape is unusable for a
      // salutation; fall through to the neutral greeting.
      return 'there';
    }
    final localPart = recipientEmail.substring(0, atIndex);
    if (localPart.isEmpty) return 'there';
    return localPart;
  }

  /// Plain-English UTC stamp. Matches the renderer-test sample-data
  /// shape (`2026-05-04 09:14 UTC`) so production renders identical
  /// copy. We deliberately stay UTC at launch — operator-local time
  /// zone resolution is a Phase 10 follow-up tracked in the email
  /// L10n backlog.
  static String _formatOccurredAt(DateTime utc) {
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    final hh = utc.hour.toString().padLeft(2, '0');
    final mm = utc.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm UTC';
  }
}
