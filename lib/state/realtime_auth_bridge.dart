// Phase 10a.UX.0 — Auth-to-realtime bridge.
//
// Bootstrap-level glue between [AuthSessionNotifier] and the
// long-lived [RealtimeSubscription] (when one was wired by the
// production main entry). Lives ABOVE every operator surface — the
// standalone Forge & Flow shell, the embedded F&F destination
// inside Barrio, the Barrio home itself — so the per-operator
// isolation rule (CLAUDE.md Hard Promise #4) holds even when the
// operator pops back to a non-F&F surface before signing out:
//
//   * Sign-in (or rehydrated session at cold start) →
//     [RealtimeSubscription.setTenantContext] with the active
//     `(operatorId, firebaseIdToken)`.
//   * Sign-out (or expired token without refresh) →
//     [RealtimeSubscription.clearTenantContext], which tears down
//     the channel, cancels the back-off timer, bumps the generation
//     so an in-flight stale connect cannot bind to the cleared
//     scope, and emits idle.
//
// Earlier slice attempts hosted the bridge inside `_AppShellState`,
// but that made the listener disappear when the embedded F&F shell
// was popped back to the Barrio home — leaving the previous
// operator's WebSocket alive across a subsequent sign-out. The
// bridge MUST live for the lifetime of the subscription; bootstrap
// is where that lifetime starts.
//
// No-ops when the bootstrap did not wire a subscription (demo /
// no-Firebase paths, widget tests that bypass bootstrap).

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../auth/auth_session.dart';
import '../services/realtime/realtime_subscription.dart';
import 'auth_session_notifier.dart';

/// Wraps the app under bootstrap so an active
/// [RealtimeSubscription] always tracks the
/// [AuthSessionNotifier] state, regardless of which operator
/// surface is currently mounted.
class RealtimeAuthBridge extends StatefulWidget {
  const RealtimeAuthBridge({super.key, required this.child});

  final Widget child;

  @override
  State<RealtimeAuthBridge> createState() => _RealtimeAuthBridgeState();
}

class _RealtimeAuthBridgeState extends State<RealtimeAuthBridge> {
  AuthSessionNotifier? _authNotifier;
  String? _lastTenantKey;

  @override
  void initState() {
    super.initState();
    // Provider lookup must happen after the first frame; reading
    // providers from initState directly throws.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attach();
    });
  }

  void _attach() {
    if (!mounted) return;
    final authNotifier = _resolveAuthNotifier();
    if (authNotifier == null) return;
    authNotifier.addListener(_sync);
    _authNotifier = authNotifier;
    // Drive an initial pass so a session that was rehydrated at
    // cold start (before the listener attached) still pushes its
    // tenant context into the subscription.
    _sync();
  }

  /// Pushes the current operator + bearer token into the
  /// [RealtimeSubscription] whenever the auth session transitions.
  /// Idempotent — duplicate notifier fires for the same
  /// `(operatorId, token)` pair are dropped so the back-off curve
  /// is not reset by every unrelated [AuthSessionNotifier] tick.
  ///
  /// On unauthenticated transitions (sign-out, expired session),
  /// [RealtimeSubscription.clearTenantContext] is called so the
  /// previous operator's WebSocket cannot stay connected or keep
  /// walking the back-off curve under the per-operator isolation
  /// rule (CLAUDE.md Hard Promise #4).
  void _sync() {
    if (!mounted) return;
    final subscription = _resolveSubscription();
    if (subscription == null) return;
    final session = _resolveAuthNotifier()?.session;
    if (session == null) {
      if (_lastTenantKey != null) {
        _lastTenantKey = null;
        unawaited(subscription.clearTenantContext());
      }
      return;
    }
    final tenantKey = _tenantKeyFor(session);
    if (tenantKey == _lastTenantKey) return;
    _lastTenantKey = tenantKey;
    unawaited(
      subscription.setTenantContext(
        RealtimeTenantContext(
          operatorId: session.operatorId,
          authToken: session.firebaseIdToken,
        ),
      ),
    );
  }

  RealtimeSubscription? _resolveSubscription() {
    try {
      return Provider.of<RealtimeSubscription?>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  AuthSessionNotifier? _resolveAuthNotifier() {
    try {
      return Provider.of<AuthSessionNotifier>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  static String _tenantKeyFor(AuthSession session) =>
      '${session.operatorId}|${session.firebaseIdToken}';

  @override
  void dispose() {
    _authNotifier?.removeListener(_sync);
    _authNotifier = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Visible-for-tests state-key reducer used by [RealtimeAuthBridge]
/// — exposed so unit tests can compare tenant identity without
/// recomputing the format.
@visibleForTesting
String tenantKeyForRealtimeAuthBridgeTest(AuthSession session) =>
    _RealtimeAuthBridgeState._tenantKeyFor(session);
