// Phase 9 / CODE_OPS_DEBT Theme A — Session-claim freshness resolver.
//
// The admin console and proxy both need a single source of truth for
// "is this session's MFA fresh enough to authorize a sensitive
// action?" The four `const … = false` constants in
// `lib/admin/admin_routes.dart` (canEditSeeded, canResetMfa,
// canIssuePairedErasure, canExportAuditLog) used to be hard-pinned
// to false because no claim was wired through. This resolver closes
// that gap by reading `lastFreshAuthAt` (the JWT `auth_time` claim,
// which Identity Platform stamps at original sign-in AND at MFA
// completion) and comparing it to a configurable freshness window.
//
// Decisions (operator-locked 2026-05-07):
//   * Window default: **3600 s (1 hour)**. This is longer than the
//     historic 5-minute fresh-auth window because the admin console
//     workflows hold one tab open across multi-step ops. Operator
//     decision: 1 hour, not 5 minutes.
//   * Env override: `MFA_FRESHNESS_WINDOW_SECONDS` (proxy + Cloud Run).
//     A non-numeric / non-positive value falls back to the default
//     and is logged at startup.
//   * Stale → **full re-authentication**: the proxy returns 401
//     `fresh_mfa_required` with a `redirect_uri` that bounces the
//     client to `/auth/login` so the user re-enters password + MFA.
//     This is intentionally NOT a step-up modal; the admin shell
//     signs out before pushing the redirect.
//
// The resolver itself reads only the `AuthSession.lastFreshAuthAt`
// field (which carries the `auth_time` claim verbatim per
// `lib/auth/auth_session.dart`). It does no I/O and is therefore
// safe to call on every paint of the admin shell.
//
// B11.2.b adapter — recognizing server-side step-up challenges.
// The proxy now emits RFC 9470 step-up challenges (401 + WWW-
// Authenticate: Bearer error="insufficient_user_authentication") for
// the routes listed in `tool/advisor_proxy/auth_step_up_routes.dart::
// kStepUpSensitiveRoutes`. Two recognition helpers below classify a
// 401 response shape so the gateway / shell can branch:
//   * [recognizeStepUpChallenge401] — true when the 401 carries a
//     step-up challenge (server-side gate). Caller should drive the
//     incremental re-auth flow via
//     `lib/operator_web/auth/step_up_challenge_handler.dart` and
//     replay the original request with the `Step-Up-Challenge-Id`
//     header (NEVER as a URL param — addendum A1).
//   * [isFreshMfaRedirect403] — true when the 403 carries the
//     existing `mfa_freshness_required` payload. Caller drives the
//     legacy full-re-auth flow via
//     `lib/auth/mfa_freshness_redirect_listener.dart`.
// Both helpers are pure — no I/O, no FFI, no Flutter dependency —
// so they can be called from any layer (gateway, screen, test).

import 'dart:io';

import 'auth_session.dart';

/// Single source of truth for MFA freshness across the admin console
/// and the proxy. The resolver knows nothing about route decorations
/// or HTTP — call sites read [isFresh] for the gate and
/// [secondsUntilStale] for diagnostic chips ("freshness expires in
/// 14 minutes"). Stale sessions trigger a full re-auth flow at the
/// gate / proxy boundary; this resolver does not perform that flow
/// itself.
abstract class FreshMfaResolver {
  /// True iff the session's `lastFreshAuthAt` is within the
  /// configured freshness window of [nowOverride] (defaults to
  /// `DateTime.now()`).
  bool isFresh(AuthSession session, {DateTime? nowOverride});

  /// Seconds remaining before the session falls outside the freshness
  /// window. Returns null when [session] has no MFA-fresh stamp at
  /// all (treat as "never fresh"), 0 when already stale, otherwise
  /// the positive integer seconds remaining.
  int? secondsUntilStale(AuthSession session, {DateTime? nowOverride});
}

/// Production resolver — reads `AuthSession.lastFreshAuthAt` (the
/// `auth_time` JWT claim that Identity Platform stamps at sign-in
/// and at MFA completion) and compares to the configured window.
///
/// The window is resolved once at construction:
///   1. Explicit [windowSeconds] argument (used by tests + proxy
///      bootstrap when env override is read up-front).
///   2. Falls back to `MFA_FRESHNESS_WINDOW_SECONDS` env var.
///   3. Falls back to [defaultWindowSeconds] (3600 s).
class JwtFreshMfaResolver implements FreshMfaResolver {
  JwtFreshMfaResolver({int? windowSeconds, DateTime Function()? now})
    : _windowSeconds = _resolveWindow(windowSeconds),
      _now = now ?? DateTime.now;

