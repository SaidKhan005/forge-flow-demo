// Phase 9 live-closeout - proxy auth-operations gateway.
//
// This is the proxy-facing seam for Team/user-management actions. The HTTP
// router validates request shape, verifies the Firebase bearer token, checks
// permissions, and then delegates to this gateway. Production implementations
// own the multi-system write choreography: Firebase Identity Platform,
// Postgres users/auth_invites/user_roles, custom claims, and audit rows.

class TeamInviteCreateCommand {
  const TeamInviteCreateCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.email,
    required this.roleId,
    required this.scopeType,
    this.targetLocationId,
    this.targetOrgUnitId,
    this.operatorOwnerBootstrap = false,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String email;
  final String roleId;
  final String scopeType;
  final String? targetLocationId;
  final String? targetOrgUnitId;

  /// Internal F&F admin-console bootstrap path only.
  ///
  /// When a brand-new operator is being created, the global admin actor cannot
  /// already have an operator-wide grant inside that new tenant. The
  /// operator/location admin route verifies the global admin role before using
  /// this flag for the first operator-owner invite.
  final bool operatorOwnerBootstrap;
}

class TeamInviteCreated {
  const TeamInviteCreated({
    required this.inviteId,
    required this.expiresAt,
    this.userId,
  });

  final String inviteId;
  final DateTime expiresAt;

  /// Postgres/Firebase user id created for the invite when the backing gateway
  /// owns identity creation. HTTP clients may omit it from the public response;
  /// server-side orchestration such as 11A.1 onboarding uses it to attach
  /// `operator_admins` without fabricating a second user row.
  final String? userId;
}

class TeamInviteListCommand {
  const TeamInviteListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

class TeamInviteListEntry {
  const TeamInviteListEntry({
    required this.inviteId,
    required this.email,
    required this.roleId,
    required this.roleLabel,
    required this.scopeType,
    required this.expiresAt,
    required this.createdAt,
    this.locationId,
    this.locationLabel,
    this.orgUnitId,
    this.orgUnitLabel,
  });

  final String inviteId;
  final String email;
  final String roleId;
  final String roleLabel;
  final String scopeType;
  final String? locationId;
  final String? locationLabel;
  final String? orgUnitId;
  final String? orgUnitLabel;
  final DateTime expiresAt;
  final DateTime createdAt;
}

class TeamInvitesListed {
  const TeamInvitesListed({required this.invites});

  final List<TeamInviteListEntry> invites;
}

class TeamInviteRevokeCommand {
  const TeamInviteRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.inviteId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String inviteId;
}

class TeamInviteRevoked {
  const TeamInviteRevoked({required this.revoked});

  final bool revoked;
}

class TeamUserStatusCommand {
  const TeamUserStatusCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    required this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String reason;
}

class TeamUserStatusUpdated {
  const TeamUserStatusUpdated({required this.updated});

  final bool updated;
}

class TeamUserListCommand {
  const TeamUserListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

class TeamUserProfilePatchCommand {
  const TeamUserProfilePatchCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    required this.displayName,
    required this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String displayName;
  final String reason;
}

class TeamUserProfilePatched {
  const TeamUserProfilePatched({required this.user});

  final TeamUserListEntry user;
}

// Phase 9.UX.grant-payload — per-grant snapshot bundled with the team-users
// projection. Mirrors the `user_roles` row shape consumed by the role-change
// dialog's inheritance hint, plus the materialized
// `user_effective_locations` set so an `org_unit` grant carries its
// reachable locations without a follow-up read. Optional / nullable fields
// stay nullable so a `location`-scoped grant (no `org_unit_id`) and an
// `operator_wide` grant (neither location nor org-unit) round-trip cleanly.
class TeamGrantSnapshot {
  const TeamGrantSnapshot({
    required this.userRoleId,
    required this.roleId,
    required this.scopeType,
    this.roleLabel,
    this.orgUnitId,
    this.locationId,
    this.sourceOrgUnitId,
    this.effectiveLocationIds = const <String>[],
    this.validFrom,
    this.validUntil,
    this.revokedAt,
  });

  final String userRoleId;
  final String roleId;

  /// `roles.display_name` for the granted role, joined into the
  /// gateway projection so the role-change dialog never needs the
  /// section's role catalog to resolve a label. Optional for
  /// backward compat with older proxies that might omit the field;
  /// when null the section falls through to its catalog/raw-id
  /// resolver.
  final String? roleLabel;

