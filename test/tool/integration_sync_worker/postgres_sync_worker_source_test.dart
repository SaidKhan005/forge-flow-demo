// Phase 8 Wave B `8.spine-bridge.0` PostgresSyncWorkerSource tests.
//
// Pure-logic coverage of the cross-tenant SELECT projection. The fake
// Postgres executor models the schema's column shape so the source's
// row-mapper / cursor-fallback / category coercion are all exercised
// without touching live Postgres.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';

import '../../../tool/integration_sync_worker/postgres_sync_worker_source.dart';

void main() {
  group('PostgresSyncWorkerSource.connectedConnections', () {
    test(
      'returns one row per connected connection with watermark cursor + '
      'last_modified_seen joined in',
      () async {
        final pool = _FakePool(<Map<String, Object?>>[
          <String, Object?>{
            'connection_id': '11111111-1111-4111-8111-111111111111',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'lightspeed_lsk',
            'category': 'pos',
            'status': 'connected',
            'last_modified_seen': DateTime.utc(2026, 5, 4, 10),
            'cursor_token': 'cursor-pos-1',
          },
          <String, Object?>{
            'connection_id': '44444444-4444-4444-8444-444444444444',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'agendrix',
            'category': 'labor',
            'status': 'connected',
            'last_modified_seen': null,
            'cursor_token': null,
          },
        ]);
        final wrapper = TenantTransactionWrapper(pool);
        final source = PostgresSyncWorkerSource(tenantWrapper: wrapper);

        final rows =
            await source.connectedConnections().toList();

        expect(rows, hasLength(2));
        expect(rows[0].vendorId, 'lightspeed_lsk');
        expect(rows[0].category, IntegrationCategory.pos);
        expect(rows[0].cursorToken, 'cursor-pos-1');
        expect(
          rows[0].lastModifiedSeen,
          DateTime.utc(2026, 5, 4, 10),
        );
        expect(rows[1].vendorId, 'agendrix');
        expect(rows[1].category, IntegrationCategory.labor);
        expect(
          rows[1].cursorToken,
          isNull,
          reason: 'null cursor_token must surface as null, not empty string',
        );
        expect(
          rows[1].lastModifiedSeen,
          DateTime.utc(1970),
          reason:
              'missing last_modified_seen falls back to the epoch sentinel '
              'so the dispatcher passes a deterministic floor cursor',
        );

        // The cross-tenant claim scan opens the first transaction; the
        // applicability turn-off read then opens exactly one more tenant
        // transaction (both connected rows share the same operator +
        // location, so the per-(operator, location) read dedupes to one).
        expect(
          pool.transactions, hasLength(2),
          reason:
              'cross-tenant claim scan (1) plus one per-(operator, location) '
              'applicability turn-off read (1)',
        );
        expect(
          pool.transactions.first.executedStatements,
          contains(predicate<String>(
              (s) => s.contains("set_config('app.bypass_rls_audit'"),
              'is system-context audit marker')),
          reason: 'the claim scan runs under runAsSystem',
        );
        // The applicability read is tenant-scoped: it issues the
        // operator/location SET LOCAL probes, not the system bypass.
        expect(
          pool.transactions.last.executedStatements,
          contains(predicate<String>(
              (s) => s.contains("set_config('app.operator_id'"),
              'is tenant-context operator marker')),
          reason: 'the applicability turn-off read runs under withTenant',
        );
      },
    );

    test(
      'WHERE clause filters status=connected (the SELECT only emits rows '
      'whose status is "connected")',
      () async {
        // The query the source issues includes
        // `where cc.status = 'connected'` so a fake pool that returns
        // mixed-status rows would only ever be exercised through the
        // SELECT — the SQL itself is what filters. We assert the query
        // text carries the literal so a future refactor that drops the
        // filter is caught by the lint here.
        final pool = _FakePool(const <Map<String, Object?>>[]);
        final wrapper = TenantTransactionWrapper(pool);
        final source = PostgresSyncWorkerSource(tenantWrapper: wrapper);

        await source.connectedConnections().toList();

        expect(
          pool.transactions.single.queriedStatements.single,
          contains("cc.status = 'connected'"),
        );
      },
    );

    test(
      'CODE_HEALTH W5-LB3: claim discipline — SELECT carries '
      '`for update of cc skip locked` so two concurrent worker replicas '
      'never enumerate the same connection in the same tick',
      () async {
        final pool = _FakePool(const <Map<String, Object?>>[]);
        final wrapper = TenantTransactionWrapper(pool);
        final source = PostgresSyncWorkerSource(tenantWrapper: wrapper);

        await source.connectedConnections().toList();

        final query = pool.transactions.single.queriedStatements.single;
        expect(
          query.toLowerCase(),
          contains('for update of cc skip locked'),
          reason:
              'claim discipline: SELECT must lock the connector_connection '
              'rows it returns so concurrent worker replicas partition the '
              'work via `SKIP LOCKED` instead of double-claiming',
        );
        // Lock scope is `OF cc` (not the joined watermark table) so the
        // canonical sink can update `connector_sync_watermark` in
        // separate per-row transactions without contending with the
        // claim.
        expect(
          query.toLowerCase(),
          isNot(contains('for update skip locked')),
          reason:
              'lock scope must be limited to `OF cc` to keep the watermark '
              'table available to per-row writes from the sink',
        );
      },
    );

    test(
      'CODE_HEALTH W5-LB3: claim discipline — concurrent SELECTs partition '
      'rows; the second worker sees the rows the first one skipped',
      () async {
        // Two concurrent fake pools backed by a shared row pool that
        // reserves rows via `FOR UPDATE SKIP LOCKED`. The first SELECT
        // claims its rows; the second SELECT (running before the first
        // commits) sees the remaining rows only.
        final shared = _SharedRowPool(<Map<String, Object?>>[
          <String, Object?>{
            'connection_id': '11111111-1111-4111-8111-111111111111',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'lightspeed_lsk',
            'category': 'pos',
            'status': 'connected',
            'last_modified_seen': null,
            'cursor_token': null,
          },
          <String, Object?>{
            'connection_id': '44444444-4444-4444-8444-444444444444',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'agendrix',
            'category': 'labor',
            'status': 'connected',
            'last_modified_seen': null,
            'cursor_token': null,
          },
        ]);
        final wrapperA =
            TenantTransactionWrapper(_LockingFakePool(shared, sliceAt: 1));
        final wrapperB =
            TenantTransactionWrapper(_LockingFakePool(shared, sliceAt: 1));
        final sourceA = PostgresSyncWorkerSource(tenantWrapper: wrapperA);
        final sourceB = PostgresSyncWorkerSource(tenantWrapper: wrapperB);

        // Concurrent: both SELECTs race the shared row pool.
        final resultsA = await sourceA.connectedConnections().toList();
        final resultsB = await sourceB.connectedConnections().toList();

        // Worker A claimed the first row (sliceAt=1). Worker B's
        // subsequent SELECT skipped the locked row and got the second.
        expect(resultsA, hasLength(1));
        expect(resultsA.single.connectionId,
            '11111111-1111-4111-8111-111111111111');
        expect(resultsB, hasLength(1));
        expect(resultsB.single.connectionId,
            '44444444-4444-4444-8444-444444444444');
      },
    );

    test(
      'unknown category coerces defensively to POS (the dispatcher then '
      'flips the row to vendor_not_registered cleanly)',
      () async {
        final pool = _FakePool(<Map<String, Object?>>[
          <String, Object?>{
            'connection_id': '11111111-1111-4111-8111-111111111111',
            'operator_id': '22222222-2222-4222-8222-222222222222',
            'location_id': '33333333-3333-4333-8333-333333333333',
            'vendor_id': 'mystery_vendor',
            'category': 'mystery_category',
            'status': 'connected',
            'last_modified_seen': null,
            'cursor_token': null,
          },
        ]);
        final wrapper = TenantTransactionWrapper(pool);
        final source = PostgresSyncWorkerSource(tenantWrapper: wrapper);

        final rows = await source.connectedConnections().toList();

        expect(rows.single.category, IntegrationCategory.pos);
      },
    );
  });

  group(
    'PostgresSyncWorkerSource.connectedConnections — polling turn-off '
    '(deny model)',
    () {
      const operatorA = '22222222-2222-4222-8222-222222222222';
      const locationA = '33333333-3333-4333-8333-333333333333';
      const locationB = '99999999-9999-4999-8999-999999999999';
      const adminUserId = '11111111-1111-4111-8111-111111111111';

      Map<String, Object?> connectorRow({
        required String connectionId,
        required String vendorId,
        required String category,
        String operatorId = operatorA,
        String locationId = locationA,
      }) {
        return <String, Object?>{
          'connection_id': connectionId,
          'operator_id': operatorId,
          'location_id': locationId,
          'vendor_id': vendorId,
          'category': category,
          'status': 'connected',
          'last_modified_seen': null,
          'cursor_token': null,
        };
      }

      test(
        'a vendor with a current enabled=false polling winner for (op, loc) '
        'is EXCLUDED while siblings are INCLUDED',
        () async {
          final pool = _ApplicabilityFakePool(
            connectorRows: <Map<String, Object?>>[
              connectorRow(
                connectionId: '11111111-1111-4111-8111-111111111111',
                vendorId: 'toast',
                category: 'pos',
              ),
              connectorRow(
                connectionId: '44444444-4444-4444-8444-444444444444',
                vendorId: 'agendrix',
                category: 'labor',
              ),
            ],
            applicabilityRows: <Map<String, Object?>>[
              // Admin turned polling OFF for toast at (operatorA, locationA).
              _vaRow(
                id: 'toast-off',
                operatorId: operatorA,
                locationId: locationA,
                vendorSlug: 'toast',
                enabled: false,
              ),
            ],
          );
          final source = PostgresSyncWorkerSource(
            tenantWrapper: TenantTransactionWrapper(pool),
          );

          final rows = await source.connectedConnections().toList();

          expect(
            rows.map((r) => r.vendorId),
            <String>['agendrix'],
            reason:
                'toast is turned off for this (operator, location); agendrix '
                'has no row and stays polled by default',
          );
        },
      );

      test(
        'a vendor with NO applicability row is INCLUDED (default poll-on)',
        () async {
          final pool = _ApplicabilityFakePool(
            connectorRows: <Map<String, Object?>>[
              connectorRow(
                connectionId: '11111111-1111-4111-8111-111111111111',
                vendorId: 'toast',
                category: 'pos',
              ),
            ],
            applicabilityRows: const <Map<String, Object?>>[],
          );
          final source = PostgresSyncWorkerSource(
            tenantWrapper: TenantTransactionWrapper(pool),
          );

          final rows = await source.connectedConnections().toList();

          expect(rows.map((r) => r.vendorId), <String>['toast']);
        },
      );

      test(
        'a vendor with an enabled=true polling winner is INCLUDED',
        () async {
          final pool = _ApplicabilityFakePool(
            connectorRows: <Map<String, Object?>>[
              connectorRow(
                connectionId: '11111111-1111-4111-8111-111111111111',
                vendorId: 'toast',
                category: 'pos',
              ),
            ],
            applicabilityRows: <Map<String, Object?>>[
              _vaRow(
                id: 'toast-on',
                operatorId: operatorA,
                locationId: locationA,
                vendorSlug: 'toast',
                enabled: true,
              ),
            ],
          );
          final source = PostgresSyncWorkerSource(
            tenantWrapper: TenantTransactionWrapper(pool),
          );

          final rows = await source.connectedConnections().toList();

          expect(rows.map((r) => r.vendorId), <String>['toast']);
        },
      );

      test(
        'a more-specific enabled=true winner overrides a global enabled=false '
        'row (vendor stays polled)',
        () async {
          final now = DateTime.utc(2026, 5, 13, 12);
          final pool = _ApplicabilityFakePool(
            connectorRows: <Map<String, Object?>>[
              connectorRow(
                connectionId: '11111111-1111-4111-8111-111111111111',
                vendorId: 'toast',
                category: 'pos',
              ),
            ],
            applicabilityRows: <Map<String, Object?>>[
              // Global default turns toast OFF...
              _vaRow(
                id: 'global-toast-off',
                operatorId: null,
                vendorSlug: 'toast',
                enabled: false,
                effectiveFrom: now,
              ),
              // ...but this location turns it back ON. Location wins.
              _vaRow(
                id: 'location-toast-on',
                operatorId: operatorA,
                locationId: locationA,
                vendorSlug: 'toast',
                enabled: true,
                effectiveFrom: now.add(const Duration(hours: 1)),
              ),
            ],
          );
          final source = PostgresSyncWorkerSource(
            tenantWrapper: TenantTransactionWrapper(pool),
          );

          final rows = await source.connectedConnections().toList();

          expect(
            rows.map((r) => r.vendorId),
            <String>['toast'],
            reason:
                'location-scoped enabled=true winner beats the global '
                'enabled=false row, so toast is polled',
          );
        },
      );

      test(
        'a turn-off scoped to location A does NOT exclude the same vendor at '
        'location B',
        () async {
          final pool = _ApplicabilityFakePool(
            connectorRows: <Map<String, Object?>>[
              // toast connected at BOTH locations under the same operator.
              connectorRow(
                connectionId: '11111111-1111-4111-8111-111111111111',
                vendorId: 'toast',
                category: 'pos',
                locationId: locationA,
              ),
              connectorRow(
                connectionId: '55555555-5555-4555-8555-555555555555',
                vendorId: 'toast',
                category: 'pos',
                locationId: locationB,
              ),
            ],
            applicabilityRows: <Map<String, Object?>>[
              // Turn-off scoped ONLY to location A.
              _vaRow(
                id: 'toast-off-loc-a',
                operatorId: operatorA,
                locationId: locationA,
                vendorSlug: 'toast',
                enabled: false,
              ),
            ],
          );
          final source = PostgresSyncWorkerSource(
            tenantWrapper: TenantTransactionWrapper(pool),
          );

          final rows = await source.connectedConnections().toList();

          // Location A's toast is dropped; location B's toast survives.
          expect(rows, hasLength(1));
          expect(rows.single.vendorId, 'toast');
          expect(
            rows.single.locationId,
            locationB,
            reason:
                'the location-A turn-off must not bleed into location B; the '
                'skip is keyed by (operator, location, vendor)',
          );
        },
      );

      test(
        'a turn-off under one operator does NOT exclude the same vendor under '
        'another operator',
        () async {
          const operatorB = '88888888-8888-4888-8888-888888888888';
          final pool = _ApplicabilityFakePool(
            connectorRows: <Map<String, Object?>>[
              connectorRow(
                connectionId: '11111111-1111-4111-8111-111111111111',
                vendorId: 'toast',
                category: 'pos',
                operatorId: operatorA,
                locationId: locationA,
              ),
              connectorRow(
                connectionId: '66666666-6666-4666-8666-666666666666',
                vendorId: 'toast',
                category: 'pos',
                operatorId: operatorB,
                locationId: locationA,
              ),
            ],
            applicabilityRows: <Map<String, Object?>>[
              // Turn-off scoped to operatorA only.
              _vaRow(
                id: 'toast-off-op-a',
                operatorId: operatorA,
                locationId: locationA,
                vendorSlug: 'toast',
                enabled: false,
              ),
            ],
          );
          final source = PostgresSyncWorkerSource(
            tenantWrapper: TenantTransactionWrapper(pool),
          );

          final rows = await source.connectedConnections().toList();

          expect(rows, hasLength(1));
          expect(rows.single.operatorId, operatorB);
        },
      );

      test(
        'the applicability read asks for setting_kind=polling with '
        'enabledOnly=false (disabled winners are returned)',
        () async {
          final pool = _ApplicabilityFakePool(
            connectorRows: <Map<String, Object?>>[
              connectorRow(
                connectionId: '11111111-1111-4111-8111-111111111111',
                vendorId: 'toast',
                category: 'pos',
              ),
            ],
            applicabilityRows: const <Map<String, Object?>>[],
          );
          final source = PostgresSyncWorkerSource(
            tenantWrapper: TenantTransactionWrapper(pool),
          );

          await source.connectedConnections().toList();

          final rankedQuery = pool.allQueriedStatements.firstWhere(
            (s) => s.contains('from ranked'),
            orElse: () => '',
          );
          expect(
            rankedQuery,
            isNotEmpty,
            reason: 'the source must run the applicability ranked SELECT',
          );
          // enabledOnly:false → the winner-side filter is bare `rn = 1`,
          // NOT `rn = 1 and enabled = true`. That is what lets a disabled
          // winner surface so the source can drop the vendor.
          expect(rankedQuery, contains('where rn = 1'));
          expect(rankedQuery, isNot(contains('enabled = true')));
          final rankedParams = pool.rankedQueryParameters;
          expect(rankedParams['setting_kind'], 'polling');
          expect(rankedParams['operator_id'], operatorA);
          expect(rankedParams['location_id'], locationA);
        },
      );

      // Marker so the analyzer keeps adminUserId referenced even if the
      // assertions above evolve; the seeded rows are created_by this id.
      test('seed helper stamps the admin user id as created_by', () {
        final row = _vaRow(
          id: 'x',
          operatorId: operatorA,
          locationId: locationA,
          vendorSlug: 'toast',
          enabled: false,
        );
        expect(row['created_by'], adminUserId);
      });
    },
  );
}

