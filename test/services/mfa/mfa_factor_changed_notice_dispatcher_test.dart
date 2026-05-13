// C-2-C wire — MfaFactorChangedNoticeDispatcher tests.
//
// Drives the dispatcher against in-memory recording seams to assert:
//
//   * Happy path: one email_outbox row + one audit row, both with the
//     locked template id + event_key, both addressed to the supplied
//     user, both stamped with a stable idempotency_key in the audit
//     payload.
//   * Idempotency-key stability: re-running the dispatcher with the
//     same (userId, factorId, removedAt) produces an identical
//     idempotency_key.
//   * Outbox row shape: template_data carries every variable the
//     renderer needs (recipientName, occurredAtHumanReadable,
//     changeDescription, accountSecurityUrl); no extra keys leak in.
//   * Audit row shape: actor-kind 'system' is the worker's
//     responsibility (the audit seam in this dispatcher is the
//     `insertSystemEventOn` shape), but the dispatcher must pass the
//     correct operator/location/user + event_type +
//     event_key/template_id/factor_id/factor_kind payload keys.
//   * Recipient resolution: display-name preferred, then email
//     local-part, then literal "there".
//   * Skip on blank recipient: a defensively-empty email skips the
//     enqueue + audit and returns the skipped outcome.

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/services/mfa/mfa_factor_changed_notice_dispatcher.dart';

const String _operatorId = '11111111-1111-4111-8111-111111111111';
const String _locationId = '22222222-2222-4222-8222-222222222222';
const String _userId = '33333333-3333-4333-8333-333333333333';
const String _factorId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const String _accountSecurityUrl =
    'https://app.forgeflow.app/account/security';

