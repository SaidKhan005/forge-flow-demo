// W4 parity - advisory role-coherence warning panel for the admin
// custom-role editor.
//
// The shared `CustomRoleValidator` (`lib/services/auth/custom_role_validator.dart`)
// produces role-coherence WARNINGS (permissions that don't cohere,
// org-wide keys at a location scope, product-access gaps, etc.). The
// operator-web custom-role editor already surfaces those warnings; this
// panel surfaces the identical set in the admin Roles + Hierarchy +
// Sessions screen's create-custom-role dialog so the two consoles stay
// in parity.
//
// The panel is ADVISORY ONLY: it informs the admin and never gates,
// blocks, or alters submit. It owns the validate() call (so the host
// dialog stays small and under its frozen size ceiling) but holds no
// mutable state - it recomputes from its inputs on every rebuild, which
// is exactly what the host's setState already drives.
//
// Built on the shared `OperatorWebBanner` (warning tone) for the header,
// with one keyed detail row per warning carrying the plain-English
// message and the affected permission keys, mirroring the operator-web
// editor's per-warning detail.

import 'package:flutter/material.dart';

import '../../services/auth/custom_role_validator.dart';
import '../../auth/permission_key_metadata.dart';
import '../../theme/app_theme.dart';
import '../../widgets/console/console_surface.dart';

/// Advisory coherence-warning panel for the admin custom-role editor.
///
/// Pass the ticked permission keys, the working [scope], the role's
/// in-progress [roleDisplayName], and the [validator]. The panel expands
/// the ticked keys through the catalog `implies` graph (the same set the
/// gateway receives), runs the validator, and renders the resulting
/// advisory warnings. Renders nothing when there are no warnings, so the
/// host can embed it unconditionally.
class AdminRoleWarningPanel extends StatelessWidget {
  const AdminRoleWarningPanel({
    super.key,
    required this.permissionKeys,
    required this.scope,
    required this.roleDisplayName,
    this.validator = const CustomRoleValidator(),
  });

  /// The permission keys the admin has ticked. The panel expands the
  /// transitive `implies` closure before validating so it matches the
  /// effective set the proxy receives on save.
  final Set<String> permissionKeys;

  /// Working hierarchy scope this role is being authored at.
  final RoleScope scope;

  /// The role's in-progress display name. Only the billing-subscription
  /// (non-Owner) rule reads it; passing it keeps that warning live as
  /// the admin types.
  final String roleDisplayName;

  /// Advisory validator. Pure Dart; override in tests to pin a warning
  /// set without seeding permission keys.
  final CustomRoleValidator validator;

  @override
  Widget build(BuildContext context) {
    final warnings = validator.validate(
      PermissionKeyMetadataCatalog.expandImplies(permissionKeys),
      scope: scope,
      roleDisplayName: roleDisplayName,
    );
    if (warnings.isEmpty) return const SizedBox.shrink();
    final count = warnings.length;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        key: const Key('admin_rhs_create_custom_role_warnings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          OperatorWebBanner(
            tone: OperatorWebBannerTone.warning,
            title:
                'Heads up: this role has $count '
                '${count == 1 ? 'thing' : 'things'} worth a second look',
            message:
                'You can save anyway. These notes call out permission '
                'combinations that may hide the screen the role needs.',
          ),
          for (final warning in warnings)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _AdminRoleWarningRow(warning: warning),
            ),
        ],
      ),
    );
  }
}

class _AdminRoleWarningRow extends StatelessWidget {
  const _AdminRoleWarningRow({required this.warning});

  final RoleWarning warning;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: Key('admin_rhs_create_custom_role_warning_${warning.code.name}'),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            warning.message,
            style: AppTextStyles.body13(color: AppColors.textPrimary),
          ),
          if (warning.affectedKeys.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: <Widget>[
                for (final key in warning.affectedKeys)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.cardGlow,
                      border: Border.all(
                        color: AppColors.borderSubtle,
                        width: 1,
                      ),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      key,
                      style: AppTextStyles.mono10(color: AppColors.textPrimary),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
