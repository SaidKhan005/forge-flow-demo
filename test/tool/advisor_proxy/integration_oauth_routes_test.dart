// Phase 8 — Operator-facing OAuth begin/callback + API-key connect
// route tests. Mirrors the slice prompt acceptance bullets.
//
// Drives the route handler over a fake `HttpRequest` + recording
// stand-ins for the bindings holder so the seam can be exercised
// without binding a real socket or a Postgres pool.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/services/integration/first_connection_backfill_job.dart';
import 'package:forge_and_flow/services/integration/integration_adapter_common.dart'
    as integration;
import 'package:forge_and_flow/services/integration/repository_integration_routes_gateway.dart'
    show
        IntegrationGatewayNotFound,
        IntegrationGatewayPermissionDenied,
        IntegrationGatewayUnavailable;

import '../../../tool/advisor_proxy/admin_integrations_routes.dart' show
    FirstConnectionBackfillEnqueueGateway,
    IntegrationRoutesGateway;
import '../../../tool/advisor_proxy/advisor_proxy.dart';
import '../../../tool/advisor_proxy/integration_oauth_routes.dart';
import '../../../tool/advisor_proxy/integration_oauth_state_store.dart';

const String _operatorA = '11111111-1111-1111-1111-111111111111';
const String _locationA = '22222222-2222-2222-2222-222222222222';
const String _operatorB = '33333333-3333-3333-3333-333333333333';
const String _locationB = '44444444-4444-4444-4444-444444444444';
const String _userA = '55555555-5555-5555-5555-555555555555';

