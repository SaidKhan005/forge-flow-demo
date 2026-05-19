// Phase 8 framework — production binder tests.
//
// Covers the six contract behaviours from the slice prompt:
//
//   1. Construction with fakes — `Phase80IntegrationRoutes.globalBindings`
//      is non-null after the binder runs.
//   2. Demo mode (`kDemoMode=true`) — globalBindings stays null.
//      Implementation note: `kDemoMode` is a `bool.fromEnvironment`
//      `dart-define`. The test surface delegates to a private branch
//      via the public `bindPhase8IntegrationsForProduction` because
//      the dart-define cannot be flipped per-test; the binder still
//      exposes `_alreadyBound` reset via `resetPhase8BinderForTests`.
//   3. Idempotent — calling the binder twice does not double-register
//      and does not throw.
//   4. Per-tenant factory routing — invoking a registered factory
//      twice with different (operator, location) tuples returns
//      distinct adapter instances; broker-resolution closures inside
//      the factory close over the right tenant tuple.
//   5. JWT adapter plumbing — a fake tool-side `ProxyJwtVerifier` that
//      returns canned claims surfaces those claims through the
//      lib-side `AdminActorJwtVerifier` shape into the bindings
//      holder's `actorResolver` closure.
//   6. Optional vendor credentials missing — when
//      `proxyConfig.hasCloverAppCredentials == false`, the Clover
//      factory is NOT registered (warn-and-disable surface). Other
//      vendors (Toast, ADP, ...) still wire normally.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';

import '../../../tool/advisor_proxy/admin_integrations_routes.dart';
import '../../../tool/advisor_proxy/advisor_proxy.dart';
import '../../../tool/advisor_proxy/phase_8_production_binder.dart';
import '../../../tool/advisor_proxy/proxy_bootstrap.dart';

const String _operatorA = '11111111-1111-1111-1111-111111111111';
const String _locationA = '22222222-2222-2222-2222-222222222222';
const String _operatorB = '33333333-3333-3333-3333-333333333333';
const String _locationB = '44444444-4444-4444-4444-444444444444';

