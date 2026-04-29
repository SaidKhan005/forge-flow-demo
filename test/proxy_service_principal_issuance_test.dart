// Phase 9 B41 - service-principal JWT issuance route/client tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';
import 'package:forge_and_flow/services/auth/proxy_admin_permission_guard.dart';
import 'package:forge_and_flow/services/auth/proxy_auth_operations_gateway.dart';
import 'package:forge_and_flow/services/auth/proxy_service_principal_issuance_gateway.dart'
    as client;

import '../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('B41 service-principal JWT issuance route', () {
    test('issues a verifier-accepted sp: JWT, audits, and completes '
        'idempotency through proxy_requests', () async {
      await _withRealHttp(() async {
        final pool = _IssuancePostgresPool();
        final gateway = PostgresServicePrincipalJwtIssuanceGateway(
          wrapper: TenantTransactionWrapper(pool),
          issuer: const ServicePrincipalJwtIssuer(sharedSecret: _jwtSecret),
        );
        final guard = _RecordingAdminGuard();
        final harness = await _RouteHarness.start(
          gateway: gateway,
          adminPermissionGuard: guard,
        );
        try {
          final response = await harness.postJson(
            '$adminServicePrincipalsPrefix$_servicePrincipalId/jwt',
            idempotencyKey: 'idem-b41',
          );

          expect(response.statusCode, equals(200));
          expect(response.json['idempotent_replay'], isFalse);
          final jwt = response.json['jwt'];
          expect(jwt, isA<String>());
          expect(
            response.json['expires_at'],
            equals('2026-04-29T12:15:00.000Z'),
          );
          expect(
            guard.permissionKeys,
            equals(<String>['admin.service_principal.issue_token']),
          );

          final claims = await ServicePrincipalJwtVerifier(
            sharedSecret: _jwtSecret,
            now: () => DateTime.utc(2026, 4, 29, 12, 1),
          ).verify(jwt! as String);
          expect(claims.actorKind, equals('service'));
          expect(claims.servicePrincipalId, equals(_servicePrincipalId));
          expect(claims.operatorId, equals(_operatorId));
          expect(claims.locationId, equals(_locationId));
          expect(claims.roles, contains('sp_scope:workflow.run'));

          final tx = pool.transactions.single;
          expect(
            tx.queryCalls.any(
              (call) => call.sql.contains('from public.service_principals'),
            ),
            isTrue,
          );
          expect(
            tx.queryCalls.any(
              (call) => call.sql.contains('insert into public.proxy_requests'),
            ),
            isTrue,
          );
          final auditCall = tx.queryCalls.singleWhere(
            (call) => call.sql.contains('insert into public.auth_events_audit'),
          );
          expect(auditCall.sql, contains("'service'"));
          expect(
            auditCall.parameters['service_principal_id'],
            equals(_servicePrincipalId),
          );
          expect(
            auditCall.parameters['event_type'],
            equals('admin.service_principal.issue_token'),
          );
          final payload =
              jsonDecode(auditCall.parameters['payload']! as String)
                  as Map<String, Object?>;
          expect(payload['issued_by_user_id'], equals(_userId));
          expect(payload, isNot(contains('jwt')));
          expect(
            tx.executeCalls.any(
              (call) => call.sql.contains('update public.proxy_requests'),
            ),
            isTrue,
          );
        } finally {
          await harness.close();
        }
      });
    });

    test('requires Idempotency-Key before issuing', () async {
      await _withRealHttp(() async {
        final gateway = _RejectingGateway();
        final harness = await _RouteHarness.start(
          gateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(),
        );
        try {
          final response = await harness.postJson(
            '$adminServicePrincipalsPrefix$_servicePrincipalId/jwt',
          );

          expect(response.statusCode, equals(400));
          expect(response.json['error'], equals('missing_idempotency_key'));
          expect(gateway.calls, equals(0));
        } finally {
          await harness.close();
        }
      });
    });

    test('admin permission denial stops issuance', () async {
      await _withRealHttp(() async {
        final gateway = _RejectingGateway();
        final harness = await _RouteHarness.start(
          gateway: gateway,
          adminPermissionGuard: _RecordingAdminGuard(
            decision: const ProxyAdminDeniedDefault(),
          ),
        );
        try {
          final response = await harness.postJson(
            '$adminServicePrincipalsPrefix$_servicePrincipalId/jwt',
            idempotencyKey: 'idem-denied',
          );

          expect(response.statusCode, equals(403));
          expect(response.json['error'], equals('permission_denied'));
          expect(gateway.calls, equals(0));
        } finally {
          await harness.close();
        }
      });
    });
  });

  group('PostgresServicePrincipalJwtIssuanceGateway', () {
    test(
      'replays completed idempotency payload without another audit row',
      () async {
        final replayJwt =
            const ServicePrincipalJwtIssuer(sharedSecret: _jwtSecret).issue(
              servicePrincipalId: _servicePrincipalId,
              operatorId: _operatorId,
              locationId: _locationId,
              scopes: const <String>['workflow.run'],
              issuedAt: DateTime.utc(2026, 4, 29, 12),
            );
        final pool = _IssuancePostgresPool(
          replayPayload: <String, Object?>{
            'jwt': replayJwt,
            'expires_at': '2026-04-29T12:15:00.000Z',
          },
        );
        final gateway = PostgresServicePrincipalJwtIssuanceGateway(
          wrapper: TenantTransactionWrapper(pool),
          issuer: const ServicePrincipalJwtIssuer(sharedSecret: _jwtSecret),
        );

        final issued = await gateway.issue(_issueCommand());

        expect(issued.idempotentReplay, isTrue);
        expect(issued.jwt, equals(replayJwt));
        final tx = pool.transactions.single;
        expect(
          tx.queryCalls.any(
            (call) => call.sql.contains('insert into public.auth_events_audit'),
          ),
          isFalse,
        );
      },
    );

    test('enforces the 100/hour service-principal issuance limit', () async {
      final pool = _IssuancePostgresPool(recentIssuanceCount: 100);
      final gateway = PostgresServicePrincipalJwtIssuanceGateway(
        wrapper: TenantTransactionWrapper(pool),
        issuer: const ServicePrincipalJwtIssuer(sharedSecret: _jwtSecret),
      );

      ServicePrincipalJwtIssueRejected? thrown;
      try {
        await gateway.issue(_issueCommand());
      } on ServicePrincipalJwtIssueRejected catch (error) {
        thrown = error;
      }

      expect(thrown, isNotNull);
      expect(thrown!.statusCode, equals(429));
      expect(thrown.code, equals('service_principal_rate_limited'));
      final tx = pool.transactions.single;
      expect(tx.rolledBack, isTrue);
      expect(
        tx.queryCalls.any(
          (call) => call.sql.contains('insert into public.proxy_requests'),
        ),
        isFalse,
      );
    });
  });

  group('ProxyServicePrincipalIssuanceGateway client', () {
    test(
      'posts to the B41 route with bearer token and idempotency key',
      () async {
        final http = _RecordingClient(
          response: const ProxyAuthOperationsResponse(
            statusCode: 200,
            body: <String, Object?>{
              'jwt': 'sp.jwt.value',
              'expires_at': '2026-04-29T12:15:00.000Z',
            },
          ),
        );
        final gateway = client.ProxyServicePrincipalIssuanceGateway(
          proxyBaseUri: Uri.parse('https://proxy.example.test'),
          idTokenProvider: () async => 'human-admin-token',
          httpClient: http,
          idempotencyKeyFactory: () => 'idem-client',
        );

        final issued = await gateway.issueJwt(
          servicePrincipalId: _servicePrincipalId,
        );

        expect(issued.jwt, equals('sp.jwt.value'));
        expect(issued.expiresAt, equals(DateTime.utc(2026, 4, 29, 12, 15)));
        expect(http.posts, hasLength(1));
        final post = http.posts.single;
        expect(
          post.url.path,
          equals('/v1/admin/service-principals/$_servicePrincipalId/jwt'),
        );
        expect(
          post.headers['Authorization'],
          equals('Bearer human-admin-token'),
        );
        expect(post.headers['Idempotency-Key'], equals('idem-client'));
        expect(post.body, isEmpty);
      },
    );
  });
}

