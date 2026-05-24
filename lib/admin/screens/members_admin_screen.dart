// Phase 11A.12 - F&F Operations Console "Members" surface.
//
// Cross-operator members + invites table for the admin console.
// Mirrors the operator-web sibling (`11W.1`) parity surface: same
// filter set (status / role / location / mfa_enrolled / search),
// same locked validation copy on the invite dialog, same per-row
// actions (Suspend / Reactivate / Soft delete / Reset password /
// Reset MFA / Force logout). The admin path adds two affordances
// the operator self-service surface does NOT expose:
//
//   * Restore soft-deleted - resurrects a soft-deleted member.
//   * Override role grant - reassigns a member's role bypassing the
//     normal `team.roles.assign` workflow.
//
// Both admin-only actions land on the proxy `/v1/admin/auth/*`
// path with `actor_kind = forge_admin` and a non-empty
// `admin_reason`. Operator self-service (`11W.1`) does NOT expose
// either action; the parity contract pins the asymmetry.
//
// The screen mounts in the admin shell at `/admin/members`. The shell
// passes the shared Operations operator context when one exists; the
// picker is only opened when the admin needs to choose or change
// operator.
//
// Authority: docs/contracts/team_roles_hierarchy_console_parity_contract.md
// "§ Members + Invites (11W.1 + 11A.12)" + "§ Operator self-service
// vs F&F admin path" + "§ Idempotency keys" + "§ Audit-row shape".

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_screen_body.dart';
import 'package:forge_and_flow/widgets/console/console_screen_header.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../theme/app_theme.dart';
import '../../theme/scope_icons.dart';
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../models/email_conflict_details.dart';
import '../services/members_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_business_accounts_back_button.dart';
import 'invite_member_admin_dialog.dart';
import 'operator_picker_screen.dart';
import 'roles_hierarchy_sessions_admin_screen.dart';

class MembersAdminScreen extends StatefulWidget {
  const MembersAdminScreen({
    super.key,
    required this.gateway,
    required this.actorUserId,
    required this.pickedOperator,
    this.editingEnabled = true,
    this.idempotencyKeyFactory,
    this.onChangeOperator,
    this.onOpenAccess,
    this.rolesGateway,
    this.canEditSeededRoles = false,
    this.initialScope,
    this.onBackToBusinessAccounts,
  });

  final MembersAdminGateway gateway;
  final String actorUserId;

  /// Operator the F&F admin picked before landing on this surface.
  /// Carries operatorId + locationId(s) the screen needs to render
  /// the members table and the invite dialog's location dropdown.
  final OperatorPickerResult pickedOperator;

  /// Mirror of the .C admin pattern: when false, every mutate
  /// affordance is hidden. The gateway also throws
  /// [MembersAdminForbiddenException] if a non-forge-admin call
  /// reaches the seam, so this is the user-facing layer of a two-
  /// layer defence.
  final bool editingEnabled;

  /// Mints idempotency keys per user action. Production binds a
  /// timestamp-counter; tests pin a deterministic factory so the
  /// retried-mutation assertions are reproducible.
  final String Function()? idempotencyKeyFactory;

  /// Re-opens the operator picker. Wired by the route shell so the
  /// admin can switch operators without leaving the surface. The
  /// affordance is rendered inline in the page header (no overlay).
  final VoidCallback? onChangeOperator;

  /// Opens the scoped role policy / hierarchy / sessions surface for
  /// the same business. This keeps role work reachable from Team.
  final VoidCallback? onOpenAccess;
  final RolesHierarchySessionsAdminGateway? rolesGateway;
  final bool canEditSeededRoles;
  final AdminHierarchyScopeIntent? initialScope;
  final VoidCallback? onBackToBusinessAccounts;

  @override
  State<MembersAdminScreen> createState() => _MembersAdminScreenState();
}

class _MembersAdminScreenState extends State<MembersAdminScreen> {
  bool _loading = true;
  String? _loadError;
  String? _actionError;
  List<AdminEmailConflictUsage> _actionEmailConflicts =
      const <AdminEmailConflictUsage>[];
  List<MemberAdminRow> _members = const <MemberAdminRow>[];
  List<MemberInviteRow> _invites = const <MemberInviteRow>[];
  List<RoleAdminRow> _roles = const <RoleAdminRow>[];
  List<OrgUnitAdminNode> _orgUnits = const <OrgUnitAdminNode>[];
  List<HierarchyLocationLeaf> _hierarchyLocations =
      const <HierarchyLocationLeaf>[];
  // Wave 2 W-2 — Cancel pending invite. Per-invite busy set so a
  // retried Cancel during an in-flight DELETE does not double-dispatch.
  final Set<String> _busyInviteIds = <String>{};
  Timer? _searchDebounce;
  int _refreshGeneration = 0;

  // Filter state. Mirrors the parity-contract filter set verbatim.
  MemberStatus? _statusFilter;
  String? _roleFilter;
  String? _locationFilter;
  bool? _mfaEnrolledFilter;
  String _searchQuery = '';

  int _idempotencyCounter = 0;

