// Lane C C-2-D — VendorSyncOutageStateRepository (Postgres impl).
//
// Persistence layer for `public.vendor_sync_outage_state` plus the
// `connector_sync_log` reader the detector uses to compute the
// consecutive-failure streak.
//
// Authority:
//   * db/migrations/202605131900_c_2_d_vendor_sync_outage_state.sql
//     (table + RLS policy + indexes).
//   * docs/contracts/hardening_rls_and_repository_pattern_contract.md
//     (every operator-scoped table goes through
//     `OperatorScopedRepository`; no raw `package:postgres` import
//     outside this directory).
//   * lib/services/vendor_sync/vendor_sync_outage_detector.dart
//     (the abstract seam this class binds).
//
// Methods:
//   * fetchRecentSyncLogEntries — Read newest-first connector_sync_log
//                                 rows for one connection, bounded by
//                                 the detector's lookback window.
//   * fetchForConnection       — Look up the current state row.
//   * upsert                   — INSERT ... ON CONFLICT ... DO UPDATE
//                                 the per-connection state row.
//   * clearForConnection       — DELETE the state row when an outage
//                                 recovers.

import '../operator_scoped_repository.dart';
import '../tenant_context.dart';
import '../../../../services/vendor_sync/vendor_sync_outage_detector.dart';

/// Postgres-backed implementation of [VendorSyncOutageStateRepository]
/// for the production polling tier.
class PostgresVendorSyncOutageStateRepository
    extends OperatorScopedRepository
    implements VendorSyncOutageStateRepository {
  PostgresVendorSyncOutageStateRepository(super.tenantWrapper);

  @override
  Future<List<SyncLogEntry>> fetchRecentSyncLogEntries({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required Duration lookback,
    required int limit,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return withTenant<List<SyncLogEntry>>(ctx, (exec) async {
      // The lookback bound is applied server-side via interval
      // arithmetic so the read uses the operator-leading partial
      // index `connector_sync_log_connection_recent_idx`
      // (connection_id, occurred_at DESC).
      final rows = await exec.query(
        'select event_kind, error_message, occurred_at '
        'from public.connector_sync_log '
        'where operator_id = @operator_id::uuid '
        'and connection_id = @connection_id::uuid '
        "and occurred_at >= now() - (@lookback_seconds || ' seconds')::interval "
        'order by occurred_at desc '
        'limit @limit',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'connection_id': connectionId,
          'lookback_seconds': lookback.inSeconds,
          'limit': limit,
        },
      );
      return rows
          .map((row) {
            final eventKind = row['event_kind'];
            final occurredAt = row['occurred_at'];
            if (eventKind is! String || occurredAt is! DateTime) {
              throw StateError(
                'connector_sync_log row had an unexpected shape: $row',
              );
            }
            final rawError = row['error_message'];
            return SyncLogEntry(
              eventKind: eventKind,
              occurredAt: occurredAt,
              errorMessage: rawError is String ? rawError : null,
            );
          })
          .toList(growable: false);
    });
  }

  @override
  Future<VendorSyncOutageStateRow?> fetchForConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return withTenant<VendorSyncOutageStateRow?>(ctx, (exec) async {
      final rows = await exec.query(
        'select outage_started_at, consecutive_failure_count, '
        'notified_at, last_error_message '
        'from public.vendor_sync_outage_state '
        'where operator_id = @operator_id::uuid '
        'and connection_id = @connection_id::uuid',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'connection_id': connectionId,
        },
      );
      if (rows.isEmpty) return null;
      final row = rows.single;
      final outageStartedAt = row['outage_started_at'];
      final consecutiveFailureCount = row['consecutive_failure_count'];
      if (outageStartedAt is! DateTime ||
          consecutiveFailureCount is! int) {
        throw StateError(
          'vendor_sync_outage_state row had an unexpected shape: $row',
        );
      }
      final notifiedAt = row['notified_at'];
      final lastErrorMessage = row['last_error_message'];
      return VendorSyncOutageStateRow(
        outageStartedAt: outageStartedAt,
        consecutiveFailureCount: consecutiveFailureCount,
        notifiedAt: notifiedAt is DateTime ? notifiedAt : null,
        lastErrorMessage:
            lastErrorMessage is String ? lastErrorMessage : null,
      );
    });
  }

  @override
  Future<void> upsert({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required DateTime outageStartedAt,
    required int consecutiveFailureCount,
    DateTime? notifiedAt,
    String? lastErrorMessage,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'insert into public.vendor_sync_outage_state ('
        'operator_id, location_id, connection_id, '
        'outage_started_at, consecutive_failure_count, '
        'notified_at, last_error_message, updated_at'
        ') values ('
        '@operator_id::uuid, @location_id::uuid, @connection_id::uuid, '
        '@outage_started_at::timestamptz, @consecutive_failure_count, '
        '@notified_at::timestamptz, @last_error_message, now()'
        ') on conflict (connection_id) do update set '
        // outage_started_at stays sticky for the lifetime of the
        // current outage — the detector always re-supplies the
        // oldest-failure-in-streak timestamp, so this UPDATE is
        // idempotent within a single outage window.
        'outage_started_at = excluded.outage_started_at, '
        'consecutive_failure_count = excluded.consecutive_failure_count, '
        // notified_at only flips NULL → non-null. Once stamped, a
        // subsequent UPSERT inside the same outage window keeps the
        // original stamp via COALESCE.
        'notified_at = coalesce('
        '  public.vendor_sync_outage_state.notified_at, '
        '  excluded.notified_at), '
        'last_error_message = excluded.last_error_message, '
        'updated_at = now()',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
          'connection_id': connectionId,
          'outage_started_at': outageStartedAt.toUtc(),
          'consecutive_failure_count': consecutiveFailureCount,
          'notified_at': notifiedAt?.toUtc(),
          'last_error_message': lastErrorMessage,
        },
      );
    });
  }

  @override
  Future<void> clearForConnection({
    required String operatorId,
    required String locationId,
    required String connectionId,
  }) {
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: null,
    );
    return withTenant<void>(ctx, (exec) async {
      await exec.execute(
        'delete from public.vendor_sync_outage_state '
        'where operator_id = @operator_id::uuid '
        'and connection_id = @connection_id::uuid',
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'connection_id': connectionId,
        },
      );
    });
  }
}
