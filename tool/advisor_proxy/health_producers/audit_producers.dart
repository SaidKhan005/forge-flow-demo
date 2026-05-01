// Phase 11A.B42 — Audit / auth-foundation health producers.
//
// Watches the audit chain (B37/B43), applied-migrations registry,
// Firebase JWKS reachability, and service-principal JWT signer.

import '../advisor_proxy.dart' show ProxyHealthMetric;
import 'health_producer.dart';

ProxyHealthMetric _auditChainLagTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'seconds',
  description:
      'Lag between current audit chain head and the most recent durable '
      'audit anchor (B37/B43). Yellow at 30 minutes, red at 6 hours.',
  source: 'audit_chain_anchors',
  owner: 'B37/B43',
  thresholds: <String, Object?>{'yellow': 1800, 'red': 21600},
  metadata: <String, Object?>{'tier': 1},
);

Future<ProxyHealthMetric> auditChainLagSecondsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _auditChainLagTemplate, () async {
    final rows = await context.runner.query(
      "select extract(epoch from (now() - max(anchored_at)))::bigint as lag "
      "from audit_chain_anchors",
    );
    if (rows.isEmpty || rows.first['lag'] == null) {
      return ProxyHealthMetric(
        status: 'red',
        value: null,
        unit: 'seconds',
        description: _auditChainLagTemplate().description,
        source: 'audit_chain_anchors',
        owner: 'B37/B43',
        observedAt: context.now,
        thresholds: _auditChainLagTemplate().thresholds,
        metadata: const <String, Object?>{
          'tier': 1,
          'warning': 'no_anchor_recorded',
        },
      );
    }
    final lag = (rows.first['lag'] as num).toInt();
    return ProxyHealthMetric(
      status: lag >= 21600 ? 'red' : (lag >= 1800 ? 'yellow' : 'green'),
      value: lag,
      unit: 'seconds',
      description: _auditChainLagTemplate().description,
      source: 'audit_chain_anchors',
      owner: 'B37/B43',
      observedAt: context.now,
      thresholds: _auditChainLagTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 1},
    );
  });
}

ProxyHealthMetric _auditChainAnchorAgeTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'seconds',
  description:
      'Age of the most recent Azure Blob immutable audit anchor. Yellow at '
      '24h, red at 48h to keep the daily anchor cadence honest.',
  source: 'audit_chain_anchors',
  owner: 'B37/B43',
  thresholds: <String, Object?>{'yellow': 86400, 'red': 172800},
  metadata: <String, Object?>{'tier': 1},
);

Future<ProxyHealthMetric> auditChainAnchorAgeSecondsProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _auditChainAnchorAgeTemplate, () async {
    final rows = await context.runner.query(
      "select extract(epoch from (now() - max(blob_anchored_at)))::bigint as age "
      "from audit_chain_anchors where blob_anchored_at is not null",
    );
    if (rows.isEmpty || rows.first['age'] == null) {
      return ProxyHealthMetric(
        status: 'red',
        value: null,
        unit: 'seconds',
        description: _auditChainAnchorAgeTemplate().description,
        source: 'audit_chain_anchors',
        owner: 'B37/B43',
        observedAt: context.now,
        thresholds: _auditChainAnchorAgeTemplate().thresholds,
        metadata: const <String, Object?>{
          'tier': 1,
          'warning': 'no_blob_anchor_recorded',
        },
      );
    }
    final age = (rows.first['age'] as num).toInt();
    return ProxyHealthMetric(
      status: age >= 172800 ? 'red' : (age >= 86400 ? 'yellow' : 'green'),
      value: age,
      unit: 'seconds',
      description: _auditChainAnchorAgeTemplate().description,
      source: 'audit_chain_anchors',
      owner: 'B37/B43',
      observedAt: context.now,
      thresholds: _auditChainAnchorAgeTemplate().thresholds,
      metadata: const <String, Object?>{'tier': 1},
    );
  });
}

ProxyHealthMetric _migrationApplyDriftTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'count',
  description:
      'Migration files present in db/migrations that the proxy has not yet '
      'recorded as applied in proxy_migrations_applied. Any drift is red.',
  source: 'proxy_migrations_applied',
  owner: 'B42',
  thresholds: <String, Object?>{'red': 1},
  metadata: <String, Object?>{'tier': 1},
);

