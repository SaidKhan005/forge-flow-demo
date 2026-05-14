// Wave 2 Q-4 - Custom role editor advisory validator.
//
// Origin: debug.md:78-80 (AC-2). The operator-facing Custom Role
// editor lets an admin assemble a custom role by checking permission
// keys. The keys themselves are frozen and validated against
// PermissionKeys.all, but coherence between keys is not. Three
// incoherent combinations the operator wants warned about:
//
//   1. Member-management chain. If a role grants any
//      team.users.* write key (invite, deactivate, reactivate,
//      soft_delete, reset_password, reset_mfa) it should also grant
//      team.users.view - otherwise the admin can act on a list of
//      members they cannot open. Same logic for team.roles.* writes
//      vs team.roles.view, team.hierarchy.* vs team.hierarchy
//      visibility, and team.session.force_logout vs team.users.view.
//
//   2. View-required-for-edit. Any *.edit / *.write / *.manage /
//      *.override / *.lock / *.unlock / *.replace key whose matching
//      *.view sibling is in the catalog should not be granted alone.
//      The validator pairs them by stem and warns when the write is
//      checked but the view is not.
//
//   3. Location-scoped role attempting org-wide actions. A custom
//      role assigned at Location scope cannot meaningfully grant
//      Business-wide actions (business_setup, business_timing,
//      operator-level admin keys, billing, pricing-tier edits, etc.)
//      The validator warns when the editor's working scope is
//      Location and the selected set contains any key flagged as
//      org-wide.
//
// All warnings are advisory. The operator can save anyway - they
// are an informational surface, not a gate. The proxy still enforces
// PermissionKeys.all on save.
//
// Wave 2 Q-4 follow-up (this commit) - the three rules above stay as
// they were. We add three more rules powered by the R-1L + R-2L
// metadata (`productLabel`, `categoryLabel`, `scopeKind`, `implies`,
// `humanLabel` on `PermissionKeyMetadataCatalog.byKey`):
//
//   4. Orphan implied dependency (metadata-driven). For every key
//      selected in the role, walk its `implies[]` recursively (via
//      `PermissionKeyMetadataCatalog.expandImplies`). Any implied key
//      that is NOT also selected produces a per-pair WARNING whose
//      message uses the `humanLabel` of both keys. This generalises
//      the hand-curated `kViewRequiredForWrite` map - any future
//      implies edge added to the metadata automatically participates,
//      no validator change required.
//
//   5. Per-key location-vs-org-wide warning (metadata-driven).
//      Identical purpose to Rule 3 above, but emits ONE warning per
//      offending key (instead of one bulk warning) and uses
//      `humanLabel` so the operator sees the friendly name instead of
//      the dotted key. Source of truth is
//      `PermissionKeyMetadataCatalog.byKey[k].scopeKind` rather than
//      the hand-curated `kOrgWidePermissionKeys` table.
//
//   6. Product-rule warnings. Hard-coded suspicious combinations
//      that the implies graph cannot express:
//        a. Any `barrio.*` key selected without
//           `product.barrio.access`.
//        b. Any `forgeflow.*` *.edit / *.override / *.manage / *.lock
//           / *.unlock / *.replace key selected without
//           `product.forgeflow.access`.
//        c. `billing.subscription.manage` selected on a role whose
//           display name does not contain "owner" (case-insensitive
//           heuristic). Billing-subscription is an Owner-level lever;
//           granting it on a non-Owner role usually indicates a
//           misclick.
//
// Per-warning dismissal lives outside the pure validator. The editor
// owns a `RoleWarningDismissalStore` and filters warnings whose
// `(roleId, code, affectedKeys.join(','))` key was previously
// dismissed. The store backs the "Don't show this warning again for
// this role" affordance.
//
// Authority anchors:
//   - lib/auth/permission_keys.dart (frozen catalog mirror).
//   - lib/auth/permission_key_metadata.dart (R-1L + R-2L metadata).
//   - docs/contracts/auth_permission_key_catalog.md.
//   - docs/_indices/DEBUG_MD_IMPLEMENTATION_STATUS.md AC-2 row.
//   - UX writing standard (memory/project_ux_writing_standard.md):
//     plain English, no engineering jargon, message reads as
//     training to a new admin.

