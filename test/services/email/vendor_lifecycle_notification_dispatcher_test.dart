// Phase 8 V1.E lane — VendorLifecycleNotificationDispatcher tests.
//
// Drives the dispatcher against in-memory fake repositories to assert:
//
//   * Empty pending list → zero outbox rows.
//   * N pending notifications → N outbox rows + N fulfilment stamps.
//   * Re-dispatching the same vendor → no duplicate outbox rows.
//   * Cross-tenant isolation: operator A's pending rows do not leak
//     into operator B's fan-out.
//   * Non-`productionCredentialed` lifecycle state → no fan-out.
//   * Template rendering against the on-disk
//     `vendor_now_available.md` template — all variables substitute
//     and no em-dash (U+2014) leaks into the rendered subject / body.
//   * Outbox enqueue carries the vendor display name + business name
//     + integration console URL the template needs.
//   * Salutation falls back to the email local-part when no display
//     name is supplied.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/email/email_template_renderer.dart';

import '../../../tool/advisor_proxy/email_dispatch/notification_event_fanout.dart';
import '../../../tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart';

void main() {
  group('VendorLifecycleNotificationDispatcher.dispatchForVendor', () {
    test('empty pending list → zero outbox rows', () async {
      final notifications = _FakeNotificationRepo();
      final outbox = _FakeOutboxRepo(notifications);
      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver: _staticContextResolver(
          vendorDisplayName: 'Toast',
          businessName: 'Acme Bistro',
          integrationConsoleUrl: 'https://app.forgeflow.app/admin/integrations',
        ),
        now: () => DateTime.utc(2026, 5, 6, 12, 0),
      );

      final outcome = await dispatcher.dispatchForVendor(
        vendorId: 'toast',
        newLifecycleState: 'productionCredentialed',
      );

      expect(outcome.notificationsEnqueued, 0);
      expect(outcome.notificationsSkipped, 0);
      expect(outcome.operatorsTouched, 0);
      expect(outbox.enqueued, isEmpty);
      expect(notifications.markedNotified, isEmpty);
    });

    test(
      'three pending notifications → three outbox rows + three stamps',
      () async {
        final notifications = _FakeNotificationRepo()
          ..seedPending('op-1', 'toast', <_FakePending>[
            _FakePending(
              id: 'n-1',
              email: 'admin@acme.test',
              displayName: null,
            ),
            _FakePending(
              id: 'n-2',
              email: 'manager@acme.test',
              displayName: 'Manager Pat',
            ),
            _FakePending(id: 'n-3', email: 'gm@acme.test', displayName: null),
          ]);
        final outbox = _FakeOutboxRepo(notifications);
        final dispatcher = VendorLifecycleNotificationDispatcher(
          notificationRepository: notifications,
          outboxRepository: outbox,
          contextResolver: _staticContextResolver(
            vendorDisplayName: 'Toast',
            businessName: 'Acme Bistro',
            integrationConsoleUrl:
                'https://app.forgeflow.app/admin/integrations',
          ),
          now: () => DateTime.utc(2026, 5, 6, 12, 0),
        );

        final outcome = await dispatcher.dispatchForVendor(
          vendorId: 'toast',
          newLifecycleState: 'productionCredentialed',
        );

        expect(outcome.notificationsEnqueued, 3);
        expect(outcome.notificationsSkipped, 0);
        expect(outcome.operatorsTouched, 1);
        expect(outbox.enqueued, hasLength(3));
        expect(notifications.markedNotified, hasLength(3));
        // All three rows now report `notified_at != null`.
        for (final id in <String>['n-1', 'n-2', 'n-3']) {
          expect(notifications.isNotified(id), isTrue);
        }
        // Operator id is preserved on every outbox row (per-tenant
        // index leading column rule).
        for (final row in outbox.enqueued) {
          expect(row.operatorId, 'op-1');
          expect(row.templateId, EmailTemplateIds.vendorNowAvailable);
          expect(row.templateData['vendorName'], 'Toast');
          expect(row.templateData['businessName'], 'Acme Bistro');
          expect(
            row.templateData['integrationConsoleUrl'],
            'https://app.forgeflow.app/admin/integrations',
          );
          expect(row.templateData['recipientName'], isNotEmpty);
        }
      },
    );

    test('re-dispatch is idempotent (no duplicate outbox rows)', () async {
      final notifications = _FakeNotificationRepo()
        ..seedPending('op-1', 'toast', <_FakePending>[
          _FakePending(id: 'n-1', email: 'admin@acme.test'),
          _FakePending(id: 'n-2', email: 'manager@acme.test'),
          _FakePending(id: 'n-3', email: 'gm@acme.test'),
        ]);
      final outbox = _FakeOutboxRepo(notifications);
      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver: _staticContextResolver(
          vendorDisplayName: 'Toast',
          businessName: 'Acme Bistro',
          integrationConsoleUrl: 'https://app.forgeflow.app/admin/integrations',
        ),
      );

      final firstOutcome = await dispatcher.dispatchForVendor(
        vendorId: 'toast',
        newLifecycleState: 'productionCredentialed',
      );
      final secondOutcome = await dispatcher.dispatchForVendor(
        vendorId: 'toast',
        newLifecycleState: 'productionCredentialed',
      );

      expect(firstOutcome.notificationsEnqueued, 3);
      expect(secondOutcome.notificationsEnqueued, 0);
      expect(secondOutcome.operatorsTouched, 0);
      expect(outbox.enqueued, hasLength(3));
    });

    test(
      'concurrent claim loss is treated as a no-op, not a skipped send',
      () async {
        final notifications = _FakeNotificationRepo()
          ..seedPending('op-1', 'toast', <_FakePending>[
            _FakePending(id: 'n-1', email: 'admin@acme.test'),
          ]);
        final outbox = _RejectingClaimOutboxRepo();
        final dispatcher = VendorLifecycleNotificationDispatcher(
          notificationRepository: notifications,
          outboxRepository: outbox,
          contextResolver: _staticContextResolver(
            vendorDisplayName: 'Toast',
            businessName: 'Acme Bistro',
            integrationConsoleUrl:
                'https://app.forgeflow.app/admin/integrations',
          ),
        );

        final outcome = await dispatcher.dispatchForVendor(
          vendorId: 'toast',
          newLifecycleState: 'productionCredentialed',
        );

        expect(outcome.notificationsEnqueued, 0);
        expect(outcome.notificationsSkipped, 0);
        expect(notifications.isNotified('n-1'), isFalse);
      },
    );

    test('cross-tenant isolation: operator A → A only', () async {
      final notifications = _FakeNotificationRepo()
        ..seedPending('op-A', 'toast', <_FakePending>[
          _FakePending(id: 'a-1', email: 'a@acme.test'),
          _FakePending(id: 'a-2', email: 'a2@acme.test'),
        ])
        ..seedPending('op-B', 'toast', <_FakePending>[
          _FakePending(id: 'b-1', email: 'b@beta.test'),
        ]);
      final outbox = _FakeOutboxRepo(notifications);
      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver:
            ({required String operatorId, required String vendorId}) async {
              return VendorNotificationOperatorContext(
                operatorBusinessName: operatorId == 'op-A'
                    ? 'Acme Bistro'
                    : 'Beta Cafe',
                vendorDisplayName: 'Toast',
                integrationConsoleUrl:
                    'https://app.forgeflow.app/admin/integrations',
              );
            },
      );

      final outcome = await dispatcher.dispatchForVendor(
        vendorId: 'toast',
        newLifecycleState: 'productionCredentialed',
      );

      expect(outcome.operatorsTouched, 2);
      expect(outcome.notificationsEnqueued, 3);
      // Per-operator stamps did not bleed across tenants.
      final opARows = outbox.enqueued
          .where((row) => row.operatorId == 'op-A')
          .toList();
      final opBRows = outbox.enqueued
          .where((row) => row.operatorId == 'op-B')
          .toList();
      expect(opARows, hasLength(2));
      expect(opBRows, hasLength(1));
      expect(
        opARows.every(
          (row) => row.templateData['businessName'] == 'Acme Bistro',
        ),
        isTrue,
      );
      expect(
        opBRows.every((row) => row.templateData['businessName'] == 'Beta Cafe'),
        isTrue,
      );
      // markedNotified records carry the matching operator id.
      expect(
        notifications.markedNotifiedFor('op-A'),
        unorderedEquals(<String>['a-1', 'a-2']),
      );
      expect(
        notifications.markedNotifiedFor('op-B'),
        unorderedEquals(<String>['b-1']),
      );
    });

    test('non-productionCredentialed state → no fan-out', () async {
      final notifications = _FakeNotificationRepo()
        ..seedPending('op-1', 'toast', <_FakePending>[
          _FakePending(id: 'n-1', email: 'admin@acme.test'),
        ]);
      final outbox = _FakeOutboxRepo(notifications);
      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver: _staticContextResolver(
          vendorDisplayName: 'Toast',
          businessName: 'Acme Bistro',
          integrationConsoleUrl: 'https://app.forgeflow.app',
        ),
      );

      final earlierOutcomes = <VendorLifecycleNotificationDispatchOutcome>[];
      for (final state in <String>[
        'documented',
        'sandboxVerified',
        'liveWithOperators',
        '',
      ]) {
        earlierOutcomes.add(
          await dispatcher.dispatchForVendor(
            vendorId: 'toast',
            newLifecycleState: state,
          ),
        );
      }

      expect(
        earlierOutcomes.every((o) => o.notificationsEnqueued == 0),
        isTrue,
      );
      expect(outbox.enqueued, isEmpty);
      expect(notifications.markedNotified, isEmpty);
    });

    test('renders the on-disk vendor_now_available template '
        'with no em-dash leakage', () async {
      // Load the actual template + brand wrapper from the proxy
      // assets directory. Keeps copy-quality regressions caught by
      // the dispatcher test suite even though the renderer test
      // already iterates EmailTemplateIds.all.
      final templatesDir = Directory('tool/advisor_proxy/email_templates');
      final wrapper = File(
        '${templatesDir.path}/_brand_wrapper.html',
      ).readAsStringSync();
      final templates = <String, String>{};
      for (final id in EmailTemplateIds.all) {
        final file = File('${templatesDir.path}/$id.md');
        templates[id] = file.readAsStringSync();
      }
      final renderer = EmailTemplateRenderer(
        templateSource: EmailTemplateRenderer.fromMap(templates),
        brandWrapperSource: EmailTemplateRenderer.fromString(wrapper),
      );

      // Sample data the dispatcher would build for a real send.
      final rendered = renderer.render(
        templateId: EmailTemplateIds.vendorNowAvailable,
        templateData: <String, String>{
          'vendorName': 'Toast',
          'businessName': 'Acme Bistro',
          'integrationConsoleUrl':
              'https://app.forgeflow.app/admin/integrations',
          'recipientName': 'Pat',
        },
      );

      // Subject + bodies must render with all variables substituted.
      expect(rendered.subject, contains('Toast'));
      expect(rendered.subject, isNot(contains('{{')));
      expect(rendered.htmlBody, contains('Toast'));
      expect(rendered.htmlBody, contains('Acme Bistro'));
      expect(
        rendered.htmlBody,
        contains('https://app.forgeflow.app/admin/integrations'),
      );
      expect(rendered.textBody, isNot(contains('{{')));

      // Em-dash check: the codepoint U+2014 must NOT appear anywhere
      // in the rendered subject, plain-text body, or HTML body. The
      // V1.E prompt bans em-dashes in operator-facing copy.
      const emDash = '—';
      expect(rendered.subject, isNot(contains(emDash)));
      expect(rendered.textBody, isNot(contains(emDash)));
      expect(rendered.htmlBody, isNot(contains(emDash)));
      // Also reject the literal "—" character (same codepoint, but
      // assert against the literal so a future encoding-change
      // regression still fails this guard).
      expect(rendered.subject, isNot(contains('—')));
      expect(rendered.textBody, isNot(contains('—')));
    });

    test(
      'salutation falls back to email local-part when no display name',
      () async {
        final notifications = _FakeNotificationRepo()
          ..seedPending('op-1', 'toast', <_FakePending>[
            _FakePending(id: 'n-1', email: 'pat.manager@acme.test'),
          ]);
        final outbox = _FakeOutboxRepo(notifications);
        final dispatcher = VendorLifecycleNotificationDispatcher(
          notificationRepository: notifications,
          outboxRepository: outbox,
          contextResolver: _staticContextResolver(
            vendorDisplayName: 'Toast',
            businessName: 'Acme Bistro',
            integrationConsoleUrl: 'https://app.forgeflow.app',
          ),
        );

        await dispatcher.dispatchForVendor(
          vendorId: 'toast',
          newLifecycleState: 'productionCredentialed',
        );

        expect(
          outbox.enqueued.single.templateData['recipientName'],
          'pat.manager',
        );
      },
    );

    test('per-row enqueue failure leaves the row pending for retry', () async {
      final notifications = _FakeNotificationRepo()
        ..seedPending('op-1', 'toast', <_FakePending>[
          _FakePending(id: 'n-good', email: 'a@acme.test'),
          _FakePending(id: 'n-bad', email: 'b@acme.test'),
        ]);
      final outbox = _FakeOutboxRepo(
        notifications,
        failOnRecipientEmails: <String>{'b@acme.test'},
      );
      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver: _staticContextResolver(
          vendorDisplayName: 'Toast',
          businessName: 'Acme Bistro',
          integrationConsoleUrl: 'https://app.forgeflow.app',
        ),
      );

      final outcome = await dispatcher.dispatchForVendor(
        vendorId: 'toast',
        newLifecycleState: 'productionCredentialed',
      );

      expect(outcome.notificationsEnqueued, 1);
      expect(outcome.notificationsSkipped, 1);
      expect(notifications.isNotified('n-good'), isTrue);
      expect(notifications.isNotified('n-bad'), isFalse);
    });

    test('delegates to NotificationEventFanout for notif.vendor.now_available '
        'when an eventFanout is wired', () async {
      // Phase 8 W2.B refactor: when the dispatcher is wired with a
      // fanout seam, every per-operator pending batch fires the
      // multi-channel fanout for notif.vendor.now_available so push +
      // inbox channels layer on top of the legacy email path.
      // Existing email-only callers continue to work because
      // eventFanout is optional.
      final notifications = _FakeNotificationRepo()
        ..seedPending('op-1', 'toast', <_FakePending>[
          _FakePending(id: 'n-1', email: 'admin@acme.test'),
        ])
        ..seedPending('op-2', 'toast', <_FakePending>[
          _FakePending(id: 'n-2', email: 'admin@beta.test'),
        ]);
      final outbox = _FakeOutboxRepo(notifications);
      final fanoutCalls = <_RecordedFanoutCall>[];

      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver: _staticContextResolver(
          vendorDisplayName: 'Toast',
          businessName: 'Acme Bistro',
          integrationConsoleUrl: 'https://app.forgeflow.app',
        ),
        eventFanout:
            ({
              required String operatorId,
              required NotificationEventEnvelope envelope,
            }) async {
              fanoutCalls.add(
                _RecordedFanoutCall(operatorId: operatorId, envelope: envelope),
              );
              return NotificationFanoutOutcome(
                eventKey: envelope.eventKey,
                usersConsidered: 0,
                usersGated: 0,
                pushDispatched: 0,
                emailDispatched: 0,
                inboxDispatched: 0,
                skipped: 0,
              );
            },
      );

      final outcome = await dispatcher.dispatchForVendor(
        vendorId: 'toast',
        newLifecycleState: 'productionCredentialed',
      );

      // Email path still runs.
      expect(outcome.notificationsEnqueued, 2);
      // Fanout fires once per operator that had pending email rows.
      expect(fanoutCalls, hasLength(2));
      expect(
        fanoutCalls.every(
          (c) => c.envelope.eventKey == 'notif.vendor.now_available',
        ),
        isTrue,
      );
      expect(
        fanoutCalls.first.envelope.dedupeKeyPrefix,
        startsWith('notif.vendor.now_available:'),
      );
      expect(
        fanoutCalls.first.envelope.emailTemplateData['vendorName'],
        'Toast',
      );
    });

    test('fanout failure does not block the email path', () async {
      final notifications = _FakeNotificationRepo()
        ..seedPending('op-1', 'toast', <_FakePending>[
          _FakePending(id: 'n-1', email: 'admin@acme.test'),
        ]);
      final outbox = _FakeOutboxRepo(notifications);
      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver: _staticContextResolver(
          vendorDisplayName: 'Toast',
          businessName: 'Acme Bistro',
          integrationConsoleUrl: 'https://app.forgeflow.app',
        ),
        eventFanout:
            ({
              required String operatorId,
              required NotificationEventEnvelope envelope,
            }) async {
              throw StateError('seeded fanout failure');
            },
      );

      final outcome = await dispatcher.dispatchForVendor(
        vendorId: 'toast',
        newLifecycleState: 'productionCredentialed',
      );

      expect(outcome.notificationsEnqueued, 1);
      expect(outbox.enqueued, hasLength(1));
    });

    test('context resolver failure leaves the operator pending', () async {
      final notifications = _FakeNotificationRepo()
        ..seedPending('op-broken', 'toast', <_FakePending>[
          _FakePending(id: 'n-broken-1', email: 'a@acme.test'),
          _FakePending(id: 'n-broken-2', email: 'b@acme.test'),
        ])
        ..seedPending('op-healthy', 'toast', <_FakePending>[
          _FakePending(id: 'n-healthy-1', email: 'c@beta.test'),
        ]);
      final outbox = _FakeOutboxRepo(notifications);
      final dispatcher = VendorLifecycleNotificationDispatcher(
        notificationRepository: notifications,
        outboxRepository: outbox,
        contextResolver:
            ({required String operatorId, required String vendorId}) async {
              if (operatorId == 'op-broken') {
                throw StateError('vendor catalog miss');
              }
              return const VendorNotificationOperatorContext(
                operatorBusinessName: 'Beta Cafe',
                vendorDisplayName: 'Toast',
                integrationConsoleUrl: 'https://app.forgeflow.app',
              );
            },
      );

      final outcome = await dispatcher.dispatchForVendor(
        vendorId: 'toast',
        newLifecycleState: 'productionCredentialed',
      );

      // op-broken's two rows skipped; op-healthy's one row enqueued.
      expect(outcome.notificationsEnqueued, 1);
      expect(outcome.notificationsSkipped, 2);
      expect(outcome.operatorsTouched, 2);
      expect(outbox.enqueued.single.operatorId, 'op-healthy');
      expect(notifications.isNotified('n-broken-1'), isFalse);
      expect(notifications.isNotified('n-broken-2'), isFalse);
      expect(notifications.isNotified('n-healthy-1'), isTrue);
    });
  });
}

