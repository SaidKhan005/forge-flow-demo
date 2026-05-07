// Phase 8 — Read-only projection of `public.connector_connection` for
// the operator-self-service Connections screen.
//
// Sits alongside [RepositoryIntegrationRoutesGateway.listForLocation]
// (which is the admin-permission-gated path used by the F&F Ops
// Console). The operator-web client hits
// `GET /v1/auth/locations/{location_id}/integrations`, which already
// validates the operator's own integration permissions at the route
// layer — so this repository skips the admin permission guard and
// just runs the read inside the operator's tenant transaction.
//
// Hard-Promise alignment (CLAUDE.md Authority Order):
//
//   * HP #4 (per-operator isolation). Every read runs through
//     `OperatorScopedRepository.withTenant`; the wrapper issues
//     `set_config('app.operator_id', ...)` / `app.location_id` so RLS
//     is the backup defense.
//
// Returns a typed value object instead of a raw Map so the proxy
// route adapter can shape the wire JSON without inheriting the SQL
// row keys verbatim.

import '../../../../services/integration/integration_adapter_common.dart';
import '../operator_scoped_repository.dart';
import '../tenant_context.dart';

/// First 60-day history-pull lifecycle, mirroring
/// `connector_backfill_jobs.status` plus the operationally distinct
/// "dead-lettered" state the worker tier surfaces once attempts are
/// exhausted. Schema today admits only the first four; `deadLettered`
/// is reserved so the read seam can absorb the worker-tier exhaustion
/// state without another model edit.
enum FirstBackfillStatus { pending, running, succeeded, failed, deadLettered }

extension FirstBackfillStatusWire on FirstBackfillStatus {
  String get wire {
    switch (this) {
      case FirstBackfillStatus.pending:
        return 'pending';
      case FirstBackfillStatus.running:
        return 'running';
      case FirstBackfillStatus.succeeded:
        return 'succeeded';
      case FirstBackfillStatus.failed:
        return 'failed';
      case FirstBackfillStatus.deadLettered:
        return 'dead_lettered';
    }
  }

  static FirstBackfillStatus? tryFromWire(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim().toLowerCase();
    switch (trimmed) {
      case 'pending':
        return FirstBackfillStatus.pending;
      case 'running':
        return FirstBackfillStatus.running;
      case 'succeeded':
        return FirstBackfillStatus.succeeded;
      case 'failed':
        return FirstBackfillStatus.failed;
      case 'dead_lettered':
      case 'deadlettered':
        return FirstBackfillStatus.deadLettered;
      default:
        return null;
    }
  }
}

/// One row from `public.connector_connection`, projected for the
/// operator-self-service Connections screen.
class ConnectorConnectionListRow {
  const ConnectorConnectionListRow({
    required this.connectionId,
    required this.vendorId,
    required this.category,
    required this.status,
    required this.metadata,
    this.module,
    this.lastSyncAt,
    this.lastErrorAt,
    this.lastErrorMessage,
    this.disconnectReason,
    this.webhookUrlProvisioned = false,
    this.createdAt,
    this.updatedAt,
    this.firstBackfillStatus,
    this.firstBackfillStartedAt,
    this.firstBackfillCompletedAt,
    this.firstBackfillFailureReason,
    this.firstBackfillProcessedDays,
    this.firstBackfillTotalDays,
  });

  /// Stable `connector_connection.connection_id` UUID, lowercase text.
  final String connectionId;

  /// `connector_connection.vendor_id` (e.g. `'toast'`, `'square'`).
  final String vendorId;

  /// POS / labor / reservation, mirroring `connector_connection.category`.
  final IntegrationCategory category;

  /// `connector_connection.status`: `'connected'` / `'disconnected'` / `'error'`.
  final String status;

  /// `connector_connection.metadata` JSONB, decoded into a Dart map.
  final Map<String, Object?> metadata;

  /// Optional vendor-specific module key (e.g. `'workforce_now'`).
  final String? module;

  /// Last successful sync timestamp; null when no sync has run.
  final DateTime? lastSyncAt;

