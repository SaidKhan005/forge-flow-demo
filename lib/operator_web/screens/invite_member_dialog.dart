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
import '../widgets/hierarchy_map_picker.dart';
import '../widgets/hierarchy_tree_picker.dart';
import '../widgets/operator_web_surface.dart';

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
///
/// [orgUnitOptions] + [businessLabel] are optional: when the caller
/// omits them the picker falls back to the demo fixture so the
/// hierarchy tree still renders Business → Region → Location during
/// the walkthrough.
Future<InviteMemberDialogResult?> showInviteMemberDialog({
  required BuildContext context,
  required WebTeamUsersGateway gateway,
  required TeamUserListCommand listCommand,
  required Set<String> existingEmails,
  required List<DemoTeamRoleFixture> roleOptions,
  required List<DemoTeamLocationFixture> locationOptions,
  required String idempotencyKey,
  List<DemoTeamOrgUnitFixture> orgUnitOptions = kDemoTeamOrgUnitsFixture,
  String businessLabel = kDemoOperatorBusinessNameFixture,
}) {
  return showDialog<InviteMemberDialogResult>(
    context: context,
    builder: (_) => InviteMemberDialog(
      gateway: gateway,
      listCommand: listCommand,
      existingEmails: existingEmails,
      roleOptions: roleOptions,
      locationOptions: locationOptions,
      orgUnitOptions: orgUnitOptions,
      businessLabel: businessLabel,
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
    this.orgUnitOptions = kDemoTeamOrgUnitsFixture,
    this.businessLabel = kDemoOperatorBusinessNameFixture,
  });

  final WebTeamUsersGateway gateway;
  final TeamUserListCommand listCommand;

  /// Lower-cased emails already on the team. Used to surface the
  /// `emailDuplicate` validation copy without a server round-trip.
  final Set<String> existingEmails;

  final List<DemoTeamRoleFixture> roleOptions;
  final List<DemoTeamLocationFixture> locationOptions;

  /// Org-unit tree the hierarchy-tree picker walks alongside the
  /// flat location list. Demo build defaults to the shared fixture;
  /// live build will replace this with the operator's hierarchy
  /// gateway projection in a follow-up live wiring slice.
  final List<DemoTeamOrgUnitFixture> orgUnitOptions;

  /// Business label rendered at the root of the picker tree (e.g.
  /// "Demo Bistro"). Defaults to the demo fixture name.
  final String businessLabel;

  /// Caller-minted key. The dialog reuses the same key on retry so
  /// the proxy replay returns the original invite row.
  final String idempotencyKey;

  @override
  State<InviteMemberDialog> createState() => _InviteMemberDialogState();
}

/// Process-level cache of the operator's last hierarchy pick. The
/// dialog rewires this on every open so a Cancel → Reopen returns
/// the operator to the same selection mid-invite (HP #11 walks the
/// operator through scope; losing their pick on a typo correction is
/// hostile). Cleared once an invite submits successfully.
String? _lastSelectedHierarchyNodeId;