  String _nextIdempotencyKey(String operation) {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return '$operation-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final rolesGateway = widget.rolesGateway;
      final reads = <Future<Object>>[
        widget.gateway.listMembers(
          operatorId: widget.pickedOperator.operatorId,
          status: _statusFilter,
          roleKey: _roleFilter,
          locationId: _locationFilter,
          contextLocationId: widget.pickedOperator.locationId,
          mfaEnrolled: _mfaEnrolledFilter,
          search: _searchQuery,
        ),
        widget.gateway.listInvites(
          operatorId: widget.pickedOperator.operatorId,
          locationId: _locationFilter,
          contextLocationId: widget.pickedOperator.locationId,
        ),
        if (rolesGateway != null) ...<Future<Object>>[
          rolesGateway.listRoles(operatorId: widget.pickedOperator.operatorId),
          rolesGateway.listOrgUnits(
            operatorId: widget.pickedOperator.operatorId,
          ),
          rolesGateway.listHierarchyLocations(
            operatorId: widget.pickedOperator.operatorId,
          ),
        ],
      ];
      final results = await Future.wait<Object>(reads);
      if (generation != _refreshGeneration) return;
      final members = results[0] as List<MemberAdminRow>;
      final invites = results[1] as List<MemberInviteRow>;
      final roles = rolesGateway == null
          ? const <RoleAdminRow>[]
          : results[2] as List<RoleAdminRow>;
      final orgUnits = rolesGateway == null
          ? const <OrgUnitAdminNode>[]
          : results[3] as List<OrgUnitAdminNode>;
      final hierarchyLocations = rolesGateway == null
          ? const <HierarchyLocationLeaf>[]
          : results[4] as List<HierarchyLocationLeaf>;
      final visibleMembers = _applyLocalFilters(
        members,
        hierarchyLocations: hierarchyLocations,
      );
      final visibleInvites = _applyInviteScope(
        invites,
        hierarchyLocations: hierarchyLocations,
      );
      if (!mounted) return;
      setState(() {
        _members = visibleMembers;
        _invites = visibleInvites;
        _roles = roles;
        _orgUnits = orgUnits;
        _hierarchyLocations = hierarchyLocations;
        _loading = false;
      });
    } on MembersAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } on MembersAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load members: $error';
        _loading = false;
      });
    }
  }

  void _refreshAfterSearchPause() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _refresh();
    });
  }

  void _clearFilters() {
    setState(() {
      _statusFilter = null;
      _roleFilter = null;
      _locationFilter = null;
      _mfaEnrolledFilter = null;
      _searchQuery = '';
    });
    _refresh();
  }

  List<MemberAdminRow> _applyLocalFilters(
    List<MemberAdminRow> rows, {
    required List<HierarchyLocationLeaf> hierarchyLocations,
  }) {
    final query = _searchQuery.trim().toLowerCase();
    final roleFilter = _roleFilter;
    final locationFilter = _locationFilter;
    final scopeLocationIds = _locationIdsForHierarchyScope(hierarchyLocations);
    return rows
        .where((row) {
          if (!_memberMatchesHierarchyScope(row, scopeLocationIds)) {
            return false;
          }
          if (_statusFilter != null && row.status != _statusFilter) {
            return false;
          }
          if (roleFilter != null &&
              roleFilter.isNotEmpty &&
              !_roleMatches(row.roleKey, roleFilter)) {
            return false;
          }
          if (locationFilter != null &&
              locationFilter.isNotEmpty &&
              row.primaryLocationId != locationFilter) {
            return false;
          }
          if (_mfaEnrolledFilter != null &&
              row.mfaEnrolled != _mfaEnrolledFilter) {
            return false;
          }
          if (query.isNotEmpty && !_rowMatchesQuery(row, query)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  List<MemberInviteRow> _applyInviteScope(
    List<MemberInviteRow> rows, {
    required List<HierarchyLocationLeaf> hierarchyLocations,
  }) {
    final scopeLocationIds = _locationIdsForHierarchyScope(hierarchyLocations);
    return rows
        .where(
          (invite) => _inviteMatchesHierarchyScope(invite, scopeLocationIds),
        )
        .toList(growable: false);
  }

  Set<String> _locationIdsForHierarchyScope(
    List<HierarchyLocationLeaf> hierarchyLocations,
  ) {
    final scope = widget.initialScope;
    if (scope == null || !scope.isOrgUnitScope) return const <String>{};
    final orgUnitId = scope.orgUnitId;
    if (orgUnitId == null || orgUnitId.isEmpty) return const <String>{};
    return <String>{
      for (final location in hierarchyLocations)
        if (location.orgUnitId == orgUnitId) location.locationId,
    };
  }

  bool _memberMatchesHierarchyScope(
    MemberAdminRow row,
    Set<String> scopeLocationIds,
  ) {
    final scope = widget.initialScope;
    if (scope == null || scope.isBusinessScope) return true;
    if (scope.isLocationScope) {
      final locationId = scope.locationId;
      return row.primaryLocationId == locationId ||
          row.grants.any((grant) => grant.locationId == locationId);
    }
    final orgUnitId = scope.orgUnitId;
    return row.orgUnitId == orgUnitId ||
        row.grants.any((grant) => grant.orgUnitId == orgUnitId) ||
        scopeLocationIds.contains(row.primaryLocationId) ||
        row.grants.any((grant) => scopeLocationIds.contains(grant.locationId));
  }

  bool _inviteMatchesHierarchyScope(
    MemberInviteRow invite,
    Set<String> scopeLocationIds,
  ) {
    final scope = widget.initialScope;
    if (scope == null || scope.isBusinessScope) return true;
    if (scope.isLocationScope) {
      return invite.primaryLocationId == scope.locationId;
    }
    final orgUnitId = scope.orgUnitId;
    return invite.orgUnitId == orgUnitId ||
        scopeLocationIds.contains(invite.primaryLocationId);
  }

  bool _roleMatches(String rowRoleKey, String filterRoleKey) {
    final rowRaw = rowRoleKey.toLowerCase();
    final filterRaw = filterRoleKey.toLowerCase();
    if (rowRaw == filterRaw) return true;
    return memberRoleLabel(rowRoleKey).toLowerCase() ==
        memberRoleLabel(filterRoleKey).toLowerCase();
  }

  bool _rowMatchesQuery(MemberAdminRow row, String query) {
    final haystack = <String>[
      row.email,
      row.displayName,
      row.roleKey,
      memberRoleLabel(row.roleKey),
      row.primaryLocationName,
      row.status.wire,
    ].join(' ').toLowerCase();
    return haystack.contains(query);
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() {
      _actionError = null;
      _actionEmailConflicts = const <AdminEmailConflictUsage>[];
    });
    try {
      await action();
      await _refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on MembersAdminForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } on MembersAdminGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _actionError = error.message;
        _actionEmailConflicts = AdminEmailConflictUsage.listFromDetails(
          error.details,
        );
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    }
  }

  Future<String?> _promptAdminReason(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _AdminReasonDialog(title: title),
    );
  }

  Future<void> _onSuspend(MemberAdminRow row) async {
    final reason = await _promptAdminReason('Suspend ${row.displayName}');
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.suspendMember(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-suspend'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Suspended ${row.displayName}',
    );
  }

  Future<void> _onReactivate(MemberAdminRow row) async {
    final reason = await _promptAdminReason('Reactivate ${row.displayName}');
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.reactivateMember(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-reactivate'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Reactivated ${row.displayName}',
    );
  }

  Future<void> _onSoftDelete(MemberAdminRow row) async {
    final reason = await _promptAdminReason('Soft delete ${row.displayName}');
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.softDeleteMember(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-soft-delete'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Soft-deleted ${row.displayName}',
    );
  }

  Future<void> _onResetPassword(MemberAdminRow row) async {
    final reason = await _promptAdminReason(
      'Reset password for ${row.displayName}',
    );
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.resetPassword(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-reset-password'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Sent ${row.displayName} a password-reset email.',
    );
  }

  Future<void> _onResetMfa(MemberAdminRow row) async {
    final reason = await _promptAdminReason(
      'Reset two-factor sign-in for ${row.displayName}',
    );
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.resetMfa(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-reset-mfa'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint:
          "${row.displayName}'s two-factor sign-in will be removed in 24 "
          'hours unless cancelled.',
    );
  }

  Future<void> _onForceLogout(MemberAdminRow row) async {
    final reason = await _promptAdminReason('Force logout ${row.displayName}');
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.forceLogout(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-force-logout'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: '${row.displayName} has been signed out of every device.',
    );
  }

  Future<void> _onEditDisplayName(MemberAdminRow row) async {
    // Wave 2 W-1 — Members edit-user write path. The dialog covers
    // both display name and email; the admin gateway's
    // [HttpMembersAdminGateway.updateMember] PATCHes through the
    // existing `/v1/admin/auth/users/{id}` route which the proxy
    // fans out to Firebase Identity Platform + Postgres + audit log.
    final result = await showDialog<_DisplayNameEditResult>(
      context: context,
      builder: (_) => _DisplayNameEditDialog(row: row),
    );
    if (result == null) return;
    final emailChanged = result.email != null &&
        result.email!.trim().toLowerCase() != row.email.toLowerCase();
    final displayNameChanged =
        result.displayName.trim() != row.displayName.trim();
    if (!emailChanged && !displayNameChanged) return;
    await _runAndRefresh(
      () => widget.gateway.updateMember(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-edit'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
        email: emailChanged ? result.email : null,
        displayName: displayNameChanged ? result.displayName : null,
      ),
      successHint: 'Updated ${row.email}.',
    );
  }

  Future<void> _onRestoreSoftDeleted(MemberAdminRow row) async {
    final reason = await _promptAdminReason('Restore ${row.displayName}');
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.restoreSoftDeletedMember(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-restore'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Restored ${row.displayName}',
    );
  }

  Future<void> _onOverrideRoleGrant(MemberAdminRow row) async {
    final result = await showDialog<_OverrideRoleResult>(
      context: context,
      builder: (_) => _OverrideRoleDialog(
        currentRoleKey: row.roleKey,
        targetDisplayName: row.displayName,
        roles: _roles,
        accessScopes: _availableAccessScopes,
        initialScope: _initialGrantScope(row),
      ),
    );
    if (result == null) return;
    await _runAndRefresh(
      () => widget.gateway.overrideRoleGrant(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        roleId: result.roleId,
        roleKey: result.roleKey,
        idempotencyKey: _nextIdempotencyKey('member-override-role'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
        scopeType: result.scope.scopeType,
        primaryLocationId: result.scope.locationId,
        orgUnitId: result.scope.orgUnitId,
      ),
      successHint:
          'Reassigned ${row.displayName} to ${memberRoleLabel(result.roleKey)}',
    );
  }

  Future<void> _onEditSeededRole(RoleAdminRow row) async {
    if (!widget.canEditSeededRoles) return;
    final rolesGateway = widget.rolesGateway;
    if (rolesGateway == null) return;
    final result = await showDialog<EditSeededRoleResult>(
      context: context,
      builder: (_) => EditSeededRoleDialog(initial: row),
    );
    if (result == null) return;
    await _runAndRefresh(() async {
      await rolesGateway.editSeededRole(
        operatorId: widget.pickedOperator.operatorId,
        roleId: row.roleId,
        permissionKeys: result.permissionKeys,
        idempotencyKey: _nextIdempotencyKey('roles-edit-seeded'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      );
    }, successHint: 'Updated ${roleAdminDisplayLabel(row)}');
  }

  Future<void> _onCreateCustomRole() async {
    final rolesGateway = widget.rolesGateway;
    if (rolesGateway == null) return;
    final result = await showDialog<CustomRoleDraft>(
      context: context,
      builder: (_) => CreateCustomRoleDialog(
        existingRoleKeys: <String>{for (final r in _roles) r.roleKey},
      ),
    );
    if (result == null) return;
    await _runAndRefresh(() async {
      await rolesGateway.createCustomRole(
        operatorId: widget.pickedOperator.operatorId,
        roleKey: result.roleKey,
        displayName: result.displayName,
        description: result.description,
        permissionKeys: result.permissionKeys,
        idempotencyKey: _nextIdempotencyKey('roles-create-custom'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      );
    }, successHint: 'Created ${result.displayName}');
  }

  Future<void> _onDeleteCustomRole(RoleAdminRow row) async {
    final rolesGateway = widget.rolesGateway;
    if (rolesGateway == null) return;
    final reason = await _promptAdminReason(
      'Delete ${roleAdminDisplayLabel(row)}',
    );
    if (reason == null) return;
    await _runAndRefresh(
      () => rolesGateway.deleteCustomRole(
        operatorId: widget.pickedOperator.operatorId,
        roleId: row.roleId,
        idempotencyKey: _nextIdempotencyKey('roles-delete-custom'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Deleted ${roleAdminDisplayLabel(row)}',
    );
  }

  MemberAccessScopeRef? _initialGrantScope(MemberAdminRow row) {
    final grant = row.grants.isEmpty ? null : row.grants.first;
    if (grant == null) {
      return MemberAccessScopeRef(
        scopeType: 'location',
        id: 'location:${row.primaryLocationId}',
        label: 'Location / ${row.primaryLocationName}',
        locationId: row.primaryLocationId,
      );
    }
    final scopeId = switch (grant.scopeType) {
      'operator_wide' => 'operator_wide:${widget.pickedOperator.operatorId}',
      'org_unit' => 'org_unit:${grant.orgUnitId ?? row.orgUnitId ?? ''}',
      'location' => 'location:${grant.locationId ?? row.primaryLocationId}',
      _ => 'location:${row.primaryLocationId}',
    };
    for (final scope in _availableAccessScopes) {
      if (scope.id == scopeId) return scope;
    }
    return null;
  }

  MemberAccessScopeRef? _initialInviteScope() {
    final scope = widget.initialScope;
    if (scope == null) return null;
    final scopeId = switch (scope.scopeType) {
      AdminHierarchyScopeType.business =>
        'operator_wide:${widget.pickedOperator.operatorId}',
      AdminHierarchyScopeType.orgUnit => 'org_unit:${scope.orgUnitId ?? ''}',
      AdminHierarchyScopeType.location => 'location:${scope.locationId ?? ''}',
    };
    for (final ref in _availableAccessScopes) {
      if (ref.id == scopeId) return ref;
    }
    return null;
  }

  Future<void> _onInvite() async {
    if (!widget.editingEnabled) return;
    final existing = <String>{
      for (final m in _members) m.email.toLowerCase(),
      for (final i in _invites) i.email.toLowerCase(),
    };
    final existingUsages = <String, AdminEmailConflictUsage>{
      for (final m in _members)
        m.email.toLowerCase(): AdminEmailConflictUsage(
          email: m.email,
          userId: m.userId,
          operatorId: widget.pickedOperator.operatorId,
          operatorName: widget.pickedOperator.operatorBusinessName,
          locationId: m.primaryLocationId,
          locationName: m.primaryLocationName,
          status: memberStatusLabel(m.status),
          roleLabel: memberRoleLabel(m.roleKey),
          source: 'team_member',
        ),
      for (final i in _invites)
        i.email.toLowerCase(): AdminEmailConflictUsage(
          email: i.email,
          operatorId: widget.pickedOperator.operatorId,
          operatorName: widget.pickedOperator.operatorBusinessName,
          locationId: i.primaryLocationId,
          locationName: i.primaryLocationName,
          orgUnitId: i.orgUnitId,
          orgUnitName: i.orgUnitName,
          status: 'Pending invite',
          roleLabel: memberRoleLabel(i.roleKey),
          source: 'pending_invite',
        ),
    };
    final draft = await showDialog<InviteMemberAdminDraft>(
      context: context,
      builder: (_) => InviteMemberAdminDialog(
        operatorBusinessName: widget.pickedOperator.operatorBusinessName,
        locations: _availableLocations,
        accessScopes: _availableAccessScopes,
        initialScope: _initialInviteScope(),
        existingEmails: existing,
        existingEmailUsages: existingUsages,
        onReviewExistingEmail: _showEmailUsage,
      ),
    );
    if (draft == null) return;
    await _runAndRefresh(
      () => widget.gateway.createInvite(
        operatorId: widget.pickedOperator.operatorId,
        email: draft.email,
        displayName: draft.displayName,
        roleKey: draft.roleKey,
        primaryLocationId: draft.primaryLocationId,
        scopeType: draft.scopeType,
        orgUnitId: draft.orgUnitId,
        idempotencyKey: _nextIdempotencyKey('member-invite'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: draft.adminReason,
        welcomeNote: draft.welcomeNote,
      ),
      successHint: 'Invite sent to ${draft.email}',
    );
  }

  Future<void> _onCancelInvite(MemberInviteRow invite) async {
    // Wave 2 W-2 — Cancel pending invite end-to-end.
    //
    // Confirm-then-reason flow mirrors the existing destructive
    // admin actions (suspend / soft-delete): the operator confirms
    // the destructive intent first, then writes a short audit
    // reason. The proxy DELETE call fans out to Firebase Identity
    // Platform + Postgres `auth_invites.revoked_at` + shadow user
    // soft-delete + audit row under the operator-bound
    // `team.users.invite` permission gate.
    if (!widget.editingEnabled) return;
    if (_busyInviteIds.contains(invite.inviteId)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('admin_members_cancel_invite_confirm'),
        backgroundColor: AppColors.backgroundSurface,
        title: Text(
          'Cancel invite',
          style: AdminButtonStyles.dialogTitleStyle,
        ),
        content: Text(
          'Cancel the pending invite for ${invite.email}? Their link will '
          'stop working. You can send a new invite later if they still '
          'need access.',
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('admin_members_cancel_invite_keep'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep invite'),
          ),
          FilledButton(
            key: const Key('admin_members_cancel_invite_confirm_button'),
            style: AdminButtonStyles.primary,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Cancel invite'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final reason = await _promptAdminReason('Cancel invite for ${invite.email}');
    if (reason == null) return;
    setState(() => _busyInviteIds.add(invite.inviteId));
    try {
      await _runAndRefresh(
        () => widget.gateway.cancelInvite(
          operatorId: widget.pickedOperator.operatorId,
          inviteId: invite.inviteId,
          idempotencyKey: _nextIdempotencyKey('member-invite-cancel'),
          actorUserId: widget.actorUserId,
          actorIsForgeAdmin: widget.editingEnabled,
          adminReason: reason,
          reason: reason,
        ),
        successHint: 'Invite for ${invite.email} cancelled.',
      );
    } finally {
      if (mounted) setState(() => _busyInviteIds.remove(invite.inviteId));
    }
  }

  void _showEmailUsage(AdminEmailConflictUsage usage) {
    setState(() {
      _statusFilter = null;
      _roleFilter = null;
      _locationFilter =
          usage.operatorId == null ||
              usage.operatorId == widget.pickedOperator.operatorId
          ? usage.locationId
          : null;
      _mfaEnrolledFilter = null;
      _searchQuery = usage.email;
      _actionError = null;
      _actionEmailConflicts = const <AdminEmailConflictUsage>[];
    });
    _refresh();
  }

  List<MemberLocationRef> get _availableLocations {
    final byId = <String, MemberLocationRef>{};
    if (widget.pickedOperator.locationId.isNotEmpty) {
      byId[widget.pickedOperator.locationId] = MemberLocationRef(
        locationId: widget.pickedOperator.locationId,
        name: widget.pickedOperator.locationName,
      );
    }
    for (final loc in _hierarchyLocations) {
      byId.putIfAbsent(
        loc.locationId,
        () => MemberLocationRef(locationId: loc.locationId, name: loc.name),
      );
    }
    for (final m in _members) {
      byId.putIfAbsent(
        m.primaryLocationId,
        () => MemberLocationRef(
          locationId: m.primaryLocationId,
          name: m.primaryLocationName,
        ),
      );
    }
    for (final i in _invites) {
      byId.putIfAbsent(
        i.primaryLocationId,
        () => MemberLocationRef(
          locationId: i.primaryLocationId,
          name: i.primaryLocationName,
        ),
      );
    }
    return byId.values.toList(growable: false);
  }

  List<MemberAccessScopeRef> get _availableAccessScopes {
    final scopes = <MemberAccessScopeRef>[
      MemberAccessScopeRef(
        scopeType: 'operator_wide',
        id: 'operator_wide:${widget.pickedOperator.operatorId}',
        label: 'Business / ${widget.pickedOperator.operatorBusinessName}',
      ),
      for (final orgUnit in _orgUnits)
        MemberAccessScopeRef(
          scopeType: 'org_unit',
          id: 'org_unit:${orgUnit.orgUnitId}',
          label: 'Org unit / ${orgUnit.name}',
          orgUnitId: orgUnit.orgUnitId,
        ),
      for (final location in _availableLocations)
        MemberAccessScopeRef(
          scopeType: 'location',
          id: 'location:${location.locationId}',
          label: location.name,
          locationId: location.locationId,
        ),
    ];
    return scopes;
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebScreenBody(
      scrollKey: const Key('admin_members_screen'),
      maxContentWidth: 1120,
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OperatorWebScreenHeader(
            icon: Icons.group_outlined,
            title: 'Team members',
            actions: _buildHeaderActions(),
          ),
          const SizedBox(height: 14),
          if (!widget.editingEnabled)
            const _ReadOnlyBanner(key: Key('admin_members_readonly_banner')),
          if (_actionError != null)
            _ErrorBanner(
              key: const Key('admin_members_action_error'),
              message: _actionError!,
              emailConflicts: _actionEmailConflicts,
              currentOperatorId: widget.pickedOperator.operatorId,
              onShowConflict: _showEmailUsage,
              onChangeOperator: widget.onChangeOperator,
            ),
          _PeopleAccessScopeCard(
            pickedOperator: widget.pickedOperator,
            initialScope: widget.initialScope,
            accessScopes: _availableAccessScopes,
          ),
          const SizedBox(height: 12),
          _MembersFilterBar(
            statusFilter: _statusFilter,
            roleFilter: _roleFilter,
            locationFilter: _locationFilter,
            mfaEnrolledFilter: _mfaEnrolledFilter,
            searchQuery: _searchQuery,
            locations: _availableLocations,
            onStatusChanged: (v) {
              setState(() => _statusFilter = v);
              _refresh();
            },
            onRoleChanged: (v) {
              setState(() => _roleFilter = v);
              _refresh();
            },
            onLocationChanged: (v) {
              setState(() => _locationFilter = v);
              _refresh();
            },
            onMfaEnrolledChanged: (v) {
              setState(() => _mfaEnrolledFilter = v);
              _refresh();
            },
            onSearchChanged: (v) {
              setState(() => _searchQuery = v);
              _refreshAfterSearchPause();
            },
            onClearFilters: _clearFilters,
          ),
          const SizedBox(height: 12),
          _buildBody(),
        ],
      ),
    );
  }

  List<Widget> _buildHeaderActions() {
    final children = <Widget>[];
    if (widget.onBackToBusinessAccounts != null) {
      children.add(
        AdminBusinessAccountsBackButton(
          onPressed: widget.onBackToBusinessAccounts,
        ),
      );
    }
    if (widget.onChangeOperator != null) {
      children.add(
        OutlinedButton.icon(
          key: const Key('admin_members_change_operator'),
          onPressed: widget.onChangeOperator,
          style: AdminButtonStyles.secondary(),
          icon: const Icon(Icons.swap_horiz, size: 16),
          label: const Text('Change operator'),
        ),
      );
    }
    if (widget.onOpenAccess != null) {
      children.add(
        OutlinedButton.icon(
          key: const Key('admin_members_open_access'),
          onPressed: widget.onOpenAccess,
          style: AdminButtonStyles.secondary(),
          icon: const Icon(Icons.shield_outlined, size: 16),
          label: const Text('Role policy'),
        ),
      );
    }
    if (widget.editingEnabled) {
      children.add(
        FilledButton.icon(
          key: const Key('admin_members_invite_button'),
          onPressed: _onInvite,
          style: AdminButtonStyles.primary,
          icon: const Icon(Icons.person_add_alt_1, size: 16),
          label: const Text('Invite member'),
        ),
      );
    }
    return children;
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        key: Key('admin_members_loading'),
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (_loadError != null) {
      return _ErrorBanner(
        key: const Key('admin_members_load_error'),
        message: _loadError!,
      );
    }
    // Outer frame is OperatorWebScreenBody (a SingleChildScrollView), so
    // this body returns a plain Column to avoid nesting a second scroll
    // view inside it.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _MembersTable(
          rows: _members,
          editingEnabled: widget.editingEnabled,
          onSuspend: _onSuspend,
          onReactivate: _onReactivate,
          onSoftDelete: _onSoftDelete,
          onResetPassword: _onResetPassword,
          onResetMfa: _onResetMfa,
          onForceLogout: _onForceLogout,
          onEditDisplayName: _onEditDisplayName,
          onRestoreSoftDeleted: _onRestoreSoftDeleted,
          onOverrideRoleGrant: _onOverrideRoleGrant,
        ),
        const SizedBox(height: 16),
        _InvitesPanel(
          invites: _invites,
          editingEnabled: widget.editingEnabled,
          busyInviteIds: _busyInviteIds,
          onCancel: _onCancelInvite,
        ),
        if (widget.rolesGateway != null) ...<Widget>[
          const SizedBox(height: 16),
          RolePolicyAdminPanel(
            roles: _roles,
            editingEnabled: widget.editingEnabled,
            canEditSeededRoles: widget.canEditSeededRoles,
            onEditSeeded: _onEditSeededRole,
            onCreateCustom: _onCreateCustomRole,
            onDeleteCustom: _onDeleteCustomRole,
          ),
        ],
      ],
    );
  }
}

class _PeopleAccessScopeCard extends StatelessWidget {
  const _PeopleAccessScopeCard({
    required this.pickedOperator,
    required this.accessScopes,
    this.initialScope,
  });

  final OperatorPickerResult pickedOperator;
  final List<MemberAccessScopeRef> accessScopes;
  final AdminHierarchyScopeIntent? initialScope;

  @override
  Widget build(BuildContext context) {
    final scope = initialScope;
    final scopeLabel = _selectedScopeLabel(scope);
    final scopeDisplay =
        scope?.displayLabel ?? pickedOperator.operatorBusinessName;
    return OperatorWebPanel(
      key: const Key('admin_people_access_scope_card'),
      title: 'People, access, and roles',
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _ScopePill(
            icon: scopeIcon(kind: ScopeEntityKind.business),
            label: pickedOperator.operatorBusinessName,
          ),
          _ScopePill(icon: Icons.tune_outlined, label: scopeLabel),
          _ScopePill(icon: Icons.account_tree_outlined, label: scopeDisplay),
          _ScopePill(
            icon: Icons.lock_open_outlined,
            label: '${accessScopes.length} grant scopes',
          ),
          Text(
            'Invites and role grants can target business, org-unit, or location scopes.',
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

String _selectedScopeLabel(AdminHierarchyScopeIntent? scope) {
  switch (scope?.scopeType ?? AdminHierarchyScopeType.business) {
    case AdminHierarchyScopeType.business:
      return 'Selected business scope';
    case AdminHierarchyScopeType.orgUnit:
      return 'Selected org unit scope';
    case AdminHierarchyScopeType.location:
      return 'Selected location scope';
  }
}

class _ScopePill extends StatelessWidget {
  const _ScopePill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: AppColors.textMuted),
          const SizedBox(width: 4),
          Text(
            label,
            style: AppTextStyles.mono11(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Filter bar is Stateful so the search field's [TextEditingController]
/// has a stable identity across parent rebuilds. The previous
/// stateless implementation re-created the controller on every parent
/// `setState` (which fires on every keystroke, since `onSearchChanged`
/// triggers `_refresh`), which collapsed the cursor mid-typing and
/// broke IME composition. The controller now lives in `State` and is
/// disposed in `dispose`.
class _MembersFilterBar extends StatefulWidget {
  const _MembersFilterBar({
    required this.statusFilter,
    required this.roleFilter,
    required this.locationFilter,
    required this.mfaEnrolledFilter,
    required this.searchQuery,
    required this.locations,
    required this.onStatusChanged,
    required this.onRoleChanged,
    required this.onLocationChanged,
    required this.onMfaEnrolledChanged,
    required this.onSearchChanged,
    required this.onClearFilters,
  });

  final MemberStatus? statusFilter;
  final String? roleFilter;
  final String? locationFilter;
  final bool? mfaEnrolledFilter;
  final String searchQuery;
  final List<MemberLocationRef> locations;
  final ValueChanged<MemberStatus?> onStatusChanged;
  final ValueChanged<String?> onRoleChanged;
  final ValueChanged<String?> onLocationChanged;
  final ValueChanged<bool?> onMfaEnrolledChanged;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearFilters;

  @override
  State<_MembersFilterBar> createState() => _MembersFilterBarState();
}

class _MembersFilterBarState extends State<_MembersFilterBar> {
  late final TextEditingController _searchController = TextEditingController(
    text: widget.searchQuery,
  );

  @override
  void didUpdateWidget(covariant _MembersFilterBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Keep the controller's text in sync if the parent reassigns
    // searchQuery from outside (e.g., a "Clear filters" button).
    // Skip the assignment when the parent's value already matches —
    // assigning the same text resets selection to (0, 0) and
    // breaks the cursor for the user mid-typing.
    if (widget.searchQuery != _searchController.text) {
      _searchController.text = widget.searchQuery;
      _searchController.selection = TextSelection.collapsed(
        offset: widget.searchQuery.length,
      );
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeFilters = <String>[
      if (widget.statusFilter != null) 'Status',
      if (widget.roleFilter != null) 'Role',
      if (widget.locationFilter != null) 'Location',
      if (widget.mfaEnrolledFilter != null) 'MFA',
      if (widget.searchQuery.trim().isNotEmpty) 'Search',
    ];
    // Web parity (members_screen.dart `_MembersFilterRail`): filters
    // render in a plain bordered surface with NO panel title, and the
    // admin-only "Clear filters" affordance sits inline as the last
    // child of the same Wrap.
    return Container(
      key: const Key('admin_members_filter_card'),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<MemberStatus?>(
                  key: const Key('admin_members_filter_status'),
                  initialValue: widget.statusFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Status',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<MemberStatus?>>[
                    const DropdownMenuItem<MemberStatus?>(
                      value: null,
                      child: Text('Any status'),
                    ),
                    for (final s in MemberStatus.values)
                      DropdownMenuItem<MemberStatus?>(
                        value: s,
                        child: Text(memberStatusLabel(s)),
                      ),
                  ],
                  onChanged: widget.onStatusChanged,
                ),
              ),
              SizedBox(
                width: 200,
                child: DropdownButtonFormField<String?>(
                  key: const Key('admin_members_filter_role'),
                  initialValue: widget.roleFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Role',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Any role'),
                    ),
                    for (final role in kSeededRoleKeysForAdmin)
                      DropdownMenuItem<String?>(
                        value: role,
                        child: Text(memberRoleLabel(role)),
                      ),
                  ],
                  onChanged: widget.onRoleChanged,
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String?>(
                  key: const Key('admin_members_filter_location'),
                  initialValue: widget.locationFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Location',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Any location'),
                    ),
                    for (final loc in widget.locations)
                      DropdownMenuItem<String?>(
                        value: loc.locationId,
                        child: Text(loc.name),
                      ),
                  ],
                  onChanged: widget.onLocationChanged,
                ),
              ),
              SizedBox(
                width: 180,
                child: DropdownButtonFormField<bool?>(
                  key: const Key('admin_members_filter_mfa'),
                  initialValue: widget.mfaEnrolledFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Two-factor sign-in',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: const <DropdownMenuItem<bool?>>[
                    DropdownMenuItem<bool?>(
                      value: null,
                      child: Text('Any'),
                    ),
                    DropdownMenuItem<bool?>(
                      value: true,
                      child: Text('On'),
                    ),
                    DropdownMenuItem<bool?>(
                      value: false,
                      child: Text('Off'),
                    ),
                  ],
                  onChanged: widget.onMfaEnrolledChanged,
                ),
              ),
              SizedBox(
                width: 240,
                child: TextField(
                  key: const Key('admin_members_filter_search'),
                  decoration: const InputDecoration(
                    labelText: 'Search by name or email',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: widget.onSearchChanged,
                  controller: _searchController,
                ),
              ),
              if (activeFilters.isNotEmpty)
                OutlinedButton.icon(
                  key: const Key('admin_members_clear_filters'),
                  onPressed: widget.onClearFilters,
                  style: AdminButtonStyles.secondary(
                    minWidth: 120,
                    minHeight: 40,
                  ),
                  icon: const Icon(Icons.filter_alt_off_outlined, size: 16),
                  label: const Text('Clear filters'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MembersTable extends StatelessWidget {
  const _MembersTable({
    required this.rows,
    required this.editingEnabled,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
    required this.onForceLogout,
    required this.onEditDisplayName,
    required this.onRestoreSoftDeleted,
    required this.onOverrideRoleGrant,
  });

  final List<MemberAdminRow> rows;
  final bool editingEnabled;
  final ValueChanged<MemberAdminRow> onSuspend;
  final ValueChanged<MemberAdminRow> onReactivate;
  final ValueChanged<MemberAdminRow> onSoftDelete;
  final ValueChanged<MemberAdminRow> onResetPassword;
  final ValueChanged<MemberAdminRow> onResetMfa;
  final ValueChanged<MemberAdminRow> onForceLogout;
  final ValueChanged<MemberAdminRow> onEditDisplayName;
  final ValueChanged<MemberAdminRow> onRestoreSoftDeleted;
  final ValueChanged<MemberAdminRow> onOverrideRoleGrant;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_members_table'),
      title: 'Members',
      trailing: Text(
        '${rows.length} row${rows.length == 1 ? '' : 's'}',
        style: AppTextStyles.mono11(color: AppColors.textMuted),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (rows.isEmpty)
            Container(
              key: const Key('admin_members_empty_state'),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.backgroundDeep,
                border: Border.all(color: AppColors.borderSubtle, width: 1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'No members match these filters',
                    style: AppTextStyles.mono14(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Try clearing a filter or use Invite member to add '
                    'someone new to the team.',
                    style: AppTextStyles.body13(color: AppColors.textSecondary),
                  ),
                ],
              ),
            )
          else
            for (final row in rows)
              _MemberRowTile(
                key: Key('admin_members_row_${row.userId}'),
                row: row,
                editingEnabled: editingEnabled,
                onSuspend: onSuspend,
                onReactivate: onReactivate,
                onSoftDelete: onSoftDelete,
                onResetPassword: onResetPassword,
                onResetMfa: onResetMfa,
                onForceLogout: onForceLogout,
                onEditDisplayName: onEditDisplayName,
                onRestoreSoftDeleted: onRestoreSoftDeleted,
                onOverrideRoleGrant: onOverrideRoleGrant,
              ),
        ],
      ),
    );
  }
}

class _MemberRowTile extends StatelessWidget {
  const _MemberRowTile({
    super.key,
    required this.row,
    required this.editingEnabled,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
    required this.onForceLogout,
    required this.onEditDisplayName,
    required this.onRestoreSoftDeleted,
    required this.onOverrideRoleGrant,
  });

  final MemberAdminRow row;
  final bool editingEnabled;
  final ValueChanged<MemberAdminRow> onSuspend;
  final ValueChanged<MemberAdminRow> onReactivate;
  final ValueChanged<MemberAdminRow> onSoftDelete;
  final ValueChanged<MemberAdminRow> onResetPassword;
  final ValueChanged<MemberAdminRow> onResetMfa;
  final ValueChanged<MemberAdminRow> onForceLogout;
  final ValueChanged<MemberAdminRow> onEditDisplayName;
  final ValueChanged<MemberAdminRow> onRestoreSoftDeleted;
  final ValueChanged<MemberAdminRow> onOverrideRoleGrant;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    row.displayName,
                    style: AppTextStyles.body14(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                _StatusChip(status: row.status),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              row.email,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: <Widget>[
                _MetaPill(
                  icon: Icons.shield_outlined,
                  label: memberRoleLabel(row.roleKey),
                ),
                _MetaPill(
                  icon: Icons.location_on_outlined,
                  label: row.primaryLocationName,
                ),
                _MetaPill(
                  icon: row.mfaEnrolled
                      ? Icons.verified_user_outlined
                      : Icons.gpp_maybe_outlined,
                  label: row.mfaEnrolled ? 'MFA on' : 'MFA off',
                ),
              ],
            ),
            if (row.grants.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: <Widget>[
                  for (final grant in row.grants) _GrantScopeChip(grant: grant),
                ],
              ),
            ],
            if (editingEnabled) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 6, runSpacing: 6, children: _buildActionButtons()),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _buildActionButtons() {
    final buttons = <Widget>[];
    buttons.add(
      _RowAction(
        keyValue: 'admin_members_action_edit_name_${row.userId}',
        label: 'Edit display name',
        onPressed: () => onEditDisplayName(row),
      ),
    );
    if (row.status == MemberStatus.active) {
      buttons.add(
        _RowAction(
          keyValue: 'admin_members_action_suspend_${row.userId}',
          label: 'Suspend',
          onPressed: () => onSuspend(row),
        ),
      );
      buttons.add(
        _RowAction(
          keyValue: 'admin_members_action_soft_delete_${row.userId}',
          label: 'Soft delete',
          onPressed: () => onSoftDelete(row),
        ),
      );
    }
    if (row.status == MemberStatus.suspended ||
        row.status == MemberStatus.dormant30) {
      buttons.add(
        _RowAction(
          keyValue: 'admin_members_action_reactivate_${row.userId}',
          label: 'Reactivate',
          onPressed: () => onReactivate(row),
        ),
      );
    }
    if (row.status == MemberStatus.softDeleted) {
      // Admin-only action. Operator self-service (11W.1) does NOT
      // expose Restore - the parity contract pins this asymmetry.
      buttons.add(
        _RowAction(
          keyValue: 'admin_members_action_restore_${row.userId}',
          label: 'Restore soft-deleted',
          onPressed: () => onRestoreSoftDeleted(row),
        ),
      );
    } else {
      // Admin-only action. Operator self-service (11W.1) routes role
      // changes through the normal `team.roles.assign` workflow; the
      // override path lives only on the admin surface.
      buttons.add(
        _RowAction(
          keyValue: 'admin_members_action_override_role_${row.userId}',
          label: 'Grant role',
          onPressed: () => onOverrideRoleGrant(row),
        ),
      );
    }
    return buttons;
  }
}

class _GrantScopeChip extends StatelessWidget {
  const _GrantScopeChip({required this.grant});

  final MemberRoleGrantRow grant;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${grant.roleDisplayLabel} / ${_grantScopeLabel(grant)}',
        style: AppTextStyles.mono11(color: AppColors.textSecondary),
      ),
    );
  }
}

