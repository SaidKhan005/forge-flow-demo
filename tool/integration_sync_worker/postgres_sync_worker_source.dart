// Phase 8 Wave B `8.spine-bridge.0` — Postgres-backed [SyncWorkerSource].
//
// Production [SyncWorkerSource] implementation: every recurring poll
// tick reads `public.connector_connection` rows whose `status =
// 'connected'` and joins each one against its
// `public.connector_sync_watermark` row so the dispatcher can pass a
// real `last_modified_seen` cursor into [PollIncrementalCommand].
//
// The recurring sync MUST process every operator's connections, not
// just one. We use [TenantTransactionWrapper.runAsSystem] (the
// `runAsSystem` cross-tenant escape hatch in the
// `OperatorScopedRepository` base) because the worker iterates across
// all tenants by definition. Same shape as the OAuth refresh worker
// and the first-connect backfill worker scope reader: enumeration is
// the cross-tenant seam, per-row dispatch stays scoped via the
// vendor-side broker / sink under the dispatcher's hood.
//
// What this file deliberately does NOT do:
//
//   * Filter by polling cadence — that lives in
//     `IntegrationSyncWorkerDispatch._resolveCadenceForRow` (Lane
//     `.0a`) and the scheduler-side cadence picker (Lane `.3`). The
//     source returns every connected row; cadence-based skipping
//     happens at dispatch time so the resolver's `tier_assignment_*`
//     audit log rows still surface.
//   * Order by anything but `(operator_id, location_id, vendor_id)` —
//     ordering is stable for reproducible Cloud Run logs but does not
//     attempt fairness across operators.
//
// CLAUDE.md alignment:
//
//   * HP #1 (transport-only). The source reads `connector_connection`
//     and `connector_sync_watermark` only — both Phase 8 framework
//     tables — and writes nothing.
//   * HP #4 (per-operator isolation). Cross-tenant SELECT runs through
//     `runAsSystem` with a non-blank reason string for audit
//     attribution; the per-row dispatch path the caller drives stays
//     tenant-scoped via the broker / canonical sink.

import 'package:forge_and_flow/infrastructure/persistence/postgres/operator_scoped_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import 'dispatch.dart';
import 'main.dart';

/// Concrete [SyncWorkerSource] backed by `public.connector_connection`
/// joined against `public.connector_sync_watermark`. Production wires
/// this; tests inject the in-memory list-based source from
/// `dispatch_test.dart`.
class PostgresSyncWorkerSource extends OperatorScopedRepository
    implements SyncWorkerSource {
  PostgresSyncWorkerSource({required TenantTransactionWrapper tenantWrapper})
      : super(tenantWrapper);

  /// Sentinel cursor passed when the watermark row is absent (first
  /// poll for this connection — backfill worker has not landed yet).
  /// `IntegrationSyncWorkerDispatch.dispatchPollTick` then forwards
  /// epoch as `lastModifiedSeen`, which the adapter interprets as
  /// "fetch from the beginning of the vendor's available history". The
  /// backfill worker's cursor write later supersedes this on the next
  /// tick.
  static final DateTime _epochSentinel = DateTime.utc(1970);

  @override
  Stream<ConnectorConnectionRow> connectedConnections() async* {
    final rows = await withSystem<List<ConnectorConnectionRow>>(
      (exec) async {
        final query = await exec.query(
          'select '
          '  cc.connection_id::text as connection_id, '
          '  cc.operator_id::text as operator_id, '
          '  cc.location_id::text as location_id, '
          '  cc.vendor_id, '
          '  cc.category, '
          '  cc.status, '
          '  csw.last_modified_seen, '
          '  csw.cursor_token '
          'from public.connector_connection cc '
          'left join public.connector_sync_watermark csw '
          '  on csw.connection_id = cc.connection_id '
          "where cc.status = 'connected' "
          'order by cc.operator_id, cc.location_id, cc.vendor_id',
        );
        return <ConnectorConnectionRow>[
          for (final row in query) _rowFromPostgres(row),
        ];
      },
      reason: 'integration_sync_worker.list_connected_connections',
    );
    for (final row in rows) {
      yield row;
    }
  }

  static ConnectorConnectionRow _rowFromPostgres(Map<String, Object?> row) {
    final lastModifiedSeen = row['last_modified_seen'];
    final DateTime parsedLastModified;
    if (lastModifiedSeen is DateTime) {
      parsedLastModified = lastModifiedSeen.toUtc();
    } else if (lastModifiedSeen is String && lastModifiedSeen.isNotEmpty) {
      parsedLastModified =
          DateTime.tryParse(lastModifiedSeen)?.toUtc() ?? _epochSentinel;
    } else {
      parsedLastModified = _epochSentinel;
    }
    final cursorTokenRaw = row['cursor_token'];
    final cursorToken = cursorTokenRaw is String && cursorTokenRaw.isNotEmpty
        ? cursorTokenRaw
        : null;
    return ConnectorConnectionRow(
      connectionId: (row['connection_id']! as String).trim(),
      operatorId: (row['operator_id']! as String).trim(),
      locationId: (row['location_id']! as String).trim(),
      vendorId: (row['vendor_id']! as String).trim(),
      category: _categoryFromWire(row['category']),
      status: ConnectionStatus.connected,
      lastModifiedSeen: parsedLastModified,
      cursorToken: cursorToken,
    );
  }

  static IntegrationCategory _categoryFromWire(Object? raw) {
    if (raw is String) {
      switch (raw) {
        case 'pos':
          return IntegrationCategory.pos;
        case 'labor':
          return IntegrationCategory.labor;
        case 'reservation':
          return IntegrationCategory.reservation;
      }
    }
    // Defensive default. The CHECK constraint on
    // `connector_connection.category` already restricts to
    // `(pos, labor, reservation)`, so a row with anything else means
    // the migration was bypassed; we surface this as POS to keep the
    // dispatcher path live and let `_isVendorRegistered` flip the row
    // to `vendor_not_registered` cleanly.
    return IntegrationCategory.pos;
  }
}
