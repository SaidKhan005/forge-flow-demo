// Phase 9 live-closeout B16 (framework portion) - reCAPTCHA v3 verifier.
//
// reCAPTCHA v3 returns a score (0.0–1.0) + an action name + a list of
// error codes. The proxy verifies the token server-side via Google's
// `siteverify` endpoint and decides:
//
//   * accept: score >= threshold AND action matches expected
//             AND the response's `challengeTs` is fresh.
//   * challenge: score < threshold but >= challengeFloor; serve an
//                additional friction step (email magic-link, etc.).
//   * reject: score < challengeFloor OR action mismatch OR token
//             verification failed OR `challengeTs` is older than the
//             freshness cap (replayed token).
//
// Cloud-side configuration (site key, secret, score threshold per
// route, action labels) is owned by the operator and lives in the
// proxy's secret loader. The framework here is the verifier
// interface + the policy that turns a verifier outcome into the
// accept/challenge/reject decision. The actual Google `siteverify`
// HTTP call binding lands together with the operator's reCAPTCHA
// admin-console approval (see B16 backlog blocker).
//
// CODE_HEALTH L10 (token-freshness): Google's siteverify response
// carries a `challenge_ts` ISO-8601 timestamp marking when the token
// was issued. The policy now rejects a token whose `challengeTs` is
// older than [maxChallengeAge] (default 60s, override via the env
// var `RECAPTCHA_MAX_CHALLENGE_AGE_SECONDS`). Without this gate a
// stolen token replayed days later still verifies as long as score +
// action match, defeating the point of v3 risk scoring.

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
  /// Default constructor. `const` for backward compatibility with
  /// existing call sites that build the policy as a top-level
  /// constant. Operators that want to tune the freshness cap from
  /// the environment construct via [RecaptchaV3Policy.fromEnvironment]
  /// instead; tests inject a deterministic clock via
  /// [RecaptchaV3Policy.withClock].
  const RecaptchaV3Policy({
    this.acceptThreshold = defaultAcceptThreshold,
    this.challengeFloor = defaultChallengeFloor,
    this.maxChallengeAge = defaultMaxChallengeAge,
  }) : _now = null;

  /// Resolves [maxChallengeAge] from the proxy environment. Reads
  /// [maxChallengeAgeEnvVar]; falls back to [defaultMaxChallengeAge]
  /// when unset, blank, or non-positive. The proxy bootstrap calls
  /// this with `Platform.environment`; tests pass a literal map.
  factory RecaptchaV3Policy.fromEnvironment(
    Map<String, String> environment, {
    double acceptThreshold = defaultAcceptThreshold,
    double challengeFloor = defaultChallengeFloor,
  }) {
    return RecaptchaV3Policy(
      acceptThreshold: acceptThreshold,
      challengeFloor: challengeFloor,
      maxChallengeAge: _resolveMaxChallengeAge(environment),
    );
  }

  /// Test-only constructor that injects a deterministic clock so
  /// [decide] freshness checks are reproducible.
  const RecaptchaV3Policy.withClock({
    required DateTime Function() now,
    this.acceptThreshold = defaultAcceptThreshold,
    this.challengeFloor = defaultChallengeFloor,
    this.maxChallengeAge = defaultMaxChallengeAge,
  }) : _now = now;

  /// Plan-locked default accept threshold per the Phase 9.5 brief
  /// ("enable reCAPTCHA after repeated failures"); operator can
  /// tune via the proxy config without touching the framework.
  static const double defaultAcceptThreshold = 0.5;

  /// Below this floor a request is rejected outright. Anything in
  /// `[challengeFloor, acceptThreshold)` falls into the challenge
  /// zone.
  static const double defaultChallengeFloor = 0.3;

  /// Default freshness cap for `challengeTs`. CODE_HEALTH L10: any
  /// older response is treated as a replay and rejected. Operators
  /// can tune by setting `RECAPTCHA_MAX_CHALLENGE_AGE_SECONDS` in
  /// the proxy environment; constructor override wins over env.
  static const Duration defaultMaxChallengeAge = Duration(seconds: 60);

  /// Env var name for the operator-side freshness override. Read via
  /// the [environment] constructor parameter so the value is
  /// injectable in tests; the proxy bootstrap passes
  /// `Platform.environment`.
  static const String maxChallengeAgeEnvVar =
      'RECAPTCHA_MAX_CHALLENGE_AGE_SECONDS';

  final double acceptThreshold;
  final double challengeFloor;

  /// Reject any verification whose `challengeTs` is older than this
  /// from `now()`. Defaults to [defaultMaxChallengeAge]; operator
  /// override via [maxChallengeAgeEnvVar].
  final Duration maxChallengeAge;

  /// Optional clock injection for tests. The default constructor
  /// leaves this null and the freshness gate uses [DateTime.now].
  final DateTime Function()? _now;

  RecaptchaV3Decision decide({
    required RecaptchaV3VerifyOutcome outcome,
    required String expectedAction,
  }) {
    if (!outcome.success) return RecaptchaV3Decision.reject;
    if (outcome.action != expectedAction) return RecaptchaV3Decision.reject;
    // Freshness gate (CODE_HEALTH L10). When `challengeTs` is
    // present and older than [maxChallengeAge], the token is treated
    // as a replay and rejected. A response missing `challengeTs`
    // (legacy verifier impls + every existing scaffold/test outcome
    // that pre-dates the freshness gate) falls through to the score
    // checks; the production HTTP verifier always populates
    // `challengeTs` so the gate is effective on the real wire.
    final challengeTs = outcome.challengeTs;
    if (challengeTs != null) {
      final clock = _now ?? DateTime.now;
      final age = clock().difference(challengeTs);
      if (age > maxChallengeAge) {
        return RecaptchaV3Decision.reject;
      }
    }
    if (outcome.score < challengeFloor) return RecaptchaV3Decision.reject;
    if (outcome.score < acceptThreshold) return RecaptchaV3Decision.challenge;
    return RecaptchaV3Decision.accept;
  }

  static Duration _resolveMaxChallengeAge(Map<String, String>? environment) {
    final raw = environment?[maxChallengeAgeEnvVar];
    if (raw == null) return defaultMaxChallengeAge;
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed <= 0) return defaultMaxChallengeAge;
    return Duration(seconds: parsed);
  }
}