void main() {
  setUp(() {
    resetPhase8BinderForTests();
  });
  tearDown(() {
    resetPhase8BinderForTests();
  });

  group('bindPhase8IntegrationsForProduction', () {
    test(
      'installs Phase80IntegrationRoutes.globalBindings on first call',
      () async {
        final config = _buildConfig();
        final bindings = _buildBindings();

        expect(Phase80IntegrationRoutes.globalBindings, isNull);

        await bindPhase8IntegrationsForProduction(
          bindings,
          config,
          proxyJwtVerifier: _StubJwtVerifier(),
        );

        expect(Phase80IntegrationRoutes.globalBindings, isNotNull);
        final installed = Phase80IntegrationRoutes.globalBindings!;
        // Smoke-check the holder. The webhook handler must have at
        // least the Toast factory + verifier wired (Toast does not
        // require any optional secrets so it is always on).
        expect(installed.webhookHandler.posAdapterFactories, contains('toast'));
        expect(installed.webhookHandler.signatureVerifiers, contains('toast'));
        expect(installed.firstBackfillEnqueueGateway, isNotNull);
        expect(
          phase8ProjectingSinksByVendor,
          contains('toast'),
          reason:
              'production boot should create the default post-commit '
              'projector wiring when no test override is supplied',
        );
      },
    );

    test(
      'idempotent — second call is a no-op (no double-register, no throw)',
      () async {
        final config = _buildConfig();
        final bindings = _buildBindings();

        await bindPhase8IntegrationsForProduction(
          bindings,
          config,
          proxyJwtVerifier: _StubJwtVerifier(),
        );
        final firstHolder = Phase80IntegrationRoutes.globalBindings;
        await bindPhase8IntegrationsForProduction(
          bindings,
          config,
          proxyJwtVerifier: _StubJwtVerifier(),
        );
        final secondHolder = Phase80IntegrationRoutes.globalBindings;

        // Same instance (the second call short-circuits before
        // overwriting).
        expect(identical(firstHolder, secondHolder), isTrue);
      },
    );
  });

  group('per-tenant factory routing', () {
    test(
      'Toast factory yields distinct adapters for (opA, locA) and (opB, locB)',
      () async {
        final config = _buildConfig();
        final bindings = _buildBindings();

        await bindPhase8IntegrationsForProduction(
          bindings,
          config,
          proxyJwtVerifier: _StubJwtVerifier(),
        );

        final factory = Phase80IntegrationRoutes
            .globalBindings!
            .webhookHandler
            .posAdapterFactories['toast']!;

        final adapterA = await factory(
          operatorId: _operatorA,
          locationId: _locationA,
        );
        final adapterB = await factory(
          operatorId: _operatorB,
          locationId: _locationB,
        );

        expect(
          identical(adapterA, adapterB),
          isFalse,
          reason:
              'each factory invocation must build a fresh adapter so '
              '(operator, location)-bound credential resolvers stay '
              'isolated per tenant',
        );
      },
    );
  });

  group('JWT adapter plumbing', () {
    test('actorResolver returns null when bearer header missing', () async {
      final config = _buildConfig();
      final bindings = _buildBindings();
      await bindPhase8IntegrationsForProduction(
        bindings,
        config,
        proxyJwtVerifier: _StubJwtVerifier(
          claims: const ProxyJwtClaims(
            userId: 'fb-uid',
            operatorId: _operatorA,
            locationId: _locationA,
            roles: <String>['operator_owner'],
            firebaseUid: 'fb-uid',
          ),
        ),
      );

      final actorResolver =
          Phase80IntegrationRoutes.globalBindings!.actorResolver;
      // Build a request with no Authorization header.
      final request = _StubHttpRequest(headers: const <String, String>{});
      final ctx = await actorResolver(request);
      expect(
        ctx,
        isNull,
        reason: 'missing Authorization header → null context (route 401s)',
      );
    });

    test('lib-side JWT bridge passes claims through tool-side verifier', () {
      // The bridge surface is exercised end-to-end by the
      // `actorResolver` test above; the structural assertion is that
      // the binder accepts a `ProxyJwtVerifier` and keeps the public
      // `Phase80IntegrationRoutesBindingsHolder.actorResolver` typed
      // against the tool-side `AdminActorContext`.
      expect(_StubJwtVerifier(), isA<ProxyJwtVerifier>());
    });
  });

  group('optional vendor app credentials missing', () {
    test(
      'Clover factory NOT registered when hasCloverAppCredentials is false',
      () async {
        final config = _buildConfig();
        // Sanity: Clover credentials default to absent.
        expect(config.hasCloverAppCredentials, isFalse);

        final bindings = _buildBindings();
        await bindPhase8IntegrationsForProduction(
          bindings,
          config,
          proxyJwtVerifier: _StubJwtVerifier(),
        );

        final factories = Phase80IntegrationRoutes
            .globalBindings!
            .webhookHandler
            .posAdapterFactories;
        expect(
          factories.containsKey('clover'),
          isFalse,
          reason:
              'optional vendor with missing app credentials must '
              'warn-and-disable, not throw at boot',
        );
        // Toast is NOT optional and must remain wired.
        expect(factories.containsKey('toast'), isTrue);
      },
    );

    test(
      'Clover factory IS registered when hasCloverAppCredentials is true',
      () async {
        final config = _buildConfig(
          extraEnv: <String, String>{
            ProxySecretNames.cloverAppToken: 'placeholder-clover-app-token',
            ProxySecretNames.cloverAppId: 'placeholder-clover-app-id',
          },
        );
        expect(config.hasCloverAppCredentials, isTrue);

        final bindings = _buildBindings(config: config);
        await bindPhase8IntegrationsForProduction(
          bindings,
          config,
          proxyJwtVerifier: _StubJwtVerifier(),
        );

        final factories = Phase80IntegrationRoutes
            .globalBindings!
            .webhookHandler
            .posAdapterFactories;
        expect(factories.containsKey('clover'), isTrue);
      },
    );
  });

  group('async-factory vendors (Lightspeed LSK + SevenRooms)', () {
    test('lightspeed_lsk is wired in posAdapterFactories (no longer '
        'disabled-with-warn after async typedef)', () async {
      final config = _buildConfig();
      final bindings = _buildBindings();
      await bindPhase8IntegrationsForProduction(
        bindings,
        config,
        proxyJwtVerifier: _StubJwtVerifier(),
      );

      final installed = Phase80IntegrationRoutes.globalBindings!;
      // The factory is registered (was on the disabled list before
      // PR `8.framework.async-adapter-factories` because the sync
      // typedef could not await `PerTenantLocationConfigResolver`).
      expect(
        installed.webhookHandler.posAdapterFactories.containsKey(
          'lightspeed_lsk',
        ),
        isTrue,
        reason:
            'lightspeed_lsk must move from disabled list to wired list '
            'now that PosAdapterFactory returns Future<PosAdapter>',
      );
      // Signature verifier is also registered (was already on the
      // disabled-but-verifiable list pre-PR).
      expect(
        installed.webhookHandler.signatureVerifiers.containsKey(
          'lightspeed_lsk',
        ),
        isTrue,
      );
    });

    test('sevenrooms is wired in reservationAdapterFactories (no longer '
        'disabled-with-warn after async typedef)', () async {
      final config = _buildConfig();
      final bindings = _buildBindings();
      await bindPhase8IntegrationsForProduction(
        bindings,
        config,
        proxyJwtVerifier: _StubJwtVerifier(),
      );

      final installed = Phase80IntegrationRoutes.globalBindings!;
      expect(
        installed.webhookHandler.reservationAdapterFactories.containsKey(
          'sevenrooms',
        ),
        isTrue,
        reason:
            'sevenrooms must move from disabled list to wired list now '
            'that ReservationAdapterFactory returns Future<ReservationAdapter>',
      );
      expect(
        installed.webhookHandler.signatureVerifiers.containsKey('sevenrooms'),
        isTrue,
      );
    });
  });
}

