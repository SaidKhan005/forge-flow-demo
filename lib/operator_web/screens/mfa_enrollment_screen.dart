// Phase 11W.0 — MFA enrollment screen.
//
// Step 3 of the onboarding click path. Operator picks a factor type
// (TOTP authenticator app or SMS), the auth source returns the
// enrollment artifact (QR + secret for TOTP, masked number for SMS),
// the operator enters a verification code, the auth source advances
// to T&Cs.
//
// UX writing standard:
//
//   * Plain English explainer of what MFA is and why F&F requires it.
//   * Brief copy on each factor option so the operator can pick
//     without engineering knowledge.
//   * Plain English remediation copy on bad codes.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/operator_web_auth_source.dart';
import '../../theme/app_theme.dart';
import 'shared/onboarding_layout.dart';

/// MFA enrollment surface. Renders when the auth source is in
/// [OperatorWebEnrollingMfa]. Two-step:
///
///   1. Operator picks a factor type → screen calls
///      [onBeginEnrollment] which returns the [MfaEnrollmentArtifact].
///   2. Operator enters the 6-digit verification code → screen calls
///      [onConfirmEnrollment]; auth source advances to T&Cs.
class MfaEnrollmentScreen extends StatefulWidget {
  const MfaEnrollmentScreen({
    super.key,
    required this.operatorEmail,
    required this.onBeginEnrollment,
    required this.onConfirmEnrollment,
    this.errorMessage,
    this.submitting = false,
  });

  /// Operator email — drives the TOTP issuer label hint copy.
  final String operatorEmail;

  /// Called when the operator picks a factor + presses "Generate code".
  /// Returns the artifact carrying the QR / shared secret / masked
  /// number the screen renders.
  final Future<MfaEnrollmentArtifact?> Function({
    required MfaFactorType factorType,
    String? phoneNumber,
  })
  onBeginEnrollment;

  /// Called when the operator enters the verification code. The auth
  /// source advances to T&Cs on success.
  final Future<void> Function({
    required String enrollmentId,
    required String oneTimeCode,
  })
  onConfirmEnrollment;

  final String? errorMessage;
  final bool submitting;

  @override
  State<MfaEnrollmentScreen> createState() => _MfaEnrollmentScreenState();
}