const _jwtSecret = 'test-service-principal-signing-secret';
const _userId = '11111111-1111-4111-8111-111111111111';
const _operatorId = '22222222-2222-4222-8222-222222222222';
const _locationId = '33333333-3333-4333-8333-333333333333';
const _servicePrincipalId = '44444444-4444-4444-8444-444444444444';

ServicePrincipalJwtIssueCommand _issueCommand() {
  return ServicePrincipalJwtIssueCommand(
    servicePrincipalId: _servicePrincipalId,
    operator: const OperatorContext(
      userId: _userId,
      operatorId: _operatorId,
      locationId: _locationId,
      roles: <String>['roles_version:7'],
    ),
    idempotencyKey: 'idem-b41',
    issuedAt: DateTime.utc(2026, 4, 29, 12),
  );
}

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

class _RouteHarness {
  _RouteHarness._({
    required this.server,
    required this.client,
    required this.baseUri,
  });

  final HttpServer server;
  final HttpClient client;
  final Uri baseUri;

  static Future<_RouteHarness> start({
    required ServicePrincipalJwtIssuanceGateway gateway,
    required ProxyAdminPermissionGuard adminPermissionGuard,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final guard = ProxyRequestGuard(verifier: const _StaticVerifier());
    server.listen((request) async {
      await routeRequest(
        request,
        guard,
        adminPermissionGuard: adminPermissionGuard,
        servicePrincipalJwtIssuanceGateway: gateway,
        now: () => DateTime.utc(2026, 4, 29, 12),
      );
    });
    return _RouteHarness._(
      server: server,
      client: HttpClient(),
      baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
    );
  }

  Future<_HttpJsonResponse> postJson(
    String path, {
    String? idempotencyKey,
  }) async {
    final request = await client.postUrl(baseUri.resolve(path));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer test-token');
    if (idempotencyKey != null) {
      request.headers.set('Idempotency-Key', idempotencyKey);
    }
    final encoded = utf8.encode(jsonEncode(const <String, Object?>{}));
    request.contentLength = encoded.length;
    request.add(encoded);
    final response = await request.close();
    return _HttpJsonResponse.from(response);
  }

  Future<void> close() async {
    client.close(force: true);
    await server.close(force: true);
  }
}

class _HttpJsonResponse {
  const _HttpJsonResponse({required this.statusCode, required this.json});

