// Phase 9.UX.7 - self-serve password reset confirm screen.
//
// Triggered by the Firebase action page deep-link. Carries the
// `oobCode` issued by Firebase plus the operator's chosen new
// password to the proxy reset-confirm route. On success, redirects
// to the login screen with a snackbar; never auto-signs the user in.
// On policy / HIBP / history rejection, surfaces operator-friendly
// copy without redirecting.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../auth/password_policy.dart';
import '../../services/auth/password_reset_gateway.dart';
import '../../theme/app_theme.dart';

class PasswordResetConfirmScreen extends StatefulWidget {
  const PasswordResetConfirmScreen({
    super.key,
    required this.gateway,
    required this.oobCode,
    this.minPasswordLength = PasswordPolicy.minLength,
    this.onResetCompleted,
    this.idempotencyKeyFactory,
  });

  final PasswordResetGateway gateway;
  final String oobCode;
  final int minPasswordLength;

  /// Optional override for the idempotency-key generator. Tests pin
  /// it to a counter so they can assert key reuse vs rotation.
  final String Function()? idempotencyKeyFactory;

  /// Called after a successful confirm. Defaults to popping back to
  /// the login route with a success snackbar shown via the active
  /// [ScaffoldMessenger]. Tests inject this to capture the call
  /// without depending on Navigator state.
  final void Function(BuildContext context)? onResetCompleted;

  @override
  State<PasswordResetConfirmScreen> createState() =>
      _PasswordResetConfirmScreenState();
}

