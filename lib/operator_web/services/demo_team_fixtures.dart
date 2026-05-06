// Phase 11W parity block - shared demo fixture data set.
//
// One demo operator (`Demo Bistro`), three locations, two org units,
// six users covering each non-admin seeded role plus one custom role
// holder, four active sessions, and roughly 50 audit-log entries
// across the last 30 days. The fixture lives in this file so every
// 11W self-service parity slice (Members, Roles, Hierarchy, Sessions,
// Audit Log, Security) can navigate the demo walkthrough end-to-end
// without seeing inconsistent state.
//
// Slices add fixtures here additively as they land:
//   * 11W.1 Members  - users + invites + scope catalog (this slice)
//   * 11W.2 Roles    - seeded role catalog + Floor Captain custom role
//   * 11W.3 Hierarchy - org unit tree + locations
//   * 11W.4 Sessions - auth_sessions ledger snapshot
//   * 11W.5 Audit    - audit_logs entries
//   * 11W.6 Security - own-user MFA factors + login history slice
//
// Demo gateways MUST NOT mutate this fixture data permanently across
// page loads - the walkthrough has to stay reproducible. Mutations a
// demo gateway makes during one walkthrough session live in that
// gateway's own copy of the fixture; reloading the page resets to the
// values declared here.
//
// Web-safe: pure-Dart, no `dart:io`, no `sqflite` imports.

import 'package:flutter/foundation.dart';

import '../../services/auth/auth_operations_gateway.dart';

/// Demo operator handle every 11W parity slice keys off.
const String kDemoOperatorIdFixture = 'demo-operator';

/// Display name rendered in the welcome / T&Cs copy.
const String kDemoOperatorBusinessNameFixture = 'Demo Bistro';

/// Locations the demo operator owns. Order matches the org tree
/// 11W.3 renders so location filters surface them in this sequence.
class DemoTeamLocationFixture {
  const DemoTeamLocationFixture({
    required this.locationId,
    required this.name,
    required this.orgUnitId,
  });

  final String locationId;
  final String name;
  final String orgUnitId;
}

/// Region grouping (11W.3 walks the tree as East Region containing
/// Downtown + North Loop, West Region containing Riverside).
class DemoTeamOrgUnitFixture {
  const DemoTeamOrgUnitFixture({
    required this.orgUnitId,
    required this.name,
    this.parentOrgUnitId,
  });

  final String orgUnitId;
  final String name;
  final String? parentOrgUnitId;
}

const List<DemoTeamLocationFixture> kDemoTeamLocationsFixture =
    <DemoTeamLocationFixture>[
  DemoTeamLocationFixture(
    locationId: 'demo-loc-downtown',
    name: 'Downtown',
    orgUnitId: 'demo-org-east',
  ),
  DemoTeamLocationFixture(
    locationId: 'demo-loc-north-loop',
    name: 'North Loop',
    orgUnitId: 'demo-org-east',
  ),
  DemoTeamLocationFixture(
    locationId: 'demo-loc-riverside',
    name: 'Riverside',
    orgUnitId: 'demo-org-west',
  ),
];

const List<DemoTeamOrgUnitFixture> kDemoTeamOrgUnitsFixture =
    <DemoTeamOrgUnitFixture>[
  DemoTeamOrgUnitFixture(orgUnitId: 'demo-org-east', name: 'East Region'),
  DemoTeamOrgUnitFixture(orgUnitId: 'demo-org-west', name: 'West Region'),
];

/// Seeded role catalog the parity slices project from. 11W.1 needed
/// the role keys + display labels so the Members filter rail and
/// invite dialog could render dropdowns. 11W.2 expands the fixture
/// with the per-role permission set so the Roles screen + Permission
/// Explainer can render against the same data the live gateway
/// returns.
class DemoTeamRoleFixture {
  const DemoTeamRoleFixture({
    required this.roleId,
    required this.roleKey,
    required this.displayName,
    required this.isSeeded,
    this.isEditable = false,
    this.description = '',
    this.permissionKeys = const <String>[],
  });

  final String roleId;
  final String roleKey;
  final String displayName;
  final bool isSeeded;
  final bool isEditable;
  final String description;

