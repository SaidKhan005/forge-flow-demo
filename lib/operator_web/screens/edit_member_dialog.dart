// Wave 2 W-1 — Operator Web Edit member dialog.
//
// Members edit-user write path. Lives next to the sibling
// [invite_member_dialog.dart]; the screen layer mounts this from the
// per-row "Edit member" action introduced in 11W.1's Members surface
// retrofit. The dialog edits two write-path fields and surfaces two
// read-only fields scoped by the Wave 2 ledger row W-1:
//
//   * email             — (write) change Firebase Identity Platform
//                         account email + Postgres mirror; sensitive
//                         (the dialog requires the operator to confirm
//                         before the Save button enables).
//   * display name      — (write) change Team display name + Firebase
//                         display name in lock-step.
//   * role assignment   — (read-only) shows the current role. Changing
//                         the role is intentionally NOT wired here; a
//                         follow-up slice (W-1-FU) wires the dropdown
//                         through the existing `createRoleGrant` +
//                         `revokeRoleGrant` gateway path. Operator
//                         decision 2026-05-14: keep the field visible
//                         so the operator can see the current role at
//                         a glance, but un-clickable so a role
//                         demotion cannot be silently dropped on save.
//   * hierarchy scope   — (read-only) shows the current scope (and the
//                         pinned location when scope = location). Same
//                         W-1-FU follow-up unlocks the dropdowns.
//
// Idempotency: the dialog mints one key for the email/display-name
// patch. The role-grant idempotency key is plumbed through but unused
// today because the role/scope rotation is read-only — W-1-FU will
// activate it.
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

  // Role + hierarchy scope dropdowns are intentionally read-only in
  // this dialog (operator decision 2026-05-14). Save lights up only
  // when email or display name changes; role/scope rotation is handled
  // by W-1-FU through the existing `createRoleGrant` /
  // `revokeRoleGrant` gateway path. Roles page remains the canonical
  // surface for role + scope changes today.
  bool get _anythingChanged => _emailChanged || _displayNameChanged;

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
    // Role + scope are read-only on this dialog, so roleMissing /
    // locationMissing cannot be triggered through the UI. The
    // existing role/location values come from the user fixture and
    // pass through the dialog untouched.
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
      // Role + hierarchy scope rotation is intentionally NOT wired
      // here. The dropdowns above render the current values as
      // read-only state (their `onChanged` is null). Operators change
      // role + scope through the Roles page today; W-1-FU will wire
      // the dropdowns through the existing
      // `TeamRoleGrantCreate`/`TeamRoleGrantRevoke` gateway methods.
      // See ledger row W-1 in `docs/_indices/WAVE_2_LEDGER.md`.
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
                // Role + hierarchy scope dropdowns are visible so the
                // operator can see the current role and scope at a
                // glance, but `onChanged: null` keeps them un-clickable.
                // The Roles page is the canonical surface for role +
                // scope changes today. W-1-FU will unlock the
                // dropdowns and wire them through the existing
                // createRoleGrant / revokeRoleGrant gateway path.
                DropdownButtonFormField<String>(
                  key: const Key('edit_member_dialog_role_field'),
                  initialValue: _selectedRoleId,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: null,
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
                  onChanged: null,
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
                    onChanged: null,
                    items: <DropdownMenuItem<String>>[
                      for (final location in widget.locationOptions)
                        DropdownMenuItem<String>(
                          value: location.locationId,
                          child: Text(location.name),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  'To change role or hierarchy scope, use the Roles page.',
                  key: const Key('edit_member_dialog_role_scope_lock_note'),
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
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
