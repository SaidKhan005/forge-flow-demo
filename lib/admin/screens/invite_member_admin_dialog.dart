// Phase 11A.12 - F&F admin invite-member dialog.
//
// Single-step invite form with the same field set + locked validation
// copy as the operator-web sibling (`11W.1`), plus an explicit
// `admin_reason` field that every admin-path mutation requires per
// the parity contract. Emits an [InviteMemberAdminDraft] on submit
// which the calling screen forwards to the gateway with a freshly
// minted idempotency key.

import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../operator_web/widgets/hierarchy_map_picker.dart';
import '../../operator_web/widgets/hierarchy_tree_picker.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../models/email_conflict_details.dart';
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
class MemberAccessScopeRef {
  const MemberAccessScopeRef({
    required this.scopeType,
    required this.id,
    required this.label,
    this.locationId,
    this.orgUnitId,
  });

  final String scopeType;
  final String id;
  final String label;
  final String? locationId;
  final String? orgUnitId;

  bool get isLocation => scopeType == 'location';
  bool get isOrgUnit => scopeType == 'org_unit';
  bool get isBusiness => scopeType == 'operator_wide';
}

@immutable
class InviteMemberAdminDraft {
  const InviteMemberAdminDraft({
    required this.email,
    required this.displayName,
    required this.roleKey,
    required this.primaryLocationId,
    required this.adminReason,
    this.scopeType = 'location',
    this.orgUnitId,
    this.welcomeNote,
  });

  final String email;
  final String displayName;
  final String roleKey;
  final String primaryLocationId;
  final String adminReason;
  final String scopeType;
  final String? orgUnitId;
  final String? welcomeNote;
}

class InviteMemberAdminDialog extends StatefulWidget {
  const InviteMemberAdminDialog({
    super.key,
    required this.operatorBusinessName,
    required this.locations,
    this.accessScopes = const <MemberAccessScopeRef>[],
    this.initialScope,
    this.existingEmails = const <String>{},
    this.existingEmailUsages = const <String, AdminEmailConflictUsage>{},
    this.onReviewExistingEmail,
  });

  final String operatorBusinessName;
  final List<MemberLocationRef> locations;
  final List<MemberAccessScopeRef> accessScopes;
  final MemberAccessScopeRef? initialScope;

  /// Lower-cased emails already on the team. Used by the dialog to
  /// surface the locked "email already on the team" copy without
  /// round-tripping the proxy.
  final Set<String> existingEmails;
  final Map<String, AdminEmailConflictUsage> existingEmailUsages;
  final ValueChanged<AdminEmailConflictUsage>? onReviewExistingEmail;

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
  late String? _scopeId =
      widget.initialScope?.id ??
      (widget.accessScopes.isEmpty ? null : widget.accessScopes.first.id);
  String? _violation;
  AdminEmailConflictUsage? _violationUsage;

  List<MemberAccessScopeRef> get _scopeOptions {
    if (widget.accessScopes.isNotEmpty) return widget.accessScopes;
    return <MemberAccessScopeRef>[
      for (final loc in widget.locations)
        MemberAccessScopeRef(
          scopeType: 'location',
          id: 'location:${loc.locationId}',
          label: loc.name,
          locationId: loc.locationId,
        ),
    ];
  }

  /// Project the admin scope catalog into the hierarchy-tree picker's
  /// node shape. Each [MemberAccessScopeRef] becomes one
  /// [HierarchyMapNode]; the picker uses the prefix on `id`
  /// (`operator_wide:` / `org_unit:` / `location:`) to derive parent
  /// links so the rendered tree mirrors Business → Region → Location.
  /// Location nodes parent under the first non-business scope when no
  /// explicit org-unit linkage exists (admin scope catalog is flat —
  /// callers can pass parented data in a follow-up live-wiring slice
  /// without breaking the picker's contract).
  List<HierarchyMapNode> _hierarchyNodes() {
    final scopes = _scopeOptions;
    if (scopes.isEmpty) return const <HierarchyMapNode>[];
    // Find the business root (operator_wide) so org-units + un-parented
    // locations can hang underneath it. If none is present (admin
    // surface filtered out the business scope) the tree renders the
    // org-units as roots and locations either parent under their
    // org-unit when known or hang as siblings of the org-units.
    String? businessRootId;
    for (final scope in scopes) {
      if (scope.isBusiness) {
        businessRootId = scope.id;
        break;
      }
    }
    return <HierarchyMapNode>[
      for (final scope in scopes)
        HierarchyMapNode(
          id: scope.id,
          label: scope.label,
          helper: scope.isBusiness
              ? 'Whole business'
              : scope.isOrgUnit
                  ? 'Region or group'
                  : 'Location',
          kind: scope.isBusiness
              ? HierarchyMapNodeKind.business
              : scope.isOrgUnit
                  ? HierarchyMapNodeKind.orgUnit
                  : HierarchyMapNodeKind.location,
          parentId: scope.isBusiness
              ? null
              : scope.isOrgUnit
                  // Admin catalog is flat; org-units hang directly under
                  // the business root for now. A follow-up live wiring
                  // slice can encode parent linkage on
                  // MemberAccessScopeRef without a picker change.
                  ? businessRootId
                  // Location nodes parent under their org-unit when one
                  // is encoded in the access-scope id pattern
                  // ("location:<locId>"); the admin catalog does not
                  // carry the org-unit linkage today, so locations sit
                  // under the business root alongside the regions. The
                  // operator still sees the location grouped beneath
                  // "Whole business" with the region nodes as peers,
                  // which is correct for the flat admin catalog.
                  : businessRootId,
          inheritanceBreadcrumb: scope.isBusiness
              ? 'Granting at this level covers every region and location.'
              : scope.isOrgUnit
                  ? 'Locations under this region inherit access granted here.'
                  : null,
        ),
    ];
  }

