import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';

typedef TotpChallengeSubmit = Future<void> Function(String code);

class TotpChallengeView extends StatefulWidget {
  const TotpChallengeView({
    super.key,
    required this.email,
    required this.onSubmit,
    required this.onCancel,
    this.errorMessage,
    this.helpMessage,
    this.onRequestHelp,
    this.title = 'Two-factor verification',
    this.sectionTitle = 'Authenticator app',
    this.instructions =
        'Open your authenticator app and enter the 6-digit code.',
    this.emptyCodeMessage = 'Enter a code to continue.',
    this.helpPrompt = "Can't access your authenticator app?",
    this.helpButtonLabel = 'Contact your admin',
    this.helpButtonLoadingLabel = 'Sending...',
    this.cancelButtonLabel = 'Sign out',
  });

  final String email;
  final String title;
  final String sectionTitle;
  final String instructions;
  final String emptyCodeMessage;
  final String helpPrompt;
  final String helpButtonLabel;
  final String helpButtonLoadingLabel;
  final String cancelButtonLabel;
  final String? errorMessage;
  final String? helpMessage;
  final TotpChallengeSubmit onSubmit;
  final Future<void> Function()? onRequestHelp;
  final VoidCallback onCancel;

  @override
  State<TotpChallengeView> createState() => _TotpChallengeViewState();
}

class _TotpChallengeViewState extends State<TotpChallengeView> {
  final _codeController = TextEditingController();
  bool _submitting = false;
  bool _requestingHelp = false;
  String? _localError;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _localError = widget.emptyCodeMessage);
      return;
    }
    setState(() {
      _localError = null;
      _submitting = true;
    });
    try {
      await widget.onSubmit(code);
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  Future<void> _requestHelp() async {
    final requestHelp = widget.onRequestHelp;
    if (_requestingHelp || requestHelp == null) return;
    setState(() {
      _localError = null;
      _requestingHelp = true;
    });
    try {
      await requestHelp();
    } finally {
      if (mounted) {
        setState(() => _requestingHelp = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final errorMessage = _localError ?? widget.errorMessage;
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
                    if (widget.helpMessage != null) ...[
                      _InfoBanner(message: widget.helpMessage!),
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
                      widget.title,
                      textAlign: TextAlign.center,
                      style: AppTextStyles.mono15(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.email,
                      textAlign: TextAlign.center,
                      style: AppTextStyles.mono10(color: AppColors.textMuted),
                    ),
                    const SizedBox(height: 16),
                    if (errorMessage != null) ...[
                      _ErrorBanner(message: errorMessage),
                      const SizedBox(height: 12),
                    ],
                    _ChallengeSection(
                      title: widget.sectionTitle,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _BrandedMfaField(
                            controller: _codeController,
                            enabled: !_submitting,
                            onSubmitted: _submit,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            widget.instructions,
                            style: AppTextStyles.body11(
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _VerifyButton(
                            submitting: _submitting,
                            onPressed: _submitting ? null : _submit,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    _ChallengeTrailingActions(
                      submitting: _submitting,
                      requestingHelp: _requestingHelp,
                      onRequestHelp: widget.onRequestHelp == null
                          ? null
                          : _requestHelp,
                      onCancel: widget.onCancel,
                      helpPrompt: widget.helpPrompt,
                      helpButtonLabel: widget.helpButtonLabel,
                      helpButtonLoadingLabel: widget.helpButtonLoadingLabel,
                      cancelButtonLabel: widget.cancelButtonLabel,
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
    required this.requestingHelp,
    required this.onRequestHelp,
    required this.onCancel,
    required this.helpPrompt,
    required this.helpButtonLabel,
    required this.helpButtonLoadingLabel,
    required this.cancelButtonLabel,
  });

  final bool submitting;
  final bool requestingHelp;
  final VoidCallback? onRequestHelp;
  final VoidCallback onCancel;
  final String helpPrompt;
  final String helpButtonLabel;
  final String helpButtonLoadingLabel;
  final String cancelButtonLabel;

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
        if (onRequestHelp != null) ...[
          Text(
            helpPrompt,
            textAlign: TextAlign.center,
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 44,
            child: OutlinedButton.icon(
              key: const Key('mfa_contact_admin_button'),
              onPressed: submitting || requestingHelp ? null : onRequestHelp,
              style: fallbackStyle,
              icon: requestingHelp
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
                requestingHelp ? helpButtonLoadingLabel : helpButtonLabel,
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
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
            label: Text(cancelButtonLabel),
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

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.message});

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