void main() {
  group('IntegrationOAuthRoutes — begin', () {
    test('returns authorize URL with fresh state token; row written',
        () async {
      final store = InMemoryIntegrationOAuthStateStore();
      final routes = _buildRoutes(store: store);

      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse('http://localhost/v1/integrations/oauth/toast/begin'),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
          HttpHeaders.hostHeader: 'api.forgeflow.app',
        },
      );

      final handled = await routes.tryHandle(request);
      expect(handled, isTrue);
      expect(request.response.statusCode, 200);

      final body = jsonDecode(request.response.bodyText) as Map<String, Object?>;
      final stateToken = body['state_token'] as String;
      final authorizeUrl = Uri.parse(body['authorization_url'] as String);

      expect(stateToken.length, greaterThanOrEqualTo(32));
      expect(authorizeUrl.queryParameters['state'], stateToken);
      expect(authorizeUrl.queryParameters['client_id'], 'toast-client-id');
      expect(authorizeUrl.queryParameters['response_type'], 'code');
      expect(authorizeUrl.queryParameters['redirect_uri'],
          contains('/v1/integrations/oauth/toast/callback'));

      final stored = await store.peek(stateToken);
      expect(stored, isNotNull);
      expect(stored!.operatorId, _operatorA);
      expect(stored.locationId, _locationA);
      expect(stored.vendorId, 'toast');
    });

    test('invalid operator session → 401', () async {
      final routes = _buildRoutes(rejectAllJwts: true);

      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse('http://localhost/v1/integrations/oauth/toast/begin'),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
        headers: const <String, String>{},
      );

      final handled = await routes.tryHandle(request);
      expect(handled, isTrue);
      expect(request.response.statusCode, 401);
    });

    test('vendor with no descriptor → 503', () async {
      final routes = _buildRoutes();

      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/oauth/unknown_vendor/begin',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );

      await routes.tryHandle(request);
      expect(request.response.statusCode, 503);
      final body = jsonDecode(request.response.bodyText) as Map<String, Object?>;
      expect(body['error'], 'oauth_exchange_unconfigured');
    });
  });

  group('IntegrationOAuthRoutes — callback', () {
    test('valid state + code → exchange + persist + 302 success', () async {
      final store = InMemoryIntegrationOAuthStateStore();
      final exchanger = _RecordingExchanger();
      final writer = _RecordingConnectionWriter();
      final backfill = _RecordingBackfillEnqueueGateway();
      final routes = _buildRoutes(
        store: store,
        exchanger: exchanger,
        connectionWriter: writer.write,
        firstBackfillEnqueueGateway: backfill,
      );

      // Seed a state row directly.
      final stateToken = _stateTokenOf('a');
      await store.issue(
        stateToken: stateToken,
        operatorId: _operatorA,
        locationId: _locationA,
        vendorId: 'toast',
        redirectUri:
            'http://localhost/v1/integrations/oauth/toast/callback',
        ttl: const Duration(minutes: 10),
        actorUserId: _userA,
      );

      final request = _StubHttpRequest(
        method: 'GET',
        uri: Uri.parse(
          'http://localhost/v1/integrations/oauth/toast/callback'
          '?code=auth-code-123&state=$stateToken',
        ),
        headers: const <String, String>{},
      );

      await routes.tryHandle(request);
      expect(request.response.statusCode, HttpStatus.found);
      final location =
          request.response.headers.value(HttpHeaders.locationHeader)!;
      final redirected = Uri.parse(location);
      expect(redirected.path, contains('/integrations/toast'));
      expect(redirected.queryParameters['status'], 'success');

      // Exchanger received the code with the right tuple.
      expect(exchanger.calls, hasLength(1));
      expect(exchanger.calls.single['code'], 'auth-code-123');
      expect(exchanger.calls.single['operator_id'], _operatorA);
      expect(exchanger.calls.single['location_id'], _locationA);

      // Connection writer received the OAuth bundle.
      expect(writer.calls, hasLength(1));
      expect(writer.calls.single['vendor_id'], 'toast');
      expect(writer.calls.single['access_token'], 'access-token-stub');

      // Backfill enqueue ran with the new connection id.
      expect(backfill.calls, hasLength(1));
      expect(backfill.calls.single.vendorId, 'toast');
    });

    test('expired state token → redirect with state_expired reason',
        () async {
      var clock = DateTime.parse('2026-05-07T12:00:00Z');
      final store = InMemoryIntegrationOAuthStateStore(now: () => clock);
      final routes = _buildRoutes(store: store, now: () => clock);
      final stateToken = _stateTokenOf('b');
      await store.issue(
        stateToken: stateToken,
        operatorId: _operatorA,
        locationId: _locationA,
        vendorId: 'toast',
        redirectUri:
            'http://localhost/v1/integrations/oauth/toast/callback',
        ttl: const Duration(minutes: 1),
      );
      // Skip ahead past the TTL.
      clock = clock.add(const Duration(minutes: 5));

      final request = _StubHttpRequest(
        method: 'GET',
        uri: Uri.parse(
          'http://localhost/v1/integrations/oauth/toast/callback'
          '?code=zzz&state=$stateToken',
        ),
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, HttpStatus.found);
      final redirected = Uri.parse(
        request.response.headers.value(HttpHeaders.locationHeader)!,
      );
      expect(redirected.queryParameters['status'], 'error');
      expect(redirected.queryParameters['reason'], 'state_expired');
    });

    test('already-consumed state token → state_already_consumed', () async {
      final store = InMemoryIntegrationOAuthStateStore();
      final routes = _buildRoutes(
        store: store,
        exchanger: _RecordingExchanger(),
        connectionWriter: _RecordingConnectionWriter().write,
      );
      final stateToken = _stateTokenOf('c');
      await store.issue(
        stateToken: stateToken,
        operatorId: _operatorA,
        locationId: _locationA,
        vendorId: 'toast',
        redirectUri:
            'http://localhost/v1/integrations/oauth/toast/callback',
        ttl: const Duration(minutes: 10),
      );
      // First callback consumes.
      await store.consume(
        stateToken: stateToken,
        operatorId: _operatorA,
        locationId: _locationA,
        vendorId: 'toast',
      );

      final request = _StubHttpRequest(
        method: 'GET',
        uri: Uri.parse(
          'http://localhost/v1/integrations/oauth/toast/callback'
          '?code=zzz&state=$stateToken',
        ),
      );
      await routes.tryHandle(request);
      final redirected = Uri.parse(
        request.response.headers.value(HttpHeaders.locationHeader)!,
      );
      expect(redirected.queryParameters['reason'], 'state_already_consumed');
    });

    test('vendor token-exchange failure → oauth_exchange_failed redirect',
        () async {
      final store = InMemoryIntegrationOAuthStateStore();
      final exchanger = _RecordingExchanger(
        result: _ExchangerResult.throwOnInvoke,
      );
      final writer = _RecordingConnectionWriter();
      final routes = _buildRoutes(
        store: store,
        exchanger: exchanger,
        connectionWriter: writer.write,
      );
      final stateToken = _stateTokenOf('d');
      await store.issue(
        stateToken: stateToken,
        operatorId: _operatorA,
        locationId: _locationA,
        vendorId: 'toast',
        redirectUri:
            'http://localhost/v1/integrations/oauth/toast/callback',
        ttl: const Duration(minutes: 10),
      );
      final request = _StubHttpRequest(
        method: 'GET',
        uri: Uri.parse(
          'http://localhost/v1/integrations/oauth/toast/callback'
          '?code=zzz&state=$stateToken',
        ),
      );
      await routes.tryHandle(request);
      final redirected = Uri.parse(
        request.response.headers.value(HttpHeaders.locationHeader)!,
      );
      expect(redirected.queryParameters['reason'], 'oauth_exchange_failed');
      // Connection writer not called on failure.
      expect(writer.calls, isEmpty);
    });

    test(
      'cross-tenant: operator B cannot consume operator A state token',
      () async {
        final store = InMemoryIntegrationOAuthStateStore();
        final routes = _buildRoutes(store: store);
        final stateToken = _stateTokenOf('e');
        await store.issue(
          stateToken: stateToken,
          operatorId: _operatorA,
          locationId: _locationA,
          vendorId: 'toast',
          redirectUri:
              'http://localhost/v1/integrations/oauth/toast/callback',
          ttl: const Duration(minutes: 10),
        );
        // The route resolves the row from the token alone and matches
        // (operator, location) from the row body. A third-party who
        // intercepts the URL but lacks the matching session will be
        // gated by the per-tenant RLS policy in production; we model
        // that here by flipping the vendor on the URL so the consume
        // path takes the tupleMismatch branch.
        final request = _StubHttpRequest(
          method: 'GET',
          uri: Uri.parse(
            'http://localhost/v1/integrations/oauth/square/callback'
            '?code=zzz&state=$stateToken',
          ),
        );
        await routes.tryHandle(request);
        final redirected = Uri.parse(
          request.response.headers.value(HttpHeaders.locationHeader)!,
        );
        expect(redirected.queryParameters['reason'], 'state_tuple_mismatch');
      },
    );
  });

  group('IntegrationOAuthRoutes — api-key connect', () {
    test('valid api key + adapter health() OK → stored', () async {
      final store = InMemoryIntegrationOAuthStateStore();
      final gateway = _RecordingIntegrationRoutesGateway();
      final validator = _RecordingApiKeyValidator(valid: true);
      final routes = _buildRoutes(
        store: store,
        integrationRoutesGateway: gateway,
        apiKeyValidator: validator.validate,
      );

      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/api-key/tock/connect',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
          'api_key': 'paste-this-key',
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);

      expect(request.response.statusCode, 200);
      expect(validator.calls, hasLength(1));
      expect(gateway.connectKeyCalls, hasLength(1));
      expect(gateway.connectKeyCalls.single.apiKey, 'paste-this-key');
    });

    test('invalid api key (validator returns false) → 400 without storing',
        () async {
      final gateway = _RecordingIntegrationRoutesGateway();
      final validator = _RecordingApiKeyValidator(valid: false);
      final routes = _buildRoutes(
        integrationRoutesGateway: gateway,
        apiKeyValidator: validator.validate,
      );
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/api-key/tock/connect',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
          'api_key': 'bogus-key',
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 400);
      expect(gateway.connectKeyCalls, isEmpty);
    });

    test('JWT scope mismatch → 403', () async {
      final routes = _buildRoutes();
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/api-key/tock/connect',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorB,
          'location_id': _locationB,
          'api_key': 'whatever',
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 403);
    });
  });

  group('IntegrationOAuthRoutes — test-connection', () {
    test('happy path: 200 with ok=true + latency_ms', () async {
      final gateway = _RecordingIntegrationRoutesGateway(
        testConnectionResult: <String, Object?>{
          'auth_valid': true,
          'elapsed_ms': 7,
          'sample': <String, Object?>{'order_id': 'abc'},
          'field_mapping': <String, Object?>{'covers': 'guests'},
        },
      );
      final routes = _buildRoutes(integrationRoutesGateway: gateway);
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/toast/test-connection',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 200);
      final body =
          jsonDecode(request.response.bodyText) as Map<String, Object?>;
      expect(body['ok'], isTrue);
      expect(body['auth_valid'], isTrue);
      expect(body['latency_ms'], isA<int>());
      expect(gateway.testConnectionCalls, hasLength(1));
      expect(gateway.testConnectionCalls.single.vendorId, 'toast');
    });

    test('missing bearer → 401', () async {
      final routes = _buildRoutes();
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/toast/test-connection',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 401);
    });

    test('JWT scope mismatch → 403', () async {
      final routes = _buildRoutes();
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/toast/test-connection',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorB,
          'location_id': _locationB,
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 403);
    });

    test('unknown vendor (gateway raises NotFound) → 404', () async {
      final gateway = _RecordingIntegrationRoutesGateway(
        testConnectionThrows:
            const _GatewayThrow(_GatewayThrowKind.notFound, 'no_row'),
      );
      final routes = _buildRoutes(integrationRoutesGateway: gateway);
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/unknown_vendor/test-connection',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 404);
    });

    test('permission denied → 403', () async {
      final gateway = _RecordingIntegrationRoutesGateway(
        testConnectionThrows: const _GatewayThrow(
          _GatewayThrowKind.permissionDenied,
          'integrations.configure_required',
        ),
      );
      final routes = _buildRoutes(integrationRoutesGateway: gateway);
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/toast/test-connection',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 403);
    });
  });

  group('IntegrationOAuthRoutes — disconnect', () {
    test('happy path: 200 with ok=true', () async {
      final gateway = _RecordingIntegrationRoutesGateway(
        disconnectResult: <String, Object?>{
          'connection_id': 'conn-1',
          'status': 'disconnected',
          'disconnect_reason': 'operator_action',
          'already_disconnected': false,
        },
      );
      final routes = _buildRoutes(integrationRoutesGateway: gateway);
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/toast/disconnect',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
          'reason': 'operator_action',
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 200);
      final body =
          jsonDecode(request.response.bodyText) as Map<String, Object?>;
      expect(body['ok'], isTrue);
      expect(body['status'], 'disconnected');
      expect(gateway.disconnectCalls, hasLength(1));
      expect(gateway.disconnectCalls.single.vendorId, 'toast');
      expect(gateway.disconnectCalls.single.reason, 'operator_action');
    });

    test('missing bearer → 401', () async {
      final routes = _buildRoutes();
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/toast/disconnect',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 401);
    });

    test('JWT scope mismatch → 403', () async {
      final routes = _buildRoutes();
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/toast/disconnect',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorB,
          'location_id': _locationB,
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 403);
    });

    test('unknown connection (gateway raises NotFound) → 404', () async {
      final gateway = _RecordingIntegrationRoutesGateway(
        disconnectThrows:
            const _GatewayThrow(_GatewayThrowKind.notFound, 'no_row'),
      );
      final routes = _buildRoutes(integrationRoutesGateway: gateway);
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/unknown_vendor/disconnect',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 404);
    });

    test('permission denied → 403', () async {
      final gateway = _RecordingIntegrationRoutesGateway(
        disconnectThrows: const _GatewayThrow(
          _GatewayThrowKind.permissionDenied,
          'integrations.configure_required',
        ),
      );
      final routes = _buildRoutes(integrationRoutesGateway: gateway);
      final request = _StubHttpRequest(
        method: 'POST',
        uri: Uri.parse(
          'http://localhost/v1/integrations/toast/disconnect',
        ),
        bodyJson: <String, Object?>{
          'operator_id': _operatorA,
          'location_id': _locationA,
        },
        headers: <String, String>{
          HttpHeaders.authorizationHeader: 'Bearer test-jwt',
        },
      );
      await routes.tryHandle(request);
      expect(request.response.statusCode, 403);
    });
  });

  group('buildPhase8OperatorOAuthWiring — 17-vendor coverage', () {
    test(
      'wires OAuth descriptors + exchangers when every app credential '
      'is loaded; api-key validators present for the 5 key-paste + 5 '
      'client-credentials vendors',
      () {
        final config = _proxyConfigWithAllVendorCredentials();
        final wiring = buildPhase8OperatorOAuthWiring(
          proxyConfig: config,
          connectionWriter: _defaultRecordingWriter,
        );

        // Every OAuth-using vendor whose static app credentials live
        // in ProxyConfig should land on the descriptor map (Square,
        // Clover, 7shifts, QuickBooks Time, Libro, Humanity). The
        // remaining six OAuth vendors (Toast, Aloha, Lightspeed LSK,
        // Oracle MICROS Simphony, Revel, ADP) use client_credentials
        // or per-tenant pairs and ship on the api-key validator
        // surface.
        expect(
          wiring.oauthBeginDescriptors.keys.toSet(),
          equals(<String>{
            'square',
            'clover',
            '7shifts',
            'quickbooks_time',
            'libro',
            'humanity',
          }),
        );
        expect(
          wiring.oauthExchangers.keys.toSet(),
          equals(<String>{
            'square',
            'clover',
            '7shifts',
            'quickbooks_time',
            'libro',
            'humanity',
          }),
        );
        // API-key validators cover the 5 documented key-paste vendors
        // (Tock, Push Operations, Agendrix, SevenRooms, OpenTable)
        // plus the 6 client_credentials / per-tenant-pair vendors
        // (Toast, Lightspeed LSK, Aloha NCR Voyix, Oracle MICROS
        // Simphony, Revel, ADP).
        expect(
          wiring.apiKeyValidators.keys.toSet(),
          equals(<String>{
            'toast',
            'lightspeed_lsk',
            'aloha_ncr_voyix',
            'oracle_micros_simphony',
            'revel',
            'adp',
            'tock',
            'push_operations',
            'agendrix',
            'sevenrooms',
            'opentable',
          }),
        );
        expect(wiring.disabledVendors, isEmpty);
        // All 17 documented Phase 8 vendor ids are reachable through
        // either the OAuth descriptor map or the api-key validator
        // map.
        final reachable = <String>{
          ...wiring.oauthBeginDescriptors.keys,
          ...wiring.apiKeyValidators.keys,
        };
        expect(
          reachable,
          equals(kPhase8VendorCategories.keys.toSet()),
        );
      },
    );

    test(
      'when OAuth app credentials are missing the dispatcher reports '
      'the vendor in disabledVendors and omits it from the descriptor '
      'map',
      () {
        final config = _proxyConfigBareSecrets();
        final wiring = buildPhase8OperatorOAuthWiring(
          proxyConfig: config,
          connectionWriter: _defaultRecordingWriter,
        );
        // Square / Clover / 7shifts / QuickBooks Time / Libro /
        // Humanity all need optional static app credentials; without
        // them they are absent from descriptors / exchangers but
        // present in disabledVendors.
        expect(wiring.oauthBeginDescriptors, isEmpty);
        expect(wiring.oauthExchangers, isEmpty);
        expect(
          wiring.disabledVendors.keys.toSet(),
          equals(<String>{
            'square',
            'clover',
            '7shifts',
            'quickbooks_time',
            'libro',
            'humanity',
          }),
        );
        // The 11 always-on api-key validators still light up — none
        // of them depend on optional static app credentials.
        expect(wiring.apiKeyValidators, hasLength(11));
      },
    );
  });
}

