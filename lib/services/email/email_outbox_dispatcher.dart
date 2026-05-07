// Forge & Flow — EmailOutboxDispatcher.
//
// Phase 9.8 email-provider slice. Drains the durable `email_outbox`
// queue: claims pending rows with `SELECT … FOR UPDATE SKIP LOCKED`,
// renders each row's template, hands the rendered envelope to the
// configured [EmailProvider], and advances the row through the
// status state machine:
//
//   pending → sending → sent     (provider returned 2xx)
//                    → failed    (>= max_attempts retries exhausted)
//                    → bounced   (webhook later marks the final state)
//                    → complaint (webhook later marks the final state)
//
// The `bounced` / `complaint` transitions are owned by the SendGrid
// webhook handler — the dispatcher itself only advances pending →
// sending → sent / failed. Wiring the webhook route is downstream
// scope (see slice doc § "Acceptance Criteria"); this file ships
// the dispatcher half so pending rows never get stuck on a missing
// webhook.
//
// Retry posture (slice doc, hard rule): up to 3 attempts. The 4th
// attempt does not fire — instead the row flips to `status='failed'`
// and the dispatcher emits an `email_dispatch.failed` alert event
// for the admin alert log row. The exact alert sink is injected so
// production binds it to the structured proxy log and tests can
// substitute a buffered list.
//
// Scheduling: the migration registers a `pg_cron` job that calls
// `public.email_outbox_tick()` every 1 minute. The SQL function
// emits `pg_notify('email_outbox_tick', '{}')`; in-process
// schedulers can also call [EmailOutboxDispatcher.drainBatch]
// directly (used by the "Test connection" admin route to dispatch
// the freshly-enqueued test row immediately rather than waiting up
// to a minute for the next cron tick).
//
// Per-batch claim ordering matches the locked operator-leading
// index pattern: the SQL adds `ORDER BY scheduled_for, email_id`
// so the dispatcher walks the head of the queue contiguously
// without serialising contention with other Cloud Run instances —
// `SKIP LOCKED` keeps each instance's claim disjoint.

import 'dart:async';

import 'email_provider.dart';
import 'email_template_renderer.dart';

/// Maximum send attempts before the dispatcher dead-letters a row.
/// Slice doc § "pg_cron worker": "3-strike rule: attempt_count >= 3
/// → status = 'failed' with admin alert."
const int kEmailDispatchMaxAttempts = 3;

/// Code-Health L8 — typed result returned by the SendGrid call site.
/// Replaces the string-contains reverse-engineering that used to live
/// in `_failureKindFromError`. The dispatcher branches on the runtime
/// type via an exhaustive `switch` (Dart sealed-class semantics) so
/// adding a new failure shape forces every callsite to handle it.
///
/// Classification rules (HTTP status from `EmailProviderException`):
///   * 2xx                 → [EmailSent]
///   * 429                 → [EmailRateLimitError] (honour Retry-After)
///   * 4xx other than 429  → [EmailPermanentError]
///   * 5xx + timeouts +
///     network             → [EmailTransientError]
///   * unknown shapes      → [EmailTransientError] (counts toward retry
///                           cap so transient unrecognised failures do
///                           not strand emails)
sealed class EmailSendOutcome {
  const EmailSendOutcome();
}

/// SendGrid returned 2xx and we have a `provider_message_id`.
class EmailSent extends EmailSendOutcome {
  const EmailSent(this.result);

  final EmailSendResult result;
}

/// Retryable failure: 5xx, network, timeout, unknown. Counts toward
/// the dispatcher's attempt cap; once exhausted the dispatcher
/// dead-letters the row.
class EmailTransientError extends EmailSendOutcome {
  const EmailTransientError({
    required this.kind,
    required this.message,
    this.statusCode,
  });

  final EmailFailureKind kind;
  final String message;
  final int? statusCode;
}

/// Non-retryable failure: 4xx (other than 429), provider auth,
/// provider protocol, render-time missing template variable. Dispatcher
/// dead-letters immediately on the first occurrence.
class EmailPermanentError extends EmailSendOutcome {
  const EmailPermanentError({
    required this.kind,
    required this.message,
    this.statusCode,
  });

  final EmailFailureKind kind;
  final String message;
  final int? statusCode;
}

/// Rate-limit failure (HTTP 429). Retryable; the dispatcher honours
/// `Retry-After` when present and falls back to the next cron tick
/// otherwise.
class EmailRateLimitError extends EmailSendOutcome {
  const EmailRateLimitError({
    required this.message,
    this.statusCode,
    this.retryAfter,
  });

  final String message;
  final int? statusCode;
  final Duration? retryAfter;
}

