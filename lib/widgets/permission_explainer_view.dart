// Shared Permission Explainer view.
//
// Surface-agnostic widget that renders the frozen permission key
// catalog as an 11-category tree per the Team / Roles / Hierarchy /
// Sessions / Audit / Security console parity contract
// § "Roles + Permission Explainer (11W.2 + 11A.13 Roles tab)".
//
// This widget is the single source of truth for the Explainer copy
// and category order so the Operator Web screen and the F&F Admin
// Roles tab cannot drift. Before this lift the logic + verbatim copy
// were duplicated; the admin copy paraphrased the catalog (a parity
// violation) and dropped the `account.*` + `business_timing.*`
// categories. The contract rule:
//
//   "Permission Explainer copy uses the catalog `description` field
//    VERBATIM. Do NOT paraphrase. If a description is unclear, fix
//    the catalog (separate slice); do NOT silently improve copy in
//    the UI."
//
//   "Every key listed [in the catalog] must appear in the Permission
//    Explainer; nothing else may."
//
// The verbatim copy mirrored here is sourced from the migrations that
// seed `public.permission_keys.description`:
//
//   * db/migrations/202604250008_auth_schema_foundation.sql
//   * db/migrations/202604270000_phase_9_0a_scope_extensions.sql
//   * db/migrations/202604280014_phase_9_0sigma_h2_audit_privacy_role.sql
//   * db/migrations/202604300002_phase_9_mfa_hardening_launch_roles.sql
//   * db/migrations/202605040000_phase_8_0_integration_framework.sql
//   * db/migrations/202605061100_phase_11A_14_admin_users_reset_mfa_factors_key.sql
//   * db/migrations/202605061600_phase_11W_5_team_audit_log_export_key.sql
//   * db/migrations/202605082200_admin_hierarchy_lifecycle.sql
//   * db/migrations/202605131500_b5_b_catalog_tri_mirror.sql
//
// Adding a new permission key requires updating the migration, the
// catalog doc, `lib/auth/permission_keys.dart`, and this file's
// description map. MFA-required keys (per `PermissionKeys.requiresMfa`)
// render with a lock chip + tooltip per the parity contract's
// MFA-required keys rule.
//
// Web-compat: Flutter + `lib/auth/permission_keys.dart` only. No
// `dart:io` / `sqflite` import — safe under `lib/main_operator_web.dart`
// and `lib/main_admin.dart`.

import 'package:flutter/material.dart';

import '../auth/permission_keys.dart';
import '../theme/app_theme.dart';

/// Locked render order from the parity contract § Roles + Permission
/// Explainer. The view MUST render categories in this exact order.
/// Includes `account` + `business_timing` so no catalog key is
/// silently dropped (contract: every key must appear).
const List<String> kPermissionExplainerCategories = <String>[
  'product',
  'forgeflow',
  'barrio',
  'admin',
  'team',
  'account',
  'business_timing',
  'billing',
  'integration',
  'integrations',
  'workflow',
];

/// Display label for each category prefix. Plain English, matches the
/// catalog doc category headings.
const Map<String, String> kPermissionExplainerCategoryLabels = <String, String>{
  'product': 'Product access',
  'forgeflow': 'Forge & Flow',
  'barrio': 'Barrio',
  'admin': 'F&F admin',
  'team': 'Team self-service',
  'account': 'Account configuration',
  'business_timing': 'Business timing',
  'billing': 'Billing',
  'integration': 'Integrations (per vendor)',
  'integrations': 'Integrations (vendor connections)',
  'workflow': 'Workflows (Phase 12)',
};