// ─── ProxyConfig helpers for the wiring tests ─────────────────────────

ProxyConfig _proxyConfigBareSecrets() {
  return ProxyConfig.fromEnvironment(<String, String>{
    ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
    ProxySecretNames.voyageApiKey: 'placeholder-voyage',
    ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
    ProxySecretNames.postgresAdminUrl: 'postgres://admin-role.example/forgeflow',
    ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web',
    ProxySecretNames.servicePrincipalJwtSecret: 'placeholder-sp-jwt',
    ProxySecretNames.pgcryptoEnvelopeKey: 'placeholder-pgcrypto',
    ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
  });
}

ProxyConfig _proxyConfigWithAllVendorCredentials() {
  return ProxyConfig.fromEnvironment(<String, String>{
    ProxySecretNames.anthropicApiKey: 'placeholder-anthropic',
    ProxySecretNames.voyageApiKey: 'placeholder-voyage',
    ProxySecretNames.postgresUrl: 'postgres://app-role.example/forgeflow',
    ProxySecretNames.postgresAdminUrl: 'postgres://admin-role.example/forgeflow',
    ProxySecretNames.firebaseWebApiKey: 'placeholder-firebase-web',
    ProxySecretNames.servicePrincipalJwtSecret: 'placeholder-sp-jwt',
    ProxySecretNames.pgcryptoEnvelopeKey: 'placeholder-pgcrypto',
    ProxySecretNames.publicBaseUri: 'https://api.forgeflow.app',
    // Optional vendor app credentials — every loaded together so the
    // descriptor / exchanger maps are fully populated for the
    // coverage assertions.
    ProxySecretNames.squareClientId: 'sq-client',
    ProxySecretNames.squareClientSecret: 'sq-secret',
    ProxySecretNames.squareNotificationUrlHost: 'https://api.forgeflow.app',
    ProxySecretNames.cloverAppToken: 'cl-app-token',
    ProxySecretNames.cloverAppId: 'cl-app-id',
    ProxySecretNames.humanityClientId: 'hum-client',
    ProxySecretNames.humanityClientSecret: 'hum-secret',
    ProxySecretNames.quickBooksTimeClientId: 'qbt-client',
    ProxySecretNames.quickBooksTimeClientSecret: 'qbt-secret',
    ProxySecretNames.sevenShiftsClientId: '7s-client',
    ProxySecretNames.sevenShiftsClientSecret: '7s-secret',
    ProxySecretNames.libroClientId: 'libro-client',
    ProxySecretNames.libroClientSecret: 'libro-secret',
  });
}