  /// Frozen catalog keys this fixture role grants with `effect=allow`.
  /// Demo data only - the live catalog ships the authoritative grants
  /// via the `/v1/admin/auth/roles` projection.
  final List<String> permissionKeys;
}

/// Allow-set per seeded role for the demo flavor. Mirrors the baseline
/// grants documented in `docs/contracts/auth_permission_key_catalog.md`
/// closely enough to drive a believable Roles + Permission Explainer
/// walkthrough; live data still wins via the proxy projection.
const List<String> _kDemoOperatorOwnerPermissions = <String>[
  'product.forgeflow.access',
  'forgeflow.shift.view',
  'forgeflow.shift.edit',
  'forgeflow.variance.view',
  'forgeflow.variance.edit',
  'forgeflow.schedule.view',
  'forgeflow.schedule.edit',
  'forgeflow.history.view',
  'forgeflow.benchmark.view',
  'forgeflow.target_profile.view',
  'forgeflow.target_profile.manage',
  'forgeflow.target_cycle.view',
  'forgeflow.weekly_plan.view',
  'forgeflow.weekly_plan.lock',
  'forgeflow.settings.view',
  'forgeflow.settings.manage',
  'team.users.view',
  'team.users.invite',
  'team.users.deactivate',
  'team.users.reactivate',
  'team.users.soft_delete',
  'team.users.reset_password',
  'team.users.reset_mfa',
  'team.roles.view',
  'team.roles.create_custom',
  'team.roles.assign',
  'team.roles.revoke',
  'team.audit_log.view',
  'team.session.force_logout',
  'billing.invoice.view',
  'billing.usage.view',
  'integrations.configure',
];

const List<String> _kDemoOperatorManagerPermissions = <String>[
  'product.forgeflow.access',
  'forgeflow.shift.view',
  'forgeflow.shift.edit',
  'forgeflow.variance.view',
  'forgeflow.variance.edit',
  'forgeflow.schedule.view',
  'forgeflow.schedule.edit',
  'forgeflow.history.view',
  'forgeflow.weekly_plan.view',
  'forgeflow.settings.view',
  'team.users.view',
  'team.users.invite',
  'team.users.reactivate',
  'team.users.reset_password',
  'team.roles.view',
  'team.roles.assign',
  'team.roles.revoke',
  'team.audit_log.view',
  'team.session.force_logout',
];

const List<String> _kDemoOperatorSupervisorPermissions = <String>[
  'product.forgeflow.access',
  'forgeflow.shift.view',
  'forgeflow.variance.view',
  'forgeflow.schedule.view',
  'forgeflow.history.view',
  'barrio.supervisor_content.view',
];

const List<String> _kDemoOperatorStaffPermissions = <String>[
  'product.forgeflow.access',
  'forgeflow.shift.view',
  'barrio.handbook.view',
  'barrio.learning.complete_unit',
  'barrio.streak.view',
];

const List<String> _kDemoLocationManagerPermissions = <String>[
  'product.forgeflow.access',
  'forgeflow.shift.view',
  'forgeflow.shift.edit',
  'forgeflow.variance.view',
  'forgeflow.schedule.view',
  'forgeflow.history.view',
  'team.users.view',
  'team.roles.view',
];

/// Custom-role allow-set for the demo Floor Captain. Mirrors the
/// "1 custom role with a 4-permission subset" description in the
/// parity contract demo-fixture rules.
const List<String> _kDemoFloorCaptainPermissions = <String>[
  'forgeflow.shift.view',
  'forgeflow.shift.edit',
  'forgeflow.variance.view',
  'forgeflow.history.view',
];

