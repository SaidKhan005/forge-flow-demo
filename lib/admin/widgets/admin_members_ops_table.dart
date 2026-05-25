import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_info_button.dart';
import 'package:forge_and_flow/widgets/console/console_section_heading.dart';

import '../../theme/app_theme.dart';
import '../services/members_admin_gateway.dart';

typedef AdminMemberAction = Future<void> Function(MemberAdminRow row);
typedef AdminInviteAction = Future<void> Function(MemberInviteRow invite);

class AdminMembersOpsTable extends StatelessWidget {
  const AdminMembersOpsTable({
    super.key,
    required this.rows,
    required this.editingEnabled,
    required this.busyUserIds,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
    required this.onEditDisplayName,
  });

  final List<MemberAdminRow> rows;
  final bool editingEnabled;
  final Set<String> busyUserIds;
  final AdminMemberAction onSuspend;
  final AdminMemberAction onReactivate;
  final AdminMemberAction onSoftDelete;
  final AdminMemberAction onResetPassword;
  final AdminMemberAction onResetMfa;
  final AdminMemberAction onEditDisplayName;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Container(
        key: const Key('admin_members_empty_state'),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.backgroundSurface,
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
              'Try clearing a filter or use Invite member to add someone '
              'new to the team.',
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        return Container(
          key: const Key('admin_members_table'),
          decoration: BoxDecoration(
            color: AppColors.backgroundSurface,
            border: Border.all(color: AppColors.borderSubtle, width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!compact) const _MembersTableHeader(),
              for (var i = 0; i < rows.length; i++) ...<Widget>[
                if (i > 0 || !compact)
                  const Divider(
                    height: 1,
                    thickness: 1,
                    color: AppColors.borderSubtle,
                  ),
                if (compact)
                  _MembersCompactCard(
                    row: rows[i],
                    editingEnabled: editingEnabled,
                    busy: busyUserIds.contains(rows[i].userId),
                    onEdit: onEditDisplayName,
                    onSuspend: onSuspend,
                    onReactivate: onReactivate,
                    onSoftDelete: onSoftDelete,
                    onResetPassword: onResetPassword,
                    onResetMfa: onResetMfa,
                  )
                else
                  _MembersTableRow(
                    row: rows[i],
                    editingEnabled: editingEnabled,
                    busy: busyUserIds.contains(rows[i].userId),
                    onEdit: onEditDisplayName,
                    onSuspend: onSuspend,
                    onReactivate: onReactivate,
                    onSoftDelete: onSoftDelete,
                    onResetPassword: onResetPassword,
                    onResetMfa: onResetMfa,
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class AdminMembersPaginationBar extends StatelessWidget {
  const AdminMembersPaginationBar({
    super.key,
    required this.pageIndex,
    required this.pageSize,
    required this.totalRows,
    required this.onPrevious,
    required this.onNext,
  });

  final int pageIndex;
  final int pageSize;
  final int totalRows;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final start = totalRows == 0 ? 0 : pageIndex * pageSize + 1;
    final end = ((pageIndex + 1) * pageSize).clamp(0, totalRows);
    final canPrev = pageIndex > 0;
    final canNext = end < totalRows;
    return Container(
      key: const Key('admin_members_pagination'),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Row(
        children: <Widget>[
          Text(
            totalRows == 0
                ? 'No members'
                : 'Showing $start to $end of $totalRows',
            style: AppTextStyles.mono10(color: AppColors.textMuted),
          ),
          const Spacer(),
          IconButton(
            key: const Key('admin_members_pagination_prev'),
            onPressed: canPrev ? onPrevious : null,
            icon: const Icon(Icons.chevron_left, size: 18),
            color: AppColors.sunsetDark,
            disabledColor: AppColors.borderSubtle,
            tooltip: 'Previous page',
          ),
          IconButton(
            key: const Key('admin_members_pagination_next'),
            onPressed: canNext ? onNext : null,
            icon: const Icon(Icons.chevron_right, size: 18),
            color: AppColors.sunsetDark,
            disabledColor: AppColors.borderSubtle,
            tooltip: 'Next page',
          ),
        ],
      ),
    );
  }
}

class AdminMembersInvitesPanel extends StatelessWidget {
  const AdminMembersInvitesPanel({
    super.key,
    required this.invites,
    required this.editingEnabled,
    required this.busyInviteIds,
    required this.onCancel,
  });

  final List<MemberInviteRow> invites;
  final bool editingEnabled;
  final Set<String> busyInviteIds;
  final AdminInviteAction onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_members_invites_panel'),
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const _PendingInvitesHeading(),
          const SizedBox(height: 10),
          for (final invite in invites) _buildInviteRow(invite),
        ],
      ),
    );
  }

  Widget _buildInviteRow(MemberInviteRow invite) {
    return Padding(
      key: Key('admin_members_invite_row_${invite.inviteId}'),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          _InviteTextCell(flex: 4, text: invite.email),
          _InviteTextCell(flex: 2, text: memberRoleLabel(invite.roleKey)),
          _InviteTextCell(flex: 2, text: _inviteScopeLabel(invite)),
          if (editingEnabled)
            _InviteCancelCell(
              invite: invite,
              busy: busyInviteIds.contains(invite.inviteId),
              onCancel: onCancel,
            ),
        ],
      ),
    );
  }
}

