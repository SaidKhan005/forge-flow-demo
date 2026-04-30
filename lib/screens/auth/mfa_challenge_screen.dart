// Phase 9.4 - MFA TOTP challenge screen.
//
// Replaces the 9.3 [MfaChallengePlaceholder]. Renders a focused
// authenticator-app code entry with a restaurant-admin help path.
// On submit, drives the existing
// [AuthSessionNotifier.completeTotpChallenge] (which 9.3 already
// wired) — the difference vs. the placeholder is real form input,
// per-attempt rate-limit guarding (1 / minute, 5 / 24h per the
// decision lock).
//
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  bool _submitting = false;
  bool _requestingAdminHelp = false;
  String? _localError;
  String? _adminHelpMessage;

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
    setState(() {
      _localError = null;
      _submitting = true;
    });
    try {
      final factorId = challenge.factorIds.isNotEmpty
          ? challenge.factorIds.first
          : 'totp';
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
    if (_requestingAdminHelp) return;
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
      _requestingAdminHelp = true;
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
    } finally {
      if (mounted) {
        setState(() => _requestingAdminHelp = false);
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
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_adminHelpMessage != null) ...[
                      _AdminHelpBanner(message: _adminHelpMessage!),
                      const SizedBox(height: 14),
                    ],
                    Center(
                      child: Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.sunset.withValues(alpha: 0.18),
                              blurRadius: 14,
                              spreadRadius: 1,
                              offset: const Offset(0, 4),
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
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Two-factor verification',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.mono15(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      challenge.email,
                      textAlign: TextAlign.center,
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 16),
                    if (errorMessage != null) ...[
                      _ErrorBanner(message: errorMessage),
                      const SizedBox(height: 12),
                    ],
                    _ChallengeSection(
                      title: 'Authenticator app',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _BrandedMfaField(
                            controller: _codeController,
                            enabled: !_submitting,
                            onSubmitted: () => _submit(challenge),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Open your authenticator app and enter the 6-digit code.',
                            style: AppTextStyles.body11(
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _VerifyButton(
                            submitting: _submitting,
                            onPressed: _submitting
                                ? null
                                : () => _submit(challenge),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _ChallengeTrailingActions(
                      submitting: _submitting,
                      requestingAdminHelp: _requestingAdminHelp,
                      onRequestAdminHelp: () => _requestAdminHelp(challenge),
                      onCancel: notifier.signOutThisSession,
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

class _BrandedMfaField extends StatefulWidget {
  const _BrandedMfaField({
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSubmitted;

  @override
  State<_BrandedMfaField> createState() => _BrandedMfaFieldState();
}

class _BrandedMfaFieldState extends State<_BrandedMfaField> {
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    _focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _BrandedMfaField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleControllerChanged);
      widget.controller.addListener(_handleControllerChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _focusNode.removeListener(_handleFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  void _handleFocusChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return _buildSegmentedTotp();
  }

  Widget _buildSegmentedTotp() {
    final text = widget.controller.text;
    final activeIndex = text.length.clamp(0, 5);
    final isFocused = _focusNode.hasFocus;
    return SizedBox(
      height: 56,
      child: Stack(
        children: [
          Positioned.fill(
            child: TextField(
              key: const Key('mfa_code_field'),
              controller: widget.controller,
              focusNode: _focusNode,
              enabled: widget.enabled,
              autofocus: true,
              showCursor: false,
              keyboardType: TextInputType.number,
              autofillHints: const <String>[AutofillHints.oneTimeCode],
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              maxLength: 6,
              onSubmitted: (_) => widget.onSubmitted(),
              style: const TextStyle(
                color: Colors.transparent,
                fontSize: 22,
                height: 1,
              ),
              cursorColor: Colors.transparent,
              decoration: const InputDecoration(
                counterText: '',
                isCollapsed: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          IgnorePointer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List<Widget>.generate(6, (i) {
                final digit = i < text.length ? text[i] : '';
                final isActive =
                    isFocused && i == activeIndex && widget.enabled;
                final hasValue = digit.isNotEmpty;
                final borderColor = isActive
                    ? AppColors.sunset
                    : (hasValue
                          ? AppColors.sunset.withValues(alpha: 0.5)
                          : AppColors.borderSubtle);
                return Opacity(
                  opacity: widget.enabled ? 1.0 : 0.7,
                  child: Container(
                    width: 40,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSurface,
                      border: Border.all(
                        color: borderColor,
                        width: isActive ? 1.6 : 1,
                      ),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: isActive
                          ? [
                              BoxShadow(
                                color: AppColors.sunset.withValues(alpha: 0.18),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: Text(
                      digit,
                      style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700,
                      ).copyWith(fontSize: 22, height: 1),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _VerifyButton extends StatelessWidget {
  const _VerifyButton({required this.submitting, required this.onPressed});

  final bool submitting;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: FilledButton(
        key: const Key('mfa_submit_button'),
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.sunset,
          foregroundColor: AppColors.backgroundSurface,
          disabledBackgroundColor: AppColors.sunset.withValues(alpha: 0.55),
          disabledForegroundColor: AppColors.backgroundSurface.withValues(
            alpha: 0.85,
          ),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: AppTextStyles.mono15(
            color: AppColors.backgroundSurface,
            weight: FontWeight.w700,
          ),
        ),
        child: submitting
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: AppColors.backgroundSurface,
                ),
              )
            : const Text('Verify'),
      ),
    );
  }
}

class _ChallengeSection extends StatelessWidget {
  const _ChallengeSection({required this.title, required this.child});

  final String title;
  final Widget child;

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
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
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
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class _ChallengeTrailingActions extends StatelessWidget {
  const _ChallengeTrailingActions({
    required this.submitting,
    required this.requestingAdminHelp,
    required this.onRequestAdminHelp,
    required this.onCancel,
  });

  final bool submitting;
  final bool requestingAdminHelp;
  final VoidCallback onRequestAdminHelp;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final fallbackStyle = OutlinedButton.styleFrom(
      foregroundColor: AppColors.textSecondary,
      side: BorderSide(
        color: AppColors.borderSubtle.withValues(alpha: 0.9),
        width: 1,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      textStyle: AppTextStyles.mono12(
        color: AppColors.textSecondary,
        weight: FontWeight.w600,
      ),
    );
    return Column(
      key: const Key('mfa_trailing_actions'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          "Can't access your authenticator app?",
          textAlign: TextAlign.center,
          style: AppTextStyles.mono10(color: AppColors.textMuted),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: OutlinedButton.icon(
            key: const Key('mfa_contact_admin_button'),
            onPressed: submitting || requestingAdminHelp
                ? null
                : onRequestAdminHelp,
            style: fallbackStyle,
            icon: requestingAdminHelp
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(
                    Icons.support_agent_rounded,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
            label: Text(
              requestingAdminHelp ? 'Sending…' : 'Contact your admin',
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: OutlinedButton.icon(
            key: const Key('mfa_cancel_button'),
            onPressed: submitting ? null : onCancel,
            style: fallbackStyle,
            icon: const Icon(
              Icons.logout_rounded,
              size: 16,
              color: AppColors.textSecondary,
            ),
            label: const Text('Sign out'),
          ),
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
      key: const Key('mfa_error_banner'),
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

class _AdminHelpBanner extends StatelessWidget {
  const _AdminHelpBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('mfa_admin_help_message'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: AppColors.textPrimary.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: AppColors.sunsetDark),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body11(color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