/// Factory: returns a producer that compares [expectedFilenames]
/// (basenames of files in `db/migrations/`) against the
/// `proxy_migrations_applied` registry. Bootstrap callers thread the
/// on-disk list through here so the SQL function receives the
/// non-null `expected_filenames` array — the bare zero-arg call is
/// reserved for cases where the producer has no list to compare and
/// must project to `unknown`.
ProxyHealthProducer migrationApplyDriftCountProducerFor(
  List<String> expectedFilenames,
) {
  return (ProxyHealthProducerContext context) {
    return runProducer(context, _migrationApplyDriftTemplate, () async {
      if (expectedFilenames.isEmpty) {
        return ProxyHealthMetric(
          status: 'unknown',
          value: null,
          unit: 'count',
          description: _migrationApplyDriftTemplate().description,
          source: 'proxy_migrations_applied',
          owner: 'B42',
          observedAt: context.now,
          thresholds: _migrationApplyDriftTemplate().thresholds,
          metadata: const <String, Object?>{
            'tier': 1,
            'warning': 'expected_filenames_not_provided',
          },
        );
      }
      final rows = await context.runner.query(
        'select coalesce(drift_count, 0)::int as cnt, '
        'coalesce(missing_migrations, array[]::text[]) as missing '
        'from public.proxy_migration_apply_drift(@expected::text[])',
        parameters: <String, Object?>{'expected': expectedFilenames},
      );
      final count = (rows.first['cnt'] as num?)?.toInt() ?? 0;
      final missing = rows.first['missing'];
      final missingList = missing is List
          ? List<String>.from(missing.map((e) => e.toString()))
          : const <String>[];
      return ProxyHealthMetric(
        status: count >= 1 ? 'red' : 'green',
        value: count,
        unit: 'count',
        description: _migrationApplyDriftTemplate().description,
        source: 'proxy_migrations_applied',
        owner: 'B42',
        observedAt: context.now,
        thresholds: _migrationApplyDriftTemplate().thresholds,
        metadata: <String, Object?>{
          'tier': 1,
          if (missingList.isNotEmpty) 'missing_count': missingList.length,
        },
      );
    });
  };
}

/// Default catalog entry: when the bootstrap has not threaded an
/// expected list yet, the producer projects to `unknown` rather than
/// silently green. This is a stricter default than the bare SQL
/// function's zero-arg branch.
final ProxyHealthProducer migrationApplyDriftCountProducer =
    migrationApplyDriftCountProducerFor(const <String>[]);

ProxyHealthMetric _firebaseJwksFetchAliveTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'boolean',
  description:
      'Whether the most recent Firebase JWKS fetch succeeded inside the JWKS '
      'cache TTL window. False means token verification is degraded.',
  source: 'firebase_jwks_cache_status',
  owner: 'B42',
  metadata: <String, Object?>{'tier': 1},
);

Future<ProxyHealthMetric> firebaseJwksFetchAliveProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _firebaseJwksFetchAliveTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(alive, false) as alive, '
      'extract(epoch from (now() - last_success_at))::bigint as age_seconds '
      'from firebase_jwks_cache_status order by observed_at desc limit 1',
    );
    if (rows.isEmpty) {
      return ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'boolean',
        description: _firebaseJwksFetchAliveTemplate().description,
        source: 'firebase_jwks_cache_status',
        owner: 'B42',
        observedAt: context.now,
        metadata: const <String, Object?>{
          'tier': 1,
          'warning': 'no_jwks_status_recorded',
        },
      );
    }
    final alive = rows.first['alive'] == true;
    final age = (rows.first['age_seconds'] as num?)?.toInt() ?? 0;
    return ProxyHealthMetric(
      status: alive && age <= 3600 ? 'green' : 'red',
      value: alive,
      unit: 'boolean',
      description: _firebaseJwksFetchAliveTemplate().description,
      source: 'firebase_jwks_cache_status',
      owner: 'B42',
      observedAt: context.now,
      metadata: <String, Object?>{
        'tier': 1,
        'seconds_since_last_success': age,
      },
    );
  });
}

ProxyHealthMetric _servicePrincipalJwtAliveTemplate() => const ProxyHealthMetric(
  status: 'unknown',
  value: null,
  unit: 'boolean',
  description:
      'Whether the service-principal HMAC signer secret is loaded and a '
      'recent sp: token was successfully verified.',
  source: 'service_principals_signer_status',
  owner: 'B42',
  metadata: <String, Object?>{'tier': 1},
);

Future<ProxyHealthMetric> servicePrincipalJwtAliveProducer(
  ProxyHealthProducerContext context,
) {
  return runProducer(context, _servicePrincipalJwtAliveTemplate, () async {
    final rows = await context.runner.query(
      'select coalesce(signer_loaded, false) as signer_loaded, '
      'coalesce(recent_verify_ok, false) as recent_verify_ok '
      'from service_principals_signer_status limit 1',
    );
    if (rows.isEmpty) {
      return ProxyHealthMetric(
        status: 'unknown',
        value: null,
        unit: 'boolean',
        description: _servicePrincipalJwtAliveTemplate().description,
        source: 'service_principals_signer_status',
        owner: 'B42',
        observedAt: context.now,
        metadata: const <String, Object?>{
          'tier': 1,
          'warning': 'no_signer_status_recorded',
        },
      );
    }
    final signerLoaded = rows.first['signer_loaded'] == true;
    final recentVerifyOk = rows.first['recent_verify_ok'] == true;
    final alive = signerLoaded && recentVerifyOk;
    return ProxyHealthMetric(
      status: alive ? 'green' : 'red',
      value: alive,
      unit: 'boolean',
      description: _servicePrincipalJwtAliveTemplate().description,
      source: 'service_principals_signer_status',
      owner: 'B42',
      observedAt: context.now,
      metadata: const <String, Object?>{'tier': 1},
    );
  });
}

final Map<String, ProxyHealthProducer> auditProducers =
    <String, ProxyHealthProducer>{
      'audit_chain_lag_seconds': auditChainLagSecondsProducer,
      'audit_chain_anchor_age_seconds': auditChainAnchorAgeSecondsProducer,
      'migration_apply_drift_count': migrationApplyDriftCountProducer,
      'firebase_jwks_fetch_alive': firebaseJwksFetchAliveProducer,
      'service_principal_jwt_alive': servicePrincipalJwtAliveProducer,
    };
