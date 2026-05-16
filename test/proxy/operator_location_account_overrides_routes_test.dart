// Wave 2 U-FU-hp11-account — proxy route tests for
// GET/PATCH /v1/operator/location-account-overrides/{location_id}.
//
// Pins the route shape end-to-end:
//
//   * 200 happy-path PATCH — returns the effective / override /
//     businessDefault triple; audit row emitted with the override +
//     businessDefault + effective field sets.
//   * 200 happy-path GET — returns the same triple without an
//     Idempotency-Key (the route is read-only).
//   * 400 on a missing / non-UUID location_id path segment.
//   * 400 on each per-field validation failure (currency / locale /
//     iana_timezone / rollover hour / contact_email / contact_phone /
//     no_fields_to_update).
//   * 404 location_not_found — the gateway returned locationNotFound.
//   * 403 forbidden — caller lacks operator_owner / operator_admin
//     (dispatcher-level gate).
//   * Idempotency replay — same Idempotency-Key + same body within
//     TTL returns the cached 200 response without re-invoking the
//     gateway.
//   * 503 when the handler is not configured (null injection).
//   * Cross-tenant isolation — gateway sees JWT operatorId only.
//
// The pure decoder (`decodeLocationAccountOverridesPatchBody`) is
// covered by its own group at the bottom for fast feedback on
// validation rules without standing up HTTP.

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
const String _kTargetLoc = '55555555-5555-5555-5555-555555555555';

const String _kPath =
    '/v1/operator/location-account-overrides/$_kTargetLoc';