class _PendingInvitesHeading extends StatelessWidget {
  const _PendingInvitesHeading();

  @override
  Widget build(BuildContext context) {
    return OperatorWebSectionHeading(
      title: 'Pending invites',
      trailing: OperatorWebInfoButton(
        title: 'Pending invites',
        tooltip: 'Pending invites',
        body: Text(
          'Invites your team has sent that the new teammate has not '
          'accepted yet.',
          style: AppTextStyles.body13(color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

class _InviteTextCell extends StatelessWidget {
  const _InviteTextCell({required this.flex, required this.text});

  final int flex;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(
        text,
        style: AppTextStyles.body13(color: AppColors.textPrimary),
      ),
    );
  }
}

class _InviteCancelCell extends StatelessWidget {
  const _InviteCancelCell({
    required this.invite,
    required this.busy,
    required this.onCancel,
  });

  final MemberInviteRow invite;
  final bool busy;
  final AdminInviteAction onCancel;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 88,
      child: Align(
        alignment: Alignment.centerRight,
        child: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sunsetDark,
                ),
              )
            : TextButton(
                key: Key('admin_members_invite_cancel_${invite.inviteId}'),
                onPressed: () => onCancel(invite),
                child: const Text('Cancel'),
              ),
      ),
    );
  }
}

class _MembersTableHeader extends StatelessWidget {
  const _MembersTableHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: const BoxDecoration(
        color: AppColors.cardGlow,
        border: Border(
          bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
        ),
      ),
      child: Row(
        children: <Widget>[
          _HeaderCell(label: 'Member', flex: 4),
          _HeaderCell(label: 'Role', flex: 2),
          _HeaderCell(label: 'Location', flex: 2),
          _HeaderCell(label: 'Status', flex: 2),
          _HeaderCell(label: 'Two-factor sign-in', flex: 2),
          const SizedBox(width: 112),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label, required this.flex});

  final String label;
  final int flex;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: flex,
      child: Text(
        label,
        style: AppTextStyles.mono10(color: AppColors.textMuted),
      ),
    );
  }
}

class _MembersTableRow extends StatelessWidget {
  const _MembersTableRow({
    required this.row,
    required this.editingEnabled,
    required this.busy,
    required this.onEdit,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
  });

  final MemberAdminRow row;
  final bool editingEnabled;
  final bool busy;
  final AdminMemberAction onEdit;
  final AdminMemberAction onSuspend;
  final AdminMemberAction onReactivate;
  final AdminMemberAction onSoftDelete;
  final AdminMemberAction onResetPassword;
  final AdminMemberAction onResetMfa;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_members_row_${row.userId}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          _MemberNameCell(row: row),
          _TextCell(label: _roleLabel(row)),
          _TextCell(label: _locationLabel(row)),
          Expanded(flex: 2, child: _StatusChip(status: row.status)),
          Expanded(
            flex: 2,
            child: Text(
              row.mfaEnrolled ? 'On' : 'Off',
              style: AppTextStyles.body13(
                color: row.mfaEnrolled
                    ? AppColors.positive
                    : AppColors.textSecondary,
              ),
            ),
          ),
          _MembersRowActionsButton(
            row: row,
            editingEnabled: editingEnabled,
            busy: busy,
            onEdit: onEdit,
            onSuspend: onSuspend,
            onReactivate: onReactivate,
            onSoftDelete: onSoftDelete,
            onResetPassword: onResetPassword,
            onResetMfa: onResetMfa,
          ),
        ],
      ),
    );
  }
}