/// Verbatim descriptions from the migrations seed. The view must
/// render these without paraphrasing per the parity contract. Adding
/// or fixing a description is a separate slice that updates the
/// migration, catalog doc, `lib/auth/permission_keys.dart`, and this
/// map together.
const Map<String, String> kPermissionExplainerDescriptions = <String, String>{
  // product.* (2)
  'product.forgeflow.access':
      'Access to Forge & Flow surfaces in either product shell.',
  'product.barrio.access':
      'Access to Barrio surfaces in the Barrio product shell.',

  // forgeflow.* (20)
  'forgeflow.shift.view': 'View shift surface.',
  'forgeflow.shift.edit': 'Edit shift assignments.',
  'forgeflow.variance.view': 'View variance surface.',
  'forgeflow.variance.edit': 'Edit variance reasons and notes.',
  'forgeflow.schedule.view': 'View schedule surface.',
  'forgeflow.schedule.edit': 'Edit upcoming schedule assignments.',
  'forgeflow.baseline.view': 'View baseline benchmark.',
  'forgeflow.baseline.override':
      'Override baseline values for a service period.',
  'forgeflow.history.view': 'View historical service-period results.',
  'forgeflow.benchmark.view': 'View 60-day benchmark snapshot.',
  'forgeflow.benchmark.edit': 'Edit 60-day benchmark snapshot inputs.',
  'forgeflow.target_profile.view': 'View active target profile.',
  'forgeflow.target_profile.manage': 'Manage target-profile parameters.',
  'forgeflow.target_cycle.view': 'View target cycle.',
  'forgeflow.target_cycle.unlock':
      'Unlock the active target cycle for early replacement.',
  'forgeflow.target_cycle.replace': 'Replace the active target cycle.',
  'forgeflow.weekly_plan.view': 'View locked weekly plan snapshot.',
  'forgeflow.weekly_plan.lock': 'Lock the in-force weekly plan snapshot.',
  'forgeflow.settings.view': 'View Forge & Flow settings.',
  'forgeflow.settings.manage': 'Manage Forge & Flow settings.',

  // barrio.* (12)
  'barrio.handbook.view': 'View Barrio handbook.',
  'barrio.interview_playbook.view': 'View interview playbook.',
  'barrio.jim_taylor.view': 'View Jim Taylor course.',
  'barrio.preston_lee.view': 'View Preston Lee course.',
  'barrio.supervisor_content.view': 'View supervisor learning content.',
  'barrio.el_podio.view': 'View El Podio leaderboard surfaces.',
  'barrio.handbook.edit':
      'Edit Barrio handbook content (operator owner / F&F only).',
  'barrio.interview_playbook.edit': 'Edit interview-playbook content.',
  'barrio.preston_lee.edit': 'Edit Preston Lee course content.',
  'barrio.supervisor_content.edit': 'Edit supervisor learning content.',
  'barrio.learning.complete_unit':
      'Mark a learning unit complete for the current user.',
  'barrio.streak.view': 'View own streak / leaderboard standing.',

  // admin.* (28)
  'admin.users.view': 'View users in admin console.',
  'admin.users.create': 'Create users programmatically (rare path).',
  'admin.users.deactivate': 'Suspend a user account.',
  'admin.users.reactivate': 'Reactivate a suspended user account.',
  'admin.users.soft_delete':
      'Soft-delete a user (status -> deleted; data retained).',
  'admin.users.erase_pii':
      'GDPR right-to-erasure: redact PII for a user. Paired-approval + MFA required.',
  'admin.users.reset_password':
      'Trigger admin-initiated password reset for a user.',
  'admin.users.reset_mfa_factors':
      "Reset a member's MFA factors from the F&F admin support path. "
      'Required for support-side account recovery when the member has '
      'lost access to their second factor. Paired with admin_reason on '
      'every call. MFA required.',
  'admin.invites.create': 'Create user invites.',
  'admin.invites.revoke': 'Revoke pending user invites.',
  'admin.roles.view': 'View roles in admin console.',
  'admin.roles.edit_seeded':
      'Edit permissions on seeded roles (super_admin only). MFA required.',
  'admin.roles.create_custom': 'Create custom operator-scoped roles.',
  'admin.roles.delete_custom':
      'Delete custom operator-scoped roles (after revoking grants).',
  'admin.roles.assign': 'Grant a role to a user.',
  'admin.roles.revoke': 'Revoke a role from a user.',
  'admin.audit_log.view': 'View auth event audit log.',
  'admin.audit_log.export': 'Export audit log to CSV.',
  'admin.target_cycle.unlock': 'Admin-side override of target-cycle lock.',
  'admin.pricing_tier.view': 'View operator pricing tier.',
  'admin.pricing_tier.edit':
      'Edit operator pricing tier (F&F super_admin only). MFA required.',
  'admin.feature_flag.view': 'View feature flags.',
  'admin.feature_flag.toggle': 'Toggle feature flag value.',
  'admin.status_page.publish': 'Publish a status-page incident or recovery.',
  'admin.debug_console.view': 'View internal debug console.',
  'admin.session.force_logout': 'Force-revoke all sessions for a user.',
  'admin.service_principal.issue_token':
      'Issue short-lived service-principal JWTs for automation identities. MFA required.',
  'admin.audit_privacy.read':
      'Read raw advisor conversation content (encrypted columns) under '
      'the audit-privacy access path. Every call writes an audit_logs '
      'provenance row capturing reader, reason, target, and records-read '
      'count. MFA required.',
  // admin.hierarchy.* (5) — Slice E. Verbatim mirror of the catalog /
  // migration descriptions for the dormant F&F-admin hierarchy keys.
  'admin.hierarchy.create':
      'Create operator hierarchy nodes (org-units and locations) from the '
      'F&F admin "Business accounts" console.',
  'admin.hierarchy.move':
      'Move operator hierarchy nodes (org-units and locations) within the '
      'tree from the F&F admin "Business accounts" console.',
  'admin.hierarchy.rename':
      'Rename operator hierarchy nodes (org-units and locations) from the '
      'F&F admin "Business accounts" console.',
  'admin.hierarchy.suspend':
      'Suspend or reactivate operator hierarchy nodes (org-units and '
      'locations) from the F&F admin "Business accounts" console. MFA '
      'required.',
  'admin.hierarchy.delete':
      'Delete operator hierarchy nodes (org-units and empty locations) from '
      'the F&F admin "Business accounts" console. MFA required.',

  // team.* (19)
  'team.users.view': "View the operator's user list.",
  'team.users.invite': 'Create invites for users in own operator.',
  'team.users.deactivate': 'Suspend a user in own operator.',
  'team.users.reactivate': 'Reactivate a suspended user in own operator.',
  'team.users.soft_delete': 'Soft-delete a user in own operator.',
  'team.users.reset_password':
      'Admin-initiated password reset for a team member.',
  'team.users.reset_mfa':
      'Start or cancel delayed authenticator-app removal for a team member after fresh authentication.',
  'team.users.self_update':
      'Change your own display name or email from My Account. Distinct from team.users.invite which gates editing someone else; every signed-in operator role is granted this key by default.',
  'team.roles.view': "View the operator's role list.",
  'team.roles.create_custom': 'Create operator-scoped custom role.',
  'team.roles.assign': 'Grant role to user within own operator.',
  'team.roles.revoke': 'Revoke role from user within own operator.',
  'team.roles.default_catalog.view':
      'View the F&F Default Role Catalog template - read-only access to the '
      'seeded role set every new operator begins with. F&F super_admin + '
      'ff_support only.',
  'team.roles.default_catalog.edit':
      'Edits the F&F Default Role Catalog template - adds, renames, or '
      'removes seeded roles for new operators. F&F super_admin only.',
  'team.audit_log.view': 'View audit log scoped to own operator.',
  'team.audit_log.export': 'View and export team audit log entries (CSV).',
  'team.session.force_logout':
      "Force-logout a user's sessions within own operator.",
  'team.hierarchy.suspend':
      'Suspend or reactivate locations and hierarchy levels.',
  'team.hierarchy.delete':
      'Delete locations and empty hierarchy levels.',

  // account.* (1)
  'account.configure':
      'Configure operator business account identity, locale, currency, '
      'business-week, rollover-hour, and logo settings.',

  // business_timing.* (1)
  'business_timing.configure':
      'Configure effective-dated business timing profiles, rollover-hour, '
      'week-start, and service periods.',

  // billing.* (5)
  'billing.invoice.view': 'View operator invoices.',
  'billing.subscription.manage':
      'Manage subscription tier + payment terms. MFA required.',
  'billing.payment_method.manage':
      'Add or remove operator payment methods. MFA required.',
  'billing.usage.view': 'View per-class usage and cost rollups.',
  'billing.usage_caps.edit': 'Edit per-class monthly cap. MFA required.',

  // integration.* (9)
  'integration.toast.connect': 'Connect or rotate Toast POS credentials.',
  'integration.toast.view': 'View Toast integration status.',
  'integration.7shifts.connect': 'Connect or rotate 7shifts labor credentials.',
  'integration.7shifts.view': 'View 7shifts integration status.',
  'integration.opentable.connect':
      'Connect or rotate OpenTable reservation credentials.',
  'integration.opentable.view': 'View OpenTable integration status.',
  'integration.qbo.connect': 'Connect or rotate QuickBooks Online credentials.',
  'integration.xero.connect': 'Connect or rotate Xero credentials.',
  'integration.key_rotate': 'Rotate any integration secret. MFA required.',

  // integrations.* (1)
  'integrations.configure':
      'Configure inbound vendor connections (POS / labor / reservation) '
      'on the per-(operator, location) Vendor Connections admin surface.',

  // workflow.* (8)
  'workflow.catalog.view': 'View Phase 12 workflow catalog.',
  'workflow.run': 'Run a Phase 12 workflow.',
  'workflow.approve': 'Approve a Phase 12 workflow approval gate.',
  'workflow.reject': 'Reject a Phase 12 workflow approval gate.',
  'workflow.create': 'Create a Phase 12 workflow.',
  'workflow.delete': 'Delete a Phase 12 workflow.',
  'workflow.history.view': 'View Phase 12 workflow run history.',
  'workflow.tool.invoke': 'Invoke a Phase 12 workflow tool directly.',
};

