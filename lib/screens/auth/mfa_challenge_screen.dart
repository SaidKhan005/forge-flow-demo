// Phase 9.4 - MFA TOTP challenge screen.
//
// Operator/mobile adapter around the shared TOTP challenge view. The
// reusable page chrome lives in `totp_challenge_view.dart`; this file
// keeps the operator session state, recovery request routing, and
// restaurant-admin copy out of the admin console.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/auth_login_service.dart';
import '../../services/mfa/mfa_recovery_request_gateway.dart';
import '../../state/auth_session_notifier.dart';
import '../../theme/app_theme.dart';
import 'totp_challenge_view.dart';

class MfaChallengeScreen extends StatefulWidget {
  const MfaChallengeScreen({super.key, this.recoveryRequestGateway});

  final MfaRecoveryRequestGateway? recoveryRequestGateway;

  @override
  State<MfaChallengeScreen> createState() => _MfaChallengeScreenState();
}

class _MfaChallengeScreenState extends State<MfaChallengeScreen> {
  String? _localError;
  String? _adminHelpMessage;

  Future<void> _submit(AuthSessionMfaChallenge challenge, String code) async {
    final factorId = challenge.factorIds.isNotEmpty
        ? challenge.factorIds.first
        : 'totp';
    final result = await context
        .read<AuthSessionNotifier>()
        .completeTotpChallenge(factorId: factorId, oneTimeCode: code);
    if (!mounted) return;
    if (result is AuthLoginFailure) {
      setState(() => _localError = result.message);
    } else {
      setState(() => _localError = null);
    }
  }

  Future<void> _requestAdminHelp(AuthSessionMfaChallenge challenge) async {
    final gateway = widget.recoveryRequestGateway;
    if (gateway == null) {
      setState(() {
        _adminHelpMessage = 'Contact your restaurant admin directly.';
      });
      return;
    }
    setState(() {
      _localError = null;
      _adminHelpMessage = null;
    });
    try {
      final accepted = await gateway.requestRecovery(
        MfaRecoveryRequestCommand(email: challenge.email),
      );
      if (!mounted) return;
      setState(() {
        _adminHelpMessage = accepted.queued
            ? 'Help request recorded. Contact your restaurant admin directly if you need urgent access.'
            : 'We could not route this automatically. Contact your restaurant admin directly.';
      });
    } on MfaRecoveryRequestRejected catch (error) {
      if (!mounted) return;
      setState(() {
        _adminHelpMessage = error.code == 'mfa_recovery_request_rate_limited'
            ? 'Too many access requests. Try again later or contact your restaurant admin directly.'
            : 'Help request could not be recorded. Contact your restaurant admin directly.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _adminHelpMessage =
            'Help request could not be sent. Contact your restaurant admin directly.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AuthSessionNotifier>();
    final state = notifier.state;
    if (state is! AuthSessionMfaChallenge) {
      return const Scaffold(
        backgroundColor: AppColors.backgroundDeep,
        body: SizedBox.shrink(),
      );
    }
    final challenge = state;
    return TotpChallengeView(
      email: challenge.email,
      errorMessage: _localError,
      helpMessage: _adminHelpMessage,
      onSubmit: (code) => _submit(challenge, code),
      onRequestHelp: () => _requestAdminHelp(challenge),
      onCancel: notifier.signOutThisSession,
    );
  }
}