import '../../auth/permission_key_metadata.dart';
import '../../auth/permission_keys.dart';

/// Hierarchy scope at which a custom role is being authored. Mirrors
/// the operator-web session's working scope (Business or Location).
/// Region / Brand collapse into [RoleScope.business] for the org-wide
/// warning category - any non-Location scope can carry org-wide
/// permissions.
enum RoleScope {
  /// The role is being authored at the Business (org-wide) scope.
  /// Org-wide permissions are coherent here.
  business,

  /// The role is being authored at a single Location. Org-wide
  /// permissions trigger the [RoleWarningCode.locationScopeOrgWideKey]
  /// warning.
  location,
}

/// Severity of an advisory [RoleWarning].
///
/// Both severities are advisory - the editor renders them but never
/// blocks save. `warn` is for combinations that almost certainly hide
/// a surface from the admin; `info` is for hints worth surfacing but
/// less likely to cause a real-world hole.
enum RoleWarningSeverity {
  info,
  warn,
}

/// Machine-readable warning code emitted by [CustomRoleValidator].
/// Pairs with [RoleWarning.message] which carries the plain-English
/// copy the editor renders.
enum RoleWarningCode {
  /// A *.edit / *.write / *.manage / *.override / *.lock / *.unlock /
  /// *.replace key was selected without its matching *.view sibling.
  /// [RoleWarning.affectedKeys] holds the write keys missing a view.
  orphanViewDependency,

  /// One or more team.users.* write keys (invite, deactivate, etc.)
  /// were selected without team.users.view. The admin can act on a
  /// list of members they cannot open.
  memberManagementMissingUsersView,

  /// One or more team.roles.* write keys (create_custom, assign,
  /// revoke) were selected without team.roles.view. The admin can
  /// edit a list of roles they cannot open.
  roleManagementMissingRolesView,

  /// team.session.force_logout was selected without team.users.view.
  /// The admin can force a logout on a list of users they cannot
  /// open.
  sessionForceLogoutMissingUsersView,

  /// team.hierarchy.* keys were selected without team.audit_log.view.
  /// Hierarchy changes are audit-logged and the actor cannot review
  /// the audit trail of their own actions.
  hierarchyMissingAuditView,

  /// The role is being authored at Location scope but selected an
  /// org-wide permission key. The grant will be issued but the
  /// runtime gate will refuse the action.
  locationScopeOrgWideKey,

  /// Wave 2 Q-4 follow-up. A selected key whose recursive `implies[]`
  /// chain (per `PermissionKeyMetadataCatalog.byKey`) includes a key
  /// that is NOT also selected. One warning per (write, missing-view)
  /// pair so the editor can offer a per-pair "Add the missing key"
  /// affordance later. The hand-curated [orphanViewDependency] above
  /// keeps firing for backwards compatibility; this one is the
  /// metadata-driven supplement.
  orphanImpliedDependency,

  /// Wave 2 Q-4 follow-up. Per-key flavour of
  /// [locationScopeOrgWideKey]: emitted once per offending org-wide
  /// key (instead of one bulk warning), with the key's `humanLabel`
  /// in the message so the operator sees the friendly name.
  perKeyOrgWideAtLocationScope,

  /// Wave 2 Q-4 follow-up. A `barrio.*` permission key was selected
  /// but `product.barrio.access` was not. The role grants Barrio
  /// surfaces but cannot open Barrio at all.
  barrioKeyMissingProductAccess,

  /// Wave 2 Q-4 follow-up. A `forgeflow.*` write key (edit / override
  /// / manage / lock / unlock / replace) was selected but
  /// `product.forgeflow.access` was not. The role grants Forge & Flow
  /// edits but cannot open Forge & Flow at all.
  forgeflowWriteMissingProductAccess,

  /// Wave 2 Q-4 follow-up. `billing.subscription.manage` was selected
  /// on a role whose display name does not contain "owner"
  /// (case-insensitive). Billing-subscription is an Owner-level lever;
  /// granting it on a non-Owner role usually indicates a misclick.
  billingSubscriptionOnNonOwnerRole,
}

