// G63 — shared operator-web proxy error-envelope classifier tests.
//
// Pins the (statusCode, code) → OperatorWebErrorKind mapping for every
// kind, the 403 freshness-vs-permission split, the 409 replay-vs-domain
// conflict split, the typed-exception extension getter, and the
// canonical operator-facing copy (including the no-em-dash law).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/auth/mfa_freshness_redirect_listener.dart';
import 'package:forge_and_flow/operator_web/auth/step_up_challenge_handler.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_error_envelope.dart';
import 'package:forge_and_flow/operator_web/services/operator_web_proxy_client.dart';

void main() {
  group('classifyOperatorWebError — status/code → kind', () {
    test('403 with mfa_freshness_required code → mfaFreshnessRedirect', () {
      expect(
        classifyOperatorWebError(
          statusCode: 403,
          code: MfaFreshnessRedirectPayload.errorCode,
        ),
        OperatorWebErrorKind.mfaFreshnessRedirect,
      );
    });

    test('403 with step-up sentinel code → mfaFreshnessRedirect', () {
      expect(
        classifyOperatorWebError(statusCode: 403, code: kStepUpErrorCode),
        OperatorWebErrorKind.mfaFreshnessRedirect,
      );
    });

    test(
      'isMfaFreshnessRedirect flag forces mfaFreshnessRedirect even with a '
      'generic code',
      () {
        expect(
          classifyOperatorWebError(
            statusCode: 403,
            code: 'forbidden',
            isMfaFreshnessRedirect: true,
          ),
          OperatorWebErrorKind.mfaFreshnessRedirect,
        );
      },
    );

    test('403 with any other code → permissionDenied', () {
      expect(
        classifyOperatorWebError(statusCode: 403, code: 'forbidden'),
        OperatorWebErrorKind.permissionDenied,
      );
      expect(
        classifyOperatorWebError(statusCode: 403, code: null),
        OperatorWebErrorKind.permissionDenied,
      );
    });

    test('409 with idempotency_key_conflict → idempotencyReplayConflict', () {
      expect(
        classifyOperatorWebError(
          statusCode: 409,
          code: kIdempotencyKeyConflictCode,
        ),
        OperatorWebErrorKind.idempotencyReplayConflict,
      );
    });

    test('409 with any domain code → resourceConflict', () {
      expect(
        classifyOperatorWebError(
          statusCode: 409,
          code: 'role_has_active_grants',
        ),
        OperatorWebErrorKind.resourceConflict,
      );
      expect(
        classifyOperatorWebError(statusCode: 409, code: null),
        OperatorWebErrorKind.resourceConflict,
      );
    });

    test('404 → notFound', () {
      expect(
        classifyOperatorWebError(statusCode: 404, code: 'not_found'),
        OperatorWebErrorKind.notFound,
      );
    });

    test('400 and 422 → validation', () {
      expect(
        classifyOperatorWebError(statusCode: 400, code: 'bad_request'),
        OperatorWebErrorKind.validation,
      );
      expect(
        classifyOperatorWebError(statusCode: 422, code: 'validation_failed'),
        OperatorWebErrorKind.validation,
      );
    });

    test('408, 429, and every 5xx → transient', () {
      expect(
        classifyOperatorWebError(statusCode: 408, code: null),
        OperatorWebErrorKind.transient,
      );
      expect(
        classifyOperatorWebError(statusCode: 429, code: 'rate_limited'),
        OperatorWebErrorKind.transient,
      );
      for (final status in <int>[500, 502, 503, 504, 599]) {
        expect(
          classifyOperatorWebError(statusCode: status, code: null),
          OperatorWebErrorKind.transient,
          reason: 'status $status should be transient',
        );
      }
    });

    test('null status or an unmapped status → unknown', () {
      expect(
        classifyOperatorWebError(statusCode: null, code: 'malformed_response'),
        OperatorWebErrorKind.unknown,
      );
      expect(
        classifyOperatorWebError(statusCode: 418, code: null),
        OperatorWebErrorKind.unknown,
      );
      // A 2xx never reaches the classifier in practice, but it must not
      // masquerade as a known failure kind.
      expect(
        classifyOperatorWebError(statusCode: 200, code: null),
        OperatorWebErrorKind.unknown,
      );
    });

    test('code is matched after trimming surrounding whitespace', () {
      expect(
        classifyOperatorWebError(
          statusCode: 409,
          code: '  idempotency_key_conflict  ',
        ),
        OperatorWebErrorKind.idempotencyReplayConflict,
      );
    });
  });

  group('OperatorWebProxyException.kind extension', () {
    test('feeds isMfaFreshnessRedirect into the classifier', () {
      const exception = OperatorWebProxyException(
        code: MfaFreshnessRedirectPayload.errorCode,
        message: 'fresh authentication is required',
        statusCode: 403,
        redirectUri: '/auth/login?reason=fresh_mfa_required',
      );
      expect(exception.isMfaFreshnessRedirect, isTrue);
      expect(exception.kind, OperatorWebErrorKind.mfaFreshnessRedirect);
    });

    test('a plain 403 (no redirectUri) classifies as permissionDenied', () {
      const exception = OperatorWebProxyException(
        code: 'forbidden',
        message: 'no',
        statusCode: 403,
      );
      expect(exception.isMfaFreshnessRedirect, isFalse);
      expect(exception.kind, OperatorWebErrorKind.permissionDenied);
    });

    test('409 idempotency_key_conflict classifies as replay conflict', () {
      const exception = OperatorWebProxyException(
        code: kIdempotencyKeyConflictCode,
        message: 'Idempotency-Key was reused with a different request body',
        statusCode: 409,
      );
      expect(exception.kind, OperatorWebErrorKind.idempotencyReplayConflict);
    });

    test('operatorFacingMessage returns the canonical copy for the kind', () {
      const exception = OperatorWebProxyException(
        code: kIdempotencyKeyConflictCode,
        message: 'raw proxy message',
        statusCode: 409,
      );
      expect(
        exception.operatorFacingMessage,
        operatorWebErrorMessageFor(
          OperatorWebErrorKind.idempotencyReplayConflict,
        ),
      );
    });
  });

  group('operatorWebErrorMessageFor — canonical copy', () {
    test('every kind has non-empty, em-dash-free guidance copy', () {
      for (final kind in OperatorWebErrorKind.values) {
        final copy = operatorWebErrorMessageFor(kind);
        expect(copy, isNotEmpty, reason: '$kind must have copy');
        // UX no-em-dash law: no U+2014 as punctuation in operator copy.
        expect(
          copy.contains('—'),
          isFalse,
          reason: '$kind copy must not use an em dash',
        );
      }
    });

    test('replay-conflict copy reads as "already applied" guidance', () {
      final copy = operatorWebErrorMessageFor(
        OperatorWebErrorKind.idempotencyReplayConflict,
      );
      expect(copy.toLowerCase(), contains('already'));
    });

    test('permission-denied copy is distinct from freshness copy', () {
      expect(
        operatorWebErrorMessageFor(OperatorWebErrorKind.permissionDenied),
        isNot(
          operatorWebErrorMessageFor(
            OperatorWebErrorKind.mfaFreshnessRedirect,
          ),
        ),
      );
    });
  });
}