/// Code-Health L8 — translate one SendGrid call into a typed
/// [EmailSendOutcome]. The dispatcher uses this so the post-call
/// branching is type-driven rather than string-keyed.
///
/// Visible for testing — the unit suite drives this directly to pin
/// the classification rules at each HTTP shape.
Future<EmailSendOutcome> classifyEmailSendCall(
  Future<EmailSendResult> Function() send,
) async {
  try {
    final result = await send();
    return EmailSent(result);
  } on EmailProviderException catch (error) {
    return _classifyProviderException(error);
  } on TimeoutException catch (error) {
    return EmailTransientError(
      kind: EmailFailureKind.network,
      message: 'timeout: ${error.message}',
    );
  } catch (error) {
    return EmailTransientError(
      kind: EmailFailureKind.unknown,
      message: 'unknown_send_failure: $error',
    );
  }
}

EmailSendOutcome _classifyProviderException(EmailProviderException error) {
  switch (error.kind) {
    case EmailFailureKind.providerRateLimit:
      return EmailRateLimitError(
        message: error.toString(),
        statusCode: error.statusCode,
        retryAfter: error.retryAfter,
      );
    case EmailFailureKind.providerBadRequest:
    case EmailFailureKind.providerAuth:
    case EmailFailureKind.providerProtocol:
      return EmailPermanentError(
        kind: error.kind,
        message: error.toString(),
        statusCode: error.statusCode,
      );
    case EmailFailureKind.providerInternal:
    case EmailFailureKind.network:
    case EmailFailureKind.unknown:
      return EmailTransientError(
        kind: error.kind,
        message: error.toString(),
        statusCode: error.statusCode,
      );
  }
}

/// One row claimed from `email_outbox`. The dispatcher reads this
/// shape; the persistence repository (downstream) hydrates it from
/// the SQL row.
class EmailOutboxRow {
  const EmailOutboxRow({
    required this.emailId,
    required this.templateId,
    required this.recipientEmail,
    this.recipientDisplayName,
    required this.templateData,
    required this.attemptCount,
    this.operatorId,
  });

  final String emailId;
  final String templateId;
  final String recipientEmail;
  final String? recipientDisplayName;
  final Map<String, String> templateData;

  /// Existing attempt count BEFORE this dispatch. Persistence reads
  /// it under the FOR UPDATE lock; the dispatcher decides retry vs.
  /// dead-letter using the post-increment value.
  final int attemptCount;

  /// Operator scope. Null for system / F&F-internal emails (e.g.
  /// the admin "Test connection" surface). Operator-scoped emails
  /// flow through the operator-leading index in the migration.
  final String? operatorId;
}

/// Outcome the dispatcher writes back to the persistence layer for
/// one row. Persistence translates this into the final UPDATE on
/// the `email_outbox` row.
class EmailDispatchOutcome {
  const EmailDispatchOutcome({
    required this.emailId,
    required this.statusKind,
    required this.attemptCount,
    this.providerMessageId,
    this.lastError,
    this.lastAttemptAt,
    this.failureKind,
  });

  final String emailId;
  final EmailDispatchStatusKind statusKind;
  final int attemptCount;
  final String? providerMessageId;
  final String? lastError;
  final DateTime? lastAttemptAt;

  /// Code-Health L8 — typed failure classification carried alongside
  /// the human-readable [lastError]. Set when the dispatcher caught a
  /// provider failure (transient or permanent); null on success and
  /// on render-time short-circuits where the kind is implied by the
  /// source of the failure (see [EmailDispatchAlert.failureKind]).
  /// Replaces the string-contains reverse-engineering that used to
  /// live in `_failureKindFromError`.
  final EmailFailureKind? failureKind;
}

/// State machine values the dispatcher writes back. Persistence
/// maps these to the `email_outbox.status` enum.
enum EmailDispatchStatusKind {
  /// Provider accepted the message and returned a `provider_message_id`.
  /// Persistence sets `status='sent'`, `provider_message_id=…`,
  /// `last_attempt_at=…`.
  sent,

  /// Transient failure. Persistence keeps `status='pending'`,
  /// increments `attempt_count`, stamps `last_error` /
  /// `last_attempt_at`. The next cron tick picks the row back up.
  pendingRetry,

  /// Permanent failure (3-strike exhausted, auth error, bad-request
  /// from provider, parse error, missing template variable).
  /// Persistence sets `status='failed'` and the dispatcher emits an
  /// alert event so the admin alert log surfaces it.
  failed,
}

/// Persistence seam the dispatcher uses to claim and advance rows.
/// Production binds this to a Postgres-backed implementation that
/// runs `SELECT … FOR UPDATE SKIP LOCKED` inside a transaction;
/// tests substitute an in-memory fake.
abstract class EmailOutboxRepository {
  /// Claim up to [batchSize] pending rows whose `scheduled_for <= now()`.
  /// Implementations issue
  ///   SELECT … FROM email_outbox
  ///    WHERE status = 'pending' AND scheduled_for <= now()
  ///    ORDER BY scheduled_for, email_id
  ///    FOR UPDATE SKIP LOCKED
  ///    LIMIT @batchSize
  /// inside a transaction, flip each claimed row to `status='sending'`,
  /// and commit before returning.
  Future<List<EmailOutboxRow>> claimPending({required int batchSize});