void main() {
  group('MfaFactorChangedNoticeDispatcher.dispatchForRemoval', () {
    test(
      'happy path: one outbox row + one audit row with the locked '
      'template id + event_key',
      () async {
        final outbox = _RecordingOutbox();
        final audit = _RecordingAudit();
        final dispatcher = MfaFactorChangedNoticeDispatcher(
          outboxEnqueue: outbox.enqueue,
          auditEmit: audit.emit,
          accountSecurityUrl: _accountSecurityUrl,
          now: () => DateTime.utc(2026, 5, 1, 13, 30),
        );

        final outcome = await dispatcher.dispatchForRemoval(
          _FakeExecutor(),
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          factorId: _factorId,
          factorKind: 'totp',
          factorLabel: '',
          recipientEmail: 'gm@acme.test',
          recipientDisplayName: 'Pat GM',
          removedAt: DateTime.utc(2026, 5, 1, 12, 15),
        );

        expect(outcome.enqueued, isTrue);
        expect(outcome.skippedReason, isNull);

        expect(outbox.calls, hasLength(1));
        final row = outbox.calls.single;
        expect(row.operatorId, equals(_operatorId));
        expect(row.userId, equals(_userId));
        expect(row.recipientEmail, equals('gm@acme.test'));
        expect(row.recipientDisplayName, equals('Pat GM'));
        expect(row.templateId, equals('mfa_factor_changed_notice'));
        expect(
          row.templateData['recipientName'],
          equals('Pat GM'),
          reason: 'display name preferred over email local-part',
        );
        expect(
          row.templateData['occurredAtHumanReadable'],
          equals('2026-05-01 12:15 UTC'),
          reason: 'UTC stamp must match the renderer sample-data shape',
        );
        expect(
          row.templateData['changeDescription'],
          equals('Authenticator app removed'),
          reason: 'totp factor without a label → plain copy',
        );
        expect(
          row.templateData['accountSecurityUrl'],
          equals(_accountSecurityUrl),
        );
        // The dispatcher must not leak extra keys that the renderer
        // does not declare — a stray variable would round-trip
        // through the renderer's MissingTemplateVariableError defense
        // only on rename, but the test pins the exact set today.
        expect(
          row.templateData.keys.toSet(),
          equals(<String>{
            'recipientName',
            'occurredAtHumanReadable',
            'changeDescription',
            'accountSecurityUrl',
          }),
        );

        expect(audit.calls, hasLength(1));
        final auditCall = audit.calls.single;
        expect(auditCall.operatorId, equals(_operatorId));
        expect(auditCall.locationId, equals(_locationId));
        expect(auditCall.userId, equals(_userId));
        expect(
          auditCall.eventType,
          equals('mfa_factor_changed_email_enqueued'),
        );
        expect(
          auditCall.payload['event_key'],
          equals('notif.mfa.factor_changed'),
        );
        expect(
          auditCall.payload['template_id'],
          equals('mfa_factor_changed_notice'),
        );
        expect(auditCall.payload['factor_id'], equals(_factorId));
        expect(auditCall.payload['factor_kind'], equals('totp'));
        expect(
          auditCall.payload['change_description'],
          equals('Authenticator app removed'),
        );
        expect(auditCall.payload['recipient_email_present'], isTrue);
        expect(
          auditCall.payload['occurred_at'],
          equals('2026-05-01T12:15:00.000Z'),
        );
        expect(
          auditCall.payload['enqueued_at'],
          equals('2026-05-01T13:30:00.000Z'),
        );
      },
    );

    test('idempotency-key is stable per (userId, factorId, removedAt)',
        () async {
      // The dispatcher composes the idempotency_key from the
      // (userId, factorId, removedAt) tuple. Re-running with the
      // same tuple must produce the same key so future reconciliation
      // tooling can detect retries.
      final outbox1 = _RecordingOutbox();
      final audit1 = _RecordingAudit();
      final dispatcher1 = MfaFactorChangedNoticeDispatcher(
        outboxEnqueue: outbox1.enqueue,
        auditEmit: audit1.emit,
        accountSecurityUrl: _accountSecurityUrl,
        now: () => DateTime.utc(2026, 5, 1, 13),
      );
      await dispatcher1.dispatchForRemoval(
        _FakeExecutor(),
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
        factorId: _factorId,
        factorKind: 'totp',
        factorLabel: '',
        recipientEmail: 'gm@acme.test',
        recipientDisplayName: null,
        removedAt: DateTime.utc(2026, 5, 1, 12),
      );
      final key1 = audit1.calls.single.payload['idempotency_key'];

      final outbox2 = _RecordingOutbox();
      final audit2 = _RecordingAudit();
      final dispatcher2 = MfaFactorChangedNoticeDispatcher(
        outboxEnqueue: outbox2.enqueue,
        auditEmit: audit2.emit,
        accountSecurityUrl: _accountSecurityUrl,
        // Different `now()` — should not influence the key (only
        // removedAt does).
        now: () => DateTime.utc(2026, 6, 1, 10),
      );
      await dispatcher2.dispatchForRemoval(
        _FakeExecutor(),
        operatorId: _operatorId,
        locationId: _locationId,
        userId: _userId,
        factorId: _factorId,
        factorKind: 'totp',
        factorLabel: '',
        recipientEmail: 'gm@acme.test',
        recipientDisplayName: null,
        removedAt: DateTime.utc(2026, 5, 1, 12),
      );
      final key2 = audit2.calls.single.payload['idempotency_key'];

      expect(key1, isA<String>());
      expect(key1, equals(key2));
      expect(
        key1,
        equals('notif.mfa.factor_changed:$_userId:$_factorId:'
            '2026-05-01T12:00:00.000Z'),
      );
    });

    test(
      'idempotency-key changes when removedAt changes (parallel '
      'completion of two different requests for the same factor cannot '
      'collapse)',
      () async {
        final outbox = _RecordingOutbox();
        final audit = _RecordingAudit();
        final dispatcher = MfaFactorChangedNoticeDispatcher(
          outboxEnqueue: outbox.enqueue,
          auditEmit: audit.emit,
          accountSecurityUrl: _accountSecurityUrl,
          now: () => DateTime.utc(2026, 5, 1, 12),
        );

        await dispatcher.dispatchForRemoval(
          _FakeExecutor(),
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          factorId: _factorId,
          factorKind: 'totp',
          factorLabel: '',
          recipientEmail: 'gm@acme.test',
          recipientDisplayName: null,
          removedAt: DateTime.utc(2026, 5, 1, 12),
        );
        await dispatcher.dispatchForRemoval(
          _FakeExecutor(),
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          factorId: _factorId,
          factorKind: 'totp',
          factorLabel: '',
          recipientEmail: 'gm@acme.test',
          recipientDisplayName: null,
          removedAt: DateTime.utc(2026, 5, 2, 12),
        );

        expect(audit.calls, hasLength(2));
        expect(
          audit.calls[0].payload['idempotency_key'],
          isNot(equals(audit.calls[1].payload['idempotency_key'])),
        );
      },
    );

    test(
      'recipient salutation falls back to the email local-part when '
      'no display name is supplied',
      () async {
        final outbox = _RecordingOutbox();
        final audit = _RecordingAudit();
        final dispatcher = MfaFactorChangedNoticeDispatcher(
          outboxEnqueue: outbox.enqueue,
          auditEmit: audit.emit,
          accountSecurityUrl: _accountSecurityUrl,
          now: () => DateTime.utc(2026, 5, 1, 12),
        );

        await dispatcher.dispatchForRemoval(
          _FakeExecutor(),
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          factorId: _factorId,
          factorKind: 'totp',
          factorLabel: '',
          recipientEmail: 'pat.gm@acme.test',
          recipientDisplayName: null,
          removedAt: DateTime.utc(2026, 5, 1, 12),
        );

        expect(
          outbox.calls.single.templateData['recipientName'],
          equals('pat.gm'),
        );
      },
    );

    test(
      'recipient salutation falls back to "there" when display name '
      'is whitespace and email local-part is empty',
      () async {
        final outbox = _RecordingOutbox();
        final audit = _RecordingAudit();
        final dispatcher = MfaFactorChangedNoticeDispatcher(
          outboxEnqueue: outbox.enqueue,
          auditEmit: audit.emit,
          accountSecurityUrl: _accountSecurityUrl,
          now: () => DateTime.utc(2026, 5, 1, 12),
        );

        await dispatcher.dispatchForRemoval(
          _FakeExecutor(),
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          factorId: _factorId,
          factorKind: 'totp',
          factorLabel: '',
          recipientEmail: '@acme.test',
          recipientDisplayName: '   ',
          removedAt: DateTime.utc(2026, 5, 1, 12),
        );

        expect(
          outbox.calls.single.templateData['recipientName'],
          equals('there'),
        );
      },
    );

    test(
      'blank recipient email → skipped outcome, no outbox row, '
      'no audit row',
      () async {
        final outbox = _RecordingOutbox();
        final audit = _RecordingAudit();
        final dispatcher = MfaFactorChangedNoticeDispatcher(
          outboxEnqueue: outbox.enqueue,
          auditEmit: audit.emit,
          accountSecurityUrl: _accountSecurityUrl,
          now: () => DateTime.utc(2026, 5, 1, 12),
        );

        final outcome = await dispatcher.dispatchForRemoval(
          _FakeExecutor(),
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          factorId: _factorId,
          factorKind: 'totp',
          factorLabel: '',
          recipientEmail: '   ',
          recipientDisplayName: 'Pat GM',
          removedAt: DateTime.utc(2026, 5, 1, 12),
        );

        expect(outcome.enqueued, isFalse);
        expect(outcome.skippedReason, equals('recipient_email_blank'));
        expect(outbox.calls, isEmpty);
        expect(audit.calls, isEmpty);
      },
    );

    test(
      'changeDescription branches on factorKind — totp with label, '
      'recovery_code, and unknown all stay plain English',
      () async {
        final outbox = _RecordingOutbox();
        final audit = _RecordingAudit();
        final dispatcher = MfaFactorChangedNoticeDispatcher(
          outboxEnqueue: outbox.enqueue,
          auditEmit: audit.emit,
          accountSecurityUrl: _accountSecurityUrl,
          now: () => DateTime.utc(2026, 5, 1, 12),
        );

        // totp + label
        await dispatcher.dispatchForRemoval(
          _FakeExecutor(),
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          factorId: _factorId,
          factorKind: 'totp',
          factorLabel: 'iPhone 14',
          recipientEmail: 'gm@acme.test',
          recipientDisplayName: null,
          removedAt: DateTime.utc(2026, 5, 1, 12),
        );
        expect(
          outbox.calls.last.templateData['changeDescription'],
          equals('Authenticator app removed (iPhone 14)'),
        );

        // recovery_code
        await dispatcher.dispatchForRemoval(
          _FakeExecutor(),
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          factorId: _factorId,
          factorKind: 'recovery_code',
          factorLabel: '',
          recipientEmail: 'gm@acme.test',
          recipientDisplayName: null,
          removedAt: DateTime.utc(2026, 5, 1, 12),
        );
        expect(
          outbox.calls.last.templateData['changeDescription'],
          equals('Recovery codes were revoked'),
        );

        // unknown
        await dispatcher.dispatchForRemoval(
          _FakeExecutor(),
          operatorId: _operatorId,
          locationId: _locationId,
          userId: _userId,
          factorId: _factorId,
          factorKind: 'webauthn',
          factorLabel: 'YubiKey 5',
          recipientEmail: 'gm@acme.test',
          recipientDisplayName: null,
          removedAt: DateTime.utc(2026, 5, 1, 12),
        );
        expect(
          outbox.calls.last.templateData['changeDescription'],
          equals('A two-factor method was removed (YubiKey 5)'),
        );
      },
    );
  });
}

