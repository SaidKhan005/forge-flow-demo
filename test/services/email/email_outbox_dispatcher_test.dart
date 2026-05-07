// Phase 9.8 email-provider slice — EmailOutboxDispatcher tests.
//
// Drives the dispatcher against fake repository + provider doubles
// to assert:
//
//   * Successful send → status sent + provider_message_id stamped.
//   * Transient failure → status pendingRetry + attempt count
//     incremented + last_error stamped.
//   * 3-strike retry → status flips to failed + alert sink notified.
//   * Permanent failure (providerAuth / providerBadRequest) →
//     immediate failed + alert.
//   * Missing template variable → immediate failed + alert.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/email/email_outbox_dispatcher.dart';
import 'package:forge_and_flow/services/email/email_provider.dart';
import 'package:forge_and_flow/services/email/email_template_renderer.dart';

void main() {
  EmailTemplateRenderer buildRenderer() {
    return EmailTemplateRenderer(
      templateSource: EmailTemplateRenderer.fromMap(<String, String>{
        EmailTemplateIds.operatorInviteFirstAdmin:
            'Welcome, {{recipientName}}.',
      }),
      brandWrapperSource:
          EmailTemplateRenderer.fromString('<html>{{body}}</html>'),
    );
  }

  group('EmailOutboxDispatcher.drainBatch', () {
    test('sends pending row and stamps provider_message_id', () async {
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'email-1',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'admin@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
          operatorId: 'op-1',
        ),
      ]);
      final provider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.success('sg-msg-1'),
        ],
      );
      final alerts = <EmailDispatchAlert>[];
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: alerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
        now: () => DateTime.utc(2026, 5, 4, 14, 0),
      );

      final outcomes = await dispatcher.drainBatch();

      expect(outcomes, hasLength(1));
      final outcome = outcomes.single;
      expect(outcome.statusKind, EmailDispatchStatusKind.sent);
      expect(outcome.providerMessageId, 'sg-msg-1');
      expect(outcome.attemptCount, 1);
      expect(outcome.lastError, isNull);
      expect(repo.recorded.single.statusKind,
          EmailDispatchStatusKind.sent);
      expect(alerts, isEmpty);
    });

    test('transient failure → pendingRetry on first attempt', () async {
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'email-2',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'admin@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
        ),
      ]);
      final provider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.failure(const EmailProviderException(
            kind: EmailFailureKind.providerInternal,
            message: '500',
            statusCode: 502,
          )),
        ],
      );
      final alerts = <EmailDispatchAlert>[];
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: alerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final outcomes = await dispatcher.drainBatch();

      expect(outcomes.single.statusKind,
          EmailDispatchStatusKind.pendingRetry);
      expect(outcomes.single.attemptCount, 1);
      expect(outcomes.single.lastError, contains('providerInternal'));
      expect(alerts, isEmpty);
    });

    test('3rd attempt failure flips to failed with alert', () async {
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'email-3',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'admin@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 2,
          operatorId: 'op-2',
        ),
      ]);
      final provider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.failure(const EmailProviderException(
            kind: EmailFailureKind.providerInternal,
            message: '500',
            statusCode: 502,
          )),
        ],
      );
      final alerts = <EmailDispatchAlert>[];
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: alerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final outcomes = await dispatcher.drainBatch();

      expect(outcomes.single.statusKind, EmailDispatchStatusKind.failed);
      expect(outcomes.single.attemptCount, 3);
      expect(alerts, hasLength(1));
      expect(alerts.single.emailId, 'email-3');
      expect(alerts.single.failureKind, EmailFailureKind.providerInternal);
      expect(alerts.single.attemptCount, 3);
      expect(alerts.single.operatorId, 'op-2');
    });

    test('permanent failure (auth) dead-letters on first attempt',
        () async {
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'email-4',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'admin@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
        ),
      ]);
      final provider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.failure(const EmailProviderException(
            kind: EmailFailureKind.providerAuth,
            message: 'unauthorized',
            statusCode: 401,
          )),
        ],
      );
      final alerts = <EmailDispatchAlert>[];
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: alerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final outcomes = await dispatcher.drainBatch();

      expect(outcomes.single.statusKind, EmailDispatchStatusKind.failed);
      expect(outcomes.single.attemptCount, 1);
      expect(alerts.single.failureKind, EmailFailureKind.providerAuth);
    });

    test('missing template variable dead-letters with render alert',
        () async {
      // Renderer that requires `recipientName` but data omits it.
      final renderer = EmailTemplateRenderer(
        templateSource: EmailTemplateRenderer.fromMap(<String, String>{
          EmailTemplateIds.operatorInviteFirstAdmin:
              'Hi {{recipientName}}',
        }),
        brandWrapperSource:
            EmailTemplateRenderer.fromString('{{body}}'),
      );
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'email-5',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'admin@example.com',
          templateData: <String, String>{},
          attemptCount: 0,
        ),
      ]);
      final provider = _StubProvider(sendOutcomes: <_SendOutcome>[]);
      final alerts = <EmailDispatchAlert>[];
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: renderer,
        repository: repo,
        alertSink: alerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final outcomes = await dispatcher.drainBatch();

      expect(outcomes.single.statusKind, EmailDispatchStatusKind.failed);
      expect(outcomes.single.lastError,
          contains('MissingTemplateVariableError'));
      expect(provider.sendsAttempted, 0,
          reason: 'provider should not be called when render fails');
      expect(alerts, hasLength(1));
    });

    test('rate-limit failure on a fresh row → pendingRetry', () async {
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'email-6',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'admin@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
        ),
      ]);
      final provider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.failure(const EmailProviderException(
            kind: EmailFailureKind.providerRateLimit,
            message: 'rate limit',
            statusCode: 429,
            retryAfter: Duration(seconds: 30),
          )),
        ],
      );
      final alerts = <EmailDispatchAlert>[];
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: alerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final outcomes = await dispatcher.drainBatch();

      expect(outcomes.single.statusKind,
          EmailDispatchStatusKind.pendingRetry);
      expect(alerts, isEmpty);
    });

    test('row already at attempt cap is short-circuited to failed',
        () async {
      // Defensive — the SQL claim filter should not return such rows,
      // but the dispatcher protects against a misbehaving claim by
      // refusing to send a row whose attempt_count >= max_attempts.
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'email-7',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'admin@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 3,
        ),
      ]);
      final provider = _StubProvider(sendOutcomes: <_SendOutcome>[]);
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: (_) {},
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final outcomes = await dispatcher.drainBatch();

      expect(outcomes.single.statusKind, EmailDispatchStatusKind.failed);
      expect(provider.sendsAttempted, 0);
    });
  });

  // ── Code-Health L8 — typed EmailSendOutcome classification ─────────
  //
  // These tests pin the four sealed-class branches by HTTP shape so a
  // future refactor of `_classifyProviderException` cannot silently
  // re-introduce the string-keyed reverse engineering the L8 finding
  // called out.
  group('Code-Health L8 — typed EmailSendOutcome', () {
    test('SendGrid 200/2xx → EmailSent carries the provider message id',
        () async {
      final outcome = await classifyEmailSendCall(
        () async => EmailSendResult(
          providerMessageId: 'sg-msg-200',
          acceptedAt: DateTime.utc(2026, 5, 4, 12),
        ),
      );
      expect(outcome, isA<EmailSent>());
      expect((outcome as EmailSent).result.providerMessageId, 'sg-msg-200');
    });

    test('SendGrid 429 → EmailRateLimitError carries Retry-After', () async {
      final outcome = await classifyEmailSendCall(
        () async => throw const EmailProviderException(
          kind: EmailFailureKind.providerRateLimit,
          message: 'rate limited',
          statusCode: 429,
          retryAfter: Duration(seconds: 30),
        ),
      );
      expect(outcome, isA<EmailRateLimitError>());
      final rate = outcome as EmailRateLimitError;
      expect(rate.statusCode, 429);
      expect(rate.retryAfter, const Duration(seconds: 30));
    });

    test('SendGrid 503 → EmailTransientError (5xx maps to transient)',
        () async {
      final outcome = await classifyEmailSendCall(
        () async => throw const EmailProviderException(
          kind: EmailFailureKind.providerInternal,
          message: 'service unavailable',
          statusCode: 503,
        ),
      );
      expect(outcome, isA<EmailTransientError>());
      final transient = outcome as EmailTransientError;
      expect(transient.kind, EmailFailureKind.providerInternal);
      expect(transient.statusCode, 503);
    });

    test(
        'SendGrid 422 → EmailPermanentError (4xx other than 429 is '
        'non-retryable)', () async {
      final outcome = await classifyEmailSendCall(
        () async => throw const EmailProviderException(
          kind: EmailFailureKind.providerBadRequest,
          message: 'unprocessable entity',
          statusCode: 422,
        ),
      );
      expect(outcome, isA<EmailPermanentError>());
      final permanent = outcome as EmailPermanentError;
      expect(permanent.kind, EmailFailureKind.providerBadRequest);
      expect(permanent.statusCode, 422);
    });

    test('Timeout → EmailTransientError (network kind)', () async {
      final outcome = await classifyEmailSendCall(
        () async => throw TimeoutException('socket', const Duration(seconds: 30)),
      );
      expect(outcome, isA<EmailTransientError>());
      expect((outcome as EmailTransientError).kind, EmailFailureKind.network);
    });

    test(
        'dispatcher branch: 200 → EmailSent + status=sent + no '
        'failureKind on the outcome', () async {
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'l8-1',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'ok@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
        ),
      ]);
      final provider = _StubProvider(
        sendOutcomes: <_SendOutcome>[_SendOutcome.success('sg-msg-l8-1')],
      );
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: (_) {},
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );
      final outcomes = await dispatcher.drainBatch();
      expect(outcomes.single.statusKind, EmailDispatchStatusKind.sent);
      expect(outcomes.single.failureKind, isNull);
    });

    test(
        'dispatcher branch: 429 → pendingRetry with backoff + alert is '
        'NOT raised (retry semantics)', () async {
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'l8-2',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'ok@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
        ),
      ]);
      final provider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.failure(const EmailProviderException(
            kind: EmailFailureKind.providerRateLimit,
            message: 'too fast',
            statusCode: 429,
            retryAfter: Duration(seconds: 5),
          )),
        ],
      );
      final alerts = <EmailDispatchAlert>[];
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: alerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );
      final outcomes = await dispatcher.drainBatch();
      expect(outcomes.single.statusKind, EmailDispatchStatusKind.pendingRetry);
      expect(outcomes.single.failureKind, EmailFailureKind.providerRateLimit);
      expect(alerts, isEmpty,
          reason: '429 is retryable; no alert until retries exhaust');
    });

    test(
        'dispatcher branch: 503 → pendingRetry + retryable; same row at '
        'cap with 503 dead-letters', () async {
      // First attempt: row at attempt 0, 503 → pendingRetry.
      final firstRepo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'l8-3a',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'ok@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
        ),
      ]);
      final firstProvider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.failure(const EmailProviderException(
            kind: EmailFailureKind.providerInternal,
            message: '503 service unavailable',
            statusCode: 503,
          )),
        ],
      );
      final firstAlerts = <EmailDispatchAlert>[];
      final firstDispatcher = EmailOutboxDispatcher(
        provider: firstProvider,
        renderer: buildRenderer(),
        repository: firstRepo,
        alertSink: firstAlerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );
      final firstOutcomes = await firstDispatcher.drainBatch();
      expect(firstOutcomes.single.statusKind,
          EmailDispatchStatusKind.pendingRetry);
      expect(firstOutcomes.single.failureKind,
          EmailFailureKind.providerInternal);
      expect(firstAlerts, isEmpty);

      // Now drive the same row at attempt 2 (one before cap), 503 →
      // status = failed because nextAttempt = 3 == maxAttempts.
      final lastRepo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'l8-3b',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'ok@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 2,
        ),
      ]);
      final lastProvider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.failure(const EmailProviderException(
            kind: EmailFailureKind.providerInternal,
            message: '503 service unavailable',
            statusCode: 503,
          )),
        ],
      );
      final lastAlerts = <EmailDispatchAlert>[];
      final lastDispatcher = EmailOutboxDispatcher(
        provider: lastProvider,
        renderer: buildRenderer(),
        repository: lastRepo,
        alertSink: lastAlerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );
      final lastOutcomes = await lastDispatcher.drainBatch();
      expect(lastOutcomes.single.statusKind, EmailDispatchStatusKind.failed);
      expect(lastOutcomes.single.failureKind,
          EmailFailureKind.providerInternal);
      expect(lastAlerts, hasLength(1));
      expect(lastAlerts.single.failureKind,
          EmailFailureKind.providerInternal);
    });

    test(
        'dispatcher branch: 422 → failed on first attempt (permanent), '
        'no retry, alert raised once', () async {
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'l8-4',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'ok@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
        ),
      ]);
      final provider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.failure(const EmailProviderException(
            kind: EmailFailureKind.providerBadRequest,
            message: '422 unprocessable entity',
            statusCode: 422,
          )),
        ],
      );
      final alerts = <EmailDispatchAlert>[];
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: alerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );
      final outcomes = await dispatcher.drainBatch();
      expect(outcomes.single.statusKind, EmailDispatchStatusKind.failed);
      expect(outcomes.single.attemptCount, 1,
          reason: 'permanent → dead-letter on first failed attempt');
      expect(outcomes.single.failureKind,
          EmailFailureKind.providerBadRequest);
      expect(alerts, hasLength(1));
      expect(alerts.single.failureKind,
          EmailFailureKind.providerBadRequest);
      expect(provider.sendsAttempted, 1,
          reason: 'permanent kinds must NOT retry');
    });

    test(
        'failureKind on the outcome is set from the typed branch — '
        'the alert sink no longer reverse-engineers it from lastError',
        () async {
      // The deliberately cryptic `message` would NOT match the old
      // string-contains heuristics ("providerAuth"); the typed flow
      // surfaces the kind correctly anyway.
      final repo = _FakeRepo(<EmailOutboxRow>[
        const EmailOutboxRow(
          emailId: 'l8-5',
          templateId: EmailTemplateIds.operatorInviteFirstAdmin,
          recipientEmail: 'ok@example.com',
          templateData: <String, String>{'recipientName': 'Pat'},
          attemptCount: 0,
        ),
      ]);
      final provider = _StubProvider(
        sendOutcomes: <_SendOutcome>[
          _SendOutcome.failure(const EmailProviderException(
            kind: EmailFailureKind.providerAuth,
            // Message intentionally does NOT contain the literal
            // 'providerAuth' — the old heuristic would have classified
            // this as `unknown`.
            message: 'token rotated; please update credential',
            statusCode: 403,
          )),
        ],
      );
      final alerts = <EmailDispatchAlert>[];
      final dispatcher = EmailOutboxDispatcher(
        provider: provider,
        renderer: buildRenderer(),
        repository: repo,
        alertSink: alerts.add,
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );
      final outcomes = await dispatcher.drainBatch();
      expect(outcomes.single.failureKind, EmailFailureKind.providerAuth);
      expect(alerts.single.failureKind, EmailFailureKind.providerAuth);
    });
  });

  test('configurable maxAttempts honored', () async {
    final repo = _FakeRepo(<EmailOutboxRow>[
      const EmailOutboxRow(
        emailId: 'email-8',
        templateId: EmailTemplateIds.operatorInviteFirstAdmin,
        recipientEmail: 'admin@example.com',
        templateData: <String, String>{'recipientName': 'Pat'},
        attemptCount: 0,
      ),
    ]);
    final provider = _StubProvider(
      sendOutcomes: <_SendOutcome>[
        _SendOutcome.failure(const EmailProviderException(
          kind: EmailFailureKind.providerInternal,
          message: '500',
          statusCode: 502,
        )),
      ],
    );
    final alerts = <EmailDispatchAlert>[];
    // maxAttempts = 1 → first failure dead-letters.
    final dispatcher = EmailOutboxDispatcher(
      provider: provider,
      renderer: buildRenderer(),
      repository: repo,
      alertSink: alerts.add,
      fromAddress: 'noreply@mail.forgeflow.app',
      fromDisplayName: 'Forge & Flow',
      maxAttempts: 1,
    );

    final outcomes = await dispatcher.drainBatch();

    expect(outcomes.single.statusKind, EmailDispatchStatusKind.failed);
    expect(alerts, hasLength(1));
  });
}

