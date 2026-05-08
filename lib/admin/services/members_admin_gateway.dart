// Phase 11A.12 - Members + Invites admin gateway.
//
// Cross-operator parity surface for the F&F Operations Console. The
// operator-web sibling (`11W.1`) hits `/v1/auth/team/users` +
// `/v1/auth/team/invites` after the proxy clamps `operator_id` from
// the calling team-member session. The admin path here hits the
// matching `/v1/admin/auth/users`, `/v1/admin/auth/invites`, and
// `/v1/admin/auth/role-grants` routes with an explicit `operator_id`
// query parameter and a `forge_admin` BYPASSRLS posture.
//
// Authority: docs/contracts/team_roles_hierarchy_console_parity_contract.md
// "§ Members + Invites (11W.1 + 11A.12)" — same filter set, same
// validation copy, same idempotency-key strategy, same audit-row
// shape. Differences are limited to:
//
//   * URL prefix (`/v1/admin/auth/*` vs `/v1/auth/team/*`).
//   * Required `admin_reason` on every write.
//   * Two admin-only actions: `Restore soft-deleted` and
//     `Override role grant` (both gated on the calling F&F admin's
//     UID being the value written into `created_by` /`updated_by` and
//     `audit_logs.actor_user_id`; `audit_logs.actor_kind` lands as
//     `forge_admin`).
//
// Two implementations ship in this slice, mirroring the .A / .C
// gateway split:
//
//   * [HttpMembersAdminGateway] - production. POST/PATCH/GET against
//     the proxy with the signed-in F&F admin's bearer token. Bearer
//     source is injected so production binds the Firebase ID-token
//     stream while widget tests pin a fixed value.
//
//   * [InMemoryMembersAdminGateway] - demo + widget tests. Mutates
//     an in-memory collection so the admin walkthrough runs end-to-
//     end in `kDemoMode` without a backend.
//
// Idempotency-key minting lives on the screen layer (mirrors
// `_OperatorLocationAdminScreenState._nextIdempotencyKey` from
// 11A.1) — the gateway accepts the key from the caller and forwards
// it on the request header. This keeps a retried mutation collapsing
// to a single row at the proxy `proxy_requests` UNIQUE constraint
// and a single audit row, per the parity contract.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'admin_http_timeout.dart';

/// Bearer source the gateway attaches to every proxy call. Production
/// binds this to the admin Firebase ID-token stream; tests pin a
/// synthetic value.
typedef MembersAdminBearerTokenProvider = Future<String> Function();

/// Locked enum mirroring `team.users.status` per the contract's
/// "Filter set (locked)" line.
enum MemberStatus { active, suspended, dormant30, softDeleted }

extension MemberStatusWire on MemberStatus {
  String get wire {
    switch (this) {
      case MemberStatus.active:
        return 'active';
      case MemberStatus.suspended:
        return 'suspended';
      case MemberStatus.dormant30:
        return 'dormant_30';
      case MemberStatus.softDeleted:
        return 'soft_deleted';
    }
  }

  static MemberStatus fromWire(String value) {
    for (final s in MemberStatus.values) {
      if (s.wire == value) return s;
    }
    throw ArgumentError.value(value, 'status', 'unknown member status');
  }
}

/// One member row visible in the cross-operator admin members table.
///
/// `createdBy` / `updatedBy` / `createdAt` / `updatedAt` mirror the
/// non-negotiable Phase 11A fact-table columns named in the parity
/// contract § "Created_by / updated_by population" (lines 76-77):
/// every fact-table write populates `created_by` (insert) or
/// `updated_by` (update) with the calling user's UID; for F&F admin
/// writes that's the F&F admin's UID, never an impersonated operator.
@immutable
class MemberAdminRow {
  const MemberAdminRow({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.roleKey,
    required this.primaryLocationId,
    required this.primaryLocationName,
    required this.status,
    required this.mfaEnrolled,
    required this.lastActiveAt,
    required this.createdAt,
    required this.updatedAt,
    this.createdBy,
    this.updatedBy,
    this.orgUnitId,
    this.grants = const <MemberRoleGrantRow>[],
  });

