// Phase 8 spine-bridge .C live proxy route coverage.
//
// These tests pin the Data Accuracy / Polling & Pricing admin route
// family to the same fail-closed and read/write role posture used by
// the rest of the F&F operations console.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('Data Accuracy admin proxy routes', () {
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
        _SettableVerifier verifier,
        _FakeDataAccuracyAdminGateway gateway,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      _FakeDataAccuracyAdminGateway? customGateway,
      bool gatewayConfigured = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims =
          initialClaims ??
          const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = customGateway ?? _FakeDataAccuracyAdminGateway();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            dataAccuracyAdminGateway: gatewayConfigured ? gateway : null,
            adminCorsAllowList: const <String>['https://admin.forgeflow.app'],
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {}
        }
      });
      final client = HttpClient();
      final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
      return (
        server: server,
        client: client,
        baseUri: baseUri,
        verifier: verifier,
        gateway: gateway,
      );
    }

    test('GET rows returns 503 when gateway is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(gatewayConfigured: false);
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(adminDataAccuracyRowsPath),
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('data_accuracy_admin_not_configured'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('GET rows admits ff_support read-only callers', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_support',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(adminDataAccuracyRowsPath),
          );
          expect(response.statusCode, equals(200));
          expect(gateway.lastActorUserId, equals('user_support'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PUT assignment rejects ff_support write callers', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_support',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'PUT',
            ctx.baseUri.resolve(
              '${adminPollingPricingAssignmentsPrefix}op-1/loc-1',
            ),
            body: const <String, Object?>{'tier_key': 'premium'},
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(body['required_roles'], contains('super_admin'));
          expect(body['required_roles'], isNot(contains('ff_support')));
          expect(gateway.assignTierCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('CORS preflight allows polling-pricing write methods', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminPollingPricingMarginExportPath),
          );
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'POST');
          request.headers.set(
            'Access-Control-Request-Headers',
            'Authorization, Content-Type, Idempotency-Key',
          );
          final raw = await request.close();
          await utf8.decodeStream(raw);
          expect(raw.statusCode, equals(204));
          expect(
            raw.headers.value('access-control-allow-methods'),
            contains('POST'),
          );
          expect(
            raw.headers.value('access-control-allow-headers'),
            contains('Idempotency-Key'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final current = claims;
    if (current == null) {
      throw ProxyJwtVerificationError('missing test claims');
    }
    return current;
  }
}

class _FakeDataAccuracyAdminGateway implements DataAccuracyAdminProxyGateway {
  String? lastActorUserId;
  int assignTierCalls = 0;

  @override
  Future<List<Map<String, Object?>>> listDataAccuracyRows({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<List<Map<String, Object?>>> listAuditHistory({
    required String actorUserId,
    String? operatorId,
    String? locationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>?> overrideDataAccuracy({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    String? coversSourceLunch,
    String? coversSourceDinner,
    String? coversSourceLateNight,
    String? wageSource,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <String, Object?>{'ok': true};
  }

  @override
  Future<List<Map<String, Object?>>> listTierDefinitions({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>> updateTierDefinition({
    required String actorUserId,
    required String tierKey,
    String? descriptionMd,
    Map<String, int>? pollingCadencePerVendorSeconds,
    int? defaultMonthlyPriceCents,
    int? vendorApiCostEstimateCentsMonthly,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <String, Object?>{'tier_key': 'premium'};
  }

  @override
  Future<List<Map<String, Object?>>> listTierAssignments({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>?> assignTier({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    String? reasonNote,
    required String adminReason,
  }) async {
    assignTierCalls += 1;
    lastActorUserId = actorUserId;
    return const <String, Object?>{'ok': true};
  }

  @override
  Future<Map<String, Object?>> summarizeMargin({
    required String actorUserId,
    String? tierKey,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <String, Object?>{
      'total_monthly_price_cents': 0,
      'total_monthly_vendor_cost_cents': 0,
      'per_tier': <Map<String, Object?>>[],
      'per_vendor': <Map<String, Object?>>[],
    };
  }

  @override
  Future<String> exportMarginRollupCsv({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return 'section,key\n';
  }

  @override
  Future<List<Map<String, Object?>>> listTierChangeRequests({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>?> resolveTierChangeRequest({
    required String actorUserId,
    required String requestId,
    required String status,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <String, Object?>{'request_id': 'req-1'};
  }
}

Future<_HttpResponseData> _httpGet(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
  final raw = await request.close();
  final body = await utf8.decodeStream(raw);
  return _HttpResponseData(raw.statusCode, body);
}

Future<_HttpResponseData> _httpJson(
  HttpClient client,
  String method,
  Uri uri, {
  required Map<String, Object?> body,
}) async {
  final request = await client.openUrl(method, uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
  request.headers.contentType = ContentType.json;
  final payload = utf8.encode(jsonEncode(body));
  request.contentLength = payload.length;
  request.add(payload);
  final raw = await request.close();
  final responseBody = await utf8.decodeStream(raw);
  return _HttpResponseData(raw.statusCode, responseBody);
}

class _HttpResponseData {
  const _HttpResponseData(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
