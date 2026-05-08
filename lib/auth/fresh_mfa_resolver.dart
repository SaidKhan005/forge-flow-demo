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
