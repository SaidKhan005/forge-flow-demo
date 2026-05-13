// Lane B B11.2.b — operator-web step-up challenge handler.
//
// Client adapter for the proxy's RFC 9470 step-up emission. When a
// sensitive route returns 401 with `WWW-Authenticate: Bearer
// error="insufficient_user_authentication", ...` and a JSON body
// carrying `challenge_id`, this handler:
//
//   1. Parses the WWW-Authenticate header into a typed
//      [StepUpChallengeOffer]. The header is the source of truth for
//      the `error`, `acr_values`, `max_age`, and `error_description`
//      fields; the body carries the opaque `challenge_id` and a
//      plain-English `message`. Both are required.
//   2. Hands the offer to the screen layer's
//      [StepUpChallengeReauthHook]. The hook drives the user through
//      the fresh-auth flow (TOTP / passkey / password+MFA) and
//      resolves to a fresh ID token.
//   3. The gateway that originally made the request re-issues the
//      same request, carrying the new ID token AND
//      `Step-Up-Challenge-Id: <opaque>` as a REQUEST HEADER (NEVER as
//      a URL parameter — addendum A1 prohibition).
//   4. The proxy's gate consumes the row atomically (UPDATE …
//      RETURNING) and dispatches the original handler.
//
// Replay protection is at the proxy: a consumed row returns 410, an
// expired or wrong-route row returns 401 with a fresh challenge, and
// an unknown challenge id is collapsed to 401 (oracle-safe).
//
// This handler does NOT itself touch HTTP — gateways inject the
// `replay` callback so the handler can re-issue any request shape
// without owning a generic HTTP client.

import 'package:meta/meta.dart';

/// Wire-shape constants. Mirrored from the proxy's RFC 9470 emission.
/// Lower-case header name spelling: HTTP headers are case-insensitive
/// in the wire but client libraries often normalize on `WWW-Authenticate`.
const String kStepUpWwwAuthenticateHeader = 'WWW-Authenticate';

/// Header name the client adds when replaying the original request
/// with a freshly-redeemed challenge id. Tracks
/// `tool/advisor_proxy/auth_step_up_routes.dart::kStepUpChallengeIdHeader`.
const String kStepUpChallengeIdHeader = 'Step-Up-Challenge-Id';

/// RFC 9470 §4 error code. The proxy emits this verbatim in the
/// `error=` parameter; clients use it to recognize a step-up
/// challenge vs. a generic 401.
const String kStepUpErrorCode = 'insufficient_user_authentication';

/// Parsed step-up challenge offered by the proxy. Carries the opaque
/// `challengeId` (read from the JSON body), the `acrValues` and
/// `maxAge` (read from the WWW-Authenticate header), and the
/// plain-English `message` (read from the JSON body's `message` key
/// when present, falling back to the header's `error_description`
/// when not).
@immutable
class StepUpChallengeOffer {
  const StepUpChallengeOffer({
    required this.challengeId,
    required this.acrValues,
    required this.maxAgeSeconds,
    required this.message,
    this.challengeExpiresInSeconds,
    this.reason,
  });

  final String challengeId;
  final String acrValues;
  final int maxAgeSeconds;
  final String message;
  final int? challengeExpiresInSeconds;

  /// Diagnostic-only reason ("missing_auth_time" / "auth_time_stale").
  /// Surfaces in diagnostic chips; NOT shown to end users (the user-
  /// facing message lives in [message]).
  final String? reason;

