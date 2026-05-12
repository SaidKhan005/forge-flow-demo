// Phase 8 W2.B - NotificationEventFanout tests.
//
// Drives the fanout against in-memory fakes for the user
// directory + preference seam + per-channel dispatch seams. Asserts:
//
//   * Empty user directory -> zero dispatches.
//   * Unknown event_key -> zero dispatches (rolling-deploy safety).
//   * Catalog default channels apply when no preference row exists.
//   * `enabled = false` preference row opts the user out of a
//     channel that the catalog default would otherwise admit.
//   * `enabled = true` preference row admits a channel the catalog
//     default does NOT include (operator opted in).
//   * Location-scoped row beats operator-scoped row for the same
//     channel.
//   * Admin-only events skip non-admin users; manager-only events
//     skip non-manager users.
//   * Idempotent retry: a second fanOut call with the same envelope
//     reuses the stable dedupe key so a UNIQUE-backed seam can
//     collapse duplicates.
//   * Email channel respects user's email-on-file (skips when null).
//   * Each channel's payload carries the right shape.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/models/notification_preference.dart';
import 'package:forge_and_flow/services/observability/log.dart';

import '../../../tool/advisor_proxy/email_dispatch/notification_event_fanout.dart';

void main() {
  group('NotificationEventFanout.fanOut', () {
    test('empty user directory -> zero dispatches', () async {
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => const [],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );

      expect(outcome.usersConsidered, 0);
      expect(pushes.calls, isEmpty);
      expect(emails.calls, isEmpty);
    });

    test('unknown event_key -> no-op', () async {
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: const NotificationEventEnvelope(
          eventKey: 'notif.unknown.event',
          dedupeKeyPrefix: 'notif.unknown.event:op-1',
          pushTitle: 't',
          pushBody: 'b',
          emailTemplateId: 'unknown',
          emailTemplateData: <String, String>{},
        ),
      );

      expect(outcome.usersConsidered, 0);
      expect(pushes.calls, isEmpty);
      expect(emails.calls, isEmpty);
    });

    test('catalog defaults apply when no preference row exists', () async {
      // notif.backfill.complete defaults to push + email, role gate
      // is "any". With no preference rows, the user gets both.
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );

      expect(outcome.pushDispatched, 1);
      expect(outcome.emailDispatched, 1);
      expect(outcome.inboxDispatched, 0);
      expect(pushes.calls.single.userId, 'user-1');
      expect(emails.calls.single.recipientEmail, 'admin@acme.test');
      // Salutation derived from email local-part.
      expect(emails.calls.single.templateData['recipientName'], 'admin');
    });

    test('enabled=false preference opts user out of a default channel',
        () async {
      // User opts out of email; push remains via catalog default.
      final prefs = _FakePrefSeam(rows: <NotificationPreferenceRow>[
        const NotificationPreferenceRow(
          userId: 'user-1',
          channel: NotificationChannel.email,
          scopeKind: NotificationScopeKind.operator,
          scopeId: null,
          enabled: false,
        ),
      ]);
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );

      expect(outcome.pushDispatched, 1);
      expect(outcome.emailDispatched, 0);
      expect(emails.calls, isEmpty);
    });

    test('enabled=true admits a channel the catalog default omits',
        () async {
      // notif.backfill.complete catalog default = {push, email}.
      // User explicitly opts in to inbox.
      final prefs = _FakePrefSeam(rows: <NotificationPreferenceRow>[
        const NotificationPreferenceRow(
          userId: 'user-1',
          channel: NotificationChannel.inbox,
          scopeKind: NotificationScopeKind.operator,
          scopeId: null,
          enabled: true,
        ),
      ]);
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );

      expect(outcome.inboxDispatched, 1);
      // The inbox-routed payload reuses the push seam by default
      // (production binds both to mobile_push_outbox.enqueue).
      // Among the 3 push-seam calls (1 push + 1 inbox), the inbox
      // one carries data['inbox'] == true.
      expect(pushes.calls.length, 2);
      final inboxCall =
          pushes.calls.firstWhere((p) => p.routesToInbox);
      expect(inboxCall.data['inbox'], true);
      expect(inboxCall.dedupeKey,
          equals('notif.backfill.complete:op-1:job-x:user-1:inbox'));
    });

    test('location-scoped row beats operator-scoped row', () async {
      // notif.backfill.complete catalog default = {push, email}.
      // Operator-scope preference: email = enabled.
      // Location-scope preference (matching user's location): email = false.
      final prefs = _FakePrefSeam(rows: <NotificationPreferenceRow>[
        const NotificationPreferenceRow(
          userId: 'user-1',
          channel: NotificationChannel.email,
          scopeKind: NotificationScopeKind.operator,
          scopeId: null,
          enabled: true,
        ),
        const NotificationPreferenceRow(
          userId: 'user-1',
          channel: NotificationChannel.email,
          scopeKind: NotificationScopeKind.location,
          scopeId: 'loc-1',
          enabled: false,
        ),
      ]);
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );

      expect(outcome.emailDispatched, 0);
      expect(emails.calls, isEmpty);
    });

    test('admin-only events skip non-admin users', () async {
      // notif.audit.anchor_failure is roleGate=adminOnly.
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
          // Manager - not admin.
          const FanoutUser(
            userId: 'user-2',
            locationId: 'loc-1',
            roles: <String>{'operator_manager'},
            email: 'manager@acme.test',
          ),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: const NotificationEventEnvelope(
          eventKey: 'notif.audit.anchor_failure',
          dedupeKeyPrefix: 'notif.audit.anchor_failure:op-1:2026-05-06',
          pushTitle: 'Audit chain anchor needs review',
          pushBody: 'A daily anchor did not land.',
          emailTemplateId: 'audit_anchor_failure',
          emailTemplateData: <String, String>{},
        ),
      );

      expect(outcome.usersGated, 1);
      expect(outcome.pushDispatched, 1);
      expect(outcome.emailDispatched, 1);
      expect(pushes.calls.single.userId, 'user-1');
      expect(emails.calls.single.recipientEmail, 'admin@acme.test');
    });

    test('manager-only events skip non-manager users', () async {
      // notif.shift.stale is roleGate=managerOnly.
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          // Owner - manager-set.
          const FanoutUser(
            userId: 'user-1',
            locationId: 'loc-1',
            roles: <String>{'operator_owner'},
            email: 'owner@acme.test',
          ),
          // Random user with no manager role.
          const FanoutUser(
            userId: 'user-2',
            locationId: 'loc-1',
            roles: <String>{'kitchen_lead'},
            email: 'lead@acme.test',
          ),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: const NotificationEventEnvelope(
          eventKey: 'notif.shift.stale',
          dedupeKeyPrefix: 'notif.shift.stale:op-1:shift-1',
          pushTitle: 'Open-shift snapshot stale',
          pushBody: 'No fresh covers.',
          emailTemplateId: 'shift_stale',
          emailTemplateData: <String, String>{},
        ),
      );

      expect(outcome.usersGated, 1);
      // notif.shift.stale catalog default = {push} only (no email).
      expect(outcome.pushDispatched, 1);
      expect(outcome.emailDispatched, 0);
      expect(pushes.calls.single.userId, 'user-1');
    });

    test('idempotent dedupe key: same envelope -> same key', () async {
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );
      await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );

      // Two calls; same dedupe key on each. Production-side UNIQUE
      // collapses these to one row; the fake records both.
      expect(pushes.calls, hasLength(2));
      expect(pushes.calls[0].dedupeKey, pushes.calls[1].dedupeKey);
      expect(
        pushes.calls[0].dedupeKey,
        'notif.backfill.complete:op-1:job-x:user-1:push',
      );
      expect(emails.calls, hasLength(2));
      expect(
        emails.calls[0].idempotencyKey,
        emails.calls[1].idempotencyKey,
      );
      expect(
        emails.calls[0].idempotencyKey,
        'notif.backfill.complete:op-1:job-x:user-1:email',
      );
    });

    test('email channel skips when user has no email on file', () async {
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          const FanoutUser(
            userId: 'user-1',
            locationId: 'loc-1',
            roles: <String>{'operator_owner'},
            email: null,
          ),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );

      expect(outcome.pushDispatched, 1);
      expect(outcome.emailDispatched, 0);
      expect(outcome.skipped, 1);
      expect(emails.calls, isEmpty);
    });

    test('per-channel payload shape', () async {
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );

      final push = pushes.calls.single;
      expect(push.operatorId, 'op-1');
      expect(push.userId, 'user-1');
      expect(push.locationId, 'loc-1');
      expect(push.title, 'Historical sync complete');
      expect(push.body, contains('60-day historical seed'));
      expect(push.data['event_key'], 'notif.backfill.complete');
      expect(push.data['vendor_id'], 'toast');
      expect(push.routesToInbox, isFalse);

      final email = emails.calls.single;
      expect(email.operatorId, 'op-1');
      expect(email.userId, 'user-1');
      expect(email.recipientEmail, 'admin@acme.test');
      expect(email.templateId, 'backfill_complete');
      expect(email.templateData['vendorId'], 'toast');
      expect(email.templateData['recipientName'], 'admin');
    });

    test('per-(user, channel) seam failure counts as skipped', () async {
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam(failOnUserId: 'user-1');
      final emails = _RecordingEmailSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-1',
        envelope: _backfillCompleteEnvelope(),
      );

      expect(outcome.pushDispatched, 0);
      expect(outcome.skipped, 1);
      // Email path still runs.
      expect(outcome.emailDispatched, 1);
    });
  });

  // ---------------------------------------------------------------
  // B3 hot-fix coverage (silent-swallow site -> structured log).
  // Source: docs/_decisions/post_codex_wave_decisions_addendum_2026-05-12.md
  // Block B, B3.
  // ---------------------------------------------------------------
  group('NotificationEventFanout - B3 structured log', () {
    test('email-side dispatch failure emits '
        'notification.fanout.email_render_failed', () async {
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam(
        failOnTemplateId: 'unknown_template_id',
      );
      final logs = _RecordingLogSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
        logSeam: logs.seam,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-9',
        envelope: const NotificationEventEnvelope(
          eventKey: 'notif.backfill.complete',
          dedupeKeyPrefix: 'notif.backfill.complete:op-9:job-1',
          pushTitle: 'Historical sync complete',
          pushBody: 'done',
          emailTemplateId: 'unknown_template_id',
          emailTemplateData: <String, String>{},
        ),
      );

      // Push still flows; email fails, counted as skipped.
      expect(outcome.pushDispatched, 1);
      expect(outcome.emailDispatched, 0);
      expect(outcome.skipped, 1);

      // Exactly one structured log line emitted for the email-side
      // failure; previously the catch (_) swallowed it.
      final emailFailureLogs = logs.records
          .where((r) => r.event == 'notification.fanout.email_render_failed')
          .toList();
      expect(emailFailureLogs, hasLength(1));
      final record = emailFailureLogs.single;
      expect(record.severity, LogSeverity.error);
      expect(record.fields['event_kind'], 'notif.backfill.complete');
      expect(record.fields['template_id'], 'unknown_template_id');
      expect(record.fields['operator_id'], 'op-9');
      expect(record.fields['user_id'], 'user-1');
      expect(record.fields['channel'], 'email');
      // Error type + first stack frame both present.
      expect(record.fields['error.runtimeType'], isNotEmpty);
      expect(record.fields['stack_first_frame'], isNotEmpty);
    });

    test('unknown event_key emits '
        'notification.fanout.unknown_event_key', () async {
      final prefs = _FakePrefSeam();
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final logs = _RecordingLogSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
        logSeam: logs.seam,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-2',
        envelope: const NotificationEventEnvelope(
          eventKey: 'notif.unknown.thing',
          dedupeKeyPrefix: 'notif.unknown.thing:op-2:x',
          pushTitle: 't',
          pushBody: 'b',
          emailTemplateId: 'ghost_template',
          emailTemplateData: <String, String>{},
        ),
      );

      expect(outcome.usersConsidered, 0);
      final unknown = logs.records
          .where((r) => r.event == 'notification.fanout.unknown_event_key')
          .toList();
      expect(unknown, hasLength(1));
      expect(unknown.single.severity, LogSeverity.warning);
      expect(unknown.single.fields['event_kind'], 'notif.unknown.thing');
      expect(unknown.single.fields['template_id'], 'ghost_template');
      expect(unknown.single.fields['operator_id'], 'op-2');
    });

    test('successful fanout dispatches all admitted channels for '
        'registered template ids (B3 regression)', () async {
      // Drives the now-registered backfill_complete envelope all the
      // way through. Adds inbox via an explicit opt-in preference so
      // we exercise push + email + inbox in one pass.
      final prefs = _FakePrefSeam(rows: <NotificationPreferenceRow>[
        const NotificationPreferenceRow(
          userId: 'user-1',
          channel: NotificationChannel.inbox,
          scopeKind: NotificationScopeKind.operator,
          scopeId: null,
          enabled: true,
        ),
      ]);
      final pushes = _RecordingPushSeam();
      final emails = _RecordingEmailSeam();
      final logs = _RecordingLogSeam();
      final fanout = NotificationEventFanout(
        preferenceReadSeam: prefs,
        userDirectory: ({required String operatorId}) async => <FanoutUser>[
          _adminUser(),
        ],
        pushDispatch: pushes.dispatch,
        emailDispatch: emails.dispatch,
        logSeam: logs.seam,
      );

      final outcome = await fanout.fanOut(
        operatorId: 'op-3',
        envelope: _backfillCompleteEnvelope(),
      );

      expect(outcome.pushDispatched, 1);
      expect(outcome.emailDispatched, 1);
      expect(outcome.inboxDispatched, 1);
      expect(outcome.skipped, 0);
      // Happy path: zero failure log lines.
      expect(
        logs.records.where(
          (r) => r.event == 'notification.fanout.email_render_failed',
        ),
        isEmpty,
      );
    });
  });
}