/// Builds a seeded `vendor_applicability` row map for
/// [_ApplicabilityFakePool]. Mirrors the shape the repository's
/// `VendorApplicabilityRow.fromRow` consumes. `operatorId == null`
/// models a global default; `locationId == null` models an
/// operator-level (or global) row.
Map<String, Object?> _vaRow({
  required String id,
  required String? operatorId,
  required String vendorSlug,
  required bool enabled,
  String? locationId,
  String settingKind = 'polling',
  String settingKey = 'default',
  DateTime? effectiveFrom,
}) {
  final from = effectiveFrom ?? DateTime.utc(2026, 5, 13, 12);
  return <String, Object?>{
    'id': id,
    'operator_id': operatorId,
    'location_id': locationId,
    'setting_kind': settingKind,
    'setting_key': settingKey,
    'vendor_slug': vendorSlug,
    'enabled': enabled,
    'metadata': '{}',
    'effective_from': from,
    'effective_until': null,
    'created_at': from,
    'created_by': '11111111-1111-4111-8111-111111111111',
  };
}

// ─── Fake Postgres seam ──────────────────────────────────────────────

class _FakePool implements PostgresPool {
  _FakePool(this._rows);

  final List<Map<String, Object?>> _rows;
  final List<_FakeTransaction> transactions = <_FakeTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _FakeTransaction(_rows);
    transactions.add(tx);
    return tx;
  }
}