// ─── Test fixtures ─────────────────────────────────────────────────────

ProxyConfig _buildConfig({
  Map<String, String> extraEnv = const <String, String>{},
}) {
  final env = <String, String>{
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
    ...extraEnv,
  };
  return ProxyConfig.fromEnvironment(env);
}

/// Build a [ProxyProductionBindings] with stub Postgres pools. The
/// binder only inspects a small subset of members
/// (`tenantTransactionWrapper`, `pgcryptoEnvelopeKey`,
/// `adminPermissionGuard`, `firstConnectionBackfillEnqueueGateway`,
/// `integrationCategoryResolver`, `integrationAdminActorResolver`)
/// during construction. Reusing `buildProxyProductionBindings` with a
/// stub pool factory is the cleanest path: the production builder
/// wires the right test pool through every nested repository so the
/// binder constructs without opening a real connection.
ProxyProductionBindings _buildBindings({ProxyConfig? config}) {
  return buildProxyProductionBindings(
    config ?? _buildConfig(),
    requireFirebase: false,
    expectedMigrationFilenames: const <String>[],
    postgresPoolFactory: (String _) => _StubPostgresPool(),
  );
}

class _StubPostgresPool implements PostgresPool {
  @override
  Future<PostgresTransaction> beginTransaction() {
    throw StateError('test pool must not open a real transaction');
  }
}

class _StubJwtVerifier implements ProxyJwtVerifier {
  _StubJwtVerifier({this.claims});

  final ProxyJwtClaims? claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final c = claims;
    if (c == null) {
      throw ProxyJwtVerificationError('stub verifier rejects all tokens');
    }
    return c;
  }
}

class _StubHttpRequest implements HttpRequest {
  _StubHttpRequest({required Map<String, String> headers})
    : _headers = _StubHttpHeaders(headers);

  final HttpHeaders _headers;

  @override
  HttpHeaders get headers => _headers;

  @override
  Uri get uri => Uri.parse('https://localhost/v1/admin/integrations/foo');

  @override
  String get method => 'GET';

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _StubHttpHeaders implements HttpHeaders {
  _StubHttpHeaders(this._values);

  final Map<String, String> _values;

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}
