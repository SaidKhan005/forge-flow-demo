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
// What this file DOES do beyond the raw SELECT:
//
//   * Applicability turn-off (deny model). After loading the connected
//     rows, the source drops any row whose current effective
//     `vendor_applicability` polling winner for that
//     `(operator_id, location_id)` is `enabled = FALSE`. A poll-only
//     vendor is polled BY DEFAULT — it is skipped ONLY when an admin
//     has explicitly turned polling OFF for it at that scope. Empty
//     config (no row at all) or an `enabled = TRUE` winner means the
//     vendor is polled. This is a turn-off, NOT an allow-list. The
//     turn-off set is resolved per distinct `(operator_id,
//     location_id)` through [VendorApplicabilityRepository]
//     `.listCurrentForOperator(settingKind: 'polling', enabledOnly:
//     false)`, which applies the canonical precedence (location >
//     operator > global, latest `effective_from`, `effective_until IS
//     NULL`) on the winner. The skip is strictly scoped: a turn-off at
//     location A never excludes the same vendor at location B or under
//     a different operator. Webhook (non-poll-only) vendors are
//     unaffected here — they are not polled on cadence anyway.
//
// What this file deliberately does NOT do:
//
//   * Filter by polling cadence — that lives in
//     `IntegrationSyncWorkerDispatch._resolveCadenceForRow` (Lane
//     `.0a`) and the scheduler-side cadence picker (Lane `.3`). The
//     source returns every connected row (minus applicability
//     turn-offs); cadence-based skipping happens at dispatch time so
//     the resolver's `tier_assignment_*` audit log rows still surface.
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
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/vendor_applicability_repository.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/settings/applicability_metadata_schemas.dart';

import 'dispatch.dart';
import 'main.dart';

/// Concrete [SyncWorkerSource] backed by `public.connector_connection`
/// joined against `public.connector_sync_watermark`. Production wires
/// this; tests inject the in-memory list-based source from
/// `dispatch_test.dart`.
class PostgresSyncWorkerSource extends OperatorScopedRepository
    implements SyncWorkerSource {
  PostgresSyncWorkerSource({required TenantTransactionWrapper tenantWrapper})
      : _vendorApplicabilityRepository =
            VendorApplicabilityRepository(tenantWrapper),
        super(tenantWrapper);

  /// Reuses the existing repository (no new DB pool) to resolve the
  /// per-(operator, location) polling turn-off set. Built off the SAME
  /// [TenantTransactionWrapper] the source enumerates connections with,
  /// so RLS / `SET LOCAL` discipline matches. The repository's
  /// `listCurrentForOperator` runs `withTenant`, which scopes the read
  /// to the asked operator + location.
  final VendorApplicabilityRepository _vendorApplicabilityRepository;

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
    // Claim discipline (W5-LB3): the SELECT runs inside the
    // [runAsSystem] tx and locks each `connector_connection` row with
    // `FOR UPDATE SKIP LOCKED OF cc` so two concurrent worker replicas
    // never enumerate the same connection in the same tick. The
    // left-joined watermark row is intentionally NOT locked (`OF cc`
    // limits the lock to the parent table) — watermark writes go
    // through `IntegrationSyncCanonicalSink.advanceWatermark` in
    // separate per-row transactions and must not contend with the
    // claim.
    //
    // The lock is held for the duration of `withSystem`'s tx, which
    // wraps the SELECT + row materialisation. Workers that race the
    // SELECT see disjoint partitions of the connected set; the second
    // worker's SELECT skips any rows the first has already claimed.
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
          'order by cc.operator_id, cc.location_id, cc.vendor_id '
          'for update of cc skip locked',
        );
        return <ConnectorConnectionRow>[
          for (final row in query) _rowFromPostgres(row),
        ];
      },
      reason: 'integration_sync_worker.list_connected_connections',
    );

    // Applicability turn-off (deny model). Resolve the set of vendors
    // an admin turned OFF for polling, scoped per distinct
    // (operator_id, location_id) present in the connected rows, then
    // drop matching rows. Default is poll-on: a vendor with no row or
    // an enabled=true winner is never in this set. Computed AFTER the
    // claim SELECT commits so the per-(operator, location) tenant reads
    // do not contend with the `FOR UPDATE` lock above.
    final turnedOff = await _resolvePollingTurnedOffVendors(rows);

    for (final row in rows) {
      if (turnedOff.contains(
        _scopedVendorKey(row.operatorId, row.locationId, row.vendorId),
      )) {
        // Admin turned polling OFF for this vendor at this exact
        // (operator, location). Skip it; the dispatcher never sees it.
        continue;
      }
      yield row;
    }
  }

  /// Builds the turned-off set as `operator_id|location_id|vendor_id`
  /// keys. For each distinct (operator_id, location_id) among [rows],
  /// reads the current effective `vendor_applicability` polling winners
  /// (`enabledOnly: false`, so disabled winners are returned) and keeps
  /// the ones whose winner is `enabled == false`. The repository
  /// applies the canonical precedence (location > operator > global,
  /// latest effective_from, effective_until IS NULL) before the
  /// enabled check, so a more-specific enabled=false winner suppresses
  /// the vendor and a more-specific enabled=true winner re-enables it.
  ///
  /// Keying every entry by its source (operator_id, location_id) is
  /// what keeps the skip strictly scoped: a turn-off resolved for
  /// location A is stored under A's key only and can never match a row
  /// at location B or under another operator.
  Future<Set<String>> _resolvePollingTurnedOffVendors(
    List<ConnectorConnectionRow> rows,
  ) async {
    final scopes = <String, _OperatorLocationScope>{};
    for (final row in rows) {
      final key = _operatorLocationKey(row.operatorId, row.locationId);
      scopes.putIfAbsent(
        key,
        () => _OperatorLocationScope(row.operatorId, row.locationId),
      );
    }
    if (scopes.isEmpty) return const <String>{};

    final turnedOff = <String>{};
    for (final scope in scopes.values) {
      final winners = await _vendorApplicabilityRepository
          .listCurrentForOperator(
        operatorId: scope.operatorId,
        locationId: scope.locationId,
        actorUserId: kSyncWorkerServicePrincipalId,
        settingKind: VendorApplicabilitySettingKind.polling,
        enabledOnly: false,
      );
      for (final winner in winners) {
        if (!winner.enabled) {
          turnedOff.add(
            _scopedVendorKey(
              scope.operatorId,
              scope.locationId,
              winner.vendorSlug,
            ),
          );
        }
      }
    }
    return turnedOff;
  }

  static String _operatorLocationKey(String operatorId, String locationId) =>
      '$operatorId|$locationId';

  static String _scopedVendorKey(
    String operatorId,
    String locationId,
    String vendorId,
  ) =>
      '$operatorId|$locationId|$vendorId';

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

/// One distinct `(operator_id, location_id)` the polling turn-off set
/// is resolved for. The map key dedupes scopes so the per-scope tenant
/// read in [PostgresSyncWorkerSource._resolvePollingTurnedOffVendors]
/// runs once per (operator, location), not once per connected row.
class _OperatorLocationScope {
  const _OperatorLocationScope(this.operatorId, this.locationId);

  final String operatorId;
  final String locationId;
}
