// Phase 11A.14 - Audited support actions admin gateway.
//
// Cross-operator audit-log review + support-side MFA / password
// operations + paired-approval erasure for the F&F Operations
// Console. The F&F admin picks an operator via the existing operator
// picker (`lib/admin/screens/operator_picker_screen.dart`), then
// lands on a two-region screen: an audit-log table (filters
// identical to 11W.5) plus an Actions panel (Reset MFA / Initiate
// password reset / Issue paired-approval erasure). Every read +
// write hits the admin proxy with an explicit `operator_id` and a
// `forge_admin` BYPASSRLS posture, mirroring the 11A.12 / 11A.13
// gateways.
//
// Authority:
//
//   * docs/contracts/team_roles_hierarchy_console_parity_contract.md
//     § Audit Log (11W.5 + 11A.14 Audit log tab) — locked filter
//     set + pagination + row rendering + CSV export.
//     § Security (11W.6 + 11A.14 Actions panel) — Reset MFA /
//     password reset / paired-approval erasure paths and the new
//     `admin.users.reset_mfa_factors` permission key.
//   * docs/contracts/auth_permission_key_catalog.md — the new key
//     row mirrored verbatim in the 2026-05-06 additive migration.
//
// Two implementations ship in this slice, mirroring the 11A.13
// gateway split:
//
//   * [HttpAuditedSupportActionsAdminGateway] - production. GET +
//     POST against the proxy with the signed-in F&F admin's bearer
//     token. Bearer source is injected so production binds the
//     Firebase ID-token stream while widget tests pin a fixed value.
//
//   * [InMemoryAuditedSupportActionsAdminGateway] (demo gateway,
//     in `demo_audited_support_actions_admin_gateway.dart`) - demo
//     + widget tests. Mutates an in-memory collection so the admin
//     walkthrough runs end-to-end in `kDemoMode` without a backend.
//
// Idempotency-key minting lives on the screen layer; the gateway
// accepts the key from the caller and forwards it on the request
// header so a retried mutation collapses to a single proxy
// `proxy_requests` row, a single `audit_logs` row, and a single
// `admin_action_log` provenance row.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'admin_http_timeout.dart';

/// Bearer source the gateway attaches to every proxy call.
typedef AuditedSupportActionsBearerTokenProvider = Future<String> Function();

/// Time-window enum mirroring the parity contract § Audit Log
/// "Filter set (locked)" line 141: `{last 24h, last 7d, last 30d,
/// last 90d, custom range}`. `customRange` carries [from] / [to] in
/// [AuditLogFilters].
enum AuditLogTimeWindow { last24h, last7d, last30d, last90d, customRange }

extension AuditLogTimeWindowWire on AuditLogTimeWindow {
  String get wire {
    switch (this) {
      case AuditLogTimeWindow.last24h:
        return 'last_24h';
      case AuditLogTimeWindow.last7d:
        return 'last_7d';
      case AuditLogTimeWindow.last30d:
        return 'last_30d';
      case AuditLogTimeWindow.last90d:
        return 'last_90d';
      case AuditLogTimeWindow.customRange:
        return 'custom_range';
    }
  }

  String get displayLabel {
    switch (this) {
      case AuditLogTimeWindow.last24h:
        return 'Last 24 hours';
      case AuditLogTimeWindow.last7d:
        return 'Last 7 days';
      case AuditLogTimeWindow.last30d:
        return 'Last 30 days';
      case AuditLogTimeWindow.last90d:
        return 'Last 90 days';
      case AuditLogTimeWindow.customRange:
        return 'Custom range';
    }
  }
}

/// `actor_kind` enum. F&F admin surface admits all three values per
/// the parity contract § Audit Log line 141; operator self-service
/// auto-clamps to `team_member` only.
enum AuditActorKind { teamMember, forgeAdmin, servicePrincipal }

extension AuditActorKindWire on AuditActorKind {
  String get wire {
    switch (this) {
      case AuditActorKind.teamMember:
        return 'team_member';
      case AuditActorKind.forgeAdmin:
        return 'forge_admin';
      case AuditActorKind.servicePrincipal:
        return 'service_principal';
    }
  }