/// Single advisory warning produced by [CustomRoleValidator].
class RoleWarning {
  const RoleWarning({
    required this.severity,
    required this.code,
    required this.affectedKeys,
    required this.message,
  });

  /// Severity. Both are advisory; see [RoleWarningSeverity].
  final RoleWarningSeverity severity;

  /// Machine-readable warning code; the editor uses this to dedupe
  /// and to render a code label next to each row.
  final RoleWarningCode code;

  /// Permission keys this warning is about. Always non-empty. The
  /// editor renders them as mono-font chips after the message.
  final List<String> affectedKeys;

  /// Plain-English explanation the editor renders. Reads as training
  /// to a new admin per the UX writing standard - no engineering
  /// jargon, no scope_id=..., no inherited_from=null.
  final String message;
}

/// Pure-Dart validator for the Custom Role editor. No I/O, no
/// async. Call [validate] from the editor whenever the selected set
/// changes (or once at save time when warnings are advisory only).
///
/// The validator is deliberately stateless - all rule data lives in
/// the const tables below so tests can pin the exact set of warnings
/// emitted for any (keys, scope) input.
class CustomRoleValidator {
  const CustomRoleValidator();

  /// Validate the selected [permissionKeys] for the given working
  /// [scope]. Returns an unmodifiable list of advisory warnings in
  /// deterministic order so the editor renders the same set across
  /// rebuilds.
  ///
  /// Unknown keys (outside [PermissionKeys.all]) are silently
  /// dropped - the editor already surfaces the
  /// `kCustomRoleEditorUnknownKeyMessage` panel for those, and we
  /// do not want to duplicate the message.
  ///
  /// [roleDisplayName] is the role's working display name. It is
  /// only used by Rule 6c (billing-subscription on non-Owner) - all
  /// other rules ignore it. Pass an empty string when validating a
  /// brand new role before the operator has typed a name; the
  /// non-Owner heuristic stays conservative (empty name does not
  /// contain "owner", so the warning fires).
  List<RoleWarning> validate(
    Set<String> permissionKeys, {
    required RoleScope scope,
    String roleDisplayName = '',
  }) {
    final known = permissionKeys
        .where(PermissionKeys.all.contains)
        .toSet();
    final warnings = <RoleWarning>[];

    _checkMemberManagementChain(known, warnings);
    _checkRoleManagementChain(known, warnings);
    _checkSessionForceLogoutChain(known, warnings);
    _checkHierarchyAuditChain(known, warnings);
    _checkOrphanViewDependency(known, warnings);
    if (scope == RoleScope.location) {
      _checkOrgWideKeysAtLocationScope(known, warnings);
    }

    // Wave 2 Q-4 follow-up - metadata-driven rules.
    _checkOrphanImpliedDependency(known, warnings);
    if (scope == RoleScope.location) {
      _checkPerKeyOrgWideAtLocationScope(known, warnings);
    }
    _checkProductAccessGates(known, warnings);
    _checkBillingSubscriptionOnNonOwner(known, roleDisplayName, warnings);

    return List<RoleWarning>.unmodifiable(warnings);
  }

  void _checkMemberManagementChain(
    Set<String> known,
    List<RoleWarning> sink,
  ) {
    if (known.contains(PermissionKeys.teamUsersView)) return;
    final triggered = kTeamUsersWriteKeys
        .where(known.contains)
        .toList(growable: false);
    if (triggered.isEmpty) return;
    sink.add(
      RoleWarning(
        severity: RoleWarningSeverity.warn,
        code: RoleWarningCode.memberManagementMissingUsersView,
        affectedKeys: triggered,
        message:
            'This role can manage team members but cannot open the '
            'members list. Add "team.users.view" so admins with this '
            'role can see who they are managing.',
      ),
    );
  }