class _PasswordResetConfirmScreenState
    extends State<PasswordResetConfirmScreen> {
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  late final String Function() _idempotencyKeyFactory;
  bool _submitting = false;
  String? _errorMessage;
  String? _localValidationMessage;

  /// Stable idempotency key for the current confirm attempt. Stays
  /// the same across network retries of the same (oobCode, password)
  /// pair so a retry replays the proxy's cached 200 instead of
  /// burning the single-use oobCode and surfacing
  /// `password_reset_expired`. Rotates when the operator picks a
  /// new password (e.g., after a HIBP rejection).
  String? _pendingIdempotencyKey;
  String _keyedPasswordSnapshot = '';

  @override
  void initState() {
    super.initState();
    _idempotencyKeyFactory =
        widget.idempotencyKeyFactory ?? _defaultIdempotencyKeyFactory;
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String _idempotencyKeyFor(String password) {
    if (_pendingIdempotencyKey == null ||
        password != _keyedPasswordSnapshot) {
      _pendingIdempotencyKey = _idempotencyKeyFactory();
      _keyedPasswordSnapshot = password;
    }
    return _pendingIdempotencyKey!;
  }

  void _retireIdempotencyKey() {
    _pendingIdempotencyKey = null;
    _keyedPasswordSnapshot = '';
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;
    if (password.length < widget.minPasswordLength) {
      setState(() {
        _localValidationMessage =
            'Password must be at least ${widget.minPasswordLength} characters.';
        _errorMessage = null;
      });
      return;
    }
    if (password != confirm) {
      setState(() {
        _localValidationMessage = 'Passwords do not match.';
        _errorMessage = null;
      });
      return;
    }
    final key = _idempotencyKeyFor(password);
    setState(() {
      _submitting = true;
      _localValidationMessage = null;
      _errorMessage = null;
    });
    try {
      await widget.gateway.confirmReset(
        PasswordResetConfirmRequest(
          oobCode: widget.oobCode,
          newPassword: password,
          idempotencyKey: key,
        ),
      );
      if (!mounted) return;
      _retireIdempotencyKey();
      // Reset the submitting flag so a follow-up test (or a real-world
      // flow where the redirect callback is no-op) can re-enable the
      // form. In production the redirect dismounts the screen
      // immediately so this transient state is invisible.
      setState(() => _submitting = false);
      _handleResetCompleted();
    } on PasswordResetRejected catch (rejection) {
      if (!mounted) return;
      // Terminal 4xx (policy / HIBP / history / expired oobCode):
      // the operator must pick a new password, so the next submit
      // should be a fresh attempt with a new key.
      // Transient 5xx / network: keep the key so a retry replays
      // the cached response instead of burning the oobCode.
      if (rejection.statusCode >= 400 && rejection.statusCode < 500) {
        _retireIdempotencyKey();
      }
      setState(() {
        _submitting = false;
        _errorMessage = _operatorCopyFor(rejection);
      });
    } catch (_) {
      if (!mounted) return;
      // Network/transport: keep the key for a stable retry.
      setState(() {
        _submitting = false;
        _errorMessage =
            'Password reset could not be completed. Please try again.';
      });
    }
  }

  static String _defaultIdempotencyKeyFactory() {
    final random = math.Random.secure();
    final bytes = Uint8List(16);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void _handleResetCompleted() {
    final callback = widget.onResetCompleted;
    if (callback != null) {
      callback(context);
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    messenger?.showSnackBar(
      const SnackBar(
        key: Key('password_reset_success_snackbar'),
        content: Text('Password updated. Please sign in.'),
      ),
    );
    if (navigator.canPop()) {
      navigator.popUntil((route) => route.isFirst);
    }
  }

  String _operatorCopyFor(PasswordResetRejected rejection) {
    final rejections = rejection.rejections;
    if (rejections.contains('pwned_in_breach')) {
      return 'That password appears in a known data breach. '
          'Choose a password that has not appeared in a public breach.';
    }
    if (rejections.contains('reused_from_history')) {
      return 'You have used this password recently. '
          'Choose a password you have not used in your last 5 changes.';
    }
    if (rejections.contains('violates_policy')) {
      return 'Choose a password that meets the password policy.';
    }
    if (rejection.code == 'password_reset_expired' ||
        rejection.code == 'password_reset_user_not_found' ||
        rejection.code == 'password_reset_scope_mismatch') {
      return 'This reset link is no longer valid. '
          'Request a fresh link from the sign-in screen.';
    }
    if (rejection.code == 'hibp_unavailable' ||
        rejection.code == 'password_history_unavailable') {
      return 'Password screening is unavailable. Please try again in a moment.';
    }
    return rejection.message;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppColors.textPrimary),
      ),
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
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 32,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Choose a new password',
                      style: AppTextStyles.display28(
                        color: AppColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Use at least ${widget.minPasswordLength} characters. '
                      'Avoid passwords from past breaches or reuse.',
                      style: AppTextStyles.body13(color: AppColors.textMuted),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    _ConfirmCard(
                      passwordController: _passwordController,
                      confirmController: _confirmPasswordController,
                      submitting: _submitting,
                      errorMessage: _errorMessage,
                      localValidationMessage: _localValidationMessage,
                      onSubmit: _submit,
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
}

class _ConfirmCard extends StatelessWidget {
  const _ConfirmCard({
    required this.passwordController,
    required this.confirmController,
    required this.submitting,
    required this.errorMessage,
    required this.localValidationMessage,
    required this.onSubmit,
  });

  final TextEditingController passwordController;
  final TextEditingController confirmController;
  final bool submitting;
  final String? errorMessage;
  final String? localValidationMessage;
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
              if (errorMessage != null) ...[
                _ConfirmBanner(
                  key: const Key('password_reset_confirm_error_banner'),
                  message: errorMessage!,
                ),
                const SizedBox(height: 14),
              ],
              if (localValidationMessage != null) ...[
                _ConfirmBanner(
                  key: const Key('password_reset_confirm_validation_banner'),
                  message: localValidationMessage!,
                ),
                const SizedBox(height: 14),
              ],
              _BrandedPasswordField(
                fieldKey: const Key('password_reset_confirm_password_field'),
                controller: passwordController,
                label: 'New password',
                enabled: !submitting,
              ),
              const SizedBox(height: 14),
              _BrandedPasswordField(
                fieldKey: const Key(
                  'password_reset_confirm_password_repeat_field',
                ),
                controller: confirmController,
                label: 'Confirm new password',
                enabled: !submitting,
                onSubmitted: (_) => onSubmit(),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 48,
                child: FilledButton(
                  key: const Key('password_reset_confirm_submit_button'),
                  onPressed: submitting ? null : onSubmit,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.sunset,
                    foregroundColor: AppColors.backgroundSurface,
                    disabledBackgroundColor: AppColors.sunset.withValues(
                      alpha: 0.55,
                    ),
                    disabledForegroundColor: AppColors.backgroundSurface
                        .withValues(alpha: 0.85),
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
                      : const Text('Update password'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandedPasswordField extends StatelessWidget {
  const _BrandedPasswordField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.enabled,
    this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool enabled;
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
      enabled: enabled,
      obscureText: true,
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

class _ConfirmBanner extends StatelessWidget {
  const _ConfirmBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
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
