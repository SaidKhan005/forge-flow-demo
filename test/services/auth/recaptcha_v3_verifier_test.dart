// CODE_HEALTH L10 — RecaptchaV3Policy.decide freshness gate.
//
// Pins the replay-window fix: the policy MUST reject a verification
// outcome whose `challengeTs` is older than the configured
// freshness cap (default 60 s). Cap is operator-tunable via the
// `RECAPTCHA_MAX_CHALLENGE_AGE_SECONDS` env var; constructor
// override wins over env. Outcomes with no `challengeTs` fall
// through to the score gates so the existing default-construction
// callsites (which pre-date this hardening) keep working.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/auth/recaptcha_v3_verifier.dart';

void main() {
  group('RecaptchaV3Policy.decide freshness gate (CODE_HEALTH L10)', () {
    final fixedNow = DateTime.utc(2026, 4, 28, 12, 0, 30);

    RecaptchaV3Policy policyAt(DateTime now) =>
        RecaptchaV3Policy.withClock(now: () => now);

    test('challengeTs 30s old + good score -> accept', () {
      final policy = policyAt(fixedNow);
      final outcome = RecaptchaV3VerifyOutcome(
        success: true,
        score: 0.9,
        action: 'login',
        challengeTs: fixedNow.subtract(const Duration(seconds: 30)),
      );

      final decision = policy.decide(outcome: outcome, expectedAction: 'login');

      expect(decision, equals(RecaptchaV3Decision.accept));
    });

    test('challengeTs 90s old + good score -> reject (replay defence)', () {
      final policy = policyAt(fixedNow);
      final outcome = RecaptchaV3VerifyOutcome(
        success: true,
        score: 0.9,
        action: 'login',
        challengeTs: fixedNow.subtract(const Duration(seconds: 90)),
      );

      final decision = policy.decide(outcome: outcome, expectedAction: 'login');

      // The score is fine, the action matches — only the freshness
      // gate fires. Without L10 this would have accepted.
      expect(decision, equals(RecaptchaV3Decision.reject));
    });

    test('challengeTs exactly 60s old -> still accept (boundary)', () {
      // 60s == cap; the policy rejects only when STRICTLY older than
      // the cap. Boundary chosen to match the prompt's "older than 60s"
      // language.
      final policy = policyAt(fixedNow);
      final outcome = RecaptchaV3VerifyOutcome(
        success: true,
        score: 0.9,
        action: 'login',
        challengeTs: fixedNow.subtract(const Duration(seconds: 60)),
      );

      expect(
        policy.decide(outcome: outcome, expectedAction: 'login'),
        equals(RecaptchaV3Decision.accept),
      );
    });

    test('null challengeTs falls through to score gates (legacy compat)', () {
      // Outcomes that pre-date the freshness gate (existing
      // scaffold tests, fakes that don't populate challengeTs)
      // keep working — the gate only fires when challengeTs is
      // present and stale.
      const policy = RecaptchaV3Policy();
      final outcome = const RecaptchaV3VerifyOutcome(
        success: true,
        score: 0.9,
        action: 'login',
      );
      expect(
        policy.decide(outcome: outcome, expectedAction: 'login'),
        equals(RecaptchaV3Decision.accept),
      );
    });

    test('env override loosens the cap', () {
      final policy = RecaptchaV3Policy.fromEnvironment(const <String, String>{
        'RECAPTCHA_MAX_CHALLENGE_AGE_SECONDS': '300',
      });
      expect(policy.maxChallengeAge, equals(const Duration(seconds: 300)));
    });

    test('env override tightens the cap', () {
      final policy = RecaptchaV3Policy.fromEnvironment(const <String, String>{
        'RECAPTCHA_MAX_CHALLENGE_AGE_SECONDS': '15',
      });
      expect(policy.maxChallengeAge, equals(const Duration(seconds: 15)));
    });

    test('env override with a non-positive integer falls back to default', () {
      final zero = RecaptchaV3Policy.fromEnvironment(const <String, String>{
        'RECAPTCHA_MAX_CHALLENGE_AGE_SECONDS': '0',
      });
      expect(
        zero.maxChallengeAge,
        equals(RecaptchaV3Policy.defaultMaxChallengeAge),
      );

      final negative = RecaptchaV3Policy.fromEnvironment(const <String, String>{
        'RECAPTCHA_MAX_CHALLENGE_AGE_SECONDS': '-30',
      });
      expect(
        negative.maxChallengeAge,
        equals(RecaptchaV3Policy.defaultMaxChallengeAge),
      );
    });

    test('env override with a non-numeric value falls back to default', () {
      final policy = RecaptchaV3Policy.fromEnvironment(const <String, String>{
        'RECAPTCHA_MAX_CHALLENGE_AGE_SECONDS': 'banana',
      });
      expect(
        policy.maxChallengeAge,
        equals(RecaptchaV3Policy.defaultMaxChallengeAge),
      );
    });

    test('env without the key uses the locked default (60s)', () {
      final policy = RecaptchaV3Policy.fromEnvironment(
        const <String, String>{},
      );
      expect(
        policy.maxChallengeAge,
        equals(RecaptchaV3Policy.defaultMaxChallengeAge),
      );
      expect(policy.maxChallengeAge, equals(const Duration(seconds: 60)));
    });

    test('action mismatch wins over freshness (existing reject path)', () {
      final policy = policyAt(fixedNow);
      final outcome = RecaptchaV3VerifyOutcome(
        success: true,
        score: 0.95,
        action: 'login',
        challengeTs: fixedNow.subtract(const Duration(seconds: 30)),
      );
      expect(
        policy.decide(outcome: outcome, expectedAction: 'password_reset'),
        equals(RecaptchaV3Decision.reject),
      );
    });

    test('verifier success=false rejects regardless of fresh challengeTs', () {
      final policy = policyAt(fixedNow);
      final outcome = RecaptchaV3VerifyOutcome(
        success: false,
        score: 1.0,
        action: 'login',
        errorCodes: const <String>['invalid-input-secret'],
        challengeTs: fixedNow,
      );
      expect(
        policy.decide(outcome: outcome, expectedAction: 'login'),
        equals(RecaptchaV3Decision.reject),
      );
    });
  });
}
