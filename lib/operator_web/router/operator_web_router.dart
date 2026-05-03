// Phase 11W.0 — Operator Web Console router.
//
// Watches the [OperatorWebAuthSource] state stream and renders the
// matching surface — onboarding click-path screens during the
// pre-completed stages, and the [WebAppShell] (with the post-V1
// placeholder Account / Vendor connections bodies) once
// [OnboardingStage.completed] lands.
//
// The router is render-only on the auth state. State transitions are
// driven by the auth source; the router does not push or pop routes
// directly. That keeps the route guard from drifting from the auth
// source — the auth source is the single source of truth for "where
// is this user in the onboarding click path right now."
//
// Browser URL: 11W.0 ships the magic-link landing parser only. The
// router reads `Uri.base.queryParameters['token']` once at startup so
// `/onboarding/welcome?token=...` lands the operator on the welcome
// screen with the token pre-filled. URL synchronization for the rest
// of the click path is intentionally deferred to a follow-up so this
// slice stays scoped — the Hard Promises forbid widening scope mid-
// slice.

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/operator_web_auth_source.dart';
import '../screens/account_placeholder_screen.dart';
import '../screens/mfa_enrollment_screen.dart';
import '../screens/password_setup_screen.dart';
import '../screens/tos_accept_screen.dart';
import '../screens/vendor_connections_placeholder_screen.dart';
import '../screens/welcome_screen.dart';
import '../widgets/web_app_shell.dart';
import '../../theme/app_theme.dart';

/// Stable nav ids for the post-onboarding shell. Tests and deep
/// links key off these.
const String kOperatorWebNavAccount = 'account';
const String kOperatorWebNavVendorConnections = 'vendor_connections';

/// Default nav surface the shell lands on after onboarding completes.
const String kOperatorWebDefaultNavId = kOperatorWebNavAccount;

/// Top-level router widget for the operator-web console. Drop in
/// under a `MaterialApp` with the brand theme.
class OperatorWebRouter extends StatefulWidget {
  const OperatorWebRouter({
    super.key,
    required this.source,
    this.initialMagicLinkToken,
    this.initialNavId = kOperatorWebDefaultNavId,
  });

  /// Auth source the router watches.
  final OperatorWebAuthSource source;

  /// Optional magic-link token surfaced on the welcome screen. The
  /// live entrypoint parses `Uri.base` and passes the result here;
  /// tests pass fixtures directly so the assertion does not depend
  /// on `Uri.base`.
  final String? initialMagicLinkToken;

  /// Initial post-onboarding nav surface. Tests pass
  /// `kOperatorWebNavVendorConnections` to land directly on the
  /// vendor-connections placeholder.
  final String initialNavId;

  @override
  State<OperatorWebRouter> createState() => _OperatorWebRouterState();
}

