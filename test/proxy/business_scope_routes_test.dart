import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('business scope proxy routes', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<
      ({
        HttpServer server,
        HttpClient client,
        Uri baseUri,
        _FakeBusinessScopeGateway businessGateway,
        _FakeMobileOperationalSyncGateway mobileGateway,
      })
    >
    spinUp() async {
      final guard = ProxyRequestGuard(
        verifier: _SettableVerifier(
          const ProxyJwtClaims(
            userId: 'user-1',
            operatorId: 'op-1',
            locationId: 'loc-1',
            roles: <String>['operator_manager'],
          ),
        ),
      );
      final businessGateway = _FakeBusinessScopeGateway();
      final mobileGateway = _FakeMobileOperationalSyncGateway();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        await routeRequest(
          request,
          guard,
          businessScopeGateway: businessGateway,
          mobileOperationalSyncGateway: mobileGateway,
        );
      });
      return (
        server: server,
        client: HttpClient(),
        baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
        businessGateway: businessGateway,
        mobileGateway: mobileGateway,
      );
    }

    test('user route returns server-filtered accessible scopes', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve('/v1/users/user-1/business_scopes'),
          );
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['user_id'], 'user-1');
          expect(body['operator_id'], 'op-1');
          final scopes = body['scopes'] as List<Object?>;
          expect(scopes, hasLength(2));
          expect((scopes.last as Map<String, Object?>)['location_id'], 'loc-2');
          expect(ctx.businessGateway.listCalls, <String>['user-1:op-1:loc-1']);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('rejects a user path for someone else', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve('/v1/users/user-2/business_scopes'),
          );
          expect(response.statusCode, 403);
          expect(ctx.businessGateway.listCalls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'accessible location can rebase mobile sync within operator',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                '/v1/operators/op-1/locations/loc-2/shift_records',
              ),
            );
            expect(response.statusCode, 200);
            expect(ctx.mobileGateway.calls, <String>[
              'shift_records:op-1:loc-2',
            ]);
            expect(ctx.businessGateway.accessCalls, <String>[
              'user-1:op-1:loc-2',
            ]);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });
}

class _SettableVerifier implements ProxyJwtVerifier {
  _SettableVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _FakeBusinessScopeGateway implements BusinessScopeProxyGateway {
  final listCalls = <String>[];
  final accessCalls = <String>[];

  @override
  Future<List<BusinessScopeProxyRow>> listAccessibleScopes({
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    listCalls.add('$userId:$operatorId:$locationId');
    return <BusinessScopeProxyRow>[
      BusinessScopeProxyRow(
        scopeId: 'loc-1',
        scopeType: 'location',
        operatorId: operatorId,
        locationId: 'loc-1',
        label: 'Barrio',
      ),
      BusinessScopeProxyRow(
        scopeId: 'loc-2',
        scopeType: 'location',
        operatorId: operatorId,
        locationId: 'loc-2',
        label: 'Mercado',
      ),
    ];
  }

  @override
  Future<bool> canAccessLocation({
    required String userId,
    required String operatorId,
    required String locationId,
  }) async {
    accessCalls.add('$userId:$operatorId:$locationId');
    return operatorId == 'op-1' && locationId == 'loc-2';
  }
}

class _FakeMobileOperationalSyncGateway
    implements MobileOperationalSyncProxyGateway {
  final calls = <String>[];

  @override
  Future<Map<String, Object?>> fetchShiftRecords({
    required OperatorContext scope,
    required String operatorId,
    required String locationId,
    required String? modifiedSince,
    required int pageSize,
  }) async {
    calls.add('shift_records:$operatorId:$locationId');
    return const <String, Object?>{
      'shift_records': <Map<String, Object?>>[],
      'next_cursor': null,
    };
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_HttpResult> _httpGet(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer token');
  final response = await request.close();
  final body = await utf8.decodeStream(response);
  return _HttpResult(response.statusCode, body);
}

class _HttpResult {
  const _HttpResult(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
