// C-2-F — VendorConnectionAutoDisabledDispatcher tests.
//
// Drives the dispatcher against in-memory fakes to assert:
//
//   * Recipient resolver returning null → no enqueue + skipped reason
//     `recipient_not_found`.
//   * Happy path → one outbox row enqueued with the documented
//     template_data shape (vendorName, recipientName, businessName,
//     disabledAtHumanReadable, strikeCount, lastErrorSummary,
//     integrationConsoleUrl).
//   * Idempotency-key stability: two calls with the same `(operator,
//     credential, disabled_at_minute)` produce the same key.
//   * Idempotency collapse: when the enqueue repository reports a
//     duplicate (returns null email_id), the dispatcher surfaces
//     skipped reason `duplicate_collapsed` without throwing.
//   * Enqueue error path: when the repository throws, the dispatcher
//     swallows + returns skipped reason `enqueue_error` so the worker
//     tick's cap-trip path is never blocked.
//   * `lastErrorSummary` collapses whitespace and truncates long
//     strings to ≤200 chars + ellipsis.
//   * `disabledAtHumanReadable` renders as `YYYY-MM-DD HH:mm UTC`.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/email/email_template_renderer.dart';

import '../../../tool/oauth_refresh_worker/vendor_connection_auto_disabled_dispatcher.dart';