class _OperatorWebRouterState extends State<OperatorWebRouter> {
  late OperatorWebAuthState _state;
  late StreamSubscription<OperatorWebAuthState> _subscription;
  late String _selectedNavId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _state = widget.source.current;
    _selectedNavId = widget.initialNavId;
    _subscription = widget.source.stream.listen((next) {
      if (!mounted) return;
      setState(() => _state = next);
    });
  }

  @override
  void didUpdateWidget(covariant OperatorWebRouter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _subscription.cancel();
      _state = widget.source.current;
      _subscription = widget.source.stream.listen((next) {
        if (!mounted) return;
        setState(() => _state = next);
      });
    }
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  Future<T> _withBusy<T>(Future<T> Function() task) async {
    setState(() => _busy = true);
    try {
      return await task();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _selectNav(String id) {
    if (id == _selectedNavId) return;
    setState(() => _selectedNavId = id);
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return switch (state) {
      OperatorWebLoading() => const _LoadingSplash(),
      OperatorWebSignedOut() => _buildWelcome(state.lastErrorMessage),
      OperatorWebNeedsToken() => _buildWelcome(state.lastErrorMessage),
      OperatorWebSettingPassword(:final lastErrorMessage) =>
        PasswordSetupScreen(
          onSubmitPassword: ({
            required String password,
            required String confirmation,
          }) async {
            await _withBusy(
              () => widget.source.submitPassword(
                password: password,
                confirmation: confirmation,
              ),
            );
          },
          errorMessage: lastErrorMessage,
          submitting: _busy,
        ),
      OperatorWebEnrollingMfa(:final session, :final lastErrorMessage) =>
        MfaEnrollmentScreen(
          operatorEmail: session.email,
          onBeginEnrollment: ({
            required MfaFactorType factorType,
            String? phoneNumber,
          }) async {
            return _withBusy(
              () => widget.source.beginMfaEnrollment(
                factorType: factorType,
                phoneNumber: phoneNumber,
              ),
            );
          },
          onConfirmEnrollment: ({
            required String enrollmentId,
            required String oneTimeCode,
          }) async {
            await _withBusy(
              () => widget.source.confirmMfaEnrollment(
                enrollmentId: enrollmentId,
                oneTimeCode: oneTimeCode,
              ),
            );
          },
          errorMessage: lastErrorMessage,
          submitting: _busy,
        ),
      OperatorWebAcceptingTos(
        :final session,
        :final tosVersion,
        :final tosBodyMarkdown,
        :final lastErrorMessage,
      ) =>
        TosAcceptScreen(
          session: session,
          tosVersion: tosVersion,
          tosBodyMarkdown: tosBodyMarkdown,
          onAccept: ({required String versionId, required String scope}) async {
            await _withBusy(
              () => widget.source.acceptTos(
                versionId: versionId,
                scope: scope,
              ),
            );
          },
          errorMessage: lastErrorMessage,
          submitting: _busy,
        ),
      OperatorWebForbidden(:final session) => _ForbiddenScreen(
        session: session,
        onSignOut: widget.source.signOut,
      ),
      OperatorWebCompleted(:final session) => _buildPostOnboardingShell(session),
    };
  }

  Widget _buildWelcome(String? error) {
    return WelcomeScreen(
      initialToken: widget.initialMagicLinkToken,
      errorMessage: error,
      submitting: _busy,
      onSubmitToken: (token) async {
        await _withBusy(() => widget.source.verifyMagicLinkToken(token));
      },
    );
  }

  Widget _buildPostOnboardingShell(OperatorWebSession session) {
    final navItems = const <OperatorWebNavItem>[
      OperatorWebNavItem(
        id: kOperatorWebNavAccount,
        title: 'Account',
        icon: Icons.business_outlined,
        placeholder: true,
      ),
      OperatorWebNavItem(
        id: kOperatorWebNavVendorConnections,
        title: 'Vendor connections',
        icon: Icons.cable_outlined,
        placeholder: true,
      ),
    ];
    final body = _selectedNavId == kOperatorWebNavVendorConnections
        ? VendorConnectionsPlaceholderScreen(
            session: session,
            locationId: session.primaryLocationId,
          )
        : AccountPlaceholderScreen(session: session);
    return WebAppShell(
      session: session,
      navItems: navItems,
      selectedNavId: _selectedNavId,
      onSelectNav: _selectNav,
      body: body,
      onSignOut: () {
        widget.source.signOut();
      },
    );
  }
}

class _LoadingSplash extends StatelessWidget {
  const _LoadingSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: Center(
        child: SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      ),
    );
  }
}

class _ForbiddenScreen extends StatelessWidget {
  const _ForbiddenScreen({required this.session, required this.onSignOut});

  final OperatorWebSession session;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ClipRRect(
                key: const Key('operator_web_forbidden_card'),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.backgroundSurface,
                    border: Border.all(color: AppColors.borderSubtle, width: 1),
                  ),
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.lock_outline,
                            size: 18,
                            color: AppColors.negative,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Operator web access not available',
                              style: AppTextStyles.mono15(
                                color: AppColors.textPrimary,
                                weight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'Signed in as '
                        '${session.email.isEmpty ? session.uid : session.email}, '
                        'but the Forge & Flow Operator Web Console is for '
                        'operator owners, operator admins, and location '
                        'managers. Floor staff and other roles can keep '
                        'using the Forge & Flow mobile app — most '
                        'day-to-day actions live there.',
                        style: AppTextStyles.body13(
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        height: 42,
                        child: OutlinedButton(
                          key: const Key('operator_web_forbidden_signout'),
                          onPressed: () => onSignOut(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.sunsetDark,
                            side: const BorderSide(
                              color: AppColors.sunsetDark,
                              width: 1,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          child: const Text('Sign out'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
