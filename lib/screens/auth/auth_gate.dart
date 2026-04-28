// Phase 9.3 - AuthGate widget.
//
// Sits at the root of each app shell (Forge & Flow standalone +
// Barrio host) and decides which surface to render based on the
// [AuthSessionNotifier] state:
//
//   - loading        → [loadingChild] (or a default centered spinner)
//   - unauthenticated → [LoginScreen]
//   - mfa-challenge  → MFA challenge UI (placeholder hook in 9.3;
//                      full TOTP UI lands in 9.4)
//   - authenticated  → [authenticatedChild] (the app shell)
//
// The gate intentionally does NOT install the notifier — that
// happens in `forge_flow_bootstrap.dart` so both shells share the
// same instance and Barrio's embedded Forge & Flow surface inherits
// the live session.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_session_notifier.dart';
import 'login_screen.dart';
import 'mfa_challenge_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.authenticatedChild,
    this.loadingChild,
  });

  /// The app shell to render once the user is authenticated.
  final Widget authenticatedChild;

  /// Optional override for the loading state. Defaults to a
  /// centered [CircularProgressIndicator] on a black background to
  /// match the existing splash visuals.
  final Widget? loadingChild;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AuthSessionNotifier>().state;
    return switch (state) {
      AuthSessionLoading() => loadingChild ?? const _DefaultLoading(),
      AuthSessionUnauthenticated() => const LoginScreen(),
      AuthSessionMfaChallenge() => const MfaChallengeScreen(),
      AuthSessionAuthenticated() => authenticatedChild,
    };
  }
}

class _DefaultLoading extends StatelessWidget {
  const _DefaultLoading();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