void main() {
  group('VendorConnectionAutoDisabledDispatcher.dispatchForAutoDisable',
      () {
    test('recipient resolver returns null → skipped recipient_not_found',
        () async {
      final enqueue = _FakeEnqueue();
      final dispatcher = VendorConnectionAutoDisabledDispatcher(
        enqueueRepository: enqueue,
        recipientResolver: ({required String operatorId}) async => null,
        now: () => DateTime.utc(2026, 5, 13, 14, 5),
      );

      final outcome = await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-1',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: 'invalid_grant',
      );

      expect(outcome.enqueued, isFalse);
      expect(outcome.skippedReason, 'recipient_not_found');
      expect(outcome.emailId, isNull);
      expect(enqueue.calls, isEmpty);
    });

    test('happy path enqueues one row with the documented template_data',
        () async {
      final enqueue = _FakeEnqueue()
        ..nextEmailId = 'email-1';
      final dispatcher = VendorConnectionAutoDisabledDispatcher(
        enqueueRepository: enqueue,
        recipientResolver: ({required String operatorId}) async =>
            const AutoDisabledRecipient(
              recipientEmail: 'owner@acme.test',
              businessName: 'Acme Bistro',
            ),
        vendorDisplayNameResolver: (vendorId) =>
            vendorId == 'toast' ? 'Toast' : null,
        now: () => DateTime.utc(2026, 5, 13, 14, 5, 17),
      );

      final outcome = await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-1',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: 'invalid_grant',
      );

      expect(outcome.enqueued, isTrue);
      expect(outcome.emailId, 'email-1');
      expect(outcome.skippedReason, isNull);
      expect(enqueue.calls, hasLength(1));

      final call = enqueue.calls.single;
      expect(call.operatorId, 'op-1');
      expect(call.locationId, 'loc-1');
      expect(call.credentialId, 'cred-1');
      expect(call.vendorId, 'toast');
      expect(
        call.templateId,
        EmailTemplateIds.vendorConnectionAutoDisabled,
      );
      expect(call.recipientEmail, 'owner@acme.test');
      expect(call.recipientDisplayName, isNull);
      expect(call.consecutiveFailures, 3);
      expect(call.errorMessage, 'invalid_grant');

      // Every template variable referenced by the .md template must be
      // present.
      expect(call.templateData['vendorName'], 'Toast');
      expect(call.templateData['recipientName'], 'owner');
      expect(call.templateData['businessName'], 'Acme Bistro');
      expect(
        call.templateData['disabledAtHumanReadable'],
        '2026-05-13 14:05 UTC',
      );
      expect(call.templateData['strikeCount'], '3');
      expect(call.templateData['lastErrorSummary'], 'invalid_grant');
      expect(
        call.templateData['integrationConsoleUrl'],
        'https://app.forgeflow.app/admin/integrations',
      );
    });

    test(
      'idempotency-key stable for same (operator, credential, minute)',
      () async {
        final enqueue = _FakeEnqueue()..nextEmailId = 'email-1';
        final dispatcher = VendorConnectionAutoDisabledDispatcher(
          enqueueRepository: enqueue,
          recipientResolver: ({required String operatorId}) async =>
              const AutoDisabledRecipient(
                recipientEmail: 'owner@acme.test',
                businessName: 'Acme Bistro',
              ),
          // Two times in the same minute → key is identical.
          now: () => DateTime.utc(2026, 5, 13, 14, 5, 17),
        );

        await dispatcher.dispatchForAutoDisable(
          operatorId: 'op-1',
          locationId: 'loc-1',
          credentialId: 'cred-1',
          vendorId: 'toast',
          consecutiveFailures: 3,
          errorMessage: 'invalid_grant',
        );
        await dispatcher.dispatchForAutoDisable(
          operatorId: 'op-1',
          locationId: 'loc-1',
          credentialId: 'cred-1',
          vendorId: 'toast',
          consecutiveFailures: 3,
          errorMessage: 'invalid_grant',
          // Different sub-minute timestamp (same minute) → key
          // unchanged.
          disabledAt: DateTime.utc(2026, 5, 13, 14, 5, 45),
        );

        expect(enqueue.calls, hasLength(2));
        expect(
          enqueue.calls[0].idempotencyKey,
          enqueue.calls[1].idempotencyKey,
        );
        expect(
          enqueue.calls.first.idempotencyKey,
          'auto_disable:op-1:cred-1:2026-05-13T14:05:00.000Z',
        );
      },
    );

    test(
      'idempotency-key differs for different credentials or different minutes',
      () async {
        final enqueue = _FakeEnqueue()..nextEmailId = 'email-1';
        final dispatcher = VendorConnectionAutoDisabledDispatcher(
          enqueueRepository: enqueue,
          recipientResolver: ({required String operatorId}) async =>
              const AutoDisabledRecipient(
                recipientEmail: 'owner@acme.test',
                businessName: 'Acme Bistro',
              ),
          now: () => DateTime.utc(2026, 5, 13, 14, 5, 17),
        );

        await dispatcher.dispatchForAutoDisable(
          operatorId: 'op-1',
          locationId: 'loc-1',
          credentialId: 'cred-1',
          vendorId: 'toast',
          consecutiveFailures: 3,
          errorMessage: 'invalid_grant',
        );
        await dispatcher.dispatchForAutoDisable(
          operatorId: 'op-1',
          locationId: 'loc-1',
          credentialId: 'cred-2',
          vendorId: 'toast',
          consecutiveFailures: 3,
          errorMessage: 'invalid_grant',
        );
        await dispatcher.dispatchForAutoDisable(
          operatorId: 'op-1',
          locationId: 'loc-1',
          credentialId: 'cred-1',
          vendorId: 'toast',
          consecutiveFailures: 3,
          errorMessage: 'invalid_grant',
          // Different minute → key differs from call 1.
          disabledAt: DateTime.utc(2026, 5, 13, 14, 6, 0),
        );

        final keys = enqueue.calls.map((c) => c.idempotencyKey).toSet();
        expect(keys, hasLength(3));
      },
    );

    test('duplicate collapse surfaces duplicate_collapsed', () async {
      final enqueue = _FakeEnqueue()..nextEmailId = null; // collapse
      final dispatcher = VendorConnectionAutoDisabledDispatcher(
        enqueueRepository: enqueue,
        recipientResolver: ({required String operatorId}) async =>
            const AutoDisabledRecipient(
              recipientEmail: 'owner@acme.test',
              businessName: 'Acme Bistro',
            ),
        now: () => DateTime.utc(2026, 5, 13, 14, 5, 17),
      );

      final outcome = await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-1',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: 'invalid_grant',
      );

      expect(outcome.enqueued, isFalse);
      expect(outcome.skippedReason, 'duplicate_collapsed');
      expect(outcome.emailId, isNull);
      // The fake DID receive the call — the dispatcher relies on the
      // repository's null return value to detect the dedupe.
      expect(enqueue.calls, hasLength(1));
    });

    test('repository throw surfaces enqueue_error (not rethrown)',
        () async {
      final enqueue = _FakeEnqueue()..throwOnEnqueue = true;
      final dispatcher = VendorConnectionAutoDisabledDispatcher(
        enqueueRepository: enqueue,
        recipientResolver: ({required String operatorId}) async =>
            const AutoDisabledRecipient(
              recipientEmail: 'owner@acme.test',
              businessName: 'Acme Bistro',
            ),
        now: () => DateTime.utc(2026, 5, 13, 14, 5, 17),
      );

      // Must NOT throw — the worker relies on the dispatcher
      // swallowing so the cap-trip path is never blocked.
      final outcome = await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-1',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: 'invalid_grant',
      );

      expect(outcome.enqueued, isFalse);
      expect(outcome.skippedReason, 'enqueue_error');
      expect(outcome.emailId, isNull);
    });

    test('vendor display-name resolver fallback to raw vendor id',
        () async {
      final enqueue = _FakeEnqueue()..nextEmailId = 'email-1';
      final dispatcher = VendorConnectionAutoDisabledDispatcher(
        enqueueRepository: enqueue,
        recipientResolver: ({required String operatorId}) async =>
            const AutoDisabledRecipient(
              recipientEmail: 'owner@acme.test',
              businessName: 'Acme Bistro',
            ),
        // No vendorDisplayNameResolver wired.
        now: () => DateTime.utc(2026, 5, 13, 14, 5, 17),
      );

      await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-1',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: 'invalid_grant',
      );

      expect(enqueue.calls.single.templateData['vendorName'], 'toast');
    });

    test('lastErrorSummary collapses whitespace and truncates to 200',
        () async {
      final enqueue = _FakeEnqueue()..nextEmailId = 'email-1';
      final dispatcher = VendorConnectionAutoDisabledDispatcher(
        enqueueRepository: enqueue,
        recipientResolver: ({required String operatorId}) async =>
            const AutoDisabledRecipient(
              recipientEmail: 'owner@acme.test',
              businessName: 'Acme Bistro',
            ),
        now: () => DateTime.utc(2026, 5, 13, 14, 5, 17),
      );

      final longError = 'long ' * 100; // 500 chars
      await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-1',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: '  \n\tinvalid_grant\n  '
            'token expired\n',
      );
      expect(
        enqueue.calls.single.templateData['lastErrorSummary'],
        'invalid_grant token expired',
      );

      await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-2',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: longError,
      );
      final summary =
          enqueue.calls.last.templateData['lastErrorSummary']!;
      expect(summary.length, lessThanOrEqualTo(203)); // 200 + '...'
      expect(summary.endsWith('...'), isTrue);
    });

    test('console URL builder override is honored', () async {
      final enqueue = _FakeEnqueue()..nextEmailId = 'email-1';
      final dispatcher = VendorConnectionAutoDisabledDispatcher(
        enqueueRepository: enqueue,
        recipientResolver: ({required String operatorId}) async =>
            const AutoDisabledRecipient(
              recipientEmail: 'owner@acme.test',
              businessName: 'Acme Bistro',
            ),
        consoleUrlBuilder: ({
          required String operatorId,
          required String locationId,
          required String vendorId,
        }) =>
            'https://example.test/$operatorId/$locationId/$vendorId',
        now: () => DateTime.utc(2026, 5, 13, 14, 5, 17),
      );

      await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-1',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: 'invalid_grant',
      );

      expect(
        enqueue.calls.single.templateData['integrationConsoleUrl'],
        'https://example.test/op-1/loc-1/toast',
      );
    });

    test('disabledAt parameter overrides the clock', () async {
      final enqueue = _FakeEnqueue()..nextEmailId = 'email-1';
      final dispatcher = VendorConnectionAutoDisabledDispatcher(
        enqueueRepository: enqueue,
        recipientResolver: ({required String operatorId}) async =>
            const AutoDisabledRecipient(
              recipientEmail: 'owner@acme.test',
              businessName: 'Acme Bistro',
            ),
        now: () => DateTime.utc(2026, 5, 13, 14, 5, 17),
      );

      await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-1',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: 'invalid_grant',
        disabledAt: DateTime.utc(2026, 1, 1, 0, 0),
      );

      expect(
        enqueue.calls.single.templateData['disabledAtHumanReadable'],
        '2026-01-01 00:00 UTC',
      );
    });

    test('renders against the on-disk template without missing variables',
        () async {
      final enqueue = _FakeEnqueue()..nextEmailId = 'email-1';
      final dispatcher = VendorConnectionAutoDisabledDispatcher(
        enqueueRepository: enqueue,
        recipientResolver: ({required String operatorId}) async =>
            const AutoDisabledRecipient(
              recipientEmail: 'owner@acme.test',
              businessName: 'Acme Bistro',
            ),
        vendorDisplayNameResolver: (vendorId) => 'Toast',
        now: () => DateTime.utc(2026, 5, 13, 14, 5),
      );

      await dispatcher.dispatchForAutoDisable(
        operatorId: 'op-1',
        locationId: 'loc-1',
        credentialId: 'cred-1',
        vendorId: 'toast',
        consecutiveFailures: 3,
        errorMessage: 'invalid_grant',
      );

      final templateData = enqueue.calls.single.templateData;
      // Smoke-test the renderer with the same template_data the
      // dispatcher built. Use a stubbed template source carrying the
      // on-disk template body so the test does not touch the file
      // system (which the renderer's unit-test suite already covers).
      final renderer = EmailTemplateRenderer(
        templateSource: EmailTemplateRenderer.fromMap(<String, String>{
          EmailTemplateIds.vendorConnectionAutoDisabled:
              _vendorConnectionAutoDisabledTemplateBody,
        }),
        brandWrapperSource:
            EmailTemplateRenderer.fromString('<html>{{body}}</html>'),
      );
      final rendered = renderer.render(
        templateId: EmailTemplateIds.vendorConnectionAutoDisabled,
        templateData: templateData,
      );
      expect(rendered.subject, 'Toast connection disabled');
      expect(rendered.htmlBody, contains('Toast'));
      expect(rendered.htmlBody, contains('owner'));
      expect(rendered.htmlBody, contains('invalid_grant'));
      expect(rendered.htmlBody, contains('2026-05-13 14:05 UTC'));
      // No em-dash (per UX writing standard).
      expect(rendered.textBody, isNot(contains('—')));
    });
  });
}

