// Wave 2 W-3 — Operator Web edit-self-profile dialog.
//
// Distinct from `edit_member_dialog.dart` (W-1) which edits *another*
// teammate's row. This dialog edits the signed-in operator's own
// display name and email. Two fields, plain English, no admin_reason
// field (you don't justify editing your own profile to yourself).
//
// Sensitive email change: when the operator touches the email field,
// a confirmation checkbox appears below the field, and the Save
// button stays disabled until they tick it. Mirrors the freshness
// pattern the W-1 admin edit uses.
//
// On success, the dialog pops with a [EditSelfProfileResult] carrying
// `emailChanged` so the caller can force a sign-out if the operator
// rotated their identity.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../account/operator_web_account_actions.dart';
import '../services/operator_web_proxy_client.dart';
import '../services/web_account_gateway.dart';

/// Locked validation copy.
class EditSelfProfileDialogCopy {
  const EditSelfProfileDialogCopy._();

  static const String displayNameMissing = 'Display name is required.';
  static const String emailMissing = 'Email address is required.';
  static const String emailMalformed = 'Enter a valid email address.';
  static const String nothingToSave =
      'Change a field before saving, or cancel to keep your profile as is.';
  static const String confirmEmailRequired =
      'Confirm you want to change your sign-in email.';
  static const String emailChangeNote =
      'When you change your sign-in email, we sign you out so you can '
      'sign back in with the new address.';
}

/// Result returned by the dialog. `null` (not popping with a result)
/// means the operator cancelled.
class EditSelfProfileResult {
  const EditSelfProfileResult({required this.patched});

  /// The patched profile, as returned by the proxy. Carries
  /// `emailChanged` so the caller can force a sign-out.
  final SelfProfilePatchResult patched;
}

/// Opens the dialog. Returns `null` if the operator cancelled, or a
/// non-null result on save.
Future<EditSelfProfileResult?> showEditSelfProfileDialog({
  required BuildContext context,
  required OperatorWebAccountActions actions,
  required String currentDisplayName,
  required String currentEmail,
}) {
  return showDialog<EditSelfProfileResult>(
    context: context,
    builder: (_) => EditSelfProfileDialog(
      actions: actions,
      currentDisplayName: currentDisplayName,
      currentEmail: currentEmail,
    ),
  );
}

class EditSelfProfileDialog extends StatefulWidget {
  const EditSelfProfileDialog({
    super.key,
    required this.actions,
    required this.currentDisplayName,
    required this.currentEmail,
  });

  final OperatorWebAccountActions actions;
  final String currentDisplayName;
  final String currentEmail;

  @override
  State<EditSelfProfileDialog> createState() => _EditSelfProfileDialogState();
}

class _EditSelfProfileDialogState extends State<EditSelfProfileDialog> {
  late final TextEditingController _displayNameController;
  late final TextEditingController _emailController;
  bool _confirmEmailChange = false;
  bool _submitting = false;
  String? _topLevelError;

  @override
  void initState() {
    super.initState();
    _displayNameController = TextEditingController(
      text: widget.currentDisplayName,
    );
    _emailController = TextEditingController(text: widget.currentEmail);
    _displayNameController.addListener(_onFieldChanged);
    _emailController.addListener(_onFieldChanged);
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (!mounted) return;
    setState(() {
      // Clear the top-level error as soon as the operator edits.
      if (_topLevelError != null) _topLevelError = null;
    });
  }

  String _trimmedDisplayName() => _displayNameController.text.trim();
  String _trimmedEmail() => _emailController.text.trim();

  bool get _displayNameChanged =>
      _trimmedDisplayName() != widget.currentDisplayName.trim();
  bool get _emailChanged =>
      _trimmedEmail().toLowerCase() != widget.currentEmail.trim().toLowerCase();

  bool get _hasChange => _displayNameChanged || _emailChanged;

  bool get _canSave {
    if (_submitting || !_hasChange) return false;
    if (_emailChanged && !_confirmEmailChange) return false;
    if (_emailChanged && !_looksLikeEmail(_trimmedEmail())) return false;
    if (_displayNameChanged && _trimmedDisplayName().isEmpty) return false;
    return true;
  }

