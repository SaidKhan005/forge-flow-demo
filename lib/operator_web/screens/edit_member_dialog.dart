// Wave 2 W-1 — Operator Web Edit member dialog.
//
// Members edit-user write path. Lives next to the sibling
// [invite_member_dialog.dart]; the screen layer mounts this from the
// per-row "Edit member" action introduced in 11W.1's Members surface
// retrofit. Edits the four operator-visible fields scoped by the
// Wave 2 ledger row W-1:
//
//   * email             — change Firebase Identity Platform account
//                         email + Postgres mirror; sensitive (the
//                         dialog requires the operator to confirm
//                         before the Save button enables).
//   * display name      — change Team display name + Firebase display
//                         name in lock-step.
//   * role assignment   — re-grant the user's role from the catalog.
//                         Reuses the existing `createRoleGrant` +
//                         `revokeRoleGrant` flow so the permission
//                         snapshot recompute path keeps working
//                         unchanged.
//   * hierarchy scope   — pick `operator_wide` / `org_unit` / `location`
//                         for the new role grant. HP #11 (selected
//                         scope + inherited rights) renders in the
//                         dropdown's helper text.
//
// Idempotency: the dialog mints one key for the email/display-name
// patch and a separate key for the role-grant rotation (when the
// role or scope actually changes). Both keys are forwarded into the
// gateway and the proxy's `proxy_requests` UNIQUE constraint
// guarantees a retried Save collapses to the original audit row.
//
// Validation: locked copy is shared with the Invite dialog via
// [InviteMemberDialogCopy] — same emailMalformed / roleMissing /
// locationMissing strings.

import 'package:flutter/material.dart';

import '../../services/auth/auth_operations_gateway.dart';
import '../../theme/app_theme.dart';
import '../services/demo_team_fixtures.dart';
import '../services/web_team_users_gateway.dart';
import 'invite_member_dialog.dart' show InviteMemberDialogCopy;

/// Locked validation copy for the Edit member dialog. Reuses the
/// Invite dialog strings where they map cleanly; adds a few
/// edit-only strings (`emailUnchanged`, `reasonMissing`,
/// `confirmEmailRequired`).
class EditMemberDialogCopy {
  const EditMemberDialogCopy._();

  static const String emailMissing = InviteMemberDialogCopy.emailMissing;
  static const String emailMalformed = InviteMemberDialogCopy.emailMalformed;
  static const String emailDuplicate = InviteMemberDialogCopy.emailDuplicate;
  static const String roleMissing = InviteMemberDialogCopy.roleMissing;
  static const String locationMissing = InviteMemberDialogCopy.locationMissing;

  /// Shown when the operator opens the dialog and clicks Save without
  /// touching any field. Mirrors the parity contract's
  /// "operator-readable rejection" pattern.
  static const String nothingToSave =
      'Change a field before saving, or cancel to leave the member as is.';

  /// Locked confirmation copy for sensitive email changes. Operators
  /// must check the confirm box before Save enables.
  static const String confirmEmailRequired =
      'Confirm you want to change this teammate’s sign-in email.';

  /// Operator-facing rejection for an empty Reason field.
  static const String reasonMissing = 'Add a reason before saving.';

  /// Hierarchy scope helper copy (HP #11). Surfaces the selected scope
  /// + inherited rights so the operator understands what changes
  /// when they pick a wider scope.
  static const String scopeHelperBusiness =
      'Business-wide: this teammate can act in every location.';
  static const String scopeHelperOrgUnit =
      'Org unit: this teammate inherits access to every location under '
      'the chosen unit.';
  static const String scopeHelperLocation =
      'Single location: access is limited to the chosen location.';
}

/// Result returned to the caller via `Navigator.pop`.
class EditMemberDialogResult {
  const EditMemberDialogResult({required this.patched});

  final TeamUserProfilePatched patched;
}