  /// One of `'operator_wide'`, `'org_unit'`, or `'location'` — matches
  /// the `user_roles.scope_type` CHECK constraint.
  final String scopeType;
  final String? orgUnitId;
  final String? locationId;
  final String? sourceOrgUnitId;
  final List<String> effectiveLocationIds;
  final DateTime? validFrom;
  final DateTime? validUntil;
  final DateTime? revokedAt;
}

class TeamUserListEntry {
  const TeamUserListEntry({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.roleId,
    required this.roleLabel,
    required this.status,
    this.locationId,
    this.locationLabel,
    this.mfaEnrolled = false,
    this.mfaRemovalPending = false,
    this.mfaRemovalRequestId,
    this.userRoleId,
    this.lastActiveAt,
    this.grants = const <TeamGrantSnapshot>[],
  });

  final String userId;
  final String email;
  final String displayName;
  final String roleId;
  final String roleLabel;
  final String status;
  final String? locationId;
  final String? locationLabel;
  final bool mfaEnrolled;
  final bool mfaRemovalPending;
  final String? mfaRemovalRequestId;
  final String? userRoleId;
  final DateTime? lastActiveAt;
  final List<TeamGrantSnapshot> grants;
}

class TeamUsersListed {
  const TeamUsersListed({required this.users});

  final List<TeamUserListEntry> users;
}

class TeamPasswordResetCommand {
  const TeamPasswordResetCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
}

class TeamPasswordResetQueued {
  const TeamPasswordResetQueued();
}

class TeamMfaResetCommand {
  const TeamMfaResetCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    this.stepUpProofId = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String stepUpProofId;
}

class TeamMfaResetQueued {
  const TeamMfaResetQueued({
    required this.requestedCount,
    this.requestIds = const <String>[],
    this.executeAfter,
  });

  final int requestedCount;
  final List<String> requestIds;
  final DateTime? executeAfter;
}

class TeamMfaRemovalCancelCommand {
  const TeamMfaRemovalCancelCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    required this.requestId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String requestId;
}

class TeamMfaRemovalCancelled {
  const TeamMfaRemovalCancelled({required this.cancelled});

  final bool cancelled;
}

class TeamRoleGrantCreateCommand {
  const TeamRoleGrantCreateCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetUserId,
    required this.roleId,
    required this.scopeType,
    this.targetLocationId,
    this.targetOrgUnitId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetUserId;
  final String roleId;
  final String scopeType;
  final String? targetLocationId;
  final String? targetOrgUnitId;
  final String? reason;
}

class TeamRoleGrantCreated {
  const TeamRoleGrantCreated({required this.userRoleId});

  final String userRoleId;
}

class TeamRoleGrantRevokeCommand {
  const TeamRoleGrantRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.userRoleId,
    required this.targetUserId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String userRoleId;
  final String targetUserId;
  final String? reason;
}

class TeamRoleGrantRevoked {
  const TeamRoleGrantRevoked({required this.revoked});

  final bool revoked;
}

// Phase 9.UX.4 — operator org hierarchy.
//
// `org_units` is the per-operator corp/region/district/location_group
// hierarchy stored as a Postgres `ltree` (item 1 / Q2 from
// `phase_9_scalability_decisions_2026-04-27.md`). The Settings → Team →
// Org Hierarchy surface uses these commands to render the tree, add
// child units, and move locations between units. Permission grants at
// any node inherit to descendants; the `user_effective_locations`
// materialized cache from the `202604290101_phase_9_hierarchy_access_wiring`
// migration handles the lookup.
class TeamOrgUnitEntry {
  const TeamOrgUnitEntry({
    required this.orgUnitId,
    required this.parentOrgUnitId,
    required this.unitType,
    required this.path,
    required this.label,
    this.suspendedAt,
    this.deletedAt,
  });

  final String orgUnitId;
  final String? parentOrgUnitId;
  final String unitType;
  final String path;
  final String label;
  final DateTime? suspendedAt;
  final DateTime? deletedAt;
}

class TeamOrgLocationEntry {
  const TeamOrgLocationEntry({
    required this.locationId,
    required this.parentOrgUnitId,
    required this.orgUnitPath,
    required this.label,
    this.suspendedAt,
    this.deletedAt,
  });