void main() {
  group('PATCH /v1/operator/location-account-overrides/{location_id}',
      () {
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
      _StubOverridesGateway gateway,
      _RecordingAuditSink auditSink,
      _SettableVerifier verifier,
    })> spinUp({
      ProxyJwtClaims? initialClaims,
      LocationAccountOverridesOutcome? outcomeOverride,
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
      final gateway = _StubOverridesGateway(outcomeOverride: outcomeOverride);
      final auditSink = _RecordingAuditSink();
      final handler = registerHandler
          ? OperatorLocationAccountOverridesHandler(gateway: gateway)
          : null;
      final router = OperatorWriteRouter(
        accountGateway: _UnusedAccountGateway(),
        businessTimingGateway: _UnusedTimingGateway(),
        auditSink: auditSink,
        locationAccountOverridesHandler: handler,
      );
      final server =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
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

    test('200 happy path PATCH returns the resolved triple + audits',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(_kPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-1',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'Europe/London',
              'currencyCode': 'GBP',
            },
          );
          expect(response.statusCode, equals(200));
          final decoded =
              jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['operatorId'], equals(_kOpA));
          expect(decoded['locationId'], equals(_kTargetLoc));
          final effective =
              (decoded['effective'] as Map).cast<String, Object?>();
          expect(effective['ianaTimezone'], equals('Europe/London'));
          expect(effective['currencyCode'], equals('GBP'));
          // Audit row emitted with the field triple.
          final auditedEvents =
              ctx.auditSink.events.map((e) => e.eventKind).toList();
          expect(
            auditedEvents,
            contains('operator_location_account_overrides_updated'),
          );
          final payload = ctx.auditSink.events.last.payload;
          expect(payload['location_id'], equals(_kTargetLoc));
          expect(payload['override'], isA<Map>());
          expect(payload['business_default'], isA<Map>());
          expect(payload['effective'], isA<Map>());
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('200 happy path GET returns the triple without Idempotency-Key',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(_kPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final decoded =
              jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['locationId'], equals(_kTargetLoc));
          // GET MUST NOT emit an audit row (read-only).
          final auditedKinds =
              ctx.auditSink.events.map((e) => e.eventKind).toSet();
          expect(
            auditedKinds.contains(
              'operator_location_account_overrides_updated',
            ),
            isFalse,
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_location_id on a non-UUID path segment', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/operator/location-account-overrides/not-a-uuid',
            ),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-2',
            jsonBody: <String, Object?>{
              'currencyCode': 'USD',
            },
          );
          expect(response.statusCode, equals(400));
          final decoded =
              jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_location_id'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_iana_timezone on bogus tz', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(_kPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-3',
            jsonBody: <String, Object?>{
              'ianaTimezone': 'Mars/Olympus',
            },
          );
          expect(response.statusCode, equals(400));
          final decoded =
              jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_iana_timezone'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_rollover_hour on out-of-range value', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(_kPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-4',
            jsonBody: <String, Object?>{
              'businessDayRolloverHour': 25,
            },
          );
          expect(response.statusCode, equals(400));
          final decoded =
              jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_rollover_hour'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 no_fields_to_update on empty body', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(_kPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-5',
            jsonBody: const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          final decoded =
              jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('no_fields_to_update'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '404 location_not_found when the gateway returns locationNotFound',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            outcomeOverride:
                const LocationAccountOverridesOutcome.locationNotFound(),
          );
          try {
            final response = await _httpPatch(
              ctx.client,
              ctx.baseUri.resolve(_kPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-6',
              jsonBody: <String, Object?>{
                'currencyCode': 'USD',
              },
            );
            expect(response.statusCode, equals(404));
            final decoded =
                jsonDecode(response.body) as Map<String, Object?>;
            expect(decoded['error'], equals('location_not_found'));
            // Audit row MUST NOT fire on failure.
            expect(
              ctx.auditSink.events
                  .map((e) => e.eventKind)
                  .where(
                    (k) => k == 'operator_location_account_overrides_updated',
                  ),
              isEmpty,
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '403 when caller lacks operator_owner / operator_admin',
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
              ctx.baseUri.resolve(_kPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-7',
              jsonBody: <String, Object?>{
                'currencyCode': 'USD',
              },
            );
            expect(response.statusCode, equals(403));
            expect(ctx.gateway.patchCalls, equals(0));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('503 when handler is not configured (null injection)',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(registerHandler: false);
        try {
          final response = await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(_kPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-8',
            jsonBody: <String, Object?>{
              'currencyCode': 'USD',
            },
          );
          expect(response.statusCode, equals(503));
          final decoded =
              jsonDecode(response.body) as Map<String, Object?>;
          expect(
            decoded['error'],
            equals('operator_location_account_overrides_not_configured'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'idempotency replay returns cached 200 without re-invoking gateway',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final body = <String, Object?>{'currencyCode': 'USD'};
            final first = await _httpPatch(
              ctx.client,
              ctx.baseUri.resolve(_kPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-replay',
              jsonBody: body,
            );
            expect(first.statusCode, equals(200));
            expect(ctx.gateway.patchCalls, equals(1));
            final second = await _httpPatch(
              ctx.client,
              ctx.baseUri.resolve(_kPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-replay',
              jsonBody: body,
            );
            expect(second.statusCode, equals(200));
            expect(ctx.gateway.patchCalls, equals(1));
            expect(second.body, equals(first.body));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('cross-tenant isolation: gateway sees JWT operatorId only',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          await _httpPatch(
            ctx.client,
            ctx.baseUri.resolve(_kPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-tnA',
            jsonBody: <String, Object?>{'currencyCode': 'USD'},
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
            ctx.baseUri.resolve(_kPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-tnB',
            jsonBody: <String, Object?>{'currencyCode': 'EUR'},
          );
          expect(ctx.gateway.lastOperatorId, equals(_kOpB));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('decodeLocationAccountOverridesPatchBody', () {
    test('rejects an empty body with no_fields_to_update', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{},
      );
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('no_fields_to_update'));
    });

    test('accepts a single-field happy path', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{'currencyCode': 'USD'},
      );
      expect(decode.ok, isTrue);
      expect(decode.patch?.currencyCode, equals('USD'));
      expect(decode.patch?.clearCurrencyCode, isFalse);
    });

    test('explicit null on a field flips the clear flag', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{'currencyCode': null},
      );
      expect(decode.ok, isTrue);
      expect(decode.patch?.currencyCode, isNull);
      expect(decode.patch?.clearCurrencyCode, isTrue);
    });

    test('rejects malformed currency code', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{'currencyCode': 'us'},
      );
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('invalid_currency_code'));
    });

    test('rejects malformed locale code', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{'localeCode': 'EN_US'},
      );
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('invalid_locale_code'));
    });

    test('rejects bogus IANA timezone', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{'ianaTimezone': 'Mars/Olympus'},
      );
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('invalid_iana_timezone'));
    });

    test('rejects rollover hour out of range', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{'businessDayRolloverHour': 24},
      );
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('invalid_rollover_hour'));
    });

    test('rejects contactEmail without @', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{'contactEmail': 'no-at-symbol'},
      );
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('invalid_contact_email'));
    });

    test('rejects empty contactPhone', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{'contactPhone': '   '},
      );
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('invalid_contact_phone'));
    });

    test('accepts the full kitchen-sink valid body', () {
      final decode = decodeLocationAccountOverridesPatchBody(
        const <String, Object?>{
          'ianaTimezone': 'Europe/London',
          'localeCode': 'en-GB',
          'currencyCode': 'GBP',
          'businessDayRolloverHour': 4,
          'contactEmail': 'ops@example.com',
          'contactPhone': '+44 20 7000 0000',
        },
      );
      expect(decode.ok, isTrue);
      final patch = decode.patch!;
      expect(patch.ianaTimezone, equals('Europe/London'));
      expect(patch.localeCode, equals('en-GB'));
      expect(patch.currencyCode, equals('GBP'));
      expect(patch.businessDayRolloverHour, equals(4));
      expect(patch.contactEmail, equals('ops@example.com'));
      expect(patch.contactPhone, equals('+44 20 7000 0000'));
      expect(patch.changedFieldNames.length, equals(6));
    });
  });

  group('isOperatorLocationAccountOverridesPath', () {
    test('matches the exact prefix + single uuid segment', () {
      expect(
        isOperatorLocationAccountOverridesPath(
          '/v1/operator/location-account-overrides/$_kTargetLoc',
        ),
        isTrue,
      );
    });
    test('rejects nested paths', () {
      expect(
        isOperatorLocationAccountOverridesPath(
          '/v1/operator/location-account-overrides/$_kTargetLoc/extra',
        ),
        isFalse,
      );
    });
    test('rejects the prefix alone (no location id)', () {
      expect(
        isOperatorLocationAccountOverridesPath(
          '/v1/operator/location-account-overrides/',
        ),
        isFalse,
      );
    });
  });
}