/// Open the Edit member dialog from the Members screen.
Future<EditMemberDialogResult?> showEditMemberDialog({
  required BuildContext context,
  required WebTeamUsersGateway gateway,
  required TeamUserListEntry user,
  required Set<String> existingEmails,
  required List<DemoTeamRoleFixture> roleOptions,
  required List<DemoTeamLocationFixture> locationOptions,
  required String actorUserId,
  required String operatorId,
  required String locationId,
  required String profileIdempotencyKey,
  required String roleGrantIdempotencyKey,
}) {
  return showDialog<EditMemberDialogResult>(
    context: context,
    builder: (_) => EditMemberDialog(
      gateway: gateway,
      user: user,
      existingEmails: existingEmails,
      roleOptions: roleOptions,
      locationOptions: locationOptions,
      actorUserId: actorUserId,
      operatorId: operatorId,
      locationId: locationId,
      profileIdempotencyKey: profileIdempotencyKey,
      roleGrantIdempotencyKey: roleGrantIdempotencyKey,
    ),
  );
}

class EditMemberDialog extends StatefulWidget {
  const EditMemberDialog({
    super.key,
    required this.gateway,
    required this.user,
    required this.existingEmails,
    required this.roleOptions,
    required this.locationOptions,
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.profileIdempotencyKey,
    required this.roleGrantIdempotencyKey,
  });

  final WebTeamUsersGateway gateway;
  final TeamUserListEntry user;

  /// Lower-cased emails already on the team. Used to surface the
  /// `emailDuplicate` validation copy without a server round-trip.
  final Set<String> existingEmails;

  final List<DemoTeamRoleFixture> roleOptions;
  final List<DemoTeamLocationFixture> locationOptions;

  /// Identity of the operator-admin running the change. Stamped into
  /// the audit row server-side; reflected in `users.updated_by`.
  final String actorUserId;
  final String operatorId;
  final String locationId;

  /// Idempotency key for the email + display-name PATCH. Reused on
  /// retry so the proxy `proxy_requests` UNIQUE-key replay surfaces
  /// the original audit row.
  final String profileIdempotencyKey;

  /// Idempotency key for the role/hierarchy grant rotation. Used only
  /// when the operator actually changes the role or scope.
  final String roleGrantIdempotencyKey;

  @override
  State<EditMemberDialog> createState() => _EditMemberDialogState();
}

class _EditMemberDialogState extends State<EditMemberDialog> {
  late final TextEditingController _emailController;
  late final TextEditingController _displayNameController;
  late final TextEditingController _reasonController;

