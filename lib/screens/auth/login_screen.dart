// Phase 9.3 - Branded login screen.
//
// Email + password form with one "Sign in" action. On success the
// notifier transitions to authenticated and the AuthGate swaps to
// the app shell. On MFA required the gate swaps to the TOTP
// challenge placeholder (real TOTP UI lands in 9.4). On failure the
// error message renders in a banner above the form.
//
// Visual treatment uses the Forge & Flow brand palette (sunset +
// cream + peacock) with the splash-icon mark above the form. Rich
// branded action-link pages (invite, password reset, email verify)
// are still owned by the F&F web app, not the Flutter shell.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/auth_session_notifier.dart';
import '../../theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;

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
    if (email.isEmpty || password.isEmpty) {
      return;
    }
    setState(() => _submitting = true);
    try {
      await context.read<AuthSessionNotifier>().signInWithEmailPassword(
        email: email,
        password: password,
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
    final errorMessage = state is AuthSessionUnauthenticated
        ? state.lastErrorMessage
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
                      emailController: _emailController,
                      passwordController: _passwordController,
                      submitting: _submitting,
                      onSubmit: _submit,
                    ),
                    const SizedBox(height: 20),
                    const _VersionMark(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
    required this.emailController,
    required this.passwordController,
    required this.submitting,
    required this.onSubmit,
  });

  final String? errorMessage;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool submitting;
  final Future<void> Function() onSubmit;

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
            ],
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
          disabledBackgroundColor:
              AppColors.sunset.withValues(alpha: 0.55),
          disabledForegroundColor:
              AppColors.backgroundSurface.withValues(alpha: 0.85),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
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

class _VersionMark extends StatelessWidget {
  const _VersionMark();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.bolt_rounded, size: 12, color: AppColors.textMuted),
        const SizedBox(width: 6),
        Text(
          'Forge & Flow · v1.0.0',
          style: AppTextStyles.mono8(color: AppColors.textMuted),
        ),
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
          Icon(Icons.error_outline,
              size: 16, color: AppColors.negative),
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