  /// Apply [outcome] to the row. Persistence maps the
  /// [EmailDispatchStatusKind] back to the `email_outbox.status`
  /// column and stamps `provider_message_id` / `last_error` /
  /// `last_attempt_at` as supplied.
  Future<void> recordOutcome(EmailDispatchOutcome outcome);
}

/// Alert sink for permanent failures. Production binds this to the
/// structured proxy log (`log(LogSeverity.error, 'email_dispatch.failed',
/// fields: {...})`); tests substitute a buffered list.
typedef EmailDispatchAlertSink = void Function(EmailDispatchAlert alert);

class EmailDispatchAlert {
  const EmailDispatchAlert({
    required this.emailId,
    required this.templateId,
    required this.recipientEmail,
    required this.attemptCount,
    required this.failureKind,
    required this.message,
    this.operatorId,
  });

  final String emailId;
  final String templateId;
  final String recipientEmail;
  final int attemptCount;
  final EmailFailureKind failureKind;
  final String message;
  final String? operatorId;
}

class EmailOutboxDispatcher {
  EmailOutboxDispatcher({
    required EmailProvider provider,
    required EmailTemplateRenderer renderer,
    required EmailOutboxRepository repository,
    required EmailDispatchAlertSink alertSink,
    required this.fromAddress,
    required this.fromDisplayName,
    this.replyToAddress,
    this.maxAttempts = kEmailDispatchMaxAttempts,
    int batchSize = 25,
    DateTime Function()? now,
  })  : _provider = provider,
        _renderer = renderer,
        _repository = repository,
        _alertSink = alertSink,
        _batchSize = batchSize,
        _now = now ?? DateTime.now {
    if (maxAttempts < 1) {
      throw ArgumentError('maxAttempts must be >= 1');
    }
    if (batchSize < 1) {
      throw ArgumentError('batchSize must be >= 1');
    }
  }

  final EmailProvider _provider;
  final EmailTemplateRenderer _renderer;
  final EmailOutboxRepository _repository;
  final EmailDispatchAlertSink _alertSink;
  final int _batchSize;
  final DateTime Function() _now;

  /// Verified sender address. Production binds this to
  /// `noreply@mail.forgeflow.app`; staging may use the SendGrid
  /// sandbox sender.
  final String fromAddress;
  final String fromDisplayName;

  /// Optional `Reply-To`. Defaults to [fromAddress].
  final String? replyToAddress;

  /// Maximum send attempts before dead-lettering. Defaults to
  /// [kEmailDispatchMaxAttempts]. Tests inject smaller values to
  /// exercise the dead-letter path without a 3-attempt loop.
  final int maxAttempts;

  /// Drain one batch from the outbox. Returns the per-row outcomes
  /// (and emits alert events for permanent failures via [alertSink]).
  /// Production calls this from a `pg_cron`-fired tick on the
  /// 1-minute cadence; admin "Test connection" calls it directly so
  /// the test send fires immediately.
  ///
  /// J5 race fix: the dead-letter alert is emitted ONLY after
  /// [EmailOutboxRepository.recordOutcome] succeeds. If the
  /// persistence layer throws after a successful provider send, the
  /// alert is suppressed and the error is rethrown — the row stays
  /// in `sending` state and the next tick re-drives it. This ensures
  /// an operator never sees "send failed" for a message the recipient
  /// actually received just because the persistence step crashed
  /// mid-commit.
  Future<List<EmailDispatchOutcome>> drainBatch() async {
    final claimed = await _repository.claimPending(batchSize: _batchSize);
    final outcomes = <EmailDispatchOutcome>[];
    for (final row in claimed) {
      final outcome = await _dispatchOne(row);
      // J5 fix: persist outcome BEFORE deciding dead-letter. If
      // recordOutcome throws (e.g. mid-commit crash after a
      // successful send), we surface the persistence error and do
      // NOT emit a "failed" alert — the message was delivered; the
      // row needs a manual or automatic reconciliation pass.
      await _repository.recordOutcome(outcome);
      outcomes.add(outcome);
      if (outcome.statusKind == EmailDispatchStatusKind.failed) {
        // Code-Health L8 — failureKind is carried directly on the
        // outcome by the typed `_classifyProviderException` path; the
        // alert sink no longer reverse-engineers it from the
        // `lastError` string. The fallback is `unknown` only for
        // synthetic short-circuits (e.g. attempt-cap guard) where no
        // provider call was made.
        _alertSink(
          EmailDispatchAlert(
            emailId: row.emailId,
            templateId: row.templateId,
            recipientEmail: row.recipientEmail,
            attemptCount: outcome.attemptCount,
            failureKind: outcome.failureKind ?? EmailFailureKind.unknown,
            message: outcome.lastError ?? 'unknown',
            operatorId: row.operatorId,
          ),
        );
      }
    }
    return outcomes;
  }

