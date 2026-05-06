// Phase 11W.0 / Wave A1 - operator-web session lifecycle gateway.
//
// Thin facade over `OperatorWebAuthSource` that owns the three
// session-lifecycle operations the post-onboarding shell + screens
// invoke:
//
//   * refresh()                     - pull a fresh id token; on
//                                     failure (no token, expired,
//                                     network) drop to NeedsSignIn.
//   * signOut()                     - operator-initiated sign-out;
//                                     emits NeedsSignIn cleanly.
//   * forceLogoutCurrentSession()   - sessions screen revokes its
//                                     own row; emits NeedsSignIn so
//                                     the router lands on the sign-in
//                                     surface.
//   * handleScopeMismatch()         - proxy returned identity for a
//                                     different operator/location;
//                                     drop to NeedsSignIn so the
//                                     operator can re-authenticate
//                                     with the correct scope.
//
// All four paths funnel through `OperatorWebAuthSource.signOut()`,
// which emits `OperatorWebNeedsSignIn` through the auth source's
// shared `_emit` helper. That helper enforces the lifecycle
// invariant defined in
// `lib/operator_web/auth/firebase_operator_web_auth_source.dart`:
// the cached `_currentSessionId` is cleared on every NeedsSignIn
// transition so a re-sign-in by a different user (same browser)
// cannot mark the wrong row as `(this session)` on the sessions
// screen. Centralizing the four lifecycle entry points behind this
// gateway keeps every caller honoring that invariant without each
// caller having to rediscover it.
//
// The gateway is injectable via the `Future<String?> Function()`
// id-token provider so refresh() works without a hard dependency on
// `firebase_auth_web`. Live wiring at `lib/main_operator_web.dart`
// passes the `FirebaseAuthSdkClient.currentIdToken` reference;
// tests pass a stub.
//
// No offline storage; no direct proxy calls. Live HTTP traffic for
// the active-sessions screen lives in
// `lib/operator_web/services/web_team_sessions_gateway.dart`. This
// gateway only reflects lifecycle state into the auth source.

import 'dart:async';

import '../auth/operator_web_auth_source.dart';

/// Returns the current Firebase id token (or null when no session
/// exists). The Firebase SDK adapter exposes this as
/// `FirebaseAuthClient.currentIdToken`; demo mode passes a closure
/// that returns null so refresh() takes the no-token branch.
typedef WebSessionIdTokenProvider = Future<String?> Function();

/// Operator-web session lifecycle contract. Implementations forward
/// every termination path through the auth source so the
/// `OperatorWebNeedsSignIn` lifecycle invariant stays in one place.
abstract class WebSessionGateway {
  /// Refresh the active session. On a missing/expired id token or
  /// any unhandled error the gateway hands off to [signOut] so the
  /// router lands on the sign-in surface with a clean session id.
  Future<void> refresh();

  /// Operator-initiated sign-out. Emits NeedsSignIn cleanly.
  Future<void> signOut();

  /// Force-logout the actor's own session (e.g. after revoking the
  /// `(this session)` row on the Sessions screen). Behaves like
  /// [signOut] but is a separate seam so call sites read clearly.
  Future<void> forceLogoutCurrentSession();

  /// The proxy returned a permission snapshot scoped to a different
  /// operator/location than the session ledger. Drop to NeedsSignIn
  /// so the operator can re-authenticate with the correct scope and
  /// `_currentSessionId` is cleared.
  Future<void> handleScopeMismatch();
}

/// Default implementation. Wraps any [OperatorWebAuthSource] (demo
/// or live) and delegates the four lifecycle paths through
/// [OperatorWebAuthSource.signOut]. The `_emit` helper in
/// [FirebaseOperatorWebAuthSource] guarantees the
/// `_currentSessionId` reset on every NeedsSignIn transition.
class OperatorWebSessionGateway implements WebSessionGateway {
  OperatorWebSessionGateway({
    required OperatorWebAuthSource source,
    WebSessionIdTokenProvider? idTokenProvider,
  })  : _source = source,
        _idTokenProvider = idTokenProvider;

  final OperatorWebAuthSource _source;
  final WebSessionIdTokenProvider? _idTokenProvider;

  @override
  Future<void> refresh() async {
    final provider = _idTokenProvider;
    if (provider == null) {
      // Demo mode: no live token to refresh; the stage machine is
      // driven by the demo source directly. No-op.
      return;
    }
    String? token;
    try {
      token = await provider();
    } catch (_) {
      await _source.signOut();
      return;
    }
    if (token == null || token.trim().isEmpty) {
      await _source.signOut();
    }
  }

  @override
  Future<void> signOut() => _source.signOut();

  @override
  Future<void> forceLogoutCurrentSession() => _source.signOut();

  @override
  Future<void> handleScopeMismatch() => _source.signOut();
}
