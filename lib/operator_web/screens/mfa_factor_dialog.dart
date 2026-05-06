// Phase 11W.6 - MFA factor enrollment dialog (post-onboarding manage
// flow).
//
// Separate from `mfa_enrollment_screen.dart` (the onboarding flow
// rendered when the auth source is in `OperatorWebEnrollingMfa`) -
// this dialog is the Security surface's *manage* flow, popped from
// the Security screen's `Add authenticator app` action.
//
// Two-step:
//
//   1. Begin: gateway returns the otpauth URL + shared secret. The
//      operator scans the QR or copies the secret into their
//      authenticator app.
//   2. Confirm: operator types the 6-digit code; gateway returns a
//      WebSecurityMfaFactor on success. The Security screen reloads
//      its factor list when the dialog returns true.
//
// Validation copy is locked verbatim by the parity contract
// `§ Security` rule - "That code didn't match. Try again with the
// next code from your authenticator." surfaces on `mfa_totp_invalid_code`.
//
// Idempotency: the screen mints one key for the begin step and a
// fresh key for the confirm step so a retry on confirm hits a fresh
// idempotency slot rather than replaying the prior failure.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/web_security_gateway.dart';
import '../../theme/app_theme.dart';

/// Locked validation copy. Public so the screen test can pin the
/// contract literals byte-for-byte.
class WebSecurityMfaCopy {
  const WebSecurityMfaCopy._();

  static const String invalidCode =
      "That code didn't match. Try again with the next code from your "
      'authenticator.';
  static const String genericBeginFailure =
      'Could not start authenticator setup. Try again in a moment.';
  static const String genericConfirmFailure =
      'Could not finish authenticator setup. Try again in a moment.';
  static const String emptyCode =
      'Type the 6-digit code your authenticator app shows you, then submit.';
}

/// Dialog the Security screen pops on `Add authenticator app`.
class MfaFactorDialog extends StatefulWidget {
  const MfaFactorDialog({
    super.key,
    required this.gateway,
    required this.operatorEmail,
    required this.idempotencyKeyFactory,
  });

  final WebSecurityGateway gateway;
  final String operatorEmail;

  /// Mints a fresh idempotency key per gateway call. Tests pass a
  /// deterministic factory; production wires a counter+timestamp
  /// scheme on the screen state.
  final String Function() idempotencyKeyFactory;

  @override
  State<MfaFactorDialog> createState() => _MfaFactorDialogState();
}

enum _Stage { initial, scanning, confirming }

class _MfaFactorDialogState extends State<MfaFactorDialog> {
  final _codeController = TextEditingController();
  _Stage _stage = _Stage.initial;
  WebSecurityTotpEnrollment? _enrollment;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final enrollment = await widget.gateway.beginTotpEnrollment(
        userEmail: widget.operatorEmail,
        idempotencyKey: widget.idempotencyKeyFactory(),
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stage = _Stage.scanning;
        _enrollment = enrollment;
      });
    } on WebSecurityError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message.isEmpty
            ? WebSecurityMfaCopy.genericBeginFailure
            : error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = WebSecurityMfaCopy.genericBeginFailure;
      });
    }
  }

  Future<void> _confirm() async {
    if (_busy) return;
    final enrollment = _enrollment;
    if (enrollment == null) return;
    final code = _codeController.text.trim();
    if (code.isEmpty) {
      setState(() => _error = WebSecurityMfaCopy.emptyCode);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _stage = _Stage.confirming;
    });
    try {
      await widget.gateway.confirmTotpEnrollment(
        factorId: enrollment.factorId,
        oneTimeCode: code,
        idempotencyKey: widget.idempotencyKeyFactory(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on WebSecurityError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stage = _Stage.scanning;
        _error = _mapErrorCopy(error);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stage = _Stage.scanning;
        _error = WebSecurityMfaCopy.genericConfirmFailure;
      });
    }
  }

  static String _mapErrorCopy(WebSecurityError error) {
    final code = error.code.toLowerCase();
    if (code.contains('totp') ||
        code.contains('invalid_code') ||
        code.contains('mfa_totp_invalid_code')) {
      return WebSecurityMfaCopy.invalidCode;
    }
    return WebSecurityMfaCopy.genericConfirmFailure;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('operator_web_security_mfa_factor_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Add authenticator app',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Use a free authenticator app such as 1Password, Google '
                'Authenticator, Microsoft Authenticator, or Authy. The app '
                'shows a 6-digit code that refreshes every 30 seconds; you '
                'will type that code at sign-in.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              if (_stage == _Stage.initial) _initialBody(),
              if (_stage != _Stage.initial && _enrollment != null)
                _scanBody(_enrollment!),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  key: const Key('operator_web_security_mfa_factor_error'),
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
              ],
              const SizedBox(height: 14),
              _actions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _initialBody() {
    return Text(
      'Click Generate code to create a new authenticator setup. We will show '
      'a QR code and a paste-friendly secret so you can scan or paste it '
      'into your app.',
      style: AppTextStyles.body13(color: AppColors.textSecondary),
    );
  }

  Widget _scanBody(WebSecurityTotpEnrollment enrollment) {
    final email = widget.operatorEmail.isEmpty
        ? 'this account'
        : widget.operatorEmail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('operator_web_security_mfa_factor_artifact'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.cardGlow,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Scan or paste',
                style: AppTextStyles.mono11(color: AppColors.sunsetDark),
              ),
              const SizedBox(height: 6),
              SelectableText(
                enrollment.otpAuthUrl,
                key: const Key('operator_web_security_mfa_factor_otpauth'),
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
                    enrollment.secretBase32,
                    key: const Key('operator_web_security_mfa_factor_secret'),
                    style: AppTextStyles.mono12(color: AppColors.textPrimary),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Issuer: Forge & Flow / Account: $email',
                style: AppTextStyles.body12(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('operator_web_security_mfa_factor_code_field'),
          controller: _codeController,
          enabled: !_busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 6,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          onSubmitted: (_) => _confirm(),
          decoration: const InputDecoration(
            labelText: '6-digit code',
            counterText: '',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _actions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          key: const Key('operator_web_security_mfa_factor_cancel'),
          onPressed:
              _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        if (_stage == _Stage.initial)
          FilledButton(
            key: const Key('operator_web_security_mfa_factor_begin'),
            onPressed: _busy ? null : _begin,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.sunset,
              foregroundColor: AppColors.backgroundSurface,
            ),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Generate code'),
          )
        else
          FilledButton(
            key: const Key('operator_web_security_mfa_factor_confirm'),
            onPressed: _busy ? null : _confirm,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.sunset,
              foregroundColor: AppColors.backgroundSurface,
            ),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Verify and add'),
          ),
      ],
    );
  }
}