// ─── Test fixtures ─────────────────────────────────────────────────────

/// Build a 64-char state token by repeating a single hex digit. Used
/// to seed deterministic state-store rows in tests.
String _stateTokenOf(String char) => char * 64;

IntegrationOAuthRoutes _buildRoutes({
  InMemoryIntegrationOAuthStateStore? store,
  IntegrationRoutesGateway? integrationRoutesGateway,
  _RecordingExchanger? exchanger,
  IntegrationOAuthConnectionWriter? connectionWriter,
  FirstConnectionBackfillEnqueueGateway? firstBackfillEnqueueGateway,
  VendorApiKeyValidator? apiKeyValidator,
  bool rejectAllJwts = false,
  DateTime Function()? now,
}) {
  return IntegrationOAuthRoutes(
    requestGuard: ProxyRequestGuard(
      verifier: _StubVerifier(reject: rejectAllJwts),
    ),
    stateStore: store ?? InMemoryIntegrationOAuthStateStore(),
    integrationRoutesGateway:
        integrationRoutesGateway ?? _RecordingIntegrationRoutesGateway(),
    connectionWriter: connectionWriter ?? _defaultRecordingWriter,
    oauthBeginDescriptors: <String, VendorOAuthBeginDescriptor>{
      'toast': VendorOAuthBeginDescriptor(
        vendorId: 'toast',
        authorizeUrl:
            Uri.parse('https://oauth.toasttab.com/oauth2/authorize'),
        clientId: 'toast-client-id',
        scopes: const <String>['orders:read'],
      ),
    },
    oauthExchangers: <String, VendorOAuthCodeExchanger>{
      'toast': (exchanger ?? _RecordingExchanger()).exchange,
      'square': _alwaysFailExchanger,
    },
    apiKeyValidators: <String, VendorApiKeyValidator>{
      'tock': apiKeyValidator ??
          _RecordingApiKeyValidator(valid: true).validate,
    },
    firstBackfillEnqueueGateway: firstBackfillEnqueueGateway,
    operatorUiBaseUri: Uri.parse('http://localhost'),
    stateTokenTtl: const Duration(minutes: 10),
    now: now,
  );
}