  final String locationId;
  final String parentOrgUnitId;
  final String orgUnitPath;
  final String label;
  final DateTime? suspendedAt;
  final DateTime? deletedAt;
}

class TeamOrgHierarchyListCommand {
  const TeamOrgHierarchyListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

class TeamOrgHierarchyListed {
  const TeamOrgHierarchyListed({
    required this.orgUnits,
    required this.locations,
  });

  final List<TeamOrgUnitEntry> orgUnits;
  final List<TeamOrgLocationEntry> locations;
}

class TeamOrgUnitCreateCommand {
  const TeamOrgUnitCreateCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.parentOrgUnitId,
    required this.unitType,
    required this.label,
    required this.name,
    this.adminReason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String parentOrgUnitId;
  final String unitType;
  final String label;
  final String name;
  final String? adminReason;
}

class TeamOrgUnitCreated {
  const TeamOrgUnitCreated({required this.orgUnitId});

  final String orgUnitId;
}

class TeamOrgUnitMoveCommand {
  const TeamOrgUnitMoveCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.orgUnitId,
    required this.parentOrgUnitId,
    this.adminReason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String orgUnitId;
  final String parentOrgUnitId;
  final String? adminReason;
}

class TeamOrgUnitMoved {
  const TeamOrgUnitMoved({required this.orgUnit});

  final TeamOrgUnitEntry orgUnit;
}

class TeamOrgUnitLifecycleCommand {
  const TeamOrgUnitLifecycleCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.orgUnitId,
    required this.adminReason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String orgUnitId;
  final String adminReason;
}

class TeamOrgUnitLifecycleUpdated {
  const TeamOrgUnitLifecycleUpdated({required this.orgUnit});

  final TeamOrgUnitEntry orgUnit;
}

class TeamHierarchyDeleted {
  const TeamHierarchyDeleted({required this.deleted});

  final bool deleted;
}

class TeamLocationOrgUnitMoveCommand {
  const TeamLocationOrgUnitMoveCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetLocationId,
    required this.parentOrgUnitId,
    this.adminReason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetLocationId;
  final String parentOrgUnitId;
  final String? adminReason;
}

class TeamLocationOrgUnitMoved {
  const TeamLocationOrgUnitMoved({required this.moved});

  final bool moved;
}

class TeamLocationLifecycleCommand {
  const TeamLocationLifecycleCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.targetLocationId,
    required this.adminReason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String targetLocationId;
  final String adminReason;
}

class TeamLocationLifecycleUpdated {
  const TeamLocationLifecycleUpdated({required this.location});

  final TeamOrgLocationEntry location;
}

class TeamRolePermissionRule {
  const TeamRolePermissionRule({
    required this.permissionKey,
    required this.effect,
  });

  final String permissionKey;

  /// Either `'allow'` or `'deny'`.
  final String effect;
}

class TeamRolePermissionUpdate {
  const TeamRolePermissionUpdate({
    required this.permissionKey,
    required this.effect,
  });

  final String permissionKey;

  /// `'allow'` / `'deny'` upserts a rule. `null` removes the explicit
  /// rule so the permission falls back to inherited/default behavior.
  final String? effect;
}

class TeamRoleCatalogEntry {
  const TeamRoleCatalogEntry({
    required this.roleId,
    required this.roleKey,
    required this.displayName,
    required this.description,
    required this.isSeeded,
    required this.isEditable,
    required this.permissions,
    this.operatorId,
  });

  final String roleId;
  final String roleKey;
  final String displayName;
  final String description;
  final bool isSeeded;
  final bool isEditable;
  final String? operatorId;
  final List<TeamRolePermissionRule> permissions;
}

class TeamRoleCatalogListCommand {
  const TeamRoleCatalogListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.scope,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;

  /// `all` (default), `global` / `seeded`, or `operator` / `custom`.
  final String? scope;
}

class TeamRoleCatalogListed {
  const TeamRoleCatalogListed({required this.roles});

  final List<TeamRoleCatalogEntry> roles;
}

class TeamRoleCreateCommand {
  const TeamRoleCreateCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.roleKey,
    required this.displayName,
    this.description = '',
    this.permissions = const <TeamRolePermissionUpdate>[],
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String roleKey;
  final String displayName;
  final String description;
  final List<TeamRolePermissionUpdate> permissions;
  final String? reason;
}

class TeamRoleCreated {
  const TeamRoleCreated({required this.role});