/// Tooltip text for the MFA-required indicator. Verbatim per parity
/// contract § Roles + Permission Explainer.
const String kPermissionExplainerMfaTooltip =
    'Requires multi-factor authentication.';

/// Returns the category prefix for a permission key. `forgeflow.x.y`
/// belongs to `forgeflow`; `team.users.view` belongs to `team`.
String permissionCategoryOf(String key) {
  final dot = key.indexOf('.');
  return dot < 0 ? key : key.substring(0, dot);
}

/// Returns every permission key the Explainer renders, grouped by
/// category in the locked render order. Keys inside each category are
/// sorted alphabetically so the rendering is stable.
Map<String, List<String>> permissionExplainerByCategory() {
  final byCategory = <String, List<String>>{
    for (final category in kPermissionExplainerCategories) category: <String>[],
  };
  for (final key in PermissionKeys.all) {
    final category = permissionCategoryOf(key);
    byCategory.putIfAbsent(category, () => <String>[]).add(key);
  }
  for (final list in byCategory.values) {
    list.sort();
  }
  return byCategory;
}

/// Surface-agnostic Permission Explainer body.
///
/// When [embedded] is false the view supplies its own intro text +
/// scroll/padding chrome (used by the Operator Web routed screen,
/// which wraps it in a `Scaffold`/`AppBar`). When [embedded] is true
/// the view renders a compact card-friendly column with no scroll
/// view so a host card (the F&F Admin Roles tab) owns the chrome.
///
/// [keyPrefix] namespaces every widget key so each surface keeps its
/// existing test selectors; content (copy, categories, MFA marker) is
/// identical regardless of prefix.
class PermissionExplainerView extends StatelessWidget {
  const PermissionExplainerView({
    super.key,
    this.embedded = false,
    this.keyPrefix = 'permission_explainer',
  });

