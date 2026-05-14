// Wave 2 U-FU-tier-email — Operator tier-email route tests.
//
// Mirrors the sibling-router test patterns
// (`operator_benchmark_overrides_routes_test.dart`):
//   * Handle-level tests for happy path, idempotency replay,
//     idempotency conflict, body validation, and email send failure.
//   * The route's HTTP-level auth + role + permission boilerplate is
//     reused verbatim from the proven sibling pattern; the handle-
//     level surface is what we exercise here.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/email/email_provider.dart';

import '../../tool/advisor_proxy/operator_routes.dart';
import '../../tool/advisor_proxy/operator_tier_email_routes.dart';

void main() {
  const operatorId = '22222222-2222-4222-8222-222222222222';
  const actorUserId = '11111111-1111-4111-8111-111111111111';
  const operatorName = 'Test Operator Inc.';

  group('OperatorTierEmailRouter — handle()', () {
    test('matches the canonical POST path only', () {
      expect(
        OperatorTierEmailRouter.matches(
          operatorTierEmailDataFreshnessRequestPath,
          'POST',
        ),
        isTrue,
      );
      expect(
        OperatorTierEmailRouter.matches(
          operatorTierEmailDataFreshnessRequestPath,
          'GET',
        ),
        isFalse,
      );
      expect(
        OperatorTierEmailRouter.matches('/v1/some/other/route', 'POST'),
        isFalse,
      );
    });

    test('happy path: writes audit row + sends email + returns 200',
        () async {
      final emailProvider = _RecordingEmailProvider();
      final audit = _RecordingAuditSink();
      final router = OperatorTierEmailRouter(
        emailProvider: emailProvider,
        auditSink: audit,
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
        now: () => DateTime.utc(2026, 5, 14, 12),
        auditRowIdFactory: () => 'audit-row-1',
      );

      final result = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-happy',
        body: const <String, Object?>{
          'current_tier': 'Standard',
          'requested_cadence': 'Faster than current tier',
          'business_reason': 'Dinner rush needs under-a-minute awareness.',
        },
      );

      expect(result.statusCode, 200);
      expect(result.body['ok'], true);
      expect(result.body['audit_row_id'], 'audit-row-1');
      expect(result.body['provider_message_id'], 'fake-msg-1');

      expect(audit.events, hasLength(1));
      expect(
        audit.events.single['eventKind'],
        kOperatorTierEmailAuditEventKind,
      );
      final payload = audit.events.single['payload'] as Map<String, Object?>;
      expect(payload['current_tier'], 'Standard');
      expect(payload['requested_cadence'], 'Faster than current tier');
      expect(payload['recipient'], 'support@forgeflow.org');
      expect(payload['audit_row_id'], 'audit-row-1');

      expect(emailProvider.sends, hasLength(1));
      final sent = emailProvider.sends.single;
      expect(sent.to.email, 'support@forgeflow.org');
      expect(sent.subject, contains('Test Operator Inc.'));
      expect(sent.subject, contains(operatorId));
      expect(sent.textBody, contains('Current tier: Standard'));
      expect(
        sent.textBody,
        contains('Business reason: Dinner rush needs under-a-minute awareness.'),
      );
      expect(sent.fromAddress, 'noreply@forgeflow.app');
      expect(sent.providerMetadata['audit_row_id'], 'audit-row-1');
    });

    test('idempotency replay: same key + same body returns identical envelope',
        () async {
      final emailProvider = _RecordingEmailProvider();
      final audit = _RecordingAuditSink();
      final router = OperatorTierEmailRouter(
        emailProvider: emailProvider,
        auditSink: audit,
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
        idempotencyCache: OperatorWriteIdempotencyCache(),
      );

      const body = <String, Object?>{
        'current_tier': 'Standard',
        'requested_cadence': 'Faster',
        'business_reason': 'A reason',
      };
      final first = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-replay',
        body: body,
      );
      final second = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-replay',
        body: Map<String, Object?>.from(body),
      );

      expect(first.statusCode, 200);
      expect(second.statusCode, 200);
      expect(first.body, equals(second.body));
      // The compute path runs exactly once — replay returns the
      // cached envelope without re-emailing or re-auditing.
      expect(audit.events, hasLength(1));
      expect(emailProvider.sends, hasLength(1));
    });

    test('idempotency conflict: same key + different body returns 409',
        () async {
      final router = OperatorTierEmailRouter(
        emailProvider: _RecordingEmailProvider(),
        auditSink: _RecordingAuditSink(),
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-1',
        body: const <String, Object?>{
          'current_tier': 'Standard',
          'requested_cadence': 'A',
          'business_reason': 'B',
        },
      );
      final conflict = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-1',
        body: const <String, Object?>{
          'current_tier': 'Standard',
          'requested_cadence': 'A',
          'business_reason': 'DIFFERENT',
        },
      );

      expect(conflict.statusCode, 409);
      expect(conflict.body['error'], 'idempotency_key_conflict');
    });

    test('missing current_tier returns 400 without writing audit / sending',
        () async {
      final emailProvider = _RecordingEmailProvider();
      final audit = _RecordingAuditSink();
      final router = OperatorTierEmailRouter(
        emailProvider: emailProvider,
        auditSink: audit,
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final result = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-bad-body',
        body: const <String, Object?>{
          'requested_cadence': 'Faster',
          'business_reason': 'A reason',
        },
      );

      expect(result.statusCode, 400);
      expect(result.body['error'], 'missing_current_tier');
      expect(audit.events, isEmpty);
      expect(emailProvider.sends, isEmpty);
    });

    test('missing requested_cadence returns 400', () async {
      final router = OperatorTierEmailRouter(
        emailProvider: _RecordingEmailProvider(),
        auditSink: _RecordingAuditSink(),
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final result = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-bad-2',
        body: const <String, Object?>{
          'current_tier': 'Standard',
          'business_reason': 'A reason',
        },
      );

      expect(result.statusCode, 400);
      expect(result.body['error'], 'missing_requested_cadence');
    });

    test('missing business_reason returns 400', () async {
      final router = OperatorTierEmailRouter(
        emailProvider: _RecordingEmailProvider(),
        auditSink: _RecordingAuditSink(),
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final result = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-bad-3',
        body: const <String, Object?>{
          'current_tier': 'Standard',
          'requested_cadence': 'Faster',
        },
      );

      expect(result.statusCode, 400);
      expect(result.body['error'], 'missing_business_reason');
    });

    test('field too long returns 400', () async {
      final router = OperatorTierEmailRouter(
        emailProvider: _RecordingEmailProvider(),
        auditSink: _RecordingAuditSink(),
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      final result = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-too-long',
        body: <String, Object?>{
          'current_tier': 'Standard',
          'requested_cadence': 'Faster',
          'business_reason': 'X' * 5000,
        },
      );

      expect(result.statusCode, 400);
      expect(result.body['error'], 'field_too_long');
    });

    test('SendGrid auth failure: audit row written, returns 502 email_send_failed',
        () async {
      final emailProvider = _RecordingEmailProvider(
        sendException: const EmailProviderException(
          kind: EmailFailureKind.providerAuth,
          message: 'SendGrid returned 401 unauthorized',
          statusCode: 401,
        ),
      );
      final audit = _RecordingAuditSink();
      Object? loggedError;
      final router = OperatorTierEmailRouter(
        emailProvider: emailProvider,
        auditSink: audit,
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
        auditRowIdFactory: () => 'audit-row-fail',
        sendErrorLogger: ({
          required String operatorId,
          required String actorUserId,
          required String auditRowId,
          required Object error,
        }) {
          loggedError = error;
        },
      );

      final result = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-auth-fail',
        body: const <String, Object?>{
          'current_tier': 'Standard',
          'requested_cadence': 'Faster',
          'business_reason': 'A reason',
        },
      );

      expect(result.statusCode, 502);
      expect(result.body['error'], 'email_send_failed');
      expect(result.body['audit_row_id'], 'audit-row-fail');
      expect(result.body['detail'], contains('SendGrid returned 401'));
      // Audit row STILL written — source of truth.
      expect(audit.events, hasLength(1));
      expect(
        audit.events.single['eventKind'],
        kOperatorTierEmailAuditEventKind,
      );
      // Send-error logger received the typed exception.
      expect(loggedError, isA<EmailProviderException>());
    });

    test('SendGrid network error: audit row written, returns 502',
        () async {
      final emailProvider = _RecordingEmailProvider(
        sendException: Exception('socket reset by peer'),
      );
      final audit = _RecordingAuditSink();
      final router = OperatorTierEmailRouter(
        emailProvider: emailProvider,
        auditSink: audit,
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
        auditRowIdFactory: () => 'audit-row-net',
      );

      final result = await router.handle(
        operatorId: operatorId,
        operatorName: operatorName,
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-net-fail',
        body: const <String, Object?>{
          'current_tier': 'Standard',
          'requested_cadence': 'Faster',
          'business_reason': 'A reason',
        },
      );

      expect(result.statusCode, 502);
      expect(result.body['error'], 'email_send_failed');
      expect(audit.events, hasLength(1));
    });

    test('email subject + body include operator id when display name empty',
        () async {
      final emailProvider = _RecordingEmailProvider();
      final router = OperatorTierEmailRouter(
        emailProvider: emailProvider,
        auditSink: _RecordingAuditSink(),
        fromAddress: 'noreply@forgeflow.app',
        fromDisplayName: 'Forge & Flow',
      );

      await router.handle(
        operatorId: operatorId,
        operatorName: '',
        actorUserId: actorUserId,
        actorKind: 'operator_user',
        idempotencyKey: 'idem-blank-name',
        body: const <String, Object?>{
          'current_tier': 'Standard',
          'requested_cadence': 'Faster',
          'business_reason': 'A reason',
        },
      );

      final sent = emailProvider.sends.single;
      expect(sent.subject, contains(operatorId));
      expect(sent.subject, isNot(contains('Test Operator Inc.')));
    });
  });
}