  final TeamRoleCatalogEntry role;
}

class TeamRolePatchCommand {
  const TeamRolePatchCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.roleId,
    this.displayName,
    this.description,
    this.permissions = const <TeamRolePermissionUpdate>[],
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String roleId;
  final String? displayName;
  final String? description;
  final List<TeamRolePermissionUpdate> permissions;
  final String? reason;
}

class TeamRolePatched {
  const TeamRolePatched({required this.role, required this.bumpedUsers});

  final TeamRoleCatalogEntry role;
  final int bumpedUsers;
}

class TeamRoleDeleteCommand {
  const TeamRoleDeleteCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.roleId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String roleId;
  final String? reason;
}

class TeamRoleDeleted {
  const TeamRoleDeleted({required this.deleted});

  final bool deleted;
}

// Phase 9.UX.1 - self-service MFA factor contract declarations.
//
// The live Settings MFA surface is wired through MfaOperationsGateway. These
// additive value types reserve the auth-operations contract shape for clients
// that need to project a user's own factor inventory through the broader auth
// operations seam without disturbing the Team/role/org methods below.
class MfaSelfFactorSummary {
  const MfaSelfFactorSummary({
    required this.factorId,
    required this.factorType,
    required this.enrolledAt,
    required this.issuerLabel,
    this.lastUsedAt,
    this.canRevoke = true,
  });

  final String factorId;
  final String factorType;
  final DateTime enrolledAt;
  final DateTime? lastUsedAt;
  final String issuerLabel;
  final bool canRevoke;
}

class MfaSelfFactorListCommand {
  const MfaSelfFactorListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.authorizationIdToken = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String authorizationIdToken;
}

class MfaSelfFactorListed {
  const MfaSelfFactorListed({required this.factors});

  final List<MfaSelfFactorSummary> factors;
}

class MfaSelfFactorRevokeCommand {
  const MfaSelfFactorRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.factorId,
    this.stepUpProofId = '',
    this.authorizationIdToken = '',
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String factorId;
  final String stepUpProofId;
  final String authorizationIdToken;
}

class MfaSelfFactorRevoked {
  const MfaSelfFactorRevoked({
    required this.revoked,
    this.requestId,
    this.executeAfter,
  });

  final bool revoked;
  final String? requestId;
  final DateTime? executeAfter;
}

// Phase 9.UX.5 — self-service Active Sessions viewer.
//
// Operators inspect and revoke their own auth_sessions ledger rows
// from Settings → Account → Active Sessions. The DTOs intentionally
// stay thin — only metadata that helps a person recognise their own
// device (UA / approximate location / last-seen time) is surfaced;
// raw token material never crosses this seam.

class AuthSessionSummary {
  const AuthSessionSummary({
    required this.sessionId,
    required this.createdAt,
    required this.lastSeenAt,
    this.deviceLabel,
    this.userAgent,
    this.ip,
    this.geoCountry,
    this.deviceFingerprint,
    this.revokedAt,
    this.revokedReason,
  });

  final String sessionId;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  /// Friendly label the proxy/repository can derive (e.g. parsed
  /// browser / OS pairing). Optional — UI falls back to the raw UA.
  final String? deviceLabel;
  final String? userAgent;
  final String? ip;

  /// ISO-3166 alpha-2 country code captured at login time.
  final String? geoCountry;
  final String? deviceFingerprint;
  final DateTime? revokedAt;
  final String? revokedReason;
}

class AuthActiveSessionsListCommand {
  const AuthActiveSessionsListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

class AuthActiveSessionsListed {
  const AuthActiveSessionsListed({required this.sessions});

  final List<AuthSessionSummary> sessions;
}

// 11W.4 ops-debt fix — team-wide active sessions surface. Lists every
// active `auth_sessions` row whose `user_id` belongs to the caller's
// operator, joined to `users` so the response carries the row's
// owning user identity (id / display name / email). The proxy gates
// this on `team.session.force_logout`; per-tenant RLS is enforced by
// the join through the `users.operator_id` column.
class AuthTeamActiveSessionSummary {
  const AuthTeamActiveSessionSummary({
    required this.session,
    required this.targetUserId,
    this.targetDisplayName,
    this.targetEmail,
  });

  final AuthSessionSummary session;
  final String targetUserId;
  final String? targetDisplayName;
  final String? targetEmail;
}

class AuthTeamActiveSessionsListCommand {
  const AuthTeamActiveSessionsListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
}

class AuthTeamActiveSessionsListed {
  const AuthTeamActiveSessionsListed({required this.sessions});

