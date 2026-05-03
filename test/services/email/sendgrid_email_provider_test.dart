// Phase 9.8 email-provider slice — SendGridEmailProvider tests.
//
// Drives the concrete SendGrid adapter against an in-memory HTTP
// gateway that returns recorded SendGrid sandbox responses. Verifies:
//
//   * Successful 202 → returns provider_message_id from X-Message-Id.
//   * 429 with Retry-After → providerRateLimit + retryAfter Duration.
//   * 401 → providerAuth (bad credential, surface admin alert).
//   * 4xx (other) → providerBadRequest (dead-letter immediately).
//   * 5xx → providerInternal (retry).
//   * Network exception → network (retry).
//   * 202 without X-Message-Id → providerProtocol (dead-letter).
//   * Sandbox mode adds mail_settings.sandbox_mode.enable = true.
//   * GET /v3/messages/<id> maps SendGrid status_label → enum.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/email/email_provider.dart';
import 'package:forge_and_flow/services/email/sendgrid_email_provider.dart';

void main() {
  EmailSendRequest sampleRequest() => const EmailSendRequest(
        to: EmailRecipient(
          email: 'admin@example.com',
          displayName: 'Test Admin',
        ),
        subject: 'Welcome',
        htmlBody: '<p>Hi</p>',
        textBody: 'Hi',
        fromAddress: 'noreply@mail.forgeflow.app',
        fromDisplayName: 'Forge & Flow',
        providerMetadata: <String, String>{
          'email_id': 'fixed-email-id',
          'template_id': 'operator_invite_first_admin',
        },
      );

  group('SendGridEmailProvider.send', () {
    test('returns provider_message_id when SendGrid returns 202', () async {
      final calls = <Map<String, Object?>>[];
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          calls.add(<String, Object?>{
            'method': method,
            'uri': uri.toString(),
            'headers': headers,
            'body': body,
          });
          return const SendGridHttpResponse(
            statusCode: 202,
            headers: <String, String>{
              'x-message-id': 'sg-msg-xyz789',
            },
            body: '',
          );
        },
        apiKeyProvider: () async => 'SG.test-key',
        now: () => DateTime.utc(2026, 5, 4, 12, 0),
      );

      final result = await provider.send(sampleRequest());

      expect(result.providerMessageId, 'sg-msg-xyz789');
      expect(result.acceptedAt, DateTime.utc(2026, 5, 4, 12, 0));
      expect(calls, hasLength(1));
      expect(calls.first['method'], 'POST');
      expect(
        (calls.first['uri'] as String),
        endsWith('/v3/mail/send'),
      );
      final headers = calls.first['headers'] as Map<String, String>;
      expect(headers['Authorization'], 'Bearer SG.test-key');
      expect(headers['Content-Type'], 'application/json');
      final body = jsonDecode(calls.first['body']! as String);
      expect(body['from']['email'], 'noreply@mail.forgeflow.app');
      expect(body['subject'], 'Welcome');
      final personalizations = body['personalizations'] as List;
      expect(personalizations.first['to'][0]['email'], 'admin@example.com');
      expect(personalizations.first['custom_args']['email_id'],
          'fixed-email-id');
    });

    test('throws providerProtocol when 202 lacks X-Message-Id', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          return const SendGridHttpResponse(
            statusCode: 202,
            headers: <String, String>{},
            body: '',
          );
        },
        apiKeyProvider: () async => 'SG.test-key',
      );

      expect(
        () => provider.send(sampleRequest()),
        throwsA(isA<EmailProviderException>().having(
          (e) => e.kind,
          'kind',
          EmailFailureKind.providerProtocol,
        )),
      );
    });

    test(
      '429 with Retry-After surfaces providerRateLimit + duration',
      () async {
        final provider = SendGridEmailProvider(
          httpGateway: ({
            required String method,
            required Uri uri,
            required Map<String, String> headers,
            String? body,
          }) async {
            return const SendGridHttpResponse(
              statusCode: 429,
              headers: <String, String>{'Retry-After': '45'},
              body: '{"errors":[{"message":"too many requests"}]}',
            );
          },
          apiKeyProvider: () async => 'SG.test-key',
        );

        try {
          await provider.send(sampleRequest());
          fail('expected EmailProviderException');
        } on EmailProviderException catch (e) {
          expect(e.kind, EmailFailureKind.providerRateLimit);
          expect(e.statusCode, 429);
          expect(e.retryAfter, const Duration(seconds: 45));
        }
      },
    );

    test('401 surfaces providerAuth', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          return const SendGridHttpResponse(
            statusCode: 401,
            headers: <String, String>{},
            body: '{"errors":[{"message":"unauthorized"}]}',
          );
        },
        apiKeyProvider: () async => 'SG.test-key',
      );

      try {
        await provider.send(sampleRequest());
        fail('expected EmailProviderException');
      } on EmailProviderException catch (e) {
        expect(e.kind, EmailFailureKind.providerAuth);
        expect(e.statusCode, 401);
      }
    });

    test('400 surfaces providerBadRequest', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          return const SendGridHttpResponse(
            statusCode: 400,
            headers: <String, String>{},
            body: '{"errors":[{"message":"bad email"}]}',
          );
        },
        apiKeyProvider: () async => 'SG.test-key',
      );

      try {
        await provider.send(sampleRequest());
        fail('expected EmailProviderException');
      } on EmailProviderException catch (e) {
        expect(e.kind, EmailFailureKind.providerBadRequest);
        expect(e.statusCode, 400);
      }
    });

    test('502 surfaces providerInternal', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          return const SendGridHttpResponse(
            statusCode: 502,
            headers: <String, String>{},
            body: 'bad gateway',
          );
        },
        apiKeyProvider: () async => 'SG.test-key',
      );

      try {
        await provider.send(sampleRequest());
        fail('expected EmailProviderException');
      } on EmailProviderException catch (e) {
        expect(e.kind, EmailFailureKind.providerInternal);
        expect(e.statusCode, 502);
      }
    });

    test('network exception surfaces network kind', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          throw 'connection refused';
        },
        apiKeyProvider: () async => 'SG.test-key',
      );

      try {
        await provider.send(sampleRequest());
        fail('expected EmailProviderException');
      } on EmailProviderException catch (e) {
        expect(e.kind, EmailFailureKind.network);
      }
    });

    test('empty API key short-circuits with providerAuth', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          fail('gateway should not be called when API key is empty');
        },
        apiKeyProvider: () async => '',
      );

      try {
        await provider.send(sampleRequest());
        fail('expected EmailProviderException');
      } on EmailProviderException catch (e) {
        expect(e.kind, EmailFailureKind.providerAuth);
      }
    });

    test('sandbox mode adds mail_settings.sandbox_mode.enable=true',
        () async {
      String? lastBody;
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          lastBody = body;
          return const SendGridHttpResponse(
            statusCode: 202,
            headers: <String, String>{'X-Message-Id': 'sandbox-id'},
            body: '',
          );
        },
        apiKeyProvider: () async => 'SG.staging-key',
        sandboxMode: true,
      );

      await provider.send(sampleRequest());

      final decoded = jsonDecode(lastBody!) as Map<String, Object?>;
      final mailSettings = decoded['mail_settings'] as Map<String, Object?>;
      final sandbox = mailSettings['sandbox_mode'] as Map<String, Object?>;
      expect(sandbox['enable'], true);
    });
  });

  group('SendGridEmailProvider.getDeliveryStatus', () {
    test('maps "delivered" status to delivered enum', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          return SendGridHttpResponse(
            statusCode: 200,
            headers: const <String, String>{},
            body: jsonEncode(<String, Object?>{
              'messages': [
                <String, Object?>{
                  'msg_id': 'sg-msg-xyz789',
                  'status': 'delivered',
                },
              ],
            }),
          );
        },
        apiKeyProvider: () async => 'SG.test-key',
        now: () => DateTime.utc(2026, 5, 4, 13, 0),
      );

      final status = await provider.getDeliveryStatus('sg-msg-xyz789');
      expect(status.statusKind, EmailDeliveryStatusKind.delivered);
      expect(status.providerMessageId, 'sg-msg-xyz789');
      expect(status.checkedAt, DateTime.utc(2026, 5, 4, 13, 0));
    });

    test('maps "bounce" status to bounced enum', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          return SendGridHttpResponse(
            statusCode: 200,
            headers: const <String, String>{},
            body: jsonEncode(<String, Object?>{
              'messages': [
                <String, Object?>{
                  'status': 'bounce',
                  'reason': 'mailbox full',
                },
              ],
            }),
          );
        },
        apiKeyProvider: () async => 'SG.test-key',
      );

      final status = await provider.getDeliveryStatus('sg-msg-xyz789');
      expect(status.statusKind, EmailDeliveryStatusKind.bounced);
      expect(status.detail, 'mailbox full');
    });

    test('404 maps to unknown without throwing', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          return const SendGridHttpResponse(
            statusCode: 404,
            headers: <String, String>{},
            body: '',
          );
        },
        apiKeyProvider: () async => 'SG.test-key',
      );

      final status = await provider.getDeliveryStatus('aged-out-id');
      expect(status.statusKind, EmailDeliveryStatusKind.unknown);
    });

    test('unparseable JSON throws providerProtocol', () async {
      final provider = SendGridEmailProvider(
        httpGateway: ({
          required String method,
          required Uri uri,
          required Map<String, String> headers,
          String? body,
        }) async {
          return const SendGridHttpResponse(
            statusCode: 200,
            headers: <String, String>{},
            body: 'not json',
          );
        },
        apiKeyProvider: () async => 'SG.test-key',
      );

      try {
        await provider.getDeliveryStatus('sg-msg-xyz789');
        fail('expected EmailProviderException');
      } on EmailProviderException catch (e) {
        expect(e.kind, EmailFailureKind.providerProtocol);
      }
    });
  });

  test('providerId is "sendgrid"', () {
    final provider = SendGridEmailProvider(
      httpGateway: ({
        required String method,
        required Uri uri,
        required Map<String, String> headers,
        String? body,
      }) async =>
          throw UnimplementedError(),
      apiKeyProvider: () async => 'SG.test-key',
    );
    expect(provider.providerId, 'sendgrid');
  });
}