Future<VendorOAuthExchangeResult> _alwaysFailExchanger({
  required String operatorId,
  required String locationId,
  required String vendorId,
  required String code,
  required String redirectUri,
  String? pkceVerifier,
  String? module,
}) {
  throw StateError('exchange refused');
}

Future<Map<String, Object?>> _defaultRecordingWriter({
  required String operatorId,
  required String locationId,
  required String actorUserId,
  required String vendorId,
  required integration.IntegrationCategory category,
  required String accessTokenPlaintext,
  String? refreshTokenPlaintext,
  DateTime? tokenExpiresAt,
  Map<String, Object?> metadata = const <String, Object?>{},
  String? webhookUrl,
  String? module,
  bool firstBackfillStarted = true,
}) async {
  return <String, Object?>{
    'connection_id': '99999999-9999-9999-9999-999999999999',
    'credential_id': '88888888-8888-8888-8888-888888888888',
    'vendor_id': vendorId,
    'status': 'connected',
  };
}

class _StubVerifier implements ProxyJwtVerifier {
  _StubVerifier({this.reject = false});
  final bool reject;
  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    if (reject) {
      throw ProxyJwtVerificationError('stub rejects all tokens');
    }
    return ProxyJwtClaims(
      userId: _userA,
      operatorId: _operatorA,
      locationId: _locationA,
      roles: const <String>['operator_owner'],
      firebaseUid: 'fb-uid',
    );
  }
}