  final List<AuthTeamActiveSessionSummary> sessions;
}

class AuthSessionRevokeCommand {
  const AuthSessionRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    required this.sessionId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String sessionId;
  final String? reason;
}

class AuthSessionRevoked {
  const AuthSessionRevoked({required this.revoked});

  final bool revoked;
}

class AuthAllSessionsRevokeCommand {
  const AuthAllSessionsRevokeCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.targetUserId,
    this.reason,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final String? targetUserId;
  final String? reason;
}

class AuthAllSessionsRevoked {
  const AuthAllSessionsRevoked({required this.revokedCount});

  final int revokedCount;
}

// Phase 9.UX.6 — self-service Audit Log surface.
//
// Operators inspect their own auth_events_audit history from
// Settings → Account → Audit Log. Per-user RLS pins reads to the
// signed-in actor server-side; the proxy resolves user_id from the
// verified Firebase bearer token and ignores any client-supplied
// user_id. The DTOs intentionally stay thin — no row-level secrets,
// just enough metadata to recognise an event and a friendly label
// derived from the raw `event_type` so the UI does not surface
// engineering shorthand.

/// Coarse grouping the Audit Log filter chips use. Keeps the UX
/// stable even as new low-level event_type strings land — anything
/// not in the recognised set falls into [AuthEventKind.other].
enum AuthEventKind { signIn, password, mfa, role, session, invite, user, other }

class AuthEventListEntry {
  const AuthEventListEntry({
    required this.eventId,
    required this.eventKind,
    required this.eventType,
    required this.friendlyLabel,
    required this.occurredAt,
    this.subType,
    this.ip,
    this.userAgent,
    this.geoCountry,
    this.scope,
    this.payload = const <String, Object?>{},
  });

  final String eventId;
  final AuthEventKind eventKind;

  /// Raw underlying `event_type` so UI filters / power-user toggles
  /// can match without reverse-engineering the friendly label.
  final String eventType;

  /// Human-readable label projected from [eventType] (e.g.
  /// `"Password changed"`). Stable enough for the operator to
  /// recognise the action without exposing internal naming.
  final String friendlyLabel;
  final DateTime occurredAt;

  /// Optional finer descriptor under a kind (e.g. for MFA: `"TOTP enrolled"`).
  final String? subType;
  final String? ip;
  final String? userAgent;
  final String? geoCountry;

  /// Optional human-readable scope hint (e.g. `"operator-wide"`).
  final String? scope;
  final Map<String, Object?> payload;
}

class AuthEventListCommand {
  const AuthEventListCommand({
    required this.actorUserId,
    required this.operatorId,
    required this.locationId,
    this.limit = 50,
    this.offset = 0,
    this.eventKind,
    this.from,
    this.to,
  });

  final String actorUserId;
  final String operatorId;
  final String locationId;
  final int limit;
  final int offset;

  /// Optional filter — only events whose mapped [AuthEventKind]
  /// matches survive. The proxy maps this to a server-side WHERE
  /// against a coarse SQL pattern set so RLS-leading-index lookups
  /// stay fast. A null value lists every kind.
  final AuthEventKind? eventKind;

  /// Optional `occurred_at >= from` floor. UTC.
  final DateTime? from;

  /// Optional `occurred_at <= to` ceiling. UTC.
  final DateTime? to;
}

class AuthEventsListed {
  const AuthEventsListed({required this.entries, required this.hasMore});

  final List<AuthEventListEntry> entries;
  final bool hasMore;
}

/// Projects raw `event_type` strings into a coarse [AuthEventKind] +
/// human-readable label pair. Kept here (rather than the widget
/// layer) so the proxy projection, repository tests, and the Flutter
/// widget agree on the same mapping. Unrecognised event_type values
/// fall through to [AuthEventKind.other] with the raw string as the
/// friendly label so a new server-side event is still readable.
class AuthEventLabels {
  const AuthEventLabels._();

  static AuthEventKind kindFor(String eventType) {
    final t = eventType.toLowerCase();
    if (t.contains('signed_in') ||
        t.contains('sign_in') ||
        t.contains('login') ||
        t.contains('signin')) {
      return AuthEventKind.signIn;
    }
    if (t.contains('password')) return AuthEventKind.password;
    if (t.contains('mfa') || t.contains('totp')) return AuthEventKind.mfa;
    if (t.contains('role') || t.contains('grant')) return AuthEventKind.role;
    if (t.contains('session')) return AuthEventKind.session;
    if (t.contains('invite')) return AuthEventKind.invite;
    if (t.contains('user_') || t.contains('.user.')) return AuthEventKind.user;
    return AuthEventKind.other;
  }

