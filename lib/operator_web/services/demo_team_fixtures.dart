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

/// Region grouping (11W.3 walks the tree as the corp root `Demo Bistro`
/// containing East Region (Downtown + North Loop) and West Region
/// (Riverside)). `unitType` matches the catalog the mobile reference
/// renders (`corp`, `region`, `district`, `location_group`); `path`
/// mirrors the Postgres `ltree` shape Phase 9 ships so the gateway
/// projection produces the same `TeamOrgUnitEntry.path` shape the
/// mobile widget already understands.
class DemoTeamOrgUnitFixture {
  const DemoTeamOrgUnitFixture({
    required this.orgUnitId,
    required this.name,
    required this.unitType,
    required this.path,
    this.parentOrgUnitId,
  });

  final String orgUnitId;
  final String name;
  final String unitType;
  final String path;
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

/// Org-unit tree fixture. 11W.3 renders the corp root + two regions;
/// 11W.1 surfaces the regions only (corp root is the implicit owner
/// label). New entries should keep `path` consistent with the
/// `parentOrgUnitId` chain so the gateway projection lines up.
const List<DemoTeamOrgUnitFixture> kDemoTeamOrgUnitsFixture =
    <DemoTeamOrgUnitFixture>[
  DemoTeamOrgUnitFixture(
    orgUnitId: 'demo-org-root',
    name: 'Demo Bistro',
    unitType: 'corp',
    path: 'demo_bistro',
  ),
  DemoTeamOrgUnitFixture(
    orgUnitId: 'demo-org-east',
    name: 'East Region',
    unitType: 'region',
    path: 'demo_bistro.east_region',
    parentOrgUnitId: 'demo-org-root',
  ),
  DemoTeamOrgUnitFixture(
    orgUnitId: 'demo-org-west',
    name: 'West Region',
    unitType: 'region',
    path: 'demo_bistro.west_region',
    parentOrgUnitId: 'demo-org-root',
  ),
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

/// Project an org-unit fixture into the gateway's [TeamOrgUnitEntry]
/// shape so the demo + live hierarchy gateways share one row contract.
/// 11W.3 consumes this; 11W.1 (Members) does not — it reads the
/// fixture struct directly for its location dropdown labels.
TeamOrgUnitEntry teamOrgUnitEntryFromFixture(DemoTeamOrgUnitFixture fixture) {
  return TeamOrgUnitEntry(
    orgUnitId: fixture.orgUnitId,
    parentOrgUnitId: fixture.parentOrgUnitId,
    unitType: fixture.unitType,
    path: fixture.path,
    label: fixture.name,
  );
}

/// Project a location fixture into the gateway's [TeamOrgLocationEntry]
/// shape. Resolves the parent org-unit's `path` from the org-unit
/// fixture set so the projection matches the live proxy payload shape.
TeamOrgLocationEntry teamOrgLocationEntryFromFixture(
  DemoTeamLocationFixture fixture, {
  List<DemoTeamOrgUnitFixture> orgUnits = kDemoTeamOrgUnitsFixture,
}) {
  final parent = orgUnits.firstWhere(
    (unit) => unit.orgUnitId == fixture.orgUnitId,
    orElse: () => const DemoTeamOrgUnitFixture(
      orgUnitId: '',
      name: '',
      unitType: 'region',
      path: '',
    ),
  );
  return TeamOrgLocationEntry(
    locationId: fixture.locationId,
    parentOrgUnitId: fixture.orgUnitId,
    orgUnitPath: parent.path,
    label: fixture.name,
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

/// 11W.4 Sessions — fixture session ledger snapshot. Four rows: the
/// owner is signed in concurrently on web + mobile (so the unified
/// list walkthrough has two owner-owned rows), the Downtown manager
/// is on mobile only, and the North Loop location manager is on
/// mobile only. Two of the four point at the demo owner so the
/// owner walkthrough sees both their own devices in the unified
/// `Your sessions` list. Order is deliberate: the owner's web
/// session is the freshest (matches the walkthrough where the
/// operator just signed in on web).
@immutable
class DemoTeamSessionFixture {
  const DemoTeamSessionFixture({
    required this.sessionId,
    required this.userId,
    required this.userDisplayName,
    required this.userEmail,
    required this.deviceLabel,
    required this.userAgent,
    required this.deviceFingerprint,
    required this.geoCity,
    required this.geoCountry,
    required this.lastActiveAtIso,
    required this.createdAtIso,
  });

  /// Stable id for the session row. Used by the screen to mark the
  /// `(this session)` chip when the row's `sessionId` matches the
  /// actor's current session id.
  final String sessionId;

  /// Target user the row belongs to. Lets the team-sessions view
  /// render `display_name` + email next to the device label.
  final String userId;
  final String userDisplayName;
  final String userEmail;

  /// Friendly browser + OS pairing rendered as the row's primary
  /// label. Falls back to [userAgent] when the screen wants the raw
  /// string.
  final String deviceLabel;
  final String userAgent;
  final String deviceFingerprint;

  /// City-level geo hint per the parity contract `§ Sessions` rule
  /// (city-level only, never raw IP). The [DemoTeamSessionFixture]
  /// intentionally does NOT carry an IP field so the demo screen
  /// cannot accidentally surface raw IPs.
  final String geoCity;
  final String geoCountry;

  final String lastActiveAtIso;
  final String createdAtIso;
}

/// Stable id of the row the operator-web walkthrough treats as the
/// current web session. Demo flavor pins this so the
/// `(this session)` chip lights up on a known row.
const String kDemoTeamSessionThisSessionId = 'demo-session-owner-web';

/// Stable id of the owner's mobile session — the walkthrough revokes
/// this row first so the mobile device drops to login while the web
/// session keeps rendering.
const String kDemoTeamSessionOwnerMobileId = 'demo-session-owner-mobile';

/// Stable id of the demo team-users fixture's owner row. The demo
/// sessions gateway defaults to this id when filtering own-sessions,
/// so the `Your sessions` section in the walkthrough surfaces the
/// two owner-owned session rows. Note this is the team-users
/// fixture's id, NOT the operator-web auth-source's session uid
/// (`kDemoOperatorWebSession.uid` lives in a different namespace);
/// the demo sessions gateway pins to this fixture id explicitly so
/// the dependency stays visible.
const String kDemoTeamSessionOwnerActorUserId = 'demo-user-owner';

const List<DemoTeamSessionFixture> kDemoTeamSessionsFixture =
    <DemoTeamSessionFixture>[
  DemoTeamSessionFixture(
    sessionId: kDemoTeamSessionThisSessionId,
    userId: 'demo-user-owner',
    userDisplayName: 'Sam Patel',
    userEmail: 'sam.owner@demobistro.test',
    deviceLabel: 'Chrome on macOS',
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) Chrome/124.0',
    deviceFingerprint: 'fp-owner-web-chrome',
    geoCity: 'Toronto',
    geoCountry: 'CA',
    lastActiveAtIso: '2026-05-05T14:30:00Z',
    createdAtIso: '2026-05-05T14:00:00Z',
  ),
  DemoTeamSessionFixture(
    sessionId: kDemoTeamSessionOwnerMobileId,
    userId: 'demo-user-owner',
    userDisplayName: 'Sam Patel',
    userEmail: 'sam.owner@demobistro.test',
    deviceLabel: 'Forge and Flow on iPhone',
    userAgent: 'ForgeAndFlow/1.0 (iPhone; iOS 18.1)',
    deviceFingerprint: 'fp-owner-mobile-ios',
    geoCity: 'Toronto',
    geoCountry: 'CA',
    lastActiveAtIso: '2026-05-05T13:20:00Z',
    createdAtIso: '2026-05-04T09:15:00Z',
  ),
  DemoTeamSessionFixture(
    sessionId: 'demo-session-downtown-manager-mobile',
    userId: 'demo-user-downtown-manager',
    userDisplayName: 'Jordan Lee',
    userEmail: 'jordan.lee@demobistro.test',
    deviceLabel: 'Forge and Flow on Android',
    userAgent: 'ForgeAndFlow/1.0 (Pixel 8; Android 15)',
    deviceFingerprint: 'fp-jordan-mobile-android',
    geoCity: 'Toronto',
    geoCountry: 'CA',
    lastActiveAtIso: '2026-05-05T11:00:00Z',
    createdAtIso: '2026-05-03T08:42:00Z',
  ),
  DemoTeamSessionFixture(
    sessionId: 'demo-session-northloop-locmgr-mobile',
    userId: 'demo-user-northloop-locmgr',
    userDisplayName: 'Taylor Kim',
    userEmail: 'taylor.kim@demobistro.test',
    deviceLabel: 'Forge and Flow on iPhone',
    userAgent: 'ForgeAndFlow/1.0 (iPhone; iOS 17.6)',
    deviceFingerprint: 'fp-taylor-mobile-ios',
    geoCity: 'Mississauga',
    geoCountry: 'CA',
    lastActiveAtIso: '2026-05-04T22:05:00Z',
    createdAtIso: '2026-05-01T17:30:00Z',
  ),
];

/// 11W.5 Audit Log - fixture audit_logs row snapshot. Roughly 50
/// entries across the last 30 days, covering invite / role-grant /
/// password-change / mfa-enroll / session-revoke actions, with a
/// mix of actor identities so the actor + action filter chips have
/// variety. Each row carries the parity contract `§ Audit-row shape`
/// fields (action, actor identity, actor_kind, target_kind +
/// target_id, payload, created_at). `admin_reason` stays null in the
/// self-service fixture; the `11A.14` admin walkthrough adds rows
/// that populate it.
@immutable
class DemoAuditLogEntryFixture {
  const DemoAuditLogEntryFixture({
    required this.entryId,
    required this.action,
    required this.actorUserId,
    required this.actorDisplayName,
    required this.actorEmail,
    required this.createdAtIso,
    this.actorKind = 'team_member',
    this.targetKind,
    this.targetId,
    this.payload = const <String, Object?>{},
    this.adminReason,
  });

  final String entryId;
  final String action;
  final String actorUserId;
  final String actorDisplayName;
  final String actorEmail;

  /// `team_member` | `forge_admin` | `service_principal`. Self-service
  /// fixture uses `team_member` exclusively.
  final String actorKind;

  final String? targetKind;
  final String? targetId;
  final Map<String, Object?> payload;
  final String? adminReason;

  final String createdAtIso;
}

/// Fifty audit-log fixture entries spanning 2026-04-06 to 2026-05-05.
/// Sorted newest-first so the demo gateway can serve them without an
/// extra sort. Action coverage hits every row of the parity contract
/// `§ Per-surface parity rules` example set so each filter chip in the
/// screen has at least one matching row.
const List<DemoAuditLogEntryFixture> kDemoAuditLogEntriesFixture =
    <DemoAuditLogEntryFixture>[
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-001',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-owner-web',
    payload: <String, Object?>{
      'device_label': 'Chrome on macOS',
      'geo_country': 'CA',
    },
    createdAtIso: '2026-05-05T14:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-002',
    action: 'team.users.invite',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_invite',
    targetId: 'demo-invite-pending-1',
    payload: <String, Object?>{
      'email': 'avery.lopez@demobistro.test',
      'role_key': 'operator_staff',
      'location_id': 'demo-loc-downtown',
    },
    createdAtIso: '2026-05-05T09:30:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-003',
    action: 'team.roles.assign',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'role_grant',
    targetId: 'demo-grant-floor-captain',
    payload: <String, Object?>{
      'role_id': 'role-floor-captain',
      'user_id': 'demo-user-downtown-floor-captain',
      'scope_type': 'location',
      'location_id': 'demo-loc-downtown',
    },
    createdAtIso: '2026-05-04T16:42:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-004',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-downtown-manager',
    actorDisplayName: 'Jordan Lee',
    actorEmail: 'jordan.lee@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-downtown-manager-mobile',
    payload: <String, Object?>{
      'device_label': 'Forge and Flow on Android',
    },
    createdAtIso: '2026-05-04T11:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-005',
    action: 'team.roles.create_custom',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'role',
    targetId: 'role-floor-captain',
    payload: <String, Object?>{
      'role_key': 'floor_captain',
      'display_name': 'Floor Captain',
      'permission_count': 4,
    },
    createdAtIso: '2026-05-03T18:14:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-006',
    action: 'auth.password_changed',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_user',
    targetId: 'demo-user-owner',
    createdAtIso: '2026-05-03T15:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-007',
    action: 'auth.mfa_totp_enrolled',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_mfa_factor',
    targetId: 'demo-mfa-factor-owner-totp',
    payload: <String, Object?>{'factor_type': 'totp'},
    createdAtIso: '2026-05-03T14:55:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-008',
    action: 'team.users.invite',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_invite',
    targetId: 'demo-invite-historic-2',
    payload: <String, Object?>{
      'email': 'kris.tan@demobistro.test',
      'role_key': 'operator_supervisor',
    },
    createdAtIso: '2026-05-02T19:21:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-009',
    action: 'team.users.deactivate',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_user',
    targetId: 'demo-user-riverside-supervisor',
    payload: <String, Object?>{'reason': 'leave_of_absence'},
    createdAtIso: '2026-05-02T08:30:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-010',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-owner-2',
    createdAtIso: '2026-05-02T07:45:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-011',
    action: 'team.org_unit.move',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'org_unit',
    targetId: 'demo-org-east',
    payload: <String, Object?>{
      'previous_parent': 'demo-org-root',
      'new_parent': 'demo-org-root',
      'note': 'no-op realignment',
    },
    createdAtIso: '2026-05-01T22:10:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-012',
    action: 'team.session.force_logout',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-revoked-1',
    payload: <String, Object?>{
      'target_user_id': 'demo-user-northloop-locmgr',
      'reason': 'lost_device',
    },
    createdAtIso: '2026-05-01T16:55:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-013',
    action: 'team.users.reset_password',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_user',
    targetId: 'demo-user-northloop-locmgr',
    createdAtIso: '2026-05-01T16:54:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-014',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-northloop-locmgr',
    actorDisplayName: 'Taylor Kim',
    actorEmail: 'taylor.kim@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-northloop-locmgr-mobile',
    createdAtIso: '2026-05-01T17:30:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-015',
    action: 'team.roles.assign',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'role_grant',
    targetId: 'demo-grant-northloop-locmgr',
    payload: <String, Object?>{
      'role_id': 'role-location-manager',
      'user_id': 'demo-user-northloop-locmgr',
      'scope_type': 'location',
      'location_id': 'demo-loc-north-loop',
    },
    createdAtIso: '2026-04-30T12:18:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-016',
    action: 'team.users.invite',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_invite',
    targetId: 'demo-invite-historic-3',
    payload: <String, Object?>{
      'email': 'taylor.kim@demobistro.test',
      'role_key': 'location_manager',
    },
    createdAtIso: '2026-04-30T11:55:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-017',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-riverside-supervisor',
    actorDisplayName: 'Morgan Rivers',
    actorEmail: 'morgan.rivers@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-riverside-1',
    createdAtIso: '2026-04-29T18:42:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-018',
    action: 'auth.mfa_factor_removed',
    actorUserId: 'demo-user-riverside-supervisor',
    actorDisplayName: 'Morgan Rivers',
    actorEmail: 'morgan.rivers@demobistro.test',
    targetKind: 'auth_mfa_factor',
    targetId: 'demo-mfa-factor-riverside-sms',
    payload: <String, Object?>{'factor_type': 'sms'},
    createdAtIso: '2026-04-29T18:01:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-019',
    action: 'team.users.reset_mfa',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_user',
    targetId: 'demo-user-riverside-supervisor',
    createdAtIso: '2026-04-29T16:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-020',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-owner-3',
    createdAtIso: '2026-04-28T08:20:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-021',
    action: 'team.users.invite',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_invite',
    targetId: 'demo-invite-historic-4',
    payload: <String, Object?>{
      'email': 'jordan.lee@demobistro.test',
      'role_key': 'operator_manager',
    },
    createdAtIso: '2026-04-27T13:14:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-022',
    action: 'team.roles.assign',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'role_grant',
    targetId: 'demo-grant-downtown-manager',
    payload: <String, Object?>{
      'role_id': 'role-operator-manager',
      'user_id': 'demo-user-downtown-manager',
      'scope_type': 'location',
      'location_id': 'demo-loc-downtown',
    },
    createdAtIso: '2026-04-27T13:15:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-023',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-downtown-manager',
    actorDisplayName: 'Jordan Lee',
    actorEmail: 'jordan.lee@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-downtown-1',
    createdAtIso: '2026-04-26T09:11:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-024',
    action: 'auth.password_changed',
    actorUserId: 'demo-user-downtown-manager',
    actorDisplayName: 'Jordan Lee',
    actorEmail: 'jordan.lee@demobistro.test',
    targetKind: 'auth_user',
    targetId: 'demo-user-downtown-manager',
    createdAtIso: '2026-04-26T09:08:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-025',
    action: 'auth.mfa_totp_enrolled',
    actorUserId: 'demo-user-downtown-manager',
    actorDisplayName: 'Jordan Lee',
    actorEmail: 'jordan.lee@demobistro.test',
    targetKind: 'auth_mfa_factor',
    targetId: 'demo-mfa-factor-downtown-totp',
    payload: <String, Object?>{'factor_type': 'totp'},
    createdAtIso: '2026-04-26T09:05:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-026',
    action: 'team.session.force_logout',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-revoked-2',
    payload: <String, Object?>{
      'target_user_id': 'demo-user-riverside-staff',
      'reason': 'shared_device',
    },
    createdAtIso: '2026-04-25T20:30:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-027',
    action: 'team.users.invite',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_invite',
    targetId: 'demo-invite-historic-5',
    payload: <String, Object?>{
      'email': 'casey.brooks@demobistro.test',
      'role_key': 'operator_staff',
    },
    createdAtIso: '2026-04-24T11:02:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-028',
    action: 'team.roles.assign',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'role_grant',
    targetId: 'demo-grant-riverside-staff',
    payload: <String, Object?>{
      'role_id': 'role-operator-staff',
      'user_id': 'demo-user-riverside-staff',
      'scope_type': 'location',
      'location_id': 'demo-loc-riverside',
    },
    createdAtIso: '2026-04-24T11:03:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-029',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-riverside-staff',
    actorDisplayName: 'Casey Brooks',
    actorEmail: 'casey.brooks@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-riverside-staff-1',
    createdAtIso: '2026-04-22T08:30:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-030',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-owner-4',
    createdAtIso: '2026-04-21T14:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-031',
    action: 'team.users.invite',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_invite',
    targetId: 'demo-invite-historic-6',
    payload: <String, Object?>{
      'email': 'morgan.rivers@demobistro.test',
      'role_key': 'operator_supervisor',
    },
    createdAtIso: '2026-04-20T10:18:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-032',
    action: 'team.roles.assign',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'role_grant',
    targetId: 'demo-grant-riverside-supervisor',
    payload: <String, Object?>{
      'role_id': 'role-operator-supervisor',
      'user_id': 'demo-user-riverside-supervisor',
      'scope_type': 'location',
      'location_id': 'demo-loc-riverside',
    },
    createdAtIso: '2026-04-20T10:19:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-033',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-riverside-supervisor',
    actorDisplayName: 'Morgan Rivers',
    actorEmail: 'morgan.rivers@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-riverside-2',
    createdAtIso: '2026-04-19T17:45:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-034',
    action: 'team.roles.revoke',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'role_grant',
    targetId: 'demo-grant-historic-revoked-1',
    payload: <String, Object?>{
      'role_id': 'role-operator-staff',
      'user_id': 'demo-user-historic-departing-1',
    },
    createdAtIso: '2026-04-18T15:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-035',
    action: 'team.users.soft_delete',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_user',
    targetId: 'demo-user-historic-departing-1',
    payload: <String, Object?>{'reason': 'employment_ended'},
    createdAtIso: '2026-04-18T15:01:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-036',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-owner-5',
    createdAtIso: '2026-04-17T09:14:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-037',
    action: 'team.users.invite',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_invite',
    targetId: 'demo-invite-historic-7',
    payload: <String, Object?>{
      'email': 'dakota.singh@demobistro.test',
      'role_key': 'floor_captain',
    },
    createdAtIso: '2026-04-16T13:50:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-038',
    action: 'team.roles.assign',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'role_grant',
    targetId: 'demo-grant-floor-captain-historic',
    payload: <String, Object?>{
      'role_id': 'role-floor-captain',
      'user_id': 'demo-user-downtown-floor-captain',
      'scope_type': 'location',
      'location_id': 'demo-loc-downtown',
    },
    createdAtIso: '2026-04-16T13:52:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-039',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-downtown-floor-captain',
    actorDisplayName: 'Dakota Singh',
    actorEmail: 'dakota.singh@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-downtown-fc-1',
    createdAtIso: '2026-04-15T16:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-040',
    action: 'team.org_unit.move',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'org_unit',
    targetId: 'demo-org-west',
    payload: <String, Object?>{
      'previous_parent': null,
      'new_parent': 'demo-org-root',
    },
    createdAtIso: '2026-04-14T11:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-041',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-owner-6',
    createdAtIso: '2026-04-13T08:18:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-042',
    action: 'auth.password_changed',
    actorUserId: 'demo-user-northloop-locmgr',
    actorDisplayName: 'Taylor Kim',
    actorEmail: 'taylor.kim@demobistro.test',
    targetKind: 'auth_user',
    targetId: 'demo-user-northloop-locmgr',
    createdAtIso: '2026-04-12T19:14:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-043',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-northloop-locmgr',
    actorDisplayName: 'Taylor Kim',
    actorEmail: 'taylor.kim@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-northloop-1',
    createdAtIso: '2026-04-12T19:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-044',
    action: 'team.users.reactivate',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_user',
    targetId: 'demo-user-historic-returning-1',
    createdAtIso: '2026-04-11T17:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-045',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-owner-7',
    createdAtIso: '2026-04-10T07:55:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-046',
    action: 'team.users.invite',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'team_invite',
    targetId: 'demo-invite-historic-8',
    payload: <String, Object?>{
      'email': 'sam.partner@demobistro.test',
      'role_key': 'operator_owner',
    },
    createdAtIso: '2026-04-09T14:30:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-047',
    action: 'team.roles.assign',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'role_grant',
    targetId: 'demo-grant-owner',
    payload: <String, Object?>{
      'role_id': 'role-operator-owner',
      'user_id': 'demo-user-owner',
      'scope_type': 'operator_wide',
    },
    createdAtIso: '2026-04-08T10:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-048',
    action: 'auth.mfa_totp_enrolled',
    actorUserId: 'demo-user-northloop-locmgr',
    actorDisplayName: 'Taylor Kim',
    actorEmail: 'taylor.kim@demobistro.test',
    targetKind: 'auth_mfa_factor',
    targetId: 'demo-mfa-factor-northloop-totp',
    payload: <String, Object?>{'factor_type': 'totp'},
    createdAtIso: '2026-04-07T18:30:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-049',
    action: 'auth.session_revoked',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-owner-1',
    payload: <String, Object?>{'reason': 'sign_out_all_devices'},
    createdAtIso: '2026-04-07T08:00:00Z',
  ),
  DemoAuditLogEntryFixture(
    entryId: 'demo-audit-050',
    action: 'auth.user.signed_in',
    actorUserId: 'demo-user-owner',
    actorDisplayName: 'Sam Patel',
    actorEmail: 'sam.owner@demobistro.test',
    targetKind: 'auth_session',
    targetId: 'demo-session-historic-owner-8',
    createdAtIso: '2026-04-06T07:42:00Z',
  ),
];

/// 11W.6 Security - the actor's own MFA factor inventory. Demo flavor
/// pins the demo owner with one active TOTP factor so the walkthrough
/// can exercise the revoke -> 24-hour delayed removal -> cancel flow
/// without first running an enrollment. The walkthrough then enrolls
/// a second factor to land on the contract's "enroll a TOTP factor"
/// step.
@immutable
class DemoTeamMfaFactorFixture {
  const DemoTeamMfaFactorFixture({
    required this.factorId,
    required this.factorType,
    required this.enrolledAtIso,
    required this.issuerLabel,
    this.lastUsedAtIso,
    this.canRevoke = true,
  });

  final String factorId;
  final String factorType;
  final String enrolledAtIso;
  final String? lastUsedAtIso;
  final String issuerLabel;
  final bool canRevoke;
}

/// Stable id for the demo owner's existing TOTP factor. The
/// walkthrough revokes this factor first to show the 24-hour
/// delayed-removal posture.
const String kDemoSecurityExistingFactorId = 'demo-security-totp-existing';

const List<DemoTeamMfaFactorFixture> kDemoTeamMfaFactorsFixture =
    <DemoTeamMfaFactorFixture>[
  DemoTeamMfaFactorFixture(
    factorId: kDemoSecurityExistingFactorId,
    factorType: 'totp',
    enrolledAtIso: '2026-04-12T16:00:00Z',
    lastUsedAtIso: '2026-05-05T14:00:00Z',
    issuerLabel: 'Forge & Flow',
  ),
];

/// 11W.6 Security - login history fixture. Subset of the audit log
/// the Security screen renders. Mix of `auth.signed_in`,
/// `auth.password_changed`, and `auth.mfa_*` rows spanning the last
/// 7 + 30 + 60 days so the walkthrough's "filter to last 7 days"
/// step has rows on both sides of the cutoff.
@immutable
class DemoTeamLoginHistoryFixture {
  const DemoTeamLoginHistoryFixture({
    required this.eventId,
    required this.eventType,
    required this.occurredAtIso,
    this.deviceLabel,
    this.userAgent,
    this.geoCity,
    this.geoCountry,
  });

  final String eventId;
  final String eventType;
  final String occurredAtIso;
  final String? deviceLabel;
  final String? userAgent;
  final String? geoCity;
  final String? geoCountry;
}

const List<DemoTeamLoginHistoryFixture> kDemoTeamLoginHistoryFixture =
    <DemoTeamLoginHistoryFixture>[
  DemoTeamLoginHistoryFixture(
    eventId: 'demo-history-signin-web-2026-05-05',
    eventType: 'auth.signed_in',
    occurredAtIso: '2026-05-05T14:00:00Z',
    deviceLabel: 'Chrome on macOS',
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) Chrome/124.0',
    geoCity: 'Toronto',
    geoCountry: 'CA',
  ),
  DemoTeamLoginHistoryFixture(
    eventId: 'demo-history-signin-mobile-2026-05-04',
    eventType: 'auth.signed_in',
    occurredAtIso: '2026-05-04T09:15:00Z',
    deviceLabel: 'Forge and Flow on iPhone',
    userAgent: 'ForgeAndFlow/1.0 (iPhone; iOS 18.1)',
    geoCity: 'Toronto',
    geoCountry: 'CA',
  ),
  DemoTeamLoginHistoryFixture(
    eventId: 'demo-history-mfa-enroll-2026-04-12',
    eventType: 'auth.mfa_totp_enrolled',
    occurredAtIso: '2026-04-12T16:00:00Z',
    deviceLabel: 'Chrome on macOS',
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) Chrome/124.0',
    geoCity: 'Toronto',
    geoCountry: 'CA',
  ),
  DemoTeamLoginHistoryFixture(
    eventId: 'demo-history-password-changed-2026-04-10',
    eventType: 'auth.password_changed',
    occurredAtIso: '2026-04-10T11:32:00Z',
    deviceLabel: 'Chrome on macOS',
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) Chrome/124.0',
    geoCity: 'Toronto',
    geoCountry: 'CA',
  ),
  DemoTeamLoginHistoryFixture(
    eventId: 'demo-history-signin-web-2026-03-22',
    eventType: 'auth.signed_in',
    occurredAtIso: '2026-03-22T08:42:00Z',
    deviceLabel: 'Chrome on macOS',
    userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 14_4) Chrome/124.0',
    geoCity: 'Toronto',
    geoCountry: 'CA',
  ),
  DemoTeamLoginHistoryFixture(
    eventId: 'demo-history-session-revoked-2026-03-18',
    eventType: 'auth.session_revoked',
    occurredAtIso: '2026-03-18T19:45:00Z',
    deviceLabel: 'Forge and Flow on iPad',
    userAgent: 'ForgeAndFlow/1.0 (iPad; iOS 17.5)',
    geoCity: 'Toronto',
    geoCountry: 'CA',
  ),
];
