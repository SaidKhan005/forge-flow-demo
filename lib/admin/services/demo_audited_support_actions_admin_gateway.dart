// Phase 11A.14 - in-memory demo gateway for the cross-operator
// Audited support actions surface. Powers the kDemoMode walkthrough
// plus widget tests. Mirrors the shape of
// [HttpAuditedSupportActionsAdminGateway]: every write is gated on
// `actorIsForgeAdmin` + non-empty `admin_reason`, every successful
// write captures both an `audit_logs`-shaped event AND an
// `admin_action_log` provenance row, and every retried call with the
// same idempotency key returns the original result without
// double-mutation.
//
// Demo seeds reuse the two operators from the 11A.12 / 11A.13
// fixtures (Demo Diner Co. + Sunset Cafe Group) so the walkthrough
// can hop from Members / Roles / Hierarchy / Sessions straight into
// the Audited support actions surface for the same operator.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'audited_support_actions_admin_gateway.dart';
import 'demo_members_admin_gateway.dart';

class InMemoryAuditedSupportActionsAdminGateway
    implements AuditedSupportActionsAdminGateway {
  InMemoryAuditedSupportActionsAdminGateway({
    Map<String, List<AuditLogRow>>? auditLogByOperator,
    Map<String, List<SupportActionsMember>>? membersByOperator,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       _auditLogs = <String, List<AuditLogRow>>{
         for (final entry in (auditLogByOperator ?? const {}).entries)
           entry.key: List<AuditLogRow>.of(entry.value),
       },
       _members = <String, List<SupportActionsMember>>{
         for (final entry in (membersByOperator ?? const {}).entries)
           entry.key: List<SupportActionsMember>.of(entry.value),
       };

  final DateTime Function() _clock;
  final Map<String, List<AuditLogRow>> _auditLogs;
  final Map<String, List<SupportActionsMember>> _members;
  final List<AdminActionLogRow> _adminActionLog = <AdminActionLogRow>[];
  final Map<String, Object?> _idempotentResults = <String, Object?>{};
  final Map<String, _PendingErasure> _pendingErasures =
      <String, _PendingErasure>{};

  /// Public read-only view of the F&F-internal `admin_action_log`
  /// rows captured so far. Tests assert against this directly to pin
  /// `reader_user_id`, `target_id`, `records_touched`, and
  /// `admin_reason` on every escalation.
  List<AdminActionLogRow> get capturedAdminActionLog =>
      List<AdminActionLogRow>.unmodifiable(_adminActionLog);

  /// Public read-only view of the `audit_logs`-shaped rows captured
  /// so far. Tests use this to assert the locked vocabulary
  /// (`SupportActionsAuditAction.*`) and the audit-row shape from
  /// the parity contract § Audit-row shape.
  List<AuditLogRow> capturedAuditLogFor(String operatorId) {
    return List<AuditLogRow>.unmodifiable(
      _auditLogs[operatorId] ?? const <AuditLogRow>[],
    );
  }

  void _ensureForgeAdmin(bool actorIsForgeAdmin, String operation) {
    if (!actorIsForgeAdmin) {
      throw AuditedSupportActionsForbiddenException(
        '$operation requires forge_admin role',
      );
    }
  }

  void _ensureAdminReason(String adminReason, String operation) {
    if (adminReason.trim().isEmpty) {
      throw AuditedSupportActionsGatewayError(
        statusCode: 400,
        errorCode: 'admin_reason_required',
        message: '$operation requires a non-empty admin_reason',
      );
    }
  }

  List<AuditLogRow> _logsFor(String operatorId) {
    return _auditLogs.putIfAbsent(operatorId, () => <AuditLogRow>[]);
  }

  List<SupportActionsMember> _membersFor(String operatorId) {
    return _members.putIfAbsent(operatorId, () => <SupportActionsMember>[]);
  }

  /// Append an audit-log row at the head of the list (most recent
  /// first), mirroring the proxy's `created_at DESC` ordering pinned
  /// in the parity contract § Audit Log "Pagination" line 143.
  AuditLogRow _appendAuditRow({
    required String operatorId,
    required String action,
    required String actorUserId,
    required String actorDisplayName,
    required String actorEmail,
    required AuditActorKind actorKind,
    required String targetKind,
    required String targetId,
    required Map<String, Object?> payload,
    String? adminReason,
  }) {
    final occurredAt = _clock();
    final row = AuditLogRow(
      eventId:
          'audit-${_logsFor(operatorId).length + 1}-'
          '${occurredAt.microsecondsSinceEpoch}',
      action: action,
      occurredAt: occurredAt,
      actorUserId: actorUserId,
      actorDisplayName: actorDisplayName,
      actorEmail: actorEmail,
      actorKind: actorKind,
      operatorId: operatorId,
      targetKind: targetKind,
      targetId: targetId,
      payload: Map<String, Object?>.unmodifiable(payload),
      businessDate: DateTime.utc(
        occurredAt.year,
        occurredAt.month,
        occurredAt.day,
      ),
      adminReason: adminReason,
    );
    _logsFor(operatorId).insert(0, row);
    return row;
  }

  AdminActionLogRow _appendAdminActionLog({
    required String operatorId,
    required String action,
    required String readerUserId,
    required String targetKind,
    required String targetId,
    required int recordsTouched,
    required String adminReason,
  }) {
    final occurredAt = _clock();
    final entry = AdminActionLogRow(
      actionLogId:
          'admin-action-${_adminActionLog.length + 1}-'
          '${occurredAt.microsecondsSinceEpoch}',
      action: action,
      occurredAt: occurredAt,
      readerUserId: readerUserId,
      operatorId: operatorId,
      targetKind: targetKind,
      targetId: targetId,
      recordsTouched: recordsTouched,
      adminReason: adminReason,
    );
    _adminActionLog.add(entry);
    return entry;
  }

  SupportActionsMember _requireMember(String operatorId, String userId) {
    final members = _membersFor(operatorId);
    return members.firstWhere(
      (m) => m.userId == userId,
      orElse: () => throw AuditedSupportActionsGatewayError(
        statusCode: 404,
        errorCode: 'unknown_user',
        message: 'user $userId not found in operator $operatorId',
      ),
    );
  }

  @override
  Future<AuditLogPage> listAuditLog({
    required String operatorId,
    AuditLogFilters filters = AuditLogFilters.empty,
    String? cursor,
    AuditLogScope? scope,
  }) async {
    final all = _logsFor(operatorId);
    Iterable<AuditLogRow> filtered = all;
    if (scope != null && scope.scopeType == AuditLogScopeType.location) {
      final location = scope.locationFilter?.trim();
      if (location != null && location.isNotEmpty) {
        filtered = filtered.where(
          (r) =>
              r.payload['location_id'] == location ||
              r.payload['location_filter'] == location,
        );
      }
    }
    final actorUserIds = filters.effectiveActorUserIds;
    if (actorUserIds.isNotEmpty) {
      final wanted = actorUserIds.toSet();
      filtered = filtered.where((r) => wanted.contains(r.actorUserId));
    }
    if (filters.actions.isNotEmpty) {
      final wanted = filters.actions.toSet();
      filtered = filtered.where((r) => wanted.contains(r.action));
    }
    if (filters.targetKind != null) {
      final wanted = filters.targetKind!.trim().toLowerCase();
      if (wanted.isNotEmpty) {
        filtered = filtered.where(
          (r) => (r.targetKind ?? '').toLowerCase().contains(wanted),
        );
      }
    }
    if (filters.targetId != null && filters.targetId!.trim().isNotEmpty) {
      final wanted = filters.targetId!.trim().toLowerCase();
      filtered = filtered.where(
        (r) => (r.targetId ?? '').toLowerCase().contains(wanted),
      );
    }
    if (filters.actorKinds.isNotEmpty) {
      final wanted = filters.actorKinds.toSet();
      filtered = filtered.where((r) => wanted.contains(r.actorKind));
    }
    if (filters.timeWindow != null) {
      final now = _clock();
      DateTime? lowerBound;
      DateTime? upperBound;
      switch (filters.timeWindow!) {
        case AuditLogTimeWindow.last24h:
          lowerBound = now.subtract(const Duration(hours: 24));
          break;
        case AuditLogTimeWindow.last7d:
          lowerBound = now.subtract(const Duration(days: 7));
          break;
        case AuditLogTimeWindow.last30d:
          lowerBound = now.subtract(const Duration(days: 30));
          break;
        case AuditLogTimeWindow.last90d:
          lowerBound = now.subtract(const Duration(days: 90));
          break;
        case AuditLogTimeWindow.customRange:
          lowerBound = filters.customRangeFrom;
          upperBound = filters.customRangeTo;
          break;
      }
      if (lowerBound != null) {
        filtered = filtered.where((r) => !r.occurredAt.isBefore(lowerBound!));
      }
      if (upperBound != null) {
        filtered = filtered.where((r) => !r.occurredAt.isAfter(upperBound!));
      }
    }
    final list = filtered.toList(growable: false);
    // Demo gateway returns the first 200 unconditionally; production
    // pagination is the proxy's job.
    const pageSize = 200;
    final start = cursor == null ? 0 : int.tryParse(cursor) ?? 0;
    final end = (start + pageSize).clamp(0, list.length);
    final page = list.sublist(start, end);
    final next = end < list.length ? '$end' : null;
    return AuditLogPage(rows: page, nextCursor: next);
  }

  @override
  Future<String> exportAuditLogCsv({
    required String operatorId,
    required AuditLogFilters filters,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
    AuditLogScope? scope,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'exportAuditLogCsv');
    _ensureAdminReason(adminReason, 'exportAuditLogCsv');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is String) return cached;
    final page = await listAuditLog(
      operatorId: operatorId,
      filters: filters,
      scope: scope,
    );
    final buf = StringBuffer();
    buf.writeln(
      'created_at,action,actor_user_id,actor_display_name,actor_email,'
      'actor_kind,target_kind,target_id,admin_reason,payload',
    );
    for (final row in page.rows) {
      buf.writeln(
        <String>[
          _csv(row.occurredAt.toUtc().toIso8601String()),
          _csv(row.action),
          _csv(row.actorUserId),
          _csv(row.actorDisplayName),
          _csv(row.actorEmail),
          _csv(row.actorKind.wire),
          _csv(row.targetKind ?? ''),
          _csv(row.targetId ?? ''),
          _csv(row.adminReason ?? ''),
          _csv(row.payload.isEmpty ? '' : jsonEncode(row.payload)),
        ].join(','),
      );
    }
    _appendAuditRow(
      operatorId: operatorId,
      action: SupportActionsAuditAction.auditExportRequested,
      actorUserId: actorUserId,
      actorDisplayName: 'F&F admin',
      actorEmail: '$actorUserId@forgeflow.test',
      actorKind: AuditActorKind.forgeAdmin,
      targetKind: 'audit_log_export',
      targetId: 'csv-${_clock().microsecondsSinceEpoch}',
      payload: <String, Object?>{'rows_exported': page.rows.length},
      adminReason: adminReason,
    );
    final csv = buf.toString();
    _idempotentResults[idempotencyKey] = csv;
    return csv;
  }

  static String _csv(String raw) {
    if (raw.isEmpty) return '';
    if (raw.contains(',') || raw.contains('"') || raw.contains('\n')) {
      final escaped = raw.replaceAll('"', '""');
      return '"$escaped"';
    }
    return raw;
  }

  @override
  Future<List<SupportActionsMember>> listMembers({
    required String operatorId,
  }) async {
    return List<SupportActionsMember>.unmodifiable(_membersFor(operatorId));
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'resetMemberMfa');
    _ensureAdminReason(adminReason, 'resetMemberMfa');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is AdminActionLogRow) return cached;
    final member = _requireMember(operatorId, targetUserId);
    _appendAuditRow(
      operatorId: operatorId,
      action: SupportActionsAuditAction.resetMfaFactors,
      actorUserId: actorUserId,
      actorDisplayName: 'F&F admin',
      actorEmail: '$actorUserId@forgeflow.test',
      actorKind: AuditActorKind.forgeAdmin,
      targetKind: 'user',
      targetId: targetUserId,
      payload: <String, Object?>{
        'mfa_enrolled': <String, Object?>{
          'from': member.mfaEnrolled,
          'to': false,
        },
      },
      adminReason: adminReason,
    );
    final entry = _appendAdminActionLog(
      operatorId: operatorId,
      action: SupportActionsAuditAction.resetMfaFactors,
      readerUserId: actorUserId,
      targetKind: 'user',
      targetId: targetUserId,
      // Reset MFA touches the user's mfa_factors rows; the demo
      // collapses to a single record (the proxy reports the actual
      // count from the live mutation).
      recordsTouched: 1,
      adminReason: adminReason,
    );
    // Reflect the post-reset state on the in-memory member fixture so
    // a re-list of members shows mfa_enrolled = false (lets the
    // walkthrough verify the change without a second proxy call).
    final members = _membersFor(operatorId);
    final idx = members.indexWhere((m) => m.userId == targetUserId);
    if (idx >= 0) {
      members[idx] = SupportActionsMember(
        userId: member.userId,
        email: member.email,
        displayName: member.displayName,
        mfaEnrolled: false,
        canReceivePasswordReset: member.canReceivePasswordReset,
        passwordResetBlockedReason: member.passwordResetBlockedReason,
      );
    }
    _idempotentResults[idempotencyKey] = entry;
    return entry;
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'initiatePasswordReset');
    _ensureAdminReason(adminReason, 'initiatePasswordReset');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is AdminActionLogRow) return cached;
    final member = _requireMember(operatorId, targetUserId);
    _appendAuditRow(
      operatorId: operatorId,
      action: SupportActionsAuditAction.resetPassword,
      actorUserId: actorUserId,
      actorDisplayName: 'F&F admin',
      actorEmail: '$actorUserId@forgeflow.test',
      actorKind: AuditActorKind.forgeAdmin,
      targetKind: 'user',
      targetId: targetUserId,
      payload: <String, Object?>{'recovery_email_to': member.email},
      adminReason: adminReason,
    );
    final entry = _appendAdminActionLog(
      operatorId: operatorId,
      action: SupportActionsAuditAction.resetPassword,
      readerUserId: actorUserId,
      targetKind: 'user',
      targetId: targetUserId,
      recordsTouched: 1,
      adminReason: adminReason,
    );
    _idempotentResults[idempotencyKey] = entry;
    return entry;
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'issuePairedApprovalErasure');
    _ensureAdminReason(adminReason, 'issuePairedApprovalErasure');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is PairedApprovalErasureResult) return cached;
    _requireMember(operatorId, targetUserId);
    if (confirmRequestId == null) {
      // First leg — open a pending request awaiting a second admin.
      final requestId =
          'erasure-${_pendingErasures.length + 1}-'
          '${_clock().microsecondsSinceEpoch}';
      _pendingErasures[requestId] = _PendingErasure(
        requestId: requestId,
        operatorId: operatorId,
        targetUserId: targetUserId,
        firstApproverUserId: actorUserId,
        adminReason: adminReason,
      );
      _appendAuditRow(
        operatorId: operatorId,
        action: SupportActionsAuditAction.erasureRequested,
        actorUserId: actorUserId,
        actorDisplayName: 'F&F admin',
        actorEmail: '$actorUserId@forgeflow.test',
        actorKind: AuditActorKind.forgeAdmin,
        targetKind: 'user',
        targetId: targetUserId,
        payload: <String, Object?>{'request_id': requestId},
        adminReason: adminReason,
      );
      _appendAdminActionLog(
        operatorId: operatorId,
        action: SupportActionsAuditAction.erasureRequested,
        readerUserId: actorUserId,
        targetKind: 'user',
        targetId: targetUserId,
        recordsTouched: 0,
        adminReason: adminReason,
      );
      final result = PairedApprovalErasureResult(
        requestId: requestId,
        pendingSecondApproval: true,
        firstApproverUserId: actorUserId,
      );
      _idempotentResults[idempotencyKey] = result;
      return result;
    }
    // Second leg — confirm an existing pending request.
    final pending = _pendingErasures[confirmRequestId];
    if (pending == null) {
      throw AuditedSupportActionsGatewayError(
        statusCode: 404,
        errorCode: 'unknown_request',
        message: 'erasure request $confirmRequestId not found',
      );
    }
    if (pending.firstApproverUserId == actorUserId) {
      throw AuditedSupportActionsGatewayError(
        statusCode: 400,
        errorCode: 'cannot_self_pair',
        message: SupportActionsValidationCopy.cannotSelfPair,
      );
    }
    _pendingErasures.remove(confirmRequestId);
    _appendAuditRow(
      operatorId: operatorId,
      action: SupportActionsAuditAction.erasureConfirmed,
      actorUserId: actorUserId,
      actorDisplayName: 'F&F admin',
      actorEmail: '$actorUserId@forgeflow.test',
      actorKind: AuditActorKind.forgeAdmin,
      targetKind: 'user',
      targetId: pending.targetUserId,
      payload: <String, Object?>{
        'request_id': confirmRequestId,
        'first_approver_user_id': pending.firstApproverUserId,
      },
      adminReason: adminReason,
    );
    _appendAdminActionLog(
      operatorId: operatorId,
      action: SupportActionsAuditAction.erasureConfirmed,
      readerUserId: actorUserId,
      targetKind: 'user',
      targetId: pending.targetUserId,
      // Erasure paints PII columns across multiple tables
      // (users, audit_logs.payload, etc); the demo reports a small
      // illustrative number.
      recordsTouched: 4,
      adminReason: adminReason,
    );
    final result = PairedApprovalErasureResult(
      requestId: confirmRequestId,
      pendingSecondApproval: false,
      firstApproverUserId: pending.firstApproverUserId,
      secondApproverUserId: actorUserId,
    );
    _idempotentResults[idempotencyKey] = result;
    return result;
  }

  // ─── CODE_OPS_DEBT Theme B#1 — single-admin PII erasure ─────────
  // The walkthrough now exercises the single-admin flow with a 24h
  // grace window. The demo gateway records each erasure under
  // `_singleAdminErasures` keyed by (operatorId, userId) and emits
  // an `audit_logs`-shaped row tagged with the new
  // `users.pii_erasure_requested|reversed|applied` actions.

  final Map<String, _SingleAdminErasure> _singleAdminErasures =
      <String, _SingleAdminErasure>{};
  static const Duration _demoGracePeriod = Duration(hours: 24);

  String _erasureKey(String operatorId, String targetUserId) =>
      '$operatorId::$targetUserId';

  @override
  Future<UserPiiErasureRequestSummary> requestPiiErasure({
    required String operatorId,
    required String targetUserId,
    required String idempotencyKey,
    required String actorUserId,
    required bool actorIsForgeAdmin,
    required String adminReason,
  }) async {
    _ensureForgeAdmin(actorIsForgeAdmin, 'requestPiiErasure');
    _ensureAdminReason(adminReason, 'requestPiiErasure');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is UserPiiErasureRequestSummary) return cached;
    _requireMember(operatorId, targetUserId);

    final requestedAt = _clock();
    final gracePeriodEndsAt = requestedAt.add(_demoGracePeriod);
    final erasureId =
        'pii-erasure-'
        '${_singleAdminErasures.length + 1}-'
        '${requestedAt.microsecondsSinceEpoch}';
    _singleAdminErasures[_erasureKey(
      operatorId,
      targetUserId,
    )] = _SingleAdminErasure(
      erasureId: erasureId,
      operatorId: operatorId,
      targetUserId: targetUserId,
      requestedByUserId: actorUserId,
      requestedAt: requestedAt,
      gracePeriodEndsAt: gracePeriodEndsAt,
      state: 'pending',
    );
    _appendAuditRow(
      operatorId: operatorId,
      action: SupportActionsAuditAction.erasureRequested,
      actorUserId: actorUserId,
      actorDisplayName: 'F&F admin',
      actorEmail: '$actorUserId@forgeflow.test',
      actorKind: AuditActorKind.forgeAdmin,
      targetKind: 'user',
      targetId: targetUserId,
      payload: <String, Object?>{
        'erasure_id': erasureId,
        'grace_period_ends_at': gracePeriodEndsAt.toUtc().toIso8601String(),
      },
      adminReason: adminReason,
    );
    final result = UserPiiErasureRequestSummary(
      erasureId: erasureId,
      gracePeriodEndsAt: gracePeriodEndsAt,
    );
    _idempotentResults[idempotencyKey] = result;
    return result;
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
    _ensureForgeAdmin(actorIsForgeAdmin, 'reversePiiErasure');
    final cached = _idempotentResults[idempotencyKey];
    if (cached is UserPiiErasureReverseSummary) return cached;
    final entry = _singleAdminErasures[_erasureKey(operatorId, targetUserId)];
    if (entry == null || entry.erasureId != erasureId) {
      throw AuditedSupportActionsGatewayError(
        statusCode: 404,
        errorCode: 'erasure_not_found',
        message: 'erasure $erasureId not found for user $targetUserId',
      );
    }
    if (entry.state != 'pending' ||
        !_clock().isBefore(entry.gracePeriodEndsAt)) {
      const result = UserPiiErasureReverseSummary(
        reversed: false,
        graceExpired: true,
      );
      _idempotentResults[idempotencyKey] = result;
      return result;
    }
    _singleAdminErasures[_erasureKey(operatorId, targetUserId)] = entry
        .copyWith(
          state: 'reversed',
          reversedAt: _clock(),
          reversedByUserId: actorUserId,
          reversalReason: reversalReason,
        );
    _appendAuditRow(
      operatorId: operatorId,
      action: SupportActionsAuditAction.erasureRequested,
      actorUserId: actorUserId,
      actorDisplayName: 'F&F admin',
      actorEmail: '$actorUserId@forgeflow.test',
      actorKind: AuditActorKind.forgeAdmin,
      targetKind: 'user',
      targetId: targetUserId,
      payload: <String, Object?>{
        'erasure_id': erasureId,
        if (reversalReason != null) 'reversal_reason': reversalReason,
      },
      adminReason: reversalReason ?? 'admin reversed pii erasure',
    );
    const result = UserPiiErasureReverseSummary(
      reversed: true,
      graceExpired: false,
    );
    _idempotentResults[idempotencyKey] = result;
    return result;
  }

  @override
  Future<UserPiiErasureStatusSummary?> getPiiErasureStatus({
    required String operatorId,
    required String targetUserId,
  }) async {
    final entry = _singleAdminErasures[_erasureKey(operatorId, targetUserId)];
    if (entry == null) return null;
    return UserPiiErasureStatusSummary(
      erasureId: entry.erasureId,
      state: entry.state,
      requestedAt: entry.requestedAt,
      gracePeriodEndsAt: entry.gracePeriodEndsAt,
      appliedAt: entry.appliedAt,
      reversedAt: entry.reversedAt,
      reversedByUserId: entry.reversedByUserId,
      reversalReason: entry.reversalReason,
    );
  }

  @visibleForTesting
  void clearForTesting() {
    _adminActionLog.clear();
    _idempotentResults.clear();
    _pendingErasures.clear();
    _singleAdminErasures.clear();
  }
}

