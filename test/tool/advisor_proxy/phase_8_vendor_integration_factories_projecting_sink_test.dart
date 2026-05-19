// Phase 8 `8.post-commit-projector-wire-in` — projecting-sink wiring
// tests for the factories builder.
//
// The factories builder is the single source of truth for per-vendor
// adapter wiring (see `phase_8_vendor_integration_factories.dart`).
// This file pins the contract that when the projector + period
// resolver + restaurant-id resolver triple is supplied, the bundle's
// `projectingSinksByVendor` map is populated for direct CanonicalSink
// wrappers, and `projectionTapsByVendor` is populated for direct
// adapter writes. When any of the three projector dependencies is null
// both projection surfaces stay empty.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/domain/models/aggregator_provenance_context.dart';
import 'package:forge_and_flow/domain/models/shift_fact.dart';
import 'package:forge_and_flow/domain/models/target_snapshot.dart';
import 'package:forge_and_flow/integrations/_common/vendor_credential_broker.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_post_commit_projector.dart';
import 'package:forge_and_flow/services/integration/canonical_fact_to_closed_shift_input.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart';
import 'package:forge_and_flow/services/integration/open_shift_snapshot_projector.dart';
import 'package:forge_and_flow/services/integration/per_tenant_location_config_resolver.dart';
import 'package:forge_and_flow/services/integration/projecting_canonical_sink.dart';
import 'package:http/http.dart' as http;

