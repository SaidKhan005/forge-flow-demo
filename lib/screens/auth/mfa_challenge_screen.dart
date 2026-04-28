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

import '../../state/auth_session_notifier.dart';

class MfaChallengeScreen extends StatefulWidget {
  const MfaChallengeScreen({super.key});

  @override
  State<MfaChallengeScreen> createState() => _MfaChallengeScreenState();
}

class _MfaChallengeScreenState extends State<MfaChallengeScreen> {
  final _codeController = TextEditingController();
  bool _useRecoveryCode = false;
  bool _submitting = false;
  String? _localError;

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

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AuthSessionNotifier>();
    final state = notifier.state;
    if (state is! AuthSessionMfaChallenge) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.shrink(),
      );
    }
    final challenge = state;
    final notifierError = notifier.state is AuthSessionUnauthenticated
        ? (notifier.state as AuthSessionUnauthenticated).lastErrorMessage
        : null;
    final errorMessage = _localError ?? notifierError;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.shield_outlined,
                  color: Colors.white70,
                  size: 36,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Two-factor verification',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  challenge.email,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white60),
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
                        : '6-digit authenticator code',
                    border: const OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: Colors.white),
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
                            ? 'Use authenticator'
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

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('mfa_error_banner'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0x33B00020),
        border: Border.all(color: const Color(0xFFB00020)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(message, style: const TextStyle(color: Colors.white)),
    );
  }
}