class _FakeTransaction implements PostgresTransaction {
  _FakeTransaction(this._rows);

  final List<Map<String, Object?>> _rows;
  final List<String> queriedStatements = <String>[];
  final List<String> executedStatements = <String>[];
  bool _committed = false;
  bool _rolledBack = false;

  @override
  Future<List<Map<String, Object?>>> query(
    String statement, {
    Map<String, Object?>? parameters,
  }) async {
    queriedStatements.add(statement);
    // Only the connector-connection claim SELECT returns the seeded
    // connector rows. The applicability turn-off read
    // (`VendorApplicabilityRepository.listCurrentForOperator`, whose
    // ranked SELECT carries `from ranked`) returns no rows here, which
    // is the default poll-on path: no turn-off rows means every
    // connected vendor is polled. Tests that exercise turn-offs use
    // [_ApplicabilityFakePool] instead.
    if (statement.toLowerCase().contains('for update of cc skip locked')) {
      return List<Map<String, Object?>>.unmodifiable(_rows);
    }
    return const <Map<String, Object?>>[];
  }

  @override
  Future<int> execute(
    String statement, {
    Map<String, Object?>? parameters,
  }) async {
    executedStatements.add(statement);
    return 0;
  }

  @override
  Future<void> commit() async {
    _committed = true;
  }