// ───────────────────────────────────────────────────────────────────
// Test doubles.
// ───────────────────────────────────────────────────────────────────

VendorNotificationContextResolver _staticContextResolver({
  required String vendorDisplayName,
  required String businessName,
  required String integrationConsoleUrl,
}) {
  return ({required String operatorId, required String vendorId}) async {
    return VendorNotificationOperatorContext(
      operatorBusinessName: businessName,
      vendorDisplayName: vendorDisplayName,
      integrationConsoleUrl: integrationConsoleUrl,
    );
  };
}

class _FakePending {
  _FakePending({required this.id, required this.email, this.displayName});

  final String id;
  final String email;
  final String? displayName;
  bool notified = false;
}

class _FakeNotificationRepo
    implements VendorLifecycleNotificationReadRepository {
  final Map<String, Map<String, List<_FakePending>>> _byOperator =
      <String, Map<String, List<_FakePending>>>{};
  final Map<String, List<String>> _markedByOperator = <String, List<String>>{};

  void seedPending(
    String operatorId,
    String vendorId,
    List<_FakePending> rows,
  ) {
    final byVendor = _byOperator.putIfAbsent(
      operatorId,
      () => <String, List<_FakePending>>{},
    );
    byVendor.putIfAbsent(vendorId, () => <_FakePending>[]).addAll(rows);
  }

  Iterable<String> get markedNotified =>
      _markedByOperator.values.expand((rows) => rows);

  Iterable<String> markedNotifiedFor(String operatorId) =>
      _markedByOperator[operatorId] ?? const <String>[];

  bool tryClaim(PendingVendorNotification notification) {
    final byVendor =
        _byOperator[notification.operatorId] ??
        const <String, List<_FakePending>>{};
    final rows = byVendor[notification.vendorId] ?? const <_FakePending>[];
    for (final row in rows) {
      if (row.id == notification.notificationId) {
        if (row.notified) return false;
        row.notified = true;
        _markedByOperator
            .putIfAbsent(notification.operatorId, () => <String>[])
            .add(notification.notificationId);
        return true;
      }
    }
    return false;
  }

  bool isNotified(String notificationId) {
    for (final byVendor in _byOperator.values) {
      for (final rows in byVendor.values) {
        for (final row in rows) {
          if (row.id == notificationId) return row.notified;
        }
      }
    }
    return false;
  }

  @override
  Future<List<String>> pendingOperatorIdsForVendor({
    required String vendorId,
  }) async {
    final ids = <String>[];
    for (final entry in _byOperator.entries) {
      final rows = entry.value[vendorId] ?? const <_FakePending>[];
      if (rows.any((row) => !row.notified)) {
        ids.add(entry.key);
      }
    }
    ids.sort();
    return ids;
  }

  @override
  Future<List<PendingVendorNotification>> fetchPendingForVendor({
    required String operatorId,
    required String vendorId,
  }) async {
    final rows = _byOperator[operatorId]?[vendorId] ?? const <_FakePending>[];
    return rows
        .where((row) => !row.notified)
        .map(
          (row) => PendingVendorNotification(
            notificationId: row.id,
            operatorId: operatorId,
            vendorId: vendorId,
            recipientEmail: row.email,
            recipientDisplayName: row.displayName,
          ),
        )
        .toList(growable: false);
  }
}