String _grantScopeLabel(MemberRoleGrantRow grant) {
  switch (grant.scopeType) {
    case 'operator_wide':
      return 'Business';
    case 'org_unit':
      return grant.orgUnitName ?? grant.orgUnitId ?? 'Org unit';
    case 'location':
      return grant.locationName ?? grant.locationId ?? 'Location';
    default:
      return grant.scopeType;
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.keyValue,
    required this.label,
    required this.onPressed,
  });

  final String keyValue;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      key: Key(keyValue),
      onPressed: onPressed,
      style: AdminButtonStyles.secondary(),
      child: Text(label),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final MemberStatus status;

  @override
  Widget build(BuildContext context) {
    final tone = _toneFor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.5), width: 1),
      ),
      child: Text(
        memberStatusLabel(status),
        style: AppTextStyles.mono11(color: tone),
      ),
    );
  }

  static Color _toneFor(MemberStatus status) {
    switch (status) {
      case MemberStatus.active:
        return AppColors.positive;
      case MemberStatus.suspended:
        return AppColors.warning;
      case MemberStatus.dormant30:
        return AppColors.textMuted;
      case MemberStatus.softDeleted:
        return AppColors.negative;
    }
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: AppColors.textMuted),
        const SizedBox(width: 4),
        Text(
          label,
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

class _InvitesPanel extends StatelessWidget {
  const _InvitesPanel({
    required this.invites,
    required this.editingEnabled,
    required this.busyInviteIds,
    required this.onCancel,
  });

  final List<MemberInviteRow> invites;
  // Wave 2 W-2 — Cancel pending invite end-to-end.
  final bool editingEnabled;
  final Set<String> busyInviteIds;
  final Future<void> Function(MemberInviteRow invite) onCancel;

  @override
  Widget build(BuildContext context) {
    return OperatorWebPanel(
      key: const Key('admin_members_invites_panel'),
      title: 'Pending invites',
      trailing: Text(
        '${invites.length} invite${invites.length == 1 ? '' : 's'}',
        style: AppTextStyles.mono11(color: AppColors.textMuted),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (invites.isEmpty)
            Text(
              'No pending invites.',
              style: AppTextStyles.body13(color: AppColors.textMuted),
            )
          else
            for (final invite in invites)
              Padding(
                key: Key('admin_members_invite_row_${invite.inviteId}'),
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            invite.displayName,
                            style: AppTextStyles.body14(
                              color: AppColors.textPrimary,
                            ),
                          ),
                          Text(
                            invite.email,
                            style: AppTextStyles.body13(
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '${memberRoleLabel(invite.roleKey)} / '
                      '${_inviteScopeLabel(invite)}',
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                    if (editingEnabled) ...<Widget>[
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 110,
                        child: busyInviteIds.contains(invite.inviteId)
                            ? const Align(
                                alignment: Alignment.centerRight,
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.sunsetDark,
                                  ),
                                ),
                              )
                            : Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  key: Key(
                                    'admin_members_invite_cancel_'
                                    '${invite.inviteId}',
                                  ),
                                  onPressed: () => onCancel(invite),
                                  child: const Text('Cancel invite'),
                                ),
                              ),
                      ),
                    ],
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _ReadOnlyBanner extends StatelessWidget {
  const _ReadOnlyBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: <Widget>[
          const Icon(Icons.lock_outline, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'View only. Ask a super admin if a member needs to be changed.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({
    super.key,
    required this.message,
    this.emailConflicts = const <AdminEmailConflictUsage>[],
    this.currentOperatorId,
    this.onShowConflict,
    this.onChangeOperator,
  });

  final String message;
  final List<AdminEmailConflictUsage> emailConflicts;
  final String? currentOperatorId;
  final ValueChanged<AdminEmailConflictUsage>? onShowConflict;
  final VoidCallback? onChangeOperator;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.negative, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: AppTextStyles.mono11(color: AppColors.negative)),
          if (emailConflicts.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Where this email is used',
              style: AppTextStyles.uiLabel(color: AppColors.textPrimary),
            ),
            const SizedBox(height: 6),
            for (final usage in emailConflicts)
              _EmailConflictUsageTile(
                usage: usage,
                currentOperatorId: currentOperatorId,
                onShowConflict: onShowConflict,
                onChangeOperator: onChangeOperator,
              ),
          ],
        ],
      ),
    );
  }
}