const List<DemoTeamRoleFixture> kDemoTeamRolesFixture = <DemoTeamRoleFixture>[
  DemoTeamRoleFixture(
    roleId: 'role-operator-owner',
    roleKey: 'operator_owner',
    displayName: 'Owner',
    isSeeded: true,
    description:
        'Operator owner. Full operational + operator-scoped admin + '
        'integrations.',
    permissionKeys: _kDemoOperatorOwnerPermissions,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-operator-manager',
    roleKey: 'operator_manager',
    displayName: 'Manager',
    isSeeded: true,
    description:
        'Manager-level operator user. Broad operational; limited admin.',
    permissionKeys: _kDemoOperatorManagerPermissions,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-operator-supervisor',
    roleKey: 'operator_supervisor',
    displayName: 'Supervisor',
    isSeeded: true,
    description: 'Supervisor-level. Selected operational + supervisor learning.',
    permissionKeys: _kDemoOperatorSupervisorPermissions,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-operator-staff',
    roleKey: 'operator_staff',
    displayName: 'Staff',
    isSeeded: true,
    description: 'Line-level. Barrio learning surfaces only by default.',
    permissionKeys: _kDemoOperatorStaffPermissions,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-location-manager',
    roleKey: 'location_manager',
    displayName: 'Location manager',
    isSeeded: true,
    description: 'Single-location manager. Read-only roles + members.',
    permissionKeys: _kDemoLocationManagerPermissions,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-floor-captain',
    roleKey: 'floor_captain',
    displayName: 'Floor Captain',
    isSeeded: false,
    isEditable: true,
    description:
        'Custom role for the lead server on duty. Reads shift, variance, '
        'and history; can edit shift assignments mid-service.',
    permissionKeys: _kDemoFloorCaptainPermissions,
  ),
];

/// Existing role-grant fixtures the walkthrough needs alongside user
/// rows. The 11W.2 walkthrough creates a fresh custom role + assigns
/// it during the session, so this fixture only carries the seeded
/// grants the Members + Roles screens read on first paint. Each entry
/// matches a row in [kDemoTeamUsersFixture] so the demo gateway can
/// project user grants without a second lookup.
@immutable
class DemoTeamRoleGrantFixture {
  const DemoTeamRoleGrantFixture({
    required this.userRoleId,
    required this.userId,
    required this.roleId,
    required this.scopeType,
    this.locationId,
    this.orgUnitId,
  });

  final String userRoleId;
  final String userId;
  final String roleId;

  /// One of `'operator_wide'`, `'org_unit'`, or `'location'`.
  final String scopeType;
  final String? locationId;
  final String? orgUnitId;
}

const List<DemoTeamRoleGrantFixture> kDemoTeamRoleGrantsFixture =
    <DemoTeamRoleGrantFixture>[
  DemoTeamRoleGrantFixture(
    userRoleId: 'demo-grant-owner',
    userId: 'demo-user-owner',
    roleId: 'role-operator-owner',
    scopeType: 'operator_wide',
  ),
  DemoTeamRoleGrantFixture(
    userRoleId: 'demo-grant-downtown-manager',
    userId: 'demo-user-downtown-manager',
    roleId: 'role-operator-manager',
    scopeType: 'location',
    locationId: 'demo-loc-downtown',
  ),
  DemoTeamRoleGrantFixture(
    userRoleId: 'demo-grant-northloop-locmgr',
    userId: 'demo-user-northloop-locmgr',
    roleId: 'role-location-manager',
    scopeType: 'location',
    locationId: 'demo-loc-north-loop',
  ),
  DemoTeamRoleGrantFixture(
    userRoleId: 'demo-grant-riverside-supervisor',
    userId: 'demo-user-riverside-supervisor',
    roleId: 'role-operator-supervisor',
    scopeType: 'location',
    locationId: 'demo-loc-riverside',
  ),
  DemoTeamRoleGrantFixture(
    userRoleId: 'demo-grant-riverside-staff',
    userId: 'demo-user-riverside-staff',
    roleId: 'role-operator-staff',
    scopeType: 'location',
    locationId: 'demo-loc-riverside',
  ),
  DemoTeamRoleGrantFixture(
    userRoleId: 'demo-grant-floor-captain',
    userId: 'demo-user-downtown-floor-captain',
    roleId: 'role-floor-captain',
    scopeType: 'location',
    locationId: 'demo-loc-downtown',
  ),
];