  /// Render compact (no intro paragraph chrome wrapper, no scroll
  /// view) for hosting inside a card.
  final bool embedded;

  /// Widget-key namespace. Web passes
  /// `operator_web_permission_explainer`; admin passes
  /// `admin_rhs_permission_explainer`.
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final byCategory = permissionExplainerByCategory();
    final blocks = <Widget>[
      for (final category in kPermissionExplainerCategories)
        if ((byCategory[category] ?? const <String>[]).isNotEmpty) ...<Widget>[
          _PermissionCategoryBlock(
            key: Key('${keyPrefix}_category_$category'),
            category: category,
            permissionKeys: byCategory[category]!,
            keyPrefix: keyPrefix,
          ),
          SizedBox(height: embedded ? 10 : 14),
        ],
    ];

    if (embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Every permission your team can hold, grouped by area. '
            'Use this list to plan which permissions you want to grant '
            'when you build a custom role.',
            key: Key('${keyPrefix}_intro'),
            style: AppTextStyles.body13(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          ...blocks,
        ],
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Every permission your team can hold, grouped by area. '
              'Use this list to plan which permissions you want to grant '
              'when you build a custom role.',
              key: Key('${keyPrefix}_intro'),
              style: AppTextStyles.body13(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            ...blocks,
          ],
        ),
      ),
    );
  }
}