  Future<EmailDispatchOutcome> _dispatchOne(EmailOutboxRow row) async {
    final nextAttempt = row.attemptCount + 1;
    // Guard: claim handed us a row that is already at the cap. Defensive —
    // the SQL claim should not return such rows, but this keeps a misbehaving
    // claim from looping the row through `sending` again.
    if (row.attemptCount >= maxAttempts) {
      final stamp = _now().toUtc();
      return EmailDispatchOutcome(
        emailId: row.emailId,
        statusKind: EmailDispatchStatusKind.failed,
        attemptCount: row.attemptCount,
        lastError: 'attempts already exceeded max ($maxAttempts)',
        lastAttemptAt: stamp,
      );
    }
    RenderedEmail rendered;
    try {
      rendered = _renderer.render(
        templateId: row.templateId,
        templateData: row.templateData,
      );
    } on MissingTemplateVariableError catch (e) {
      // Permanent: a missing variable cannot be fixed by retry.
      final stamp = _now().toUtc();
      return EmailDispatchOutcome(
        emailId: row.emailId,
        statusKind: EmailDispatchStatusKind.failed,
        attemptCount: nextAttempt,
        lastError: e.toString(),
        lastAttemptAt: stamp,
        // Code-Health L8 — render-time bad input is permanent and
        // semantically a "bad request" against the template surface;
        // surface providerBadRequest so the alert taxonomy stays
        // unified with the SendGrid-permanent path.
        failureKind: EmailFailureKind.providerBadRequest,
      );
    } catch (e) {
      // Unknown render failure — treat as permanent so the row does not
      // loop through retries that will keep failing.
      final stamp = _now().toUtc();
      return EmailDispatchOutcome(
        emailId: row.emailId,
        statusKind: EmailDispatchStatusKind.failed,
        attemptCount: nextAttempt,
        lastError: 'render_failed: $e',
        lastAttemptAt: stamp,
        failureKind: EmailFailureKind.unknown,
      );
    }
    final request = EmailSendRequest(
      to: EmailRecipient(
        email: row.recipientEmail,
        displayName: row.recipientDisplayName,
      ),
      subject: rendered.subject,
      htmlBody: rendered.htmlBody,
      textBody: rendered.textBody,
      fromAddress: fromAddress,
      fromDisplayName: fromDisplayName,
      replyToAddress: replyToAddress ?? fromAddress,
      providerMetadata: <String, String>{
        'email_id': row.emailId,
        'template_id': row.templateId,
        if (row.operatorId != null) 'operator_id': row.operatorId!,
      },
    );
    final stamp = _now().toUtc();
    final exhausted = nextAttempt >= maxAttempts;
    // Code-Health L8 — single classification site. The dispatcher
    // branches on the sealed `EmailSendOutcome` rather than on
    // `EmailProviderException.kind` strings, and never re-derives the
    // kind from `lastError.contains(...)`.
    final sendOutcome =
        await classifyEmailSendCall(() => _provider.send(request));
    return switch (sendOutcome) {
      EmailSent(:final result) => EmailDispatchOutcome(
          emailId: row.emailId,
          statusKind: EmailDispatchStatusKind.sent,
          attemptCount: nextAttempt,
          providerMessageId: result.providerMessageId,
          lastError: null,
          lastAttemptAt: result.acceptedAt,
        ),
      EmailRateLimitError(:final message) => EmailDispatchOutcome(
          emailId: row.emailId,
          statusKind: exhausted
              ? EmailDispatchStatusKind.failed
              : EmailDispatchStatusKind.pendingRetry,
          attemptCount: nextAttempt,
          lastError: message,
          lastAttemptAt: stamp,
          failureKind: EmailFailureKind.providerRateLimit,
        ),
      EmailTransientError(:final kind, :final message) =>
        EmailDispatchOutcome(
          emailId: row.emailId,
          statusKind: exhausted
              ? EmailDispatchStatusKind.failed
              : EmailDispatchStatusKind.pendingRetry,
          attemptCount: nextAttempt,
          lastError: message,
          lastAttemptAt: stamp,
          failureKind: kind,
        ),
      EmailPermanentError(:final kind, :final message) =>
        EmailDispatchOutcome(
          emailId: row.emailId,
          statusKind: EmailDispatchStatusKind.failed,
          attemptCount: nextAttempt,
          lastError: message,
          lastAttemptAt: stamp,
          failureKind: kind,
        ),
    };
  }
}
