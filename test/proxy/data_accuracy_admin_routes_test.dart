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

    test(
      'PUT scoped data accuracy writes through selected hierarchy scope',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final response = await _httpJson(
              ctx.client,
              'PUT',
              ctx.baseUri.resolve(adminDataAccuracyScopedSettingsPath),
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'scope_type': 'org_unit',
                'org_unit_id': 'ou-1',
                'covers_source_lunch': 'manual',
                'reason_note': 'Set lunch source for the region',
              },
            );
            expect(response.statusCode, equals(200));
            expect(gateway.scopeOverrideCalls, equals(1));
            expect(gateway.lastScopeType, equals('org_unit'));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['affected_location_count'], equals(0));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('GET service-period settings reads keyed admin rows', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(customGateway: gateway);
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '$adminDataAccuracyServicePeriodSettingsPrefix'
              'op-1/loc-1',
            ),
          );
          expect(response.statusCode, equals(200));
          expect(gateway.servicePeriodListCalls, equals(1));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final rows =
              body['data_accuracy_service_period_settings'] as List<Object?>;
          expect(rows, hasLength(1));
          final row = rows.single as Map<String, Object?>;
          expect(row['service_period_key'], equals('breakfast'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH service-period settings writes keyed admin row', () async {
      await withRealHttp(() async {
        final gateway = _FakeDataAccuracyAdminGateway();
        final ctx = await spinUp(customGateway: gateway);
        try {
          final response = await _httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '$adminDataAccuracyServicePeriodSettingsPrefix'
              'op-1/loc-1',
            ),
            body: const <String, Object?>{
              'service_period_key': 'breakfast',
              'covers_source': 'manual',
              'wage_source': 'target_substitution',
              'effective_at_business_date': '2026-06-01',
              'reason_note': 'Breakfast is now manual for launch week',
            },
          );
          expect(response.statusCode, equals(200));
          expect(gateway.servicePeriodOverrideCalls, equals(1));
          expect(gateway.lastServicePeriodKey, equals('breakfast'));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final row = body['data'] as Map<String, Object?>;
          expect(row['covers_source'], equals('manual'));
          expect(row['wage_source'], equals('target_substitution'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH service-period settings rejects ff_support callers', () async {
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
            'PATCH',
            ctx.baseUri.resolve(
              '$adminDataAccuracyServicePeriodSettingsPrefix'
              'op-1/loc-1',
            ),
            body: const <String, Object?>{
              'service_period_key': 'breakfast',
              'covers_source': 'manual',
              'wage_source': 'target_substitution',
              'effective_at_business_date': '2026-06-01',
              'reason_note': 'support cannot write',
            },
          );
          expect(response.statusCode, equals(403));
          expect(gateway.servicePeriodOverrideCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'PUT scoped polling assignment writes through selected hierarchy scope',
      () async {
        await withRealHttp(() async {
          final gateway = _FakeDataAccuracyAdminGateway();
          final ctx = await spinUp(customGateway: gateway);
          try {
            final response = await _httpJson(
              ctx.client,
              'PUT',
              ctx.baseUri.resolve(adminPollingPricingScopedAssignmentsPath),
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'scope_type': 'business',
                'tier_key': 'premium',
                'reason_note': 'Move the business to premium polling',
              },
            );
            expect(response.statusCode, equals(200));
            expect(gateway.scopeAssignCalls, equals(1));
            expect(gateway.lastScopeType, equals('business'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

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
  String? lastScopeType;
  String? lastServicePeriodKey;
  int assignTierCalls = 0;
  int scopeOverrideCalls = 0;
  int scopeAssignCalls = 0;
  int servicePeriodListCalls = 0;
  int servicePeriodOverrideCalls = 0;

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
    String? walkInHandlingMode,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    return const <String, Object?>{'ok': true};
  }

  @override
  Future<Map<String, Object?>> overrideDataAccuracyScope({
    required String actorUserId,
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
    String? coversSourceLunch,
    String? coversSourceDinner,
    String? coversSourceLateNight,
    String? wageSource,
    String? walkInHandlingMode,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastScopeType = scopeType;
    scopeOverrideCalls += 1;
    return <String, Object?>{
      'scope_type': scopeType,
      'operator_id': operatorId,
      if (orgUnitId != null) 'org_unit_id': orgUnitId,
      if (locationId != null) 'location_id': locationId,
      'affected_location_count': 0,
      'rows': const <Map<String, Object?>>[],
    };
  }

  @override
  Future<List<Map<String, Object?>>> listDataAccuracyServicePeriodRows({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    servicePeriodListCalls += 1;
    return <Map<String, Object?>>[
      _servicePeriodRow(operatorId: operatorId, locationId: locationId),
    ];
  }

  @override
  Future<Map<String, Object?>> overrideDataAccuracyServicePeriod({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required String servicePeriodKey,
    required String coversSource,
    required String wageSource,
    required String effectiveAtBusinessDate,
    required String reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastServicePeriodKey = servicePeriodKey;
    servicePeriodOverrideCalls += 1;
    return _servicePeriodRow(
      operatorId: operatorId,
      locationId: locationId,
      servicePeriodKey: servicePeriodKey,
      coversSource: coversSource,
      wageSource: wageSource,
      effectiveAtBusinessDate: effectiveAtBusinessDate,
    );
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
  Future<Map<String, Object?>> assignTierScope({
    required String actorUserId,
    required String operatorId,
    required String scopeType,
    String? orgUnitId,
    String? locationId,
    required String tierKey,
    Map<String, int>? customCadencePerVendorSeconds,
    int? monthlyPriceCentsOverride,
    int? vendorApiCostEstimateCentsMonthlyOverride,
    String? adminNotes,
    String? reasonNote,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastScopeType = scopeType;
    scopeAssignCalls += 1;
    return <String, Object?>{
      'scope_type': scopeType,
      'operator_id': operatorId,
      if (orgUnitId != null) 'org_unit_id': orgUnitId,
      if (locationId != null) 'location_id': locationId,
      'affected_location_count': 0,
      'assignments': const <Map<String, Object?>>[],
    };
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

Map<String, Object?> _servicePeriodRow({
  required String operatorId,
  required String locationId,
  String servicePeriodKey = 'breakfast',
  String coversSource = 'vendor',
  String wageSource = 'vendor_per_employee',
  String effectiveAtBusinessDate = '2026-06-01',
}) {
  return <String, Object?>{
    'id': 'sp-$servicePeriodKey',
    'operator_id': operatorId,
    'location_id': locationId,
    'service_period_key': servicePeriodKey,
    'covers_source': coversSource,
    'wage_source': wageSource,
    'effective_at_business_date': effectiveAtBusinessDate,
    'created_at': '2026-05-01T00:00:00.000Z',
    'updated_at': '2026-05-01T00:00:00.000Z',
    'updated_by': 'user_admin',
  };
}

class _HttpResponseData {
  const _HttpResponseData(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