class _StubOverridesGateway
    implements LocationAccountOverridesWriteGateway {
  _StubOverridesGateway({LocationAccountOverridesOutcome? outcomeOverride})
      : _outcomeOverride = outcomeOverride;

  final LocationAccountOverridesOutcome? _outcomeOverride;

  int patchCalls = 0;
  int loadCalls = 0;
  String? lastOperatorId;
  String? lastLocationId;
  ValidatedLocationAccountOverridesPatch? lastPatch;

  @override
  Future<LocationAccountOverridesOutcome> loadOverrides({
    required String operatorId,
    required String actorUserId,
    required String locationId,
    required String adminReason,
  }) async {
    loadCalls += 1;
    lastOperatorId = operatorId;
    lastLocationId = locationId;
    final override = _outcomeOverride;
    if (override != null) return override;
    return LocationAccountOverridesOutcome.ok(_okRecord(operatorId));
  }

  @override
  Future<LocationAccountOverridesOutcome> patchOverrides({
    required String operatorId,
    required String actorUserId,
    required String locationId,
    required ValidatedLocationAccountOverridesPatch patch,
    required String adminReason,
  }) async {
    patchCalls += 1;
    lastOperatorId = operatorId;
    lastLocationId = locationId;
    lastPatch = patch;
    final override = _outcomeOverride;
    if (override != null) return override;
    return LocationAccountOverridesOutcome.ok(
      LocationAccountOverridesRecord(
        operatorId: operatorId,
        locationId: locationId,
        effective: LocationAccountOverridesFieldSet(
          ianaTimezone: patch.ianaTimezone ?? 'America/Toronto',
          localeCode: patch.localeCode ?? 'en-US',
          currencyCode: patch.currencyCode ?? 'USD',
          businessDayRolloverHour: patch.businessDayRolloverHour ?? 4,
          contactEmail: patch.contactEmail,
          contactPhone: patch.contactPhone,
        ),
        override: LocationAccountOverridesFieldSet(
          ianaTimezone: patch.ianaTimezone,
          localeCode: patch.localeCode,
          currencyCode: patch.currencyCode,
          businessDayRolloverHour: patch.businessDayRolloverHour,
          contactEmail: patch.contactEmail,
          contactPhone: patch.contactPhone,
        ),
        businessDefault: const LocationAccountOverridesFieldSet(
          ianaTimezone: 'America/Toronto',
          localeCode: 'en-US',
          currencyCode: 'USD',
          businessDayRolloverHour: 4,
        ),
        updatedAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
      ),
    );
  }

  LocationAccountOverridesRecord _okRecord(String operatorId) {
    return LocationAccountOverridesRecord(
      operatorId: operatorId,
      locationId: _kTargetLoc,
      effective: const LocationAccountOverridesFieldSet(
        ianaTimezone: 'America/Toronto',
        localeCode: 'en-US',
        currencyCode: 'USD',
        businessDayRolloverHour: 4,
      ),
      override: const LocationAccountOverridesFieldSet(),
      businessDefault: const LocationAccountOverridesFieldSet(
        ianaTimezone: 'America/Toronto',
        localeCode: 'en-US',
        currencyCode: 'USD',
        businessDayRolloverHour: 4,
      ),
      updatedAt: DateTime.utc(2026, 5, 14, 12, 0, 0),
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
  const _HttpResponseSnapshot({
    required this.statusCode,
    required this.body,
  });
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

Future<_HttpResponseSnapshot> _httpGet(
  HttpClient client,
  Uri uri, {
  required String authorization,
}) async {
  final request = await client.openUrl('GET', uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, authorization);
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