NotificationEventEnvelope _backfillCompleteEnvelope() {
  return const NotificationEventEnvelope(
    eventKey: 'notif.backfill.complete',
    dedupeKeyPrefix: 'notif.backfill.complete:op-1:job-x',
    pushTitle: 'Historical sync complete',
    pushBody:
        'Your 60-day historical seed has finished and the connector is '
        'now live.',
    emailTemplateId: 'backfill_complete',
    emailTemplateData: <String, String>{
      'vendorId': 'toast',
      'connectionId': 'conn-1',
      'locationId': 'loc-1',
    },
    pushData: <String, Object?>{
      'vendor_id': 'toast',
      'connection_id': 'conn-1',
    },
  );
}

FanoutUser _adminUser() => const FanoutUser(
      userId: 'user-1',
      locationId: 'loc-1',
      roles: <String>{'operator_owner', 'operator_admin'},
      email: 'admin@acme.test',
    );

class _FakePrefSeam implements NotificationPreferenceReadSeam {
  _FakePrefSeam({List<NotificationPreferenceRow>? rows})
      : _rows = rows ?? const <NotificationPreferenceRow>[];

  final List<NotificationPreferenceRow> _rows;

  @override
  Future<List<NotificationPreferenceRow>> listForOperatorEvent({
    required String operatorId,
    required String eventKey,
  }) async {
    return _rows;
  }
}

