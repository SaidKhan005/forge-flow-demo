// Phase 11W.7 / Wave A2 - production audit sink for operator-scoped
// write routes.
//
// The OperatorWriteRouter calls `auditSink.record(...)` after every
// successful write. This implementation writes one row to the
// hash-chained `public.audit_logs` table per call, scoped through
// the tenant pool so RLS confines the write to the calling operator.
//
// The sink swallows audit-write failures (logging them via [onError])
// rather than rethrowing, because the business write has already
// succeeded by the time this is called and we do not want to roll it
// back on a downstream observability failure. Production callers wire
// [onError] to the same JSON log emitter the rest of the proxy uses.

import '../../infrastructure/persistence/postgres/repositories/audit_logs_repository.dart';
import '../../infrastructure/persistence/postgres/tenant_context.dart';
import '../../infrastructure/persistence/postgres/tenant_transaction.dart';
import 'operator_write_contracts.dart';

class ProductionOperatorWriteAuditSink implements OperatorWriteAuditSink {
  ProductionOperatorWriteAuditSink({
    required TenantTransactionWrapper tenantWrapper,
    AuditLogsRepository auditLogsRepository = const AuditLogsRepository(),
    void Function(Object error, StackTrace stackTrace)? onError,
  })  : _tenantWrapper = tenantWrapper,
        _auditLogsRepository = auditLogsRepository,
        _onError = onError;

  final TenantTransactionWrapper _tenantWrapper;
  final AuditLogsRepository _auditLogsRepository;
  final void Function(Object error, StackTrace stackTrace)? _onError;

  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    try {
      final ctx = TenantContext(
        operatorId: operatorId,
        // operators / business_timing_profiles writes do not require a
        // specific location_id at the audit-log layer; the sentinel
        // satisfies SET LOCAL without narrowing the row down to a
        // location the audit row never named.
        locationId: operatorId,
        userId: actorUserId,
      );
      final auditActorKind = _normalizeActorKind(actorKind);
      await _tenantWrapper.runInTenantContext(ctx, (exec) async {
        await _auditLogsRepository.writeRow(
          exec,
          operatorId: operatorId,
          locationId: null,
          occurredAt: occurredAt,
          actorKind: auditActorKind,
          actorUserId: auditActorKind == 'user' ? actorUserId : null,
          actorPrincipalId: auditActorKind == 'service' ? actorUserId : null,
          targetKind: 'operator_write',
          targetId: payload['profile_id'] is String
              ? payload['profile_id'] as String
              : null,
          action: eventKind,
          payload: payload,
        );
      });
    } catch (error, stackTrace) {
      // Audit-log failure must not propagate back to the caller because
      // the business write already committed. The proxy's structured
      // logger receives the failure so on-call sees it.
      _onError?.call(error, stackTrace);
    }
  }

  String _normalizeActorKind(String raw) {
    // The audit_logs CHECK constraint accepts only 'user' or
    // 'service'. Anything else from the JWT (firebase user, demo
    // operator) is treated as a user actor; service-principal tokens
    // already pass actorKind = 'service'.
    return raw == 'service' ? 'service' : 'user';
  }
}