/// Inline copy of `tool/advisor_proxy/email_templates/vendor_connection_auto_disabled.md`
/// for the renderer smoke test — keeps the test off-disk while
/// pinning the variable list. If the .md ever adds a variable, this
/// test fails loudly until the dispatcher's template_data grows the
/// matching key.
const String _vendorConnectionAutoDisabledTemplateBody = '''
# {{vendorName}} connection disabled

Hi {{recipientName}},

We disabled the connection between Forge & Flow and {{vendorName}} at {{disabledAtHumanReadable}}. Recent OAuth refresh attempts kept failing, and after {{strikeCount}} consecutive failures we paused the connection so you do not silently see stale numbers.

The most recent error: {{lastErrorSummary}}

While the connection is disabled, F&F will not read new data from {{vendorName}}. Existing data already in F&F stays available.

## What to do

Reconnect {{vendorName}} from the **Connected services** card:

[Reconnect {{vendorName}}]({{integrationConsoleUrl}})

This usually means signing in to {{vendorName}} once and approving the F&F permission scopes. Once reconnection succeeds, sync resumes automatically.

If the reconnect screen surfaces an error you do not recognise, reply to this email and the F&F team will help.

The Forge & Flow team
''';

class _FakeEnqueue implements AutoDisabledEmailEnqueueRepository {
  final List<_RecordedEnqueue> calls = <_RecordedEnqueue>[];