  final String userId;
  final String email;
  final String displayName;
  final String roleKey;
  final String primaryLocationId;
  final String primaryLocationName;
  final MemberStatus status;
  final bool mfaEnrolled;
  final DateTime lastActiveAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? createdBy;
  final String? updatedBy;
  final String? orgUnitId;
  final List<MemberRoleGrantRow> grants;

  bool get isSoftDeleted => status == MemberStatus.softDeleted;
}

@immutable
class MemberRoleGrantRow {
  const MemberRoleGrantRow({
    required this.userRoleId,
    required this.roleKey,
    required this.scopeType,
    this.roleLabel,
    this.locationId,
    this.locationName,
    this.orgUnitId,
    this.orgUnitName,
  });

  final String userRoleId;
  final String roleKey;
  final String? roleLabel;
  final String scopeType;
  final String? locationId;
  final String? locationName;
  final String? orgUnitId;
  final String? orgUnitName;

  String get roleDisplayLabel => roleLabel ?? memberRoleLabel(roleKey);
}

/// One invite row paired with the operator that owns it. The admin
/// surface lists pending invites alongside the members table.
@immutable
class MemberInviteRow {
  const MemberInviteRow({
    required this.inviteId,
    required this.email,
    required this.displayName,
    required this.roleKey,
    required this.primaryLocationId,
    required this.primaryLocationName,
    required this.invitedAt,
    required this.invitedBy,
    this.orgUnitId,
    this.orgUnitName,
    this.scopeType = 'location',
    this.welcomeNote,
  });

  final String inviteId;
  final String email;
  final String displayName;
  final String roleKey;
  final String primaryLocationId;
  final String primaryLocationName;
  final DateTime invitedAt;
  final String invitedBy;
  final String? orgUnitId;
  final String? orgUnitName;
  final String scopeType;
  final String? welcomeNote;
}

/// One audit-log row written by the admin gateway. Mirrors every
/// column pinned by the parity contract § "Audit-row shape"
/// (lines 60-73): `operator_id`, `actor_user_id`, `actor_kind`,
/// `action` (locked enum), `target_kind`, `target_id`, `payload`
/// (JSONB diff), `admin_reason`, `business_date`, `row_hash`.
/// `actorKind` is always `forge_admin` because non-forge-admin
/// callers throw [MembersAdminForbiddenException] before any write
/// lands.
///
/// `businessDate` is the denormalized restaurant-local date
/// (per `phase_7_55_time_boundary_contract.md`) — operator-scoped
/// fact tables carry it on every row.
///
/// `rowHash` is the SHA-256 chain link the proxy's `audit_logs`
/// writer computes per the B27 hash chain. Surfaced here so the
/// `11A.14` audit-log surface can render integrity status without
/// a second round-trip; never set on demo writes (the demo gateway
/// leaves it null because it does not own the chain producer).
@immutable
class MembersAdminAuditEvent {
  const MembersAdminAuditEvent({
    required this.eventId,
    required this.action,
    required this.occurredAt,
    required this.actorUserId,
    required this.operatorId,
    required this.targetKind,
    required this.targetId,
    required this.payload,
    required this.adminReason,
    required this.businessDate,
    this.actorKind = 'forge_admin',
    this.rowHash,
  });

  final String eventId;
  final String action;
  final DateTime occurredAt;
  final String actorUserId;
  final String actorKind;
  final String operatorId;
  final String targetKind;
  final String targetId;
  final Map<String, Object?> payload;
  final String adminReason;

  /// Denormalized restaurant-local business date the audit row
  /// belongs to. Required on every operator-scoped fact-table row
  /// per `phase_7_55_time_boundary_contract.md`.
  final DateTime businessDate;

  /// SHA-256 chain link populated by the proxy's audit-log writer.
  /// Null on demo writes because the in-memory gateway does not own
  /// the hash-chain producer; the live HTTP gateway parses it from
  /// the proxy response when present.
  final String? rowHash;
}

/// 403 thrown when a non-forge-admin caller tries to mutate via this
/// gateway. The screen layer also hides every mutate affordance via
/// `editingEnabled`; the gateway throw is defence-in-depth, mirrors
/// the data-accuracy admin gateway pattern.
class MembersAdminForbiddenException implements Exception {
  const MembersAdminForbiddenException(this.message);

  final String message;

  @override
  String toString() => 'MembersAdminForbiddenException: $message';
}

