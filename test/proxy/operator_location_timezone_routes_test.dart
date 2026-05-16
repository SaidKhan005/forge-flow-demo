// Wave 2 W-6 backend — proxy route tests for
// PATCH /v1/operator/location-timezone.
//
// Closes the backend half of W-6 (PR #682 shipped the frontend with
// the wire contract pinned). Validates:
//
//   * 200 happy path — returns operatorId/locationId/ianaTimezone/
//     previousIanaTimezone/updatedAt; audit row emitted with
//     `previous_tz` + `new_tz`.
//   * 400 invalid_timezone — body missing `ianaTimezone`, blank, or
//     not in the IANA tz database.
//   * 400 no_primary_location — operator has no primary_location_id
//     (gateway returned noPrimaryLocation).
//   * 404 location_not_found — primary-location pointer dangling
//     (gateway returned locationNotFound).
//   * 403 forbidden — caller lacks operator_owner / operator_admin
//     role (dispatcher-level gate).
//   * Idempotency replay — same Idempotency-Key + same body within
//     TTL returns the cached 200 response without re-invoking the
//     gateway.
//   * Cross-tenant isolation — gateway sees JWT operatorId only.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/operator_routes.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kOpB = '22222222-2222-2222-2222-222222222222';
const String _kLoc = '33333333-3333-3333-3333-333333333333';
const String _kPrimaryLoc =
    '55555555-5555-5555-5555-555555555555';
const String _kUser = '44444444-4444-4444-4444-444444444444';

void main() {
  group('PATCH /v1/operator/location-timezone', () {
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
      _StubLocationTimezoneGateway gateway,
      _RecordingAuditSink auditSink,
      _SettableVerifier verifier,
    })> spinUp({
      ProxyJwtClaims? initialClaims,
      LocationTimezoneUpdateOutcome? outcomeOverride,
      bool registerHandler = true,
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
      final gateway = _StubLocationTimezoneGateway(
        outcomeOverride: outcomeOverride,
      );
      final auditSink = _RecordingAuditSink();
      final handler = registerHandler
          ? OperatorLocationTimezoneHandler(gateway: gateway)
          : null;
      final router = OperatorWriteRouter(
        accountGateway: _UnusedAccountGateway(),
        businessTimingGateway: _UnusedTimingGateway(),
        auditSink: auditSink,
        locationTimezoneHandler: handler,
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
      final baseUri =
          Uri.parse('http://${server.address.host}:${server.port}');
      return (
        server: server,
        client: client,
        baseUri: baseUri,
        gateway: gateway,
        auditSink: auditSink,
        verifier: verifier,
      );
    }

    test('200 happy path returns the resolved timezone record', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-key-1',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'America/Toronto',
            },
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['operatorId'], equals(_kOpA));
          expect(decoded['locationId'], equals(_kPrimaryLoc));
          expect(decoded['ianaTimezone'], equals('America/Toronto'));
          expect(decoded['previousIanaTimezone'], equals('UTC'));
          expect(decoded['updatedAt'], isA<String>());
          expect(ctx.gateway.updateCalls, equals(1));
          expect(ctx.gateway.lastOperatorId, equals(_kOpA));
          expect(ctx.gateway.lastIanaTimezone, equals('America/Toronto'));
          final auditedEvents = ctx.auditSink.events
              .map((e) => e.eventKind)
              .toList();
          expect(
            auditedEvents,
            contains('operator_location_timezone_updated'),
          );
          final auditPayload = ctx.auditSink.events.last.payload;
          expect(auditPayload['previous_tz'], equals('UTC'));
          expect(auditPayload['new_tz'], equals('America/Toronto'));
          expect(auditPayload['location_id'], equals(_kPrimaryLoc));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_timezone when ianaTimezone is missing', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-2',
            jsonBody: const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_timezone'));
          expect(ctx.gateway.updateCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_timezone when value is not in IANA tz database',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-3',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'Mars/Olympus',
            },
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_timezone'));
          expect(ctx.gateway.updateCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_timezone when value is blank', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-4',
            jsonBody: <String, Object?>{
              'ianaTimezone': '   ',
            },
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_timezone'));
          expect(ctx.gateway.updateCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 no_primary_location when operator has no primary',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          outcomeOverride:
              const LocationTimezoneUpdateOutcome.noPrimaryLocation(),
        );
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-5',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'America/Toronto',
            },
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('no_primary_location'));
          // Audit row must NOT fire on a failure.
          expect(
            ctx.auditSink.events
                .map((e) => e.eventKind)
                .where((k) => k == 'operator_location_timezone_updated'),
            isEmpty,
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('404 location_not_found when primary pointer is dangling',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          outcomeOverride:
              const LocationTimezoneUpdateOutcome.locationNotFound(),
        );
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-6',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'America/Toronto',
            },
          );
          expect(response.statusCode, equals(404));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('location_not_found'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('403 when caller lacks operator_owner / operator_admin',
        () async {
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
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-7',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'America/Toronto',
            },
          );
          expect(response.statusCode, equals(403));
          expect(ctx.gateway.updateCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('503 when handler is not configured (null injection)',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(registerHandler: false);
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-8',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'America/Toronto',
            },
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            decoded['error'],
            equals('operator_location_timezone_not_configured'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
        'idempotency replay returns cached 200 without re-invoking '
        'gateway', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final body = <String, Object?>{
            'ianaTimezone': 'America/Toronto',
          };
          final first = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-replay',
            jsonBody: body,
          );
          expect(first.statusCode, equals(200));
          expect(ctx.gateway.updateCalls, equals(1));
          final second = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-replay',
            jsonBody: body,
          );
          expect(second.statusCode, equals(200));
          // Gateway call count must not increase on replay.
          expect(ctx.gateway.updateCalls, equals(1));
          // Both responses carry the same payload.
          expect(second.body, equals(first.body));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('cross-tenant isolation: gateway sees JWT operatorId only',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-A',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'America/Toronto',
            },
          );
          expect(ctx.gateway.lastOperatorId, equals(_kOpA));

          ctx.verifier.claims = const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpB,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
          await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(operatorLocationTimezonePath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-B',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'Europe/London',
            },
          );
          expect(ctx.gateway.lastOperatorId, equals(_kOpB));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('decodeLocationTimezoneBody', () {
    test('rejects missing ianaTimezone', () {
      final decode =
          decodeLocationTimezoneBody(const <String, Object?>{});
      expect(decode.ok, isFalse);
      expect(decode.status, equals(400));
      expect(decode.body?['error'], equals('invalid_timezone'));
    });

    test('rejects blank ianaTimezone', () {
      final decode = decodeLocationTimezoneBody(const <String, Object?>{
        'ianaTimezone': '   ',
      });
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('invalid_timezone'));
    });

    test('rejects non-IANA tz name', () {
      final decode = decodeLocationTimezoneBody(const <String, Object?>{
        'ianaTimezone': 'Mars/Olympus',
      });
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('invalid_timezone'));
    });

    test('accepts the 14-option shortlist + custom names', () {
      const shortlist = <String>[
        'America/Toronto',
        'America/New_York',
        'America/Chicago',
        'America/Denver',
        'America/Phoenix',
        'America/Los_Angeles',
        'America/Anchorage',
        'America/Halifax',
        'America/St_Johns',
        'America/Mexico_City',
        'Europe/London',
        'Europe/Paris',
        'Australia/Sydney',
        'UTC',
      ];
      for (final tz in shortlist) {
        final decode = decodeLocationTimezoneBody(<String, Object?>{
          'ianaTimezone': tz,
        });
        expect(decode.ok, isTrue, reason: 'expected $tz to be accepted');
        expect(decode.ianaTimezone, equals(tz));
      }
      // Sanity: a non-shortlist but valid IANA name passes.
      final decode = decodeLocationTimezoneBody(const <String, Object?>{
        'ianaTimezone': 'Asia/Tokyo',
      });
      expect(decode.ok, isTrue);
    });
  });
}