/// Project a [DemoTeamRoleFixture] into the gateway's
/// [TeamRoleCatalogEntry] shape. Demo gateways feed their fixture map
/// through this helper so live + demo render the same row contract.
TeamRoleCatalogEntry teamRoleEntryFromFixture(DemoTeamRoleFixture fixture) {
  return TeamRoleCatalogEntry(
    roleId: fixture.roleId,
    roleKey: fixture.roleKey,
    displayName: fixture.displayName,
    description: fixture.description,
    isSeeded: fixture.isSeeded,
    isEditable: fixture.isEditable,
    operatorId: fixture.isSeeded ? null : kDemoOperatorIdFixture,
    permissions: List<TeamRolePermissionRule>.unmodifiable(
      fixture.permissionKeys.map(
        (key) => TeamRolePermissionRule(permissionKey: key, effect: 'allow'),
      ),
    ),
  );
}

/// Project a [DemoTeamRoleGrantFixture] into the gateway's
/// [TeamGrantSnapshot] shape so the Members surface + role detail
/// panels reuse the same row contract as the live gateway.
TeamGrantSnapshot teamGrantSnapshotFromFixture(
  DemoTeamRoleGrantFixture fixture, {
  String? roleLabel,
}) {
  return TeamGrantSnapshot(
    userRoleId: fixture.userRoleId,
    roleId: fixture.roleId,
    roleLabel: roleLabel,
    scopeType: fixture.scopeType,
    orgUnitId: fixture.orgUnitId,
    locationId: fixture.locationId,
    effectiveLocationIds: fixture.locationId == null
        ? const <String>[]
        : <String>[fixture.locationId!],
  );
}

/// Six demo users covering each non-admin seeded role plus one
/// custom-role holder. The owner holds an operator-wide grant; the
/// others land at one of the three locations so the location filter
/// has variety. `lastActiveAt` is staggered so the
/// `last_active_at DESC` sort order in the Members list is visible
/// in the walkthrough. Status spread covers active + suspended +
/// dormant_30 + soft_deleted so every status filter chip has at
/// least one matching row in the demo set.
@immutable
class DemoTeamUserFixture {
  const DemoTeamUserFixture({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.roleId,
    required this.roleLabel,
    required this.status,
    this.locationId,
    this.locationLabel,
    this.mfaEnrolled = false,
    this.lastActiveAtIso,
  });

  final String userId;
  final String email;
  final String displayName;
  final String roleId;
  final String roleLabel;

  /// `'active'`, `'suspended'`, `'dormant_30'`, or `'soft_deleted'`.
  /// Matches the parity contract § Members filter set values.
  final String status;
  final String? locationId;
  final String? locationLabel;
  final bool mfaEnrolled;

  /// ISO 8601 UTC timestamp string. Stored as a string so the
  /// fixture is `const`; demo gateways parse on demand.
  final String? lastActiveAtIso;
}

const List<DemoTeamUserFixture> kDemoTeamUsersFixture = <DemoTeamUserFixture>[
  DemoTeamUserFixture(
    userId: 'demo-user-owner',
    email: 'sam.owner@demobistro.test',
    displayName: 'Sam Patel',
    roleId: 'role-operator-owner',
    roleLabel: 'Owner',
    status: 'active',
    mfaEnrolled: true,
    lastActiveAtIso: '2026-05-05T14:32:00Z',
  ),
  DemoTeamUserFixture(
    userId: 'demo-user-downtown-manager',
    email: 'jordan.lee@demobistro.test',
    displayName: 'Jordan Lee',
    roleId: 'role-operator-manager',
    roleLabel: 'Manager',
    status: 'active',
    locationId: 'demo-loc-downtown',
    locationLabel: 'Downtown',
    mfaEnrolled: true,
    lastActiveAtIso: '2026-05-05T11:05:00Z',
  ),
  DemoTeamUserFixture(
    userId: 'demo-user-northloop-locmgr',
    email: 'taylor.kim@demobistro.test',
    displayName: 'Taylor Kim',
    roleId: 'role-location-manager',
    roleLabel: 'Location manager',
    status: 'active',
    locationId: 'demo-loc-north-loop',
    locationLabel: 'North Loop',
    mfaEnrolled: false,
    lastActiveAtIso: '2026-05-04T22:10:00Z',
  ),
  DemoTeamUserFixture(
    userId: 'demo-user-riverside-supervisor',
    email: 'morgan.rivers@demobistro.test',
    displayName: 'Morgan Rivers',
    roleId: 'role-operator-supervisor',
    roleLabel: 'Supervisor',
    status: 'suspended',
    locationId: 'demo-loc-riverside',
    locationLabel: 'Riverside',
    mfaEnrolled: true,
    lastActiveAtIso: '2026-04-29T18:42:00Z',
  ),
  DemoTeamUserFixture(
    userId: 'demo-user-riverside-staff',
    email: 'casey.brooks@demobistro.test',
    displayName: 'Casey Brooks',
    roleId: 'role-operator-staff',
    roleLabel: 'Staff',
    status: 'dormant_30',
    locationId: 'demo-loc-riverside',
    locationLabel: 'Riverside',
    mfaEnrolled: false,
    lastActiveAtIso: '2026-04-02T08:15:00Z',
  ),
  DemoTeamUserFixture(
    userId: 'demo-user-downtown-floor-captain',
    email: 'dakota.singh@demobistro.test',
    displayName: 'Dakota Singh',
    roleId: 'role-floor-captain',
    roleLabel: 'Floor Captain',
    status: 'soft_deleted',
    locationId: 'demo-loc-downtown',
    locationLabel: 'Downtown',
    mfaEnrolled: false,
    lastActiveAtIso: '2026-03-18T19:45:00Z',
  ),
];

