// Phase 9.8 email-provider slice — EmailProvider abstraction tests.
//
// Asserts the public seam: failure classification, recipient shape,
// and the `EmailProviderException` round-trip. The SendGrid concrete
// adapter has its own suite at
// `test/services/email/sendgrid_email_provider_test.dart`.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/email/email_provider.dart';

void main() {
  group('EmailRecipient', () {
    test('renders bare email when no display name is supplied', () {
      const recipient = EmailRecipient(email: 'admin@example.com');
      expect(recipient.toString(), 'admin@example.com');
    });

    test('renders display name + email when supplied', () {
      const recipient = EmailRecipient(
        email: 'admin@example.com',
        displayName: 'Test Admin',
      );
      expect(recipient.toString(), 'Test Admin <admin@example.com>');
    });
  });

  group('classifyEmailFailure', () {
    test('maps EmailProviderException to its kind', () {
      const error = EmailProviderException(
        kind: EmailFailureKind.providerRateLimit,
        message: 'rate limited',
      );
      expect(classifyEmailFailure(error),
          EmailFailureKind.providerRateLimit);
    });

    test('maps TimeoutException to network', () {
      final error = TimeoutException('took too long');
      expect(classifyEmailFailure(error), EmailFailureKind.network);
    });

    test('maps unknown errors to unknown', () {
      final error = StateError('boom');
      expect(classifyEmailFailure(error), EmailFailureKind.unknown);
    });
  });

  group('EmailProviderException', () {
    test('stringifies kind + status code + message', () {
      const error = EmailProviderException(
        kind: EmailFailureKind.providerAuth,
        message: 'Bearer token invalid',
        statusCode: 401,
      );
      expect(error.toString(), contains('providerAuth'));
      expect(error.toString(), contains('401'));
      expect(error.toString(), contains('Bearer token invalid'));
    });

    test('retryAfter is null by default', () {
      const error = EmailProviderException(
        kind: EmailFailureKind.providerInternal,
        message: '500',
      );
      expect(error.retryAfter, isNull);
    });

    test('retryAfter carries Duration when supplied', () {
      const error = EmailProviderException(
        kind: EmailFailureKind.providerRateLimit,
        message: '429',
        retryAfter: Duration(seconds: 30),
      );
      expect(error.retryAfter, const Duration(seconds: 30));
    });
  });

  group('EmailDeliveryStatusKind enum', () {
    test('exposes the locked V1 set', () {
      expect(EmailDeliveryStatusKind.values, hasLength(5));
      expect(
        EmailDeliveryStatusKind.values.map((e) => e.name).toSet(),
        equals(<String>{
          'accepted',
          'delivered',
          'bounced',
          'complaint',
          'unknown',
        }),
      );
    });
  });

  group('EmailFailureKind enum', () {
    test('exposes the locked failure taxonomy', () {
      expect(
        EmailFailureKind.values.map((e) => e.name).toSet(),
        equals(<String>{
          'network',
          'providerInternal',
          'providerRateLimit',
          'providerBadRequest',
          'providerAuth',
          'providerProtocol',
          'unknown',
        }),
      );
    });
  });
}