  void _checkRoleManagementChain(
    Set<String> known,
    List<RoleWarning> sink,
  ) {
    if (known.contains(PermissionKeys.teamRolesView)) return;
    final triggered = kTeamRolesWriteKeys
        .where(known.contains)
        .toList(growable: false);
    if (triggered.isEmpty) return;
    sink.add(
      RoleWarning(
        severity: RoleWarningSeverity.warn,
        code: RoleWarningCode.roleManagementMissingRolesView,
        affectedKeys: triggered,
        message:
            'This role can create, assign, or revoke roles but cannot '
            'open the roles list. Add "team.roles.view" so admins '
            'with this role can see the roles they are editing.',
      ),
    );
  }

  void _checkSessionForceLogoutChain(
    Set<String> known,
    List<RoleWarning> sink,
  ) {
    if (!known.contains(PermissionKeys.teamSessionForceLogout)) return;
    if (known.contains(PermissionKeys.teamUsersView)) return;
    sink.add(
      RoleWarning(
        severity: RoleWarningSeverity.warn,
        code: RoleWarningCode.sessionForceLogoutMissingUsersView,
        affectedKeys: const <String>[PermissionKeys.teamSessionForceLogout],
        message:
            'This role can force someone out of their session but '
            'cannot see the team members list. Add "team.users.view" '
            'so admins with this role can pick who to sign out.',
      ),
    );
  }

  void _checkHierarchyAuditChain(
    Set<String> known,
    List<RoleWarning> sink,
  ) {
    final triggered = kTeamHierarchyKeys
        .where(known.contains)
        .toList(growable: false);
    if (triggered.isEmpty) return;
    if (known.contains(PermissionKeys.teamAuditLogView)) return;
    sink.add(
      RoleWarning(
        severity: RoleWarningSeverity.info,
        code: RoleWarningCode.hierarchyMissingAuditView,
        affectedKeys: triggered,
        message:
            'This role can suspend or delete parts of the hierarchy '
            'but cannot review the audit log of those changes. '
            'Consider adding "team.audit_log.view" so admins can see '
            'the trail of their own actions.',
      ),
    );
  }

  void _checkOrphanViewDependency(
    Set<String> known,
    List<RoleWarning> sink,
  ) {
    final orphans = <String>[];
    for (final entry in kViewRequiredForWrite.entries) {
      final write = entry.key;
      final view = entry.value;
      if (!known.contains(write)) continue;
      if (known.contains(view)) continue;
      orphans.add(write);
    }
    if (orphans.isEmpty) return;
    orphans.sort();
    sink.add(
      RoleWarning(
        severity: RoleWarningSeverity.warn,
        code: RoleWarningCode.orphanViewDependency,
        affectedKeys: orphans,
        message:
            'You enabled editing actions but not the matching view '
            'permissions. Admins with this role will not be able to '
            'open the pages they are meant to edit.',
      ),
    );
  }

  void _checkOrgWideKeysAtLocationScope(
    Set<String> known,
    List<RoleWarning> sink,
  ) {
    final triggered = kOrgWidePermissionKeys
        .where(known.contains)
        .toList(growable: false);
    if (triggered.isEmpty) return;
    sink.add(
      RoleWarning(
        severity: RoleWarningSeverity.warn,
        code: RoleWarningCode.locationScopeOrgWideKey,
        affectedKeys: triggered,
        message:
            'This role is set up for a single location but includes '
            'permissions that only work business-wide. Admins with '
            'this role will see the option in the UI but will not be '
            'allowed to use it. Either move this role to the '
            'business scope, or remove the business-wide permissions.',
      ),
    );
  }

  // ─── Wave 2 Q-4 follow-up rules ───────────────────────────────────