// ─── Recording seams ──────────────────────────────────────────────

class _OutboxCall {
  const _OutboxCall({
    required this.operatorId,
    required this.userId,
    required this.recipientEmail,
    required this.recipientDisplayName,
    required this.templateId,
    required this.templateData,
  });

  final String operatorId;
  final String userId;
  final String recipientEmail;
  final String? recipientDisplayName;
  final String templateId;
  final Map<String, String> templateData;
}

class _RecordingOutbox {
  final calls = <_OutboxCall>[];

  Future<void> enqueue(
    PostgresExecutor exec, {
    required String operatorId,
    required String userId,
    required String recipientEmail,
    required String? recipientDisplayName,
    required String templateId,
    required Map<String, String> templateData,
  }) async {
    calls.add(_OutboxCall(
      operatorId: operatorId,
      userId: userId,
      recipientEmail: recipientEmail,
      recipientDisplayName: recipientDisplayName,
      templateId: templateId,
      templateData: Map<String, String>.unmodifiable(templateData),
    ));
  }
}

class _AuditCall {
  const _AuditCall({
    required this.operatorId,
    required this.locationId,
    required this.userId,
    required this.eventType,
    required this.payload,
  });

  final String operatorId;
  final String locationId;
  final String userId;
  final String eventType;
  final Map<String, Object?> payload;
}

class _RecordingAudit {
  final calls = <_AuditCall>[];

  Future<void> emit(
    PostgresExecutor exec, {
    required String operatorId,
    required String locationId,
    required String userId,
    required String eventType,
    required Map<String, Object?> payload,
  }) async {
    calls.add(_AuditCall(
      operatorId: operatorId,
      locationId: locationId,
      userId: userId,
      eventType: eventType,
      payload: Map<String, Object?>.unmodifiable(payload),
    ));
  }
}

class _FakeExecutor implements PostgresExecutor {
  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    throw StateError(
      'unexpected query in dispatcher test — recording seams capture '
      'effects directly: $sql',
    );
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    throw StateError(
      'unexpected execute in dispatcher test — recording seams capture '
      'effects directly: $sql',
    );
  }
}