class _RecordedFanoutCall {
  _RecordedFanoutCall({required this.operatorId, required this.envelope});
  final String operatorId;
  final NotificationEventEnvelope envelope;
}

class _RecordedEnqueue {
  _RecordedEnqueue({
    required this.operatorId,
    required this.templateId,
    required this.recipientEmail,
    required this.recipientDisplayName,
    required this.templateData,
  });

  final String operatorId;
  final String templateId;
  final String recipientEmail;
  final String? recipientDisplayName;
  final Map<String, String> templateData;
}

class _FakeOutboxRepo implements EmailOutboxEnqueueRepository {
  _FakeOutboxRepo(
    _FakeNotificationRepo notifications, {
    Set<String> failOnRecipientEmails = const <String>{},
  }) : _notifications = notifications,
       _failOnRecipientEmails = failOnRecipientEmails;

  final _FakeNotificationRepo _notifications;
  final Set<String> _failOnRecipientEmails;
  final List<_RecordedEnqueue> enqueued = <_RecordedEnqueue>[];

  @override
  Future<bool> claimAndEnqueue({
    required PendingVendorNotification notification,
    required String templateId,
    required String? recipientDisplayName,
    required Map<String, String> templateData,
    required DateTime stampedAt,
  }) async {
    if (_failOnRecipientEmails.contains(notification.recipientEmail)) {
      throw StateError(
        'seeded enqueue failure for ${notification.recipientEmail}',
      );
    }
    if (!_notifications.tryClaim(notification)) {
      return false;
    }
    enqueued.add(
      _RecordedEnqueue(
        operatorId: notification.operatorId,
        templateId: templateId,
        recipientEmail: notification.recipientEmail,
        recipientDisplayName: recipientDisplayName,
        templateData: Map<String, String>.from(templateData),
      ),
    );
    return true;
  }
}

class _RejectingClaimOutboxRepo implements EmailOutboxEnqueueRepository {
  @override
  Future<bool> claimAndEnqueue({
    required PendingVendorNotification notification,
    required String templateId,
    required String? recipientDisplayName,
    required Map<String, String> templateData,
    required DateTime stampedAt,
  }) async {
    return false;
  }
}
