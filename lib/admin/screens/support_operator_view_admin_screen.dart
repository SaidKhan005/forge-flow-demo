// Consolidated F&F support workspace.
//
// This screen does not create a parallel operator console. It hosts
// the existing admin-backed People, Access, Audit/Security, and
// Vendor surfaces after the admin has selected one business/location
// scope. Reads and mutations therefore keep using `/v1/admin/*`
// routes with the existing forge_admin reason/audit gates.

import 'package:flutter/material.dart';

import '../../integrations/ui/vendor_connections/vendor_connections_gateway.dart';
import '../../theme/app_theme.dart';
import '../../theme/scope_icons.dart';
import '../admin_button_styles.dart';
import '../services/audited_support_actions_admin_gateway.dart';
import '../services/members_admin_gateway.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';
import '../widgets/admin_responsive_layout.dart';
import 'audited_support_actions_admin_screen.dart';
import 'members_admin_screen.dart';
import 'operator_picker_screen.dart';
import 'roles_hierarchy_sessions_admin_screen.dart';
import 'vendor_connections/vendor_connections_admin_mount.dart';

class SupportOperatorViewAdminScreen extends StatelessWidget {
  const SupportOperatorViewAdminScreen({
    super.key,
    required this.membersGateway,
    required this.rolesGateway,
    required this.supportGateway,
    this.vendorConnectionsGateway,
    required this.actorUserId,
    required this.pickedOperator,
    this.editingEnabled = true,
    this.canEditSeededRoles = false,
    this.canResetMfaFactors = false,
    this.canIssuePairedErasure = false,
    this.canExportAuditLog = false,
    this.onChangeOperator,
  });

  final MembersAdminGateway membersGateway;
  final RolesHierarchySessionsAdminGateway rolesGateway;
  final AuditedSupportActionsAdminGateway supportGateway;
  final VendorConnectionsGateway? vendorConnectionsGateway;
  final String actorUserId;
  final OperatorPickerResult pickedOperator;
  final bool editingEnabled;
  final bool canEditSeededRoles;
  final bool canResetMfaFactors;
  final bool canIssuePairedErasure;
  final bool canExportAuditLog;
  final VoidCallback? onChangeOperator;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Container(
        key: const Key('admin_support_operator_view_screen'),
        color: AppColors.backgroundDeep,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _header(),
              const SizedBox(height: 14),
              _statStrip(),
              if (!editingEnabled) ...<Widget>[
                const SizedBox(height: 12),
                const _SupportReadOnlyBanner(),
              ],
              const SizedBox(height: 12),
              _tabs(),
              const SizedBox(height: 12),
              Expanded(child: _tabViews()),
            ],
          ),
        ),
      ),
    );
  }

  AdminPageHeader _header() {
    return AdminPageHeader(
      title: 'Support workspace',
      subtitle:
          '${pickedOperator.operatorBusinessName}: one view for people, access, security, audit, and vendors.',
      trailing: onChangeOperator == null
          ? null
          : OutlinedButton.icon(
              key: const Key('admin_support_operator_view_change_business'),
              onPressed: onChangeOperator,
              style: AdminButtonStyles.secondary(),
              icon: const Icon(Icons.swap_horiz, size: 16),
              label: const Text('Change business'),
            ),
    );
  }

  AdminStatStrip _statStrip() {
    return AdminStatStrip(
      items: <AdminStatItem>[
        AdminStatItem(
          label: 'Business',
          value: pickedOperator.operatorBusinessName,
          icon: scopeIcon(kind: ScopeEntityKind.business),
          tone: AppColors.sunset,
        ),
        AdminStatItem(
          label: 'Location',
          value: pickedOperator.locationName,
          icon: Icons.location_on_outlined,
          tone: AppColors.peacock,
        ),
        AdminStatItem(
          label: 'Admin mode',
          value: editingEnabled ? 'Forge admin' : 'Read-only',
          icon: editingEnabled
              ? Icons.admin_panel_settings_outlined
              : Icons.visibility_outlined,
          tone: editingEnabled ? AppColors.positive : AppColors.textMuted,
        ),
        const AdminStatItem(
          label: 'Backend path',
          value: 'Admin routes',
          icon: Icons.route_outlined,
          tone: AppColors.ocean,
        ),
      ],
    );
  }

  Widget _tabs() {
    return Container(
      key: const Key('admin_support_operator_view_tabs'),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const TabBar(
        isScrollable: true,
        labelColor: AppColors.textPrimary,
        unselectedLabelColor: AppColors.textSecondary,
        indicatorColor: AppColors.sunsetDark,
        tabs: <Widget>[
          Tab(icon: Icon(Icons.people_alt_outlined, size: 18), text: 'People'),
          Tab(
            icon: Icon(Icons.account_tree_outlined, size: 18),
            text: 'Access',
          ),
          Tab(
            icon: Icon(Icons.security_outlined, size: 18),
            text: 'Security & audit',
          ),
          Tab(icon: Icon(Icons.link_outlined, size: 18), text: 'Vendors'),
        ],
      ),
    );
  }

  Widget _tabViews() {
    return TabBarView(
      children: <Widget>[
        MembersAdminScreen(
          gateway: membersGateway,
          rolesGateway: rolesGateway,
          actorUserId: actorUserId,
          pickedOperator: pickedOperator,
          editingEnabled: editingEnabled,
          canEditSeededRoles: canEditSeededRoles,
          onChangeOperator: onChangeOperator,
        ),
        RolesHierarchySessionsAdminScreen(
          gateway: rolesGateway,
          actorUserId: actorUserId,
          pickedOperator: pickedOperator,
          editingEnabled: editingEnabled,
          canEditSeededRoles: canEditSeededRoles,
          onChangeOperator: onChangeOperator,
        ),
        AuditedSupportActionsAdminScreen(
          gateway: supportGateway,
          actorUserId: actorUserId,
          pickedOperator: pickedOperator,
          editingEnabled: editingEnabled,
          canResetMfaFactors: canResetMfaFactors,
          canIssuePairedErasure: canIssuePairedErasure,
          canExportAuditLog: canExportAuditLog,
          onChangeOperator: onChangeOperator,
        ),
        VendorConnectionsAdminMount(
          operatorId: pickedOperator.operatorId,
          locationId: pickedOperator.locationId,
          locationName: pickedOperator.locationName,
          gateway: vendorConnectionsGateway,
          canMutate: editingEnabled,
          embedded: true,
        ),
      ],
    );
  }
}

class _SupportReadOnlyBanner extends StatelessWidget {
  const _SupportReadOnlyBanner();

  @override
  Widget build(BuildContext context) {
    return AdminCard(
      key: const Key('admin_support_operator_view_readonly_banner'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(
            Icons.visibility_outlined,
            size: 18,
            color: AppColors.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'This Forge & Flow staff role can inspect the scoped business, '
              'but mutation controls stay disabled until a forge_admin role '
              'with the required permission claim opens the workspace.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