class _MemberNameCell extends StatelessWidget {
  const _MemberNameCell({required this.row});

  final MemberAdminRow row;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            row.displayName.isEmpty ? row.email : row.displayName,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          const SizedBox(height: 2),
          Text(
            row.email,
            style: AppTextStyles.body12(color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _TextCell extends StatelessWidget {
  const _TextCell({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      flex: 2,
      child: Text(
        label,
        style: AppTextStyles.body13(color: AppColors.textPrimary),
      ),
    );
  }
}

class _MembersCompactCard extends StatelessWidget {
  const _MembersCompactCard({
    required this.row,
    required this.editingEnabled,
    required this.busy,
    required this.onEdit,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
  });

  final MemberAdminRow row;
  final bool editingEnabled;
  final bool busy;
  final AdminMemberAction onEdit;
  final AdminMemberAction onSuspend;
  final AdminMemberAction onReactivate;
  final AdminMemberAction onSoftDelete;
  final AdminMemberAction onResetPassword;
  final AdminMemberAction onResetMfa;

  @override
  Widget build(BuildContext context) {
    final displayName = row.displayName.isEmpty ? row.email : row.displayName;
    return Container(
      key: Key('admin_members_row_${row.userId}'),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        displayName,
                        style: AppTextStyles.body13(
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusChip(status: row.status),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  row.email,
                  style: AppTextStyles.body12(color: AppColors.textMuted),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: <Widget>[
                    _MemberMetaChip(
                      icon: Icons.badge_outlined,
                      label: _roleLabel(row),
                    ),
                    _MemberMetaChip(
                      icon: Icons.storefront_outlined,
                      label: _locationLabel(row),
                    ),
                    _MemberMetaChip(
                      icon: Icons.verified_user_outlined,
                      label: row.mfaEnrolled ? 'MFA on' : 'MFA off',
                      color: row.mfaEnrolled
                          ? AppColors.positive
                          : AppColors.textSecondary,
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _MembersRowActionsButton(
            row: row,
            editingEnabled: editingEnabled,
            busy: busy,
            onEdit: onEdit,
            onSuspend: onSuspend,
            onReactivate: onReactivate,
            onSoftDelete: onSoftDelete,
            onResetPassword: onResetPassword,
            onResetMfa: onResetMfa,
          ),
        ],
      ),
    );
  }
}

class _MemberMetaChip extends StatelessWidget {
  const _MemberMetaChip({
    required this.icon,
    required this.label,
    this.color = AppColors.textSecondary,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.cardGlow,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(label, style: AppTextStyles.mono10(color: color)),
        ],
      ),
    );
  }
}

class _MembersRowActionsButton extends StatelessWidget {
  const _MembersRowActionsButton({
    required this.row,
    required this.editingEnabled,
    required this.busy,
    required this.onEdit,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
  });

  final MemberAdminRow row;
  final bool editingEnabled;
  final bool busy;
  final AdminMemberAction onEdit;
  final AdminMemberAction onSuspend;
  final AdminMemberAction onReactivate;
  final AdminMemberAction onSoftDelete;
  final AdminMemberAction onResetPassword;
  final AdminMemberAction onResetMfa;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const _RowActionsBusyIndicator();
    }
    if (!editingEnabled || row.status == MemberStatus.softDeleted) {
      return const SizedBox(width: 112);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _RowEditButton(row: row, onEdit: onEdit),
        const SizedBox(width: 4),
        _RowOverflowMenu(
          row: row,
          onSuspend: onSuspend,
          onReactivate: onReactivate,
          onSoftDelete: onSoftDelete,
          onResetPassword: onResetPassword,
          onResetMfa: onResetMfa,
        ),
      ],
    );
  }
}

class _RowActionsBusyIndicator extends StatelessWidget {
  const _RowActionsBusyIndicator();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 112,
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sunsetDark,
          ),
        ),
      ),
    );
  }
}

class _RowEditButton extends StatelessWidget {
  const _RowEditButton({required this.row, required this.onEdit});

