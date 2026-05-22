// Phase 11W.2 - Operator Web Permission Explainer screen.
//
// Routed Scaffold wrapper around the shared, surface-agnostic
// `PermissionExplainerView` (`lib/widgets/permission_explainer_view.dart`).
// The Explainer copy, category order, bucketing, and MFA marker now
// live in the shared view so the Operator Web screen and the F&F
// Admin Roles tab cannot drift (parity contract
// § "Roles + Permission Explainer (11W.2 + 11A.13 Roles tab)").
//
// Mounted at the `/roles/explainer` route in the operator-web shell.
//
// The constants/functions used to live here; they were lifted into
// the shared view verbatim. They are re-exported below so existing
// importers (router, roles screen, `role_permission_picker.dart`,
// and the 11W.2 widget tests) keep compiling unchanged.

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../widgets/permission_explainer_view.dart';

// Re-export the shared Explainer surface so legacy importers of this
// file (operator-web router, roles screen, role_permission_picker,
// 11W.2 tests) keep their existing import path.
export '../../widgets/permission_explainer_view.dart'
    show
        PermissionExplainerView,
        kPermissionExplainerCategories,
        kPermissionExplainerCategoryLabels,
        kPermissionExplainerDescriptions,
        kPermissionExplainerMfaTooltip,
        permissionCategoryOf,
        permissionExplainerByCategory;

/// Operator Web Permission Explainer screen.
class PermissionExplainerScreen extends StatelessWidget {
  const PermissionExplainerScreen({super.key, this.onClose});

  /// Optional close callback. The router uses this to swap back to
  /// the Roles list view; tests can pass a custom hook to assert the
  /// dismiss path.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('operator_web_permission_explainer_screen'),
      backgroundColor: AppColors.backgroundDeep,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundSurface,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(
          'Permission Explainer',
          style: AppTextStyles.display20(color: AppColors.textPrimary),
        ),
        actions: <Widget>[
          SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              key: const Key('operator_web_permission_explainer_close'),
              icon: const Icon(Icons.close, size: 24),
              onPressed: onClose ?? () => Navigator.of(context).maybePop(),
              tooltip: 'Close',
            ),
          ),
        ],
      ),
      body: const PermissionExplainerView(
        keyPrefix: 'operator_web_permission_explainer',
      ),
    );
  }
}