  @override
  Future<void> rollback() async {
    _rolledBack = true;
  }

  // Avoid lint about unused field reads in a future refactor.
  bool get committed => _committed;
  bool get rolledBack => _rolledBack;
}

/// Shared row pool that partitions rows across two concurrent workers
/// the way `FOR UPDATE SKIP LOCKED` partitions across two PG sessions.
/// The first locking SELECT claims the first `sliceAt` rows; the
/// second SELECT skips the claimed slice.
class _SharedRowPool {
  _SharedRowPool(this._rows);

  final List<Map<String, Object?>> _rows;
  int _claimed = 0;

  /// Returns the next slice of unlocked rows and marks them claimed.
  /// `sliceAt` mirrors the `LIMIT N` of a real claim query — first
  /// SELECT takes `sliceAt` rows, second SELECT takes whatever remains.
  List<Map<String, Object?>> takeSlice(int sliceAt) {
    final start = _claimed;
    final end = (start + sliceAt) > _rows.length ? _rows.length : start + sliceAt;
    final slice = _rows.sublist(start, end);
    _claimed = end;
    return slice;
  }
}

class _LockingFakePool implements PostgresPool {
  _LockingFakePool(this._shared, {required this.sliceAt});

  final _SharedRowPool _shared;
  final int sliceAt;

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _LockingFakeTransaction(_shared, sliceAt: sliceAt);
  }
}

