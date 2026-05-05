// Phase 11W.live - live operator-web sign-in screens.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import 'shared/onboarding_layout.dart';

class OperatorWebSignInScreen extends StatefulWidget {
  const OperatorWebSignInScreen({
    super.key,
    required this.onSignIn,
    required this.onRequestPasswordReset,
    this.errorMessage,
    this.infoMessage,
    this.submitting = false,
  });

  final Future<void> Function({required String email, required String password})
  onSignIn;
  final Future<void> Function({required String email}) onRequestPasswordReset;
  final String? errorMessage;
  final String? infoMessage;
  final bool submitting;

  @override
  State<OperatorWebSignInScreen> createState() =>
      _OperatorWebSignInScreenState();
}

class _OperatorWebSignInScreenState extends State<OperatorWebSignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  String? _localError;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.submitting) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _localError = 'Enter your email and password.');
      return;
    }
    setState(() => _localError = null);
    await widget.onSignIn(email: email, password: password);
  }

  Future<void> _resetPassword() async {
    if (widget.submitting) return;
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(
        () => _localError = 'Enter your email, then request a reset link.',
      );
      return;
    }
    setState(() => _localError = null);
    await widget.onRequestPasswordReset(email: email);
  }

  @override
  Widget build(BuildContext context) {
    final error = _localError ?? widget.errorMessage;
    return OnboardingLayout(
      stepLabel: 'Sign in',
      title: 'Operator Web Console',
      subtitle:
          'Use the same Forge & Flow operator account you set up from your invite email.',
      errorMessage: error,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.infoMessage != null) ...[
            _InfoBanner(message: widget.infoMessage!),
            const SizedBox(height: 14),
          ],
          TextField(
            key: const Key('operator_web_signin_email_field'),
            controller: _emailController,
            enabled: !widget.submitting,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const <String>[AutofillHints.email],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Email',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('operator_web_signin_password_field'),
            controller: _passwordController,
            enabled: !widget.submitting,
            obscureText: true,
            autofillHints: const <String>[AutofillHints.password],
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 44,
            child: FilledButton(
              key: const Key('operator_web_signin_submit'),
              onPressed: widget.submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.sunset,
                foregroundColor: AppColors.backgroundSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: widget.submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Sign in'),
            ),
          ),
          const SizedBox(height: 10),
          TextButton(
            key: const Key('operator_web_signin_reset'),
            onPressed: widget.submitting ? null : _resetPassword,
            child: const Text('Send password reset email'),
          ),
        ],
      ),
    );
  }
}

class OperatorWebSignInMfaChallengeScreen extends StatefulWidget {
  const OperatorWebSignInMfaChallengeScreen({
    super.key,
    required this.email,
    required this.factorIds,
    required this.onConfirm,
    this.errorMessage,
    this.submitting = false,
  });

  final String email;
  final List<String> factorIds;
  final Future<void> Function({required String oneTimeCode, String? factorId})
  onConfirm;
  final String? errorMessage;
  final bool submitting;

  @override
  State<OperatorWebSignInMfaChallengeScreen> createState() =>
      _OperatorWebSignInMfaChallengeScreenState();
}

class _OperatorWebSignInMfaChallengeScreenState
    extends State<OperatorWebSignInMfaChallengeScreen> {
  final _codeController = TextEditingController();
  String? _localError;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.submitting) return;
    final code = _codeController.text.trim();
    if (code.length != 6) {
      setState(() => _localError = 'Enter the 6-digit code.');
      return;
    }
    setState(() => _localError = null);
    final factorId = widget.factorIds.isEmpty ? null : widget.factorIds.first;
    await widget.onConfirm(oneTimeCode: code, factorId: factorId);
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingLayout(
      stepLabel: 'Verification',
      title: 'Enter your authenticator code',
      subtitle:
          'Firebase needs one more check before opening the Operator Web Console for ${widget.email}.',
      errorMessage: _localError ?? widget.errorMessage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const Key('operator_web_signin_mfa_code_field'),
            controller: _codeController,
            autofocus: true,
            enabled: !widget.submitting,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(
              labelText: '6-digit code',
              border: OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: 44,
            child: FilledButton(
              key: const Key('operator_web_signin_mfa_submit'),
              onPressed: widget.submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.sunset,
                foregroundColor: AppColors.backgroundSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: widget.submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Verify'),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_signin_info_banner'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.peacock.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.peacock.withValues(alpha: 0.35),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.peacockDark),
      ),
    );
  }
}
