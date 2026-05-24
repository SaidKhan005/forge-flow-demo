import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/admin/models/observability_admin_models.dart';
import 'package:forge_and_flow/infrastructure/cloud_run/cloud_run_admin_client.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('RepositoryObservabilityAdminProxyGateway cloud_run', () {
    test(
      'a known capacity snapshot populates the cloud_run row',
      () async {
        final pool = _ObservabilityPool();
        final gateway = RepositoryObservabilityAdminProxyGateway(
          adminWrapper: TenantTransactionWrapper(pool),
          cloudRunServiceName: 'forge-flow-advisor-proxy',
          cloudRunRevision: 'forge-flow-advisor-proxy-00042-abc',
          cloudRunCapacityReader: _FakeCloudRunCapacityReader(
            capacity: const CloudRunServiceCapacity(
              // The parsed reader service name; the gateway prefers its
              // own configured name over this.
              serviceName: 'parsed-from-reader',
              activeInstanceCount: 3,
              minInstances: 1,
              maxInstances: 10,
              servingRevisionId: 'forge-flow-advisor-proxy-00043-def',
            ),
          ),
          now: () => DateTime.utc(2026, 5, 24, 12),
        );

        final envelope = await gateway.fetch(
          actorUserId: 'admin-user',
          adminReason: 'admin.observability.test',
          costTelemetryLimit: 10,
        );

        final cloudRun = envelope['cloud_run'] as List<Object?>;
        expect(cloudRun, hasLength(1));

        final row = cloudRun.single as Map<String, Object?>;
        // Service name prefers the gateway's configured canonical id.
        expect(row['service_name'], equals('forge-flow-advisor-proxy'));
        expect(row['instance_count'], equals(3));
        expect(row['min_instances'], equals(1));
        expect(row['max_instances'], equals(10));
        // Serving revision from the reader wins over the configured one.
        expect(
          row['revision_id'],
          equals('forge-flow-advisor-proxy-00043-def'),
        );

        // The consumer model parses the row without coercing any unknown.
        final parsed = CloudRunInstanceMetric.fromJson(
          row.cast<String, Object?>(),
        );
        expect(parsed.serviceName, equals('forge-flow-advisor-proxy'));
        expect(parsed.instanceCount, equals(3));
        expect(parsed.minInstances, equals(1));
        expect(parsed.maxInstances, equals(10));
        expect(
          parsed.revisionId,
          equals('forge-flow-advisor-proxy-00043-def'),
        );

        // cloud_run is no longer advertised as a neutral-empty surface.
        final producerNotes =
            envelope['producer_notes'] as Map<String, Object?>;
        final neutralEmpty =
            producerNotes['neutral_empty_surfaces'] as List<Object?>;
        expect(neutralEmpty.contains('cloud_run'), isFalse);
        // The other genuinely-empty surfaces stay advertised. `cap_events`
        // is no longer here: it is now a live producer (reads
        // public.usage_cap_events) that happens to have no rows until the
        // write-side refusal hook lands in a later slice.
        expect(neutralEmpty.contains('margins'), isTrue);
        expect(neutralEmpty.contains('cap_events'), isFalse);
        expect(neutralEmpty.contains('route_latency'), isTrue);
      },
    );

    test(
      'a throwing reader still returns the envelope with empty cloud_run',
      () async {
        final pool = _ObservabilityPool();
        final gateway = RepositoryObservabilityAdminProxyGateway(
          adminWrapper: TenantTransactionWrapper(pool),
          cloudRunServiceName: 'forge-flow-advisor-proxy',
          cloudRunRevision: 'forge-flow-advisor-proxy-00042-abc',
          cloudRunCapacityReader: _ThrowingCloudRunCapacityReader(),
          now: () => DateTime.utc(2026, 5, 24, 12),
        );

        // The whole fetch must succeed — the Cloud Run read failure is
        // caught internally and never propagates.
        final envelope = await gateway.fetch(
          actorUserId: 'admin-user',
          adminReason: 'admin.observability.test',
          costTelemetryLimit: 10,
        );

        // Endpoint still produced a complete envelope.
        expect(envelope['contract'], equals('admin_observability.v1'));
        expect(envelope['as_of'], isNotNull);

        // cloud_run is honestly empty (no fabricated row, no zeros).
        final cloudRun = envelope['cloud_run'] as List<Object?>;
        expect(cloudRun, isEmpty);

        // And it stays advertised as a neutral-empty surface.
        final producerNotes =
            envelope['producer_notes'] as Map<String, Object?>;
        final neutralEmpty =
            producerNotes['neutral_empty_surfaces'] as List<Object?>;
        expect(neutralEmpty.contains('cloud_run'), isTrue);

        // The configured service identity is still echoed in the notes.
        expect(
          producerNotes['cloud_run_service_name'],
          equals('forge-flow-advisor-proxy'),
        );
      },
    );

    test(
      'an unknown (all-null) snapshot yields no row and stays empty',
      () async {
        final pool = _ObservabilityPool();
        // The default reader is a NoOp all-unknown reader; constructing
        // without one must behave identically to today (honest empty).
        final gateway = RepositoryObservabilityAdminProxyGateway(
          adminWrapper: TenantTransactionWrapper(pool),
          cloudRunServiceName: 'forge-flow-advisor-proxy',
          now: () => DateTime.utc(2026, 5, 24, 12),
        );

        final envelope = await gateway.fetch(
          actorUserId: 'admin-user',
          adminReason: 'admin.observability.test',
          costTelemetryLimit: 10,
        );

        final cloudRun = envelope['cloud_run'] as List<Object?>;
        expect(cloudRun, isEmpty);

        final producerNotes =
            envelope['producer_notes'] as Map<String, Object?>;
        final neutralEmpty =
            producerNotes['neutral_empty_surfaces'] as List<Object?>;
        expect(neutralEmpty.contains('cloud_run'), isTrue);
      },
    );

    test(
      'a partial snapshot (missing a count) emits no fabricated zero',
      () async {
        final pool = _ObservabilityPool();
        // activeInstanceCount known, but min/max unknown — the common
        // live case where the v2 Service resource omits scaling. We MUST
        // NOT emit a row that would render "0-0 instances".
        final gateway = RepositoryObservabilityAdminProxyGateway(
          adminWrapper: TenantTransactionWrapper(pool),
          cloudRunServiceName: 'forge-flow-advisor-proxy',
          cloudRunCapacityReader: _FakeCloudRunCapacityReader(
            capacity: const CloudRunServiceCapacity(
              serviceName: 'forge-flow-advisor-proxy',
              activeInstanceCount: 2,
              // minInstances / maxInstances intentionally null.
              servingRevisionId: 'forge-flow-advisor-proxy-00043-def',
            ),
          ),
          now: () => DateTime.utc(2026, 5, 24, 12),
        );

        final envelope = await gateway.fetch(
          actorUserId: 'admin-user',
          adminReason: 'admin.observability.test',
          costTelemetryLimit: 10,
        );

        final cloudRun = envelope['cloud_run'] as List<Object?>;
        expect(cloudRun, isEmpty);

        final producerNotes =
            envelope['producer_notes'] as Map<String, Object?>;
        final neutralEmpty =
            producerNotes['neutral_empty_surfaces'] as List<Object?>;
        expect(neutralEmpty.contains('cloud_run'), isTrue);
      },
    );
  });
}

