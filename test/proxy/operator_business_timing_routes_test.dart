// Phase 11W.7 / Wave A2 - HTTP-level tests for the four
// business-timing-profile write routes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/business_timing/business_timing_profile_validator.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kOpB = '22222222-2222-2222-2222-222222222222';
const String _kLoc = '33333333-3333-3333-3333-333333333333';
const String _kUser = '44444444-4444-4444-4444-444444444444';
const String _kProfileA = '55555555-5555-5555-5555-555555555555';

Map<String, Object?> _validProfileBody({
  String scopeKind = 'operator',
  String? scopeId,
}) {
  return <String, Object?>{
    'scopeKind': scopeKind,
    'scopeId': scopeId ?? _kOpA,
    'effectiveAtBusinessDate': '2026-05-06',
    'ianaTimezone': 'America/Toronto',
    'weekStartDay': 'monday',
    'businessDayStartLocal': '04:00',
    'servicePeriods': const <Map<String, Object?>>[
      <String, Object?>{
        'key': 'lunch',
        'label': 'Lunch',
        'startLocal': '11:00',
        'endLocal': '15:00',
      },
      <String, Object?>{
        'key': 'dinner',
        'label': 'Dinner',
        'startLocal': '17:00',
        'endLocal': '22:00',
      },
    ],
  };
}