  static String labelFor(String eventType) {
    switch (eventType) {
      case 'auth.user.signed_in':
      case 'auth.signed_in':
        return 'Sign-in';
      case 'auth.user.password_changed':
      case 'auth.password_changed':
        return 'Password changed';
      case 'auth.password_reset_requested':
        return 'Password reset requested';
      case 'auth.password_reset_confirmed':
        return 'Password reset completed';
      case 'auth.mfa_totp_enrolled':
        return 'MFA enrolled (authenticator)';
      case 'auth.mfa_totp_enroll_failed':
        return 'MFA enrollment failed';
      case 'auth.user.mfa_factor_removed':
      case 'auth.mfa_factor_removed':
        return 'MFA factor removed';
      case 'auth.user.mfa_recovery_requested':
      case 'auth.mfa_recovery_requested':
        return 'MFA recovery requested';
      case 'auth.role_grant_created':
        return 'Role grant added';
      case 'auth.role_grant_revoked':
        return 'Role grant revoked';
      case 'auth.custom_role_created':
        return 'Custom role created';
      case 'auth.custom_role_updated':
        return 'Custom role updated';
      case 'auth.custom_role_deleted':
        return 'Custom role deleted';
      case 'auth.session_revoked':
        return 'Session revoked';
      case 'auth.all_sessions_revoked':
        return 'Signed out of all devices';
      case 'auth.invite_created':
        return 'Invite created';
      case 'auth.invite_revoked':
        return 'Invite cancelled';
      case 'invite.cancel':
        return 'Invite cancelled';
      case 'auth.invite_accepted':
        return 'Invite accepted';
      case 'auth.user_suspended':
        return 'User suspended';
      case 'auth.user_reactivated':
        return 'User reactivated';
      case 'auth.user_soft_deleted':
        return 'User soft-deleted';
    }
    // Fall back to a humanised version of the raw event_type so a
    // brand-new server-side event still reads naturally.
    final tail = eventType.contains('.')
        ? eventType.substring(eventType.lastIndexOf('.') + 1)
        : eventType;
    if (tail.isEmpty) return eventType;
    final words = tail.split('_');
    if (words.isEmpty) return tail;
    final first = words.first;
    final rest = words.skip(1).join(' ');
    final head = first.isEmpty
        ? ''
        : first.substring(0, 1).toUpperCase() + first.substring(1);
    return rest.isEmpty ? head : '$head $rest';
  }

  /// Coarse SQL `event_type LIKE` patterns the proxy uses to scope
  /// per-kind queries. Mirrors [kindFor] without rerouting through
  /// Dart-side filtering. Returns an empty list for [AuthEventKind.other]
  /// (which means "everything not specifically grouped") — the proxy
  /// then ANDs `not (matches any kind pattern)`.
  static List<String> sqlPatternsFor(AuthEventKind kind) {
    switch (kind) {
      case AuthEventKind.signIn:
        return const <String>[
          '%signed_in%',
          '%sign_in%',
          '%login%',
          '%signin%',
        ];
      case AuthEventKind.password:
        return const <String>['%password%'];
      case AuthEventKind.mfa:
        return const <String>['%mfa%', '%totp%'];
      case AuthEventKind.role:
        return const <String>['%role%', '%grant%'];
      case AuthEventKind.session:
        return const <String>['%session%'];
      case AuthEventKind.invite:
        return const <String>['%invite%'];
      case AuthEventKind.user:
        return const <String>['%user_%', '%.user.%'];
      case AuthEventKind.other:
        return const <String>[];
    }
  }

  /// Wire-format key used in `?event_kind=` query strings between
  /// Flutter and the proxy. Kept stable across versions.
  static String wireKey(AuthEventKind kind) {
    switch (kind) {
      case AuthEventKind.signIn:
        return 'sign_in';
      case AuthEventKind.password:
        return 'password';
      case AuthEventKind.mfa:
        return 'mfa';
      case AuthEventKind.role:
        return 'role';
      case AuthEventKind.session:
        return 'session';
      case AuthEventKind.invite:
        return 'invite';
      case AuthEventKind.user:
        return 'user';
      case AuthEventKind.other:
        return 'other';
    }
  }