class _InviteMemberDialogState extends State<InviteMemberDialog> {
  late final TeamInviteFormController _form;
  late final TextEditingController _emailController;
  late final List<HierarchyMapNode> _hierarchyNodes;
  String? _selectedHierarchyNodeId;
  String? _errorMessage;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _form = TeamInviteFormController();
    _emailController = TextEditingController();
    _form.addListener(_handleFormChange);
    _hierarchyNodes = buildInviteHierarchyNodes(
      businessId: widget.listCommand.operatorId,
      businessLabel: widget.businessLabel,
      orgUnits: <({String orgUnitId, String name, String? parentOrgUnitId})>[
        for (final unit in widget.orgUnitOptions)
          // The "corp" root org-unit (e.g. `demo-org-root`) doubles as
          // the business node already rendered by
          // buildInviteHierarchyNodes; skipping it keeps the tree from
          // showing two business-wide rows.
          if (unit.unitType != 'corp')
            (
              orgUnitId: unit.orgUnitId,
              name: unit.name,
              parentOrgUnitId: _isCorpRoot(unit.parentOrgUnitId)
                  ? null
                  : unit.parentOrgUnitId,
            ),
      ],
      locations: <({String locationId, String name, String? orgUnitId})>[
        for (final loc in widget.locationOptions)
          (
            locationId: loc.locationId,
            name: loc.name,
            orgUnitId: _isCorpRoot(loc.orgUnitId) ? null : loc.orgUnitId,
          ),
      ],
    );
    // Restore the operator's last pick if it is still valid.
    final last = _lastSelectedHierarchyNodeId;
    if (last != null && _hierarchyNodes.any((n) => n.id == last)) {
      _selectedHierarchyNodeId = last;
      _applyHierarchySelection(_hierarchyNodes.firstWhere((n) => n.id == last));
    }
  }

  /// `demo-org-root` is the synthetic corp node in the demo fixture
  /// that maps to the business root; treat it as the implicit parent
  /// so the tree's "Whole business" row replaces it.
  bool _isCorpRoot(String? orgUnitId) {
    if (orgUnitId == null) return false;
    for (final unit in widget.orgUnitOptions) {
      if (unit.orgUnitId == orgUnitId && unit.unitType == 'corp') return true;
    }
    return false;
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

  /// Translate a picked hierarchy node into the form's scope + scope-
  /// id pair. Mirrors the `TeamInviteFormController.setScope` rules:
  /// switching to operator-wide clears the location + org-unit ids;
  /// picking a location or region clears the other.
  void _applyHierarchySelection(HierarchyMapNode node) {
    _selectedHierarchyNodeId = node.id;
    _lastSelectedHierarchyNodeId = node.id;
    switch (node.kind) {
      case HierarchyMapNodeKind.business:
        _form.setScope(TeamInviteScope.operatorWide);
        break;
      case HierarchyMapNodeKind.orgUnit:
        _form.setScope(TeamInviteScope.orgUnit);
        // Node ids are prefixed by buildInviteHierarchyNodes so the
        // raw scope id is the suffix after the first colon.
        _form.setOrgUnitId(_idAfterPrefix(node.id, 'org_unit:'));
        break;
      case HierarchyMapNodeKind.location:
        _form.setScope(TeamInviteScope.location);
        _form.setLocationId(_idAfterPrefix(node.id, 'location:'));
        break;
    }
  }

  static String _idAfterPrefix(String value, String prefix) {
    if (value.startsWith(prefix)) return value.substring(prefix.length);
    return value;
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
      // Clear the cross-dialog hierarchy cache so the next invite
      // starts from a clean tree (the prior pick was specific to
      // this invitee and should not bleed across).
      _lastSelectedHierarchyNodeId = null;
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
    return OperatorWebDialog(
      key: const Key('invite_member_dialog'),
      title: 'Invite a team member',
      icon: Icons.person_add_alt_1_outlined,
      maxWidth: 500,
      actions: [
        TextButton(
          key: const Key('invite_member_dialog_cancel'),
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
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
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            IgnorePointer(
              ignoring: _submitting,
              child: HierarchyTreePicker(
                key: const Key('invite_member_dialog_location_field'),
                keyPrefix: 'invite_member_dialog_hierarchy',
                nodes: _hierarchyNodes,
                selectedId: _selectedHierarchyNodeId,
                onSelected: (node) {
                  setState(() {
                    _applyHierarchySelection(node);
                    // Clear the inline error once the operator picks
                    // a scope so they do not see a stale "Choose a
                    // primary location" hint after the fix.
                    if (_errorMessage ==
                        InviteMemberDialogCopy.locationMissing) {
                      _errorMessage = null;
                    }
                  });
                },
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                _errorMessage!,
                key: const Key('invite_member_dialog_error_text'),
                style: AppTextStyles.body13(color: AppColors.negative),
              ),
            ],
          ],
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