  /// Operator-locked default. 3600 s = 1 hour. Long enough to cover
  /// a multi-step admin workflow on a single MFA stamp; short enough
  /// that a stolen session still has a hard ceiling.
  static const int defaultWindowSeconds = 3600;

  /// Env var name. Overrides [defaultWindowSeconds] when the env var
  /// parses to a positive int.
  static const String envVarName = 'MFA_FRESHNESS_WINDOW_SECONDS';

  final int _windowSeconds;
  final DateTime Function() _now;

  /// Window currently in effect (seconds). Exposed for log lines /
  /// diagnostic surfaces; not meant for security decisions.
  int get windowSeconds => _windowSeconds;

  Duration get window => Duration(seconds: _windowSeconds);

  static int _resolveWindow(int? explicit) {
    if (explicit != null && explicit > 0) return explicit;
    final raw = Platform.environment[envVarName];
    if (raw == null || raw.isEmpty) return defaultWindowSeconds;
    final parsed = int.tryParse(raw.trim());
    if (parsed == null || parsed <= 0) return defaultWindowSeconds;
    return parsed;
  }

  @override
  bool isFresh(AuthSession session, {DateTime? nowOverride}) {
    final remaining = secondsUntilStale(session, nowOverride: nowOverride);
    return remaining != null && remaining > 0;
  }

  @override
  int? secondsUntilStale(AuthSession session, {DateTime? nowOverride}) {
    final stamp = session.lastFreshAuthAt;
    // The session model never stores `null` for lastFreshAuthAt today
    // (it is required), but defensive against future shape changes
    // and against the epoch-zero placeholder the proxy uses when the
    // claim is missing.
    if (stamp.millisecondsSinceEpoch <= 0) return null;
    final now = nowOverride ?? _now();
    final elapsed = now.difference(stamp).inSeconds;
    if (elapsed >= _windowSeconds) return 0;
    return _windowSeconds - elapsed;
  }
}

/// B11.2.b — server-side step-up recognition. Returns true when the
/// (statusCode, headers, body) triple matches the proxy's RFC 9470
/// challenge emission shape. The check is conservative: it requires
/// BOTH the `WWW-Authenticate: Bearer error="insufficient_user_
/// authentication"` header AND a non-empty `challenge_id` in the JSON
/// body. Pure function; no I/O.
///
/// Use this from gateways that receive a 401 to decide whether to
/// drive the incremental step-up flow (via
/// `lib/operator_web/auth/step_up_challenge_handler.dart`) vs.
/// surfacing the 401 to the screen layer as a generic auth failure.
bool recognizeStepUpChallenge401({
  required int statusCode,
  required Map<String, String> headers,
  required Map<String, Object?> body,
}) {
  if (statusCode != 401) return false;
  // Find the WWW-Authenticate header (HTTP headers are case-
  // insensitive on the wire; client libraries normalize differently).
  String? wwwAuth;
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'www-authenticate') {
      wwwAuth = entry.value;
      break;
    }
  }
  if (wwwAuth == null) return false;
  final lower = wwwAuth.toLowerCase();
  if (!lower.startsWith('bearer ')) return false;
  if (!lower.contains('error="insufficient_user_authentication"')) {
    return false;
  }
  final challengeIdRaw = body['challenge_id'];
  return challengeIdRaw is String && challengeIdRaw.isNotEmpty;
}

/// B11.2.b — legacy `mfa_freshness_required` 403 recognizer. Returns
/// true when the (statusCode, body) pair matches the older proxy
/// emission shape (full re-auth flow via
/// `mfa_freshness_redirect_listener.dart`). Pure function; no I/O.
///
/// Kept alongside [recognizeStepUpChallenge401] so the two recognition
/// helpers live in one file and a gateway can branch in one place:
///   * step-up 401 -> incremental re-auth + replay-with-challenge
///   * mfa_freshness 403 -> full sign-out + redirect
bool isFreshMfaRedirect403({
  required int statusCode,
  required Map<String, Object?> body,
}) {
  if (statusCode != 403) return false;
  final error = body['error'];
  return error is String && error == 'mfa_freshness_required';
}

/// Test fake — fixed answer regardless of the session value.
class FakeFreshMfaResolver implements FreshMfaResolver {
  FakeFreshMfaResolver({this.fresh = true, this.remainingSeconds});

  final bool fresh;
  final int? remainingSeconds;

  @override
  bool isFresh(AuthSession session, {DateTime? nowOverride}) => fresh;

  @override
  int? secondsUntilStale(AuthSession session, {DateTime? nowOverride}) {
    if (remainingSeconds != null) return remainingSeconds;
    return fresh ? JwtFreshMfaResolver.defaultWindowSeconds : 0;
  }
}