class _SingleAdminErasure {
  const _SingleAdminErasure({
    required this.erasureId,
    required this.operatorId,
    required this.targetUserId,
    required this.requestedByUserId,
    required this.requestedAt,
    required this.gracePeriodEndsAt,
    required this.state,
    this.appliedAt,
    this.reversedAt,
    this.reversedByUserId,
    this.reversalReason,
  });

  final String erasureId;
  final String operatorId;
  final String targetUserId;
  final String requestedByUserId;
  final DateTime requestedAt;
  final DateTime gracePeriodEndsAt;
  final String state;
  final DateTime? appliedAt;
  final DateTime? reversedAt;
  final String? reversedByUserId;
  final String? reversalReason;

  _SingleAdminErasure copyWith({
    String? state,
    DateTime? appliedAt,
    DateTime? reversedAt,
    String? reversedByUserId,
    String? reversalReason,
  }) {
    return _SingleAdminErasure(
      erasureId: erasureId,
      operatorId: operatorId,
      targetUserId: targetUserId,
      requestedByUserId: requestedByUserId,
      requestedAt: requestedAt,
      gracePeriodEndsAt: gracePeriodEndsAt,
      state: state ?? this.state,
      appliedAt: appliedAt ?? this.appliedAt,
      reversedAt: reversedAt ?? this.reversedAt,
      reversedByUserId: reversedByUserId ?? this.reversedByUserId,
      reversalReason: reversalReason ?? this.reversalReason,
    );
  }
}

