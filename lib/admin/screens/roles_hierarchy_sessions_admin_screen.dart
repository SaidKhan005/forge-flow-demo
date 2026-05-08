// Phase 11A.13 - F&F Operations Console "Roles + Hierarchy"
// inspect surface.
//
// Cross-operator inspect with two tabs (Roles / Hierarchy) for the
// F&F admin to inspect and audit-edit role catalog and org-unit
// hierarchy for the picked operator. Active sessions now live under
// Security/audit/sessions; the reusable panel remains in this file
// because it shares the roles/hierarchy/sessions gateway contract.
//
// Mounts in the admin shell at `/admin/roles-hierarchy-sessions`.
// The shell passes the shared Operations operator context when one
// exists; the picker is only opened when the admin needs to choose
// or change operator.
//
// Authority: docs/contracts/team_roles_hierarchy_console_parity_contract.md
// "§ Roles + Permission Explainer (11W.2 + 11A.13 Roles tab)" +
// "§ Hierarchy (11W.3 + 11A.13 Hierarchy tab)" +
// "§ Sessions (11W.4 + 11A.13 Sessions tab)" +
// "§ Operator self-service vs F&F admin path" +
// "§ Idempotency keys" + "§ Audit-row shape".

import 'package:flutter/material.dart';

import '../../auth/permission_keys.dart';
import '../../theme/app_theme.dart';
import '../admin_button_styles.dart';
import '../services/demo_roles_hierarchy_sessions_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';
import 'operator_picker_screen.dart';

class RolesHierarchySessionsAdminScreen extends StatefulWidget {
  const RolesHierarchySessionsAdminScreen({
    super.key,
    required this.gateway,
    required this.actorUserId,
    required this.pickedOperator,
    this.editingEnabled = true,
    this.canEditSeededRoles = false,
    this.idempotencyKeyFactory,
    this.onChangeOperator,
  });

  final RolesHierarchySessionsAdminGateway gateway;
  final String actorUserId;
  final OperatorPickerResult pickedOperator;

  /// Mirrors the 11A.12 Members pattern: when false, every mutate
  /// affordance is hidden. The gateway also throws
  /// [RolesHierarchySessionsForbiddenException] if a non-forge-admin
  /// call reaches the seam, so this is the user-facing layer of a
  /// two-layer defence.
  final bool editingEnabled;

  /// Per the parity contract § "Seeded roles" line 104: edit on
  /// seeded roles is gated on `admin.roles.edit_seeded` (MFA-required).
  /// This flag is the screen-level mirror; production wires it from
  /// the signed-in admin's MFA-required claims, demo defaults false.
  final bool canEditSeededRoles;

  final String Function()? idempotencyKeyFactory;

  /// Re-opens the operator picker. Wired by the route shell so the
  /// admin can switch operators without leaving the surface.
  final VoidCallback? onChangeOperator;

  @override
  State<RolesHierarchySessionsAdminScreen> createState() =>
      _RolesHierarchySessionsAdminScreenState();
}