void main() {
  group('Operator business-timing-profile routes', () {
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
      _RecordingTimingGateway gateway,
      _RecordingAuditSink audit,
      _SettableVerifier verifier,
    })> spinUp({
      ProxyJwtClaims? initialClaims,
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
      final gateway = _RecordingTimingGateway();
      final audit = _RecordingAuditSink();
      final router = OperatorWriteRouter(
        accountGateway: _NoopAccountGateway(),
        businessTimingGateway: gateway,
        auditSink: audit,
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
        audit: audit,
        verifier: verifier,
      );
    }

    test('POST /v1/operator/business-timing-profiles - 201 happy path',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            method: 'POST',
            idempotencyKey: 'idem-create-1',
            body: _validProfileBody(),
          );
          expect(response.statusCode, equals(201));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['profileId'], equals(_kProfileA));
          expect(body['versionId'], equals(_kProfileA));
          expect(body['servicePeriods'], hasLength(2));
          expect(ctx.gateway.createCalls, equals(1));
          expect(ctx.audit.records, hasLength(1));
          expect(
            ctx.audit.records.single['eventKind'],
            equals('business_timing_profile_created'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('POST profile preserves service-period metadata', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final body = _validProfileBody();
          body['servicePeriods'] = const <Map<String, Object?>>[
            <String, Object?>{
              'key': 'brunch',
              'label': 'Weekend Brunch',
              'startLocal': '10:00',
              'endLocal': '14:00',
              'applicableDays': <int>[6, 7],
              'shortLabel': 'B',
              'sortOrder': 2,
            },
          ];
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            method: 'POST',
            idempotencyKey: 'idem-create-metadata',
            body: body,
          );
          expect(response.statusCode, equals(201));
          final json = jsonDecode(response.body) as Map<String, Object?>;
          final periods = json['servicePeriods'] as List<Object?>;
          final period = periods.single as Map<String, Object?>;
          expect(period['applicableDays'], equals(<int>[6, 7]));
          expect(period['shortLabel'], equals('B'));
          expect(period['sortOrder'], equals(2));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('POST profile - 400 on overlap', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final body = _validProfileBody();
          body['servicePeriods'] = const <Map<String, Object?>>[
            <String, Object?>{
              'key': 'lunch',
              'label': 'Lunch',
              'startLocal': '11:00',
              'endLocal': '15:00',
            },
            <String, Object?>{
              'key': 'late_lunch',
              'label': 'Late Lunch',
              'startLocal': '14:00',
              'endLocal': '16:00',
            },
          ];
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            method: 'POST',
            idempotencyKey: 'idem-overlap',
            body: body,
          );
          expect(response.statusCode, equals(400));
          final json = jsonDecode(response.body) as Map<String, Object?>;
          expect(json['error'], equals('service_period_overlap'));
          expect(ctx.gateway.createCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('POST profile - 400 invalid_iana_timezone', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final body = _validProfileBody();
          body['ianaTimezone'] = 'America/Atlantis';
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            method: 'POST',
            idempotencyKey: 'idem-tz',
            body: body,
          );
          expect(response.statusCode, equals(400));
          final json = jsonDecode(response.body) as Map<String, Object?>;
          expect(json['error'], equals('invalid_iana_timezone'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('POST profile - 403 forbidden when scopeKind=operator points at '
        'another operator', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            method: 'POST',
            idempotencyKey: 'idem-cross',
            body: _validProfileBody(scopeId: _kOpB),
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('forbidden'));
          expect(ctx.gateway.createCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH profile - 200 happy path', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.seedProfile(_kProfileA);
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(
              '$operatorBusinessTimingProfilePrefix$_kProfileA',
            ),
            method: 'PATCH',
            idempotencyKey: 'idem-patch-1',
            body: const <String, Object?>{
              'businessDayStartLocal': '03:00',
            },
          );
          expect(response.statusCode, equals(200));
          expect(ctx.gateway.updateCalls, equals(1));
          expect(ctx.audit.records, hasLength(1));
          expect(
            ctx.audit.records.single['eventKind'],
            equals('business_timing_profile_updated'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH profile - 404 when profile does not exist', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          // Do NOT seed; loadProfile returns null.
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(
              '$operatorBusinessTimingProfilePrefix$_kProfileA',
            ),
            method: 'PATCH',
            idempotencyKey: 'idem-missing',
            body: const <String, Object?>{
              'businessDayStartLocal': '03:00',
            },
          );
          expect(response.statusCode, equals(404));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('profile_not_found'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('POST add service-period - 201 happy path', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.seedProfile(_kProfileA);
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(
              '$operatorBusinessTimingProfilePrefix$_kProfileA/'
              'service-periods',
            ),
            method: 'POST',
            idempotencyKey: 'idem-add-period',
            body: const <String, Object?>{
              'key': 'late_night',
              'label': 'Late Night',
              'startLocal': '22:00',
              'endLocal': '02:00',
            },
          );
          expect(response.statusCode, equals(201));
          expect(ctx.gateway.replaceCalls, equals(1));
          expect(ctx.audit.records, hasLength(1));
          expect(
            ctx.audit.records.single['eventKind'],
            equals('business_timing_service_period_added'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('POST add service-period - 400 duplicate key', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.seedProfile(_kProfileA);
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(
              '$operatorBusinessTimingProfilePrefix$_kProfileA/'
              'service-periods',
            ),
            method: 'POST',
            idempotencyKey: 'idem-dup',
            body: const <String, Object?>{
              'key': 'lunch', // already present in seeded profile
              'label': 'Late Lunch',
              'startLocal': '17:30',
              'endLocal': '18:30',
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('duplicate_service_period_key'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH service-period by key - 200 happy path', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.seedProfile(_kProfileA);
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(
              '$operatorBusinessTimingProfilePrefix$_kProfileA/'
              'service-periods/lunch',
            ),
            method: 'PATCH',
            idempotencyKey: 'idem-patch-period',
            body: const <String, Object?>{
              'label': 'Renamed Lunch',
            },
          );
          expect(response.statusCode, equals(200));
          final json = jsonDecode(response.body) as Map<String, Object?>;
          final periods = json['servicePeriods'] as List<Object?>;
          final lunch = (periods.first as Map<String, Object?>);
          expect(lunch['applicableDays'], equals(<int>[1, 2, 3, 4, 5]));
          expect(lunch['shortLabel'], equals('L'));
          expect(lunch['sortOrder'], equals(1));
          expect(ctx.gateway.replaceCalls, equals(1));
          expect(ctx.audit.records, hasLength(1));
          expect(
            ctx.audit.records.single['eventKind'],
            equals('business_timing_service_period_updated'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH service-period - 400 when body includes "key"', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.seedProfile(_kProfileA);
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(
              '$operatorBusinessTimingProfilePrefix$_kProfileA/'
              'service-periods/lunch',
            ),
            method: 'PATCH',
            idempotencyKey: 'idem-rename',
            body: const <String, Object?>{
              'key': 'lunch_renamed',
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_field'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('PATCH service-period - 404 when key is unknown', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          ctx.gateway.seedProfile(_kProfileA);
          final response = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(
              '$operatorBusinessTimingProfilePrefix$_kProfileA/'
              'service-periods/breakfast',
            ),
            method: 'PATCH',
            idempotencyKey: 'idem-missing-period',
            body: const <String, Object?>{
              'label': 'Brunch',
            },
          );
          expect(response.statusCode, equals(404));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('service_period_not_found'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('idempotency replay returns same response without re-running '
        'gateway', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final first = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            method: 'POST',
            idempotencyKey: 'idem-replay-create',
            body: _validProfileBody(),
          );
          final second = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            method: 'POST',
            idempotencyKey: 'idem-replay-create',
            body: _validProfileBody(),
          );
          expect(first.statusCode, equals(201));
          expect(second.statusCode, equals(201));
          expect(first.body, equals(second.body));
          expect(ctx.gateway.createCalls, equals(1));
          expect(ctx.audit.records, hasLength(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('idempotency conflict returns 409 on same key + different body',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            method: 'POST',
            idempotencyKey: 'idem-collide',
            body: _validProfileBody(),
          );
          final variant = _validProfileBody();
          variant['businessDayStartLocal'] = '05:00';
          final second = await _httpJson(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessTimingProfilesPath),
            method: 'POST',
            idempotencyKey: 'idem-collide',
            body: variant,
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
  });
}

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final c = claims;
    if (c == null) throw ProxyJwtVerificationError('no claims');
    return c;
  }
}

class _NoopAccountGateway implements OperatorAccountWriteGateway {
  @override
  Future<OperatorAccountRecord> patchAccount({
    required String operatorId,
    required String actorUserId,
    required String idempotencyKey,
    required ValidatedOperatorAccountPatch patch,
    required String adminReason,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<OperatorAccountRecord?> loadAccount({
    required String operatorId,
  }) async =>
      null;
}

class _RecordingTimingGateway implements OperatorBusinessTimingWriteGateway {
  int createCalls = 0;
  int updateCalls = 0;
  int replaceCalls = 0;
  String? lastOperatorId;
  String? lastProfileId;

  final Map<String, OperatorBusinessTimingProfileRecord> _seeded =
      <String, OperatorBusinessTimingProfileRecord>{};

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
          applicableDays: <int>[1, 2, 3, 4, 5],
          shortLabel: 'L',
          sortOrder: 1,
        ),
        OperatorBusinessTimingServicePeriodRecord(
          key: 'dinner',
          label: 'Dinner',
          startLocal: '17:00',
          endLocal: '22:00',
          rollsPastMidnight: false,
          applicableDays: <int>[1, 2, 3, 4, 5, 6, 7],
          shortLabel: 'D',
          sortOrder: 2,
        ),
      ],
      createdAt: DateTime.utc(2026, 5, 1),
      updatedAt: DateTime.utc(2026, 5, 6),
    );
  }

  OperatorBusinessTimingProfileRecord _newRecord(
    String profileId,
    String operatorId,
    ValidatedBusinessTimingProfile validated,
  ) {
    return OperatorBusinessTimingProfileRecord(
      profileId: profileId,
      scopeKind: validated.scopeKind,
      scopeId: validated.scopeId,
      effectiveAtBusinessDate: validated.effectiveAtBusinessDate,
      ianaTimezone: validated.ianaTimezone,
      weekStartDay: validated.weekStartDay,
      businessDayStartLocal: validated.businessDayStartLocal,
      servicePeriods: <OperatorBusinessTimingServicePeriodRecord>[
        for (final p in validated.servicePeriods)
          OperatorBusinessTimingServicePeriodRecord(
            key: p.key,
            label: p.label,
            startLocal: p.startLocal,
            endLocal: p.endLocal,
            rollsPastMidnight: p.rollsPastMidnight,
            applicableDays: p.applicableDays,
            shortLabel: p.shortLabel,
            sortOrder: p.sortOrder,
          ),
      ],
      createdAt: DateTime.utc(2026, 5, 1),
      updatedAt: DateTime.utc(2026, 5, 6),
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
    createCalls += 1;
    lastOperatorId = operatorId;
    final record = _newRecord(_kProfileA, operatorId, validated);
    _seeded[_kProfileA] = record;
    return record;
  }

  @override
  Future<OperatorBusinessTimingProfileRecord?> loadProfile({
    required String operatorId,
    required String profileId,
  }) async {
    return _seeded[profileId];
  }

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
  Future<OperatorBusinessTimingResolutionResult> resolveForLocationAsSystem({
    required String operatorId,
    required String locationId,
    required String businessDate,
    required String reason,
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
  }) async {
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
    replaceCalls += 1;
    lastOperatorId = operatorId;
    lastProfileId = profileId;
    final existing = _seeded[profileId];
    if (existing == null) {
      throw const OperatorWriteRejected(
        code: 'profile_not_found',
        message: 'profile not found',
        statusCode: 404,
      );
    }
    final updated = OperatorBusinessTimingProfileRecord(
      profileId: existing.profileId,
      scopeKind: existing.scopeKind,
      scopeId: existing.scopeId,
      effectiveAtBusinessDate: existing.effectiveAtBusinessDate,
      ianaTimezone: existing.ianaTimezone,
      weekStartDay: existing.weekStartDay,
      businessDayStartLocal: existing.businessDayStartLocal,
      servicePeriods: <OperatorBusinessTimingServicePeriodRecord>[
        for (final p in mergedSet)
          OperatorBusinessTimingServicePeriodRecord(
            key: p.key,
            label: p.label,
            startLocal: p.startLocal,
            endLocal: p.endLocal,
            rollsPastMidnight: p.rollsPastMidnight,
            applicableDays: p.applicableDays,
            shortLabel: p.shortLabel,
            sortOrder: p.sortOrder,
          ),
      ],
      createdAt: existing.createdAt,
      updatedAt: DateTime.utc(2026, 5, 7),
    );
    _seeded[profileId] = updated;
    return updated;
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
    updateCalls += 1;
    lastOperatorId = operatorId;
    lastProfileId = profileId;
    final updated = _newRecord(profileId, operatorId, validated);
    _seeded[profileId] = updated;
    return updated;
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
  required String? idempotencyKey,
  required Map<String, Object?> body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
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