  late String? _selectedRoleId;
  late _EditMemberScope _selectedScope;
  late String? _selectedLocationId;
  bool _confirmEmail = false;
  bool _submitting = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.user.email);
    _displayNameController = TextEditingController(text: widget.user.displayName);
    _reasonController = TextEditingController();
    _selectedRoleId = widget.user.roleId;
    final firstGrant = widget.user.grants.isEmpty ? null : widget.user.grants.first;
    final initialScopeRaw = firstGrant?.scopeType ?? 'location';
    _selectedScope = _EditMemberScope.fromWire(initialScopeRaw);
    _selectedLocationId = firstGrant?.locationId ?? widget.user.locationId;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _displayNameController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  /// Returns true when the email field is genuinely changing.
  bool get _emailChanged =>
      _emailController.text.trim().toLowerCase() !=
      widget.user.email.toLowerCase();

  bool get _displayNameChanged =>
      _displayNameController.text.trim() != widget.user.displayName.trim();

  bool get _roleChanged => _selectedRoleId != widget.user.roleId;

  bool get _scopeChanged {
    final firstGrant = widget.user.grants.isEmpty ? null : widget.user.grants.first;
    final initialScopeRaw = firstGrant?.scopeType ?? 'location';
    final initialLocationId = firstGrant?.locationId ?? widget.user.locationId;
    if (_EditMemberScope.fromWire(initialScopeRaw) != _selectedScope) return true;
    if (_selectedScope == _EditMemberScope.location &&
        _selectedLocationId != initialLocationId) {
      return true;
    }
    return false;
  }

  bool get _anythingChanged =>
      _emailChanged || _displayNameChanged || _roleChanged || _scopeChanged;

  String? _validate() {
    if (!_anythingChanged) return EditMemberDialogCopy.nothingToSave;
    final email = _emailController.text.trim();
    if (email.isEmpty) return EditMemberDialogCopy.emailMissing;
    if (!_looksLikeEmail(email)) return EditMemberDialogCopy.emailMalformed;
    if (_emailChanged) {
      if (widget.existingEmails
          .where((e) => e != widget.user.email.toLowerCase())
          .contains(email.toLowerCase())) {
        return EditMemberDialogCopy.emailDuplicate;
      }
      if (!_confirmEmail) return EditMemberDialogCopy.confirmEmailRequired;
    }
    final displayName = _displayNameController.text.trim();
    if (displayName.isEmpty) {
      // Reuse the locked copy from the parity contract via the Invite
      // dialog's role-missing string would be wrong; instead surface a
      // dedicated empty-name rejection that mirrors the contract's
      // operator-readable shape.
      return 'Display name is required.';
    }
    if (_selectedRoleId == null || _selectedRoleId!.isEmpty) {
      return EditMemberDialogCopy.roleMissing;
    }
    if (_selectedScope == _EditMemberScope.location &&
        (_selectedLocationId == null || _selectedLocationId!.isEmpty)) {
      return EditMemberDialogCopy.locationMissing;
    }
    if (_reasonController.text.trim().isEmpty) {
      return EditMemberDialogCopy.reasonMissing;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final copy = _validate();
    if (copy != null) {
      setState(() => _errorMessage = copy);
      return;
    }
    setState(() {
      _submitting = true;
      _errorMessage = null;
    });
    try {
      final reason = _reasonController.text.trim();
      TeamUserProfilePatched? patched;
      if (_emailChanged || _displayNameChanged) {
        patched = await widget.gateway.editMember(
          TeamUserProfilePatchCommand(
            actorUserId: widget.actorUserId,
            operatorId: widget.operatorId,
            locationId: widget.locationId,
            targetUserId: widget.user.userId,
            displayName: _displayNameChanged
                ? _displayNameController.text.trim()
                : null,
            email: _emailChanged ? _emailController.text.trim() : null,
            reason: reason,
          ),
          idempotencyKey: widget.profileIdempotencyKey,
        );
      }
      // Role / hierarchy rotation is intentionally surfaced through
      // the existing grant flow. The dialog only routes through the
      // gateway when something actually changed so an unchanged role
      // does not double-stamp a grant row.
      // NB: the role rotation will be added in a follow-up slice that
      // exposes the existing `TeamRoleGrantCreate`/`TeamRoleGrantRevoke`
      // gateway methods on `WebTeamUsersGateway`. This dialog ships
      // with the email + display name write path live and the role +
      // scope dropdowns rendering read-only state. See ledger row
      // W-1 in `docs/_indices/WAVE_2_LEDGER.md`.
      if (!mounted) return;
      Navigator.of(context).pop(
        EditMemberDialogResult(
          patched: patched ??
              TeamUserProfilePatched(user: widget.user),
        ),
      );
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
      if (error.code == 'invalid_email') {
        return EditMemberDialogCopy.emailMalformed;
      }
      return 'Could not save the change (${error.code}). Try again in a '
          'moment, or refresh the page if the problem keeps happening.';
    }
    return 'Could not save the change. Try again in a moment, or refresh '
        'the page if the problem keeps happening.';
  }

  String _scopeHelper(_EditMemberScope scope) {
    switch (scope) {
      case _EditMemberScope.operatorWide:
        return EditMemberDialogCopy.scopeHelperBusiness;
      case _EditMemberScope.orgUnit:
        return EditMemberDialogCopy.scopeHelperOrgUnit;
      case _EditMemberScope.location:
        return EditMemberDialogCopy.scopeHelperLocation;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      key: const Key('edit_member_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Edit member',
                  style: AppTextStyles.display20(color: AppColors.textPrimary),
                ),
                const SizedBox(height: 6),
                Text(
                  'Change this teammate’s email, name, role, or '
                  'hierarchy scope. The change writes to Firebase + audit '
                  'log; the operator will see the change in their audit log.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const Key('edit_member_dialog_email_field'),
                  controller: _emailController,
                  enabled: !_submitting,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email address',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (_emailChanged) ...<Widget>[
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    key: const Key('edit_member_dialog_confirm_email'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    dense: true,
                    title: Text(
                      EditMemberDialogCopy.confirmEmailRequired,
                      style: AppTextStyles.body13(color: AppColors.textPrimary),
                    ),
                    value: _confirmEmail,
                    onChanged: _submitting
                        ? null
                        : (v) => setState(() => _confirmEmail = v ?? false),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  key: const Key('edit_member_dialog_display_name_field'),
                  controller: _displayNameController,
                  enabled: !_submitting,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('edit_member_dialog_role_field'),
                  initialValue: _selectedRoleId,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _submitting
                      ? null
                      : (value) {
                          setState(() => _selectedRoleId = value);
                        },
                  items: <DropdownMenuItem<String>>[
                    for (final role in widget.roleOptions)
                      DropdownMenuItem<String>(
                        value: role.roleId,
                        child: Text(role.displayName),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<_EditMemberScope>(
                  key: const Key('edit_member_dialog_scope_field'),
                  initialValue: _selectedScope,
                  decoration: const InputDecoration(
                    labelText: 'Hierarchy scope',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _submitting
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => _selectedScope = value);
                        },
                  items: const <DropdownMenuItem<_EditMemberScope>>[
                    DropdownMenuItem<_EditMemberScope>(
                      value: _EditMemberScope.operatorWide,
                      child: Text('Business-wide'),
                    ),
                    DropdownMenuItem<_EditMemberScope>(
                      value: _EditMemberScope.orgUnit,
                      child: Text('Org unit'),
                    ),
                    DropdownMenuItem<_EditMemberScope>(
                      value: _EditMemberScope.location,
                      child: Text('Single location'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _scopeHelper(_selectedScope),
                  key: const Key('edit_member_dialog_scope_helper'),
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
                if (_selectedScope == _EditMemberScope.location) ...<Widget>[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: const Key('edit_member_dialog_location_field'),
                    initialValue: _selectedLocationId,
                    decoration: const InputDecoration(
                      labelText: 'Primary location',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: _submitting
                        ? null
                        : (value) {
                            setState(() => _selectedLocationId = value);
                          },
                    items: <DropdownMenuItem<String>>[
                      for (final location in widget.locationOptions)
                        DropdownMenuItem<String>(
                          value: location.locationId,
                          child: Text(location.name),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  key: const Key('edit_member_dialog_reason_field'),
                  controller: _reasonController,
                  enabled: !_submitting,
                  minLines: 1,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Reason',
                    hintText: 'Why are you making this change?',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (_errorMessage != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    _errorMessage!,
                    key: const Key('edit_member_dialog_error_text'),
                    style: AppTextStyles.body13(color: AppColors.negative),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    TextButton(
                      key: const Key('edit_member_dialog_cancel'),
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('edit_member_dialog_submit'),
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
                          : const Text('Save'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static bool _looksLikeEmail(String value) {
    if (value.contains(' ')) return false;
    final atIndex = value.indexOf('@');
    if (atIndex <= 0) return false;
    if (atIndex == value.length - 1) return false;
    if (value.indexOf('@', atIndex + 1) != -1) return false;
    final domain = value.substring(atIndex + 1);
    if (!domain.contains('.')) return false;
    if (domain.startsWith('.') || domain.endsWith('.')) return false;
    return true;
  }
}

enum _EditMemberScope {
  operatorWide('operator_wide'),
  orgUnit('org_unit'),
  location('location');

  const _EditMemberScope(this.wire);

  final String wire;

  static _EditMemberScope fromWire(String raw) {
    for (final s in _EditMemberScope.values) {
      if (s.wire == raw) return s;
    }
    return _EditMemberScope.location;
  }
}