class _EmailConflictUsageTile extends StatelessWidget {
  const _EmailConflictUsageTile({
    required this.usage,
    this.currentOperatorId,
    this.onShowConflict,
    this.onChangeOperator,
  });

  final AdminEmailConflictUsage usage;
  final String? currentOperatorId;
  final ValueChanged<AdminEmailConflictUsage>? onShowConflict;
  final VoidCallback? onChangeOperator;

  @override
  Widget build(BuildContext context) {
    final sameOperator =
        usage.operatorId == null || usage.operatorId == currentOperatorId;
    final details = <String>[
      usage.sourceLabel,
      if (usage.roleLabel != null) usage.roleLabel!,
      if (usage.status != null) usage.status!,
    ].join(' | ');
    return Container(
      key: Key('admin_members_email_conflict_${usage.email}'),
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.backgroundDeep.withValues(alpha: 0.45),
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.manage_search, size: 16, color: AppColors.textMuted),
          const SizedBox(width: 8),
          Expanded(
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
          ),
          const SizedBox(width: 8),
          if (sameOperator && onShowConflict != null)
            TextButton(
              key: Key('admin_members_email_conflict_show_${usage.email}'),
              onPressed: () => onShowConflict!(usage),
              child: const Text('Show row'),
            )
          else if (!sameOperator && onChangeOperator != null)
            TextButton(
              key: Key('admin_members_email_conflict_change_${usage.email}'),
              onPressed: onChangeOperator,
              child: const Text('Change operator'),
            ),
        ],
      ),
    );
  }
}