/// One pending invite so the Members invite-dialog walkthrough has a
/// row to compare against after submission. Fixture-only; the demo
/// gateway echoes new invites back into its own session-local list.
@immutable
class DemoTeamInviteFixture {
  const DemoTeamInviteFixture({
    required this.inviteId,
    required this.email,
    required this.roleId,
    required this.roleLabel,
    required this.scopeType,
    required this.expiresAtIso,
    required this.createdAtIso,
    this.locationId,
    this.locationLabel,
  });

  final String inviteId;
  final String email;
  final String roleId;
  final String roleLabel;
  final String scopeType;
  final String? locationId;
  final String? locationLabel;
  final String expiresAtIso;
  final String createdAtIso;
}

const List<DemoTeamInviteFixture> kDemoTeamInvitesFixture =
    <DemoTeamInviteFixture>[
  DemoTeamInviteFixture(
    inviteId: 'demo-invite-pending-1',
    email: 'avery.lopez@demobistro.test',
    roleId: 'role-operator-staff',
    roleLabel: 'Staff',
    scopeType: 'location',
    locationId: 'demo-loc-downtown',
    locationLabel: 'Downtown',
    expiresAtIso: '2026-05-12T17:00:00Z',
    createdAtIso: '2026-05-05T09:30:00Z',
  ),
];

/// Project the user fixture into the gateway's [TeamUserListEntry]
/// shape so demo and live consumers share one row contract.
TeamUserListEntry teamUserEntryFromFixture(DemoTeamUserFixture fixture) {
  return TeamUserListEntry(
    userId: fixture.userId,
    email: fixture.email,
    displayName: fixture.displayName,
    roleId: fixture.roleId,
    roleLabel: fixture.roleLabel,
    status: fixture.status,
    locationId: fixture.locationId,
    locationLabel: fixture.locationLabel,
    mfaEnrolled: fixture.mfaEnrolled,
    lastActiveAt: fixture.lastActiveAtIso == null
        ? null
        : DateTime.parse(fixture.lastActiveAtIso!).toUtc(),
  );
}

/// Project the invite fixture into the gateway's [TeamInviteListEntry]
/// shape.
TeamInviteListEntry teamInviteEntryFromFixture(DemoTeamInviteFixture fixture) {
  return TeamInviteListEntry(
    inviteId: fixture.inviteId,
    email: fixture.email,
    roleId: fixture.roleId,
    roleLabel: fixture.roleLabel,
    scopeType: fixture.scopeType,
    locationId: fixture.locationId,
    locationLabel: fixture.locationLabel,
    expiresAt: DateTime.parse(fixture.expiresAtIso).toUtc(),
    createdAt: DateTime.parse(fixture.createdAtIso).toUtc(),
  );
}