class MembersAdminGatewayError implements Exception {
  const MembersAdminGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
    this.details = const <String, Object?>{},
  });

  final int statusCode;
  final String errorCode;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() =>
      'MembersAdminGatewayError($statusCode/$errorCode): $message';
}

abstract class MembersAdminGateway {
  /// List the members for [operatorId]. Filter clauses are forwarded
  /// to the proxy as query parameters; nulls are omitted entirely.
  Future<List<MemberAdminRow>> listMembers({
    required String operatorId,
    MemberStatus? status,
    String? roleKey,
    String? locationId,
    String? contextLocationId,
    bool? mfaEnrolled,
    String? search,
  });

  Future<List<MemberInviteRow>> listInvites({
    required String operatorId,
    String? contextLocationId,
    String? locationId,
  });

  Future<MemberAdminRow> suspendMember({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<MemberAdminRow> reactivateMember({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<MemberAdminRow> softDeleteMember({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<void> resetPassword({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<void> resetMfa({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<void> forceLogout({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  Future<MemberAdminRow> updateDisplayName({
    required String operatorId,
    required String userId,
    required String displayName,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// Admin-only. Restores a soft-deleted member back to `active`.
  /// Operator self-service surface (`11W.1`) does NOT expose this —
  /// the parity contract pins the asymmetry.
  Future<MemberAdminRow> restoreSoftDeletedMember({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// Admin-only. Overrides the role grant on a member directly,
  /// bypassing the operator's normal `team.roles.assign` workflow.
  /// Used by F&F support to recover from a stuck grant.
  Future<MemberAdminRow> overrideRoleGrant({
    required String operatorId,
    required String userId,
    required String roleKey,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
    String scopeType = 'operator_wide',
    String? primaryLocationId,
    String? orgUnitId,
  });

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
    String scopeType = 'location',
    String? orgUnitId,
    String? welcomeNote,
  });
}

class HttpMembersAdminGateway implements MembersAdminGateway {
  HttpMembersAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri baseUri;
  final MembersAdminBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String usersPath = '/v1/admin/auth/users';
  static const String invitesPath = '/v1/admin/auth/invites';
  static const String roleGrantsPath = '/v1/admin/auth/role-grants';

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
    final routedLocationId = locationId ?? contextLocationId;
    final body = await _send(
      method: 'GET',
      path: usersPath,
      queryParameters: <String, String>{
        'operator_id': operatorId,
        if (status != null) 'status': status.wire,
        if (roleKey != null && roleKey.isNotEmpty) 'role_key': roleKey,
        if (routedLocationId != null && routedLocationId.isNotEmpty)
          'location_id': routedLocationId,
        if (mfaEnrolled != null) 'mfa_enrolled': mfaEnrolled.toString(),
        if (search != null && search.trim().isNotEmpty) 'q': search.trim(),
      },
    );
    final users = (body['users'] as List?) ?? const [];
    return <MemberAdminRow>[
      for (final user in users)
        if (user is Map && !_isInviteOnlyUserRow(user.cast<String, Object?>()))
          _memberRowFromJson(user.cast<String, Object?>()),
    ];
  }

  @override
  Future<List<MemberInviteRow>> listInvites({
    required String operatorId,
    String? contextLocationId,
    String? locationId,
  }) async {
    final routedLocationId = locationId ?? contextLocationId;
    final body = await _send(
      method: 'GET',
      path: invitesPath,
      queryParameters: <String, String>{
        'operator_id': operatorId,
        if (routedLocationId != null && routedLocationId.isNotEmpty)
          'location_id': routedLocationId,
      },
    );
    final invites = (body['invites'] as List?) ?? const [];
    return <MemberInviteRow>[
      for (final invite in invites)
        _inviteRowFromJson((invite as Map).cast<String, Object?>()),
    ];
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
    // Path segment matches the contract permission key
    // `admin.users.deactivate` (§ "Permission gate cheat sheet"
    // line 203). The user-facing label remains "Suspend"; the
    // wire vocabulary tracks the permission catalog.
    return _statusFlip(
      operatorId: operatorId,
      userId: userId,
      idempotencyKey: idempotencyKey,
      actorIsForgeAdmin: actorIsForgeAdmin,
      adminReason: adminReason,
      pathSegment: 'deactivate',
      operation: 'suspendMember',
    );
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
    return _statusFlip(
      operatorId: operatorId,
      userId: userId,
      idempotencyKey: idempotencyKey,
      actorIsForgeAdmin: actorIsForgeAdmin,
      adminReason: adminReason,
      pathSegment: 'reactivate',
      operation: 'reactivateMember',
    );
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
    return _statusFlip(
      operatorId: operatorId,
      userId: userId,
      idempotencyKey: idempotencyKey,
      actorIsForgeAdmin: actorIsForgeAdmin,
      adminReason: adminReason,
      pathSegment: 'soft-delete',
      operation: 'softDeleteMember',
    );
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
    return _statusFlip(
      operatorId: operatorId,
      userId: userId,
      idempotencyKey: idempotencyKey,
      actorIsForgeAdmin: actorIsForgeAdmin,
      adminReason: adminReason,
      pathSegment: 'restore',
      operation: 'restoreSoftDeletedMember',
    );
  }

  Future<MemberAdminRow> _statusFlip({
    required String operatorId,
    required String userId,
    required String idempotencyKey,
    required bool actorIsForgeAdmin,
    required String adminReason,
    required String pathSegment,
    required String operation,
  }) async {
    _requireEditable(actorIsForgeAdmin, operation);
    _requireAdminReason(adminReason, operation);
    final body = await _send(
      method: 'POST',
      path: '$usersPath/${Uri.encodeComponent(userId)}/$pathSegment',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
    return _memberRowFromJson(_asMap(body['user']));
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
    _requireEditable(actorIsForgeAdmin, 'resetPassword');
    _requireAdminReason(adminReason, 'resetPassword');
    await _send(
      method: 'POST',
      path: '$usersPath/${Uri.encodeComponent(userId)}/reset-password',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
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
    _requireEditable(actorIsForgeAdmin, 'resetMfa');
    _requireAdminReason(adminReason, 'resetMfa');
    // Path segment matches `admin.users.reset_mfa_factors`
    // (§ "Permission gate cheat sheet" line 203).
    await _send(
      method: 'POST',
      path: '$usersPath/${Uri.encodeComponent(userId)}/reset-mfa-factors',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
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
    _requireEditable(actorIsForgeAdmin, 'forceLogout');
    _requireAdminReason(adminReason, 'forceLogout');
    await _send(
      method: 'POST',
      path: '$usersPath/${Uri.encodeComponent(userId)}/force-logout',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
  }

  @override
  Future<MemberAdminRow> updateDisplayName({
    required String operatorId,
    required String userId,
    required String displayName,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'updateDisplayName');
    _requireAdminReason(adminReason, 'updateDisplayName');
    final trimmedDisplayName = displayName.trim();
    if (trimmedDisplayName.isEmpty) {
      throw MembersAdminGatewayError(
        statusCode: 400,
        errorCode: 'display_name_required',
        message: MembersValidationCopy.displayNameEmpty,
      );
    }
    final body = await _send(
      method: 'PATCH',
      path: '$usersPath/${Uri.encodeComponent(userId)}',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'display_name': trimmedDisplayName,
        'admin_reason': adminReason,
      },
    );
    return _memberRowFromJson(_asMap(body['user']));
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
    String scopeType = 'operator_wide',
    String? primaryLocationId,
    String? orgUnitId,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'overrideRoleGrant');
    _requireAdminReason(adminReason, 'overrideRoleGrant');
    final body = await _send(
      method: 'POST',
      path: roleGrantsPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'user_id': userId,
        'role_key': roleKey,
        'role_id': roleKey,
        'scope_type': scopeType,
        if (scopeType == 'location' &&
            primaryLocationId != null &&
            primaryLocationId.isNotEmpty)
          'location_id': primaryLocationId,
        if (scopeType == 'org_unit' &&
            orgUnitId != null &&
            orgUnitId.isNotEmpty)
          'org_unit_id': orgUnitId,
        'admin_reason': adminReason,
        'override': true,
      },
    );
    final user = _asMap(body['user']);
    if (user.isNotEmpty) return _memberRowFromJson(user);
    return MemberAdminRow(
      userId: userId,
      email: userId,
      displayName: userId,
      roleKey: roleKey,
      primaryLocationId: primaryLocationId ?? '',
      primaryLocationName: primaryLocationId ?? 'Business-wide',
      status: MemberStatus.active,
      mfaEnrolled: false,
      lastActiveAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedAt: DateTime.now().toUtc(),
      updatedBy: actorUserId,
      orgUnitId: orgUnitId,
      grants: <MemberRoleGrantRow>[
        MemberRoleGrantRow(
          userRoleId: _optionalString(body['user_role_id']) ?? '',
          roleKey: roleKey,
          scopeType: scopeType,
          locationId: primaryLocationId,
          orgUnitId: orgUnitId,
        ),
      ],
    );
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
    String scopeType = 'location',
    String? orgUnitId,
    String? welcomeNote,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'createInvite');
    _requireAdminReason(adminReason, 'createInvite');
    final body = await _send(
      method: 'POST',
      path: invitesPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'email': email.trim(),
        'display_name': displayName.trim(),
        // The live auth proxy accepts role ids, but its repository
        // binding resolves visible role keys too. Keep role_key for
        // admin-console readability while sending the contract fields
        // needed by the routed invite mutation.
        'role_id': roleKey,
        'role_key': roleKey,
        'scope_type': scopeType,
        if (scopeType == 'location') ...<String, Object?>{
          'location_id': primaryLocationId,
          'primary_location_id': primaryLocationId,
        },
        if (scopeType == 'org_unit' &&
            orgUnitId != null &&
            orgUnitId.isNotEmpty)
          'org_unit_id': orgUnitId,
        if (welcomeNote != null && welcomeNote.trim().isNotEmpty)
          'welcome_note': welcomeNote.trim(),
        'admin_reason': adminReason,
      },
    );
    final invite = _asMap(body['invite']);
    if (invite.isNotEmpty) return _inviteRowFromJson(invite);
    return _inviteRowFromJson(<String, Object?>{
      'invite_id': _stringField(body, 'invite_id'),
      'email': email.trim(),
      'display_name': displayName.trim(),
      'role_key': roleKey,
      if (scopeType == 'location') 'primary_location_id': primaryLocationId,
      'scope_type': scopeType,
      'created_at':
          _optionalString(body['created_at']) ??
          DateTime.now().toUtc().toIso8601String(),
      'invited_by': actorUserId,
      if (scopeType == 'org_unit' && orgUnitId != null && orgUnitId.isNotEmpty)
        'org_unit_id': orgUnitId,
      if (welcomeNote != null && welcomeNote.trim().isNotEmpty)
        'welcome_note': welcomeNote.trim(),
    });
  }

  void _requireEditable(bool actorIsForgeAdmin, String operation) {
    if (!actorIsForgeAdmin) {
      throw MembersAdminForbiddenException(
        '$operation requires forge_admin role',
      );
    }
  }

  void _requireAdminReason(String adminReason, String operation) {
    if (adminReason.trim().isEmpty) {
      throw MembersAdminGatewayError(
        statusCode: 400,
        errorCode: 'admin_reason_required',
        message: '$operation requires a non-empty admin_reason',
      );
    }
  }

  Future<Map<String, Object?>> _send({
    required String method,
    required String path,
    Map<String, String> queryParameters = const <String, String>{},
    Map<String, Object?>? jsonBody,
    String? idempotencyKey,
  }) async {
    final token = await bearerTokenProvider();
    var uri = baseUri.resolve(path);
    if (queryParameters.isNotEmpty) {
      uri = uri.replace(queryParameters: queryParameters);
    }
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (idempotencyKey != null && idempotencyKey.isNotEmpty) {
      request.headers['Idempotency-Key'] = idempotencyKey;
    }
    if (jsonBody != null) {
      request.headers['content-type'] = 'application/json';
      request.bodyBytes = utf8.encode(jsonEncode(jsonBody));
    }
    late final http.Response response;
    try {
      response = await sendAdminHttpRequest(
        _httpClient,
        request,
        timeout: _timeout,
      );
    } on AdminHttpTimeoutException {
      throw MembersAdminGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message: 'admin members proxy timed out after ${_timeout.inSeconds}s',
      );
    }
    final raw = utf8.decode(response.bodyBytes);
    Map<String, Object?> parsed = const <String, Object?>{};
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) parsed = decoded.cast<String, Object?>();
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return parsed;
    }
    final message =
        (parsed['message'] as String?) ??
        'admin members proxy returned an error';
    if (response.statusCode == 403) {
      throw MembersAdminForbiddenException(message);
    }
    throw MembersAdminGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: message,
      details: parsed,
    );
  }
}

MemberAdminRow _memberRowFromJson(Map<String, Object?> json) {
  final timestamp =
      _optionalDateTime(json['last_active_at']) ??
      _optionalDateTime(json['updated_at']) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final primaryLocationId = _firstOptionalStringField(json, const <String>[
    'primary_location_id',
    'location_id',
  ]);
  final primaryLocationName = _firstOptionalStringField(json, const <String>[
    'primary_location_name',
    'location_label',
  ]);
  return MemberAdminRow(
    userId: _stringField(json, 'user_id'),
    email: _stringField(json, 'email'),
    displayName: _stringField(json, 'display_name'),
    roleKey: _firstStringField(json, const <String>[
      'role_key',
      'role_label',
      'role_id',
    ]),
    primaryLocationId: primaryLocationId ?? '',
    primaryLocationName:
        primaryLocationName ?? primaryLocationId ?? 'Unassigned',
    status: MemberStatusWire.fromWire(_stringField(json, 'status')),
    mfaEnrolled: _boolField(json, 'mfa_enrolled'),
    lastActiveAt: timestamp,
    createdAt: _optionalDateTime(json['created_at']) ?? timestamp,
    updatedAt: _optionalDateTime(json['updated_at']) ?? timestamp,
    createdBy: _optionalString(json['created_by']),
    updatedBy: _optionalString(json['updated_by']),
    orgUnitId: _optionalString(json['org_unit_id']),
    grants: _memberGrantsFromJson(json),
  );
}

List<MemberRoleGrantRow> _memberGrantsFromJson(Map<String, Object?> json) {
  final raw = json['grants'];
  if (raw is List) {
    return List<MemberRoleGrantRow>.unmodifiable(<MemberRoleGrantRow>[
      for (final grant in raw)
        if (grant is Map)
          _memberGrantFromJson(grant.cast<String, Object?>(), parent: json),
    ]);
  }
  final userRoleId = _optionalString(json['user_role_id']);
  final roleKey = _firstOptionalStringField(json, const <String>[
    'role_key',
    'role_label',
    'role_id',
  ]);
  if (userRoleId == null || roleKey == null) {
    return const <MemberRoleGrantRow>[];
  }
  return <MemberRoleGrantRow>[
    MemberRoleGrantRow(
      userRoleId: userRoleId,
      roleKey: roleKey,
      roleLabel: _optionalString(json['role_label']),
      scopeType: _optionalString(json['scope_type']) ?? 'location',
      locationId: _optionalString(json['location_id']),
      locationName: _optionalString(json['location_label']),
      orgUnitId: _optionalString(json['org_unit_id']),
      orgUnitName: _optionalString(json['org_unit_label']),
    ),
  ];
}

MemberRoleGrantRow _memberGrantFromJson(
  Map<String, Object?> json, {
  required Map<String, Object?> parent,
}) {
  final roleKey = _firstOptionalStringField(json, const <String>[
    'role_key',
    'role_id',
    'role_label',
  ]);
  final locationId =
      _optionalString(json['location_id']) ??
      _optionalString(parent['location_id']);
  final orgUnitId =
      _optionalString(json['org_unit_id']) ??
      _optionalString(json['source_org_unit_id']);
  return MemberRoleGrantRow(
    userRoleId:
        _firstOptionalStringField(json, const <String>['user_role_id', 'id']) ??
        '',
    roleKey: roleKey ?? '',
    roleLabel: _optionalString(json['role_label']),
    scopeType: _optionalString(json['scope_type']) ?? 'location',
    locationId: locationId,
    locationName:
        _optionalString(json['location_label']) ??
        _optionalString(parent['location_label']),
    orgUnitId: orgUnitId,
    orgUnitName: _optionalString(json['org_unit_label']),
  );
}

bool _isInviteOnlyUserRow(Map<String, Object?> json) {
  // The live preview auth proxy can include invited-but-not-accepted rows
  // in the users envelope. The admin members contract keeps invited rows
  // on the invites surface, so filter that duplicate state out here.
  return _optionalString(json['status']) == 'invited';
}

MemberInviteRow _inviteRowFromJson(Map<String, Object?> json) {
  final invitedAt =
      _optionalDateTime(json['invited_at']) ??
      _optionalDateTime(json['created_at']) ??
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final primaryLocationId = _firstOptionalStringField(json, const <String>[
    'primary_location_id',
    'location_id',
  ]);
  final primaryLocationName = _firstOptionalStringField(json, const <String>[
    'primary_location_name',
    'location_label',
  ]);
  return MemberInviteRow(
    inviteId: _stringField(json, 'invite_id'),
    email: _stringField(json, 'email'),
    displayName:
        _optionalString(json['display_name']) ?? _stringField(json, 'email'),
    roleKey: _firstStringField(json, const <String>[
      'role_key',
      'role_label',
      'role_id',
    ]),
    primaryLocationId: primaryLocationId ?? '',
    primaryLocationName:
        primaryLocationName ?? primaryLocationId ?? 'Unassigned',
    invitedAt: invitedAt,
    invitedBy: _optionalString(json['invited_by']) ?? '',
    orgUnitId: _optionalString(json['org_unit_id']),
    orgUnitName: _optionalString(json['org_unit_label']),
    scopeType: _optionalString(json['scope_type']) ?? 'location',
    welcomeNote: _optionalString(json['welcome_note']),
  );
}

Map<String, Object?> _asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  return const <String, Object?>{};
}

String _stringField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw StateError('missing string field $key');
}

String _firstStringField(Map<String, Object?> json, List<String> keys) {
  final value = _firstOptionalStringField(json, keys);
  if (value != null) return value;
  throw StateError('missing string field ${keys.join('/')}');
}

String? _firstOptionalStringField(
  Map<String, Object?> json,
  List<String> keys,
) {
  for (final key in keys) {
    final value = _optionalString(json[key]);
    if (value != null) return value;
  }
  return null;
}

bool _boolField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  if (value is String) return value == 'true';
  return false;
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime? _optionalDateTime(Object? value) {
  if (value is DateTime) return value.toUtc();
  if (value is String && value.isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  return null;
}

/// Locked validation copy mirrored from the parity contract's
/// "Validation copy (locked, identical across surfaces)" block. The
/// dialog reads these constants verbatim — paraphrasing them is an
/// anti-pattern per § Anti-patterns of the contract.
class MembersValidationCopy {
  const MembersValidationCopy._();

  static const String emailEmpty = 'Email address is required.';
  static const String emailMalformed = 'Enter a valid email address.';
  static const String emailDuplicate =
      'This email is already on the team. Edit the existing member instead.';
  static const String roleMissing = 'Choose a role for this member.';
  static const String locationMissing =
      'Choose a primary location for this member.';
  static const String displayNameEmpty = 'Display name is required.';
}

/// Catalog of seeded role keys the invite dialog renders. Mirrors the
/// `auth_permission_key_catalog.md` seeded role list. The admin path
/// can additionally override role grants directly so this catalog is
/// shared by the override-role-grant action.
const List<String> kSeededRoleKeysForAdmin = <String>[
  'operator_owner',
  'operator_manager',
  'operator_supervisor',
  'operator_staff',
];

/// Display labels for the seeded role keys. The admin members table
/// renders these through [memberRoleLabel] so a future seeded role
/// addition does not silently render the raw key.
const Map<String, String> kSeededRoleDisplayNames = <String, String>{
  'operator_owner': 'Operator owner',
  'operator_manager': 'Operator manager',
  'operator_supervisor': 'Operator supervisor',
  'operator_staff': 'Operator staff',
};

String memberRoleLabel(String roleKey) {
  return kSeededRoleDisplayNames[roleKey] ?? roleKey;
}

/// Display label for a member status chip.
String memberStatusLabel(MemberStatus status) {
  switch (status) {
    case MemberStatus.active:
      return 'Active';
    case MemberStatus.suspended:
      return 'Suspended';
    case MemberStatus.dormant30:
      return 'Dormant 30d';
    case MemberStatus.softDeleted:
      return 'Soft deleted';
  }
}