class _RolesHierarchySessionsAdminScreenState
    extends State<RolesHierarchySessionsAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 2,
    vsync: this,
  );

  bool _rolesLoading = true;
  bool _hierarchyLoading = false;
  bool _rolesLoaded = false;
  bool _hierarchyLoaded = false;
  String? _rolesLoadError;
  String? _hierarchyLoadError;
  String? _actionError;

  List<RoleAdminRow> _roles = const <RoleAdminRow>[];
  List<OrgUnitAdminNode> _orgUnits = const <OrgUnitAdminNode>[];
  List<HierarchyLocationLeaf> _locations = const <HierarchyLocationLeaf>[];
  int _rolesGeneration = 0;
  int _hierarchyGeneration = 0;

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
    _tabController.addListener(_ensureCurrentTabLoaded);
    _refreshRoles();
  }

  @override
  void dispose() {
    _tabController.removeListener(_ensureCurrentTabLoaded);
    _tabController.dispose();
    super.dispose();
  }

  void _ensureCurrentTabLoaded() {
    switch (_tabController.index) {
      case 0:
        if (!_rolesLoaded && !_rolesLoading) {
          _refreshRoles();
        }
      case 1:
        if (!_hierarchyLoaded && !_hierarchyLoading) {
          _refreshHierarchy();
        }
    }
  }

  Future<void> _refreshRoles() async {
    final generation = ++_rolesGeneration;
    setState(() {
      _rolesLoading = true;
      _rolesLoadError = null;
    });
    try {
      final operatorId = widget.pickedOperator.operatorId;
      final roles = await widget.gateway.listRoles(operatorId: operatorId);
      if (generation != _rolesGeneration) return;
      if (!mounted) return;
      setState(() {
        _roles = roles;
        _rolesLoaded = true;
        _rolesLoading = false;
      });
    } on RolesHierarchySessionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _rolesLoadError = error.message;
        _rolesLoading = false;
      });
    } on RolesHierarchySessionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() {
        _rolesLoadError = error.message;
        _rolesLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _rolesLoadError = 'Could not load roles: $error';
        _rolesLoading = false;
      });
    }
  }

  Future<void> _refreshHierarchy() async {
    final generation = ++_hierarchyGeneration;
    setState(() {
      _hierarchyLoading = true;
      _hierarchyLoadError = null;
    });
    try {
      final operatorId = widget.pickedOperator.operatorId;
      final results = await Future.wait<Object>([
        widget.gateway.listOrgUnits(operatorId: operatorId),
        widget.gateway.listHierarchyLocations(operatorId: operatorId),
      ]);
      if (generation != _hierarchyGeneration) return;
      final orgUnits = results[0] as List<OrgUnitAdminNode>;
      final locations = results[1] as List<HierarchyLocationLeaf>;
      if (!mounted) return;
      setState(() {
        _orgUnits = orgUnits;
        _locations = locations;
        _hierarchyLoaded = true;
        _hierarchyLoading = false;
      });
    } on RolesHierarchySessionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _hierarchyLoadError = error.message;
        _hierarchyLoading = false;
      });
    } on RolesHierarchySessionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() {
        _hierarchyLoadError = error.message;
        _hierarchyLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _hierarchyLoadError = 'Could not load hierarchy: $error';
        _hierarchyLoading = false;
      });
    }
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    required Future<void> Function() refresh,
    String? successHint,
  }) async {
    setState(() => _actionError = null);
    try {
      await action();
      await refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on RolesHierarchySessionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } on RolesHierarchySessionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
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

  // --- Roles tab actions -------------------------------------------------

  Future<void> _onEditSeededRole(RoleAdminRow row) async {
    if (!widget.canEditSeededRoles) return;
    final result = await showDialog<EditSeededRoleResult>(
      context: context,
      builder: (_) => EditSeededRoleDialog(initial: row),
    );
    if (result == null) return;
    await _runAndRefresh(
      () => widget.gateway.editSeededRole(
        operatorId: widget.pickedOperator.operatorId,
        roleId: row.roleId,
        permissionKeys: result.permissionKeys,
        idempotencyKey: _nextIdempotencyKey('roles-edit-seeded'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      ),
      refresh: _refreshRoles,
      successHint: 'Updated ${roleAdminDisplayLabel(row)}',
    );
  }

  Future<void> _onCreateCustomRole() async {
    final result = await showDialog<CustomRoleDraft>(
      context: context,
      builder: (_) => CreateCustomRoleDialog(
        existingRoleKeys: <String>{for (final r in _roles) r.roleKey},
      ),
    );
    if (result == null) return;
    await _runAndRefresh(
      () => widget.gateway.createCustomRole(
        operatorId: widget.pickedOperator.operatorId,
        roleKey: result.roleKey,
        displayName: result.displayName,
        description: result.description,
        permissionKeys: result.permissionKeys,
        idempotencyKey: _nextIdempotencyKey('roles-create-custom'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      ),
      refresh: _refreshRoles,
      successHint: 'Created ${result.displayName}',
    );
  }

  Future<void> _onDeleteCustomRole(RoleAdminRow row) async {
    final reason = await _promptAdminReason(
      'Delete ${roleAdminDisplayLabel(row)}',
    );
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.deleteCustomRole(
        operatorId: widget.pickedOperator.operatorId,
        roleId: row.roleId,
        idempotencyKey: _nextIdempotencyKey('roles-delete-custom'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      refresh: _refreshRoles,
      successHint: 'Deleted ${roleAdminDisplayLabel(row)}',
    );
  }

  // --- Hierarchy tab actions --------------------------------------------

  Future<void> _onMoveLocation(HierarchyLocationLeaf leaf) async {
    final candidates = _orgUnits.toList(growable: false);
    if (candidates.isEmpty) return;
    final result = await showDialog<_MoveLocationResult>(
      context: context,
      builder: (_) => _MoveLocationDialog(leaf: leaf, candidates: candidates),
    );
    if (result == null) return;
    await _runAndRefresh(
      () => widget.gateway.moveLocation(
        operatorId: widget.pickedOperator.operatorId,
        locationId: leaf.locationId,
        newOrgUnitId: result.newOrgUnitId,
        idempotencyKey: _nextIdempotencyKey('hierarchy-move-location'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      ),
      refresh: _refreshHierarchy,
      successHint: 'Moved ${leaf.name}',
    );
  }

  Future<void> _onAddChildOrgUnit(OrgUnitAdminNode parent) async {
    final existingNames = <String>{
      for (final unit in _orgUnits)
        if (unit.parentOrgUnitId == parent.orgUnitId) unit.name.toLowerCase(),
    };
    final result = await showDialog<_AddOrgUnitResult>(
      context: context,
      builder: (_) =>
          _AddChildOrgUnitDialog(parent: parent, existingNames: existingNames),
    );
    if (result == null) return;
    await _runAndRefresh(
      () => widget.gateway.createOrgUnit(
        operatorId: widget.pickedOperator.operatorId,
        parentOrgUnitId: parent.orgUnitId,
        unitType: result.unitType,
        label: result.label,
        name: result.name,
        idempotencyKey: _nextIdempotencyKey('hierarchy-create-org-unit'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      ),
      refresh: _refreshHierarchy,
      successHint: 'Added ${result.name}',
    );
  }

  // --- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_roles_hierarchy_sessions_screen'),
      color: AppColors.backgroundDeep,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AdminPageHeader(
              title: 'Team access',
              subtitle:
                  '${widget.pickedOperator.operatorBusinessName}: role policy, '
                  'and location hierarchy. Active sessions moved to Security/audit/sessions.',
              trailing: _buildHeaderActions(),
            ),
            const SizedBox(height: 14),
            if (!widget.editingEnabled)
              const _ReadOnlyBanner(key: Key('admin_rhs_readonly_banner')),
            if (_actionError != null)
              _ErrorBanner(
                key: const Key('admin_rhs_action_error'),
                message: _actionError!,
              ),
            _AccessScopeFilterCard(pickedOperator: widget.pickedOperator),
            const SizedBox(height: 12),
            TabBar(
              key: const Key('admin_rhs_tab_bar'),
              controller: _tabController,
              labelColor: AppColors.textPrimary,
              unselectedLabelColor: AppColors.textMuted,
              indicatorColor: AppColors.sunset,
              tabs: const <Widget>[
                Tab(key: Key('admin_rhs_tab_roles'), text: 'Role policy'),
                Tab(
                  key: Key('admin_rhs_tab_hierarchy'),
                  text: 'Location hierarchy',
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget? _buildHeaderActions() {
    final children = <Widget>[];
    if (widget.onChangeOperator != null) {
      children.add(
        OutlinedButton.icon(
          key: const Key('admin_rhs_change_operator'),
          onPressed: widget.onChangeOperator,
          style: AdminButtonStyles.secondary(),
          icon: const Icon(Icons.swap_horiz, size: 16),
          label: const Text('Change operator'),
        ),
      );
    }
    if (children.isEmpty) return null;
    return Wrap(spacing: 8, runSpacing: 8, children: children);
  }

  Widget _buildBody() {
    return TabBarView(
      controller: _tabController,
      children: <Widget>[
        _TabLoadBody(
          loading: _rolesLoading,
          error: _rolesLoadError,
          loadingKey: const Key('admin_rhs_loading'),
          errorKey: const Key('admin_rhs_load_error'),
          child: RolePolicyAdminPanel(
            roles: _roles,
            editingEnabled: widget.editingEnabled,
            canEditSeededRoles: widget.canEditSeededRoles,
            onEditSeeded: _onEditSeededRole,
            onCreateCustom: _onCreateCustomRole,
            onDeleteCustom: _onDeleteCustomRole,
          ),
        ),
        _TabLoadBody(
          loading: _hierarchyLoading,
          error: _hierarchyLoadError,
          loadingKey: const Key('admin_rhs_hierarchy_loading'),
          errorKey: const Key('admin_rhs_hierarchy_load_error'),
          child: _HierarchyTab(
            orgUnits: _orgUnits,
            locations: _locations,
            editingEnabled: widget.editingEnabled,
            onAddChildOrgUnit: _onAddChildOrgUnit,
            onMoveLocation: _onMoveLocation,
          ),
        ),
      ],
    );
  }
}

class _TabLoadBody extends StatelessWidget {
  const _TabLoadBody({
    required this.loading,
    required this.error,
    required this.loadingKey,
    required this.errorKey,
    required this.child,
  });

  final bool loading;
  final String? error;
  final Key loadingKey;
  final Key errorKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(
        key: loadingKey,
        child: const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      );
    }
    if (error != null) {
      return _ErrorBanner(key: errorKey, message: error!);
    }
    return child;
  }
}

class _AccessScopeFilterCard extends StatelessWidget {
  const _AccessScopeFilterCard({required this.pickedOperator});

  final OperatorPickerResult pickedOperator;

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      key: const Key('admin_rhs_filter_card'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(Icons.filter_list, size: 18, color: AppColors.sunsetDark),
          Text(
            'Filters',
            style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
          ),
          _ScopeChip(
            icon: Icons.business_outlined,
            label: pickedOperator.operatorBusinessName,
          ),
          _ScopeChip(
            icon: Icons.location_on_outlined,
            label: pickedOperator.locationName,
          ),
          Text(
            'Role policy, hierarchy, and sessions use the selected business scope.',
            style: AppTextStyles.mono11(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  const _ScopeChip({required this.icon, required this.label});

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
        children: [
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

// ---------------------------------------------------------------------
// Roles tab
// ---------------------------------------------------------------------

class RolePolicyAdminPanel extends StatelessWidget {
  const RolePolicyAdminPanel({
    super.key,
    required this.roles,
    required this.editingEnabled,
    required this.canEditSeededRoles,
    required this.onEditSeeded,
    required this.onCreateCustom,
    required this.onDeleteCustom,
  });

  final List<RoleAdminRow> roles;
  final bool editingEnabled;
  final bool canEditSeededRoles;
  final ValueChanged<RoleAdminRow> onEditSeeded;
  final VoidCallback onCreateCustom;
  final ValueChanged<RoleAdminRow> onDeleteCustom;

  @override
  Widget build(BuildContext context) {
    final seeded = roles.where((r) => r.isSeeded).toList(growable: false);
    final custom = roles.where((r) => !r.isSeeded).toList(growable: false);
    return SingleChildScrollView(
      key: const Key('admin_rhs_roles_tab'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdminStatStrip(
            items: <AdminStatItem>[
              AdminStatItem(
                label: 'Seeded roles',
                value: seeded.length.toString(),
                icon: Icons.verified_user_outlined,
                tone: AppColors.peacock,
              ),
              AdminStatItem(
                label: 'Custom roles',
                value: custom.length.toString(),
                icon: Icons.person_add_alt_outlined,
                tone: AppColors.sunset,
              ),
              AdminStatItem(
                label: 'Permission keys',
                value: PermissionKeys.all.length.toString(),
                icon: Icons.key_outlined,
                tone: AppColors.textMuted,
              ),
            ],
          ),
          const SizedBox(height: 16),
          AdminCard(
            child: Column(
              key: const Key('admin_rhs_roles_seeded'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Seeded roles',
                        style: AppTextStyles.sectionTitle(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '${seeded.length} role${seeded.length == 1 ? '' : 's'}',
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Seeded roles are read only. To change a seeded role you '
                  'need an admin role edit permission with multi-factor sign-in.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                if (seeded.isEmpty)
                  Text(
                    'No seeded roles for this operator.',
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  )
                else
                  for (final role in seeded)
                    _RoleRowTile(
                      key: Key('admin_rhs_role_row_${role.roleId}'),
                      row: role,
                      editingEnabled:
                          editingEnabled && canEditSeededRoles && role.isSeeded,
                      isSeeded: true,
                      onEdit: onEditSeeded,
                      onDelete: onDeleteCustom,
                    ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AdminCard(
            child: Column(
              key: const Key('admin_rhs_roles_custom'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Custom roles',
                        style: AppTextStyles.sectionTitle(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (editingEnabled)
                      FilledButton.icon(
                        key: const Key('admin_rhs_roles_create_custom'),
                        onPressed: onCreateCustom,
                        style: AdminButtonStyles.primary,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('New custom role'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                if (custom.isEmpty)
                  Text(
                    'This operator has no custom roles yet.',
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  )
                else
                  for (final role in custom)
                    _RoleRowTile(
                      key: Key('admin_rhs_role_row_${role.roleId}'),
                      row: role,
                      editingEnabled: editingEnabled,
                      isSeeded: false,
                      onEdit: onEditSeeded,
                      onDelete: onDeleteCustom,
                    ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const _PermissionExplainerCard(),
        ],
      ),
    );
  }
}

class _RoleRowTile extends StatelessWidget {
  const _RoleRowTile({
    super.key,
    required this.row,
    required this.editingEnabled,
    required this.isSeeded,
    required this.onEdit,
    required this.onDelete,
  });

  final RoleAdminRow row;
  final bool editingEnabled;
  final bool isSeeded;
  final ValueChanged<RoleAdminRow> onEdit;
  final ValueChanged<RoleAdminRow> onDelete;

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
                    roleAdminDisplayLabel(row),
                    style: AppTextStyles.body14(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (isSeeded)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSurface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: AppColors.borderSubtle,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      'Seeded',
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              row.roleKey,
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
            if (row.description.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                row.description,
                style: AppTextStyles.body13(color: AppColors.textSecondary),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: <Widget>[
                for (final key in row.permissionKeys)
                  PermissionKeyChip(permissionKey: key),
              ],
            ),
            if (editingEnabled) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  if (isSeeded)
                    OutlinedButton(
                      key: Key('admin_rhs_role_edit_${row.roleId}'),
                      onPressed: () => onEdit(row),
                      style: AdminButtonStyles.secondary(),
                      child: const Text('Edit permissions'),
                    )
                  else
                    OutlinedButton(
                      key: Key('admin_rhs_role_delete_${row.roleId}'),
                      onPressed: () => onDelete(row),
                      style: AdminButtonStyles.secondary(),
                      child: const Text('Delete'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// MFA-required marker text used in the chip + tooltip per the parity
/// contract § "Roles + Permission Explainer" line 110:
/// "Render with a 🔒 chip (or text equivalent — no emoji-only signals
/// per accessibility) and the tooltip 'Requires multi-factor
/// authentication.'" The contract mandates a non-emoji-only signal —
/// this widget pairs a `Lock` icon with the literal "MFA" text label.
@visibleForTesting
const String kMfaRequiredTooltip = 'Requires multi-factor authentication.';

/// One permission-key chip. Renders the catalog `key` as a monospace
/// label; if the key is in [PermissionKeys.requiresMfa], decorates the
/// chip with a lock icon plus the literal "MFA" text and surfaces the
/// contract-pinned tooltip on hover. Used by the role row tile and
/// the Permission Explainer.
class PermissionKeyChip extends StatelessWidget {
  const PermissionKeyChip({super.key, required this.permissionKey});

  final String permissionKey;

  @override
  Widget build(BuildContext context) {
    final mfa = PermissionKeys.requiresMfa.contains(permissionKey);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            permissionKey,
            style: AppTextStyles.mono11(color: AppColors.textSecondary),
          ),
          if (mfa) ...<Widget>[
            const SizedBox(width: 6),
            const Icon(
              Icons.lock_outline,
              size: 12,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 2),
            Text(
              'MFA',
              style: AppTextStyles.mono11(color: AppColors.textMuted),
            ),
          ],
        ],
      ),
    );
    if (!mfa) return chip;
    return Tooltip(
      key: Key('admin_rhs_perm_mfa_tooltip_$permissionKey'),
      message: kMfaRequiredTooltip,
      child: chip,
    );
  }
}

/// Permission Explainer card. Renders every key in the frozen
/// [PermissionKeys.all] catalog grouped by the nine categories the
/// parity contract pins at § "Roles + Permission Explainer"
/// line 102: `product.*` → `forgeflow.*` → `barrio.*` → `admin.*` →
/// `team.*` → `billing.*` → `integration.*` → `integrations.*` →
/// `workflow.*`.
///
/// MFA-required keys carry the [PermissionKeyChip] MFA marker per
/// line 110. The chip text is the raw catalog key — descriptions live
/// in `auth_permission_key_catalog.md` and are NOT paraphrased here
/// (per the contract's anti-pattern: "A slice that paraphrases the
/// catalog `description` text in the Permission Explainer").
class _PermissionExplainerCard extends StatelessWidget {
  const _PermissionExplainerCard();

  static const List<String> _categoryOrder = <String>[
    'product',
    'forgeflow',
    'barrio',
    'admin',
    'team',
    'billing',
    'integration',
    'integrations',
    'workflow',
  ];

  static const Map<String, String> _categoryLabels = <String, String>{
    'product': 'Product access',
    'forgeflow': 'Forge & Flow surfaces',
    'barrio': 'Barrio surfaces',
    'admin': 'Admin actions',
    'team': 'Operator team management',
    'billing': 'Billing',
    'integration': 'Integration management',
    'integrations': 'Vendor connections',
    'workflow': 'Workflow automation',
  };

  Map<String, List<String>> _bucket() {
    final buckets = <String, List<String>>{
      for (final c in _categoryOrder) c: <String>[],
    };
    for (final key in PermissionKeys.all) {
      final dot = key.indexOf('.');
      if (dot <= 0) continue;
      final prefix = key.substring(0, dot);
      buckets[prefix]?.add(key);
    }
    for (final list in buckets.values) {
      list.sort();
    }
    return buckets;
  }

  @override
  Widget build(BuildContext context) {
    final bucketed = _bucket();
    return AdminCard(
      child: Column(
        key: const Key('admin_rhs_permission_explainer'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Permission catalog',
            style: AppTextStyles.sectionTitle(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            'The full set of permission keys roles can grant. Keys with '
            'a lock marker need multi-factor sign-in.',
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          for (final category in _categoryOrder)
            if ((bucketed[category] ?? const <String>[]).isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  key: Key('admin_rhs_permission_category_$category'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _categoryLabels[category] ?? category,
                      style: AppTextStyles.body14(
                        color: AppColors.textPrimary,
                      ).copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final key in bucketed[category]!)
                          PermissionKeyChip(permissionKey: key),
                      ],
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Hierarchy tab
// ---------------------------------------------------------------------

const String _orgUnitMoveGatedCopy =
    'Org-unit moves are gated until schema, proxy, and audit support ships.';

class _HierarchyTab extends StatelessWidget {
  const _HierarchyTab({
    required this.orgUnits,
    required this.locations,
    required this.editingEnabled,
    required this.onAddChildOrgUnit,
    required this.onMoveLocation,
  });

  final List<OrgUnitAdminNode> orgUnits;
  final List<HierarchyLocationLeaf> locations;
  final bool editingEnabled;
  final ValueChanged<OrgUnitAdminNode> onAddChildOrgUnit;
  final ValueChanged<HierarchyLocationLeaf> onMoveLocation;

  @override
  Widget build(BuildContext context) {
    final byParent = <String?, List<OrgUnitAdminNode>>{};
    for (final unit in orgUnits) {
      byParent
          .putIfAbsent(unit.parentOrgUnitId, () => <OrgUnitAdminNode>[])
          .add(unit);
    }
    for (final list in byParent.values) {
      list.sort((a, b) => a.name.compareTo(b.name));
    }
    final locationsByOrgUnit = <String, List<HierarchyLocationLeaf>>{};
    for (final loc in locations) {
      locationsByOrgUnit
          .putIfAbsent(loc.orgUnitId, () => <HierarchyLocationLeaf>[])
          .add(loc);
    }
    for (final list in locationsByOrgUnit.values) {
      list.sort((a, b) => a.name.compareTo(b.name));
    }
    final roots = byParent[null] ?? const <OrgUnitAdminNode>[];
    return SingleChildScrollView(
      key: const Key('admin_rhs_hierarchy_tab'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdminStatStrip(
            items: <AdminStatItem>[
              AdminStatItem(
                label: 'Org units',
                value: orgUnits.length.toString(),
                icon: Icons.account_tree_outlined,
                tone: AppColors.peacock,
              ),
              AdminStatItem(
                label: 'Locations',
                value: locations.length.toString(),
                icon: Icons.location_on_outlined,
                tone: AppColors.sunset,
              ),
            ],
          ),
          const SizedBox(height: 16),
          AdminCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Org units and locations',
                        style: AppTextStyles.sectionTitle(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '${orgUnits.length} unit'
                      '${orgUnits.length == 1 ? '' : 's'}, '
                      '${locations.length} location'
                      '${locations.length == 1 ? '' : 's'}',
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Location moves are audit-logged with your name and reason. '
                  'Use Add child to create a new region, district, or '
                  'location group under an existing unit. '
                  'Org-unit moves are gated until schema, proxy, and audit '
                  'support ships.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                if (roots.isEmpty)
                  Text(
                    'No org units yet for this operator.',
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  )
                else
                  for (final root in roots)
                    _OrgUnitNodeRow(
                      node: root,
                      byParent: byParent,
                      locationsByOrgUnit: locationsByOrgUnit,
                      depth: 0,
                      editingEnabled: editingEnabled,
                      onAddChildOrgUnit: onAddChildOrgUnit,
                      onMoveLocation: onMoveLocation,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OrgUnitNodeRow extends StatelessWidget {
  const _OrgUnitNodeRow({
    required this.node,
    required this.byParent,
    required this.locationsByOrgUnit,
    required this.depth,
    required this.editingEnabled,
    required this.onAddChildOrgUnit,
    required this.onMoveLocation,
  });

  final OrgUnitAdminNode node;
  final Map<String?, List<OrgUnitAdminNode>> byParent;
  final Map<String, List<HierarchyLocationLeaf>> locationsByOrgUnit;
  final int depth;
  final bool editingEnabled;
  final ValueChanged<OrgUnitAdminNode> onAddChildOrgUnit;
  final ValueChanged<HierarchyLocationLeaf> onMoveLocation;

  @override
  Widget build(BuildContext context) {
    final children = byParent[node.orgUnitId] ?? const <OrgUnitAdminNode>[];
    final ownLocations =
        locationsByOrgUnit[node.orgUnitId] ?? const <HierarchyLocationLeaf>[];
    final isRoot = node.parentOrgUnitId == null;
    return Padding(
      padding: EdgeInsets.only(left: depth * 16.0, top: 6, bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.borderSubtle, width: 1),
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          key: Key('admin_rhs_org_unit_${node.orgUnitId}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.account_tree_outlined,
                  size: 14,
                  color: AppColors.textMuted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    node.name,
                    style: AppTextStyles.body14(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (editingEnabled && !isRoot) ...<Widget>[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _orgUnitMoveGatedCopy,
                      key: Key(
                        'admin_rhs_org_unit_move_gated_${node.orgUnitId}',
                      ),
                      textAlign: TextAlign.right,
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ),
                ],
                if (editingEnabled) ...<Widget>[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    key: Key('admin_rhs_org_unit_add_child_${node.orgUnitId}'),
                    onPressed: () => onAddChildOrgUnit(node),
                    style: AdminButtonStyles.secondary(),
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text('Add child'),
                  ),
                ],
              ],
            ),
            for (final loc in ownLocations)
              Padding(
                padding: const EdgeInsets.only(left: 18, top: 6),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.location_on_outlined,
                      size: 14,
                      color: AppColors.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        loc.name,
                        key: Key('admin_rhs_location_${loc.locationId}'),
                        style: AppTextStyles.body13(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    if (editingEnabled)
                      OutlinedButton(
                        key: Key('admin_rhs_location_move_${loc.locationId}'),
                        onPressed: () => onMoveLocation(loc),
                        style: AdminButtonStyles.secondary(),
                        child: const Text('Move'),
                      ),
                  ],
                ),
              ),
            for (final child in children)
              _OrgUnitNodeRow(
                node: child,
                byParent: byParent,
                locationsByOrgUnit: locationsByOrgUnit,
                depth: depth + 1,
                editingEnabled: editingEnabled,
                onAddChildOrgUnit: onAddChildOrgUnit,
                onMoveLocation: onMoveLocation,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Sessions tab
// ---------------------------------------------------------------------

class ActiveSessionsAdminPanel extends StatefulWidget {
  const ActiveSessionsAdminPanel({
    super.key,
    required this.gateway,
    required this.operatorId,
    required this.operatorName,
    required this.actorUserId,
    this.editingEnabled = true,
    this.idempotencyKeyFactory,
  });

  final RolesHierarchySessionsAdminGateway gateway;
  final String operatorId;
  final String operatorName;
  final String actorUserId;
  final bool editingEnabled;
  final String Function()? idempotencyKeyFactory;

  @override
  State<ActiveSessionsAdminPanel> createState() =>
      _ActiveSessionsAdminPanelState();
}

class _ActiveSessionsAdminPanelState extends State<ActiveSessionsAdminPanel> {
  bool _loading = true;
  String? _loadError;
  String? _actionError;
  List<SessionAdminRow> _sessions = const <SessionAdminRow>[];
  int _refreshGeneration = 0;
  int _idempotencyCounter = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant ActiveSessionsAdminPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operatorId != widget.operatorId ||
        oldWidget.gateway != widget.gateway) {
      _refresh();
    }
  }

  String _nextIdempotencyKey(String operation) {
    final factory = widget.idempotencyKeyFactory;
    if (factory != null) return factory();
    _idempotencyCounter += 1;
    return '$operation-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_idempotencyCounter';
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final sessions = await widget.gateway.listSessions(
        operatorId: widget.operatorId,
      );
      if (generation != _refreshGeneration) return;
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _loading = false;
      });
    } on RolesHierarchySessionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } on RolesHierarchySessionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadError = 'Could not load sessions: $error';
        _loading = false;
      });
    }
  }

  Future<String?> _promptAdminReason(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _AdminReasonDialog(title: title),
    );
  }

  Future<void> _runAndRefresh(
    Future<void> Function() action, {
    String? successHint,
  }) async {
    setState(() => _actionError = null);
    try {
      await action();
      await _refresh();
      if (successHint != null && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successHint)));
      }
    } on RolesHierarchySessionsForbiddenException catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } on RolesHierarchySessionsGatewayError catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error.toString());
    }
  }

  Future<void> _onForceLogoutSession(SessionAdminRow row) async {
    if (row.userId == widget.actorUserId) {
      setState(() {
        _actionError = SessionsValidationCopy.cannotRevokeSelf;
      });
      return;
    }
    final reason = await _promptAdminReason(
      'Force logout ${row.userDisplayName}',
    );
    if (reason == null) return;
    await _runAndRefresh(
      () => widget.gateway.forceLogoutSession(
        operatorId: widget.operatorId,
        sessionId: row.sessionId,
        userId: row.userId,
        idempotencyKey: _nextIdempotencyKey('sessions-force-logout'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: reason,
      ),
      successHint: 'Signed out ${row.userDisplayName}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('admin_security_sessions_panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_actionError != null)
          _ErrorBanner(
            key: const Key('admin_security_sessions_action_error'),
            message: _actionError!,
          ),
        _TabLoadBody(
          loading: _loading,
          error: _loadError,
          loadingKey: const Key('admin_security_sessions_loading'),
          errorKey: const Key('admin_security_sessions_load_error'),
          child: _SessionsTab(
            sessions: _sessions,
            editingEnabled: widget.editingEnabled,
            actorUserId: widget.actorUserId,
            onForceLogout: _onForceLogoutSession,
          ),
        ),
      ],
    );
  }
}

class _SessionsTab extends StatelessWidget {
  const _SessionsTab({
    required this.sessions,
    required this.editingEnabled,
    required this.actorUserId,
    required this.onForceLogout,
  });

  final List<SessionAdminRow> sessions;
  final bool editingEnabled;
  final String actorUserId;
  final ValueChanged<SessionAdminRow> onForceLogout;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      key: const Key('admin_rhs_sessions_tab'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AdminStatStrip(
            items: <AdminStatItem>[
              AdminStatItem(
                label: 'Active sessions',
                value: sessions.length.toString(),
                icon: Icons.devices_outlined,
                tone: AppColors.peacock,
              ),
              AdminStatItem(
                label: 'Other users',
                value: sessions
                    .where((row) => row.userId != actorUserId)
                    .length
                    .toString(),
                icon: Icons.logout_outlined,
                tone: AppColors.warning,
              ),
            ],
          ),
          const SizedBox(height: 16),
          AdminCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Active sessions',
                        style: AppTextStyles.sectionTitle(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    Text(
                      '${sessions.length} session'
                      '${sessions.length == 1 ? '' : 's'}',
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Force logout is audit-logged. You cannot sign yourself out '
                  'from this surface.',
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 8),
                if (sessions.isEmpty)
                  Text(
                    'No active sessions.',
                    style: AppTextStyles.body13(color: AppColors.textMuted),
                  )
                else
                  for (final row in sessions)
                    _SessionRowTile(
                      key: Key('admin_rhs_session_row_${row.sessionId}'),
                      row: row,
                      isOwn: row.userId == actorUserId,
                      editingEnabled: editingEnabled,
                      onForceLogout: onForceLogout,
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionRowTile extends StatelessWidget {
  const _SessionRowTile({
    super.key,
    required this.row,
    required this.isOwn,
    required this.editingEnabled,
    required this.onForceLogout,
  });

  final SessionAdminRow row;
  final bool isOwn;
  final bool editingEnabled;
  final ValueChanged<SessionAdminRow> onForceLogout;

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
                    row.userDisplayName,
                    style: AppTextStyles.body14(
                      color: AppColors.textPrimary,
                    ).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (isOwn)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.backgroundSurface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: AppColors.borderSubtle,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      'Your session',
                      style: AppTextStyles.mono11(color: AppColors.textMuted),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              row.userEmail,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: <Widget>[
                _MetaPill(
                  icon: Icons.devices_outlined,
                  label: row.deviceFingerprint,
                ),
                _MetaPill(
                  icon: Icons.location_city_outlined,
                  label: row.ipGeoCity,
                ),
                _MetaPill(
                  icon: Icons.schedule_outlined,
                  label: 'Active ${_formatRelative(row.lastActiveAt)}',
                ),
              ],
            ),
            if (editingEnabled) ...<Widget>[
              const SizedBox(height: 10),
              OutlinedButton(
                key: Key('admin_rhs_session_force_logout_${row.sessionId}'),
                onPressed: isOwn ? null : () => onForceLogout(row),
                style: AdminButtonStyles.secondary(),
                child: const Text('Force logout'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatRelative(DateTime at) {
    final now = DateTime.now().toUtc();
    final diff = now.difference(at.toUtc());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

// ---------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------

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
              'View only. Ask a super admin if a setting needs to change.',
              style: AppTextStyles.mono11(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({super.key, required this.message});

  final String message;

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
      child: Text(
        message,
        style: AppTextStyles.mono11(color: AppColors.negative),
      ),
    );
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
      key: const Key('admin_rhs_reason_dialog'),
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
              key: const Key('admin_rhs_reason_field'),
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
          key: const Key('admin_rhs_reason_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_reason_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Roles tab dialogs
// ---------------------------------------------------------------------

class EditSeededRoleResult {
  const EditSeededRoleResult({
    required this.permissionKeys,
    required this.adminReason,
  });

  final List<String> permissionKeys;
  final String adminReason;
}

class EditSeededRoleDialog extends StatefulWidget {
  const EditSeededRoleDialog({super.key, required this.initial});

  final RoleAdminRow initial;

  @override
  State<EditSeededRoleDialog> createState() => _EditSeededRoleDialogState();
}

class _EditSeededRoleDialogState extends State<EditSeededRoleDialog> {
  late final _permissionsController = TextEditingController(
    text: widget.initial.permissionKeys.join('\n'),
  );
  final _reasonController = TextEditingController();
  bool _violated = false;

  @override
  void dispose() {
    _permissionsController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) {
      setState(() => _violated = true);
      return;
    }
    final keys = _permissionsController.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    Navigator.of(
      context,
    ).pop(EditSeededRoleResult(permissionKeys: keys, adminReason: reason));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_rhs_edit_seeded_role_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Edit ${roleAdminDisplayLabel(widget.initial)}',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Editing a seeded role requires multi-factor sign-in. '
              'Add one permission key per line.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_edit_seeded_role_keys'),
              controller: _permissionsController,
              minLines: 4,
              maxLines: 10,
              decoration: const InputDecoration(
                labelText: 'Permission keys',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_edit_seeded_role_reason'),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_edit_seeded_role_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class CustomRoleDraft {
  const CustomRoleDraft({
    required this.roleKey,
    required this.displayName,
    required this.description,
    required this.permissionKeys,
    required this.adminReason,
  });

  final String roleKey;
  final String displayName;
  final String description;
  final List<String> permissionKeys;
  final String adminReason;
}

class CreateCustomRoleDialog extends StatefulWidget {
  const CreateCustomRoleDialog({super.key, required this.existingRoleKeys});

  final Set<String> existingRoleKeys;

  @override
  State<CreateCustomRoleDialog> createState() => _CreateCustomRoleDialogState();
}

class _CreateCustomRoleDialogState extends State<CreateCustomRoleDialog> {
  final _displayNameController = TextEditingController();
  final _roleKeyController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _permissionsController = TextEditingController();
  final _reasonController = TextEditingController();
  String? _displayNameError;
  String? _roleKeyError;
  String? _reasonError;

  @override
  void dispose() {
    _displayNameController.dispose();
    _roleKeyController.dispose();
    _descriptionController.dispose();
    _permissionsController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final displayName = _displayNameController.text.trim();
    final roleKey = _roleKeyController.text.trim();
    final reason = _reasonController.text.trim();
    setState(() {
      _displayNameError = displayName.isEmpty
          ? 'Choose a name for this role.'
          : null;
      _roleKeyError = roleKey.isEmpty
          ? 'Choose a key for this role.'
          : widget.existingRoleKeys.contains(roleKey)
          ? 'A role with this key already exists.'
          : null;
      _reasonError = reason.isEmpty ? 'Add a reason before continuing.' : null;
    });
    if (_displayNameError != null ||
        _roleKeyError != null ||
        _reasonError != null) {
      return;
    }
    final keys = _permissionsController.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    Navigator.of(context).pop(
      CustomRoleDraft(
        roleKey: roleKey,
        displayName: displayName,
        description: _descriptionController.text.trim(),
        permissionKeys: keys,
        adminReason: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_rhs_create_custom_role_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text('New custom role', style: AdminButtonStyles.dialogTitleStyle),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const Key('admin_rhs_create_custom_role_name'),
              controller: _displayNameController,
              decoration: InputDecoration(
                labelText: 'Display name',
                border: const OutlineInputBorder(),
                errorText: _displayNameError,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('admin_rhs_create_custom_role_key'),
              controller: _roleKeyController,
              decoration: InputDecoration(
                labelText: 'Role key',
                border: const OutlineInputBorder(),
                errorText: _roleKeyError,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('admin_rhs_create_custom_role_description'),
              controller: _descriptionController,
              minLines: 1,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('admin_rhs_create_custom_role_keys'),
              controller: _permissionsController,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Permission keys (one per line)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('admin_rhs_create_custom_role_reason'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _reasonError,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_create_custom_role_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Create role'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Hierarchy tab dialogs
// ---------------------------------------------------------------------

class _AddOrgUnitResult {
  const _AddOrgUnitResult({
    required this.unitType,
    required this.label,
    required this.name,
    required this.adminReason,
  });

  final String unitType;
  final String label;
  final String name;
  final String adminReason;
}

class _AddChildOrgUnitDialog extends StatefulWidget {
  const _AddChildOrgUnitDialog({
    required this.parent,
    required this.existingNames,
  });

  final OrgUnitAdminNode parent;
  final Set<String> existingNames;

  @override
  State<_AddChildOrgUnitDialog> createState() => _AddChildOrgUnitDialogState();
}

class _AddChildOrgUnitDialogState extends State<_AddChildOrgUnitDialog> {
  String _unitType = 'region';
  final _nameController = TextEditingController();
  final _labelController = TextEditingController();
  final _reasonController = TextEditingController();
  String? _nameError;
  String? _reasonError;

  @override
  void dispose() {
    _nameController.dispose();
    _labelController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _onSubmit() {
    final name = _nameController.text.trim();
    final reason = _reasonController.text.trim();
    setState(() {
      _nameError = name.isEmpty
          ? HierarchyValidationCopy.orgUnitNameEmpty
          : widget.existingNames.contains(name.toLowerCase())
          ? HierarchyValidationCopy.orgUnitNameDuplicate
          : null;
      _reasonError = reason.isEmpty ? 'Add a reason before continuing.' : null;
    });
    if (_nameError != null || _reasonError != null) return;
    final rawLabel = _labelController.text.trim();
    final label = rawLabel.isEmpty ? _sanitiseLabel(name) : rawLabel;
    Navigator.of(context).pop(
      _AddOrgUnitResult(
        unitType: _unitType,
        label: label,
        name: name,
        adminReason: reason,
      ),
    );
  }

  static String _sanitiseLabel(String name) {
    final collapsed = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return collapsed.replaceAll(RegExp(r'^_+|_+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_rhs_add_child_org_unit_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Add child org unit',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Under ${widget.parent.name}',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('admin_rhs_add_org_unit_type'),
              initialValue: _unitType,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Unit type',
                border: OutlineInputBorder(),
              ),
              items: const <DropdownMenuItem<String>>[
                DropdownMenuItem<String>(
                  value: 'region',
                  child: Text('Region'),
                ),
                DropdownMenuItem<String>(
                  value: 'district',
                  child: Text('District'),
                ),
                DropdownMenuItem<String>(
                  value: 'location_group',
                  child: Text('Location group'),
                ),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _unitType = value);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_add_org_unit_name'),
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Display name',
                border: const OutlineInputBorder(),
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_add_org_unit_label'),
              controller: _labelController,
              decoration: const InputDecoration(
                labelText: 'Label (a-z, 0-9, underscore)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_add_org_unit_reason'),
              controller: _reasonController,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: 'Reason',
                border: const OutlineInputBorder(),
                errorText: _reasonError,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('admin_rhs_add_org_unit_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_add_org_unit_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _MoveLocationResult {
  const _MoveLocationResult({
    required this.newOrgUnitId,
    required this.adminReason,
  });

  final String newOrgUnitId;
  final String adminReason;
}

class _MoveLocationDialog extends StatefulWidget {
  const _MoveLocationDialog({required this.leaf, required this.candidates});

  final HierarchyLocationLeaf leaf;
  final List<OrgUnitAdminNode> candidates;

  @override
  State<_MoveLocationDialog> createState() => _MoveLocationDialogState();
}

class _MoveLocationDialogState extends State<_MoveLocationDialog> {
  late String _selectedOrgUnitId = widget.leaf.orgUnitId;
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
    Navigator.of(context).pop(
      _MoveLocationResult(
        newOrgUnitId: _selectedOrgUnitId,
        adminReason: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_rhs_move_location_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Move ${widget.leaf.name}',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DropdownButtonFormField<String>(
              key: const Key('admin_rhs_move_location_org_unit'),
              initialValue: _selectedOrgUnitId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'New org unit',
                border: OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<String>>[
                for (final candidate in widget.candidates)
                  DropdownMenuItem<String>(
                    value: candidate.orgUnitId,
                    child: Text(candidate.name),
                  ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _selectedOrgUnitId = v);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_move_location_reason'),
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('admin_rhs_move_location_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Move'),
        ),
      ],
    );
  }
}