  @override
  void dispose() {
    _emailController.dispose();
    _displayNameController.dispose();
    _adminReasonController.dispose();
    _welcomeNoteController.dispose();
    super.dispose();
  }

  _InviteValidationIssue? _validate() {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      return const _InviteValidationIssue(MembersValidationCopy.emailEmpty);
    }
    if (!_looksLikeEmail(email)) {
      return const _InviteValidationIssue(MembersValidationCopy.emailMalformed);
    }
    final duplicate = _duplicateUsageFor(email);
    if (duplicate != null) {
      return _InviteValidationIssue(
        MembersValidationCopy.emailDuplicate,
        usage: duplicate,
      );
    }
    final role = _roleKey;
    if (role == null || role.isEmpty) {
      return const _InviteValidationIssue(MembersValidationCopy.roleMissing);
    }
    final scope = _selectedScope;
    if (scope == null) {
      return const _InviteValidationIssue(
        MembersValidationCopy.locationMissing,
      );
    }
    if (_displayNameController.text.trim().isEmpty) {
      return const _InviteValidationIssue('Display name is required.');
    }
    if (_adminReasonController.text.trim().isEmpty) {
      // Admin-path-only validation; the operator self-service
      // sibling (`11W.1`) does not surface this field at all because
      // self-service writes don't carry `admin_reason`. Plain-
      // English copy mirrors the in-screen reason dialog so the
      // operator-facing audit log reads consistently.
      return const _InviteValidationIssue(
        'Add a reason before sending the invite.',
      );
    }
    return null;
  }

  MemberAccessScopeRef? get _selectedScope {
    final scopeId = _scopeId;
    if (scopeId == null) return null;
    for (final scope in _scopeOptions) {
      if (scope.id == scopeId) return scope;
    }
    return null;
  }

  AdminEmailConflictUsage? _duplicateUsageFor(String email) {
    final key = email.toLowerCase();
    final usage = widget.existingEmailUsages[key];
    if (usage != null) return usage;
    if (!widget.existingEmails.contains(key)) return null;
    return AdminEmailConflictUsage(email: email, source: 'team_member');
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
      setState(() {
        _violation = violation.message;
        _violationUsage = violation.usage;
      });
      return;
    }
    final welcome = _welcomeNoteController.text.trim();
    final scope = _selectedScope!;
    Navigator.of(context).pop(
      InviteMemberAdminDraft(
        email: _emailController.text.trim(),
        displayName: _displayNameController.text.trim(),
        roleKey: _roleKey!,
        primaryLocationId: scope.locationId ?? '',
        scopeType: scope.scopeType,
        orgUnitId: scope.orgUnitId,
        adminReason: _adminReasonController.text.trim(),
        welcomeNote: welcome.isEmpty ? null : welcome,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_members_invite_dialog'),
      title: 'Invite a team member',
      icon: Icons.person_add_alt_1_outlined,
      maxWidth: 520,
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
      child: Flexible(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // Operator-web parity (invite_member_dialog.dart): the intro
              // line is copied verbatim so the admin invite dialog opens with
              // the same plain-English framing as the operator self-service
              // dialog.
              Text(
                'Send an email invite. The new teammate will set their own '
                'password and turn on two-factor sign-in before they get to '
                'your dashboard.',
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 14),
              if (_violation != null) ...[
                _ValidationBanner(
                  message: _violation!,
                  usage: _violationUsage,
                  onReview:
                      _violationUsage == null ||
                          widget.onReviewExistingEmail == null
                      ? null
                      : () {
                          widget.onReviewExistingEmail?.call(_violationUsage!);
                          Navigator.of(context).pop();
                        },
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const Key('admin_members_invite_email'),
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  hintText: 'jordan.lee@example.com',
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
              HierarchyTreePicker(
                key: const Key('admin_members_invite_location'),
                keyPrefix: 'admin_members_invite_scope',
                nodes: _hierarchyNodes(),
                selectedId: _scopeId,
                onSelected: (node) => setState(() => _scopeId = node.id),
                label: 'Choose where this person will work',
                helper:
                    'Pick the location, region, or whole business. Higher '
                    'levels include everything beneath.',
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
    );
  }
}

class _InviteValidationIssue {
  const _InviteValidationIssue(this.message, {this.usage});

  final String message;
  final AdminEmailConflictUsage? usage;
}

class _ValidationBanner extends StatelessWidget {
  const _ValidationBanner({required this.message, this.usage, this.onReview});

  final String message;
  final AdminEmailConflictUsage? usage;
  final VoidCallback? onReview;

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: AppTextStyles.body13(color: AppColors.negative)),
          if (usage != null) ...[
            const SizedBox(height: 8),
            _EmailConflictSummary(usage: usage!),
            if (onReview != null) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                key: const Key('admin_members_invite_show_existing_email'),
                onPressed: onReview,
                icon: const Icon(Icons.manage_search, size: 16),
                label: const Text('Show where it is used'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _EmailConflictSummary extends StatelessWidget {
  const _EmailConflictSummary({required this.usage});

  final AdminEmailConflictUsage usage;

  @override
  Widget build(BuildContext context) {
    final details = <String>[
      usage.sourceLabel,
      if (usage.roleLabel != null) usage.roleLabel!,
      if (usage.status != null) usage.status!,
    ].join(' | ');
    return Container(
      key: const Key('admin_members_invite_existing_email_details'),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            usage.scopeLabel,
            style: AppTextStyles.body13(
              color: AppColors.textPrimary,
            ).copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Text(
            details,
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
