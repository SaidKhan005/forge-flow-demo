import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('Admin debug-console proxy routes', () {
    test('GET requests forwards multi-location support-log filters', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingDebugConsoleGateway();
        final ctx = await _spinUp(gateway);
        try {
          final uri = ctx.baseUri.resolve(
            '$adminDebugRequestsPath?operator_id=op-1'
            '&location_ids=loc-a,loc-b&limit=25',
          );
          final response = await _httpGet(ctx.client, uri);

          expect(response.statusCode, equals(200));
          expect(gateway.operatorIds, equals(<String?>['op-1']));
          expect(gateway.locationIds, equals(<String?>[null]));
          expect(
            gateway.locationIdLists,
            equals(<List<String>?>[
              <String>['loc-a', 'loc-b'],
            ]),
          );
          expect(gateway.limits, equals(<int>[25]));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
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

Future<({HttpServer server, HttpClient client, Uri baseUri})> _spinUp(
  DebugConsoleAdminProxyGateway gateway,
) async {
  final guard = ProxyRequestGuard(
    verifier: _FixedClaimsVerifier(
      const ProxyJwtClaims(
        userId: 'admin-user',
        operatorId: null,
        locationId: null,
        roles: <String>['super_admin'],
      ),
    ),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    await routeRequest(request, guard, debugConsoleAdminGateway: gateway);
  });
  final client = HttpClient();
  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  return (server: server, client: client, baseUri: baseUri);
}

Future<({int statusCode, Map<String, Object?> body})> _httpGet(
  HttpClient client,
  Uri uri,
) async {
  final request = await client.getUrl(uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  final decoded = text.isEmpty ? <String, Object?>{} : jsonDecode(text);
  return (
    statusCode: response.statusCode,
    body: decoded is Map
        ? decoded.cast<String, Object?>()
        : <String, Object?>{},
  );
}

class _FixedClaimsVerifier implements ProxyJwtVerifier {
  const _FixedClaimsVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _RecordingDebugConsoleGateway implements DebugConsoleAdminProxyGateway {
  final operatorIds = <String?>[];
  final locationIds = <String?>[];
  final locationIdLists = <List<String>?>[];
  final limits = <int>[];

  @override
  Future<List<Map<String, Object?>>> listRequests({
    required String actorUserId,
    required String adminReason,
    String? operatorId,
    String? locationId,
    List<String>? locationIds,
    String? usageClass,
    String? status,
    int? timeWindowSeconds,
    String? searchText,
    required int limit,
    required bool includeFullContent,
  }) async {
    operatorIds.add(operatorId);
    this.locationIds.add(locationId);
    locationIdLists.add(locationIds);
    limits.add(limit);
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>?> getByIdempotencyKey({
    required String actorUserId,
    required String adminReason,
    required String idempotencyKey,
    required bool includeFullContent,
  }) async => null;

  @override
  Future<Map<String, Object?>?> getByRequestId({
    required String actorUserId,
    required String adminReason,
    required String requestId,
    required bool includeFullContent,
  }) async => null;

  @override
  Future<List<Map<String, Object?>>> listFullContentOptIns({
    required String actorUserId,
    required String adminReason,
  }) async => const <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> tailRecent({
    required String actorUserId,
    required String adminReason,
    required int limit,
    required bool includeFullContent,
  }) async => const <Map<String, Object?>>[];
}
