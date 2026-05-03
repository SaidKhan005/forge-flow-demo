// Phase 11W.0 — Password setup screen.
//
// Step 2 of the onboarding click path. Operator chose a password +
// confirmation; the auth source validates against the Phase 9
// password policy server-side (HIBP screen, length, history). The
// client mirrors the minimum length so a too-short password is caught
// before round-tripping to the proxy.
//
// UX writing standard:
//
//   * 1-line "what this is" header above each action.
//   * Plain English explainer of what makes a password strong.
//   * Plain English error remediation copy (no codes / hashes).

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'shared/onboarding_layout.dart';

/// Password setup surface. The router renders this when the auth
/// source is in [OperatorWebSettingPassword].
class PasswordSetupScreen extends StatefulWidget {
  const PasswordSetupScreen({
    super.key,
    required this.onSubmitPassword,
    this.errorMessage,
    this.submitting = false,
  });

  /// Called when the operator submits both fields. The auth source
  /// validates server-side and either advances to MFA or surfaces a
  /// remediation message via [errorMessage].
  final Future<void> Function({
    required String password,
    required String confirmation,
  })
  onSubmitPassword;

  final String? errorMessage;
  final bool submitting;

  @override
  State<PasswordSetupScreen> createState() => _PasswordSetupScreenState();
}

class _PasswordSetupScreenState extends State<PasswordSetupScreen> {
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _showLocalLengthHint = false;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.submitting) return;
    final password = _passwordController.text;
    final confirmation = _confirmationController.text;
    if (password.length < 12) {
      setState(() => _showLocalLengthHint = true);
      return;
    }
    setState(() => _showLocalLengthHint = false);
    await widget.onSubmitPassword(
      password: password,
      confirmation: confirmation,
    );
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingLayout(
      stepLabel: 'Step 2 of 4 — Password',
      title: 'Set your password',
      subtitle:
          'Choose a password you can remember but no one would guess. Forge & '
          'Flow will check that the password has not appeared in known data '
          'breaches.',
      errorMessage: _showLocalLengthHint
          ? 'Use at least 12 characters. Forge & Flow rejects shorter '
                'passwords because they are too easy to guess.'
          : widget.errorMessage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _PasswordExplainer(),
          const SizedBox(height: 18),
          _OnboardingField(
            fieldKey: const Key('operator_web_password_field'),
            controller: _passwordController,
            label: 'New password',
            obscureText: true,
            enabled: !widget.submitting,
            autofillHints: const <String>[AutofillHints.newPassword],
          ),
          const SizedBox(height: 14),
          _OnboardingField(
            fieldKey: const Key('operator_web_password_confirm_field'),
            controller: _confirmationController,
            label: 'Type your password again',
            obscureText: true,
            enabled: !widget.submitting,
            autofillHints: const <String>[AutofillHints.newPassword],
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 22),
          _SubmitButton(
            label: 'Save password and continue',
            submitting: widget.submitting,
            onPressed: widget.submitting ? null : _submit,
          ),
          const SizedBox(height: 14),
          Text(
            'Forge & Flow stores only a hashed copy of your password — '
            'support staff cannot read it. If you forget it later, use '
            '"Forgot password" on the sign-in screen and we will email a '
            'reset link.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _PasswordExplainer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_password_explainer'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'What makes a strong password',
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 6),
          Text(
            'A short phrase from a song, a book, or a memory you wouldn\'t '
            'share — at least 12 characters. Avoid words that show up in '
            'your business name, address, or social media.',
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            'Why we ask: a strong password is the first line of defense '
            'against someone signing in as you. The next step adds a '
            'second factor on top of it.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _OnboardingField extends StatelessWidget {
  const _OnboardingField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.obscureText,
    required this.enabled,
    this.autofillHints,
    this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool obscureText;
  final bool enabled;
  final List<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    );
    return TextField(
      key: fieldKey,
      controller: controller,
      obscureText: obscureText,
      enabled: enabled,
      autofillHints: autofillHints,
      onSubmitted: onSubmitted,
      cursorColor: AppColors.sunset,
      style: AppTextStyles.body15(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
        floatingLabelStyle: AppTextStyles.mono11(color: AppColors.sunsetDark),
        filled: true,
        fillColor: AppColors.backgroundSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: AppColors.sunset, width: 1.6),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: BorderSide(
            color: AppColors.borderSubtle.withValues(alpha: 0.6),
            width: 1,
          ),
        ),
      ),
    );
  }
}

class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.label,
    required this.submitting,
    required this.onPressed,
  });

  final String label;
  final bool submitting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        key: const Key('operator_web_password_submit'),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.sunset,
          foregroundColor: AppColors.backgroundSurface,
          disabledBackgroundColor: AppColors.sunset.withValues(alpha: 0.55),
          disabledForegroundColor: AppColors.backgroundSurface.withValues(
            alpha: 0.85,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: AppTextStyles.mono14(
            color: AppColors.backgroundSurface,
            weight: FontWeight.w600,
          ),
        ),
        child: submitting
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.backgroundSurface,
                ),
              )
            : Text(label),
      ),
    );
  }
}