  String get displayLabel {
    switch (this) {
      case AuditActorKind.teamMember:
        return 'Operator member';
      case AuditActorKind.forgeAdmin:
        return 'F&F admin';
      case AuditActorKind.servicePrincipal:
        return 'Service account';
    }
  }
}

AuditActorKind auditActorKindFromWire(String wire) {
  for (final kind in AuditActorKind.values) {
    if (kind.wire == wire) return kind;
  }
  throw ArgumentError.value(wire, 'actor_kind', 'unknown actor_kind');
}

/// Audit-log filter clause. Forwarded to the proxy on every list
/// call. Mirrors the parity contract § Audit Log "Filter set
/// (locked)" line 141 verbatim. All fields are optional; callers
/// pass [AuditLogFilters.empty] when first opening the surface.
@immutable
class AuditLogFilters {
  const AuditLogFilters({
    this.actorUserId,
    this.actions = const <String>[],
    this.targetKind,
    this.targetId,
    this.timeWindow,
    this.customRangeFrom,
    this.customRangeTo,
    this.actorKinds = const <AuditActorKind>[],
  });

  static const AuditLogFilters empty = AuditLogFilters();

  /// Picked actor (user picker single-select). Null means no actor
  /// filter applied.
  final String? actorUserId;

  /// Locked enum multi-select. Empty means no action filter.
  final List<String> actions;

  /// Locked enum single-select. Null means no target_kind filter.
  final String? targetKind;

  /// Free-text target_id (copyable from row). Null/empty means no
  /// target_id filter.
  final String? targetId;

  /// Time window. Null defaults server-side to last 24h.
  final AuditLogTimeWindow? timeWindow;

  /// Set when [timeWindow] is [AuditLogTimeWindow.customRange].
  final DateTime? customRangeFrom;
  final DateTime? customRangeTo;

  /// `actor_kind` multi-select. F&F admin surface only — the proxy
  /// rejects this clause for `/v1/auth/audit-log` (operator
  /// self-service auto-clamps to `team_member`).
  final List<AuditActorKind> actorKinds;

  AuditLogFilters copyWith({
    Object? actorUserId = _undef,
    List<String>? actions,
    Object? targetKind = _undef,
    Object? targetId = _undef,
    Object? timeWindow = _undef,
    Object? customRangeFrom = _undef,
    Object? customRangeTo = _undef,
    List<AuditActorKind>? actorKinds,
  }) {
    return AuditLogFilters(
      actorUserId: identical(actorUserId, _undef)
          ? this.actorUserId
          : actorUserId as String?,
      actions: actions ?? this.actions,
      targetKind: identical(targetKind, _undef)
          ? this.targetKind
          : targetKind as String?,
      targetId: identical(targetId, _undef)
          ? this.targetId
          : targetId as String?,
      timeWindow: identical(timeWindow, _undef)
          ? this.timeWindow
          : timeWindow as AuditLogTimeWindow?,
      customRangeFrom: identical(customRangeFrom, _undef)
          ? this.customRangeFrom
          : customRangeFrom as DateTime?,
      customRangeTo: identical(customRangeTo, _undef)
          ? this.customRangeTo
          : customRangeTo as DateTime?,
      actorKinds: actorKinds ?? this.actorKinds,
    );
  }

  bool get isEmpty =>
      actorUserId == null &&
      actions.isEmpty &&
      targetKind == null &&
      (targetId == null || targetId!.trim().isEmpty) &&
      timeWindow == null &&
      actorKinds.isEmpty;
}

const Object _undef = Object();

/// One audit-log row rendered in the table. Mirrors every column the
/// parity contract § Audit Log "Row rendering" line 145 names plus
/// the columns the audit-row shape contract pins (lines 60-73):
/// `created_at`, actor (display_name + email + actor_kind),
/// `action`, target (target_kind + target_id), payload, `business_date`,
/// `row_hash`, and the `admin_reason` field for `forge_admin` rows.
@immutable
class AuditLogRow {
  const AuditLogRow({
    required this.eventId,
    required this.action,
    required this.occurredAt,
    required this.actorUserId,
    required this.actorDisplayName,
    required this.actorEmail,
    required this.actorKind,
    required this.operatorId,
    required this.targetKind,
    required this.targetId,
    required this.payload,
    required this.businessDate,
    this.adminReason,
    this.rowHash,
  });

