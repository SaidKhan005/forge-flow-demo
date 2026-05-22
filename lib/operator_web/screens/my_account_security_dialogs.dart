part of 'my_account_screen.dart';

class _BackupCodesDialog extends StatelessWidget {
  const _BackupCodesDialog();

  // Demo backup codes — the proxy returns 10 single-use codes on
  // enrollment confirm; we surface the same shape so the walkthrough
  // copy is stable across the demo + live flows.
  static const List<String> _codes = <String>[
    '4QF8-7VPC',
    'KX2J-MN9R',
    'TR5Y-LQ8B',
    'WC3D-PE6H',
    'BG7N-SV4A',
    'ZH9F-DM1U',
    'YJ6X-CT2L',
    'NK4P-OW8E',
    'QS3R-IB7G',
    'AL5K-VU9X',
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('mfa_backup_codes_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OperatorWebDialogHeader(
                title: 'Backup codes',
                closeKey: const Key('mfa_backup_codes_dialog_x'),
                onClose: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 8),
              Text(
                'Save these somewhere safe. If you lose your phone, any one '
                'of these codes lets you sign in once.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 12),
              Container(
                key: const Key('mfa_backup_codes_dialog_list'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.cardGlow,
                  border: Border.all(color: AppColors.borderSubtle, width: 1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final code in _codes)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: SelectableText(
                          code,
                          style: AppTextStyles.mono14(
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const Key('mfa_backup_codes_dialog_close'),
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.sunset,
                    foregroundColor: AppColors.backgroundSurface,
                  ),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({this.onSubmit});

  final Future<void> Function({
    required String currentPassword,
    required String newPassword,
  })?
  onSubmit;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _currentController = TextEditingController();
  final _newController = TextEditingController();
  final _confirmController = TextEditingController();
  String? _currentError;
  String? _newError;
  String? _confirmError;
  bool _submitting = false;

  @override
  void dispose() {
    _currentController.dispose();
    _newController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    // Clear all field errors before re-validating so stale errors disappear.
    setState(() {
      _currentError = null;
      _newError = null;
      _confirmError = null;
    });
    if (_currentController.text.isEmpty) {
      setState(
        () => _currentError =
            'Type your current password first so we can confirm it\'s you.',
      );
      return;
    }
    if (_newController.text.length < 12) {
      setState(
        () => _newError =
            'Use at least 12 characters for your new password. A short '
            'phrase from a song or book is easier to remember than a string '
            'of random characters.',
      );
      return;
    }
    if (_newController.text != _confirmController.text) {
      setState(
        () => _confirmError =
            'The two new passwords didn\'t match. Type the same password in '
            'both fields and try again.',
      );
      return;
    }
    final submit = widget.onSubmit;
    if (submit != null) {
      setState(() {
        _submitting = true;
        _currentError = null;
        _newError = null;
        _confirmError = null;
      });
      try {
        await submit(
          currentPassword: _currentController.text,
          newPassword: _newController.text,
        );
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _submitting = false;
          _currentError = 'Could not update the password: $error';
        });
        return;
      }
      if (!mounted) return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('change_password_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OperatorWebDialogHeader(
                title: 'Change password',
                closeKey: const Key('change_password_dialog_close'),
                onClose: _submitting
                    ? null
                    : () => Navigator.of(context).pop(false),
              ),
              const SizedBox(height: 8),
              Text(
                'A strong password is one of the simplest things you can do '
                'to keep your business data safe. Mix letters, numbers, and '
                'a symbol, and don\'t reuse it from another site.',
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('change_password_dialog_current'),
                controller: _currentController,
                obscureText: true,
                autofocus: true,
                enabled: !_submitting,
                decoration: InputDecoration(
                  labelText: 'Current password',
                  border: const OutlineInputBorder(),
                  errorText: _currentError,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('change_password_dialog_new'),
                controller: _newController,
                obscureText: true,
                enabled: !_submitting,
                decoration: InputDecoration(
                  labelText: 'New password',
                  border: const OutlineInputBorder(),
                  errorText: _newError,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('change_password_dialog_confirm'),
                controller: _confirmController,
                obscureText: true,
                enabled: !_submitting,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Confirm new password',
                  border: const OutlineInputBorder(),
                  errorText: _confirmError,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('change_password_dialog_cancel'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('change_password_dialog_submit'),
                    onPressed: _submitting ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.sunset,
                      foregroundColor: AppColors.backgroundSurface,
                    ),
                    child: _submitting
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