class _LockingFakeTransaction implements PostgresTransaction {
  _LockingFakeTransaction(this._shared, {required this.sliceAt});

  final _SharedRowPool _shared;
  final int sliceAt;

  @override
  Future<List<Map<String, Object?>>> query(
    String statement, {
    Map<String, Object?>? parameters,
  }) async {
    // Honor the `FOR UPDATE ... SKIP LOCKED` semantics: the first
    // tx claims the first slice, the second tx skips the claimed
    // rows and sees what's left.
    if (statement.toLowerCase().contains('for update of cc skip locked')) {
      return _shared.takeSlice(sliceAt);
    }
    return const <Map<String, Object?>>[];
  }

  @override
  Future<int> execute(
    String statement, {
    Map<String, Object?>? parameters,
  }) async =>
      0;

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}

// ─── Applicability-aware fake seam ───────────────────────────────────

/// Fake pool that serves BOTH reads the source now issues: the
/// cross-tenant connector claim SELECT and the per-(operator, location)
/// `vendor_applicability` polling ranked SELECT. The connector claim
/// returns [connectorRows]; the ranked SELECT evaluates [applicabilityRows]
/// with the SAME precedence the repository SQL expresses (location >
/// operator > global, latest effective_from), honoring the bound
/// `@operator_id` / `@location_id`, so location/operator scoping is
/// exercised honestly rather than stubbed.
class _ApplicabilityFakePool implements PostgresPool {
  _ApplicabilityFakePool({
    required this.connectorRows,
    required this.applicabilityRows,
  });

