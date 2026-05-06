// Phase 11A.13 - F&F Operations Console "Roles + Hierarchy +
// Sessions" inspect surface.
//
// Cross-operator inspect with three tabs (Roles / Hierarchy /
// Sessions) for the F&F admin to inspect and audit-edit role catalog,
// org-unit hierarchy, and active sessions for the picked operator.
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
    length: 3,
    vsync: this,
  );

  bool _loading = true;
  String? _loadError;
  String? _actionError;

  List<RoleAdminRow> _roles = const <RoleAdminRow>[];
  List<OrgUnitAdminNode> _orgUnits = const <OrgUnitAdminNode>[];
  List<HierarchyLocationLeaf> _locations = const <HierarchyLocationLeaf>[];
  List<SessionAdminRow> _sessions = const <SessionAdminRow>[];
  int _refreshGeneration = 0;

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
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final generation = ++_refreshGeneration;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final operatorId = widget.pickedOperator.operatorId;
      final results = await Future.wait<Object>([
        widget.gateway.listRoles(operatorId: operatorId),
        widget.gateway.listOrgUnits(operatorId: operatorId),
        widget.gateway.listHierarchyLocations(operatorId: operatorId),
        widget.gateway.listSessions(operatorId: operatorId),
      ]);
      if (generation != _refreshGeneration) return;
      final roles = results[0] as List<RoleAdminRow>;
      final orgUnits = results[1] as List<OrgUnitAdminNode>;
      final locations = results[2] as List<HierarchyLocationLeaf>;
      final sessions = results[3] as List<SessionAdminRow>;
      if (!mounted) return;
      setState(() {
        _roles = roles;
        _orgUnits = orgUnits;
        _locations = locations;
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
        _loadError = 'Could not load: $error';
        _loading = false;
      });
    }
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

  Future<String?> _promptAdminReason(String title) async {
    return showDialog<String>(
      context: context,
      builder: (_) => _AdminReasonDialog(title: title),
    );
  }

  // --- Roles tab actions -------------------------------------------------

  Future<void> _onEditSeededRole(RoleAdminRow row) async {
    if (!widget.canEditSeededRoles) return;
    final result = await showDialog<_EditSeededRoleResult>(
      context: context,
      builder: (_) => _EditSeededRoleDialog(initial: row),
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
      successHint: 'Updated ${roleAdminDisplayLabel(row)}',
    );
  }

  Future<void> _onCreateCustomRole() async {
    final result = await showDialog<_CustomRoleDraft>(
      context: context,
      builder: (_) => _CreateCustomRoleDialog(
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
      successHint: 'Deleted ${roleAdminDisplayLabel(row)}',
    );
  }

  // --- Hierarchy tab actions --------------------------------------------

  Future<void> _onMoveOrgUnit(OrgUnitAdminNode node) async {
    final candidates = <OrgUnitAdminNode?>[
      null,
      ..._orgUnits.where((u) => u.orgUnitId != node.orgUnitId),
    ];
    final result = await showDialog<_MoveOrgUnitResult>(
      context: context,
      builder: (_) => _MoveOrgUnitDialog(node: node, candidates: candidates),
    );
    if (result == null) return;
    await _runAndRefresh(
      () => widget.gateway.moveOrgUnit(
        operatorId: widget.pickedOperator.operatorId,
        orgUnitId: node.orgUnitId,
        newParentOrgUnitId: result.newParentOrgUnitId,
        idempotencyKey: _nextIdempotencyKey('hierarchy-move-org-unit'),
        actorUserId: widget.actorUserId,
        actorIsForgeAdmin: widget.editingEnabled,
        adminReason: result.adminReason,
      ),
      successHint: 'Moved ${node.name}',
    );
  }

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
      successHint: 'Moved ${leaf.name}',
    );
  }

  // --- Sessions tab actions ---------------------------------------------

  Future<void> _onForceLogoutSession(SessionAdminRow row) async {
    if (row.userId == widget.actorUserId) {
      // Defence in depth alongside the gateway throw + the disabled
      // button; render the validation copy verbatim.
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
        operatorId: widget.pickedOperator.operatorId,
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
              title: 'Roles, hierarchy, and sessions',
              subtitle:
                  'Inspect and audit-edit the role catalog, org-unit '
                  'hierarchy, and active sessions for '
                  '${widget.pickedOperator.operatorBusinessName}. '
                  'Every change you make here is recorded with your '
                  'name and reason.',
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
            TabBar(
              key: const Key('admin_rhs_tab_bar'),
              controller: _tabController,
              labelColor: AppColors.textPrimary,
              unselectedLabelColor: AppColors.textMuted,
              indicatorColor: AppColors.sunset,
              tabs: const <Widget>[
                Tab(key: Key('admin_rhs_tab_roles'), text: 'Roles'),
                Tab(key: Key('admin_rhs_tab_hierarchy'), text: 'Hierarchy'),
                Tab(key: Key('admin_rhs_tab_sessions'), text: 'Sessions'),
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
    if (_loading) {
      return const Center(
        key: Key('admin_rhs_loading'),
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
        key: const Key('admin_rhs_load_error'),
        message: _loadError!,
      );
    }
    return TabBarView(
      controller: _tabController,
      children: <Widget>[
        _RolesTab(
          roles: _roles,
          editingEnabled: widget.editingEnabled,
          canEditSeededRoles: widget.canEditSeededRoles,
          onEditSeeded: _onEditSeededRole,
          onCreateCustom: _onCreateCustomRole,
          onDeleteCustom: _onDeleteCustomRole,
        ),
        _HierarchyTab(
          orgUnits: _orgUnits,
          locations: _locations,
          editingEnabled: widget.editingEnabled,
          onMoveOrgUnit: _onMoveOrgUnit,
          onMoveLocation: _onMoveLocation,
        ),
        _SessionsTab(
          sessions: _sessions,
          editingEnabled: widget.editingEnabled,
          actorUserId: widget.actorUserId,
          onForceLogout: _onForceLogoutSession,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------
// Roles tab
// ---------------------------------------------------------------------

class _RolesTab extends StatelessWidget {
  const _RolesTab({
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
          const _PermissionExplainerCard(),
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

class _HierarchyTab extends StatelessWidget {
  const _HierarchyTab({
    required this.orgUnits,
    required this.locations,
    required this.editingEnabled,
    required this.onMoveOrgUnit,
    required this.onMoveLocation,
  });

  final List<OrgUnitAdminNode> orgUnits;
  final List<HierarchyLocationLeaf> locations;
  final bool editingEnabled;
  final ValueChanged<OrgUnitAdminNode> onMoveOrgUnit;
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
      child: AdminCard(
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
                  '${orgUnits.length} unit${orgUnits.length == 1 ? '' : 's'}, '
                  '${locations.length} location'
                  '${locations.length == 1 ? '' : 's'}',
                  style: AppTextStyles.mono11(color: AppColors.textMuted),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Read-mostly view. Move actions are audit-logged with your '
              'name and reason.',
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
                  onMoveOrgUnit: onMoveOrgUnit,
                  onMoveLocation: onMoveLocation,
                ),
          ],
        ),
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
    required this.onMoveOrgUnit,
    required this.onMoveLocation,
  });

  final OrgUnitAdminNode node;
  final Map<String?, List<OrgUnitAdminNode>> byParent;
  final Map<String, List<HierarchyLocationLeaf>> locationsByOrgUnit;
  final int depth;
  final bool editingEnabled;
  final ValueChanged<OrgUnitAdminNode> onMoveOrgUnit;
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
                if (editingEnabled && !isRoot)
                  OutlinedButton(
                    key: Key('admin_rhs_org_unit_move_${node.orgUnitId}'),
                    onPressed: () => onMoveOrgUnit(node),
                    style: AdminButtonStyles.secondary(),
                    child: const Text('Move'),
                  ),
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
                onMoveOrgUnit: onMoveOrgUnit,
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
      child: AdminCard(
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
              'Every session for every member of this operator. '
              'Forcing a sign-out is audit-logged with your name and reason. '
              'You cannot sign yourself out from this surface.',
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

class _EditSeededRoleResult {
  const _EditSeededRoleResult({
    required this.permissionKeys,
    required this.adminReason,
  });

  final List<String> permissionKeys;
  final String adminReason;
}

class _EditSeededRoleDialog extends StatefulWidget {
  const _EditSeededRoleDialog({required this.initial});

  final RoleAdminRow initial;

  @override
  State<_EditSeededRoleDialog> createState() => _EditSeededRoleDialogState();
}

class _EditSeededRoleDialogState extends State<_EditSeededRoleDialog> {
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
    ).pop(_EditSeededRoleResult(permissionKeys: keys, adminReason: reason));
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

class _CustomRoleDraft {
  const _CustomRoleDraft({
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

class _CreateCustomRoleDialog extends StatefulWidget {
  const _CreateCustomRoleDialog({required this.existingRoleKeys});

  final Set<String> existingRoleKeys;

  @override
  State<_CreateCustomRoleDialog> createState() =>
      _CreateCustomRoleDialogState();
}

class _CreateCustomRoleDialogState extends State<_CreateCustomRoleDialog> {
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
      _CustomRoleDraft(
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

class _MoveOrgUnitResult {
  const _MoveOrgUnitResult({
    required this.newParentOrgUnitId,
    required this.adminReason,
  });

  final String? newParentOrgUnitId;
  final String adminReason;
}

class _MoveOrgUnitDialog extends StatefulWidget {
  const _MoveOrgUnitDialog({required this.node, required this.candidates});

  final OrgUnitAdminNode node;
  final List<OrgUnitAdminNode?> candidates;

  @override
  State<_MoveOrgUnitDialog> createState() => _MoveOrgUnitDialogState();
}

class _MoveOrgUnitDialogState extends State<_MoveOrgUnitDialog> {
  late String? _selectedParentId = widget.node.parentOrgUnitId;
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
      _MoveOrgUnitResult(
        newParentOrgUnitId: _selectedParentId,
        adminReason: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('admin_rhs_move_org_unit_dialog'),
      backgroundColor: AppColors.backgroundSurface,
      title: Text(
        'Move ${widget.node.name}',
        style: AdminButtonStyles.dialogTitleStyle,
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            DropdownButtonFormField<String?>(
              key: const Key('admin_rhs_move_org_unit_parent'),
              initialValue: _selectedParentId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'New parent',
                border: OutlineInputBorder(),
              ),
              items: <DropdownMenuItem<String?>>[
                for (final candidate in widget.candidates)
                  DropdownMenuItem<String?>(
                    value: candidate?.orgUnitId,
                    child: Text(candidate?.name ?? 'Top level'),
                  ),
              ],
              onChanged: (v) => setState(() => _selectedParentId = v),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('admin_rhs_move_org_unit_reason'),
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
          key: const Key('admin_rhs_move_org_unit_submit'),
          style: AdminButtonStyles.primary,
          onPressed: _onSubmit,
          child: const Text('Move'),
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
