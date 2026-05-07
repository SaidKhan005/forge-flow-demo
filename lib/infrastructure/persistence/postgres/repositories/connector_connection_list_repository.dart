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
      'connection_id::text as connection_id, '
      'vendor_id, '
      'category, '
      'status, '
      'module, '
      'metadata, '
      'last_sync_at, '
      'last_error_at, '
      'last_error_message, '
      'disconnect_reason, '
      'webhook_url_provisioned, '
      'created_at, '
      'updated_at';

  /// Returns every connector_connection row scoped to
  /// (operatorId, locationId), regardless of status. The
  /// operator-web Connections screen renders disconnected /
  /// errored vendors so the operator can reconnect or read the
  /// error message — filtering to connected-only would hide
  /// recoverable state.
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
        'from public.connector_connection '
        'where operator_id = @operator_id::uuid '
        '  and location_id = @location_id::uuid '
        "order by category asc, vendor_id asc, coalesce(module, '') asc",
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
    );
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