  final List<Map<String, Object?>> connectorRows;
  final List<Map<String, Object?>> applicabilityRows;

  /// Aggregated across every transaction this pool hands out, so an
  /// inspection test can find the ranked applicability query + params.
  final List<String> allQueriedStatements = <String>[];
  Map<String, Object?> rankedQueryParameters = const <String, Object?>{};

  @override
  Future<PostgresTransaction> beginTransaction() async {
    return _ApplicabilityFakeTransaction(this);
  }
}

class _ApplicabilityFakeTransaction implements PostgresTransaction {
  _ApplicabilityFakeTransaction(this._pool);

  final _ApplicabilityFakePool _pool;

  @override
  Future<List<Map<String, Object?>>> query(
    String statement, {
    Map<String, Object?>? parameters,
  }) async {
    _pool.allQueriedStatements.add(statement);
    final lower = statement.toLowerCase();
    if (lower.contains('for update of cc skip locked')) {
      return List<Map<String, Object?>>.unmodifiable(_pool.connectorRows);
    }
    if (!statement.contains('from ranked')) {
      return const <Map<String, Object?>>[];
    }
    // Ranked applicability SELECT. Capture params for assertions and
    // evaluate the precedence the repository SQL expresses.
    _pool.rankedQueryParameters = Map<String, Object?>.from(
      parameters ?? const <String, Object?>{},
    );
    final operatorId = parameters?['operator_id'] as String?;
    final locationId = parameters?['location_id'] as String?;
    final settingKind = parameters?['setting_kind'] as String?;
    final settingKey = parameters?['setting_key'] as String?;

    // `visible` CTE: admit global (operator_id null), operator-level
    // (operator match, location null), and location-specific (operator
    // match, location match) current rows; exclude other-location rows.
    final visible = _pool.applicabilityRows.where((row) {
      final rowOperator = row['operator_id'] as String?;
      if (!(rowOperator == null || rowOperator == operatorId)) return false;
      final rowLocation = row['location_id'] as String?;
      if (!(rowLocation == null || rowLocation == locationId)) return false;
      if (settingKind != null && row['setting_kind'] != settingKind) {
        return false;
      }
      if (row['effective_until'] != null) return false;
      if (settingKey != null && row['setting_key'] != settingKey) return false;
      return true;
    }).toList();

    // Partition by (setting_kind, setting_key, vendor_slug); rank by the
    // 3-way precedence (location 0, operator 1, global 2), then latest
    // effective_from; keep rn = 1.
    final byKey = <String, List<Map<String, Object?>>>{};
    for (final row in visible) {
      final key =
          '${row['setting_kind']}|${row['setting_key']}|${row['vendor_slug']}';
      (byKey[key] ??= <Map<String, Object?>>[]).add(row);
    }
    int precedence(Map<String, Object?> row) {
      if ((row['location_id'] as String?) == locationId) return 0;
      if ((row['operator_id'] as String?) == operatorId) return 1;
      return 2;
    }

    final winners = <Map<String, Object?>>[];
    for (final group in byKey.values) {
      group.sort((a, b) {
        final byPrec = precedence(a).compareTo(precedence(b));
        if (byPrec != 0) return byPrec;
        return (b['effective_from'] as DateTime).compareTo(
          a['effective_from'] as DateTime,
        );
      });
      winners.add(group.first);
    }

    // Winner-side `enabled = true` filter only when the SQL carries it.
    // The source calls with enabledOnly:false, so this stays off and
    // disabled winners are returned (the source then drops them).
    final enabledOnly = statement.contains('and enabled = true');
    final result = winners
        .where((row) => !enabledOnly || row['enabled'] == true)
        .toList();
    return result.map((row) => Map<String, Object?>.from(row)).toList();
  }

  @override
  Future<int> execute(
    String statement, {
    Map<String, Object?>? parameters,
  }) async =>
      0;

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
