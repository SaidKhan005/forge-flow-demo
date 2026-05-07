// Phase 8 framework — PerTenantLocationConfigResolver unit tests.
//
// Coverage:
//   * Happy path: known (operatorId, locationId, vendorId) round-trips
//     a config whose timezone, rollover hour, and webhook URL all line
//     up with the row + injected base URI.
//   * Cross-tenant isolation: a resolver bound to one tenant cannot
//     return tenant B's row even when the underlying pool would
//     otherwise hand it back. The SQL filter on `operator_id` +
//     `location_id` prevents the leak; the test pins both filter
//     bindings.
//   * Cache hit inside the TTL window does not open a second
//     transaction.
//   * Cache miss after the TTL window re-runs the query.
//   * Missing location row throws `PerTenantConfigNotFound`.
//   * Per-location override beats operator default; operator default
//     wins when location override is null.
//   * Vendor id pattern is enforced so path-traversal cannot land in
//     the composed webhook URL.

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/integration/per_tenant_location_config_resolver.dart';

const String _opA = '11111111-1111-1111-1111-111111111111';
const String _opB = '44444444-4444-4444-4444-444444444444';
const String _locA = '22222222-2222-2222-2222-222222222222';
const String _locB = '55555555-5555-5555-5555-555555555555';
const String _vendor = 'lightspeed_lsk';

PostgresRow _row({
  String timezone = 'America/Toronto',
  int? locationRolloverHour = 4,
  int? operatorRolloverHour = 4,
}) {
  return <String, Object?>{
    'timezone': timezone,
    'location_rollover_hour': locationRolloverHour,
    'operator_rollover_hour': operatorRolloverHour,
  };
}

PerTenantLocationConfigResolver _resolver(
  _ConfigPool pool, {
  Uri? base,
  Duration ttl = const Duration(minutes: 5),
  DateTime Function()? now,
}) {
  return PerTenantLocationConfigResolver(
    TenantTransactionWrapper(pool),
    webhookPublicBaseUri: base ?? Uri.parse('https://api.forgeflow.app'),
    cacheTtl: ttl,
    now: now,
  );
}

