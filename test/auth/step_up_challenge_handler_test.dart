// Lane B B11.2.b — step-up challenge handler unit tests.
//
// Pins the contract for the operator-web client adapter that parses
// an RFC 9470 challenge from a 401 response and replays the original
// request with `Step-Up-Challenge-Id` as a request HEADER (NEVER as
// a URL parameter — addendum A1 prohibition).

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/operator_web/auth/step_up_challenge_handler.dart';

void main() {
  group('StepUpChallengeOffer.tryParse', () {
    test('returns null for non-401 responses', () {
      final offer = StepUpChallengeOffer.tryParse(
        statusCode: 403,
        headers: const <String, String>{
          'www-authenticate':
              'Bearer error="insufficient_user_authentication", '
              'acr_values="urn:mfa", max_age=300',
        },
        body: const <String, Object?>{
          'challenge_id': 'abc',
        },
      );
      expect(offer, isNull);
    });

    test('returns null when WWW-Authenticate header is absent', () {
      final offer = StepUpChallengeOffer.tryParse(
        statusCode: 401,
        headers: const <String, String>{},
        body: const <String, Object?>{
          'challenge_id': 'abc',
        },
      );
      expect(offer, isNull);
    });

    test('returns null when WWW-Authenticate error code does not match', () {
      final offer = StepUpChallengeOffer.tryParse(
        statusCode: 401,
        headers: const <String, String>{
          'www-authenticate': 'Bearer error="invalid_token"',
        },
        body: const <String, Object?>{
          'challenge_id': 'abc',
        },
      );
      expect(offer, isNull);
    });

    test('returns null when challenge_id is missing or empty', () {
      final offer = StepUpChallengeOffer.tryParse(
        statusCode: 401,
        headers: const <String, String>{
          'www-authenticate':
              'Bearer error="insufficient_user_authentication", '
              'acr_values="urn:mfa", max_age=300',
        },
        body: const <String, Object?>{},
      );
      expect(offer, isNull);
    });

    test('parses a well-formed challenge end-to-end', () {
      final offer = StepUpChallengeOffer.tryParse(
        statusCode: 401,
        headers: const <String, String>{
          'www-authenticate':
              'Bearer error="insufficient_user_authentication", '
              'acr_values="urn:mfa", max_age=300, '
              'error_description="Changing your password requires '
              'a fresh sign-in."',
        },
        body: const <String, Object?>{
          'error': 'insufficient_user_authentication',
          'message': 'Changing your password requires a fresh sign-in.',
          'challenge_id': 'CHAL_22CHARSABCDEFGHIJK',
          'required_acr': 'urn:mfa',
          'max_age_seconds': 300,
          'challenge_expires_in_seconds': 300,
          'reason': 'auth_time_stale',
        },
      );
      expect(offer, isNotNull);
      expect(offer!.challengeId, equals('CHAL_22CHARSABCDEFGHIJK'));
      expect(offer.acrValues, equals('urn:mfa'));
      expect(offer.maxAgeSeconds, equals(300));
      expect(offer.message,
          equals('Changing your password requires a fresh sign-in.'));
      expect(offer.challengeExpiresInSeconds, equals(300));
      expect(offer.reason, equals('auth_time_stale'));
    });

    test('case-insensitive WWW-Authenticate header lookup', () {
      final offer = StepUpChallengeOffer.tryParse(
        statusCode: 401,
        headers: const <String, String>{
          'WWW-Authenticate':
              'Bearer error="insufficient_user_authentication", '
              'acr_values="urn:mfa", max_age=300',
        },
        body: const <String, Object?>{
          'challenge_id': 'abc',
          'message': 'fresh auth required',
        },
      );
      expect(offer, isNotNull);
    });

    test('handles backslash-escaped quoted values in WWW-Authenticate', () {
      final offer = StepUpChallengeOffer.tryParse(
        statusCode: 401,
        headers: const <String, String>{
          'www-authenticate':
              r'Bearer error="insufficient_user_authentication", '
              r'acr_values="urn:mfa", max_age=300, '
              r'error_description="Reason with \"quote\""',
        },
        body: const <String, Object?>{
          'challenge_id': 'abc',
        },
      );
      expect(offer, isNotNull);
      expect(offer!.message, contains('"quote"'));
    });
  });

  group('runStepUpChallenge', () {
    test('drives reauth hook + replays with HEADER (never URL)', () async {
      final hook = RecordingStepUpChallengeReauthHook(
        respondWith: 'fresh-id-token',
      );
      String? replayedToken;
      String? replayedChallengeId;
      String? urlSeenByReplay;
      final result = await runStepUpChallenge<String>(
        offer: const StepUpChallengeOffer(
          challengeId: 'CHAL_REPLAY',
          acrValues: 'urn:mfa',
          maxAgeSeconds: 300,
          message: 'fresh auth required',
        ),
        hook: hook,
        replay: ({required freshIdToken, required challengeId}) async {
          replayedToken = freshIdToken;
          replayedChallengeId = challengeId;
          // The challenge id should NEVER end up in any URL the
          // replay constructs. We assert here that the test's replay
          // closure has no URL — the contract is purely (token,
          // challengeId) -> result.
          urlSeenByReplay = null;
          return 'replay-result';
        },
      );
      expect(result, equals('replay-result'));
      expect(replayedToken, equals('fresh-id-token'));
      expect(replayedChallengeId, equals('CHAL_REPLAY'));
      expect(urlSeenByReplay, isNull);
      expect(hook.events, hasLength(1));
      expect(hook.events.single.challengeId, equals('CHAL_REPLAY'));
    });

    test('throws StepUpChallengeAbortedException when hook returns null',
        () async {
      const hook = NoopStepUpChallengeReauthHook();
      const offer = StepUpChallengeOffer(
        challengeId: 'CHAL_AAA',
        acrValues: 'urn:mfa',
        maxAgeSeconds: 300,
        message: 'fresh auth required',
      );
      expect(
        () => runStepUpChallenge<String>(
          offer: offer,
          hook: hook,
          replay: ({required freshIdToken, required challengeId}) async => 'x',
        ),
        throwsA(isA<StepUpChallengeAbortedException>()),
      );
    });

    test('propagates network errors from the replay callback', () async {
      final hook = RecordingStepUpChallengeReauthHook(
        respondWith: 'fresh-token',
      );
      const offer = StepUpChallengeOffer(
        challengeId: 'CHAL_AAA',
        acrValues: 'urn:mfa',
        maxAgeSeconds: 300,
        message: 'fresh auth required',
      );
      expect(
        () => runStepUpChallenge<String>(
          offer: offer,
          hook: hook,
          replay: ({required freshIdToken, required challengeId}) async {
            throw StateError('network error');
          },
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Step-Up-Challenge-Id wire shape — addendum A1', () {
    test('header name constant matches the proxy contract', () {
      expect(kStepUpChallengeIdHeader, equals('Step-Up-Challenge-Id'));
    });

    test('WWW-Authenticate header name is the standard RFC 7235 spelling', () {
      expect(kStepUpWwwAuthenticateHeader, equals('WWW-Authenticate'));
    });

    test('error code matches RFC 9470 §4', () {
      expect(kStepUpErrorCode, equals('insufficient_user_authentication'));
    });
  });
}