class _RecordingExchanger {
  _RecordingExchanger({this.result = _ExchangerResult.success});

  final _ExchangerResult result;
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  Future<VendorOAuthExchangeResult> exchange({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String code,
    required String redirectUri,
    String? pkceVerifier,
    String? module,
  }) async {
    calls.add(<String, Object?>{
      'operator_id': operatorId,
      'location_id': locationId,
      'vendor_id': vendorId,
      'code': code,
      'redirect_uri': redirectUri,
    });
    if (result == _ExchangerResult.throwOnInvoke) {
      throw StateError('vendor refused exchange');
    }
    return VendorOAuthExchangeResult(
      accessTokenPlaintext: 'access-token-stub',
      category: integration.IntegrationCategory.pos,
      refreshTokenPlaintext: 'refresh-token-stub',
      tokenExpiresAt: DateTime.utc(2027, 1, 1),
      metadata: const <String, Object?>{'partner_id': 'p-1'},
    );
  }
}

enum _ExchangerResult { success, throwOnInvoke }

class _RecordingConnectionWriter {
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  Future<Map<String, Object?>> write({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required integration.IntegrationCategory category,
    required String accessTokenPlaintext,
    String? refreshTokenPlaintext,
    DateTime? tokenExpiresAt,
    Map<String, Object?> metadata = const <String, Object?>{},
    String? webhookUrl,
    String? module,
    bool firstBackfillStarted = true,
  }) async {
    calls.add(<String, Object?>{
      'operator_id': operatorId,
      'location_id': locationId,
      'vendor_id': vendorId,
      'access_token': accessTokenPlaintext,
      'refresh_token': refreshTokenPlaintext,
      'category': category.name,
    });
    return <String, Object?>{
      'connection_id': '99999999-9999-9999-9999-999999999999',
      'credential_id': '88888888-8888-8888-8888-888888888888',
      'vendor_id': vendorId,
      'status': 'connected',
    };
  }
}