  final String eventId;
  final String action;
  final DateTime occurredAt;
  final String actorUserId;
  final String actorDisplayName;
  final String actorEmail;
  final AuditActorKind actorKind;
  final String operatorId;
  final String targetKind;
  final String targetId;
  final Map<String, Object?> payload;
  final DateTime businessDate;

  /// Required for `actor_kind = forge_admin`; null for self-service
  /// rows. The screen renders this inline on forge_admin rows.
  final String? adminReason;

  /// SHA-256 chain link populated by the proxy's audit-log writer.
  final String? rowHash;
}

/// Page result for a paginated [AuditLogRow] read. `nextCursor` is
/// null when the last page has been served. Mirrors the parity
/// contract § Audit Log "Pagination" line 143: cursor-based, 200
/// rows per page (Performance Framework cap), sorted
/// `created_at DESC`.
@immutable
class AuditLogPage {
  const AuditLogPage({required this.rows, this.nextCursor});

  final List<AuditLogRow> rows;
  final String? nextCursor;
}

/// One member visible in the Actions panel target picker. Mirrors a
/// minimal subset of [MemberAdminRow] so this gateway can scope
/// independently from the 11A.12 Members surface.
@immutable
class SupportActionsMember {
  const SupportActionsMember({
    required this.userId,
    required this.email,
    required this.displayName,
    required this.mfaEnrolled,
    this.canReceivePasswordReset = true,
    this.passwordResetBlockedReason,
  });

  final String userId;
  final String email;
  final String displayName;
  final bool mfaEnrolled;
  final bool canReceivePasswordReset;
  final String? passwordResetBlockedReason;
}

/// One row written to `admin_action_log`, the F&F-internal
/// provenance ledger that captures `reader`, `target`, and
/// `records_touched` for every support escalation per the phase plan
/// § `11A.14`. Distinct from `audit_logs`: `audit_logs` is the
/// operator-visible chain; `admin_action_log` is the F&F internal
/// reader trail.
@immutable
class AdminActionLogRow {
  const AdminActionLogRow({
    required this.actionLogId,
    required this.action,
    required this.occurredAt,
    required this.readerUserId,
    required this.operatorId,
    required this.targetKind,
    required this.targetId,
    required this.recordsTouched,
    required this.adminReason,
  });

  final String actionLogId;
  final String action;
  final DateTime occurredAt;
  final String readerUserId;
  final String operatorId;
  final String targetKind;
  final String targetId;
  final int recordsTouched;
  final String adminReason;
}

/// CODE_OPS_DEBT Theme B#1 — single-admin erasure outcome. Replaces
/// the legacy paired-approval flow at the launch decision (2026-05-08
/// operator decision register). The proxy returns `erasureId` +
/// `gracePeriodEndsAt` on the 202 from `POST .../erase-pii`; reversal
/// inside the grace window goes through `reversePiiErasure`.
@immutable
class UserPiiErasureRequestSummary {
  const UserPiiErasureRequestSummary({
    required this.erasureId,
    required this.gracePeriodEndsAt,
  });

  final String erasureId;
  final DateTime gracePeriodEndsAt;
}

/// CODE_OPS_DEBT Theme B#1 — outcome of `reversePiiErasure`. The
/// proxy returns 200 on success; 410 when the grace window has
/// expired (which the gateway translates to [graceExpired] = true).
@immutable
class UserPiiErasureReverseSummary {
  const UserPiiErasureReverseSummary({
    required this.reversed,
    required this.graceExpired,
  });

  final bool reversed;
  final bool graceExpired;
}

/// Status row returned by `getPiiErasureStatus`. Mirrors the proxy's
/// JSON shape — `state` is one of `'pending'`, `'applied'`, or
/// `'reversed'`. The screen renders the countdown chip from
/// [gracePeriodEndsAt] when [state] = `'pending'`.
@immutable
class UserPiiErasureStatusSummary {
  const UserPiiErasureStatusSummary({
    required this.erasureId,
    required this.state,
    required this.requestedAt,
    required this.gracePeriodEndsAt,
    this.appliedAt,
    this.reversedAt,
    this.reversedByUserId,
    this.reversalReason,
  });

