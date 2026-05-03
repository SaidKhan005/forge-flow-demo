// Phase 11W.0 — Magic-link welcome / landing screen.
//
// First screen in the operator-web onboarding click path. Renders the
// brand mark + a single "Continue" affordance that consumes the
// `?token=` query param the invite email lands the operator on.
// Mirrors the welcome copy from
// `docs/phases/phase_11W/operator_onboarding_flow.md` (Phase 2 step 4)
// and the UX-writing standard from
// `~/.claude/projects/.../memory/project_ux_writing_standard.md`:
//
//   * 1-line "what this is" header above the action.
//   * 1-2 sentence "what happens when you click" explainer below.
//   * Plain English error remediation.
//
// The screen is intentionally stateless on the routing axis — the
// router passes the parsed token in via [initialToken]; tapping
// Continue calls [onSubmitToken] which routes through the
// `OperatorWebAuthSource` (welcome → password). When the token is
// missing or malformed, the screen surfaces a token text field as a
// fallback so a copy-paste recovery still works.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'shared/onboarding_layout.dart';

/// Magic-link landing surface. The router instantiates one of these
/// when it lands on `/onboarding/welcome`.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({
    super.key,
    required this.onSubmitToken,
    this.initialToken,
    this.errorMessage,
    this.submitting = false,
  });

  /// Called when the operator presses Continue. Passes the (possibly
  /// edited) token through; the auth source verifies it against the
  /// proxy.
  final Future<void> Function(String token) onSubmitToken;

  /// Token parsed from the `?token=` query param. When non-null the
  /// screen pre-fills the field and arms the auto-submit affordance.
  final String? initialToken;

  /// Error message to render in the feedback strip. Sourced from the
  /// auth source's `lastErrorMessage` so token-mismatch copy lands
  /// here.
  final String? errorMessage;

  /// True while the auth source is verifying. Disables the submit
  /// affordance.
  final bool submitting;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  late TextEditingController _tokenController;

  @override
  void initState() {
    super.initState();
    _tokenController = TextEditingController(text: widget.initialToken ?? '');
  }

  @override
  void didUpdateWidget(covariant WelcomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialToken != widget.initialToken &&
        (widget.initialToken ?? '').isNotEmpty &&
        _tokenController.text.isEmpty) {
      _tokenController.text = widget.initialToken!;
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.submitting) return;
    final token = _tokenController.text.trim();
    await widget.onSubmitToken(token);
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingLayout(
      stepLabel: 'Step 1 of 4 — Welcome',
      title: 'Welcome to Forge & Flow',
      subtitle:
          'We sent you an invite email so you can finish setting up your '
          'account. The email contains a single-use code that signs you '
          'in for the first time.',
      errorMessage: widget.errorMessage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _ExplainerSection(
            heading: 'What happens next',
            body:
                'Continue from here to set a password, turn on two-factor '
                'sign-in, and accept the data-access terms. The whole flow '
                'takes about three minutes. You only do it once.',
          ),
          const SizedBox(height: 18),
          _TokenField(
            key: const Key('operator_web_welcome_token_field'),
            controller: _tokenController,
            enabled: !widget.submitting,
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          Text(
            'Tip: most operators arrive here from the invite email link, '
            'so this code is already filled in. If you copy/pasted the '
            'link manually, double-check that the whole code came across.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
          const SizedBox(height: 22),
          _ContinueButton(
            label: 'Continue to password setup',
            submitting: widget.submitting,
            onPressed: widget.submitting ? null : _submit,
          ),
          const SizedBox(height: 14),
          _SupportFooter(
            body:
                "Didn't get the email or the code says it expired? Forge & "
                'Flow support can resend the invite — reach out to your '
                'F&F point of contact and they will issue a new link.',
          ),
        ],
      ),
    );
  }
}

class _ExplainerSection extends StatelessWidget {
  const _ExplainerSection({required this.heading, required this.body});

  final String heading;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_welcome_explainer'),
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
            heading,
            style: AppTextStyles.mono11(color: AppColors.sunsetDark),
          ),
          const SizedBox(height: 6),
          Text(body, style: AppTextStyles.body13(color: AppColors.textPrimary)),
        ],
      ),
    );
  }
}

class _TokenField extends StatelessWidget {
  const _TokenField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onSubmitted;

  @override
  Widget build(BuildContext context) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(6),
      borderSide: const BorderSide(color: AppColors.borderSubtle, width: 1),
    );
    return TextField(
      controller: controller,
      enabled: enabled,
      onSubmitted: onSubmitted,
      cursorColor: AppColors.sunset,
      style: AppTextStyles.body15(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: 'Invite code',
        helperText:
            'The code from your invite email, usually 30+ characters long.',
        helperMaxLines: 2,
        labelStyle: AppTextStyles.mono11(color: AppColors.textMuted),
        floatingLabelStyle: AppTextStyles.mono11(color: AppColors.sunsetDark),
        helperStyle: AppTextStyles.body12(color: AppColors.textMuted),
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

class _ContinueButton extends StatelessWidget {
  const _ContinueButton({
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
        key: const Key('operator_web_welcome_submit'),
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

class _SupportFooter extends StatelessWidget {
  const _SupportFooter({required this.body});

  final String body;

  @override
  Widget build(BuildContext context) {
    return Text(
      body,
      key: const Key('operator_web_welcome_support_footer'),
      style: AppTextStyles.body12(color: AppColors.textMuted),
    );
  }
}