void main() {
  group('PerTenantLocationConfigResolver.resolve — happy path', () {
    test(
      'returns a config whose timezone, rollover hour, and webhook URL '
      'reflect the locations row + injected public base; SQL flows '
      'through withTenant SET LOCAL chain',
      () async {
        final pool = _ConfigPool(rows: <PostgresRow>[_row()]);
        final resolver = _resolver(pool);
        final config = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(config.operatorId, equals(_opA));
        expect(config.locationId, equals(_locA));
        expect(config.vendorId, equals(_vendor));
        expect(config.restaurantTimezone, equals('America/Toronto'));
        expect(config.businessDayRolloverHour, equals(4));
        expect(
          config.webhookBaseUri.toString(),
          equals(
            'https://api.forgeflow.app/v1/webhooks/$_vendor/$_opA/$_locA',
          ),
        );

        final tx = pool.transactions.single;
        // SET LOCAL chain proves we ran through withTenant: tenant
        // GUCs land before the SELECT.
        expect(
          tx.executedSql.where((s) => s.contains("'app.operator_id'")),
          hasLength(1),
        );
        expect(
          tx.executedSql.where((s) => s.contains("'app.location_id'")),
          hasLength(1),
        );
        expect(
          tx.executedSql.where(
            (s) => s.contains("'app.bypass_rls_audit'") &&
                !s.contains('system'),
          ),
          isNotEmpty,
          reason: 'tenant-scope marker, not the system: bypass marker',
        );

        // SQL filters on both operator_id and location_id so cross-
        // tenant isolation is enforced even on a service_role-only
        // RLS posture (the locations table predates per-tenant
        // policies).
        final selectSql = tx.executedSql.firstWhere(
          (s) => s.contains('from public.locations loc'),
        );
        expect(
          selectSql,
          contains('where loc.operator_id = @operator_id::uuid'),
        );
        expect(
          selectSql,
          contains('and loc.location_id = @location_id::uuid'),
        );
        // Joined to operators so the operator-level rollover_hour
        // default is available for the per-location-null fallback.
        expect(
          selectSql,
          contains('join public.operators op'),
        );

        final selectParams = tx.parameters.firstWhere(
          (p) =>
              p['operator_id'] == _opA && p['location_id'] == _locA,
        );
        expect(selectParams['operator_id'], equals(_opA));
        expect(selectParams['location_id'], equals(_locA));
      },
    );

    test(
      'webhook URL preserves a non-root path on the configured base '
      'URI (e.g. https://proxy.example/edge -> '
      'https://proxy.example/edge/v1/webhooks/...)',
      () async {
        final pool = _ConfigPool(rows: <PostgresRow>[_row()]);
        final resolver = _resolver(
          pool,
          base: Uri.parse('https://proxy.example/edge'),
        );
        final config = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(
          config.webhookBaseUri.toString(),
          equals(
            'https://proxy.example/edge/v1/webhooks/$_vendor/$_opA/$_locA',
          ),
        );
      },
    );

    test(
      'webhook URL handles a trailing-slash base without doubling the '
      'separator',
      () async {
        final pool = _ConfigPool(rows: <PostgresRow>[_row()]);
        final resolver = _resolver(
          pool,
          base: Uri.parse('https://api.forgeflow.app/'),
        );
        final config = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(
          config.webhookBaseUri.toString(),
          equals(
            'https://api.forgeflow.app/v1/webhooks/$_vendor/$_opA/$_locA',
          ),
        );
      },
    );
  });

  group('PerTenantLocationConfigResolver.resolve — rollover precedence',
      () {
    test('per-location override beats the operator default', () async {
      final pool = _ConfigPool(
        rows: <PostgresRow>[
          _row(locationRolloverHour: 6, operatorRolloverHour: 3),
        ],
      );
      final resolver = _resolver(pool);
      final config = await resolver.resolve(
        operatorId: _opA,
        locationId: _locA,
        vendorId: _vendor,
      );
      expect(config.businessDayRolloverHour, equals(6));
    });

    test(
      'operator-level default applies when the location override is '
      'NULL',
      () async {
        final pool = _ConfigPool(
          rows: <PostgresRow>[
            _row(locationRolloverHour: null, operatorRolloverHour: 5),
          ],
        );
        final resolver = _resolver(pool);
        final config = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(config.businessDayRolloverHour, equals(5));
      },
    );

    test(
      'falls back to the documented default (4) when both location '
      'and operator rollover columns are NULL',
      () async {
        final pool = _ConfigPool(
          rows: <PostgresRow>[
            _row(locationRolloverHour: null, operatorRolloverHour: null),
          ],
        );
        final resolver = _resolver(pool);
        final config = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(
          config.businessDayRolloverHour,
          equals(kPerTenantLocationConfigDefaultRolloverHour),
        );
      },
    );
  });

  group('PerTenantLocationConfigResolver.resolve — cross-tenant isolation',
      () {
    test(
      'second resolve call against a different tenant runs its own '
      'transaction with its own operator_id/location_id GUCs — the '
      'first tenant\'s context never bleeds in',
      () async {
        final pool = _ConfigPool(
          rows: <PostgresRow>[_row()],
          rowsPerTransaction: <List<PostgresRow>>[
            <PostgresRow>[
              _row(timezone: 'America/Toronto'),
            ],
            <PostgresRow>[
              _row(timezone: 'Europe/Berlin'),
            ],
          ],
        );
        final resolver = _resolver(pool);
        final configA = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        final configB = await resolver.resolve(
          operatorId: _opB,
          locationId: _locB,
          vendorId: _vendor,
        );
        expect(configA.restaurantTimezone, equals('America/Toronto'));
        expect(configB.restaurantTimezone, equals('Europe/Berlin'));

        expect(pool.transactions, hasLength(2));

        // Each transaction sets its OWN operator_id GUC parametrically.
        final opAParams = pool.transactions[0].parameters
            .firstWhere((p) => p['value'] == _opA);
        final opBParams = pool.transactions[1].parameters
            .firstWhere((p) => p['value'] == _opB);
        expect(opAParams['value'], equals(_opA));
        expect(opBParams['value'], equals(_opB));

        // Webhook URLs carry the right tenant — a leak would surface
        // here as a mismatched URL.
        expect(
          configA.webhookBaseUri.toString(),
          equals(
            'https://api.forgeflow.app/v1/webhooks/$_vendor/$_opA/$_locA',
          ),
        );
        expect(
          configB.webhookBaseUri.toString(),
          equals(
            'https://api.forgeflow.app/v1/webhooks/$_vendor/$_opB/$_locB',
          ),
        );
      },
    );
  });

  group('PerTenantLocationConfigResolver.resolve — cache TTL', () {
    test(
      'second call inside the TTL window returns the cached config '
      'without opening a second transaction',
      () async {
        final pool = _ConfigPool(rows: <PostgresRow>[_row()]);
        var nowTicks = DateTime.utc(2026, 5, 7, 10);
        final resolver = _resolver(
          pool,
          ttl: const Duration(minutes: 5),
          now: () => nowTicks,
        );
        final first = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        // Advance one minute — still inside the 5-min TTL.
        nowTicks = nowTicks.add(const Duration(minutes: 1));
        final second = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(identical(first, second), isTrue);
        expect(
          pool.transactions,
          hasLength(1),
          reason: 'cache hit must not open a second tx',
        );
      },
    );

    test(
      'after the TTL expires the next call re-reads through a fresh '
      'transaction',
      () async {
        final pool = _ConfigPool(
          rowsPerTransaction: <List<PostgresRow>>[
            <PostgresRow>[_row(timezone: 'America/Toronto')],
            <PostgresRow>[_row(timezone: 'America/Vancouver')],
          ],
        );
        var nowTicks = DateTime.utc(2026, 5, 7, 10);
        final resolver = _resolver(
          pool,
          ttl: const Duration(minutes: 5),
          now: () => nowTicks,
        );
        final first = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(first.restaurantTimezone, equals('America/Toronto'));

        // Advance past the TTL — next read must hit the DB again.
        nowTicks = nowTicks.add(const Duration(minutes: 6));
        final second = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(second.restaurantTimezone, equals('America/Vancouver'));
        expect(pool.transactions, hasLength(2));
      },
    );

    test(
      'invalidateAll() drops every cached entry so the next resolve '
      'picks up a freshly-written config',
      () async {
        final pool = _ConfigPool(
          rowsPerTransaction: <List<PostgresRow>>[
            <PostgresRow>[_row(timezone: 'America/Toronto')],
            <PostgresRow>[_row(timezone: 'Europe/Berlin')],
          ],
        );
        final resolver = _resolver(pool);
        await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        resolver.invalidateAll();
        final second = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(second.restaurantTimezone, equals('Europe/Berlin'));
        expect(pool.transactions, hasLength(2));
      },
    );

    test(
      'invalidateLocation() targets one (operator, location) tuple — '
      'other tenants stay cached',
      () async {
        final pool = _ConfigPool(
          rowsPerTransaction: <List<PostgresRow>>[
            <PostgresRow>[_row(timezone: 'America/Toronto')],
            <PostgresRow>[_row(timezone: 'Europe/Berlin')],
            <PostgresRow>[_row(timezone: 'America/Toronto')],
          ],
        );
        final resolver = _resolver(pool);
        await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        await resolver.resolve(
          operatorId: _opB,
          locationId: _locB,
          vendorId: _vendor,
        );
        resolver.invalidateLocation(operatorId: _opA, locationId: _locA);
        // Tenant A re-reads; tenant B stays cached.
        await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        await resolver.resolve(
          operatorId: _opB,
          locationId: _locB,
          vendorId: _vendor,
        );
        expect(pool.transactions, hasLength(3));
      },
    );
  });

  group('PerTenantLocationConfigResolver.resolve — error paths', () {
    test(
      'throws PerTenantConfigNotFound when the location row is '
      'missing for the operator',
      () async {
        final pool = _ConfigPool(rows: const <PostgresRow>[]);
        final resolver = _resolver(pool);
        await expectLater(
          resolver.resolve(
            operatorId: _opA,
            locationId: _locA,
            vendorId: _vendor,
          ),
          throwsA(isA<PerTenantConfigNotFound>()),
        );
      },
    );

    test(
      'after a NotFound failure, a fresh row landing in the DB resolves '
      '— the resolver does NOT cache the failure',
      () async {
        final pool = _ConfigPool(
          rowsPerTransaction: <List<PostgresRow>>[
            const <PostgresRow>[],
            <PostgresRow>[_row()],
          ],
        );
        final resolver = _resolver(pool);
        await expectLater(
          resolver.resolve(
            operatorId: _opA,
            locationId: _locA,
            vendorId: _vendor,
          ),
          throwsA(isA<PerTenantConfigNotFound>()),
        );
        final second = await resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: _vendor,
        );
        expect(second.restaurantTimezone, equals('America/Toronto'));
      },
    );

    test('rejects a blank vendor id', () async {
      final pool = _ConfigPool(rows: <PostgresRow>[_row()]);
      final resolver = _resolver(pool);
      expect(
        () => resolver.resolve(
          operatorId: _opA,
          locationId: _locA,
          vendorId: '   ',
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(pool.transactions, isEmpty);
    });

    test(
      'rejects vendor ids with characters outside [a-z0-9_]+ (defends '
      'the composed webhook URL against path traversal)',
      () async {
        final pool = _ConfigPool(rows: <PostgresRow>[_row()]);
        final resolver = _resolver(pool);
        expect(
          () => resolver.resolve(
            operatorId: _opA,
            locationId: _locA,
            vendorId: '../evil',
          ),
          throwsA(isA<ArgumentError>()),
        );
        expect(pool.transactions, isEmpty);
      },
    );

    test(
      'rejects a non-http(s) public base URI at construction so a '
      'misconfigured boot cannot mint a file:// or javascript: URL',
      () {
        final pool = _ConfigPool();
        expect(
          () => PerTenantLocationConfigResolver(
            TenantTransactionWrapper(pool),
            webhookPublicBaseUri: Uri.parse('file:///etc/passwd'),
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );
  });
}

/// Recording fake `PostgresPool` shaped for the resolver. The pool can
/// be configured two ways:
///   * [rows] — every transaction returns the same row set. Convenient
///     for single-call tests.
///   * [rowsPerTransaction] — one entry per transaction in order.
///     Tests that exercise cache miss / multi-tenant flows pass this.
class _ConfigPool implements PostgresPool {
  _ConfigPool({
    this.rows = const <PostgresRow>[],
    this.rowsPerTransaction,
  });

  final List<PostgresRow> rows;
  final List<List<PostgresRow>>? rowsPerTransaction;
  final List<_ConfigTransaction> transactions = <_ConfigTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final List<PostgresRow> rowsForTx;
    final perTx = rowsPerTransaction;
    if (perTx != null) {
      if (transactions.length >= perTx.length) {
        throw StateError(
          'pool has no rowsPerTransaction entry for transaction '
          '#${transactions.length + 1}',
        );
      }
      rowsForTx = perTx[transactions.length];
    } else {
      rowsForTx = rows;
    }
    final tx = _ConfigTransaction(rows: rowsForTx);
    transactions.add(tx);
    return tx;
  }
}

class _ConfigTransaction extends PostgresTransaction {
  _ConfigTransaction({required this.rows});

  final List<PostgresRow> rows;

  final List<String> executedSql = <String>[];
  final List<PostgresParameters> parameters = <PostgresParameters>[];
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    if (sql.contains('from public.locations loc')) {
      return rows;
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    executedSql.add(sql);
    this.parameters.add(parameters);
    return 0;
  }

  @override
  Future<void> commit() async {
    _finalized = true;
  }

  @override
  Future<void> rollback() async {
    _finalized = true;
  }
}