  /// Last error timestamp; null when no error has been recorded.
  final DateTime? lastErrorAt;

  /// Last error message; null when no error has been recorded.
  final String? lastErrorMessage;

  /// `connector_connection.disconnect_reason`; null while connected.
  final String? disconnectReason;

  /// True iff the framework provisioned a webhook URL for this row.
  final bool webhookUrlProvisioned;

  /// Row insertion time.
  final DateTime? createdAt;

  /// Row last-touched time (status flip, metadata change, etc.).
  final DateTime? updatedAt;

  /// Latest `connector_backfill_jobs.status` for this
  /// (operator, location, vendor). `null` when no job row exists —
  /// the connection predates the backfill queue.
  final FirstBackfillStatus? firstBackfillStatus;

  /// `connector_backfill_jobs.claimed_at` when status entered
  /// `running`. `null` while still pending.
  final DateTime? firstBackfillStartedAt;

  /// `connector_backfill_jobs.completed_at` when the backfill ended
  /// (succeeded or failed). `null` while still in flight.
  final DateTime? firstBackfillCompletedAt;

  /// `connector_backfill_jobs.last_error` reason. Surfaced verbatim
  /// to the operator as the "what to fix" line.
  final String? firstBackfillFailureReason;

  /// Optional progress hint — number of business days the worker has
  /// already pulled. The schema today has no per-day column, so this
  /// stays `null` and the UI falls back to indeterminate progress.
  /// Reserved for the worker-tier progress upgrade.
  final int? firstBackfillProcessedDays;

  /// Optional progress hint — total business days in the window
  /// (typically 60). Pairs with [firstBackfillProcessedDays]; both
  /// must be non-null for the UI to render determinate progress.
  final int? firstBackfillTotalDays;
}

/// Bundle returned by [ConnectorConnectionListRepository.listForLocation].
class ConnectorConnectionListBundle {
  const ConnectorConnectionListBundle({
    required this.operatorId,
    required this.locationId,
    required this.rows,
  });

  final String operatorId;
  final String locationId;
  final List<ConnectorConnectionListRow> rows;

  /// True iff no connected row exists for [category]. The operator-web
  /// Connections screen uses this to decide whether the demo bundle
  /// picker is still active for that category.
  bool noConnectedRowForCategory(IntegrationCategory category) {
    for (final row in rows) {
      if (row.category == category && row.status == 'connected') return false;
    }
    return true;
  }
}

/// Read-only projection over `public.connector_connection`. Used by
/// the operator-self-service Connections route only — admin-side
/// reads continue to flow through
/// [RepositoryIntegrationRoutesGateway.listForLocation], which gates
/// on `integrations.configure`.
class ConnectorConnectionListRepository extends OperatorScopedRepository {
  ConnectorConnectionListRepository(super.tenantWrapper);

  static const String _selectColumns =
      'cc.connection_id::text as connection_id, '
      'cc.vendor_id, '
      'cc.category, '
      'cc.status, '
      'cc.module, '
      'cc.metadata, '
      'cc.last_sync_at, '
      'cc.last_error_at, '
      'cc.last_error_message, '
      'cc.disconnect_reason, '
      'cc.webhook_url_provisioned, '
      'cc.created_at, '
      'cc.updated_at, '
      'fbj.status as first_backfill_status, '
      'fbj.claimed_at as first_backfill_started_at, '
      'fbj.completed_at as first_backfill_completed_at, '
      'fbj.last_error as first_backfill_failure_reason';