import '../../../tool/advisor_proxy/advisor_proxy.dart';
import '../../../tool/advisor_proxy/phase_8_production_binder.dart';
import '../../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('Phase8VendorIntegrationFactories projecting-sink wiring', () {
    test('projector triple supplied → wrappers populated for the 7 always-on '
        'directly-CanonicalSink-implementing vendors (Toast, Lightspeed LSK, '
        'Oracle MICROS, Revel, ADP, Agendrix, Push Operations)', () {
      final config = _buildConfig();
      final factories = _buildFactoriesWithProjector(
        config,
        canonicalFactPostCommitProjector: _stubProjector,
        canonicalFactPeriodResolver: _stubPeriodResolver,
        canonicalRestaurantIdResolver: _stubRestaurantIdResolver,
      );

      // Vendors whose factories wire unconditionally (no optional
      // app-credential gate). Every one has a postgres sink that
      // directly implements CanonicalSink, so every one must be
      // wrapped.
      const alwaysOnDirectCanonicalSinkVendors = <String>{
        'toast',
        'lightspeed_lsk',
        'oracle_micros_simphony',
        'revel',
        'aloha_ncr_voyix', // alohaSink is built unconditionally; only
        // the factory closure is gated on credentials.
        'adp',
        'agendrix',
        'push_operations',
        'humanity', // Humanity is `authMode = keyPaste`; both the
        // sink AND the factory closure are unconditional. App creds
        // are read by the OAuth refresh worker only.
        'quickbooks_time', // qbtSink is built unconditionally; the
        // factory closure is gated.
      };

      for (final vendor in alwaysOnDirectCanonicalSinkVendors) {
        expect(
          factories.projectingSinksByVendor.containsKey(vendor),
          isTrue,
          reason:
              '$vendor sink must be wrapped — its postgres sink '
              'directly implements CanonicalSink and is built outside '
              'any optional-credential gate',
        );
        expect(
          factories.projectingSinksByVendor[vendor],
          isA<ProjectingCanonicalSink>(),
          reason: '$vendor wrapper must be a ProjectingCanonicalSink',
        );
      }

      // Sanity: the 4 view-based vendors stay out of the wrap map even
      // with projector wiring active.
      for (final outOfScope in const <String>[
        'libro',
        'opentable',
        'tock',
        'sevenrooms',
      ]) {
        expect(
          factories.projectingSinksByVendor.containsKey(outOfScope),
          isFalse,
          reason:
              '$outOfScope exposes CanonicalSink only via asCanonicalSink '
              'and is wrapped per-tenant downstream, not at boot',
        );
      }
    });

    test('all three projector deps null → projectingSinksByVendor stays empty '
        '(caller has not surfaced a production-wired projector yet)', () {
      final config = _buildConfig();
      final factories = _buildFactoriesWithProjector(
        config,
        // Pass nothing — wiring inactive.
      );

      expect(factories.projectionTapsByVendor, isEmpty);
      expect(
        factories.projectingSinksByVendor,
        isEmpty,
        reason:
            'when any of the three projector deps is null the wrapper map '
            'must be empty — no partial wiring',
      );
    });

    test(
      'partial projector dep (only projector) → wrapper map empty: all three '
      'must be present together',
      () {
        final config = _buildConfig();
        final factories = _buildFactoriesWithProjector(
          config,
          canonicalFactPostCommitProjector: _stubProjector,
          // resolvers null
        );

        expect(
          factories.projectingSinksByVendor,
          isEmpty,
          reason:
              'incomplete projector wiring (projector without resolvers) must '
              'short-circuit to empty rather than silently constructing a '
              'half-wired wrapper',
        );
      },
    );

    test('each wrapper exposes the underlying CanonicalSink', () {
      final config = _buildConfig();
      final factories = _buildFactoriesWithProjector(
        config,
        canonicalFactPostCommitProjector: _stubProjector,
        canonicalFactPeriodResolver: _stubPeriodResolver,
        canonicalRestaurantIdResolver: _stubRestaurantIdResolver,
      );

      // Toast is always wired (no optional credentials needed).
      final toastWrapper = factories.projectingSinksByVendor['toast'];
      expect(toastWrapper, isNotNull);
      expect(
        toastWrapper!.underlying,
        isNotNull,
        reason:
            'wrapper must expose the underlying CanonicalSink so '
            'downstream consumers can introspect the wired stack',
      );
    });

    test(
      'projection taps cover direct adapter sinks, including reservations',
      () {
        final config = _buildConfig();
        final factories = _buildFactoriesWithProjector(
          config,
          canonicalFactPostCommitProjector: _stubProjector,
          canonicalFactPeriodResolver: _stubPeriodResolver,
          canonicalRestaurantIdResolver: _stubRestaurantIdResolver,
        );

        const expectedNoCredentialTapVendors = <String>{
          'toast',
          'aloha_ncr_voyix',
          'lightspeed_lsk',
          'oracle_micros_simphony',
          'revel',
          'adp',
          'agendrix',
          'humanity',
          'push_operations',
          'quickbooks_time',
          'seven_shifts',
          'libro',
          'opentable',
          'sevenrooms',
          'tock',
        };

        expect(
          factories.projectionTapsByVendor.keys.toSet(),
          containsAll(expectedNoCredentialTapVendors),
          reason:
              'direct adapter writes must have a tap, including the 4 '
              'reservation sinks whose CanonicalSink view is built per tenant',
        );
        expect(factories.projectionTapsByVendor, isNot(contains('clover')));
        expect(factories.projectionTapsByVendor, isNot(contains('square')));
        for (final vendor in expectedNoCredentialTapVendors) {
          expect(
            factories.projectionTapsByVendor[vendor],
            isA<CanonicalFactProjectionTap>(),
            reason: '$vendor must expose a drainable direct-write tap',
          );
        }
      },
    );
  });
}

