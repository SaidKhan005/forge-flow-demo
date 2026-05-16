// 11W.7 ops-debt - HTTP-level tests for the GET companions of
// `/v1/operator/account` and `/v1/operator/business-timing-profiles`.
//
// Fix #3 (GET account) and Fix #4 (GET timing profiles) added the
// missing read surfaces so the operator-web Settings shell can hydrate
// the Account screen and Business Timing editor without a write.
// These tests pin:
//   * 200 with the expected payload shape on the happy path
//   * 404 when the gateway returns no row (account only)
//   * RLS / cross-tenant: gateway always sees the JWT operator
//   * 401 when bearer token is rejected
//   * 403 when caller lacks the operator owner / admin role gate
//   * 503 when router not configured

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/operator_routes.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kOpB = '22222222-2222-2222-2222-222222222222';
const String _kLoc = '33333333-3333-3333-3333-333333333333';
const String _kUser = '44444444-4444-4444-4444-444444444444';
const String _kProfile = '55555555-5555-5555-5555-555555555555';

void main() {
  group('GET /v1/operator/account', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<({
      HttpServer server,
      HttpClient client,
      Uri baseUri,
      _RecordingAccountGateway accountGateway,
      _RecordingTimingGateway timingGateway,
      _SettableVerifier verifier,
    })> spinUp({
      ProxyJwtClaims? initialClaims,
      bool routerConfigured = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims ??
          const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final accountGateway = _RecordingAccountGateway();
      final timingGateway = _RecordingTimingGateway();
      final router = OperatorWriteRouter(
        accountGateway: accountGateway,
        businessTimingGateway: timingGateway,
        auditSink: _NoopAuditSink(),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            operatorWriteRouter: routerConfigured ? router : null,
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
        accountGateway: accountGateway,
        timingGateway: timingGateway,
        verifier: verifier,
      );
    }

    test('200 returns the resolved account row', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['operatorId'], equals(_kOpA));
          expect(body['businessName'], equals('Recording Co'));
          expect(body['currencyCode'], equals('CAD'));
          expect(body['localeTag'], equals('en-CA'));
          expect(body['weekStartDay'], equals('monday'));
          expect(body['rolloverHour'], equals(4));
          expect(ctx.accountGateway.loadCalls, equals(1));
          expect(ctx.accountGateway.lastOperatorId, equals(_kOpA));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('404 operator_not_found when load returns null', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        ctx.accountGateway.loadReturnsNull = true;
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(404));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('operator_not_found'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('GET requires no Idempotency-Key header', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPath),
            authorization: 'Bearer fake.token',
            // No Idempotency-Key set.
          );
          expect(response.statusCode, equals(200));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('403 when caller lacks operator_owner / operator_admin', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_member'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(403));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('503 when router is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(routerConfigured: false);
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(503));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('cross-tenant isolation: gateway sees JWT operatorId only', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          // Operator A reads.
          await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPath),
            authorization: 'Bearer fake.token',
          );
          expect(ctx.accountGateway.lastOperatorId, equals(_kOpA));

          // Same shared server, switch JWT to operator B.
          ctx.verifier.claims = const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpB,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
          await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPath),
            authorization: 'Bearer fake.token',
          );
          expect(ctx.accountGateway.lastOperatorId, equals(_kOpB));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('GET /v1/operator/business-timing-profiles', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<({
      HttpServer server,
      HttpClient client,
      Uri baseUri,
      _RecordingAccountGateway accountGateway,
      _RecordingTimingGateway timingGateway,
      _SettableVerifier verifier,
    })> spinUp({ProxyJwtClaims? initialClaims}) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims ??
          const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final accountGateway = _RecordingAccountGateway();
      final timingGateway = _RecordingTimingGateway();
      timingGateway.seedProfile(_kProfile);
      final router = OperatorWriteRouter(
        accountGateway: accountGateway,
        businessTimingGateway: timingGateway,
        auditSink: _NoopAuditSink(),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            operatorWriteRouter: router,
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
        accountGateway: accountGateway,
        timingGateway: timingGateway,
        verifier: verifier,
      );
    }

    test('200 returns the operator profile set with service periods',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final profiles = body['profiles'] as List<Object?>;
          expect(profiles, hasLength(1));
          final profile = Map<String, Object?>.from(
            profiles.single as Map<Object?, Object?>,
          );
          expect(profile['profileId'], equals(_kProfile));
          expect(profile['scopeKind'], equals('operator'));
          expect(profile['ianaTimezone'], equals('America/Toronto'));
          expect(profile['servicePeriods'], hasLength(2));
          expect(ctx.timingGateway.listCalls, equals(1));
          expect(ctx.timingGateway.lastListOperatorId, equals(_kOpA));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('200 with empty profiles array when nothing seeded', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        ctx.timingGateway.clear();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['profiles'], isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('cross-tenant isolation: gateway sees JWT operatorId only', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            authorization: 'Bearer fake.token',
          );
          expect(ctx.timingGateway.lastListOperatorId, equals(_kOpA));

          ctx.verifier.claims = const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpB,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
          await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            authorization: 'Bearer fake.token',
          );
          expect(ctx.timingGateway.lastListOperatorId, equals(_kOpB));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('403 when caller lacks operator_owner / operator_admin', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_member'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(403));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  // Fix #4 / S1 — GET
  // /v1/operator/locations/:locationId/business-timing-resolution.
  // Backend prerequisite for G13/G41/G42: returns the FULL canonical
  // candidate chain in scope_depth order with scope ancestry + full
  // service-period fields + location timezone so the Flutter client
  // can run the one pure resolver.
  group('GET business-timing-resolution', () {
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    Future<({
      HttpServer server,
      HttpClient client,
      Uri baseUri,
      _RecordingTimingGateway timingGateway,
      _SettableVerifier verifier,
    })> spinUp({
      ProxyJwtClaims? initialClaims,
      bool routerConfigured = true,
      bool seedChain = true,
    }) async {
      final verifier = _SettableVerifier();
      verifier.claims = initialClaims ??
          const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
      final guard = ProxyRequestGuard(verifier: verifier);
      final timingGateway = _RecordingTimingGateway();
      if (seedChain) timingGateway.seedResolutionChain();
      final router = OperatorWriteRouter(
        accountGateway: _RecordingAccountGateway(),
        businessTimingGateway: timingGateway,
        auditSink: _NoopAuditSink(),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            operatorWriteRouter: routerConfigured ? router : null,
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
        timingGateway: timingGateway,
        verifier: verifier,
      );
    }

    Uri resolutionUri(Uri baseUri, String locationId, {String? businessDate}) {
      final path = operatorLocationBusinessTimingResolutionPrefix +
          locationId +
          operatorLocationBusinessTimingResolutionSuffix;
      final base = baseUri.resolve(path);
      if (businessDate == null) return base;
      return base.replace(
        queryParameters: <String, String>{'business_date': businessDate},
      );
    }

    test('200 returns the 3-level chain in scope_depth order with full '
        'period fields + timezone', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kLoc, businessDate: '2026-05-10'),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['operatorId'], equals(_kOpA));
          expect(body['locationId'], equals(_kLoc));
          expect(body['businessDate'], equals('2026-05-10'));
          expect(body['ianaTimezone'], equals('America/Toronto'));
          final candidates = body['candidates'] as List<Object?>;
          expect(candidates, hasLength(3));
          final scopeTypes = <Object?>[
            for (final c in candidates)
              (c as Map<Object?, Object?>)['scopeType'],
          ];
          // Canonical resolver precedence: operator default first,
          // location override last.
          expect(scopeTypes, equals(<String>['operator', 'org_unit',
              'location']));
          final ranks = <Object?>[
            for (final c in candidates)
              (c as Map<Object?, Object?>)['scopeDepthRank'],
          ];
          expect(ranks, equals(<int>[0, 1, 2]));
          final location = Map<Object?, Object?>.from(
            candidates.last as Map<Object?, Object?>,
          );
          expect(location['scopeLabel'], equals('Flagship'));
          final periods = location['servicePeriods'] as List<Object?>;
          final brunch = Map<Object?, Object?>.from(
            periods.single as Map<Object?, Object?>,
          );
          // G45/Gap 28 read round-trip: day-restricted period survives.
          expect(brunch['applicableDays'], equals(<int>[6, 7]));
          expect(brunch['shortLabel'], equals('Brn'));
          expect(brunch['sortOrder'], equals(1));
          expect(ctx.timingGateway.resolveCalls, equals(1));
          expect(ctx.timingGateway.lastResolveOperatorId, equals(_kOpA));
          expect(ctx.timingGateway.lastResolveLocationId, equals(_kLoc));
          expect(
            ctx.timingGateway.lastResolveBusinessDate,
            equals('2026-05-10'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('200 with empty candidate list + null timezone when none seeded',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(seedChain: false);
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kLoc),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['candidates'], isEmpty);
          expect(body['ianaTimezone'], isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('403 location_scope_mismatch when path location != token scope',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(
              ctx.baseUri,
              '99999999-9999-9999-9999-999999999999',
            ),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('location_scope_mismatch'));
          // Gateway must never be reached on a scope mismatch.
          expect(ctx.timingGateway.resolveCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('403 when caller lacks operator_owner / operator_admin', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_member'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kLoc),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(403));
          expect(ctx.timingGateway.resolveCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_business_date on a malformed query param', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kLoc, businessDate: 'May-10'),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_business_date'));
          expect(ctx.timingGateway.resolveCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('503 when the operator write router is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(routerConfigured: false);
        try {
          final response = await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kLoc),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(503));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('cross-tenant: gateway only ever sees the JWT operatorId',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kLoc),
            authorization: 'Bearer fake.token',
          );
          expect(ctx.timingGateway.lastResolveOperatorId, equals(_kOpA));

          // A token for operator B with location scope _kLoc still
          // resolves only operator B (URL never supplies operator).
          ctx.verifier.claims = const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpB,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
          await _httpGet(
            ctx.client,
            resolutionUri(ctx.baseUri, _kLoc),
            authorization: 'Bearer fake.token',
          );
          expect(ctx.timingGateway.lastResolveOperatorId, equals(_kOpB));
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
  Object? error;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final err = error;
    if (err != null) throw err;
    final c = claims;
    if (c == null) {
      throw ProxyJwtVerificationError('no claims set');
    }
    return c;
  }
}

class _RecordingAccountGateway implements OperatorAccountWriteGateway {
  int loadCalls = 0;
  int patchCalls = 0;
  String? lastOperatorId;
  bool loadReturnsNull = false;

  @override
  Future<OperatorAccountRecord> patchAccount({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedOperatorAccountPatch patch,
    required String adminReason,
  }) async {
    patchCalls += 1;
    lastOperatorId = operatorId;
    return OperatorAccountRecord(
      operatorId: operatorId,
      businessName: 'Recording Co',
      logoUrl: null,
      currencyCode: 'CAD',
      localeTag: 'en-CA',
      weekStartDay: 'monday',
      rolloverHour: 4,
      updatedAt: DateTime.utc(2026, 5, 7),
    );
  }

  @override
  Future<OperatorAccountRecord?> loadAccount({
    required String operatorId,
  }) async {
    loadCalls += 1;
    lastOperatorId = operatorId;
    if (loadReturnsNull) return null;
    return OperatorAccountRecord(
      operatorId: operatorId,
      businessName: 'Recording Co',
      logoUrl: null,
      currencyCode: 'CAD',
      localeTag: 'en-CA',
      weekStartDay: 'monday',
      rolloverHour: 4,
      updatedAt: DateTime.utc(2026, 5, 7),
    );
  }
}

class _RecordingTimingGateway implements OperatorBusinessTimingWriteGateway {
  int listCalls = 0;
  String? lastListOperatorId;
  final Map<String, OperatorBusinessTimingProfileRecord> _seeded =
      <String, OperatorBusinessTimingProfileRecord>{};

  void clear() {
    _seeded.clear();
  }

  void seedProfile(String profileId) {
    _seeded[profileId] = OperatorBusinessTimingProfileRecord(
      profileId: profileId,
      scopeKind: 'operator',
      scopeId: _kOpA,
      effectiveAtBusinessDate: '2026-05-06',
      ianaTimezone: 'America/Toronto',
      weekStartDay: 'monday',
      businessDayStartLocal: '04:00',
      servicePeriods: const <OperatorBusinessTimingServicePeriodRecord>[
        OperatorBusinessTimingServicePeriodRecord(
          key: 'lunch',
          label: 'Lunch',
          startLocal: '11:00',
          endLocal: '15:00',
          rollsPastMidnight: false,
        ),
        OperatorBusinessTimingServicePeriodRecord(
          key: 'dinner',
          label: 'Dinner',
          startLocal: '17:00',
          endLocal: '22:00',
          rollsPastMidnight: false,
        ),
      ],
      createdAt: DateTime.utc(2026, 5, 1),
      updatedAt: DateTime.utc(2026, 5, 6),
    );
  }

  // Fix #4 / S1 — ordered 3-level resolution chain the new
  // `/v1/operator/locations/:locationId/business-timing-resolution`
  // route returns. `resolveCalls` / `lastResolve*` let the cross-
  // tenant + happy-path tests assert the gateway only ever sees the
  // JWT-scoped operator + the path location.
  int resolveCalls = 0;
  String? lastResolveOperatorId;
  String? lastResolveLocationId;
  String? lastResolveBusinessDate;
  List<OperatorBusinessTimingResolutionCandidate>? _resolutionChain;

  void seedResolutionChain() {
    _resolutionChain = <OperatorBusinessTimingResolutionCandidate>[
      OperatorBusinessTimingResolutionCandidate(
        profileId: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        scopeType: 'operator',
        scopeId: _kOpA,
        scopeLabel: 'Operator default',
        scopeDepthRank: 0,
        ianaTimezone: 'America/Toronto',
        effectiveAtBusinessDate: '2026-01-01',
        weekStartDay: 'monday',
        businessDayStartLocal: '04:00',
        servicePeriods: const <OperatorBusinessTimingServicePeriodRecord>[
          OperatorBusinessTimingServicePeriodRecord(
            key: 'all_day',
            label: 'All day',
            startLocal: '06:00',
            endLocal: '22:00',
            rollsPastMidnight: false,
            shortLabel: 'All',
            sortOrder: 1,
            applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
          ),
        ],
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
      OperatorBusinessTimingResolutionCandidate(
        profileId: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        scopeType: 'org_unit',
        scopeId: '66666666-6666-6666-6666-666666666666',
        scopeLabel: 'East region',
        scopeDepthRank: 1,
        ianaTimezone: 'America/Toronto',
        effectiveAtBusinessDate: '2026-02-01',
        weekStartDay: 'monday',
        businessDayStartLocal: '04:00',
        servicePeriods: const <OperatorBusinessTimingServicePeriodRecord>[
          OperatorBusinessTimingServicePeriodRecord(
            key: 'lunch',
            label: 'Lunch',
            startLocal: '11:00',
            endLocal: '15:00',
            rollsPastMidnight: false,
            shortLabel: 'Lun',
            sortOrder: 1,
            applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
          ),
        ],
        createdAt: DateTime.utc(2026, 2, 1),
        updatedAt: DateTime.utc(2026, 2, 1),
      ),
      OperatorBusinessTimingResolutionCandidate(
        profileId: 'cccccccc-cccc-cccc-cccc-cccccccccccc',
        scopeType: 'location',
        scopeId: _kLoc,
        scopeLabel: 'Flagship',
        scopeDepthRank: 2,
        ianaTimezone: 'America/Toronto',
        effectiveAtBusinessDate: '2026-03-01',
        weekStartDay: 'monday',
        businessDayStartLocal: '05:00',
        servicePeriods: const <OperatorBusinessTimingServicePeriodRecord>[
          OperatorBusinessTimingServicePeriodRecord(
            key: 'brunch',
            label: 'Weekend Brunch',
            startLocal: '09:00',
            endLocal: '14:00',
            rollsPastMidnight: false,
            shortLabel: 'Brn',
            sortOrder: 1,
            // Day-restricted (G45/Gap 28 read round-trip): Sat + Sun.
            applicableDays: <int>[6, 7],
          ),
        ],
        createdAt: DateTime.utc(2026, 3, 1),
        updatedAt: DateTime.utc(2026, 3, 1),
      ),
    ];
  }

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocation({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? actorUserId,
  }) async {
    resolveCalls += 1;
    lastResolveOperatorId = operatorId;
    lastResolveLocationId = locationId;
    lastResolveBusinessDate = businessDate;
    final chain = _resolutionChain ??
        const <OperatorBusinessTimingResolutionCandidate>[];
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: chain.isEmpty ? null : chain.first.ianaTimezone,
      candidates: chain,
    );
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> createProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OperatorBusinessTimingProfileRecord?> loadProfile({
    required String operatorId,
    required String profileId,
  }) async =>
      _seeded[profileId];

  @override
  Future<List<OperatorBusinessTimingProfileRecord>> listProfiles({
    required String operatorId,
  }) async {
    listCalls += 1;
    lastListOperatorId = operatorId;
    return List<OperatorBusinessTimingProfileRecord>.unmodifiable(
      _seeded.values,
    );
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> replaceServicePeriodSet({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required List<ValidatedServicePeriod> mergedSet,
    required String eventKind,
    required Map<String, Object?> auditPayload,
    required String adminReason,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OperatorBusinessTimingProfileRecord> updateProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async {
    throw UnimplementedError();
  }
}

class _NoopAuditSink implements OperatorWriteAuditSink {
  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {}
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpGet(
  HttpClient client,
  Uri uri, {
  required String authorization,
  String? idempotencyKey,
}) async {
  final request = await client.openUrl('GET', uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