  static bool _looksLikeEmail(String value) {
    if (value.contains(' ')) return false;
    final atIndex = value.indexOf('@');
    if (atIndex <= 0 || atIndex == value.length - 1) return false;
    if (value.indexOf('@', atIndex + 1) != -1) return false;
    final domain = value.substring(atIndex + 1);
    if (!domain.contains('.')) return false;
    if (domain.startsWith('.') || domain.endsWith('.')) return false;
    return true;
  }

  Future<void> _handleSave() async {
    if (!_canSave) return;
    setState(() {
      _submitting = true;
      _topLevelError = null;
    });
    try {
      final patched = await widget.actions.patchSelfProfile(
        displayName: _displayNameChanged ? _trimmedDisplayName() : null,
        email: _emailChanged ? _trimmedEmail() : null,
      );
      if (!mounted) return;
      if (patched == null) {
        setState(() {
          _submitting = false;
          _topLevelError =
              'Profile editing is not available in this build. Reach out to '
              'Forge & Flow support if you need to change your sign-in email.';
        });
        return;
      }
      Navigator.of(context).pop(EditSelfProfileResult(patched: patched));
    } on OperatorWebProxyException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _topLevelError = _friendly(error);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _topLevelError = 'Could not save your profile: $error';
      });
    }
  }

  String _friendly(OperatorWebProxyException error) {
    if (error.isMfaFreshnessRedirect) {
      return 'Please sign in again to continue. This protects your account '
          'before changing your email.';
    }
    switch (error.code) {
      case 'invalid_email':
        return EditSelfProfileDialogCopy.emailMalformed;
      case 'no_profile_fields':
        return EditSelfProfileDialogCopy.nothingToSave;
      default:
        return error.message;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('edit_self_profile_dialog'),
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
                'Edit your profile',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                'Your display name shows up on every shift, schedule, and '
                'audit row. Your email is what you sign in with.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 16),
              _LabelledField(
                label: 'Display name',
                child: TextField(
                  key: const Key('edit_self_profile_display_name_field'),
                  controller: _displayNameController,
                  enabled: !_submitting,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _LabelledField(
                label: 'Email',
                child: TextField(
                  key: const Key('edit_self_profile_email_field'),
                  controller: _emailController,
                  enabled: !_submitting,
                  keyboardType: TextInputType.emailAddress,
                  inputFormatters: [
                    FilteringTextInputFormatter.deny(RegExp(r'\s')),
                  ],
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              if (_emailChanged) ...[
                const SizedBox(height: 10),
                Container(
                  key: const Key('edit_self_profile_email_confirm_box'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.sunset.withValues(alpha: 0.08),
                    border: Border.all(
                      color: AppColors.sunset.withValues(alpha: 0.40),
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        EditSelfProfileDialogCopy.emailChangeNote,
                        style: AppTextStyles.body13(
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      InkWell(
                        onTap: _submitting
                            ? null
                            : () => setState(
                                () => _confirmEmailChange = !_confirmEmailChange,
                              ),
                        child: Row(
                          children: [
                            Checkbox(
                              key: const Key(
                                'edit_self_profile_email_confirm_checkbox',
                              ),
                              value: _confirmEmailChange,
                              onChanged: _submitting
                                  ? null
                                  : (v) => setState(
                                      () => _confirmEmailChange = v ?? false,
                                    ),
                            ),
                            Expanded(
                              child: Text(
                                EditSelfProfileDialogCopy.confirmEmailRequired,
                                style: AppTextStyles.body13(
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (_topLevelError != null) ...[
                const SizedBox(height: 10),
                Container(
                  key: const Key('edit_self_profile_error'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.negative.withValues(alpha: 0.08),
                    border: Border.all(
                      color: AppColors.negative.withValues(alpha: 0.30),
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _topLevelError!,
                    style: AppTextStyles.body13(color: AppColors.negative),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('edit_self_profile_cancel'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('edit_self_profile_save'),
                    onPressed: _canSave ? _handleSave : null,
                    child: Text(_submitting ? 'Saving...' : 'Save changes'),
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

class _LabelledField extends StatelessWidget {
  const _LabelledField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.mono11(color: AppColors.sunsetDark),
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
