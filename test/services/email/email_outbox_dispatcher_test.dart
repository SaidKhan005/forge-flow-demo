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