class _PermissionCategoryBlock extends StatelessWidget {
  const _PermissionCategoryBlock({
    super.key,
    required this.category,
    required this.permissionKeys,
    required this.keyPrefix,
  });

  final String category;
  final List<String> permissionKeys;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final label = kPermissionExplainerCategoryLabels[category] ?? category;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundSurface,
        border: Border.all(color: AppColors.borderSubtle, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: const BoxDecoration(
              color: AppColors.cardGlow,
              border: Border(
                bottom: BorderSide(color: AppColors.borderSubtle, width: 1),
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    label,
                    style: AppTextStyles.mono14(
                      color: AppColors.textPrimary,
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${permissionKeys.length} '
                  '${permissionKeys.length == 1 ? 'key' : 'keys'}',
                  style: AppTextStyles.mono10(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
          for (var i = 0; i < permissionKeys.length; i++) ...<Widget>[
            if (i > 0)
              const Divider(
                height: 1,
                thickness: 1,
                color: AppColors.borderSubtle,
              ),
            _PermissionRow(
              permissionKey: permissionKeys[i],
              keyPrefix: keyPrefix,
            ),
          ],
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.permissionKey,
    required this.keyPrefix,
  });

  final String permissionKey;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final description =
        kPermissionExplainerDescriptions[permissionKey] ?? permissionKey;
    final requiresMfa = PermissionKeys.requiresMfa.contains(permissionKey);
    return Padding(
      key: Key('${keyPrefix}_row_$permissionKey'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        permissionKey,
                        style: AppTextStyles.mono12(
                          color: AppColors.textPrimary,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (requiresMfa) ...<Widget>[
                      const SizedBox(width: 8),
                      _MfaChip(
                        keyValue: Key('${keyPrefix}_mfa_$permissionKey'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  key: Key('${keyPrefix}_desc_$permissionKey'),
                  style: AppTextStyles.body13(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MfaChip extends StatelessWidget {
  const _MfaChip({required this.keyValue});

  final Key keyValue;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: kPermissionExplainerMfaTooltip,
      child: Container(
        key: keyValue,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.45),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.lock_outline, size: 11, color: AppColors.warning),
            const SizedBox(width: 4),
            Text('MFA', style: AppTextStyles.mono8(color: AppColors.warning)),
          ],
        ),
      ),
    );
  }
}