  /// Rule 4 - metadata-driven orphan implies check. Walks the
  /// `implies[]` graph from `PermissionKeyMetadataCatalog` for every
  /// selected key and emits one WARNING per (selected, missing-implied)
  /// pair. Uses `humanLabel` so the operator sees the friendly name
  /// instead of the dotted key. Skips edges already covered by the
  /// hand-curated [orphanViewDependency] warning so the editor does
  /// not render the same fact twice.
  void _checkOrphanImpliedDependency(
    Set<String> known,
    List<RoleWarning> sink,
  ) {
    // Build the set of (write, view) pairs the hand-curated check has
    // already complained about - we skip those to avoid duplicate
    // rendering. The hand-curated check emits ONE bulk warning, but
    // for the dedupe we want to know each write key it covered.
    final handCuratedWritesAlreadyOrphaned = <String>{};
    for (final entry in kViewRequiredForWrite.entries) {
      if (!known.contains(entry.key)) continue;
      if (known.contains(entry.value)) continue;
      handCuratedWritesAlreadyOrphaned.add(entry.key);
    }

    // Collect (write, missing-implied) pairs, walking the implies
    // graph recursively. Sort for deterministic rendering order.
    final pairs = <_OrphanImpliesPair>[];
    for (final selectedKey in known) {
      final meta = PermissionKeyMetadataCatalog.byKey[selectedKey];
      if (meta == null) continue;
      if (meta.implies.isEmpty) continue;
      // expandImplies returns the closure including selectedKey, so
      // remove it before checking misses.
      final closure = PermissionKeyMetadataCatalog.expandImplies(
        <String>[selectedKey],
      )..remove(selectedKey);
      for (final impliedKey in closure) {
        if (known.contains(impliedKey)) continue;
        // Skip pairs the hand-curated [orphanViewDependency] warning
        // already reported on - same fact, two surfaces.
        if (handCuratedWritesAlreadyOrphaned.contains(selectedKey) &&
            kViewRequiredForWrite[selectedKey] == impliedKey) {
          continue;
        }
        pairs.add(_OrphanImpliesPair(selectedKey, impliedKey));
      }
    }
    if (pairs.isEmpty) return;
    pairs.sort((a, b) {
      final c = a.write.compareTo(b.write);
      if (c != 0) return c;
      return a.implied.compareTo(b.implied);
    });

    for (final pair in pairs) {
      final writeLabel = _labelForKey(pair.write);
      final viewLabel = _labelForKey(pair.implied);
      sink.add(
        RoleWarning(
          severity: RoleWarningSeverity.warn,
          code: RoleWarningCode.orphanImpliedDependency,
          affectedKeys: <String>[pair.write, pair.implied],
          message:
              '"$writeLabel" is selected without "$viewLabel". '
              'Users with this role would not be able to see what '
              "they're editing.",
        ),
      );
    }
  }

  /// Rule 5 - per-key org-wide-at-location warning. Emits one warning
  /// per offending key (instead of one bulk warning) so the operator
  /// gets a friendly per-row callout. Reads `scopeKind` straight from
  /// `PermissionKeyMetadataCatalog`.
  void _checkPerKeyOrgWideAtLocationScope(
    Set<String> known,
    List<RoleWarning> sink,
  ) {
    final offenders = <String>[];
    for (final key in known) {
      final meta = PermissionKeyMetadataCatalog.byKey[key];
      if (meta == null) continue;
      if (meta.scopeKind == PermissionScopeKind.orgWide) {
        offenders.add(key);
      }
    }
    if (offenders.isEmpty) return;
    offenders.sort();
    for (final key in offenders) {
      final label = _labelForKey(key);
      sink.add(
        RoleWarning(
          severity: RoleWarningSeverity.info,
          code: RoleWarningCode.perKeyOrgWideAtLocationScope,
          affectedKeys: <String>[key],
          message:
              '"$label" doesn\'t apply at the location level. Users '
              "with this role won't be able to use it.",
        ),
      );
    }
  }

