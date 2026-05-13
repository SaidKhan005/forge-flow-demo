// Phase 11A.B42 — central producer registry.
//
// One catalog of all 58 deep-health producers. The registry-backed
// [RegistryProxyHealthCheckStore] runs producers through a bounded
// concurrency lane, applies each producer's individual budget, and assembles a
// [ProxyHealthStatus] with the dependency probes resolved separately
// so postgres/AGE/pgvector liveness can drive HTTP 503 without forcing
// tier-2/3 producers to participate in the failure model.

import '../advisor_proxy.dart'
    show
        ProxyHealthMetric,
        ProxyHealthRegistryContext,
        ProxyHealthRegistryProducer;

import 'audit_producers.dart';
import 'cost_producers.dart';
import 'graph_producers.dart';
import 'health_producer.dart';
import 'infra_producers.dart';
import 'outbox_producers.dart';
import 'retrieval_producers.dart';
import 'rollup_producers.dart';
import 'vector_producers.dart';

const String familyInfra = 'infra';
const String familyAudit = 'audit';
const String familyOutbox = 'outbox';
const String familyGraph = 'graph';
const String familyVector = 'vector';
const String familyRollup = 'rollup';
const String familyRetrieval = 'retrieval';
const String familyCost = 'cost';

/// Per-family producer maps, keyed by family name. Useful for tests
/// that want to exercise one family at a time.
Map<String, Map<String, ProxyHealthProducer>> proxyHealthProducerFamilies() {
  return <String, Map<String, ProxyHealthProducer>>{
    familyInfra: infraProducers,
    familyAudit: auditProducers,
    familyOutbox: outboxProducers,
    familyGraph: graphProducers,
    familyVector: vectorProducers,
    familyRollup: rollupProducers,
    familyRetrieval: retrievalProducers,
    familyCost: costProducers,
  };
}

/// Flat key → producer map covering all 58 slots. The map is keyed by
/// the metric name in the proxy `/health` envelope.
Map<String, ProxyHealthProducer> proxyHealthProducerCatalog() {
  final result = <String, ProxyHealthProducer>{};
  for (final family in proxyHealthProducerFamilies().values) {
    result.addAll(family);
  }
  return result;
}

/// Adapter that bridges the function-based registry context to the
/// runner-based producer context family files use.
class _FunctionalProxyHealthQueryRunner implements ProxyHealthQueryRunner {
  _FunctionalProxyHealthQueryRunner(this._runnerFn);

  final Future<List<Map<String, Object?>>> Function(
    String sql, {
    Map<String, Object?> parameters,
  })
  _runnerFn;

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, {
    Map<String, Object?> parameters = const <String, Object?>{},
  }) => _runnerFn(sql, parameters: parameters);
}

/// Adapt a family-file producer so the registry can call it with a
/// [ProxyHealthRegistryContext].
ProxyHealthRegistryProducer adaptFamilyProducer(ProxyHealthProducer producer) {
  return (ProxyHealthRegistryContext registryContext) {
    final familyContext = ProxyHealthProducerContext(
      runner: _FunctionalProxyHealthQueryRunner(registryContext.runnerFn),
      now: registryContext.now,
      budget: registryContext.budget,
      inMemoryBreakerStates: registryContext.inMemoryBreakerStates,
      sessionRecordIncompleteSnapshot:
          registryContext.sessionRecordIncompleteSnapshot,
    );
    return producer(familyContext);
  };
}

/// All 58 producers, adapted to the registry signature so the proxy
/// boot can wire them into [RegistryProxyHealthCheckStore].
///
/// Pass [expectedMigrationFilenames] (basenames of files in
/// `db/migrations/`) so the Tier-1 `migration_apply_drift_count`
/// producer can compute drift against the live registry. When the list
/// is empty, the drift producer projects to `unknown` rather than
/// silently green.
Map<String, ProxyHealthRegistryProducer> buildProxyHealthRegistryProducers({
  List<String> expectedMigrationFilenames = const <String>[],
}) {
  final catalog = <String, ProxyHealthProducer>{
    ...proxyHealthProducerCatalog(),
    'migration_apply_drift_count': migrationApplyDriftCountProducerFor(
      expectedMigrationFilenames,
    ),
  };
  return <String, ProxyHealthRegistryProducer>{
    for (final entry in catalog.entries)
      entry.key: adaptFamilyProducer(entry.value),
  };
}

/// Sanity helper used in tests: returns the count of distinct producer
/// keys in the catalog. The current producer catalog pins this at 58.
int proxyHealthRegisteredProducerCount() => proxyHealthProducerCatalog().length;

/// Internal: re-export an adapter for unit tests that want to call
/// `ProxyHealthQueryRunner` against a function-shaped runner.
ProxyHealthQueryRunner functionalRunnerForTests(
  Future<List<Map<String, Object?>>> Function(
    String sql, {
    Map<String, Object?> parameters,
  })
  fn,
) => _FunctionalProxyHealthQueryRunner(fn);

/// Convenience for tests that want to round-trip a family producer
/// through the registry adapter without spinning up the registry.
Future<MapEntry<String, ProxyHealthMetric>> runFamilyProducerForTests(
  String key,
  ProxyHealthProducer producer,
  ProxyHealthRegistryContext context,
) async {
  final adapted = adaptFamilyProducer(producer);
  final metric = await adapted(context);
  return MapEntry(key, metric);
}