Phase8VendorIntegrationFactories _buildFactoriesWithProjector(
  ProxyConfig config, {
  CanonicalFactPostCommitProjector? canonicalFactPostCommitProjector,
  CanonicalFactPeriodResolver? canonicalFactPeriodResolver,
  CanonicalRestaurantIdResolver? canonicalRestaurantIdResolver,
}) {
  final bindings = buildProxyProductionBindings(
    config,
    requireFirebase: false,
    expectedMigrationFilenames: const <String>[],
    postgresPoolFactory: (String _) => _StubPostgresPool(),
  );
  final wrapper = bindings.tenantTransactionWrapper;
  return buildPhase8VendorIntegrationFactoriesFromCredentials(
    tenantTransactionWrapper: wrapper,
    broker: VendorCredentialBroker(
      tenantWrapper: wrapper,
      pgcryptoEnvelopeKey: bindings.pgcryptoEnvelopeKey,
    ),
    locationConfigResolver: PerTenantLocationConfigResolver(
      wrapper,
      webhookPublicBaseUri: config.publicBaseUri,
    ),
    sharedHttpClient: http.Client(),
    webhookPublicBaseUri: config.publicBaseUri,
    canonicalFactPostCommitProjector: canonicalFactPostCommitProjector,
    canonicalFactPeriodResolver: canonicalFactPeriodResolver,
    canonicalRestaurantIdResolver: canonicalRestaurantIdResolver,
  );
}

ProxyConfig _buildConfig() {
  return ProxyConfig.fromEnvironment(<String, String>{
    ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
    ProxySecretNames.voyageApiKey: 'placeholder-voyage',
    ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
    ProxySecretNames.postgresAdminUrl:
        'postgres://admin-role.example/forgeflow',
    ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web-api-key',
    ProxySecretNames.servicePrincipalJwtSecret:
        'placeholder-service-principal-jwt-secret',
    ProxySecretNames.pgcryptoEnvelopeKey: 'placeholder-pgcrypto-envelope-key',
    ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
  });
}

class _StubPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw StateError('test pool must not open a real transaction');
  }
}

/// Stub projector — never invoked in these wiring-shape tests; kept as
/// a non-null sentinel so the wrap-each-sink branch fires.
final CanonicalFactPostCommitProjector _stubProjector =
    CanonicalFactPostCommitProjector(
      closedAggregator: _UnreachableClosedAggregator(),
      targetSnapshotResolver: _UnreachableTargetSnapshotResolver(),
      closedWriter: _UnreachableClosedWriter(),
      openProjector: _UnreachableOpenProjector(),
    );

FutureOr<CanonicalFactCommittedPeriod?> _stubPeriodResolver({
  required String operatorId,
  required String locationId,
  required IntegrationCategory category,
  required String vendorId,
  required String connectionId,
  required Map<String, Object?> canonicalFact,
}) => null;

FutureOr<String> _stubRestaurantIdResolver({
  required String operatorId,
  required String locationId,
}) => operatorId;

class _UnreachableClosedAggregator implements ClosedShiftPostCommitAggregator {
  @override
  Future<AggregatorResult?> aggregate(CanonicalFactCommittedPeriod period) {
    throw StateError('wiring-shape test must never invoke the aggregator');
  }
}

class _UnreachableTargetSnapshotResolver
    implements ClosedShiftTargetSnapshotResolver {
  @override
  Future<TargetSnapshot> resolveTargetSnapshot({
    required CanonicalFactPostCommitInput input,
    required CanonicalFactCommittedPeriod period,
    required AggregatorResult aggregateResult,
  }) {
    throw StateError(
      'wiring-shape test must never invoke the target-snapshot resolver',
    );
  }
}

class _UnreachableClosedWriter implements ClosedShiftPostCommitWriter {
  @override
  Future<void> write({
    required String operatorId,
    required String locationId,
    required ShiftFact shiftFact,
    required AggregatorProvenanceContext provenance,
  }) {
    throw StateError(
      'wiring-shape test must never invoke the closed-shift writer',
    );
  }
}

class _UnreachableOpenProjector implements OpenShiftPostCommitProjector {
  @override
  Future<OpenShiftProjectionResult> project({
    required CanonicalFactPostCommitInput input,
    required Iterable<CanonicalFactCommittedPeriod> periods,
  }) {
    throw StateError(
      'wiring-shape test must never invoke the open-shift projector',
    );
  }
}