  /// Rule 6a + 6b - product-access gate. Warns when a Barrio
  /// permission is selected without the Barrio product gate, and
  /// when a Forge & Flow write permission is selected without the
  /// F&F product gate.
  void _checkProductAccessGates(
    Set<String> known,
    List<RoleWarning> sink,
  ) {
    // 6a: barrio.* without product.barrio.access.
    if (!known.contains(PermissionKeys.productBarrioAccess)) {
      final barrioKeys = known
          .where(
            (k) =>
                k.startsWith('barrio.') ||
                (PermissionKeyMetadataCatalog.byKey[k]?.productLabel ==
                    'barrio'),
          )
          .toList()
        ..sort();
      if (barrioKeys.isNotEmpty) {
        sink.add(
          RoleWarning(
            severity: RoleWarningSeverity.warn,
            code: RoleWarningCode.barrioKeyMissingProductAccess,
            affectedKeys: barrioKeys,
            message:
                'This role grants Barrio permissions but does not let '
                'users open Barrio. Add "Open Barrio" so admins with '
                'this role can reach the Barrio screens they have '
                'permissions for.',
          ),
        );
      }
    }

    // 6b: forgeflow.* write keys without product.forgeflow.access.
    if (!known.contains(PermissionKeys.productForgeflowAccess)) {
      final ffWriteKeys = known
          .where((k) => _isForgeflowWriteKey(k))
          .toList()
        ..sort();
      if (ffWriteKeys.isNotEmpty) {
        sink.add(
          RoleWarning(
            severity: RoleWarningSeverity.warn,
            code: RoleWarningCode.forgeflowWriteMissingProductAccess,
            affectedKeys: ffWriteKeys,
            message:
                'This role can change Forge & Flow data but does not '
                'let users open Forge & Flow. Add "Open Forge & Flow" '
                'so admins with this role can reach the screens they '
                'are meant to edit.',
          ),
        );
      }
    }
  }

  /// Rule 6c - billing.subscription.manage on a non-Owner role.
  /// Heuristic: the operator-facing display name does not contain
  /// "owner" (case-insensitive). Empty display name (brand-new role
  /// before the operator typed a name) still triggers because
  /// "owner" is not present.
  void _checkBillingSubscriptionOnNonOwner(
    Set<String> known,
    String roleDisplayName,
    List<RoleWarning> sink,
  ) {
    if (!known.contains(PermissionKeys.billingSubscriptionManage)) return;
    if (roleDisplayName.toLowerCase().contains('owner')) return;
    sink.add(
      RoleWarning(
        severity: RoleWarningSeverity.warn,
        code: RoleWarningCode.billingSubscriptionOnNonOwnerRole,
        affectedKeys: const <String>[PermissionKeys.billingSubscriptionManage],
        message:
            'Managing the subscription and payment plan is usually an '
            "Owner-only action. This role's name does not look like an "
            'Owner role. Double-check that you want every member of '
            'this role to be able to change the subscription.',
      ),
    );
  }

  /// Lookup the human-friendly label for [key] using the R-2L
  /// metadata. Falls back to the dotted key when the metadata row is
  /// missing - the lint at `tool/permission_key_lint.dart` keeps the
  /// catalog complete, so the fallback is for the brief gap during a
  /// new-key migration and tests that pass in raw dotted strings.
  static String _labelForKey(String key) {
    final meta = PermissionKeyMetadataCatalog.byKey[key];
    if (meta == null) return key;
    if (meta.humanLabel.isEmpty) return key;
    return meta.humanLabel;
  }

  /// True iff [key] looks like a Forge & Flow write key (a permission
  /// that changes state). Matches by metadata `implies` non-empty AND
  /// `productLabel == 'forgeflow'`, plus the dotted-key suffix
  /// fallback (`.edit` / `.override` / `.manage` / `.lock` / `.unlock`
  /// / `.replace`) so the rule still fires for keys that are
  /// catalogued as their own root.
  static bool _isForgeflowWriteKey(String key) {
    final meta = PermissionKeyMetadataCatalog.byKey[key];
    if (meta != null) {
      if (meta.productLabel != 'forgeflow') return false;
      if (meta.implies.isNotEmpty) return true;
    }
    if (!key.startsWith('forgeflow.')) return false;
    const writeSuffixes = <String>{
      'edit',
      'override',
      'manage',
      'lock',
      'unlock',
      'replace',
    };
    final tail = key.split('.').last;
    return writeSuffixes.contains(tail);
  }
}

/// Internal helper - one (write, implied) pair surfaced by the
/// metadata-driven Rule 4. Pure value type; not exported.
class _OrphanImpliesPair {
  const _OrphanImpliesPair(this.write, this.implied);
  final String write;
  final String implied;
}

// ---------------------------------------------------------------------
// Rule data tables
// ---------------------------------------------------------------------

