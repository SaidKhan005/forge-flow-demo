// Phase 11A.12 - F&F admin invite-member dialog.
//
// Single-step invite form with the same field set + locked validation
// copy as the operator-web sibling (`11W.1`), plus an explicit
// `admin_reason` field that every admin-path mutation requires per
// the parity contract. Emits an [InviteMemberAdminDraft] on submit
// which the calling screen forwards to the gateway with a freshly
// minted idempotency key.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../services/members_admin_gateway.dart';

/// Lightweight ref pair the dialog renders in its location dropdown.
/// The screen owns the source of truth (it knows the operator's
/// locations from the picker result) and passes them in.
@immutable
class MemberLocationRef {
  const MemberLocationRef({required this.locationId, required this.name});

  final String locationId;
  final String name;
}

@immutable
class InviteMemberAdminDraft {
  const InviteMemberAdminDraft({
    required this.email,
    required this.displayName,
    required this.roleKey,
    required this.primaryLocationId,
    required this.adminReason,
    this.welcomeNote,
  });

  final String email;
  final String displayName;
  final String roleKey;
  final String primaryLocationId;
  final String adminReason;
  final String? welcomeNote;
}

class InviteMemberAdminDialog extends StatefulWidget {
  const InviteMemberAdminDialog({
    super.key,
    required this.operatorBusinessName,
    required this.locations,
    this.existingEmails = const <String>{},
  });

  final String operatorBusinessName;
  final List<MemberLocationRef> locations;

  /// Lower-cased emails already on the team. Used by the dialog to
  /// surface the locked "email already on the team" copy without
  /// round-tripping the proxy.
  final Set<String> existingEmails;

  @override
  State<InviteMemberAdminDialog> createState() =>
      _InviteMemberAdminDialogState();
}

class _InviteMemberAdminDialogState extends State<InviteMemberAdminDialog> {
  final _emailController = TextEditingController();
  final _displayNameController = TextEditingController();
  final _adminReasonController = TextEditingController();
  final _welcomeNoteController = TextEditingController();
  String? _roleKey;
  String? _locationId;
  String? _violation;

  @override
  void dispose() {
    _emailController.dispose();
    _displayNameController.dispose();
    _adminReasonController.dispose();
    _welcomeNoteController.dispose();
    super.dispose();
  }

  String? _validate() {
    final email = _emailController.text.trim();
    if (email.isEmpty) return MembersValidationCopy.emailEmpty;
    if (!_looksLikeEmail(email)) return MembersValidationCopy.emailMalformed;
    if (widget.existingEmails.contains(email.toLowerCase())) {
      return MembersValidationCopy.emailDuplicate;
    }
    final role = _roleKey;
    if (role == null || role.isEmpty) {
      return MembersValidationCopy.roleMissing;
    }
    final loc = _locationId;
    if (loc == null || loc.isEmpty) {
      return MembersValidationCopy.locationMissing;
    }
    if (_displayNameController.text.trim().isEmpty) {
      return 'Display name is required.';
    }
    if (_adminReasonController.text.trim().isEmpty) {
      // Admin-path-only validation; the operator self-service
      // sibling (`11W.1`) does not surface this field at all because
      // self-service writes don't carry `admin_reason`. Plain-
      // English copy mirrors the in-screen reason dialog so the
      // operator-facing audit log reads consistently.
      return 'Add a reason before sending the invite.';
    }
    return null;
  }

  static bool _looksLikeEmail(String value) {
    final atIndex = value.indexOf('@');
    if (atIndex <= 0) return false;
    if (atIndex == value.length - 1) return false;
    if (value.contains(' ')) return false;
    return true;
  }

  void _onSubmit() {
    final violation = _validate();
    if (violation != null) {
      setState(() => _violation = violation);
      return;
    }
    final welcome = _welcomeNoteController.text.trim();
    Navigator.of(context).pop(
      InviteMemberAdminDraft(
        email: _emailController.text.trim(),
        displayName: _displayNameController.text.trim(),
        roleKey: _roleKey!,
        primaryLocationId: _locationId!,
        adminReason: _adminReasonController.text.trim(),
        welcomeNote: welcome.isEmpty ? null : welcome,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_members_invite_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Invite member to ${widget.operatorBusinessName}',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_violation != null) ...[
                _ValidationBanner(message: _violation!),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const Key('admin_members_invite_email'),
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  hintText: 'name@example.com',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.emailAddress,
                autofillHints: const <String>[AutofillHints.email],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_members_invite_display_name'),
                controller: _displayNameController,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('admin_members_invite_role'),
                initialValue: _roleKey,
                isExpanded: true,
                hint: const Text('Choose role'),
                decoration: const InputDecoration(
                  labelText: 'Role',
                  border: OutlineInputBorder(),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final role in kSeededRoleKeysForAdmin)
                    DropdownMenuItem<String>(
                      key: Key('admin_members_invite_role_$role'),
                      value: role,
                      child: Text(memberRoleLabel(role)),
                    ),
                ],
                onChanged: (v) => setState(() => _roleKey = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const Key('admin_members_invite_location'),
                initialValue: _locationId,
                isExpanded: true,
                hint: const Text('Choose primary location'),
                decoration: const InputDecoration(
                  labelText: 'Primary location',
                  border: OutlineInputBorder(),
                ),
                items: <DropdownMenuItem<String>>[
                  for (final loc in widget.locations)
                    DropdownMenuItem<String>(
                      key: Key(
                        'admin_members_invite_location_${loc.locationId}',
                      ),
                      value: loc.locationId,
                      child: Text(loc.name),
                    ),
                ],
                onChanged: (v) => setState(() => _locationId = v),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_members_invite_welcome_note'),
                controller: _welcomeNoteController,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Welcome note (optional)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('admin_members_invite_admin_reason'),
                controller: _adminReasonController,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Admin reason (required)',
                  hintText: 'Why is F&F support inviting this member?',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_members_invite_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_members_invite_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Send invite'),
        ),
      ],
    );
  }
}

class _ValidationBanner extends StatelessWidget {
  const _ValidationBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_members_invite_validation_banner'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.negative.withValues(alpha: 0.08),
        border: Border.all(
          color: AppColors.negative.withValues(alpha: 0.45),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        message,
        style: AppTextStyles.body13(color: AppColors.negative),
      ),
    );
  }
}
