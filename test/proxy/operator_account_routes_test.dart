// Phase 11W.7 / Wave A2 - HTTP-level tests for PATCH /v1/operator/account.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kOpB = '22222222-2222-2222-2222-222222222222';
const String _kLoc = '33333333-3333-3333-3333-333333333333';
const String _kUser = '44444444-4444-4444-4444-444444444444';

void main() {
  group('PATCH /v1/operator/account', () {
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
      _RecordingAuditSink auditSink,
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
      final auditSink = _RecordingAuditSink();
      final router = OperatorWriteRouter(
        accountGateway: accountGateway,
        businessTimingGateway: timingGateway,
        auditSink: auditSink,
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
        auditSink: auditSink,
      );
    }

    test('happy path - 200 with the patched record', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-001',
            body: const <String, Object?>{
              'businessName': 'Forge Test',
              'currencyCode': 'USD',
              'localeTag': 'en-US',
              'weekStartDay': 'monday',
              'rolloverHour': 4,
            },
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['operatorId'], equals(_kOpA));
          expect(body['businessName'], equals('Forge Test'));
          expect(ctx.accountGateway.patchCalls, equals(1));
          expect(ctx.auditSink.records, hasLength(1));
          expect(
            ctx.auditSink.records.single['eventKind'],
            equals('operator_account_updated'),
          );
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
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-001',
            body: const <String, Object?>{'businessName': 'X'},
          );
          expect(response.statusCode, equals(503));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('401 when bearer token rejected', () async {
      await withRealHttp(() async {
        final verifier = _SettableVerifier();
        verifier.claims = null;
        verifier.error =
            ProxyJwtVerificationError('token rejected by test verifier');
        final guard = ProxyRequestGuard(verifier: verifier);
        final router = OperatorWriteRouter(
          accountGateway: _RecordingAccountGateway(),
          businessTimingGateway: _RecordingTimingGateway(),
          auditSink: _RecordingAuditSink(),
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        // ignore: unawaited_futures
        server.listen((request) async {
          await routeRequest(
            request,
            guard,
            operatorWriteRouter: router,
          );
        });
        final client = HttpClient();
        try {
          final response = await _httpJson(
            client,
            Uri.parse('http://${server.address.host}:${server.port}')
                .resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-001',
            body: const <String, Object?>{'businessName': 'X'},
          );
          expect(response.statusCode, anyOf(401, 403));
        } finally {
          client.close(force: true);
          await server.close(force: true);
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
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-001',
            body: const <String, Object?>{'businessName': 'X'},
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('forbidden'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 idempotency_key_missing when header is absent', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: null,
            body: const <String, Object?>{'businessName': 'X'},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_missing'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 idempotency_key_too_long when header > 200 chars', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final tooLong = 'x' * 201;
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: tooLong,
            body: const <String, Object?>{'businessName': 'X'},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_too_long'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_business_name on empty body field', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-bad-name',
            body: const <String, Object?>{'businessName': '   '},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_business_name'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_currency_code', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-bad-currency',
            body: const <String, Object?>{'currencyCode': 'usd'},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_currency_code'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('idempotent replay with same body returns the same response',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final firstResp = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-replay',
            body: const <String, Object?>{'businessName': 'Replay Co'},
          );
          final secondResp = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-replay',
            body: const <String, Object?>{'businessName': 'Replay Co'},
          );
          expect(firstResp.statusCode, equals(200));
          expect(secondResp.statusCode, equals(200));
          // Same status (replay does not bump 200 to 201).
          expect(firstResp.body, equals(secondResp.body));
          // Gateway saw the call exactly once.
          expect(ctx.accountGateway.patchCalls, equals(1));
          // Audit was emitted once (replay does not double-audit).
          expect(ctx.auditSink.records, hasLength(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('409 idempotency_key_conflict on same key, different body',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-collide',
            body: const <String, Object?>{'businessName': 'A'},
          );
          final second = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-collide',
            body: const <String, Object?>{'businessName': 'B'},
          );
          expect(second.statusCode, equals(409));
          final body = jsonDecode(second.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_conflict'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('cross-tenant write impossible: gateway always sees JWT operator',
        () async {
      // Build two operator scopes; verify the gateway never sees
      // operator B even though the router is shared.
      await withRealHttp(() async {
        final verifier = _SettableVerifier();
        final accountGateway = _RecordingAccountGateway();
        final guard = ProxyRequestGuard(verifier: verifier);
        final router = OperatorWriteRouter(
          accountGateway: accountGateway,
          businessTimingGateway: _RecordingTimingGateway(),
          auditSink: _RecordingAuditSink(),
        );
        final server =
            await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        // ignore: unawaited_futures
        server.listen((request) async {
          await routeRequest(
            request,
            guard,
            operatorWriteRouter: router,
          );
        });
        final client = HttpClient();
        try {
          // Operator A patches.
          verifier.claims = const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
          final aResp = await _httpJson(
            client,
            Uri.parse('http://${server.address.host}:${server.port}')
                .resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-cross-a',
            body: const <String, Object?>{'businessName': 'A Inc'},
          );
          expect(aResp.statusCode, equals(200));
          expect(accountGateway.lastOperatorId, equals(_kOpA));

          // Operator B patches; gateway must see B, not A.
          verifier.claims = const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpB,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
          final bResp = await _httpJson(
            client,
            Uri.parse('http://${server.address.host}:${server.port}')
                .resolve(operatorAccountPatchPath),
            method: 'PATCH',
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-cross-b',
            body: const <String, Object?>{'businessName': 'B Inc'},
          );
          expect(bResp.statusCode, equals(200));
          expect(accountGateway.lastOperatorId, equals(_kOpB));
        } finally {
          client.close(force: true);
          await server.close(force: true);
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
  int patchCalls = 0;
  int loadCalls = 0;
  String? lastOperatorId;
  ValidatedOperatorAccountPatch? lastPatch;
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
    lastPatch = patch;
    return OperatorAccountRecord(
      operatorId: operatorId,
      businessName:
          (patch.fields['business_name'] as String?) ?? 'Recording Co',
      logoUrl: patch.fields['logo_url'] as String?,
      currencyCode:
          (patch.fields['preferred_currency'] as String?) ?? 'CAD',
      localeTag: (patch.fields['locale_tag'] as String?) ?? 'en-CA',
      weekStartDay:
          (patch.fields['week_start_day'] as String?) ?? 'monday',
      rolloverHour: (patch.fields['rollover_hour'] as int?) ?? 4,
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
      null;

  @override
  Future<OperatorBusinessTimingResolutionResult> resolveForLocation({
    required String operatorId,
    required String locationId,
    required String businessDate,
    String? actorUserId,
  }) async {
    return OperatorBusinessTimingResolutionResult(
      operatorId: operatorId,
      locationId: locationId,
      businessDate: businessDate,
      ianaTimezone: null,
      candidates: const <OperatorBusinessTimingResolutionCandidate>[],
    );
  }

  @override
  Future<List<OperatorBusinessTimingProfileRecord>> listProfiles({
    required String operatorId,
  }) async =>
      const <OperatorBusinessTimingProfileRecord>[];

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

class _RecordingAuditSink implements OperatorWriteAuditSink {
  final List<Map<String, Object?>> records = <Map<String, Object?>>[];

  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    records.add(<String, Object?>{
      'operatorId': operatorId,
      'actorUserId': actorUserId,
      'actorKind': actorKind,
      'eventKind': eventKind,
      'payload': payload,
      'occurredAt': occurredAt,
    });
  }
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpJson(
  HttpClient client,
  Uri uri, {
  required String method,
  required String authorization,
  required String? idempotencyKey,
  required Map<String, Object?> body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  request.headers.contentType = ContentType.json;
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  final encoded = utf8.encode(jsonEncode(body));
  request.contentLength = encoded.length;
  request.add(encoded);
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