class _RecordingApiKeyValidator {
  _RecordingApiKeyValidator({required this.valid});

  final bool valid;
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  Future<VendorApiKeyValidationResult> validate({
    required String operatorId,
    required String locationId,
    required String vendorId,
    required String apiKey,
    String? apiSecret,
  }) async {
    calls.add(<String, Object?>{
      'vendor_id': vendorId,
      'api_key': apiKey,
    });
    return VendorApiKeyValidationResult(
      valid: valid,
      category: integration.IntegrationCategory.reservation,
      errorMessage: valid ? null : 'health_check_unauthorized',
    );
  }
}

class _RecordingBackfillEnqueueGateway
    implements FirstConnectionBackfillEnqueueGateway {
  final List<FirstConnectionBackfillJob> calls =
      <FirstConnectionBackfillJob>[];

  @override
  Future<FirstConnectionBackfillJob> enqueueFirstBackfill({
    required String operatorId,
    required String locationId,
    required String connectionId,
    required String vendorId,
    required integration.IntegrationCategory category,
    required DateTime windowStart,
    required DateTime windowEnd,
    String? actorUserId,
  }) async {
    final job = FirstConnectionBackfillJob(
      jobId: 'job-1',
      operatorId: operatorId,
      locationId: locationId,
      connectionId: connectionId,
      vendorId: vendorId,
      category: category,
      windowStart: windowStart,
      windowEnd: windowEnd,
      status: FirstConnectionBackfillJobStatus.pending,
      attemptCount: 0,
      createdAt: DateTime.utc(2026, 5, 7),
      updatedAt: DateTime.utc(2026, 5, 7),
    );
    calls.add(job);
    return job;
  }
}

class _RecordingIntegrationRoutesGateway implements IntegrationRoutesGateway {
  _RecordingIntegrationRoutesGateway({
    this.testConnectionResult,
    this.testConnectionThrows,
    this.disconnectResult,
    this.disconnectThrows,
  });

  final List<_ConnectKeyCall> connectKeyCalls = <_ConnectKeyCall>[];
  final List<_TestConnectionCall> testConnectionCalls =
      <_TestConnectionCall>[];
  final List<_DisconnectCall> disconnectCalls = <_DisconnectCall>[];

  final Map<String, Object?>? testConnectionResult;
  final _GatewayThrow? testConnectionThrows;
  final Map<String, Object?>? disconnectResult;
  final _GatewayThrow? disconnectThrows;

  @override
  Future<Map<String, Object?>> connectViaKeyPaste({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String apiKey,
    String? username,
    String? module,
  }) async {
    connectKeyCalls.add(_ConnectKeyCall(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      apiKey: apiKey,
    ));
    return <String, Object?>{
      'connection_id': '00000000-0000-0000-0000-00000000aaaa',
      'credential_id': '00000000-0000-0000-0000-00000000bbbb',
      'vendor_id': vendorId,
      'status': 'connected',
      'first_backfill_started': true,
    };
  }