  /// Parses a (statusCode, headers, body) triple into a typed offer.
  /// Returns null when the response is NOT a step-up challenge so the
  /// caller can fall back to its existing 401 handling.
  static StepUpChallengeOffer? tryParse({
    required int statusCode,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) {
    if (statusCode != 401) return null;
    final wwwHeader = _findHeaderCaseInsensitive(
      headers,
      kStepUpWwwAuthenticateHeader,
    );
    if (wwwHeader == null) return null;
    final parsedHeader = _parseWwwAuthenticate(wwwHeader);
    if (parsedHeader == null) return null;
    if (parsedHeader.error != kStepUpErrorCode) return null;
    final challengeIdRaw = body['challenge_id'];
    if (challengeIdRaw is! String || challengeIdRaw.isEmpty) return null;
    final messageRaw = body['message'];
    final message = (messageRaw is String && messageRaw.isNotEmpty)
        ? messageRaw
        : (parsedHeader.errorDescription ??
            'Fresh authentication is required.');
    final reasonRaw = body['reason'];
    final expiresInRaw = body['challenge_expires_in_seconds'];
    final maxAgeBody = body['max_age_seconds'];
    final maxAgeSeconds = _readInt(maxAgeBody) ?? parsedHeader.maxAge ?? 300;
    return StepUpChallengeOffer(
      challengeId: challengeIdRaw,
      acrValues: parsedHeader.acrValues ?? 'urn:mfa',
      maxAgeSeconds: maxAgeSeconds,
      message: message,
      challengeExpiresInSeconds: _readInt(expiresInRaw),
      reason: reasonRaw is String ? reasonRaw : null,
    );
  }
}

/// Listener seam wired by the operator-web shell. The shell registers
/// an implementation that drives the user through the fresh-auth flow
/// and resolves to a fresh ID token; the handler then re-issues the
/// original request with the new token + the challenge id header.
///
/// Mirrors `MfaFreshnessRedirectListener` from
/// `lib/auth/mfa_freshness_redirect_listener.dart` (the older
/// full-re-auth path that B11.2.b's step-up flow replaces for routes
/// in `kStepUpSensitiveRoutes`).
abstract class StepUpChallengeReauthHook {
  /// Drives the user through fresh auth. Resolves to a fresh ID token
  /// when the user successfully re-authenticates, OR null when the
  /// user cancels / the flow times out. Implementations MUST NOT
  /// throw on user-cancel — the calling gateway is mid-flight and any
  /// throw would mask the original 401 surface.
  Future<String?> resolveFreshAuth(StepUpChallengeOffer offer);
}

/// No-op hook used as a default so gateways can call into the seam
/// without a null check. Always returns null (treated as "user
/// cancelled / fresh auth unavailable") so the gateway propagates the
/// original 401 surface unchanged.
class NoopStepUpChallengeReauthHook implements StepUpChallengeReauthHook {
  const NoopStepUpChallengeReauthHook();

  @override
  Future<String?> resolveFreshAuth(StepUpChallengeOffer offer) async => null;
}

/// Recording fake — used in tests to assert the gateway dispatched
/// exactly one fresh-auth request with the expected challenge id.
class RecordingStepUpChallengeReauthHook implements StepUpChallengeReauthHook {
  RecordingStepUpChallengeReauthHook({this.respondWith});

  final String? respondWith;
  final List<StepUpChallengeOffer> events = <StepUpChallengeOffer>[];

