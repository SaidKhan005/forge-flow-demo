// Phase 9.4 - MFA TOTP challenge screen.
//
// Replaces the 9.3 [MfaChallengePlaceholder]. Renders a single 6-digit
// TOTP entry with an optional "use a recovery code instead" path.
// On submit, drives the existing
// [AuthSessionNotifier.completeTotpChallenge] (which 9.3 already
// wired) — the difference vs. the placeholder is real form input,
// per-attempt rate-limit guarding (1 / minute, 5 / 24h per the
// decision lock), and a recovery-code fallback.
//
// The actual recovery-code consumption happens server-side: the proxy
// receives the recovery-code path's `oneTimeCode` value, looks it up
// via [RecoveryCodeHasher.verify] against the user's stored hashes,
// marks the matching `mfa_factors` row's `used_at`, and emits the
// completion audit row. This screen only collects the input.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/mfa/mfa_recovery_request_gateway.dart';
import '../../state/auth_session_notifier.dart';
import '../../theme/app_theme.dart';

class MfaChallengeScreen extends StatefulWidget {
  const MfaChallengeScreen({super.key, this.recoveryRequestGateway});

  final MfaRecoveryRequestGateway? recoveryRequestGateway;

  @override
  State<MfaChallengeScreen> createState() => _MfaChallengeScreenState();
}

class _MfaChallengeScreenState extends State<MfaChallengeScreen> {
  final _codeController = TextEditingController();
  bool _useRecoveryCode = false;
  bool _submitting = false;
  bool _requestingRecoveryHelp = false;
  String? _localError;
  String? _recoveryHelpMessage;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit(AuthSessionMfaChallenge challenge) async {
    if (_submitting) return;
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _localError = 'Enter a code to continue.');
      return;
    }
    final factorId = _useRecoveryCode
        ? 'recovery_code'
        : (challenge.factorIds.isNotEmpty ? challenge.factorIds.first : 'totp');
    setState(() {
      _localError = null;
      _submitting = true;
    });
    try {
      await context.read<AuthSessionNotifier>().completeTotpChallenge(
        factorId: factorId,
        oneTimeCode: code,
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _requestAdminHelp(AuthSessionMfaChallenge challenge) async {
    if (_requestingRecoveryHelp) return;
    final gateway = widget.recoveryRequestGateway;
    if (gateway == null) {
      setState(() {
        _recoveryHelpMessage = 'Contact your restaurant admin directly.';
      });
      return;
    }
    setState(() {
      _localError = null;
      _recoveryHelpMessage = null;
      _requestingRecoveryHelp = true;
    });
    try {
      await gateway.requestRecovery(
        MfaRecoveryRequestCommand(email: challenge.email),
      );
      if (!mounted) return;
      setState(() {
        _recoveryHelpMessage =
            'Recovery request sent to your restaurant admin.';
      });
    } on MfaRecoveryRequestRejected {
      if (!mounted) return;
      setState(() {
        _recoveryHelpMessage =
            'Recovery request could not be sent. Contact your restaurant admin directly.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _recoveryHelpMessage =
            'Recovery request could not be sent. Contact your restaurant admin directly.';
      });
    } finally {
      if (mounted) {
        setState(() => _requestingRecoveryHelp = false);
      }
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
    final notifierError = notifier.state is AuthSessionUnauthenticated
        ? (notifier.state as AuthSessionUnauthenticated).lastErrorMessage
        : null;
    final errorMessage = _localError ?? notifierError;

    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: ClipOval(
                    child: Image.asset(
                      'assets/images/forge_flow_splash_icon.png',
                      width: 54,
                      height: 54,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Two-factor verification',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  challenge.email,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textMuted),
                ),
                const SizedBox(height: 24),
                if (errorMessage != null) ...[
                  _ErrorBanner(message: errorMessage),
                  const SizedBox(height: 16),
                ],
                TextField(
                  key: const Key('mfa_code_field'),
                  controller: _codeController,
                  enabled: !_submitting,
                  keyboardType: _useRecoveryCode
                      ? TextInputType.text
                      : TextInputType.number,
                  autofillHints: _useRecoveryCode
                      ? const <String>[]
                      : const <String>[AutofillHints.oneTimeCode],
                  onSubmitted: (_) => _submit(challenge),
                  decoration: InputDecoration(
                    labelText: _useRecoveryCode
                        ? 'Recovery code (e.g. ABCD-EFGH-JKMN)'
                        : '6-digit code',
                    helperText: _useRecoveryCode
                        ? 'Use one of the recovery codes saved during setup.'
                        : 'Displayed on your authenticator app.',
                    border: const OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 12),
                _RestaurantAdminRecoveryHelp(
                  requesting: _requestingRecoveryHelp,
                  message: _recoveryHelpMessage,
                  onPressed: _submitting
                      ? null
                      : () => _requestAdminHelp(challenge),
                ),
                const SizedBox(height: 12),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton(
                      key: const Key('mfa_recovery_toggle'),
                      onPressed: _submitting
                          ? null
                          : () {
                              setState(() {
                                _useRecoveryCode = !_useRecoveryCode;
                                _codeController.clear();
                                _localError = null;
                              });
                            },
                      child: Text(
                        _useRecoveryCode
                            ? 'Use authenticator app'
                            : 'Use recovery code',
                      ),
                    ),
                    TextButton(
                      key: const Key('mfa_cancel_button'),
                      onPressed: _submitting
                          ? null
                          : notifier.signOutThisSession,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('mfa_submit_button'),
                  onPressed: _submitting ? null : () => _submit(challenge),
                  child: _submitting
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Verify'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RestaurantAdminRecoveryHelp extends StatelessWidget {
  const _RestaurantAdminRecoveryHelp({
    required this.requesting,
    required this.message,
    required this.onPressed,
  });

  final bool requesting;
  final String? message;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('mfa_admin_recovery_help'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'No access to your authenticator app or recovery codes?',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 6),
        OutlinedButton.icon(
          key: const Key('mfa_contact_admin_button'),
          onPressed: requesting ? null : onPressed,
          icon: requesting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.support_agent_rounded, size: 18),
          label: Text(
            requesting ? 'Sending request...' : 'Contact restaurant admin',
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 6),
          Text(
            message!,
            key: const Key('mfa_admin_recovery_message'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('mfa_error_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.14),
        border: Border.all(color: AppColors.negative),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: const TextStyle(color: AppColors.textPrimary),
      ),
    );
  }
}
