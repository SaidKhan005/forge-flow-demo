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

/// Seeded role catalog the parity slices project from. 11W.2 will
/// expand this with permissions + add the Floor Captain custom role
/// definition; for 11W.1 we only need the role keys + display labels
/// so the Members filter rail and invite dialog can render the
/// dropdown options.
class DemoTeamRoleFixture {
  const DemoTeamRoleFixture({
    required this.roleId,
    required this.roleKey,
    required this.displayName,
    required this.isSeeded,
    this.isEditable = false,
  });

  final String roleId;
  final String roleKey;
  final String displayName;
  final bool isSeeded;
  final bool isEditable;
}

const List<DemoTeamRoleFixture> kDemoTeamRolesFixture = <DemoTeamRoleFixture>[
  DemoTeamRoleFixture(
    roleId: 'role-operator-owner',
    roleKey: 'operator_owner',
    displayName: 'Owner',
    isSeeded: true,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-operator-manager',
    roleKey: 'operator_manager',
    displayName: 'Manager',
    isSeeded: true,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-operator-supervisor',
    roleKey: 'operator_supervisor',
    displayName: 'Supervisor',
    isSeeded: true,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-operator-staff',
    roleKey: 'operator_staff',
    displayName: 'Staff',
    isSeeded: true,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-location-manager',
    roleKey: 'location_manager',
    displayName: 'Location manager',
    isSeeded: true,
  ),
  DemoTeamRoleFixture(
    roleId: 'role-floor-captain',
    roleKey: 'floor_captain',
    displayName: 'Floor Captain',
    isSeeded: false,
    isEditable: true,
  ),
];

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
