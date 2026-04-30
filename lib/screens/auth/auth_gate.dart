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

import '../../services/mfa/mfa_recovery_request_gateway.dart';
import '../../state/auth_session_notifier.dart';
import '../../theme/app_theme.dart';
import 'login_screen.dart';
import 'mfa_challenge_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({
    super.key,
    required this.authenticatedChild,
    this.loadingChild,
    this.mfaRecoveryRequestGateway,
  });

  /// The app shell to render once the user is authenticated.
  final Widget authenticatedChild;

  /// Optional override for the loading state. Defaults to the branded
  /// splash that mirrors the login screen gradient + brand mark.
  final Widget? loadingChild;
  final MfaRecoveryRequestGateway? mfaRecoveryRequestGateway;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AuthSessionNotifier>().state;
    return switch (state) {
      AuthSessionLoading() => loadingChild ?? const _DefaultLoading(),
      AuthSessionUnauthenticated() => const LoginScreen(),
      AuthSessionMfaChallenge() => MfaChallengeScreen(
        recoveryRequestGateway: mfaRecoveryRequestGateway,
      ),
      AuthSessionAuthenticated() => authenticatedChild,
    };
  }
}

class _DefaultLoading extends StatelessWidget {
  const _DefaultLoading();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              AppColors.backgroundDeep,
              AppColors.backgroundMid,
              AppColors.shimmer,
            ],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 92,
                  height: 92,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.sunset.withValues(alpha: 0.18),
                        blurRadius: 24,
                        spreadRadius: 1,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: Image.asset(
                      'assets/images/forge_flow_splash_icon.png',
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Forge & Flow',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.display28(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.sunset,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