class _RecordingEmailProvider implements EmailProvider {
  _RecordingEmailProvider({this.sendException});

  /// When non-null, every call to [send] throws this object instead
  /// of returning a result. Lets a single test simulate SendGrid
  /// rejecting / network erroring out.
  final Object? sendException;

  final List<EmailSendRequest> sends = <EmailSendRequest>[];

  @override
  String get providerId => 'fake';

  @override
  Future<EmailSendResult> send(EmailSendRequest request) async {
    sends.add(request);
    final ex = sendException;
    if (ex != null) {
      // ignore: only_throw_errors
      throw ex;
    }
    return EmailSendResult(
      providerMessageId: 'fake-msg-${sends.length}',
      acceptedAt: DateTime.utc(2026, 5, 14, 12, sends.length),
    );
  }

  @override
  Future<EmailDeliveryStatus> getDeliveryStatus(String providerMessageId) {
    throw UnimplementedError();
  }
}

class _RecordingAuditSink implements OperatorWriteAuditSink {
  final List<Map<String, Object?>> events = <Map<String, Object?>>[];

  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    events.add(<String, Object?>{
      'operatorId': operatorId,
      'actorUserId': actorUserId,
      'actorKind': actorKind,
      'eventKind': eventKind,
      'payload': payload,
      'occurredAt': occurredAt,
    });
  }
}