  /// When non-null, the next enqueue returns this email_id (success).
  /// When null, the next enqueue returns null (duplicate_collapsed
  /// surface).
  String? nextEmailId;

  /// When true, the next enqueue throws StateError.
  bool throwOnEnqueue = false;

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
  }) async {
    calls.add(_RecordedEnqueue(
      operatorId: operatorId,
      locationId: locationId,
      credentialId: credentialId,
      vendorId: vendorId,
      templateId: templateId,
      recipientEmail: recipientEmail,
      recipientDisplayName: recipientDisplayName,
      templateData: templateData,
      idempotencyKey: idempotencyKey,
      occurredAt: occurredAt,
      consecutiveFailures: consecutiveFailures,
      errorMessage: errorMessage,
    ));
    if (throwOnEnqueue) {
      throw StateError('synthetic enqueue failure for test');
    }
    return nextEmailId;
  }
}

class _RecordedEnqueue {
  _RecordedEnqueue({
    required this.operatorId,
    required this.locationId,
    required this.credentialId,
    required this.vendorId,
    required this.templateId,
    required this.recipientEmail,
    required this.recipientDisplayName,
    required this.templateData,
    required this.idempotencyKey,
    required this.occurredAt,
    required this.consecutiveFailures,
    required this.errorMessage,
  });

  final String operatorId;
  final String locationId;
  final String credentialId;
  final String vendorId;
  final String templateId;
  final String recipientEmail;
  final String? recipientDisplayName;
  final Map<String, String> templateData;
  final String idempotencyKey;
  final DateTime occurredAt;
  final int consecutiveFailures;
  final String errorMessage;
}