  final int statusCode;
  final Map<String, Object?> json;

  static Future<_HttpJsonResponse> from(HttpClientResponse response) async {
    final raw = await utf8.decodeStream(response.cast<List<int>>());
    return _HttpJsonResponse(
      statusCode: response.statusCode,
      json: raw.isEmpty
          ? const <String, Object?>{}
          : Map<String, Object?>.from(jsonDecode(raw) as Map),
    );
  }
}

class _StaticVerifier implements ProxyJwtVerifier {
  const _StaticVerifier();

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    return ProxyJwtClaims(
      userId: _userId,
      operatorId: _operatorId,
      locationId: _locationId,
      roles: const <String>['roles_version:7'],
      rolesVersion: 7,
      lastFreshAuthAt: DateTime.utc(2026, 4, 29, 11, 59),
    );
  }
}

class _RecordingAdminGuard implements ProxyAdminPermissionGuard {
  _RecordingAdminGuard({this.decision = const ProxyAdminAllowed()});

  final ProxyAdminGuardDecision decision;
  final permissionKeys = <String>[];

  @override
  Future<ProxyAdminGuardDecision> evaluate(
    ProxyAdminGuardContext context,
  ) async {
    permissionKeys.add(context.requestedPermissionKey);
    return decision;
  }
}