  static AuthEventKind? fromWireKey(String? key) {
    if (key == null || key.isEmpty) return null;
    switch (key) {
      case 'sign_in':
        return AuthEventKind.signIn;
      case 'password':
        return AuthEventKind.password;
      case 'mfa':
        return AuthEventKind.mfa;
      case 'role':
        return AuthEventKind.role;
      case 'session':
        return AuthEventKind.session;
      case 'invite':
        return AuthEventKind.invite;
      case 'user':
        return AuthEventKind.user;
      case 'other':
        return AuthEventKind.other;
    }
    return null;
  }
}

// A7 — magic-link token redemption gateway seam.
//
// Kept separate from AuthOperationsGateway so the POST
// /v1/auth/magic-link/redeem route can be exercised in tests without
// wiring the full team-management surface. Production binds a
// Postgres-backed implementation that looks up the token in
// auth_invites, marks it used, and returns a Firebase custom token.

class MagicLinkRedeemCommand {
  const MagicLinkRedeemCommand({
    required this.token,
    required this.idempotencyKey,
  });

  /// The single-use invite token from the URL (after being stripped
  /// from the address bar and POSTed via the welcome screen body).
  final String token;

  /// Client-generated idempotency key (UUIDv4 or secure-random base64)
  /// so a network retry with the same token does not double-redeem.
  final String idempotencyKey;
}

class MagicLinkRedeemed {
  const MagicLinkRedeemed({required this.firebaseCustomToken});

  /// Firebase custom token the client exchanges for an ID token via
  /// `signInWithCustomToken`. Scoped to the invited user's UID and
  /// the operator's tenant claims.
  final String firebaseCustomToken;
}

/// Thrown when the token is not found, already used, or expired.
/// [statusCode] is 404 for not-found and 410 for expired/used.
class MagicLinkTokenInvalid implements Exception {
  const MagicLinkTokenInvalid({
    required this.code,
    required this.message,
    required this.statusCode,
  });

  final String code;
  final String message;
  final int statusCode;

  @override
  String toString() => 'MagicLinkTokenInvalid(code: $code)';
}

abstract class MagicLinkRedeemGateway {
  /// Validates and redeems the token. Throws [MagicLinkTokenInvalid]
  /// on any 4xx condition (expired, already-used, not-found). Throws
  /// other exceptions on transient 5xx conditions.
  Future<MagicLinkRedeemed> redeem(MagicLinkRedeemCommand command);
}

class AuthOperationRejected implements Exception {
  const AuthOperationRejected({
    required this.code,
    required this.message,
    required this.statusCode,
    this.details = const <String, Object?>{},
  });

  final String code;
  final String message;
  final int statusCode;
  final Map<String, Object?> details;

  @override
  String toString() => 'AuthOperationRejected(code: $code)';
}

abstract class AuthOperationsGateway {
  Future<TeamUsersListed> listUsers(TeamUserListCommand command);

  Future<TeamUserProfilePatched> patchUserProfile(
    TeamUserProfilePatchCommand command,
  );

  Future<TeamRoleCatalogListed> listRoles(TeamRoleCatalogListCommand command);

  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command);

  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command);

  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command);

  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command);

  Future<TeamInviteCreated> createInvite(TeamInviteCreateCommand command);

  Future<TeamInviteRevoked> revokeInvite(TeamInviteRevokeCommand command);

  Future<TeamUserStatusUpdated> suspendUser(TeamUserStatusCommand command);

  Future<TeamUserStatusUpdated> reactivateUser(TeamUserStatusCommand command);