/// In-memory [EmailOutboxRepository] used by the test suite. Holds
/// the rows that will be returned from the next claim and records
/// every outcome so assertions can inspect the recorded state.
class _FakeRepo implements EmailOutboxRepository {
  _FakeRepo(List<EmailOutboxRow> seed)
      : _pending = List<EmailOutboxRow>.from(seed);

  final List<EmailOutboxRow> _pending;
  final List<EmailDispatchOutcome> recorded = <EmailDispatchOutcome>[];

  @override
  Future<List<EmailOutboxRow>> claimPending(
      {required int batchSize}) async {
    final batch = _pending.take(batchSize).toList(growable: false);
    _pending.removeRange(0, batch.length);
    return batch;
  }

  @override
  Future<void> recordOutcome(EmailDispatchOutcome outcome) async {
    recorded.add(outcome);
  }
}

/// Test [EmailProvider] double that returns the next pre-canned
/// send outcome from the supplied list. `sendsAttempted` makes
/// it easy to assert that the provider was not called when the
/// dispatcher dead-letters before send.
class _StubProvider implements EmailProvider {
  _StubProvider({required this.sendOutcomes});

  final List<_SendOutcome> sendOutcomes;
  int sendsAttempted = 0;

  @override
  String get providerId => 'stub';

  @override
  Future<EmailSendResult> send(EmailSendRequest request) async {
    sendsAttempted += 1;
    if (sendOutcomes.isEmpty) {
      throw StateError('stub provider was called with no outcomes left');
    }
    final outcome = sendOutcomes.removeAt(0);
    if (outcome.success != null) {
      return outcome.success!;
    }
    throw outcome.failure!;
  }

  @override
  Future<EmailDeliveryStatus> getDeliveryStatus(
      String providerMessageId) async {
    throw UnimplementedError();
  }
}

class _SendOutcome {
  _SendOutcome.success(String messageId)
      : success = EmailSendResult(
          providerMessageId: messageId,
          acceptedAt: DateTime.utc(2026, 5, 4),
        ),
        failure = null;

  _SendOutcome.failure(EmailProviderException error)
      : success = null,
        failure = error;

  final EmailSendResult? success;
  final EmailProviderException? failure;
}
