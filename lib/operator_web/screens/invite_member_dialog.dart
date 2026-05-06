// Phase 11W.1 - Operator Web invite member dialog.
//
// Single-step invite form mounted from the Members screen "Invite
// member" button. Mirrors the locked validation copy from the
// Team / Roles / Hierarchy / Sessions / Audit / Security console
// parity contract § Members + Invites:
//
//   * Empty email   → "Email address is required."
//   * Bad email     → "Enter a valid email address."
//   * Already on team → "This email is already on the team. Edit the
//                       existing member instead."
//   * Missing role  → "Choose a role for this member."
//   * Missing loc.  → "Choose a primary location for this member."
//
// The dialog accepts a single idempotency key from its caller; that
// same key is replayed on a retry so the proxy `proxy_requests`
// UNIQUE-key replay surfaces the original invite row instead of
// double-issuing.

import 'package:flutter/material.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../../services/team/team_invite_form_controller.dart';
import '../services/demo_team_fixtures.dart';
import '../services/web_team_users_gateway.dart';
import '../../theme/app_theme.dart';

/// Locked validation copy. Tests assert against these strings to pin
/// the parity contract against the rendered dialog copy.
class InviteMemberDialogCopy {
  const InviteMemberDialogCopy._();

  static const String emailMissing = 'Email address is required.';
  static const String emailMalformed = 'Enter a valid email address.';
  static const String emailDuplicate =
      'This email is already on the team. Edit the existing member instead.';
  static const String roleMissing = 'Choose a role for this member.';
  static const String locationMissing =
      'Choose a primary location for this member.';
}

/// Result returned to the caller via `Navigator.pop`.
class InviteMemberDialogResult {
  const InviteMemberDialogResult({required this.created});

  final TeamInviteCreated created;
}

/// Open the invite dialog from the Members screen.
Future<InviteMemberDialogResult?> showInviteMemberDialog({
  required BuildContext context,
  required WebTeamUsersGateway gateway,
  required TeamUserListCommand listCommand,
  required Set<String> existingEmails,
  required List<DemoTeamRoleFixture> roleOptions,
  required List<DemoTeamLocationFixture> locationOptions,
  required String idempotencyKey,
}) {
  return showDialog<InviteMemberDialogResult>(
    context: context,
    builder: (_) => InviteMemberDialog(
      gateway: gateway,
      listCommand: listCommand,
      existingEmails: existingEmails,
      roleOptions: roleOptions,
      locationOptions: locationOptions,
      idempotencyKey: idempotencyKey,
    ),
  );
}

/// Modal form widget. Stateful so the email field, role + location
/// dropdowns, error message, and submit-in-flight flag can drive
/// rebuilds locally without re-running the parent screen.
class InviteMemberDialog extends StatefulWidget {
  const InviteMemberDialog({
    super.key,
    required this.gateway,
    required this.listCommand,
    required this.existingEmails,
    required this.roleOptions,
    required this.locationOptions,
    required this.idempotencyKey,
  });

  final WebTeamUsersGateway gateway;
  final TeamUserListCommand listCommand;

  /// Lower-cased emails already on the team. Used to surface the
  /// `emailDuplicate` validation copy without a server round-trip.
  final Set<String> existingEmails;

  final List<DemoTeamRoleFixture> roleOptions;
  final List<DemoTeamLocationFixture> locationOptions;

  /// Caller-minted key. The dialog reuses the same key on retry so
  /// the proxy replay returns the original invite row.
  final String idempotencyKey;

  @override
  State<InviteMemberDialog> createState() => _InviteMemberDialogState();
}