/// Fake reader returning a fixed capacity snapshot. No HTTP / GCP.
class _FakeCloudRunCapacityReader implements CloudRunCapacityReader {
  _FakeCloudRunCapacityReader({required this.capacity});

  final CloudRunServiceCapacity capacity;

  @override
  Future<CloudRunServiceCapacity> readServiceCapacity() async => capacity;
}

/// Fake reader that throws, simulating a missing GCP scope / timeout /
/// malformed body on staging.
class _ThrowingCloudRunCapacityReader implements CloudRunCapacityReader {
  @override
  Future<CloudRunServiceCapacity> readServiceCapacity() async {
    throw CloudRunAdminError(
      message: 'cloud_run_get_forbidden',
      statusCode: 403,
    );
  }
}

class _ObservabilityPool implements PostgresPool {
  final List<_ObservabilityTransaction> transactions =
      <_ObservabilityTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _ObservabilityTransaction();
    transactions.add(tx);
    return tx;
  }
}

/// Minimal transaction fake: every observability SQL query returns no
/// rows. The cloud_run surface is fed by the injected reader, not the DB,
/// so the empty result set is sufficient to exercise the gateway end to
/// end.
class _ObservabilityTransaction extends PostgresTransaction {
  bool _finalized = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    if (_finalized) throw StateError('transaction already finalized');
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