class _MfaEnrollmentScreenState extends State<MfaEnrollmentScreen> {
  MfaFactorType _selectedFactor = MfaFactorType.totp;
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  MfaEnrollmentArtifact? _artifact;
  bool _busy = false;
  String? _localError;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_busy || widget.submitting) return;
    setState(() {
      _busy = true;
      _localError = null;
    });
    try {
      final artifact = await widget.onBeginEnrollment(
        factorType: _selectedFactor,
        phoneNumber: _selectedFactor == MfaFactorType.sms
            ? _phoneController.text.trim()
            : null,
      );
      if (!mounted) return;
      setState(() => _artifact = artifact);
    } catch (_) {
      // Auth source pushes its own error message via [errorMessage];
      // local error stays null so the banner doesn't double-render.
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _confirm() async {
    if (_busy || widget.submitting) return;
    final artifact = _artifact;
    if (artifact == null) {
      setState(() {
        _localError =
            'Generate the code first by picking an authenticator app or '
            'SMS factor above.';
      });
      return;
    }
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() {
        _localError =
            'Enter the 6-digit code from your authenticator app or text '
            'message.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _localError = null;
    });
    try {
      await widget.onConfirmEnrollment(
        enrollmentId: artifact.enrollmentId,
        oneTimeCode: code,
      );
    } catch (_) {
      // Pass-through to auth source remediation.
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return OnboardingLayout(
      stepLabel: 'Step 3 of 4 — Two-factor sign-in',
      title: 'Turn on two-factor sign-in',
      subtitle:
          'Two-factor sign-in (also called MFA) means a second one-time code '
          'is required at every sign-in. If someone learns your password '
          'they still cannot sign in without your phone or authenticator '
          'app. Forge & Flow requires it for all operator users.',
      errorMessage: _localError ?? widget.errorMessage,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _FactorPicker(
            selected: _selectedFactor,
            enabled: !_busy && !widget.submitting,
            onSelect: (next) => setState(() {
              _selectedFactor = next;
              _artifact = null;
              _codeController.clear();
            }),
          ),
          const SizedBox(height: 18),
          if (_selectedFactor == MfaFactorType.sms) ...[
            _OnboardingField(
              fieldKey: const Key('operator_web_mfa_phone_field'),
              controller: _phoneController,
              label: 'Mobile phone number',
              keyboardType: TextInputType.phone,
              enabled: _artifact == null && !_busy && !widget.submitting,
            ),
            const SizedBox(height: 14),
          ],
          if (_artifact == null) ...[
            _SubmitButton(
              label: _selectedFactor == MfaFactorType.totp
                  ? 'Generate authenticator code'
                  : 'Send verification text message',
              submitting: _busy,
              onPressed: (_busy || widget.submitting) ? null : _begin,
              keyName: 'operator_web_mfa_begin',
            ),
          ] else ...[
            _ArtifactPanel(artifact: _artifact!, email: widget.operatorEmail),
            const SizedBox(height: 14),
            _OnboardingField(
              fieldKey: const Key('operator_web_mfa_code_field'),
              controller: _codeController,
              label: 'Verification code',
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              enabled: !_busy && !widget.submitting,
              onSubmitted: (_) => _confirm(),
            ),
            const SizedBox(height: 14),
            _SubmitButton(
              label: 'Verify and continue',
              submitting: _busy,
              onPressed: (_busy || widget.submitting) ? null : _confirm,
              keyName: 'operator_web_mfa_confirm',
            ),
          ],
          const SizedBox(height: 14),
          Text(
            'Lost access to your factor later? Go to the operator app under '
            'Settings → Security to reset MFA, or ask your F&F point of '
            'contact to issue a recovery link.',
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _FactorPicker extends StatelessWidget {
  const _FactorPicker({
    required this.selected,
    required this.enabled,
    required this.onSelect,
  });

  final MfaFactorType selected;
  final bool enabled;
  final ValueChanged<MfaFactorType> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('operator_web_mfa_factor_picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FactorOption(
          factor: MfaFactorType.totp,
          selected: selected == MfaFactorType.totp,
          enabled: enabled,
          onSelect: () => onSelect(MfaFactorType.totp),
          title: 'Authenticator app (recommended)',
          body:
              'Use a free app such as 1Password, Google Authenticator, or '
              'Authy. We will show a QR code; you scan it once and the app '
              'starts generating codes you read at sign-in.',
        ),
        const SizedBox(height: 10),
        _FactorOption(
          factor: MfaFactorType.sms,
          selected: selected == MfaFactorType.sms,
          enabled: enabled,
          onSelect: () => onSelect(MfaFactorType.sms),
          title: 'Text message (SMS)',
          body:
              'A code is texted to your mobile phone every time you sign '
              'in. Easier to set up but less reliable than an authenticator '
              'app — text messages can be delayed.',
        ),
      ],
    );
  }
}

class _FactorOption extends StatelessWidget {
  const _FactorOption({
    required this.factor,
    required this.selected,
    required this.enabled,
    required this.onSelect,
    required this.title,
    required this.body,
  });

  final MfaFactorType factor;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelect;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? AppColors.sunset.withValues(alpha: 0.08) : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        key: Key('operator_web_mfa_option_${factor.name}'),
        onTap: enabled ? onSelect : null,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? AppColors.sunset.withValues(alpha: 0.55)
                  : AppColors.borderSubtle,
              width: 1,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 18,
                color: selected
                    ? AppColors.sunsetDark
                    : AppColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: AppTextStyles.mono14(
                        color: AppColors.textPrimary,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      body,
                      style: AppTextStyles.body13(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtifactPanel extends StatelessWidget {
  const _ArtifactPanel({required this.artifact, required this.email});

  final MfaEnrollmentArtifact artifact;
  final String email;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('operator_web_mfa_artifact_panel'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: artifact.factorType == MfaFactorType.totp
          ? _TotpArtifact(artifact: artifact, email: email)
          : _SmsArtifact(artifact: artifact),
    );
  }
}

class _TotpArtifact extends StatelessWidget {
  const _TotpArtifact({required this.artifact, required this.email});

  final MfaEnrollmentArtifact artifact;
  final String email;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Open your authenticator app',
          style: AppTextStyles.mono11(color: AppColors.sunsetDark),
        ),
        const SizedBox(height: 6),
        Text(
          'Scan the QR code or paste the shared secret. The app will start '
          'generating 6-digit codes that refresh every 30 seconds.',
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 10),
        // Render the otpauth URI as a plain text payload + the shared
        // secret so the operator can paste either into their app.
        // 11W.0 ships without a QR-image generator — the URI is enough
        // to validate the click path; a QR widget can land in 11W.0a if
        // operator feedback asks for it.
        SelectableText(
          artifact.totpQrUri ?? '',
          style: AppTextStyles.mono10(color: AppColors.textPrimary),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              'Shared secret: ',
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
            SelectableText(
              artifact.totpSharedSecret ?? '',
              style: AppTextStyles.mono12(color: AppColors.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Issuer: Forge & Flow • Account: $email',
          style: AppTextStyles.body12(color: AppColors.textMuted),
        ),
      ],
    );
  }
}

class _SmsArtifact extends StatelessWidget {
  const _SmsArtifact({required this.artifact});

  final MfaEnrollmentArtifact artifact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Check your text messages',
          style: AppTextStyles.mono11(color: AppColors.sunsetDark),
        ),
        const SizedBox(height: 6),
        Text(
          'We sent a 6-digit code to ${artifact.smsMaskedNumber ?? "your "
              "phone"}. Enter it below. Codes expire after 5 minutes — '
          'if it doesn\'t arrive, switch to the authenticator app option.',
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        ),
      ],
    );
  }
}

class _OnboardingField extends StatelessWidget {
  const _OnboardingField({
    required this.fieldKey,
    required this.controller,
    required this.label,
    required this.enabled,
    this.keyboardType,
    this.maxLength,
    this.inputFormatters,
    this.onSubmitted,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String label;
  final bool enabled;
  final TextInputType? keyboardType;
  final int? maxLength;
  final List<TextInputFormatter>? inputFormatters;
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
      maxLength: maxLength,
      inputFormatters: inputFormatters,
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
        counterText: '',
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
    required this.keyName,
  });

  final String label;
  final bool submitting;
  final VoidCallback? onPressed;
  final String keyName;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        key: Key(keyName),
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