/// team.users.* write keys that imply the actor needs to see the
/// members list. Sorted alphabetically so warning output is stable
/// across runs.
const List<String> kTeamUsersWriteKeys = <String>[
  PermissionKeys.teamUsersDeactivate,
  PermissionKeys.teamUsersInvite,
  PermissionKeys.teamUsersReactivate,
  PermissionKeys.teamUsersResetMfa,
  PermissionKeys.teamUsersResetPassword,
  PermissionKeys.teamUsersSoftDelete,
];

/// team.roles.* write keys that imply the actor needs to see the
/// roles list.
const List<String> kTeamRolesWriteKeys = <String>[
  PermissionKeys.teamRolesAssign,
  PermissionKeys.teamRolesCreateCustom,
  PermissionKeys.teamRolesRevoke,
];

/// team.hierarchy.* keys that mutate the org structure. Suspending or
/// deleting a node leaves an audit trail the actor should be able to
/// review.
const List<String> kTeamHierarchyKeys = <String>[
  PermissionKeys.teamHierarchyDelete,
  PermissionKeys.teamHierarchySuspend,
];

/// Write-action permission keys whose matching view sibling exists in
/// the frozen catalog. Each entry maps write -> view. Pairs are
/// hand-curated by walking PermissionKeys.all and matching by stem
/// (everything before the last `.<verb>` segment).
const Map<String, String> kViewRequiredForWrite = <String, String>{
  // forgeflow.*
  PermissionKeys.forgeflowShiftEdit: PermissionKeys.forgeflowShiftView,
  PermissionKeys.forgeflowVarianceEdit: PermissionKeys.forgeflowVarianceView,
  PermissionKeys.forgeflowScheduleEdit: PermissionKeys.forgeflowScheduleView,
  PermissionKeys.forgeflowBaselineOverride:
      PermissionKeys.forgeflowBaselineView,
  PermissionKeys.forgeflowBenchmarkEdit: PermissionKeys.forgeflowBenchmarkView,
  PermissionKeys.forgeflowTargetProfileManage:
      PermissionKeys.forgeflowTargetProfileView,
  PermissionKeys.forgeflowTargetCycleUnlock:
      PermissionKeys.forgeflowTargetCycleView,
  PermissionKeys.forgeflowTargetCycleReplace:
      PermissionKeys.forgeflowTargetCycleView,
  PermissionKeys.forgeflowWeeklyPlanLock:
      PermissionKeys.forgeflowWeeklyPlanView,
  PermissionKeys.forgeflowSettingsManage: PermissionKeys.forgeflowSettingsView,

  // barrio.*
  PermissionKeys.barrioHandbookEdit: PermissionKeys.barrioHandbookView,
  PermissionKeys.barrioInterviewPlaybookEdit:
      PermissionKeys.barrioInterviewPlaybookView,
  PermissionKeys.barrioPrestonLeeEdit: PermissionKeys.barrioPrestonLeeView,
  PermissionKeys.barrioSupervisorContentEdit:
      PermissionKeys.barrioSupervisorContentView,

  // admin.* - paired by stem against admin.*.view siblings that exist
  // in the catalog.
  PermissionKeys.adminRolesEditSeeded: PermissionKeys.adminRolesView,
  PermissionKeys.adminRolesCreateCustom: PermissionKeys.adminRolesView,
  PermissionKeys.adminRolesDeleteCustom: PermissionKeys.adminRolesView,
  PermissionKeys.adminRolesAssign: PermissionKeys.adminRolesView,
  PermissionKeys.adminRolesRevoke: PermissionKeys.adminRolesView,
  PermissionKeys.adminUsersCreate: PermissionKeys.adminUsersView,
  PermissionKeys.adminUsersDeactivate: PermissionKeys.adminUsersView,
  PermissionKeys.adminUsersReactivate: PermissionKeys.adminUsersView,
  PermissionKeys.adminUsersSoftDelete: PermissionKeys.adminUsersView,
  PermissionKeys.adminUsersErasePii: PermissionKeys.adminUsersView,
  PermissionKeys.adminUsersResetPassword: PermissionKeys.adminUsersView,
  PermissionKeys.adminUsersResetMfaFactors: PermissionKeys.adminUsersView,
  PermissionKeys.adminAuditLogExport: PermissionKeys.adminAuditLogView,
  PermissionKeys.adminPricingTierEdit: PermissionKeys.adminPricingTierView,
  PermissionKeys.adminFeatureFlagToggle: PermissionKeys.adminFeatureFlagView,

  // team.* - paired by stem against team.*.view siblings.
  PermissionKeys.teamUsersInvite: PermissionKeys.teamUsersView,
  PermissionKeys.teamUsersDeactivate: PermissionKeys.teamUsersView,
  PermissionKeys.teamUsersReactivate: PermissionKeys.teamUsersView,
  PermissionKeys.teamUsersSoftDelete: PermissionKeys.teamUsersView,
  PermissionKeys.teamUsersResetPassword: PermissionKeys.teamUsersView,
  PermissionKeys.teamUsersResetMfa: PermissionKeys.teamUsersView,
  PermissionKeys.teamRolesCreateCustom: PermissionKeys.teamRolesView,
  PermissionKeys.teamRolesAssign: PermissionKeys.teamRolesView,
  PermissionKeys.teamRolesRevoke: PermissionKeys.teamRolesView,
  PermissionKeys.teamRolesDefaultCatalogEdit:
      PermissionKeys.teamRolesDefaultCatalogView,
  PermissionKeys.teamAuditLogExport: PermissionKeys.teamAuditLogView,
};