  @override
  Future<String?> resolveFreshAuth(StepUpChallengeOffer offer) async {
    events.add(offer);
    return respondWith;
  }
}

/// Replay callback shape — accepts a fresh token + the challenge id
/// header and returns the result of re-running the original request.
/// Generic parameter [T] is the gateway's success-shape; on failure
/// the callback may throw whatever exception the gateway normally
/// emits.
typedef StepUpReplayFn<T> = Future<T> Function({
  required String freshIdToken,
  required String challengeId,
});

/// Top-level helper. Given a parsed [StepUpChallengeOffer], drives the
/// reauth hook + replays the original request. Returns the replay
/// result on success.
///
/// Throws [StepUpChallengeAbortedException] when the reauth hook
/// returns null (user cancelled / hook unavailable). The caller can
/// catch this to map back to the gateway's existing failure UX.
Future<T> runStepUpChallenge<T>({
  required StepUpChallengeOffer offer,
  required StepUpChallengeReauthHook hook,
  required StepUpReplayFn<T> replay,
}) async {
  final freshToken = await hook.resolveFreshAuth(offer);
  if (freshToken == null || freshToken.isEmpty) {
    throw StepUpChallengeAbortedException(offer: offer);
  }
  return replay(
    freshIdToken: freshToken,
    // Addendum A1: the challenge id is passed as a request HEADER
    // value by the gateway — see callers in
    // `lib/operator_web/services/web_account_gateway.dart` and the
    // proxy client below. The id is NEVER appended to a URL.
    challengeId: offer.challengeId,
  );
}

/// Thrown by [runStepUpChallenge] when the reauth hook resolves to
/// null (user cancelled, no hook wired, etc.). Gateways catch this
/// to fall back to their original 401 / re-throw discipline.
class StepUpChallengeAbortedException implements Exception {
  const StepUpChallengeAbortedException({required this.offer});

  final StepUpChallengeOffer offer;

  @override
  String toString() =>
      'StepUpChallengeAbortedException(challengeId=${offer.challengeId})';
}

// ─── private ────────────────────────────────────────────────────────

class _ParsedWwwAuthenticate {
  const _ParsedWwwAuthenticate({
    required this.error,
    required this.acrValues,
    required this.maxAge,
    required this.errorDescription,
  });

  final String? error;
  final String? acrValues;
  final int? maxAge;
  final String? errorDescription;
}

/// Parses a `Bearer error="...", acr_values="urn:mfa", max_age=300,
/// error_description="..."` header value. Returns null on bad shape.
_ParsedWwwAuthenticate? _parseWwwAuthenticate(String value) {
  final trimmed = value.trim();
  if (!trimmed.toLowerCase().startsWith('bearer ')) return null;
  final rest = trimmed.substring('Bearer '.length);
  String? error;
  String? acrValues;
  int? maxAge;
  String? errorDescription;
  // The RFC 9470 emitter we ship always uses a fixed key set so a
  // simple split on `,` then `=` is sufficient. Quoted-string values
  // are unwrapped; backslash-escaped chars in the quoted form are
  // restored.
  for (final raw in _splitTopLevel(rest)) {
    final eq = raw.indexOf('=');
    if (eq <= 0) continue;
    final key = raw.substring(0, eq).trim().toLowerCase();
    final rawValue = raw.substring(eq + 1).trim();
    final unquoted = _unquote(rawValue);
    switch (key) {
      case 'error':
        error = unquoted;
      case 'acr_values':
        acrValues = unquoted;
      case 'max_age':
        maxAge = int.tryParse(unquoted);
      case 'error_description':
        errorDescription = unquoted;
    }
  }
  return _ParsedWwwAuthenticate(
    error: error,
    acrValues: acrValues,
    maxAge: maxAge,
    errorDescription: errorDescription,
  );
}

List<String> _splitTopLevel(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  var escape = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (escape) {
      buf.write(ch);
      escape = false;
      continue;
    }
    if (ch == '\\' && inQuotes) {
      buf.write(ch);
      escape = true;
      continue;
    }
    if (ch == '"') {
      inQuotes = !inQuotes;
      buf.write(ch);
      continue;
    }
    if (ch == ',' && !inQuotes) {
      out.add(buf.toString());
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  if (buf.isNotEmpty) out.add(buf.toString());
  return out;
}

String _unquote(String s) {
  if (s.length < 2) return s;
  if (s.startsWith('"') && s.endsWith('"')) {
    final inner = s.substring(1, s.length - 1);
    return inner.replaceAll(r'\"', '"').replaceAll(r'\\', r'\');
  }
  return s;
}

String? _findHeaderCaseInsensitive(Map<String, String> headers, String name) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) {
      return entry.value;
    }
  }
  return null;
}

int? _readInt(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  if (raw is String) return int.tryParse(raw);
  return null;
}
