// Phase 11A.12 - in-memory demo gateway for the admin Members surface.
//
// Powers the kDemoMode walkthrough plus widget tests. Mirrors the
// shape of [HttpMembersAdminGateway]: every write is gated on
// `actorIsForgeAdmin` (the gateway throws
// [MembersAdminForbiddenException] otherwise — defence in depth
// behind the screen's `editingEnabled` flag), every write captures
// an audit event with `actor_kind = forge_admin` and the calling
// admin's UID + non-empty `admin_reason`, and every retried call
// with the same idempotency key returns the original result without
// double-mutation. Mirrors the .C admin gateway pattern that drives
// the Tab 1 / Tab 2 walkthroughs.

import 'package:flutter/foundation.dart';

import 'members_admin_gateway.dart';

class InMemoryMembersAdminGateway implements MembersAdminGateway {
  InMemoryMembersAdminGateway({
    Map<String, List<MemberAdminRow>>? membersByOperator,
    Map<String, List<MemberInviteRow>>? invitesByOperator,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _members = <String, List<MemberAdminRow>>{
         for (final entry in (membersByOperator ?? const {}).entries)
           entry.key: List<MemberAdminRow>.of(entry.value),
       },
       _invites = <String, List<MemberInviteRow>>{
         for (final entry in (invitesByOperator ?? const {}).entries)
           entry.key: List<MemberInviteRow>.of(entry.value),
       };

  final DateTime Function() _clock;
  final Map<String, List<MemberAdminRow>> _members;
  final Map<String, List<MemberInviteRow>> _invites;
  final List<MembersAdminAuditEvent> _auditLog = <MembersAdminAuditEvent>[];

  /// Idempotency cache so a retried mutation collapses to a single
  /// audit row and a single state change. Mirrors the proxy-side
  /// `proxy_requests` UNIQUE constraint.
  final Map<String, Object?> _idempotentResults = <String, Object?>{};

  /// Public read-only view of every audit event the gateway has
  /// captured so far. Tests assert on this; the screen reads it via
  /// [listAuditHistory].
  List<MembersAdminAuditEvent> get capturedAuditEvents =>
      List<MembersAdminAuditEvent>.unmodifiable(_auditLog);

  void _ensureForgeAdmin(bool actorIsForgeAdmin, String operation) {
    if (!actorIsForgeAdmin) {
      throw MembersAdminForbiddenException(
        '$operation requires forge_admin role',
      );
    }
  }

  void _ensureAdminReason(String adminReason, String operation) {
    if (adminReason.trim().isEmpty) {
      throw MembersAdminGatewayError(
        statusCode: 400,
        errorCode: 'admin_reason_required',
        message: '$operation requires a non-empty admin_reason',
      );
    }
  }

  void _record({
    required String action,
    required String actorUserId,
    required String operatorId,
    required String targetKind,
    required String targetId,
    required Map<String, Object?> payload,
    required String adminReason,
  }) {
    final occurredAt = _clock();
    _auditLog.add(
      MembersAdminAuditEvent(
        eventId: 'audit-${_auditLog.length + 1}',
        action: action,
        occurredAt: occurredAt,
        actorUserId: actorUserId,
        operatorId: operatorId,
        targetKind: targetKind,
        targetId: targetId,
        payload: Map<String, Object?>.unmodifiable(payload),
        adminReason: adminReason,
        // Demo gateway approximates the restaurant-local business
        // date by truncating the wall-clock instant to the date
        // component. The proxy-side audit-log writer computes the
        // real value from the operator's primary location timezone +
        // business-day rollover hour.
        businessDate: DateTime.utc(
          occurredAt.year,
          occurredAt.month,
          occurredAt.day,
        ),
      ),
    );
  }

  List<MemberAdminRow> _membersFor(String operatorId) {
    return _members.putIfAbsent(operatorId, () => <MemberAdminRow>[]);
  }

  List<MemberInviteRow> _invitesFor(String operatorId) {
    return _invites.putIfAbsent(operatorId, () => <MemberInviteRow>[]);
  }

  int _indexOfMember({required String operatorId, required String userId}) {
    final members = _membersFor(operatorId);
    final index = members.indexWhere((m) => m.userId == userId);
    if (index < 0) {
      throw MembersAdminGatewayError(
        statusCode: 404,
        errorCode: 'unknown_user',
        message: 'user $userId not found for operator $operatorId',
      );
    }
    return index;
  }

  MemberAdminRow _replaceStatus({
    required String operatorId,
    required String userId,
    required MemberStatus next,
    required String actorUserId,
  }) {
    final members = _membersFor(operatorId);
    final index = _indexOfMember(operatorId: operatorId, userId: userId);
    final prev = members[index];
    // `updatedBy` lands as the calling F&F admin's UID per the
    // parity contract § "Created_by / updated_by population": for
    // F&F admin writes, populate with the F&F admin's UID — never
    // impersonate the operator user.
    final updated = MemberAdminRow(
      userId: prev.userId,
      email: prev.email,
      displayName: prev.displayName,
      roleKey: prev.roleKey,
      primaryLocationId: prev.primaryLocationId,
      primaryLocationName: prev.primaryLocationName,
      status: next,
      mfaEnrolled: prev.mfaEnrolled,
      lastActiveAt: prev.lastActiveAt,
      createdAt: prev.createdAt,
      createdBy: prev.createdBy,
      updatedAt: _clock(),
      updatedBy: actorUserId,
      orgUnitId: prev.orgUnitId,
    );
    members[index] = updated;
    return updated;
  }

  @override
  Future<List<MemberAdminRow>> listMembers({
    required String operatorId,
    MemberStatus? status,
    String? roleKey,
    String? locationId,
    String? contextLocationId,
    bool? mfaEnrolled,
    String? search,
  }) async {
    final source = _membersFor(operatorId);
    final query = (search ?? '').trim().toLowerCase();
    return source
        .where((m) {
          if (status != null && m.status != status) return false;
          if (roleKey != null && roleKey.isNotEmpty && m.roleKey != roleKey) {
            return false;
          }
          if (locationId != null &&
              locationId.isNotEmpty &&
              m.primaryLocationId != locationId) {
            return false;
          }
          if (mfaEnrolled != null && m.mfaEnrolled != mfaEnrolled) return false;
          if (query.isNotEmpty) {
            final haystack =
                '${m.email.toLowerCase()} ${m.displayName.toLowerCase()}';
            if (!haystack.contains(query)) return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  @override
  Future<List<MemberInviteRow>> listInvites({
    required String operatorId,
    String? contextLocationId,
    String? locationId,
  }) async {
    final invites = _invitesFor(operatorId);
    if (locationId == null || locationId.isEmpty) {
      return List<MemberInviteRow>.unmodifiable(invites);
    }
    return invites
        .where((invite) => invite.primaryLocationId == locationId)
        .toList(growable: false);
  }

  @override
  Future<MemberAdminRow> suspendMember({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'suspendMember');
    _ensureAdminReason(adminReason, 'suspendMember');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is MemberAdminRow) return cached;
    final updated = _replaceStatus(
      operatorId: operatorId,
      userId: userId,
      next: MemberStatus.suspended,
      actorUserId: actorUserId,
    );
    _record(
      // Per parity contract § "Operator self-service vs F&F admin
      // path": admin-path and operator-self-service writes produce
      // identical canonical fact rows differing only in actor_kind.
      // The locked enum uses the `team.*` family; the admin-only
      // marker is `actor_kind = forge_admin` plus `admin_reason`.
      action: 'team.users.deactivate',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_user',
      targetId: userId,
      payload: <String, Object?>{
        'status': <String, String>{'from': 'active', 'to': 'suspended'},
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = updated;
    return updated;
  }

  @override
  Future<MemberAdminRow> reactivateMember({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'reactivateMember');
    _ensureAdminReason(adminReason, 'reactivateMember');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is MemberAdminRow) return cached;
    final updated = _replaceStatus(
      operatorId: operatorId,
      userId: userId,
      next: MemberStatus.active,
      actorUserId: actorUserId,
    );
    _record(
      action: 'team.users.reactivate',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_user',
      targetId: userId,
      payload: <String, Object?>{
        'status': <String, String>{'from': 'suspended', 'to': 'active'},
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = updated;
    return updated;
  }

  @override
  Future<MemberAdminRow> softDeleteMember({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'softDeleteMember');
    _ensureAdminReason(adminReason, 'softDeleteMember');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is MemberAdminRow) return cached;
    final updated = _replaceStatus(
      operatorId: operatorId,
      userId: userId,
      next: MemberStatus.softDeleted,
      actorUserId: actorUserId,
    );
    _record(
      action: 'team.users.soft_delete',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_user',
      targetId: userId,
      payload: <String, Object?>{
        'status': <String, String>{'to': 'soft_deleted'},
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = updated;
    return updated;
  }

  @override
  Future<MemberAdminRow> restoreSoftDeletedMember({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'restoreSoftDeletedMember');
    _ensureAdminReason(adminReason, 'restoreSoftDeletedMember');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is MemberAdminRow) return cached;
    final members = _membersFor(operatorId);
    final index = _indexOfMember(operatorId: operatorId, userId: userId);
    final prev = members[index];
    if (!prev.isSoftDeleted) {
      throw MembersAdminGatewayError(
        statusCode: 400,
        errorCode: 'not_soft_deleted',
        message: 'restore is only valid for soft-deleted users',
      );
    }
    final updated = _replaceStatus(
      operatorId: operatorId,
      userId: userId,
      next: MemberStatus.active,
      actorUserId: actorUserId,
    );
    _record(
      // Restore is admin-only (operator self-service does not expose
      // it). The action stays in the `team.*` family for vocabulary
      // consistency with the rest of the locked audit enum; the
      // admin-only marker is `actor_kind = forge_admin`.
      action: 'team.users.restore',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_user',
      targetId: userId,
      payload: <String, Object?>{
        'status': <String, String>{'from': 'soft_deleted', 'to': 'active'},
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = updated;
    return updated;
  }

  @override
  Future<void> resetPassword({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'resetPassword');
    _ensureAdminReason(adminReason, 'resetPassword');
    if (_idempotentResults.containsKey(idempotencyKey)) return;
    _indexOfMember(operatorId: operatorId, userId: userId);
    _record(
      action: 'auth.password.reset',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_user',
      targetId: userId,
      payload: const <String, Object?>{'reset_email_dispatched': true},
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = const Object();
  }

  @override
  Future<void> resetMfa({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'resetMfa');
    _ensureAdminReason(adminReason, 'resetMfa');
    if (_idempotentResults.containsKey(idempotencyKey)) return;
    _indexOfMember(operatorId: operatorId, userId: userId);
    _record(
      action: 'auth.mfa.reset',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_user',
      targetId: userId,
      payload: const <String, Object?>{'mfa_removal_scheduled': true},
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = const Object();
  }

  @override
  Future<void> forceLogout({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'forceLogout');
    _ensureAdminReason(adminReason, 'forceLogout');
    if (_idempotentResults.containsKey(idempotencyKey)) return;
    _indexOfMember(operatorId: operatorId, userId: userId);
    _record(
      // Pinned to the contract example at § "Audit-row shape" (line 66):
      // `team.session.force_logout`. Identical action enum used by both
      // self-service and admin paths; actor_kind disambiguates.
      action: 'team.session.force_logout',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_user',
      targetId: userId,
      payload: const <String, Object?>{'all_sessions_revoked': true},
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = const Object();
  }

  @override
  Future<MemberAdminRow> overrideRoleGrant({
    required String operatorId,
    required String userId,
    required String roleKey,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'overrideRoleGrant');
    _ensureAdminReason(adminReason, 'overrideRoleGrant');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is MemberAdminRow) return cached;
    final members = _membersFor(operatorId);
    final index = _indexOfMember(operatorId: operatorId, userId: userId);
    final prev = members[index];
    final updated = MemberAdminRow(
      userId: prev.userId,
      email: prev.email,
      displayName: prev.displayName,
      roleKey: roleKey,
      primaryLocationId: prev.primaryLocationId,
      primaryLocationName: prev.primaryLocationName,
      status: prev.status,
      mfaEnrolled: prev.mfaEnrolled,
      lastActiveAt: prev.lastActiveAt,
      orgUnitId: prev.orgUnitId,
      createdBy: prev.createdBy,
      createdAt: prev.createdAt,
      updatedBy: actorUserId,
      updatedAt: _clock(),
    );
    members[index] = updated;
    _record(
      // Override is admin-only; the canonical fact is "role grant
      // changed". Vocabulary stays in the `team.*` family because
      // the `role_grants` audit target is shared with the operator
      // self-service surface; `actor_kind = forge_admin` plus the
      // `payload.override = true` marker disambiguate.
      action: 'team.roles.assign',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_user',
      targetId: userId,
      payload: <String, Object?>{
        'role_key': <String, String>{'from': prev.roleKey, 'to': roleKey},
        'override': true,
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = updated;
    return updated;
  }

  @override
  Future<MemberInviteRow> createInvite({
    required String operatorId,
    required String email,
    required String displayName,
    required String roleKey,
    required String primaryLocationId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
    String? orgUnitId,
    String? welcomeNote,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'createInvite');
    _ensureAdminReason(adminReason, 'createInvite');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is MemberInviteRow) return cached;
    final invites = _invitesFor(operatorId);
    final members = _membersFor(operatorId);
    final normalizedEmail = email.trim().toLowerCase();
    final emailDuplicate = members.any(
      (m) => m.email.toLowerCase() == normalizedEmail,
    );
    if (emailDuplicate) {
      throw MembersAdminGatewayError(
        statusCode: 409,
        errorCode: 'email_in_operator',
        message: MembersValidationCopy.emailDuplicate,
      );
    }
    final primaryLocationName = _findLocationName(
      members: members,
      invites: invites,
      locationId: primaryLocationId,
    );
    final invite = MemberInviteRow(
      inviteId:
          'invite-${invites.length + 1}-${_clock().microsecondsSinceEpoch}',
      email: email.trim(),
      displayName: displayName.trim(),
      roleKey: roleKey,
      primaryLocationId: primaryLocationId,
      primaryLocationName: primaryLocationName ?? primaryLocationId,
      invitedAt: _clock(),
      invitedBy: actorUserId,
      orgUnitId: orgUnitId,
      welcomeNote: welcomeNote,
    );
    invites.add(invite);
    _record(
      // Pinned to contract § "Audit-row shape" line 66 example:
      // `team.users.invite`. Same action enum on both paths.
      action: 'team.users.invite',
      actorUserId: actorUserId,
      operatorId: operatorId,
      targetKind: 'team_invite',
      targetId: invite.inviteId,
      payload: <String, Object?>{
        'email': invite.email,
        'role_key': roleKey,
        'primary_location_id': primaryLocationId,
        if (orgUnitId != null) 'org_unit_id': orgUnitId,
      },
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = invite;
    return invite;
  }

  String? _findLocationName({
    required List<MemberAdminRow> members,
    required List<MemberInviteRow> invites,
    required String locationId,
  }) {
    for (final m in members) {
      if (m.primaryLocationId == locationId) return m.primaryLocationName;
    }
    for (final i in invites) {
      if (i.primaryLocationId == locationId) return i.primaryLocationName;
    }
    return null;
  }

  /// Test helper used by the screen widget tests so they can assert on
  /// the audit-event ordering without poking at the internal list.
  @visibleForTesting
  void clearAuditEventsForTesting() {
    _auditLog.clear();
  }

  /// Test helper exposing the captured audit log filtered by
  /// operator. The screen layer does not consume audit history in
  /// this slice — that's owned by 11A.14.
  @visibleForTesting
  List<MembersAdminAuditEvent> auditEventsForOperator(String operatorId) {
    return _auditLog
        .where((e) => e.operatorId == operatorId)
        .toList(growable: false);
  }
}

/// Demo seed used by the kDemoMode walkthrough + widget tests. Mirrors
/// the operators on `_defaultDemoGateway` (Demo Diner Co. + Sunset
/// Cafe Group) so the admin walkthrough hops between operators without
/// fabricating extra fixture identities.
const String kDemoDinerOperatorId = '00000000-0000-4000-8000-000000000001';
const String kDemoDinerLocationToronto = '00000000-0000-4000-8000-0000000000a1';
const String kDemoDinerLocationVancouver =
    '00000000-0000-4000-8000-0000000000a2';
const String kDemoSunsetOperatorId = '00000000-0000-4000-8000-000000000002';
const String kDemoSunsetLocationBrooklyn =
    '00000000-0000-4000-8000-0000000000b1';

Map<String, List<MemberAdminRow>> kDemoMembersByOperator({DateTime? at}) {
  final ts = at ?? DateTime.utc(2026, 5, 4, 12);
  final seedTs = DateTime.utc(2026, 1, 12, 14, 30);
  return <String, List<MemberAdminRow>>{
    kDemoDinerOperatorId: <MemberAdminRow>[
      MemberAdminRow(
        userId: 'demo-user-diner-owner',
        email: 'owner@demo-diner.test',
        displayName: 'Dana Owner',
        roleKey: 'operator_owner',
        primaryLocationId: kDemoDinerLocationToronto,
        primaryLocationName: 'Toronto Yorkville',
        status: MemberStatus.active,
        mfaEnrolled: true,
        lastActiveAt: ts.subtract(const Duration(hours: 1)),
        createdAt: seedTs,
        createdBy: 'demo-super-admin',
        updatedAt: seedTs,
      ),
      MemberAdminRow(
        userId: 'demo-user-diner-manager',
        email: 'manager@demo-diner.test',
        displayName: 'Mira Manager',
        roleKey: 'operator_manager',
        primaryLocationId: kDemoDinerLocationVancouver,
        primaryLocationName: 'Vancouver Robson',
        status: MemberStatus.active,
        mfaEnrolled: false,
        lastActiveAt: ts.subtract(const Duration(hours: 6)),
        createdAt: seedTs,
        createdBy: 'demo-user-diner-owner',
        updatedAt: seedTs,
      ),
      MemberAdminRow(
        userId: 'demo-user-diner-supervisor',
        email: 'sup@demo-diner.test',
        displayName: 'Sam Supervisor',
        roleKey: 'operator_supervisor',
        primaryLocationId: kDemoDinerLocationToronto,
        primaryLocationName: 'Toronto Yorkville',
        status: MemberStatus.suspended,
        mfaEnrolled: false,
        lastActiveAt: ts.subtract(const Duration(days: 3)),
        createdAt: seedTs,
        createdBy: 'demo-user-diner-owner',
        updatedAt: ts.subtract(const Duration(days: 3)),
        updatedBy: 'demo-user-diner-owner',
      ),
      MemberAdminRow(
        userId: 'demo-user-diner-staff-archived',
        email: 'archived@demo-diner.test',
        displayName: 'Avery Archived',
        roleKey: 'operator_staff',
        primaryLocationId: kDemoDinerLocationToronto,
        primaryLocationName: 'Toronto Yorkville',
        status: MemberStatus.softDeleted,
        mfaEnrolled: false,
        lastActiveAt: ts.subtract(const Duration(days: 45)),
        createdAt: seedTs,
        createdBy: 'demo-user-diner-owner',
        updatedAt: ts.subtract(const Duration(days: 45)),
        updatedBy: 'demo-user-diner-owner',
      ),
    ],
    kDemoSunsetOperatorId: <MemberAdminRow>[
      MemberAdminRow(
        userId: 'demo-user-sunset-owner',
        email: 'owner@sunset-cafe.test',
        displayName: 'Quinn Owner',
        roleKey: 'operator_owner',
        primaryLocationId: kDemoSunsetLocationBrooklyn,
        primaryLocationName: 'Brooklyn Williamsburg',
        status: MemberStatus.active,
        mfaEnrolled: true,
        lastActiveAt: ts.subtract(const Duration(minutes: 30)),
        createdAt: seedTs,
        createdBy: 'demo-super-admin',
        updatedAt: seedTs,
      ),
      MemberAdminRow(
        userId: 'demo-user-sunset-staff',
        email: 'staff@sunset-cafe.test',
        displayName: 'Rae Staff',
        roleKey: 'operator_staff',
        primaryLocationId: kDemoSunsetLocationBrooklyn,
        primaryLocationName: 'Brooklyn Williamsburg',
        status: MemberStatus.dormant30,
        mfaEnrolled: false,
        lastActiveAt: ts.subtract(const Duration(days: 31)),
        createdAt: seedTs,
        createdBy: 'demo-user-sunset-owner',
        updatedAt: seedTs,
      ),
    ],
  };
}

Map<String, List<MemberInviteRow>> kDemoInvitesByOperator({DateTime? at}) {
  final ts = at ?? DateTime.utc(2026, 5, 4, 12);
  return <String, List<MemberInviteRow>>{
    kDemoDinerOperatorId: <MemberInviteRow>[
      MemberInviteRow(
        inviteId: 'demo-invite-diner-1',
        email: 'newhire@demo-diner.test',
        displayName: 'Nico Newhire',
        roleKey: 'operator_staff',
        primaryLocationId: kDemoDinerLocationToronto,
        primaryLocationName: 'Toronto Yorkville',
        invitedAt: ts.subtract(const Duration(days: 1)),
        invitedBy: 'demo-user-diner-owner',
      ),
    ],
    kDemoSunsetOperatorId: const <MemberInviteRow>[],
  };
}
