// Phase 9.3 - Branded login screen.
//
// Email + password form with one "Sign in" action. On success the
// notifier transitions to authenticated and the AuthGate swaps to
// the app shell. On MFA required the gate swaps to the TOTP
// challenge placeholder. On failure the error message renders in a
// banner above the form.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_session_notifier.dart';
import '../../theme/app_theme.dart';

const bool _demoOperatorSignInEnabled =
    bool.fromEnvironment('kDemoMode') ||
    bool.fromEnvironment('FORGE_FLOW_DEMO_MODE');
const String _defaultDemoOperatorEmail = 'demo.operator@forgeflow.test';
const String _defaultDemoOperatorPassword = 'forge-flow-demo';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    this.showDemoOperatorSignIn = _demoOperatorSignInEnabled,
    this.demoOperatorEmail = _defaultDemoOperatorEmail,
    this.demoOperatorPassword = _defaultDemoOperatorPassword,
  });

  final bool showDemoOperatorSignIn;
  final String demoOperatorEmail;
  final String demoOperatorPassword;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  bool _requestingReset = false;
  String? _localMessage;
  bool _localMessageIsError = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) return;

    setState(() {
      _submitting = true;
      _localMessage = null;
    });
    try {
      await context.read<AuthSessionNotifier>().signInWithEmailPassword(
        email: email,
        password: password,
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitDemoOperator() async {
    if (_submitting) return;
    _emailController.text = widget.demoOperatorEmail;
    _passwordController.text = widget.demoOperatorPassword;
    await _submit();
  }

  Future<void> _requestPasswordReset() async {
    if (_submitting || _requestingReset) return;
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() {
        _localMessage = 'Enter your email to reset your password.';
        _localMessageIsError = true;
      });
      return;
    }

    setState(() {
      _requestingReset = true;
      _localMessage = null;
    });
    try {
      await context.read<AuthSessionNotifier>().requestPasswordReset(
        email: email,
      );
      if (!mounted) return;
      setState(() {
        _localMessage =
            'If that email is registered, a password reset link is on the way.';
        _localMessageIsError = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _localMessage =
            'Password reset could not be started. Please try again.';
        _localMessageIsError = true;
      });
    } finally {
      if (mounted) setState(() => _requestingReset = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AuthSessionNotifier>();
    final state = notifier.state;
    final errorMessage = state is AuthSessionUnauthenticated
        ? _safeLoginError(state)
        : null;

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
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _BrandMark(),
                    const SizedBox(height: 32),
                    _LoginCard(
                      errorMessage: errorMessage,
                      localMessage: _localMessage,
                      localMessageIsError: _localMessageIsError,
                      emailController: _emailController,
                      passwordController: _passwordController,
                      submitting: _submitting,
                      requestingReset: _requestingReset,
                      showDemoOperatorSignIn: widget.showDemoOperatorSignIn,
                      onSubmit: _submit,
                      onDemoOperatorSignIn: _submitDemoOperator,
                      onRequestPasswordReset: _requestPasswordReset,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String? _safeLoginError(AuthSessionUnauthenticated state) {
    final code = state.lastErrorCode;
    return switch (code) {
      null =>
        state.lastErrorMessage == null
            ? null
            : 'Sign-in could not be completed. Please try again.',
      'invalid_credentials' => 'Email or password is incorrect.',
      'account_suspended' =>
        'This account cannot sign in right now. Contact your administrator.',
      'email_not_verified' => 'Verify your email before signing in.',
      'network_error' => 'Sign-in is temporarily unavailable. Try again.',
      'too_many_attempts' =>
        'Too many attempts. Please wait a moment and try again.',
      'ledger_unavailable' =>
        'Sign-in could not be recorded. Please try again in a moment.',
      _ => 'Sign-in could not be completed. Please try again.',
    };
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Column(
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
      ],
    );
  }
}

class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.errorMessage,
    required this.localMessage,
    required this.localMessageIsError,
    required this.emailController,
    required this.passwordController,
    required this.submitting,
    required this.requestingReset,
    required this.showDemoOperatorSignIn,
    required this.onSubmit,
    required this.onDemoOperatorSignIn,
    required this.onRequestPasswordReset,
  });

  final String? errorMessage;
  final String? localMessage;
  final bool localMessageIsError;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool submitting;
  final bool requestingReset;
  final bool showDemoOperatorSignIn;
  final Future<void> Function() onSubmit;
  final Future<void> Function() onDemoOperatorSignIn;
  final Future<void> Function() onRequestPasswordReset;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.backgroundSurface, AppColors.cardGlow],
          ),
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          boxShadow: [
            BoxShadow(
              color: AppColors.textPrimary.withValues(alpha: 0.04),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Sign in',
                style: AppTextStyles.mono15(
                  color: AppColors.textPrimary,
                  weight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                height: 2,
                width: 28,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [AppColors.sunset, AppColors.sunsetDark],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              if (errorMessage != null) ...[
                _ErrorBanner(message: errorMessage!),
                const SizedBox(height: 14),
              ],
              if (localMessage != null) ...[
                _LoginMessageBanner(
                  message: localMessage!,
                  isError: localMessageIsError,
                ),
                const SizedBox(height: 14),
              ],
              _BrandedField(
                fieldKey: const Key('login_email_field'),
                controller: emailController,
                label: 'Email',
                obscureText: false,
                enabled: !submitting,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const <String>[AutofillHints.username],
              ),
              const SizedBox(height: 14),
              _BrandedField(
                fieldKey: const Key('login_password_field'),
                controller: passwordController,
                label: 'Password',
                obscureText: true,
                enabled: !submitting,
                autofillHints: const <String>[AutofillHints.password],
                onSubmitted: (_) => onSubmit(),
              ),
              const SizedBox(height: 20),
              _SignInButton(
                submitting: submitting,
                onPressed: submitting ? null : onSubmit,
              ),
              if (showDemoOperatorSignIn) ...[
                const SizedBox(height: 10),
                _DemoOperatorButton(
                  onPressed: submitting ? null : onDemoOperatorSignIn,
                ),
              ],
              const SizedBox(height: 8),
              TextButton(
                key: const Key('login_forgot_password_button'),
                onPressed: submitting || requestingReset
                    ? null
                    : onRequestPasswordReset,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.sunsetDark,
                  textStyle: AppTextStyles.mono12(
                    color: AppColors.sunsetDark,
                    weight: FontWeight.w600,
                  ),
                ),
                child: requestingReset
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Forgot password?'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DemoOperatorButton extends StatelessWidget {
  const _DemoOperatorButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: OutlinedButton.icon(
        key: const Key('login_demo_operator_button'),
        onPressed: onPressed,
        icon: const Icon(Icons.person_pin_circle_outlined, size: 18),
        label: const Text('Use demo operator'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.sunsetDark,
          side: const BorderSide(color: AppColors.borderSubtle),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: AppTextStyles.mono12(
            color: AppColors.sunsetDark,
            weight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _BrandedField extends StatelessWidget {
  const _BrandedField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.obscureText,
    required this.enabled,
    this.keyboardType,
    this.autofillHints,
    this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool obscureText;
  final bool enabled;
  final TextInputType? keyboardType;
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
      keyboardType: keyboardType,
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

class _SignInButton extends StatelessWidget {
  const _SignInButton({required this.submitting, required this.onPressed});

  final bool submitting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        key: const Key('login_submit_button'),
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
            : const Text('Sign in'),
      ),
    );
  }
}

class _LoginMessageBanner extends StatelessWidget {
  const _LoginMessageBanner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? AppColors.negative : AppColors.positive;
    return Container(
      key: const Key('login_local_message_banner'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: AppTextStyles.body13(color: color)),
          ),
        ],
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
      key: const Key('login_error_banner'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: AppColors.negative),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.negative),
            ),
          ),
        ],
      ),
    );
  }
}
