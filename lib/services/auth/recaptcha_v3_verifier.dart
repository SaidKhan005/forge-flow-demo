// Phase 9 live-closeout B16 (framework portion) - reCAPTCHA v3 verifier.
//
// reCAPTCHA v3 returns a score (0.0–1.0) + an action name + a list of
// error codes. The proxy verifies the token server-side via Google's
// `siteverify` endpoint and decides:
//
//   * accept: score >= threshold AND action matches expected.
//   * challenge: score < threshold but >= challengeFloor; serve an
//                additional friction step (email magic-link, etc.).
//   * reject: score < challengeFloor OR action mismatch OR token
//             verification failed.
//
// Cloud-side configuration (site key, secret, score threshold per
// route, action labels) is owned by the operator and lives in the
// proxy's secret loader. The framework here is the verifier
// interface + the policy that turns a verifier outcome into the
// accept/challenge/reject decision. The actual Google `siteverify`
// HTTP call binding lands together with the operator's reCAPTCHA
// admin-console approval (see B16 backlog blocker).

class RecaptchaV3VerifyOutcome {
  const RecaptchaV3VerifyOutcome({
    required this.success,
    required this.score,
    required this.action,
    this.errorCodes = const <String>[],
    this.hostname,
    this.challengeTs,
  });

  /// Whether the underlying `siteverify` call returned success.
  final bool success;

  /// Score in [0.0, 1.0]. Higher = more likely human.
  final double score;

  /// Action label associated with the request (e.g. `'login'`,
  /// `'password_reset'`, `'mfa_enroll'`).
  final String action;

  /// Google-side error codes when [success] is false.
  final List<String> errorCodes;

  final String? hostname;
  final DateTime? challengeTs;
}

abstract class RecaptchaV3Verifier {
  /// Verifies [token] for the expected [action]. Returns the
  /// outcome regardless of accept/challenge/reject — the policy
  /// decides downstream.
  Future<RecaptchaV3VerifyOutcome> verify({
    required String token,
    required String expectedAction,
    String? remoteIp,
  });
}

/// Hard-fail-closed default. Refuses every verification so a
/// production deploy that exposed a reCAPTCHA-protected route
/// without wiring the real verifier surfaces a clear "no reCAPTCHA
/// backend wired" error rather than silently treating every
/// request as a human.
class ScaffoldFailingRecaptchaV3Verifier implements RecaptchaV3Verifier {
  const ScaffoldFailingRecaptchaV3Verifier();

  @override
  Future<RecaptchaV3VerifyOutcome> verify({
    required String token,
    required String expectedAction,
    String? remoteIp,
  }) async {
    throw StateError(
      'B16 scaffold: real RecaptchaV3Verifier is not wired — bind a '
      "verifier that calls Google's `siteverify` with the operator's "
      'reCAPTCHA secret in the proxy bootstrap before exposing '
      'reCAPTCHA-protected routes.',
    );
  }
}

/// Decision the policy returns to the route handler.
enum RecaptchaV3Decision {
  /// Accept the request as human.
  accept,

  /// Score is in the gray zone — serve an additional friction step
  /// (email magic-link, support contact, etc.) before accepting.
  challenge,

  /// Reject the request. Caller emits an
  /// `auth.recaptcha_challenged` or `auth.recaptcha_rejected` audit
  /// event depending on which threshold was breached.
  reject,
}

class RecaptchaV3Policy {
  const RecaptchaV3Policy({
    this.acceptThreshold = defaultAcceptThreshold,
    this.challengeFloor = defaultChallengeFloor,
  });

  /// Plan-locked default accept threshold per the Phase 9.5 brief
  /// ("enable reCAPTCHA after repeated failures"); operator can
  /// tune via the proxy config without touching the framework.
  static const double defaultAcceptThreshold = 0.5;

  /// Below this floor a request is rejected outright. Anything in
  /// `[challengeFloor, acceptThreshold)` falls into the challenge
  /// zone.
  static const double defaultChallengeFloor = 0.3;

  final double acceptThreshold;
  final double challengeFloor;

  RecaptchaV3Decision decide({
    required RecaptchaV3VerifyOutcome outcome,
    required String expectedAction,
  }) {
    if (!outcome.success) return RecaptchaV3Decision.reject;
    if (outcome.action != expectedAction) return RecaptchaV3Decision.reject;
    if (outcome.score < challengeFloor) return RecaptchaV3Decision.reject;
    if (outcome.score < acceptThreshold) return RecaptchaV3Decision.challenge;
    return RecaptchaV3Decision.accept;
  }
}