  final String erasureId;
  final String state;
  final DateTime requestedAt;
  final DateTime gracePeriodEndsAt;
  final DateTime? appliedAt;
  final DateTime? reversedAt;
  final String? reversedByUserId;
  final String? reversalReason;

  bool get isPending => state == 'pending';
  bool get isApplied => state == 'applied';
  bool get isReversed => state == 'reversed';
}

/// Paired-approval result returned by `issuePairedApprovalErasure`.
/// `pendingSecondApproval == true` means the gateway captured the
/// first admin's request and is awaiting the second admin's
/// confirmation; `pendingSecondApproval == false` means both
/// approvals have landed and the erasure is queued.
@immutable
class PairedApprovalErasureResult {
  const PairedApprovalErasureResult({
    required this.requestId,
    required this.pendingSecondApproval,
    required this.firstApproverUserId,
    this.secondApproverUserId,
  });

  final String requestId;
  final bool pendingSecondApproval;
  final String firstApproverUserId;
  final String? secondApproverUserId;
}

/// 403 thrown when a non-forge-admin caller tries to mutate via this
/// gateway. The screen layer also hides every mutate affordance via
/// `editingEnabled`; the gateway throw is defence-in-depth.
class AuditedSupportActionsForbiddenException implements Exception {
  const AuditedSupportActionsForbiddenException(this.message);

  final String message;

  @override
  String toString() => 'AuditedSupportActionsForbiddenException: $message';
}

class AuditedSupportActionsGatewayError implements Exception {
  const AuditedSupportActionsGatewayError({
    required this.statusCode,
    required this.errorCode,
    required this.message,
  });

  final int statusCode;
  final String errorCode;
  final String message;

  @override
  String toString() =>
      'AuditedSupportActionsGatewayError($statusCode/$errorCode): $message';
}

abstract class AuditedSupportActionsAdminGateway {
  // ── Audit-log reads ────────────────────────────────────────────────
  Future<AuditLogPage> listAuditLog({
    required String operatorId,
    AuditLogFilters filters = AuditLogFilters.empty,
    String? cursor,
  });