class _DisplayNameEditResult {
  const _DisplayNameEditResult({
    required this.displayName,
    required this.adminReason,
    this.email,
  });

  final String displayName;
  final String? email;
  final String adminReason;
}

class _DisplayNameEditDialog extends StatefulWidget {
  const _DisplayNameEditDialog({required this.row});

  final MemberAdminRow row;

  @override
  State<_DisplayNameEditDialog> createState() => _DisplayNameEditDialogState();
}

class _DisplayNameEditDialogState extends State<_DisplayNameEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  final _reasonController = TextEditingController();
  bool _nameViolated = false;
  bool _emailViolated = false;
  bool _reasonViolated = false;
  bool _confirmEmail = false;
  bool _confirmEmailViolated = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.row.displayName);
    _emailController = TextEditingController(text: widget.row.email);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  bool _emailChanged() =>
      _emailController.text.trim().toLowerCase() !=
      widget.row.email.toLowerCase();

  void _onSubmit() {
    final displayName = _nameController.text.trim();
    final email = _emailController.text.trim();
    final reason = _reasonController.text.trim();
    final emailIsChanging = _emailChanged();
    setState(() {
      _nameViolated = displayName.isEmpty;
      _emailViolated = email.isEmpty || !_looksLikeEmailAdmin(email);
      _reasonViolated = reason.isEmpty;
      _confirmEmailViolated = emailIsChanging && !_confirmEmail;
    });
    if (_nameViolated ||
        _emailViolated ||
        _reasonViolated ||
        _confirmEmailViolated) {
      return;
    }
    Navigator.of(context).pop(
      _DisplayNameEditResult(
        displayName: displayName,
        email: emailIsChanging ? email : null,
        adminReason: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_members_display_name_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Edit member',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              widget.row.email,
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_members_email_field'),
              controller: _emailController,
              textInputAction: TextInputAction.next,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: 'Email',
                border: const OutlineInputBorder(),
                errorText: _emailViolated
                    ? MembersValidationCopy.emailMalformed
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_emailChanged()) ...<Widget>[
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('admin_members_email_confirm'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text(
                  'Confirm: change this teammate’s sign-in email.',
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                subtitle: _confirmEmailViolated
                    ? Text(
                        'You must confirm before saving an email change.',
                        style:
                            AppTextStyles.body12(color: AppColors.negative),
                      )
                    : null,
                value: _confirmEmail,
                onChanged: (v) => setState(() => _confirmEmail = v ?? false),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_members_display_name_field'),
              controller: _nameController,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Display name',
                border: const OutlineInputBorder(),
                errorText: _nameViolated
                    ? MembersValidationCopy.displayNameEmpty
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_members_display_name_reason'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _reasonViolated
                    ? 'Add a reason before continuing.'
                    : null,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_members_display_name_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_members_display_name_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Save'),
        ),
      ],
    );
  }

  static bool _looksLikeEmailAdmin(String value) {
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

class _AdminReasonDialog extends StatefulWidget {
  const _AdminReasonDialog({required this.title});

  final String title;

  @override
  State<_AdminReasonDialog> createState() => _AdminReasonDialogState();
}

class _AdminReasonDialogState extends State<_AdminReasonDialog> {
  final _reasonController = TextEditingController();
  bool _violated = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _violated = true);
      return;
    }
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_members_reason_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(widget.title, style: AdminButtonStyles.dialogTitleStyle),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'The operator will see this reason in their audit log. '
              'Write a short, plain-English note about why you are '
              'making this change.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_members_reason_field'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _violated ? 'Add a reason before continuing.' : null,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_members_reason_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_members_reason_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

class _OverrideRoleResult {
  const _OverrideRoleResult({
    required this.roleId,
    required this.roleKey,
    required this.scope,
    required this.adminReason,
  });

  final String roleId;
  final String roleKey;
  final MemberAccessScopeRef scope;
  final String adminReason;
}

class _OverrideRoleChoice {
  const _OverrideRoleChoice({
    required this.roleId,
    required this.roleKey,
    required this.label,
  });

  final String roleId;
  final String roleKey;
  final String label;
}

String _inviteScopeLabel(MemberInviteRow invite) {
  switch (invite.scopeType) {
    case 'operator_wide':
      return 'Business';
    case 'org_unit':
      return invite.orgUnitName ?? invite.orgUnitId ?? 'Org unit';
    case 'location':
      return invite.primaryLocationName.isNotEmpty
          ? invite.primaryLocationName
          : 'Location';
    default:
      return invite.scopeType;
  }
}

class _OverrideRoleDialog extends StatefulWidget {
  const _OverrideRoleDialog({
    required this.currentRoleKey,
    required this.targetDisplayName,
    required this.roles,
    required this.accessScopes,
    this.initialScope,
  });

  final String currentRoleKey;
  final String targetDisplayName;
  final List<RoleAdminRow> roles;
  final List<MemberAccessScopeRef> accessScopes;
  final MemberAccessScopeRef? initialScope;

  @override
  State<_OverrideRoleDialog> createState() => _OverrideRoleDialogState();
}

class _OverrideRoleDialogState extends State<_OverrideRoleDialog> {
  late final List<_OverrideRoleChoice> _roleChoices = _buildRoleChoices();
  late String _selectedRoleId = _initialRoleId();
  late String? _selectedScopeId =
      widget.initialScope?.id ??
      (widget.accessScopes.isEmpty ? null : widget.accessScopes.first.id);
  final _reasonController = TextEditingController();
  bool _violated = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    final scope = _selectedScope;
    if (reason.isEmpty || scope == null) {
      setState(() => _violated = true);
      return;
    }
    final role = _selectedRoleChoice;
    if (role == null) {
      setState(() => _violated = true);
      return;
    }
    Navigator.of(context).pop(
      _OverrideRoleResult(
        roleId: role.roleId,
        roleKey: role.roleKey,
        scope: scope,
        adminReason: reason,
      ),
    );
  }

  MemberAccessScopeRef? get _selectedScope {
    final selected = _selectedScopeId;
    if (selected == null) return null;
    for (final scope in widget.accessScopes) {
      if (scope.id == selected) return scope;
    }
    return null;
  }

  _OverrideRoleChoice? get _selectedRoleChoice {
    for (final choice in _roleChoices) {
      if (choice.roleId == _selectedRoleId) return choice;
    }
    return null;
  }

  List<_OverrideRoleChoice> _buildRoleChoices() {
    if (widget.roles.isNotEmpty) {
      return <_OverrideRoleChoice>[
        for (final role in widget.roles)
          _OverrideRoleChoice(
            roleId: role.roleId,
            roleKey: role.roleKey,
            label: roleAdminDisplayLabel(role),
          ),
      ];
    }
    return <_OverrideRoleChoice>[
      for (final roleKey in kSeededRoleKeysForAdmin)
        _OverrideRoleChoice(
          roleId: roleKey,
          roleKey: roleKey,
          label: memberRoleLabel(roleKey),
        ),
    ];
  }

  String _initialRoleId() {
    for (final choice in _roleChoices) {
      if (choice.roleKey == widget.currentRoleKey) return choice.roleId;
    }
    return _roleChoices.isEmpty
        ? widget.currentRoleKey
        : _roleChoices.first.roleId;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_members_override_role_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Override role grant for ${widget.targetDisplayName}',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              "Reassigns this member's role directly. The operator's "
              'normal role-assignment workflow is skipped. The new '
              'role takes effect immediately.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('admin_members_override_role_select'),
              initialValue: _selectedRoleId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'New role',
                border: OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<String>>[
                for (final role in _roleChoices)
                  DropdownMenuItem<String>(
                    value: role.roleId,
                    child: Text(role.label),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _selectedRoleId = v);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('admin_members_override_role_scope'),
              initialValue: _selectedScopeId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Grant scope',
                border: const OutlineInputBorder(),
                errorText: _violated && _selectedScope == null
                    ? 'Choose a scope for this role grant.'
                    : null,
              ),
              items: <DropdownMenuItem<String>>[
                for (final scope in widget.accessScopes)
                  DropdownMenuItem<String>(
                    value: scope.id,
                    child: Text(scope.label),
                  ),
              ],
              onChanged: (v) => setState(() => _selectedScopeId = v),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_members_override_role_reason'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _violated ? 'Add a reason before continuing.' : null,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_members_override_role_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_members_override_role_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Apply override'),
        ),
      ],
    );
  }
}