class _PendingErasure {
  const _PendingErasure({
    required this.requestId,
    required this.operatorId,
    required this.targetUserId,
    required this.firstApproverUserId,
    required this.adminReason,
  });

  final String requestId;
  final String operatorId;
  final String targetUserId;
  final String firstApproverUserId;
  final String adminReason;
}

// ---------------------------------------------------------------------
// Demo seeds
// ---------------------------------------------------------------------

/// Demo audit-log entries seeded so the walkthrough renders a
/// non-empty table on first open. Mirrors the canonical action
/// vocabulary across self-service (`team_member`) and admin
/// (`forge_admin`) actor kinds so the locked filter set has rows to
/// match against.
Map<String, List<AuditLogRow>> kDemoAuditLogByOperator({DateTime? at}) {
  final ts = at ?? DateTime.utc(2026, 5, 5, 12);
  return <String, List<AuditLogRow>>{
    kDemoDinerOperatorId: <AuditLogRow>[
      AuditLogRow(
        eventId: 'seed-diner-1',
        action: 'team.users.invite',
        occurredAt: ts.subtract(const Duration(hours: 6)),
        actorUserId: 'demo-user-diner-owner',
        actorDisplayName: 'Dana Owner',
        actorEmail: 'owner@demo-diner.test',
        actorKind: AuditActorKind.teamMember,
        operatorId: kDemoDinerOperatorId,
        targetKind: 'user',
        targetId: 'demo-user-diner-staff-2',
        payload: const <String, Object?>{
          'invited_email': 'newhire@demo-diner.test',
        },
        businessDate: DateTime.utc(ts.year, ts.month, ts.day),
      ),
      AuditLogRow(
        eventId: 'seed-diner-2',
        action: 'auth.password.change',
        occurredAt: ts.subtract(const Duration(days: 1)),
        actorUserId: 'demo-user-diner-manager',
        actorDisplayName: 'Mira Manager',
        actorEmail: 'manager@demo-diner.test',
        actorKind: AuditActorKind.teamMember,
        operatorId: kDemoDinerOperatorId,
        targetKind: 'user',
        targetId: 'demo-user-diner-manager',
        payload: const <String, Object?>{},
        businessDate: DateTime.utc(ts.year, ts.month, ts.day - 1),
      ),
      AuditLogRow(
        eventId: 'seed-diner-3',
        action: 'admin.session.force_logout',
        occurredAt: ts.subtract(const Duration(days: 2)),
        actorUserId: 'demo-super-admin',
        actorDisplayName: 'F&F admin',
        actorEmail: 'super.admin@forgeflow.test',
        actorKind: AuditActorKind.forgeAdmin,
        operatorId: kDemoDinerOperatorId,
        targetKind: 'auth_session',
        targetId: 'session-diner-owner-mobile',
        payload: const <String, Object?>{'user_id': 'demo-user-diner-owner'},
        businessDate: DateTime.utc(ts.year, ts.month, ts.day - 2),
        adminReason: 'support escalation',
        rowHash: 'demo-hash-3',
      ),
    ],
    kDemoSunsetOperatorId: <AuditLogRow>[
      AuditLogRow(
        eventId: 'seed-sunset-1',
        action: 'auth.mfa.enroll',
        occurredAt: ts.subtract(const Duration(hours: 12)),
        actorUserId: 'demo-user-sunset-owner',
        actorDisplayName: 'Quinn Owner',
        actorEmail: 'owner@sunset-cafe.test',
        actorKind: AuditActorKind.teamMember,
        operatorId: kDemoSunsetOperatorId,
        targetKind: 'mfa_factor',
        targetId: 'factor-sunset-owner-totp',
        payload: const <String, Object?>{'kind': 'totp'},
        businessDate: DateTime.utc(ts.year, ts.month, ts.day),
      ),
    ],
  };
}

/// Demo members per operator. Reuses the user IDs from the 11A.12
/// Members fixture so the Actions panel target picker can resolve a
/// known user without coupling to the Members gateway directly.
Map<String, List<SupportActionsMember>> kDemoSupportActionsMembersByOperator() {
  return <String, List<SupportActionsMember>>{
    kDemoDinerOperatorId: const <SupportActionsMember>[
      SupportActionsMember(
        userId: 'demo-user-diner-owner',
        email: 'owner@demo-diner.test',
        displayName: 'Dana Owner',
        mfaEnrolled: true,
      ),
      SupportActionsMember(
        userId: 'demo-user-diner-manager',
        email: 'manager@demo-diner.test',
        displayName: 'Mira Manager',
        mfaEnrolled: true,
      ),
      SupportActionsMember(
        userId: 'demo-user-diner-staff-1',
        email: 'cook@demo-diner.test',
        displayName: 'Casey Cook',
        mfaEnrolled: false,
      ),
    ],
    kDemoSunsetOperatorId: const <SupportActionsMember>[
      SupportActionsMember(
        userId: 'demo-user-sunset-owner',
        email: 'owner@sunset-cafe.test',
        displayName: 'Quinn Owner',
        mfaEnrolled: true,
      ),
    ],
  };
}