  final MemberAdminRow row;
  final AdminMemberAction onEdit;

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      key: Key('admin_members_row_edit_${row.userId}'),
      icon: const Icon(Icons.edit_outlined, size: 16),
      label: const Text('Edit'),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.sunsetDark,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: () => onEdit(row),
    );
  }
}

class _RowOverflowMenu extends StatelessWidget {
  const _RowOverflowMenu({
    required this.row,
    required this.onSuspend,
    required this.onReactivate,
    required this.onSoftDelete,
    required this.onResetPassword,
    required this.onResetMfa,
  });

  final MemberAdminRow row;
  final AdminMemberAction onSuspend;
  final AdminMemberAction onReactivate;
  final AdminMemberAction onSoftDelete;
  final AdminMemberAction onResetPassword;
  final AdminMemberAction onResetMfa;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: PopupMenuButton<_MembersRowAction>(
        key: Key('admin_members_row_actions_${row.userId}'),
        tooltip: 'More actions',
        padding: EdgeInsets.zero,
        iconSize: 18,
        icon: const Icon(Icons.more_vert, size: 18),
        onSelected: _handleSelected,
        itemBuilder: (_) => _menuItems(row.status == MemberStatus.suspended),
      ),
    );
  }

  void _handleSelected(_MembersRowAction action) {
    switch (action) {
      case _MembersRowAction.suspend:
        onSuspend(row);
      case _MembersRowAction.reactivate:
        onReactivate(row);
      case _MembersRowAction.softDelete:
        onSoftDelete(row);
      case _MembersRowAction.resetPassword:
        onResetPassword(row);
      case _MembersRowAction.resetMfa:
        onResetMfa(row);
    }
  }
}

List<PopupMenuEntry<_MembersRowAction>> _menuItems(bool isSuspended) {
  return <PopupMenuEntry<_MembersRowAction>>[
    if (!isSuspended)
      const PopupMenuItem<_MembersRowAction>(
        key: Key('members_row_action_suspend'),
        value: _MembersRowAction.suspend,
        child: Text('Suspend'),
      ),
    if (isSuspended)
      const PopupMenuItem<_MembersRowAction>(
        key: Key('members_row_action_reactivate'),
        value: _MembersRowAction.reactivate,
        child: Text('Reactivate'),
      ),
    const PopupMenuItem<_MembersRowAction>(
      key: Key('members_row_action_reset_password'),
      value: _MembersRowAction.resetPassword,
      child: Text('Reset password'),
    ),
    const PopupMenuItem<_MembersRowAction>(
      key: Key('members_row_action_reset_mfa'),
      value: _MembersRowAction.resetMfa,
      child: Text('Reset two-factor sign-in'),
    ),
    const PopupMenuItem<_MembersRowAction>(
      key: Key('members_row_action_soft_delete'),
      value: _MembersRowAction.softDelete,
      child: Text('Remove from team'),
    ),
  ];
}

enum _MembersRowAction {
  suspend,
  reactivate,
  softDelete,
  resetPassword,
  resetMfa,
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final MemberStatus status;

  @override
  Widget build(BuildContext context) {
    final tone = _toneFor(status);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: tone.withValues(alpha: 0.45), width: 1),
        ),
        child: Text(_labelFor(status), style: AppTextStyles.mono8(color: tone)),
      ),
    );
  }

  static String _labelFor(MemberStatus status) {
    switch (status) {
      case MemberStatus.active:
        return 'Active';
      case MemberStatus.suspended:
        return 'Suspended';
      case MemberStatus.dormant30:
        return 'Dormant';
      case MemberStatus.softDeleted:
        return 'Removed';
    }
  }

  static Color _toneFor(MemberStatus status) {
    switch (status) {
      case MemberStatus.active:
        return AppColors.positive;
      case MemberStatus.suspended:
        return AppColors.negative;
      case MemberStatus.dormant30:
        return AppColors.textMuted;
      case MemberStatus.softDeleted:
        return AppColors.textMuted;
    }
  }
}

String _locationLabel(MemberAdminRow row) {
  return row.primaryLocationName.isEmpty
      ? 'All locations'
      : row.primaryLocationName;
}

String _roleLabel(MemberAdminRow row) {
  for (final grant in row.grants) {
    if (grant.roleKey == row.roleKey) return grant.roleDisplayLabel;
  }
  return memberRoleLabel(row.roleKey);
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
