import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class AdminHierarchyScopeNotice extends StatelessWidget {
  const AdminHierarchyScopeNotice({
    super.key,
    required this.message,
    this.icon = Icons.info_outline,
  });

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('admin_hierarchy_scope_notice'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: AppColors.sunsetDark),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