class _RejectingGateway implements ServicePrincipalJwtIssuanceGateway {
  var calls = 0;

  @override
  Future<ServicePrincipalJwtIssued> issue(
    ServicePrincipalJwtIssueCommand command,
  ) async {
    calls++;
    throw const ServicePrincipalJwtIssueRejected(
      code: 'unexpected_call',
      message: 'gateway should not have been called',
      statusCode: 500,
    );
  }
}

class _IssuancePostgresPool implements PostgresPool {
  _IssuancePostgresPool({this.replayPayload, this.recentIssuanceCount = 0});

  final Map<String, Object?>? replayPayload;
  final int recentIssuanceCount;
  final transactions = <_IssuancePostgresTransaction>[];

  @override
  Future<PostgresTransaction> beginTransaction() async {
    final tx = _IssuancePostgresTransaction(
      replayPayload: replayPayload,
      recentIssuanceCount: recentIssuanceCount,
    );
    transactions.add(tx);
    return tx;
  }
}

class _SqlCall {
  const _SqlCall(this.sql, this.parameters);

  final String sql;
  final PostgresParameters parameters;
}

class _IssuancePostgresTransaction implements PostgresTransaction {
  _IssuancePostgresTransaction({
    required this.replayPayload,
    required this.recentIssuanceCount,
  });

  final Map<String, Object?>? replayPayload;
  final int recentIssuanceCount;
  final queryCalls = <_SqlCall>[];
  final executeCalls = <_SqlCall>[];
  var committed = false;
  var rolledBack = false;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    queryCalls.add(_SqlCall(sql, parameters));
    if (sql.contains('from public.proxy_requests')) {
      if (replayPayload == null) return const <PostgresRow>[];
      return <PostgresRow>[
        <String, Object?>{
          'request_type': 'service_principal_jwt_issue:$_servicePrincipalId',
          'response_payload': jsonEncode(replayPayload),
        },
      ];
    }
    if (sql.contains('from public.service_principals')) {
      return <PostgresRow>[
        <String, Object?>{
          'id': _servicePrincipalId,
          'scopes': jsonEncode(<String>['workflow.run']),
          'revoked_at': null,
        },
      ];
    }
    if (sql.contains('count(*)::int as issuance_count')) {
      return <PostgresRow>[
        <String, Object?>{'issuance_count': recentIssuanceCount},
      ];
    }
    if (sql.contains('insert into public.proxy_requests')) {
      return const <PostgresRow>[
        <String, Object?>{'request_id': '55555555-5555-4555-8555-555555555555'},
      ];
    }
    if (sql.contains('insert into public.auth_events_audit')) {
      return const <PostgresRow>[
        <String, Object?>{'event_id': '66666666-6666-4666-8666-666666666666'},
      ];
    }
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    executeCalls.add(_SqlCall(sql, parameters));
    if (sql.contains('update public.proxy_requests')) return 1;
    return 0;
  }

  @override
  Future<void> commit() async {
    committed = true;
  }

  @override
  Future<void> rollback() async {
    rolledBack = true;
  }
}

class _RecordingClient implements ProxyAuthOperationsHttpClient {
  _RecordingClient({required this.response});

  final ProxyAuthOperationsResponse response;
  final posts = <_RecordedPost>[];

  @override
  Future<ProxyAuthOperationsResponse> postJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    posts.add(_RecordedPost(url: url, headers: headers, body: body));
    return response;
  }

  @override
  Future<ProxyAuthOperationsResponse> deleteJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<ProxyAuthOperationsResponse> getJson({
    required Uri url,
    required Map<String, String> headers,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<ProxyAuthOperationsResponse> patchJson({
    required Uri url,
    required Map<String, String> headers,
    required Map<String, Object?> body,
  }) async {
    throw UnimplementedError();
  }
}

class _RecordedPost {
  const _RecordedPost({
    required this.url,
    required this.headers,
    required this.body,
  });

  final Uri url;
  final Map<String, String> headers;
  final Map<String, Object?> body;
}