  /// CSV export. Gated on `admin.audit_log.export` per the parity
  /// contract § Audit Log "CSV export" line 147. The export job
  /// itself writes an audit row (`audit.export.requested`).
  Future<String> exportAuditLogCsv({
    required String operatorId,
    required AuditLogFilters filters,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  // ── Actions panel ──────────────────────────────────────────────────

  Future<List<SupportActionsMember>> listMembers({required String operatorId});

  /// Reset member MFA. Gated on the new
  /// `admin.users.reset_mfa_factors` key (MFA-required) per the
  /// parity contract § Security line 161.
  Future<AdminActionLogRow> resetMemberMfa({
    required String operatorId,
    required String targetUserId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// Initiate admin-driven password reset. Gated on
  /// `admin.users.reset_password`. Sends the recovery email via the
  /// proxy's SendGrid binding.
  Future<AdminActionLogRow> initiatePasswordReset({
    required String operatorId,
    required String targetUserId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// Issue paired-approval erasure. Gated on
  /// `admin.users.erase_pii` (MFA-required) + paired-approval
  /// workflow. The first call captures the first admin's request
  /// and returns `pendingSecondApproval = true`; the second call
  /// (with the same `requestId`) confirms and returns
  /// `pendingSecondApproval = false`. The second approver MUST be a
  /// distinct F&F admin; the gateway rejects same-admin
  /// confirmations with `cannot_self_pair`.
  Future<PairedApprovalErasureResult> issuePairedApprovalErasure({
    required String operatorId,
    required String targetUserId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
    String? confirmRequestId,
  });

  /// CODE_OPS_DEBT Theme B#1 — single-admin PII erasure with 24h
  /// grace-window reverse. The proxy returns 202 with the
  /// [UserPiiErasureRequestSummary]; the screen renders a countdown
  /// chip based on [gracePeriodEndsAt] and offers a "Reverse" action
  /// while the chip is non-zero.
  Future<UserPiiErasureRequestSummary> requestPiiErasure({
    required String operatorId,
    required String targetUserId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  });

  /// CODE_OPS_DEBT Theme B#1 — reverses a pending erasure within its
  /// 24h grace window. Returns [UserPiiErasureReverseSummary.reversed]
  /// on success; the proxy 410 (grace expired or already terminal)
  /// flips [graceExpired] = true so the screen can re-render the
  /// status panel without surfacing the reverse affordance again.
  Future<UserPiiErasureReverseSummary> reversePiiErasure({
    required String operatorId,
    required String targetUserId,
    required String erasureId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reversalReason,
  });

  /// CODE_OPS_DEBT Theme B#1 — read latest erasure status for a user.
  /// Returns null when no erasure has ever been issued.
  Future<UserPiiErasureStatusSummary?> getPiiErasureStatus({
    required String operatorId,
    required String targetUserId,
  });
}

class HttpAuditedSupportActionsAdminGateway
    implements AuditedSupportActionsAdminGateway {
  HttpAuditedSupportActionsAdminGateway({
    required this.baseUri,
    required this.bearerTokenProvider,
    http.Client? httpClient,
    Duration timeout = kAdminHttpRequestTimeout,
  }) : _httpClient = httpClient ?? http.Client(),
       _timeout = timeout;

  final Uri baseUri;
  final AuditedSupportActionsBearerTokenProvider bearerTokenProvider;
  final http.Client _httpClient;
  final Duration _timeout;

  static const String auditLogPath = '/v1/admin/auth/audit-log';
  static const String auditLogExportPath = '/v1/admin/auth/audit-log/export';
  static const String membersPath = '/v1/admin/auth/users';
  static const String mfaResetPathPrefix = '/v1/admin/auth/users/';
  static const String mfaResetPathSuffix = '/mfa/reset';
  static const String passwordResetPathSuffix = '/password/reset';
  static const String erasurePathSuffix = '/erasure';
  // CODE_OPS_DEBT Theme B#1 — single-admin PII erasure routes.
  static const String piiErasurePathSuffix = '/erase-pii';
  static const String piiErasureReversePathSuffix = '/erase-pii/reverse';

  @override
  Future<AuditLogPage> listAuditLog({
    required String operatorId,
    AuditLogFilters filters = AuditLogFilters.empty,
    String? cursor,
  }) async {
    final query = <String, String>{
      'operator_id': operatorId,
      if (filters.actorUserId != null) 'actor_user_id': filters.actorUserId!,
      if (filters.actions.isNotEmpty) 'actions': filters.actions.join(','),
      if (filters.targetKind != null) 'target_kind': filters.targetKind!,
      if (filters.targetId != null && filters.targetId!.trim().isNotEmpty)
        'target_id': filters.targetId!.trim(),
      if (filters.timeWindow != null) 'time_window': filters.timeWindow!.wire,
      if (filters.customRangeFrom != null)
        'from': filters.customRangeFrom!.toUtc().toIso8601String(),
      if (filters.customRangeTo != null)
        'to': filters.customRangeTo!.toUtc().toIso8601String(),
      if (filters.actorKinds.isNotEmpty)
        'actor_kinds': filters.actorKinds.map((k) => k.wire).join(','),
      if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
    };
    final body = await _send(
      method: 'GET',
      path: auditLogPath,
      queryParameters: query,
    );
    final rows = (body['rows'] as List?) ?? const [];
    final next = body['next_cursor'];
    return AuditLogPage(
      rows: <AuditLogRow>[
        for (final row in rows)
          _auditRowFromJson((row as Map).cast<String, Object?>()),
      ],
      nextCursor: next is String && next.isNotEmpty ? next : null,
    );
  }

  @override
  Future<String> exportAuditLogCsv({
    required String operatorId,
    required AuditLogFilters filters,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'exportAuditLogCsv');
    _requireAdminReason(adminReason, 'exportAuditLogCsv');
    final body = await _send(
      method: 'POST',
      path: auditLogExportPath,
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        if (filters.actorUserId != null) 'actor_user_id': filters.actorUserId,
        if (filters.actions.isNotEmpty) 'actions': filters.actions,
        if (filters.targetKind != null) 'target_kind': filters.targetKind,
        if (filters.targetId != null && filters.targetId!.trim().isNotEmpty)
          'target_id': filters.targetId!.trim(),
        if (filters.timeWindow != null) 'time_window': filters.timeWindow!.wire,
        if (filters.customRangeFrom != null)
          'from': filters.customRangeFrom!.toUtc().toIso8601String(),
        if (filters.customRangeTo != null)
          'to': filters.customRangeTo!.toUtc().toIso8601String(),
        if (filters.actorKinds.isNotEmpty)
          'actor_kinds': filters.actorKinds.map((k) => k.wire).toList(),
        'admin_reason': adminReason,
      },
    );
    final csv = body['csv'];
    return csv is String ? csv : '';
  }

  @override
  Future<List<SupportActionsMember>> listMembers({
    required String operatorId,
  }) async {
    final body = await _send(
      method: 'GET',
      path: membersPath,
      queryParameters: <String, String>{'operator_id': operatorId},
    );
    final users = (body['users'] as List?) ?? const [];
    return <SupportActionsMember>[
      for (final user in users)
        _memberFromJson((user as Map).cast<String, Object?>()),
    ];
  }

  @override
  Future<AdminActionLogRow> resetMemberMfa({
    required String operatorId,
    required String targetUserId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'resetMemberMfa');
    _requireAdminReason(adminReason, 'resetMemberMfa');
    final body = await _send(
      method: 'POST',
      path:
          '$mfaResetPathPrefix${Uri.encodeComponent(targetUserId)}'
          '$mfaResetPathSuffix',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
    return _adminActionLogRowFromJson(_asMap(body['admin_action_log']));
  }

  @override
  Future<AdminActionLogRow> initiatePasswordReset({
    required String operatorId,
    required String targetUserId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'initiatePasswordReset');
    _requireAdminReason(adminReason, 'initiatePasswordReset');
    final body = await _send(
      method: 'POST',
      path:
          '$mfaResetPathPrefix${Uri.encodeComponent(targetUserId)}'
          '$passwordResetPathSuffix',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
    return _adminActionLogRowFromJson(_asMap(body['admin_action_log']));
  }

  @override
  Future<PairedApprovalErasureResult> issuePairedApprovalErasure({
    required String operatorId,
    required String targetUserId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
    String? confirmRequestId,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'issuePairedApprovalErasure');
    _requireAdminReason(adminReason, 'issuePairedApprovalErasure');
    final body = await _send(
      method: 'POST',
      path:
          '$mfaResetPathPrefix${Uri.encodeComponent(targetUserId)}'
          '$erasurePathSuffix',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
        if (confirmRequestId != null) 'confirm_request_id': confirmRequestId,
      },
    );
    return _pairedApprovalFromJson(_asMap(body['erasure']));
  }

  @override
  Future<UserPiiErasureRequestSummary> requestPiiErasure({
    required String operatorId,
    required String targetUserId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'requestPiiErasure');
    _requireAdminReason(adminReason, 'requestPiiErasure');
    final body = await _send(
      method: 'POST',
      path:
          '$mfaResetPathPrefix${Uri.encodeComponent(targetUserId)}'
          '$piiErasurePathSuffix',
      idempotencyKey: idempotencyKey,
      jsonBody: <String, Object?>{
        'operator_id': operatorId,
        'admin_reason': adminReason,
      },
    );
    final erasureId = body['erasure_id'];
    final graceEndsAtRaw = body['grace_period_ends_at'];
    if (erasureId is! String ||
        erasureId.isEmpty ||
        graceEndsAtRaw is! String ||
        graceEndsAtRaw.isEmpty) {
      throw AuditedSupportActionsGatewayError(
        statusCode: 502,
        errorCode: 'malformed_pii_erasure_response',
        message:
            'admin proxy returned a PII erasure response without '
            'erasure_id / grace_period_ends_at',
      );
    }
    return UserPiiErasureRequestSummary(
      erasureId: erasureId,
      gracePeriodEndsAt: DateTime.parse(graceEndsAtRaw).toUtc(),
    );
  }

  @override
  Future<UserPiiErasureReverseSummary> reversePiiErasure({
    required String operatorId,
    required String targetUserId,
    required String erasureId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    String? reversalReason,
  }) async {
    _requireEditable(actorIsForgeAdmin, 'reversePiiErasure');
    try {
      await _send(
        method: 'POST',
        path:
            '$mfaResetPathPrefix${Uri.encodeComponent(targetUserId)}'
            '$piiErasureReversePathSuffix',
        idempotencyKey: idempotencyKey,
        jsonBody: <String, Object?>{
          'operator_id': operatorId,
          'erasure_id': erasureId,
          if (reversalReason != null && reversalReason.isNotEmpty)
            'reversal_reason': reversalReason,
        },
      );
      return const UserPiiErasureReverseSummary(
        reversed: true,
        graceExpired: false,
      );
    } on AuditedSupportActionsGatewayError catch (error) {
      if (error.statusCode == 410 ||
          error.errorCode == 'grace_window_expired') {
        return const UserPiiErasureReverseSummary(
          reversed: false,
          graceExpired: true,
        );
      }
      rethrow;
    }
  }

  @override
  Future<UserPiiErasureStatusSummary?> getPiiErasureStatus({
    required String operatorId,
    required String targetUserId,
  }) async {
    final body = await _send(
      method: 'GET',
      path:
          '$mfaResetPathPrefix${Uri.encodeComponent(targetUserId)}'
          '$piiErasurePathSuffix',
      queryParameters: <String, String>{'operator_id': operatorId},
    );
    final raw = body['erasure'];
    if (raw == null) return null;
    final map = (raw as Map).cast<String, Object?>();
    final erasureId = map['erasure_id'];
    final state = map['state'];
    final requestedAtRaw = map['requested_at'];
    final graceEndsAtRaw = map['grace_period_ends_at'];
    if (erasureId is! String ||
        state is! String ||
        requestedAtRaw is! String ||
        graceEndsAtRaw is! String) {
      throw AuditedSupportActionsGatewayError(
        statusCode: 502,
        errorCode: 'malformed_pii_erasure_status',
        message: 'admin proxy returned a malformed PII erasure status row',
      );
    }
    return UserPiiErasureStatusSummary(
      erasureId: erasureId,
      state: state,
      requestedAt: DateTime.parse(requestedAtRaw).toUtc(),
      gracePeriodEndsAt: DateTime.parse(graceEndsAtRaw).toUtc(),
      appliedAt: map['applied_at'] is String
          ? DateTime.parse(map['applied_at'] as String).toUtc()
          : null,
      reversedAt: map['reversed_at'] is String
          ? DateTime.parse(map['reversed_at'] as String).toUtc()
          : null,
      reversedByUserId: map['reversed_by_user_id'] as String?,
      reversalReason: map['reversal_reason'] as String?,
    );
  }

  void _requireEditable(bool actorIsForgeAdmin, String operation) {
    if (!actorIsForgeAdmin) {
      throw AuditedSupportActionsForbiddenException(
        '$operation requires forge_admin role',
      );
    }
  }

  void _requireAdminReason(String adminReason, String operation) {
    if (adminReason.trim().isEmpty) {
      throw AuditedSupportActionsGatewayError(
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
      throw AuditedSupportActionsGatewayError(
        statusCode: 408,
        errorCode: 'timeout',
        message:
            'admin audited-support-actions proxy timed out after '
            '${_timeout.inSeconds}s',
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
        'admin audited-support-actions proxy returned an error';
    if (response.statusCode == 403) {
      throw AuditedSupportActionsForbiddenException(message);
    }
    throw AuditedSupportActionsGatewayError(
      statusCode: response.statusCode,
      errorCode: (parsed['error'] as String?) ?? 'unknown_error',
      message: message,
    );
  }
}

AuditLogRow _auditRowFromJson(Map<String, Object?> json) {
  final payloadRaw = json['payload'];
  return AuditLogRow(
    eventId: _stringField(json, 'event_id'),
    action: _stringField(json, 'action'),
    occurredAt: _dateTimeField(json, 'occurred_at'),
    actorUserId: _stringField(json, 'actor_user_id'),
    actorDisplayName: (json['actor_display_name'] as String?) ?? '',
    actorEmail: (json['actor_email'] as String?) ?? '',
    actorKind: auditActorKindFromWire(_stringField(json, 'actor_kind')),
    operatorId: _stringField(json, 'operator_id'),
    targetKind: _stringField(json, 'target_kind'),
    targetId: _stringField(json, 'target_id'),
    payload: payloadRaw is Map
        ? payloadRaw.cast<String, Object?>()
        : const <String, Object?>{},
    businessDate: _dateTimeField(json, 'business_date'),
    adminReason: _optionalString(json['admin_reason']),
    rowHash: _optionalString(json['row_hash']),
  );
}

SupportActionsMember _memberFromJson(Map<String, Object?> json) {
  final status =
      _optionalString(json['status']) ??
      _optionalString(json['state']) ??
      _optionalString(json['invite_status']);
  final inviteOnly =
      status == 'pending_invite' ||
      status == 'invite_pending' ||
      status == 'pending';
  return SupportActionsMember(
    userId: _stringField(json, 'user_id'),
    email: _stringField(json, 'email'),
    displayName: _stringField(json, 'display_name'),
    mfaEnrolled: _boolField(json, 'mfa_enrolled'),
    canReceivePasswordReset: _optionalBoolField(
      json,
      'can_receive_password_reset',
      defaultValue: !inviteOnly,
    ),
    passwordResetBlockedReason: _optionalString(
      json['password_reset_blocked_reason'],
    ),
  );
}

AdminActionLogRow _adminActionLogRowFromJson(Map<String, Object?> json) {
  return AdminActionLogRow(
    actionLogId: _stringField(json, 'action_log_id'),
    action: _stringField(json, 'action'),
    occurredAt: _dateTimeField(json, 'occurred_at'),
    readerUserId: _stringField(json, 'reader_user_id'),
    operatorId: _stringField(json, 'operator_id'),
    targetKind: _stringField(json, 'target_kind'),
    targetId: _stringField(json, 'target_id'),
    recordsTouched: _intField(json, 'records_touched'),
    adminReason: _stringField(json, 'admin_reason'),
  );
}

PairedApprovalErasureResult _pairedApprovalFromJson(Map<String, Object?> json) {
  return PairedApprovalErasureResult(
    requestId: _stringField(json, 'request_id'),
    pendingSecondApproval: _boolField(json, 'pending_second_approval'),
    firstApproverUserId: _stringField(json, 'first_approver_user_id'),
    secondApproverUserId: _optionalString(json['second_approver_user_id']),
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

bool _boolField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  if (value is String) return value == 'true';
  return false;
}

bool _optionalBoolField(
  Map<String, Object?> json,
  String key, {
  required bool defaultValue,
}) {
  final value = json[key];
  if (value is bool) return value;
  if (value is String) return value == 'true';
  return defaultValue;
}

int _intField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.parse(value);
  return 0;
}

String? _optionalString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

DateTime _dateTimeField(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is DateTime) return value.toUtc();
  if (value is String && value.isNotEmpty) {
    return DateTime.parse(value).toUtc();
  }
  throw StateError('missing datetime field $key');
}

/// Locked validation copy for the Actions panel. Mirrored verbatim
/// in widget tests to detect drift.
class SupportActionsValidationCopy {
  const SupportActionsValidationCopy._();

  /// Per the parity contract paired-approval workflow: a second F&F
  /// admin must confirm the erasure; the first approver cannot pair
  /// with themselves.
  static const String cannotSelfPair =
      'A second F&F admin must confirm this erasure. '
      'You cannot confirm your own request.';

  /// Generic blank-reason guard.
  static const String adminReasonRequired = 'Add a reason before continuing.';
}

/// Locked vocabulary the demo gateway and the live proxy emit on
/// every admin support action. Surface tests assert this set is
/// stable so audit-log payload schemas stay parseable.
class SupportActionsAuditAction {
  const SupportActionsAuditAction._();

  static const String resetMfaFactors = 'admin.users.reset_mfa_factors';
  static const String resetPassword = 'admin.users.reset_password';
  static const String erasureRequested = 'admin.users.erasure.requested';
  static const String erasureConfirmed = 'admin.users.erasure.confirmed';
  static const String auditExportRequested = 'audit.export.requested';
}