class _StubLocationTimezoneGateway
    implements OperatorLocationTimezoneWriteGateway {
  _StubLocationTimezoneGateway({LocationTimezoneUpdateOutcome? outcomeOverride})
      : _outcomeOverride = outcomeOverride;

  final LocationTimezoneUpdateOutcome? _outcomeOverride;

  int updateCalls = 0;
  String? lastOperatorId;
  String? lastIanaTimezone;

  @override
  Future<LocationTimezoneUpdateOutcome> updateLocationTimezone({
    required String operatorId,
    required String ianaTimezone,
    required String adminReason,
  }) async {
    updateCalls += 1;
    lastOperatorId = operatorId;
    lastIanaTimezone = ianaTimezone;
    final override = _outcomeOverride;
    if (override != null) return override;
    return LocationTimezoneUpdateOutcome.ok(
      LocationTimezoneRecord(
        operatorId: operatorId,
        locationId: _kPrimaryLoc,
        ianaTimezone: ianaTimezone,
        previousIanaTimezone: 'UTC',
        updatedAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
      ),
    );
  }
}

class _AuditEvent {
  _AuditEvent({required this.eventKind, required this.payload});
  final String eventKind;
  final Map<String, Object?> payload;
}

class _RecordingAuditSink implements OperatorWriteAuditSink {
  final List<_AuditEvent> events = <_AuditEvent>[];

  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    events.add(_AuditEvent(eventKind: eventKind, payload: payload));
  }
}

class _UnusedAccountGateway implements OperatorAccountWriteGateway {
  @override
  Future<OperatorAccountRecord> patchAccount({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedOperatorAccountPatch patch,
    required String adminReason,
  }) async =>
      throw UnimplementedError();

  @override
  Future<OperatorAccountRecord?> loadAccount({
    required String operatorId,
  }) async =>
      null;
}

class _UnusedTimingGateway implements OperatorBusinessTimingWriteGateway {
  @override
  Future<OperatorBusinessTimingProfileRecord> createProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async =>
      throw UnimplementedError();

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
  }) async =>
      throw UnimplementedError();

  @override
  Future<OperatorBusinessTimingProfileRecord> updateProfile({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required String profileId,
    required ValidatedBusinessTimingProfile validated,
    required String adminReason,
  }) async =>
      throw UnimplementedError();
}

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;
  Object? error;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final err = error;
    if (err != null) throw err;
    final c = claims;
    if (c == null) throw ProxyJwtVerificationError('no claims set');
    return c;
  }
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpPatch(
  HttpClient client,
  Uri uri, {
  required String authorization,
  required String idempotencyKey,
  required Map<String, Object?> jsonBody,
}) async {
  final request = await client.openUrl('PATCH', uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  request.headers.set('Idempotency-Key', idempotencyKey);
  request.headers.contentType = ContentType.json;
  final encoded = utf8.encode(jsonEncode(jsonBody));
  request.contentLength = encoded.length;
  request.add(encoded);
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
