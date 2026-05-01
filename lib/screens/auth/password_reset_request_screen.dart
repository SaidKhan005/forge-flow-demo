// Phase 9.UX.7 - self-serve password reset request screen.
//
// Operator taps "Forgot password?" on the login screen. We collect
// their email, post it through the proxy reset-request route, and
// show the same privacy-preserving confirmation copy regardless of
// whether the email actually exists. This screen never reveals
// presence/absence of the account.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../services/auth/password_reset_gateway.dart';
import '../../theme/app_theme.dart';

class PasswordResetRequestScreen extends StatefulWidget {
  const PasswordResetRequestScreen({
    super.key,
    required this.gateway,
    this.initialEmail,
    this.idempotencyKeyFactory,
  });

  final PasswordResetGateway gateway;
  final String? initialEmail;

  /// Optional override for the idempotency-key generator. Tests pin
  /// it to a counter so they can assert key reuse vs rotation.
  final String Function()? idempotencyKeyFactory;

  @override
  State<PasswordResetRequestScreen> createState() =>
      _PasswordResetRequestScreenState();
}

class _PasswordResetRequestScreenState
    extends State<PasswordResetRequestScreen> {
  late final TextEditingController _emailController;
  late final String Function() _idempotencyKeyFactory;
  bool _submitting = false;
  bool _confirmationShown = false;
  String? _errorMessage;

  /// Stable idempotency key for the current logical reset attempt.
  /// Stays the same across network retries of the same email so the
  /// proxy replays its cached response instead of issuing a second
  /// reset email; rotates when the operator changes the email
  /// (different attempt entirely).
  String? _pendingIdempotencyKey;
  String _keyedEmailSnapshot = '';

  static const String _confirmationCopy =
      "If an account exists for this email, you'll receive a reset link.";

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.initialEmail ?? '');
    _idempotencyKeyFactory =
        widget.idempotencyKeyFactory ?? _defaultIdempotencyKeyFactory;
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  String _idempotencyKeyFor(String email) {
    if (_pendingIdempotencyKey == null || email != _keyedEmailSnapshot) {
      _pendingIdempotencyKey = _idempotencyKeyFactory();
      _keyedEmailSnapshot = email;
    }
    return _pendingIdempotencyKey!;
  }

  void _retireIdempotencyKey() {
    _pendingIdempotencyKey = null;
    _keyedEmailSnapshot = '';
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final email = _emailController.text.trim();
    if (!_isValidEmail(email)) {
      setState(() {
        _errorMessage = 'Enter a valid email address.';
        _confirmationShown = false;
      });
      return;
    }
    final key = _idempotencyKeyFor(email);
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      await widget.gateway.requestReset(
        PasswordResetRequestCommand(email: email, idempotencyKey: key),
      );
      if (!mounted) return;
      _retireIdempotencyKey();
      setState(() {
        _confirmationShown = true;
        _submitting = false;
      });
    } on PasswordResetRejected catch (rejection) {
      if (!mounted) return;
      // 429 rate-limit responses are conceptually "wait, then retry the
      // same request" — pinning the key would replay the cached 429
      // forever and defeat that semantic. Retire the key so the next
      // attempt is a fresh proxy call. The proxy cache also skips
      // 429s defensively; this is the client-side half of that pact.
      // For other rejections, keep the key so a tap-again retry
      // replays the cached response instead of double-sending the
      // email. The key rotates when the operator edits the email.
      if (rejection.code == 'rate_limited' || rejection.statusCode == 429) {
        _retireIdempotencyKey();
      }
      setState(() {
        _submitting = false;
        _errorMessage = _copyForRejection(rejection);
        _confirmationShown = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage =
            'Password reset timed out before the proxy responded. Try again.';
        _confirmationShown = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage =
            'Password reset is temporarily unavailable. Please try again.';
        _confirmationShown = false;
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

  bool _isValidEmail(String value) {
    if (value.isEmpty) return false;
    // Minimal RFC-shape check: exactly one `@`, non-empty local and
    // domain parts, and a `.` somewhere in the domain. The proxy is
    // the source of truth for stricter validation; this gate just
    // blocks obvious typos before sending the request.
    final atIndex = value.indexOf('@');
    if (atIndex <= 0 || atIndex != value.lastIndexOf('@')) return false;
    final domain = value.substring(atIndex + 1);
    if (domain.isEmpty || !domain.contains('.')) return false;
    final tld = domain.substring(domain.lastIndexOf('.') + 1);
    if (tld.isEmpty) return false;
    return true;
  }

  String _copyForRejection(PasswordResetRejected rejection) {
    if (rejection.code == 'rate_limited' || rejection.statusCode == 429) {
      return 'Too many reset requests. Please wait a moment and try again.';
    }
    if (rejection.statusCode == 404 || rejection.code == 'not found') {
      return 'Password reset route is not deployed. Rebuild with the staging proxy.';
    }
    if (rejection.code == 'password_reset_request_not_configured' ||
        rejection.code == 'password_reset_not_configured') {
      return 'Password reset is not configured in this build.';
    }
    return 'Password reset is temporarily unavailable. Please try again.';
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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const _PasswordResetLogo(
                      key: Key('password_reset_request_logo'),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      'Reset your password',
                      style: AppTextStyles.display28(
                        color: AppColors.textPrimary,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      "Enter the email associated with your account and "
                      "we'll send a reset link.",
                      style: AppTextStyles.body13(color: AppColors.textMuted),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    _RequestCard(
                      emailController: _emailController,
                      submitting: _submitting,
                      errorMessage: _errorMessage,
                      confirmationShown: _confirmationShown,
                      confirmationCopy: _confirmationCopy,
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

class _PasswordResetLogo extends StatelessWidget {
  const _PasswordResetLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 82,
        height: 82,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: AppColors.sunset.withValues(alpha: 0.18),
              blurRadius: 22,
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
    );
  }
}

class _RequestCard extends StatelessWidget {
  const _RequestCard({
    required this.emailController,
    required this.submitting,
    required this.errorMessage,
    required this.confirmationShown,
    required this.confirmationCopy,
    required this.onSubmit,
  });

  final TextEditingController emailController;
  final bool submitting;
  final String? errorMessage;
  final bool confirmationShown;
  final String confirmationCopy;
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
                _ResetBanner(
                  key: const Key('password_reset_request_error_banner'),
                  message: errorMessage!,
                  isError: true,
                ),
                const SizedBox(height: 14),
              ],
              if (confirmationShown) ...[
                _ResetBanner(
                  key: const Key('password_reset_request_confirmation_banner'),
                  message: confirmationCopy,
                  isError: false,
                ),
                const SizedBox(height: 14),
              ],
              _BrandedField(
                fieldKey: const Key('password_reset_request_email_field'),
                controller: emailController,
                label: 'Email',
                enabled: !submitting,
                keyboardType: TextInputType.emailAddress,
                onSubmitted: (_) => onSubmit(),
              ),
              const SizedBox(height: 20),
              SizedBox(
                height: 48,
                child: FilledButton(
                  key: const Key('password_reset_request_submit_button'),
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
                      : const Text('Send reset link'),
                ),
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
    required this.enabled,
    this.keyboardType,
    this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final TextInputType? keyboardType;
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
      keyboardType: keyboardType,
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

class _ResetBanner extends StatelessWidget {
  const _ResetBanner({super.key, required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final color = isError ? AppColors.negative : AppColors.positive;
    return Container(
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