  Future<TeamUserStatusUpdated> softDeleteUser(TeamUserStatusCommand command);

  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  );

  Future<TeamMfaResetQueued> requestMfaReset(TeamMfaResetCommand command);

  Future<TeamMfaRemovalCancelled> cancelMfaRemoval(
    TeamMfaRemovalCancelCommand command,
  );

  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  );

  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  );

  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  );

  Future<TeamOrgUnitCreated> createOrgUnit(TeamOrgUnitCreateCommand command);

  Future<TeamOrgUnitMoved> moveOrgUnit(TeamOrgUnitMoveCommand command);

  Future<TeamOrgUnitLifecycleUpdated> suspendOrgUnit(
    TeamOrgUnitLifecycleCommand command,
  );

  Future<TeamOrgUnitLifecycleUpdated> reactivateOrgUnit(
    TeamOrgUnitLifecycleCommand command,
  );

  Future<TeamHierarchyDeleted> deleteOrgUnit(
    TeamOrgUnitLifecycleCommand command,
  );

  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command,
  );

  Future<TeamLocationLifecycleUpdated> suspendLocation(
    TeamLocationLifecycleCommand command,
  );

  Future<TeamLocationLifecycleUpdated> reactivateLocation(
    TeamLocationLifecycleCommand command,
  );

  Future<TeamHierarchyDeleted> deleteLocation(
    TeamLocationLifecycleCommand command,
  );

  // Phase 9.UX.5 — self-service Active Sessions surface.
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  );

  // 11W.4 ops-debt — team-wide Active Sessions surface (operator
  // scoped). Joins `auth_sessions` to `users` on
  // `users.operator_id = command.operatorId`. Proxy gates on
  // `team.session.force_logout`.
  Future<AuthTeamActiveSessionsListed> listTeamActiveSessions(
    AuthTeamActiveSessionsListCommand command,
  );

  Future<AuthSessionRevoked> revokeSession(AuthSessionRevokeCommand command);

  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  );

  // Phase 9.UX.6 — self-service Audit Log surface.
  Future<AuthEventsListed> listAuthEventsForActor(AuthEventListCommand command);
}

class ScaffoldFailingAuthOperationsGateway implements AuthOperationsGateway {
  const ScaffoldFailingAuthOperationsGateway();

  @override
  Future<TeamUsersListed> listUsers(TeamUserListCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamUserProfilePatched> patchUserProfile(
    TeamUserProfilePatchCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleCatalogListed> listRoles(TeamRoleCatalogListCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleCreated> createRole(TeamRoleCreateCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamRolePatched> patchRole(TeamRolePatchCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleDeleted> deleteRole(TeamRoleDeleteCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamInvitesListed> listInvites(TeamInviteListCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamInviteCreated> createInvite(TeamInviteCreateCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamInviteRevoked> revokeInvite(TeamInviteRevokeCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamUserStatusUpdated> suspendUser(TeamUserStatusCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamUserStatusUpdated> reactivateUser(TeamUserStatusCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamUserStatusUpdated> softDeleteUser(TeamUserStatusCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamPasswordResetQueued> requestPasswordReset(
    TeamPasswordResetCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamMfaResetQueued> requestMfaReset(TeamMfaResetCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamMfaRemovalCancelled> cancelMfaRemoval(
    TeamMfaRemovalCancelCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleGrantCreated> createRoleGrant(
    TeamRoleGrantCreateCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamRoleGrantRevoked> revokeRoleGrant(
    TeamRoleGrantRevokeCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamOrgHierarchyListed> listOrgHierarchy(
    TeamOrgHierarchyListCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamOrgUnitCreated> createOrgUnit(TeamOrgUnitCreateCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamOrgUnitMoved> moveOrgUnit(TeamOrgUnitMoveCommand command) {
    throw StateError(_message);
  }

  @override
  Future<TeamOrgUnitLifecycleUpdated> suspendOrgUnit(
    TeamOrgUnitLifecycleCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamOrgUnitLifecycleUpdated> reactivateOrgUnit(
    TeamOrgUnitLifecycleCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamHierarchyDeleted> deleteOrgUnit(
    TeamOrgUnitLifecycleCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamLocationOrgUnitMoved> moveLocationToOrgUnit(
    TeamLocationOrgUnitMoveCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamLocationLifecycleUpdated> suspendLocation(
    TeamLocationLifecycleCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamLocationLifecycleUpdated> reactivateLocation(
    TeamLocationLifecycleCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<TeamHierarchyDeleted> deleteLocation(
    TeamLocationLifecycleCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<AuthActiveSessionsListed> listActiveSessions(
    AuthActiveSessionsListCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<AuthTeamActiveSessionsListed> listTeamActiveSessions(
    AuthTeamActiveSessionsListCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<AuthSessionRevoked> revokeSession(AuthSessionRevokeCommand command) {
    throw StateError(_message);
  }

  @override
  Future<AuthAllSessionsRevoked> signOutAll(
    AuthAllSessionsRevokeCommand command,
  ) {
    throw StateError(_message);
  }

  @override
  Future<AuthEventsListed> listAuthEventsForActor(
    AuthEventListCommand command,
  ) {
    throw StateError(_message);
  }

  static const String _message =
      'Phase 9 auth-operations gateway is not wired; bind the production '
      'gateway before exposing Team/user-management proxy routes.';
}
