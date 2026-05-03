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
  });

  final String emailId;
  final EmailDispatchStatusKind statusKind;
  final int attemptCount;
  final String? providerMessageId;
  final String? lastError;
  final DateTime? lastAttemptAt;
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
  Future<List<EmailDispatchOutcome>> drainBatch() async {
    final claimed = await _repository.claimPending(batchSize: _batchSize);
    final outcomes = <EmailDispatchOutcome>[];
    for (final row in claimed) {
      final outcome = await _dispatchOne(row);
      outcomes.add(outcome);
      await _repository.recordOutcome(outcome);
      if (outcome.statusKind == EmailDispatchStatusKind.failed) {
        _alertSink(
          EmailDispatchAlert(
            emailId: row.emailId,
            templateId: row.templateId,
            recipientEmail: row.recipientEmail,
            attemptCount: outcome.attemptCount,
            failureKind: _failureKindFromError(outcome.lastError),
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
    EmailSendResult result;
    try {
      result = await _provider.send(request);
    } on EmailProviderException catch (error) {
      final stamp = _now().toUtc();
      final permanent = _isPermanent(error.kind);
      final exhausted = nextAttempt >= maxAttempts;
      if (permanent || exhausted) {
        return EmailDispatchOutcome(
          emailId: row.emailId,
          statusKind: EmailDispatchStatusKind.failed,
          attemptCount: nextAttempt,
          lastError: error.toString(),
          lastAttemptAt: stamp,
        );
      }
      return EmailDispatchOutcome(
        emailId: row.emailId,
        statusKind: EmailDispatchStatusKind.pendingRetry,
        attemptCount: nextAttempt,
        lastError: error.toString(),
        lastAttemptAt: stamp,
      );
    } on TimeoutException catch (error) {
      final stamp = _now().toUtc();
      final exhausted = nextAttempt >= maxAttempts;
      return EmailDispatchOutcome(
        emailId: row.emailId,
        statusKind: exhausted
            ? EmailDispatchStatusKind.failed
            : EmailDispatchStatusKind.pendingRetry,
        attemptCount: nextAttempt,
        lastError: 'timeout: ${error.message}',
        lastAttemptAt: stamp,
      );
    } catch (error) {
      // Unknown error shape. Counts toward the retry limit.
      final stamp = _now().toUtc();
      final exhausted = nextAttempt >= maxAttempts;
      return EmailDispatchOutcome(
        emailId: row.emailId,
        statusKind: exhausted
            ? EmailDispatchStatusKind.failed
            : EmailDispatchStatusKind.pendingRetry,
        attemptCount: nextAttempt,
        lastError: 'unknown_send_failure: $error',
        lastAttemptAt: stamp,
      );
    }
    return EmailDispatchOutcome(
      emailId: row.emailId,
      statusKind: EmailDispatchStatusKind.sent,
      attemptCount: nextAttempt,
      providerMessageId: result.providerMessageId,
      lastError: null,
      lastAttemptAt: result.acceptedAt,
    );
  }

  bool _isPermanent(EmailFailureKind kind) {
    switch (kind) {
      case EmailFailureKind.providerBadRequest:
      case EmailFailureKind.providerAuth:
      case EmailFailureKind.providerProtocol:
        return true;
      case EmailFailureKind.network:
      case EmailFailureKind.providerInternal:
      case EmailFailureKind.providerRateLimit:
      case EmailFailureKind.unknown:
        return false;
    }
  }

  EmailFailureKind _failureKindFromError(String? error) {
    if (error == null) return EmailFailureKind.unknown;
    if (error.contains('providerAuth')) return EmailFailureKind.providerAuth;
    if (error.contains('providerBadRequest')) {
      return EmailFailureKind.providerBadRequest;
    }
    if (error.contains('providerInternal')) {
      return EmailFailureKind.providerInternal;
    }
    if (error.contains('providerRateLimit')) {
      return EmailFailureKind.providerRateLimit;
    }
    if (error.contains('providerProtocol')) {
      return EmailFailureKind.providerProtocol;
    }
    if (error.contains('network') || error.contains('timeout')) {
      return EmailFailureKind.network;
    }
    return EmailFailureKind.unknown;
  }
}
