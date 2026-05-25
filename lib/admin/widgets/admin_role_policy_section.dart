import 'package:flutter/material.dart';
import 'package:forge_and_flow/widgets/console/console_surface.dart';

import '../../theme/app_theme.dart';
import '../services/roles_hierarchy_sessions_admin_gateway.dart';

class AdminRolePolicySection extends StatelessWidget {
  const AdminRolePolicySection({
    super.key,
    required this.title,
    required this.roles,
    required this.sectionKey,
    required this.emptyText,
    required this.showAll,
    required this.onToggleExpanded,
    required this.rowBuilder,
    this.rolePreviewLimit,
    this.toggleKey,
    this.trailing,
  });

  final String title;
  final List<RoleAdminRow> roles;
  final Key sectionKey;
  final String emptyText;
  final bool showAll;
  final int? rolePreviewLimit;
  final Key? toggleKey;
  final VoidCallback onToggleExpanded;
  final Widget Function(RoleAdminRow role) rowBuilder;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final limit = rolePreviewLimit;
    final shouldTruncate = limit != null && roles.length > limit;
    final visibleRoles = shouldTruncate && !showAll
        ? roles.take(limit).toList(growable: false)
        : roles;
    return OperatorWebPanel(
      title: '$title (${roles.length})',
      trailing: trailing,
      child: Column(
        key: sectionKey,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (roles.isEmpty)
            Text(
              emptyText,
              style: AppTextStyles.body13(color: AppColors.textMuted),
            )
          else
            for (final role in visibleRoles) rowBuilder(role),
          if (shouldTruncate) ...<Widget>[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: toggleKey,
                onPressed: onToggleExpanded,
                icon: Icon(
                  showAll ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                  size: 18,
                ),
                label: Text(showAll ? 'Show fewer' : 'Show all'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
