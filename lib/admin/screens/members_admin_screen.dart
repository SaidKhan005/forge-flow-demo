// Phase 11A.12 - F&F Operations Console "Members" surface.
//
// Cross-operator members + invites table for the admin console.
// Mirrors the operator-web sibling (`11W.1`) parity surface: same
// filter set (status / role / location / mfa_enrolled / search),
// same locked validation copy on the invite dialog, same pagination,
// same table layout, and same Team-tab row actions (Edit, Suspend /
// Reactivate, Remove from team, Reset password, Reset MFA). The
// admin path still writes through `/v1/admin/auth/*` with
// `actor_kind = forge_admin` and a non-empty `admin_reason`, but the
// Team tab UX follows operator web. Role policy and restore workflows
// stay outside this tab.
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
import '../admin_button_styles.dart';
import '../admin_route_handoff.dart';
import '../models/email_conflict_details.dart';
import '../services/members_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_members_ops_table.dart';
import '../widgets/admin_business_accounts_back_button.dart';
import 'invite_member_admin_dialog.dart';
import 'operator_picker_screen.dart';

const int _kMembersPageSize = 50;

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

  /// Kept for route compatibility. Team members no longer renders a
  /// Role policy action because operator web is the UX authority here.
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
  final Set<String> _busyUserIds = <String>{};
  Timer? _searchDebounce;
  int _refreshGeneration = 0;

  // Filter state. Mirrors the parity-contract filter set verbatim.
  MemberStatus? _statusFilter;
  String? _roleFilter;
  String? _locationFilter;
  bool? _mfaEnrolledFilter;
  String _searchQuery = '';
  int _pageIndex = 0;

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
        _clampPageIndex(visibleMembers.length);
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
      _pageIndex = 0;
    });
    _refresh();
  }

  void _resetPageAndRefresh() {
    setState(() => _pageIndex = 0);
    _refresh();
  }

  List<MemberAdminRow> get _pagedMembers {
    final pageStart = _pageIndex * _kMembersPageSize;
    if (pageStart >= _members.length) return const <MemberAdminRow>[];
    final pageEnd = (pageStart + _kMembersPageSize).clamp(0, _members.length);
    return _members.sublist(pageStart, pageEnd);
  }

  void _previousPage() {
    if (_pageIndex == 0) return;
    setState(() => _pageIndex -= 1);
  }

  void _nextPage() {
    final nextStart = (_pageIndex + 1) * _kMembersPageSize;
    if (nextStart >= _members.length) return;
    setState(() => _pageIndex += 1);
  }

  void _clampPageIndex(int totalRows) {
    final maxPage = totalRows == 0 ? 0 : (totalRows - 1) ~/ _kMembersPageSize;
    if (_pageIndex > maxPage) _pageIndex = maxPage;
  }

  List<MemberAdminRow> _applyLocalFilters(
    List<MemberAdminRow> rows, {
    required List<HierarchyLocationLeaf> hierarchyLocations,
  }) {
    final query = _searchQuery.trim().toLowerCase();
    final roleFilter = _roleFilter;
    final locationFilter = _locationFilter;
    final scopeLocationIds = _locationIdsForHierarchyScope(hierarchyLocations);
    final filtered = rows
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
    final sorted = filtered.toList();
    sorted.sort((a, b) {
      final cmp = b.lastActiveAt.compareTo(a.lastActiveAt);
      if (cmp != 0) return cmp;
      return a.email.toLowerCase().compareTo(b.email.toLowerCase());
    });
    return List<MemberAdminRow>.unmodifiable(sorted);
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

  Future<void> _runUserAction(
    MemberAdminRow row,
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() => _busyUserIds.add(row.userId));
    try {
      await _runAndRefresh(action, successHint: successHint);
    } finally {
      if (mounted) setState(() => _busyUserIds.remove(row.userId));
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
    await _runUserAction(
      row,
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
    await _runUserAction(
      row,
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
    final reason = await _promptAdminReason('Remove access');
    if (reason == null) return;
    await _runUserAction(
      row,
      () => widget.gateway.softDeleteMember(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-soft-delete'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Member access removed.',
    );
  }

  Future<void> _onResetPassword(MemberAdminRow row) async {
    final reason = await _promptAdminReason(
      'Reset password for ${row.displayName}',
    );
    if (reason == null) return;
    await _runUserAction(
      row,
      () => widget.gateway.resetPassword(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-reset-password'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Password reset email queued.',
    );
  }

  Future<void> _onResetMfa(MemberAdminRow row) async {
    final reason = await _promptAdminReason(
      'Reset two-factor sign-in for ${row.displayName}',
    );
    if (reason == null) return;
    await _runUserAction(
      row,
      () => widget.gateway.resetMfa(
        operatorId: widget.pickedOperator.operatorId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('member-reset-mfa'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint:
          'Two-factor sign-in removal started. It will be removed in 24 '
          'hours.',
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
      builder: (_) => _DisplayNameEditDialog(
        row: row,
        roles: _roles,
        accessScopes: _availableAccessScopes,
        initialScope: _initialGrantScope(row),
      ),
    );
    if (result == null) return;
    final emailChanged =
        result.email != null &&
        result.email!.trim().toLowerCase() != row.email.toLowerCase();
    final displayNameChanged =
        result.displayName.trim() != row.displayName.trim();
    final roleChanged = result.roleKey != row.roleKey;
    final scopeChanged = _scopeChanged(row, result.scope);
    if (!emailChanged && !displayNameChanged && !roleChanged && !scopeChanged) {
      return;
    }
    await _runUserAction(row, () async {
      if (emailChanged || displayNameChanged) {
        await widget.gateway.updateMember(
          operatorId: widget.pickedOperator.operatorId,
          userId: row.userId,
          idempotencyKey: _nextIdempotencyKey('member-edit'),
          actorUserId: widget.actorUserId,
          actorIsForgeAdmin: widget.editingEnabled,
          adminReason: result.adminReason,
          email: emailChanged ? result.email : null,
          displayName: displayNameChanged ? result.displayName : null,
        );
      }
      if (roleChanged || scopeChanged) {
        await widget.gateway.overrideRoleGrant(
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
        );
      }
    }, successHint: 'Updated ${row.email}.');
  }

  bool _scopeChanged(MemberAdminRow row, MemberAccessScopeRef scope) {
    final initial = _initialGrantScope(row);
    return initial?.id != scope.id;
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
      builder: (context) => OperatorWebDialog(
        key: const Key('admin_members_cancel_invite_confirm'),
        title: 'Cancel invite',
        icon: Icons.cancel_schedule_send_outlined,
        maxWidth: 480,
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
        child: Text(
          'Cancel the pending invite for ${invite.email}? Their link will '
          'stop working. You can send a new invite later if they still '
          'need access.',
          style: AppTextStyles.body13(color: AppColors.textPrimary),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final reason = await _promptAdminReason(
      'Cancel invite for ${invite.email}',
    );
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

  List<_RoleFilterOption> get _roleFilterOptions {
    if (_roles.isNotEmpty) {
      return <_RoleFilterOption>[
        for (final role in _roles)
          _RoleFilterOption(
            roleKey: role.roleKey,
            label: roleAdminDisplayLabel(role),
          ),
      ];
    }
    return <_RoleFilterOption>[
      for (final roleKey in kSeededRoleKeysForAdmin)
        _RoleFilterOption(roleKey: roleKey, label: memberRoleLabel(roleKey)),
    ];
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
            collapseBelowWidth: 980,
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
          _MembersFilterBar(
            statusFilter: _statusFilter,
            roleFilter: _roleFilter,
            locationFilter: _locationFilter,
            mfaEnrolledFilter: _mfaEnrolledFilter,
            searchQuery: _searchQuery,
            locations: _availableLocations,
            roles: _roleFilterOptions,
            onStatusChanged: (v) {
              setState(() => _statusFilter = v);
              _resetPageAndRefresh();
            },
            onRoleChanged: (v) {
              setState(() => _roleFilter = v);
              _resetPageAndRefresh();
            },
            onLocationChanged: (v) {
              setState(() => _locationFilter = v);
              _resetPageAndRefresh();
            },
            onMfaEnrolledChanged: (v) {
              setState(() => _mfaEnrolledFilter = v);
              _resetPageAndRefresh();
            },
            onSearchChanged: (v) {
              setState(() {
                _searchQuery = v;
                _pageIndex = 0;
              });
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
    if (widget.editingEnabled) {
      children.add(
        SizedBox(
          height: 48,
          child: FilledButton.icon(
            key: const Key('admin_members_invite_button'),
            onPressed: _onInvite,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.sunset,
              foregroundColor: AppColors.backgroundSurface,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              textStyle: AppTextStyles.display16(
                color: AppColors.backgroundSurface,
              ),
            ),
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 20),
            label: const Text('Invite member'),
          ),
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
      return ConstrainedBox(
        key: const Key('admin_members_load_error'),
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Members could not load',
                style: AppTextStyles.display20(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 8),
              Text(
                _loadError!,
                style: AppTextStyles.body13(color: AppColors.textPrimary),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  key: const Key('admin_members_load_retry'),
                  onPressed: _refresh,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.sunsetDark,
                    side: const BorderSide(
                      color: AppColors.sunsetDark,
                      width: 1,
                    ),
                  ),
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
        ),
      );
    }
    // Outer frame is OperatorWebScreenBody (a SingleChildScrollView), so
    // this body returns a plain Column to avoid nesting a second scroll
    // view inside it.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdminMembersOpsTable(
          rows: _pagedMembers,
          editingEnabled: widget.editingEnabled,
          busyUserIds: _busyUserIds,
          onSuspend: _onSuspend,
          onReactivate: _onReactivate,
          onSoftDelete: _onSoftDelete,
          onResetPassword: _onResetPassword,
          onResetMfa: _onResetMfa,
          onEditDisplayName: _onEditDisplayName,
        ),
        const SizedBox(height: 12),
        AdminMembersPaginationBar(
          pageIndex: _pageIndex,
          pageSize: _kMembersPageSize,
          totalRows: _members.length,
          onPrevious: _previousPage,
          onNext: _nextPage,
        ),
        if (_invites.isNotEmpty) ...<Widget>[
          const SizedBox(height: 24),
          AdminMembersInvitesPanel(
            invites: _invites,
            editingEnabled: widget.editingEnabled,
            busyInviteIds: _busyInviteIds,
            onCancel: _onCancelInvite,
          ),
        ],
      ],
    );
  }
}

class _RoleFilterOption {
  const _RoleFilterOption({required this.roleKey, required this.label});

  final String roleKey;
  final String label;
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
    required this.roles,
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
  final List<_RoleFilterOption> roles;
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
    return Container(
      key: const Key('admin_members_filter_card'),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 260,
            child: TextField(
              key: const Key('admin_members_filter_search'),
              decoration: const InputDecoration(
                labelText: 'Search by name or email',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onChanged: widget.onSearchChanged,
              controller: _searchController,
            ),
          ),
          SizedBox(
            width: 220,
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
            width: 220,
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
                for (final role in widget.roles)
                  DropdownMenuItem<String?>(
                    value: role.roleKey,
                    child: Text(role.label),
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
            width: 220,
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
                DropdownMenuItem<bool?>(value: null, child: Text('Any')),
                DropdownMenuItem<bool?>(value: true, child: Text('On')),
                DropdownMenuItem<bool?>(value: false, child: Text('Off')),
              ],
              onChanged: widget.onMfaEnrolledChanged,
            ),
          ),
          if (activeFilters.isNotEmpty)
            TextButton.icon(
              key: const Key('admin_members_clear_filters'),
              onPressed: widget.onClearFilters,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.sunsetDark,
              ),
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Clear filters'),
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
    required this.roleId,
    required this.roleKey,
    required this.scope,
    required this.adminReason,
    this.email,
  });

  final String displayName;
  final String roleId;
  final String roleKey;
  final MemberAccessScopeRef scope;
  final String? email;
  final String adminReason;
}

class _EditRoleChoice {
  const _EditRoleChoice({
    required this.roleId,
    required this.roleKey,
    required this.label,
  });

  final String roleId;
  final String roleKey;
  final String label;
}

class _DisplayNameEditDialog extends StatefulWidget {
  const _DisplayNameEditDialog({
    required this.row,
    required this.roles,
    required this.accessScopes,
    this.initialScope,
  });

  final MemberAdminRow row;
  final List<RoleAdminRow> roles;
  final List<MemberAccessScopeRef> accessScopes;
  final MemberAccessScopeRef? initialScope;

  @override
  State<_DisplayNameEditDialog> createState() => _DisplayNameEditDialogState();
}

class _DisplayNameEditDialogState extends State<_DisplayNameEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _emailController;
  final _reasonController = TextEditingController();
  late final List<_EditRoleChoice> _roleChoices = _buildRoleChoices();
  late String _selectedRoleId = _initialRoleId();
  late String? _selectedScopeId =
      widget.initialScope?.id ??
      (widget.accessScopes.isEmpty ? null : widget.accessScopes.first.id);
  bool _nameViolated = false;
  bool _emailViolated = false;
  bool _reasonViolated = false;
  bool _roleViolated = false;
  bool _scopeViolated = false;
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

  _EditRoleChoice? get _selectedRoleChoice {
    for (final role in _roleChoices) {
      if (role.roleId == _selectedRoleId) return role;
    }
    return null;
  }

  MemberAccessScopeRef? get _selectedScope {
    final selected = _selectedScopeId;
    if (selected == null) return null;
    for (final scope in widget.accessScopes) {
      if (scope.id == selected) return scope;
    }
    return null;
  }

  List<_EditRoleChoice> _buildRoleChoices() {
    if (widget.roles.isNotEmpty) {
      return <_EditRoleChoice>[
        for (final role in widget.roles)
          _EditRoleChoice(
            roleId: role.roleId,
            roleKey: role.roleKey,
            label: roleAdminDisplayLabel(role),
          ),
      ];
    }
    return <_EditRoleChoice>[
      for (final roleKey in kSeededRoleKeysForAdmin)
        _EditRoleChoice(
          roleId: roleKey,
          roleKey: roleKey,
          label: memberRoleLabel(roleKey),
        ),
    ];
  }

  String _initialRoleId() {
    for (final choice in _roleChoices) {
      if (choice.roleKey == widget.row.roleKey) return choice.roleId;
    }
    return _roleChoices.isEmpty
        ? widget.row.roleKey
        : _roleChoices.first.roleId;
  }

  String _scopeHelper(MemberAccessScopeRef? scope) {
    if (scope == null) return 'Choose where this applies.';
    switch (scope.scopeType) {
      case 'operator_wide':
        return 'Business-wide: this teammate can act in every location.';
      case 'org_unit':
        return 'Org unit: this teammate inherits access to locations under '
            'the chosen unit.';
      case 'location':
        return 'Single location: access is limited to the chosen location.';
      default:
        return 'Choose where this applies.';
    }
  }

  void _onSubmit() {
    final displayName = _nameController.text.trim();
    final email = _emailController.text.trim();
    final reason = _reasonController.text.trim();
    final emailIsChanging = _emailChanged();
    final selectedRole = _selectedRoleChoice;
    final selectedScope = _selectedScope;
    setState(() {
      _nameViolated = displayName.isEmpty;
      _emailViolated = email.isEmpty || !_looksLikeEmailAdmin(email);
      _reasonViolated = reason.isEmpty;
      _roleViolated = selectedRole == null;
      _scopeViolated = selectedScope == null;
      _confirmEmailViolated = emailIsChanging && !_confirmEmail;
    });
    if (_nameViolated ||
        _emailViolated ||
        _reasonViolated ||
        _roleViolated ||
        _scopeViolated ||
        _confirmEmailViolated) {
      return;
    }
    Navigator.of(context).pop(
      _DisplayNameEditResult(
        displayName: displayName,
        roleId: selectedRole!.roleId,
        roleKey: selectedRole.roleKey,
        scope: selectedScope!,
        email: emailIsChanging ? email : null,
        adminReason: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return OperatorWebDialog(
      key: const Key('admin_members_display_name_dialog'),
      title: 'Edit member',
      icon: Icons.manage_accounts_outlined,
      maxWidth: 540,
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
      child: SingleChildScrollView(
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
                labelText: 'Email address',
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
                  "Confirm you want to change this teammate's sign-in email.",
                  style: AppTextStyles.body13(color: AppColors.textPrimary),
                ),
                subtitle: _confirmEmailViolated
                    ? Text(
                        'You must confirm before saving an email change.',
                        style: AppTextStyles.body12(color: AppColors.negative),
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
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('admin_members_role_field'),
              initialValue: _selectedRoleId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Role',
                border: const OutlineInputBorder(),
                errorText: _roleViolated
                    ? MembersValidationCopy.roleMissing
                    : null,
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
              key: const Key('admin_members_scope_field'),
              initialValue: _selectedScopeId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Where this applies',
                border: const OutlineInputBorder(),
                errorText: _scopeViolated
                    ? MembersValidationCopy.locationMissing
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
            const SizedBox(height: 6),
            Text(
              _scopeHelper(_selectedScope),
              key: const Key('admin_members_scope_helper'),
              style: AppTextStyles.body12(color: AppColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_members_display_name_reason'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                hintText: 'Why are you making this change?',
                border: const OutlineInputBorder(),
                errorText: _reasonViolated
                    ? 'Add a reason before continuing.'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
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
    return OperatorWebDialog(
      key: const Key('admin_members_reason_dialog'),
      title: widget.title,
      icon: Icons.edit_note,
      maxWidth: 520,
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
    );
  }
}
