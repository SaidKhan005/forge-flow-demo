// Phase 11W.6 - Change-password dialog (post-onboarding manage flow).
//
// Separate from the onboarding `_ChangePasswordDialog` embedded in
// `account_screen.dart`; this dialog is the Security surface's
// password rotation flow and writes through `WebSecurityGateway`.
// Validation copy is locked verbatim by the parity contract
// `§ Security` rule:
//
//   * Wrong current password   -> "Current password is incorrect."
//   * Password too weak        -> "Password must be at least 12
//                                  characters with one number and one
//                                  symbol."
//   * Reused password          -> "You can't reuse a recent password.
//                                  Choose a new one."
//
// Idempotency: the screen mints one key per submit, threaded into
// the gateway. Retrying after a 422 surfaces a fresh key so the proxy
// `proxy_requests` UNIQUE-key replay does not bind a new attempt to
// a prior failure.

import 'package:flutter/material.dart';

import '../services/web_security_gateway.dart';
import '../../theme/app_theme.dart';

/// Locked validation copy strings. Public so the screen test can
/// assert the dialog renders the contract literals byte-for-byte.
class WebSecurityPasswordCopy {
  const WebSecurityPasswordCopy._();

  static const String wrongCurrent = 'Current password is incorrect.';
  static const String tooWeak =
      'Password must be at least 12 characters with one number and one '
      'symbol.';
  static const String reused =
      "You can't reuse a recent password. Choose a new one.";
  static const String genericFailure =
      'Could not update the password. Try again in a moment.';
  static const String mismatchedConfirm =
      'New password and confirmation must match. Re-type both fields and '
      'try again.';
}

/// Dialog the Security screen pops on `Change password`.
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({
    super.key,
    required this.gateway,
    required this.idempotencyKeyFactory,
  });

  final WebSecurityGateway gateway;

  /// Mints a fresh idempotency key per submit. The screen's seq
  /// counter increments only after the dialog calls this; tests pass
  /// a deterministic factory.
  final String Function() idempotencyKeyFactory;

  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_currentController.text.isEmpty) {
      setState(() => _error = WebSecurityPasswordCopy.wrongCurrent);
      return;
    }
    if (!_localPolicyOk(_newController.text)) {
      setState(() => _error = WebSecurityPasswordCopy.tooWeak);
      return;
    }
    if (_newController.text != _confirmController.text) {
      setState(() => _error = WebSecurityPasswordCopy.mismatchedConfirm);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.gateway.changePassword(
        currentPassword: _currentController.text,
        newPassword: _newController.text,
        idempotencyKey: widget.idempotencyKeyFactory(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on WebSecurityError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _mapErrorCopy(error);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = WebSecurityPasswordCopy.genericFailure;
      });
    }
  }

  static bool _localPolicyOk(String value) {
    if (value.length < 12) return false;
    final hasDigit = RegExp(r'\d').hasMatch(value);
    final hasSymbol = RegExp(r'[^A-Za-z0-9]').hasMatch(value);
    return hasDigit && hasSymbol;
  }

  static String _mapErrorCopy(WebSecurityError error) {
    final code = error.code.toLowerCase();
    if (code.contains('wrong_current_password') ||
        code.contains('invalid_current_password')) {
      return WebSecurityPasswordCopy.wrongCurrent;
    }
    if (code.contains('reuse')) {
      return WebSecurityPasswordCopy.reused;
    }
    if (code.contains('policy') ||
        code.contains('too_short') ||
        code.contains('too_weak') ||
        code.contains('hibp_pwned') ||
        code.contains('password_policy_failed')) {
      return WebSecurityPasswordCopy.tooWeak;
    }
    if (error.rejections.any((r) => r.toLowerCase().contains('reused'))) {
      return WebSecurityPasswordCopy.reused;
    }
    if (error.rejections.any(
      (r) => r.toLowerCase().contains('too_short') || r.contains('weak'),
    )) {
      return WebSecurityPasswordCopy.tooWeak;
    }
    return WebSecurityPasswordCopy.genericFailure;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('operator_web_security_change_password_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Change password',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                'Type your current password to confirm it is you, then pick a '
                'new password. The new password must be at least 12 '
                'characters and include one number and one symbol.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key(
                  'operator_web_security_change_password_current',
                ),
                controller: _currentController,
                obscureText: true,
                autofocus: true,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Current password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('operator_web_security_change_password_new'),
                controller: _newController,
                obscureText: true,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'New password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key(
                  'operator_web_security_change_password_confirm',
                ),
                controller: _confirmController,
                obscureText: true,
                enabled: !_busy,
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(
                  labelText: 'Confirm new password',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  key: const Key(
                    'operator_web_security_change_password_error',
                  ),
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key(
                      'operator_web_security_change_password_cancel',
                    ),
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key(
                      'operator_web_security_change_password_submit',
                    ),
                    onPressed: _busy ? null : _submit,
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
                        : const Text('Update password'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