class _RecordingPushSeam {
  _RecordingPushSeam({this.failOnUserId});
  final String? failOnUserId;
  final List<FanoutPushPayload> calls = <FanoutPushPayload>[];

  Future<void> dispatch(FanoutPushPayload payload) async {
    if (failOnUserId != null && payload.userId == failOnUserId) {
      throw StateError('seeded push failure for ${payload.userId}');
    }
    calls.add(payload);
  }
}

class _RecordingEmailSeam {
  _RecordingEmailSeam({this.failOnTemplateId});

  /// When set, dispatch throws an [ArgumentError] for any payload
  /// carrying this template id - simulating the renderer's
  /// "Unknown templateId" exception that previously got swallowed
  /// by the fanout's silent `catch (_)`.
  final String? failOnTemplateId;
  final List<FanoutEmailPayload> calls = <FanoutEmailPayload>[];

  Future<void> dispatch(FanoutEmailPayload payload) async {
    if (failOnTemplateId != null &&
        payload.templateId == failOnTemplateId) {
      throw ArgumentError('Unknown templateId: ${payload.templateId}');
    }
    calls.add(payload);
  }
}

/// Captures every log call the fanout makes through its log seam.
/// Mirrors the [log] signature so wiring is a no-op for tests.
class _RecordingLogSeam {
  final List<_LoggedRecord> records = <_LoggedRecord>[];

  void seam(
    LogSeverity severity,
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    records.add(_LoggedRecord(
      severity: severity,
      event: event,
      fields: Map<String, Object?>.from(fields),
    ));
  }
}

class _LoggedRecord {
  _LoggedRecord({
    required this.severity,
    required this.event,
    required this.fields,
  });

  final LogSeverity severity;
  final String event;
  final Map<String, Object?> fields;
}