/// Permission keys that only make sense at the Business (org-wide)
/// scope. Hand-curated by walking PermissionKeys.all and selecting
/// keys whose runtime semantics are inherently org-wide (operator
/// account settings, billing, business timing, F&F-internal admin
/// surfaces, integration provider keys, pricing tier, feature flags,
/// service principals, status page, audit privacy, default-role
/// catalog edits).
///
/// Location-scoped operational keys (forgeflow.*, barrio.*,
/// team.* day-to-day, integration.*.view) are intentionally absent -
/// those are coherent at any scope.
const List<String> kOrgWidePermissionKeys = <String>[
  // account.* / business_timing.* - operator-level settings.
  PermissionKeys.accountConfigure,
  PermissionKeys.businessTimingConfigure,
  // billing.* - all billing flows are operator-scoped, not location.
  PermissionKeys.billingInvoiceView,
  PermissionKeys.billingSubscriptionManage,
  PermissionKeys.billingPaymentMethodManage,
  PermissionKeys.billingUsageView,
  PermissionKeys.billingUsageCapsEdit,
  // admin.* - F&F-internal admin surfaces (always operator-scoped on
  // the proxy, never location-scoped).
  PermissionKeys.adminPricingTierView,
  PermissionKeys.adminPricingTierEdit,
  PermissionKeys.adminFeatureFlagView,
  PermissionKeys.adminFeatureFlagToggle,
  PermissionKeys.adminStatusPagePublish,
  PermissionKeys.adminDebugConsoleView,
  PermissionKeys.adminServicePrincipalIssueToken,
  PermissionKeys.adminAuditPrivacyRead,
  PermissionKeys.adminRolesEditSeeded,
  // integrations.* / integration.* connect + key rotation - vendor
  // credential surfaces are operator-scoped (per the integrations
  // location-editable carve-out in HP #11, view is allowed at
  // location but connect / rotate is org-wide).
  PermissionKeys.integrationsConfigure,
  PermissionKeys.integrationToastConnect,
  PermissionKeys.integration7shiftsConnect,
  PermissionKeys.integrationOpentableConnect,
  PermissionKeys.integrationQboConnect,
  PermissionKeys.integrationXeroConnect,
  PermissionKeys.integrationKeyRotate,
  // Wave 2 RP-9 - team.roles.default_catalog.* are F&F-internal,
  // global-deployment-wide actions. Publishing a new default catalog
  // version affects every operator, so location-scoped grants are
  // nonsensical.
  PermissionKeys.teamRolesDefaultCatalogView,
  PermissionKeys.teamRolesDefaultCatalogEdit,
];