class _InviteMemberDialogState extends State<InviteMemberDialog> {
  late final TeamInviteFormController _form;
  late final TextEditingController _emailController;
  String? _errorMessage;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _form = TeamInviteFormController();
    _emailController = TextEditingController();
    _form.addListener(_handleFormChange);
  }

  @override
  void dispose() {
    _form.removeListener(_handleFormChange);
    _form.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _handleFormChange() {
    if (!mounted) return;
    if (_emailController.text != _form.email) {
      _emailController.text = _form.email;
    }
    setState(() {});
  }

  String? _resolveValidationCopy() {
    final trimmed = _form.email.trim();
    if (trimmed.isEmpty) return InviteMemberDialogCopy.emailMissing;
    if (!_looksLikeEmail(trimmed)) {
      return InviteMemberDialogCopy.emailMalformed;
    }
    if (widget.existingEmails.contains(trimmed.toLowerCase())) {
      return InviteMemberDialogCopy.emailDuplicate;
    }
    if (_form.roleId == null || _form.roleId!.isEmpty) {
      return InviteMemberDialogCopy.roleMissing;
    }
    if (_form.scope == null) {
      return InviteMemberDialogCopy.locationMissing;
    }
    if (_form.scope == TeamInviteScope.location &&
        (_form.locationId == null || _form.locationId!.isEmpty)) {
      return InviteMemberDialogCopy.locationMissing;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final copy = _resolveValidationCopy();
    if (copy != null) {
      setState(() => _errorMessage = copy);
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final created = await widget.gateway.createInvite(
        TeamInviteCreateCommand(
          actorUserId: widget.listCommand.actorUserId,
          operatorId: widget.listCommand.operatorId,
          locationId: widget.listCommand.locationId,
          email: _form.email.trim(),
          roleId: _form.roleId!,
          scopeType: _form.scope!.sqlKey,
          targetLocationId: _form.scope == TeamInviteScope.location
              ? _form.locationId
              : null,
          targetOrgUnitId: _form.scope == TeamInviteScope.orgUnit
              ? _form.orgUnitId
              : null,
        ),
        idempotencyKey: widget.idempotencyKey,
      );
      if (!mounted) return;
      Navigator.of(context).pop(InviteMemberDialogResult(created: created));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorMessage = _friendlyErrorFor(error);
      });
    }
  }

  String _friendlyErrorFor(Object error) {
    if (error is WebTeamUsersError) {
      if (error.code == 'duplicate_invite' ||
          error.code == 'email_already_on_team') {
        return InviteMemberDialogCopy.emailDuplicate;
      }
      return 'Could not send the invite (${error.code}). Try again in a '
          'moment, or refresh the page if the problem keeps happening.';
    }
    return 'Could not send the invite. Try again in a moment, or refresh '
        'the page if the problem keeps happening.';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('invite_member_dialog'),
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
                'Invite a team member',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                'Send an email invite. The new teammate will set their own '
                'password and turn on two-factor sign-in before they get to '
                'your dashboard.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              TextField(
                key: const Key('invite_member_dialog_email_field'),
                controller: _emailController,
                autofocus: true,
                enabled: !_submitting,
                keyboardType: TextInputType.emailAddress,
                onChanged: _form.setEmail,
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  hintText: 'jordan.lee@example.com',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('invite_member_dialog_role_field'),
                initialValue: _form.roleId,
                onChanged: _submitting
                    ? null
                    : (value) {
                        _form.setRoleId(value);
                      },
                decoration: const InputDecoration(
                  labelText: 'Role',
                  border: OutlineInputBorder(),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final role in widget.roleOptions)
                    DropdownMenuItem<String>(
                      value: role.roleId,
                      child: Text(role.displayName),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('invite_member_dialog_location_field'),
                initialValue: _form.locationId,
                onChanged: _submitting
                    ? null
                    : (value) {
                        if (value == null) return;
                        _form.setScope(TeamInviteScope.location);
                        _form.setLocationId(value);
                      },
                decoration: const InputDecoration(
                  labelText: 'Primary location',
                  border: OutlineInputBorder(),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final location in widget.locationOptions)
                    DropdownMenuItem<String>(
                      value: location.locationId,
                      child: Text(location.name),
                    ),
                ],
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 10),
                Text(
                  _errorMessage!,
                  key: const Key('invite_member_dialog_error_text'),
                  style: AppTextStyles.body13(color: AppColors.negative),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    key: const Key('invite_member_dialog_cancel'),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const Key('invite_member_dialog_submit'),
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
                        : const Text('Send invite'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _looksLikeEmail(String value) {
    final atIndex = value.indexOf('@');
    if (atIndex <= 0) return false;
    if (atIndex == value.length - 1) return false;
    if (value.contains(' ')) return false;
    final domain = value.substring(atIndex + 1);
    return domain.contains('.');
  }
}