  /// Returns every connector_connection row scoped to
  /// (operatorId, locationId), regardless of status. The
  /// operator-web Connections screen renders disconnected /
  /// errored vendors so the operator can reconnect or read the
  /// error message — filtering to connected-only would hide
  /// recoverable state.
  ///
  /// LEFT JOIN to `connector_backfill_jobs` pulls the most recent
  /// job row per (operator, location, vendor) so the operator-web
  /// UI can render the "60-day history" progress indicator alongside
  /// the connection status. The schema does not track per-day
  /// progress today; `processed_days` / `total_days` stay null and
  /// the UI falls back to an indeterminate indicator.
  Future<ConnectorConnectionListBundle> listForLocation({
    required String operatorId,
    required String locationId,
    String? actorUserId,
  }) {
    _requireNonBlank('operatorId', operatorId);
    _requireNonBlank('locationId', locationId);
    final ctx = TenantContext(
      operatorId: operatorId,
      locationId: locationId,
      userId: actorUserId,
    );
    return withTenant<ConnectorConnectionListBundle>(ctx, (exec) async {
      final rows = await exec.query(
        'select $_selectColumns '
        'from public.connector_connection cc '
        'left join lateral ('
        '  select status, claimed_at, completed_at, last_error '
        '  from public.connector_backfill_jobs j '
        '  where j.operator_id = cc.operator_id '
        '    and j.location_id = cc.location_id '
        '    and j.vendor_id = cc.vendor_id '
        '  order by j.updated_at desc '
        '  limit 1'
        ') fbj on true '
        'where cc.operator_id = @operator_id::uuid '
        '  and cc.location_id = @location_id::uuid '
        "order by cc.category asc, cc.vendor_id asc, "
        "         coalesce(cc.module, '') asc",
        parameters: <String, Object?>{
          'operator_id': operatorId,
          'location_id': locationId,
        },
      );
      return ConnectorConnectionListBundle(
        operatorId: operatorId,
        locationId: locationId,
        rows: rows
            .map(_rowFromPostgres)
            .toList(growable: false),
      );
    });
  }

  static ConnectorConnectionListRow _rowFromPostgres(
    Map<String, Object?> row,
  ) {
    return ConnectorConnectionListRow(
      connectionId: _readString(row['connection_id']) ?? '',
      vendorId: _readString(row['vendor_id']) ?? '',
      category: _categoryFromWire(_readString(row['category'])),
      status: _readString(row['status']) ?? 'disconnected',
      metadata: _coerceMetadata(row['metadata']),
      module: _readString(row['module']),
      lastSyncAt: _readDate(row['last_sync_at']),
      lastErrorAt: _readDate(row['last_error_at']),
      lastErrorMessage: _readString(row['last_error_message']),
      disconnectReason: _readString(row['disconnect_reason']),
      webhookUrlProvisioned: row['webhook_url_provisioned'] == true,
      createdAt: _readDate(row['created_at']),
      updatedAt: _readDate(row['updated_at']),
      firstBackfillStatus: FirstBackfillStatusWire.tryFromWire(
        _readString(row['first_backfill_status']),
      ),
      firstBackfillStartedAt: _readDate(row['first_backfill_started_at']),
      firstBackfillCompletedAt: _readDate(row['first_backfill_completed_at']),
      firstBackfillFailureReason: _readString(
        row['first_backfill_failure_reason'],
      ),
      firstBackfillProcessedDays: _readInt(row['first_backfill_processed_days']),
      firstBackfillTotalDays: _readInt(row['first_backfill_total_days']),
    );
  }

  static int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static IntegrationCategory _categoryFromWire(String? raw) {
    switch (raw) {
      case 'labor':
        return IntegrationCategory.labor;
      case 'reservation':
        return IntegrationCategory.reservation;
      case 'pos':
      default:
        return IntegrationCategory.pos;
    }
  }

  static String? _readString(Object? value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }

  static DateTime? _readDate(Object? value) {
    if (value is DateTime) return value.toUtc();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      return DateTime.tryParse(trimmed)?.toUtc();
    }
    return null;
  }

  static Map<String, Object?> _coerceMetadata(Object? value) {
    if (value is Map<Object?, Object?>) {
      final result = <String, Object?>{};
      value.forEach((key, v) {
        if (key is String) result[key] = v;
      });
      return Map<String, Object?>.unmodifiable(result);
    }
    return const <String, Object?>{};
  }

  void _requireNonBlank(String name, String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, name, 'must be non-blank');
    }
  }
}