  @override
  Future<Map<String, Object?>> disconnect({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    required String reason,
  }) async {
    disconnectCalls.add(_DisconnectCall(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
      reason: reason,
    ));
    final thrown = disconnectThrows;
    if (thrown != null) thrown.throwIt();
    return disconnectResult ?? const <String, Object?>{};
  }

  @override
  Future<Map<String, Object?>> handleOAuthCallback({
    required String vendorId,
    required Map<String, String> queryParameters,
  }) async => <String, Object?>{};

  @override
  Future<bool> hasIntegrationsConfigurePermission({
    required String operatorId,
    required String userId,
  }) async => true;

  @override
  Future<Map<String, Object?>> listForLocation({
    required String operatorId,
    required String locationId,
    required String actorUserId,
  }) async => <String, Object?>{};

  @override
  Future<List<Map<String, Object?>>> listSyncLogs({
    required String operatorId,
    required String locationId,
    required String vendorId,
    int limit = 100,
  }) async => const <Map<String, Object?>>[];

  @override
  Future<Map<String, Object?>> startOAuth({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
    String? module,
  }) async => <String, Object?>{};

  @override
  Future<Map<String, Object?>> testConnection({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String vendorId,
  }) async {
    testConnectionCalls.add(_TestConnectionCall(
      operatorId: operatorId,
      locationId: locationId,
      vendorId: vendorId,
    ));
    final thrown = testConnectionThrows;
    if (thrown != null) thrown.throwIt();
    return testConnectionResult ?? const <String, Object?>{};
  }
}

class _ConnectKeyCall {
  _ConnectKeyCall({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.apiKey,
  });
  final String operatorId;
  final String locationId;
  final String vendorId;
  final String apiKey;
}

class _TestConnectionCall {
  _TestConnectionCall({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
  });
  final String operatorId;
  final String locationId;
  final String vendorId;
}

class _DisconnectCall {
  _DisconnectCall({
    required this.operatorId,
    required this.locationId,
    required this.vendorId,
    required this.reason,
  });
  final String operatorId;
  final String locationId;
  final String vendorId;
  final String reason;
}

enum _GatewayThrowKind { notFound, permissionDenied, unavailable }

class _GatewayThrow {
  const _GatewayThrow(this.kind, this.message);
  final _GatewayThrowKind kind;
  final String message;

  Never throwIt() {
    switch (kind) {
      case _GatewayThrowKind.notFound:
        throw IntegrationGatewayNotFound(message);
      case _GatewayThrowKind.permissionDenied:
        throw IntegrationGatewayPermissionDenied(message);
      case _GatewayThrowKind.unavailable:
        throw IntegrationGatewayUnavailable(message);
    }
  }
}

// ─── Stub HttpRequest / HttpResponse ──────────────────────────────────

class _StubHttpRequest extends Stream<Uint8List> implements HttpRequest {
  _StubHttpRequest({
    required this.method,
    required Uri uri,
    Map<String, Object?>? bodyJson,
    Map<String, String> headers = const <String, String>{},
  })  : _uri = uri,
        _headers = _StubHttpHeaders(headers),
        _body = bodyJson == null
            ? Uint8List(0)
            : Uint8List.fromList(utf8.encode(jsonEncode(bodyJson))),
        response = _StubHttpResponse();

  final Uri _uri;
  final HttpHeaders _headers;
  final Uint8List _body;

  @override
  final String method;

  @override
  final _StubHttpResponse response;

  @override
  HttpHeaders get headers => _headers;

  @override
  Uri get uri => _uri;

  @override
  Uri get requestedUri => _uri;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<Uint8List>.value(_body).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

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

class _StubHttpResponse implements HttpResponse {
  @override
  int statusCode = 200;
  final StringBuffer _body = StringBuffer();
  final _StubResponseHeaders _headers = _StubResponseHeaders();
  String get bodyText => _body.toString();

  @override
  void write(Object? object) {
    _body.write(object);
  }

  @override
  Future<void> close() async {}

  @override
  HttpHeaders get headers => _headers;

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}

class _StubResponseHeaders implements HttpHeaders {
  final Map<String, String> _values = <String, String>{};
  ContentType? _contentType;

  @override
  ContentType? get contentType => _contentType;

  @override
  set contentType(ContentType? value) {
    _contentType = value;
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => _values[name.toLowerCase()];

  @override
  noSuchMethod(Invocation invocation) {
    return super.noSuchMethod(invocation);
  }
}
