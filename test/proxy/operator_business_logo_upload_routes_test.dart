// Wave 2 W-5 — proxy route tests for POST /v1/operator/business/logo.
//
// Validates:
//   * 200 happy path returns the logoUrl from the uploader stub
//   * 400 invalid_filename for non-.png filenames
//   * 400 invalid_content for missing/empty base64
//   * 400 invalid_png_magic for bytes that do not start with the
//     PNG magic prefix
//   * 413 payload_too_large for payloads over the 600 KB cap
//   * 503 when the uploader is unconfigured (no Azure env vars)
//   * 403 when caller lacks operator_owner role
//   * Cross-tenant isolation: gateway sees JWT operatorId only
//   * Audit sink records `operator_business_logo_uploaded` on success

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

void main() {
  group('POST /v1/operator/business/logo', () {
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
      _StubBusinessLogoUploader uploader,
      _RecordingAuditSink auditSink,
      _SettableVerifier verifier,
    })> spinUp({
      ProxyJwtClaims? initialClaims,
      bool uploaderConfigured = true,
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
      final uploader = _StubBusinessLogoUploader(
        configured: uploaderConfigured,
      );
      final auditSink = _RecordingAuditSink();
      final logoHandler = BusinessLogoUploadHandler(uploader: uploader);
      final router = OperatorWriteRouter(
        accountGateway: _UnusedAccountGateway(),
        businessTimingGateway: _UnusedTimingGateway(),
        auditSink: auditSink,
        businessLogoUploadHandler: logoHandler,
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
        uploader: uploader,
        auditSink: auditSink,
        verifier: verifier,
      );
    }

    List<int> validPngBytes({int trailingZeros = 16}) {
      return <int>[
        ...kPngMagic,
        for (var i = 0; i < trailingZeros; i++) 0x00,
      ];
    }

    test('200 happy path returns the uploaded logoUrl', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final body = <String, Object?>{
            'filename': 'logo.png',
            'contentBase64': base64Encode(validPngBytes()),
          };
          final response = await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessLogoUploadPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-key-1',
            jsonBody: body,
          );
          expect(response.statusCode, equals(200));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['logoUrl'], startsWith('https://stub.example/'));
          expect(decoded['sizeBytes'], equals(24));
          expect(ctx.uploader.uploadCalls, equals(1));
          expect(ctx.uploader.lastOperatorId, equals(_kOpA));
          expect(
            ctx.auditSink.events,
            contains('operator_business_logo_uploaded'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_filename when filename does not end in .png',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessLogoUploadPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-2',
            jsonBody: <String, Object?>{
              'filename': 'logo.jpg',
              'contentBase64': base64Encode(validPngBytes()),
            },
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_filename'));
          expect(ctx.uploader.uploadCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_content when contentBase64 is missing', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessLogoUploadPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-3',
            jsonBody: <String, Object?>{
              'filename': 'logo.png',
            },
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_content'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 invalid_png_magic when bytes do not start with PNG header',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessLogoUploadPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-4',
            jsonBody: <String, Object?>{
              'filename': 'logo.png',
              'contentBase64': base64Encode(<int>[0xFF, 0xD8, 0xFF, 0xE0]),
            },
          );
          expect(response.statusCode, equals(400));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('invalid_png_magic'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('413 payload_too_large when bytes exceed the 600 KB cap',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final big = <int>[
            ...kPngMagic,
            for (var i = 0; i < kBusinessLogoMaxBytes; i++) 0x00,
          ];
          final response = await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessLogoUploadPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-5',
            jsonBody: <String, Object?>{
              'filename': 'logo.png',
              'contentBase64': base64Encode(big),
            },
          );
          expect(response.statusCode, equals(413));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(decoded['error'], equals('payload_too_large'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('503 when uploader is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(uploaderConfigured: false);
        try {
          final response = await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessLogoUploadPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-6',
            jsonBody: <String, Object?>{
              'filename': 'logo.png',
              'contentBase64': base64Encode(validPngBytes()),
            },
          );
          expect(response.statusCode, equals(503));
          final decoded = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            decoded['error'],
            equals('business_logo_uploader_not_configured'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('403 when caller lacks operator_owner',
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
          final response = await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessLogoUploadPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-7',
            jsonBody: <String, Object?>{
              'filename': 'logo.png',
              'contentBase64': base64Encode(validPngBytes()),
            },
          );
          expect(response.statusCode, equals(403));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('cross-tenant isolation: uploader sees JWT operatorId only',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessLogoUploadPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-A',
            jsonBody: <String, Object?>{
              'filename': 'logo.png',
              'contentBase64': base64Encode(validPngBytes()),
            },
          );
          expect(ctx.uploader.lastOperatorId, equals(_kOpA));

          ctx.verifier.claims = const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpB,
            locationId: _kLoc,
            roles: <String>['operator_owner'],
          );
          await _httpPost(
            ctx.client,
            ctx.baseUri.resolve(operatorBusinessLogoUploadPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-B',
            jsonBody: <String, Object?>{
              'filename': 'logo.png',
              'contentBase64': base64Encode(validPngBytes()),
            },
          );
          expect(ctx.uploader.lastOperatorId, equals(_kOpB));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('decodeBusinessLogoUploadBody', () {
    test('rejects missing filename', () {
      final decode =
          decodeBusinessLogoUploadBody(const <String, Object?>{});
      expect(decode.ok, isFalse);
      expect(decode.status, equals(400));
    });

    test('rejects malformed base64', () {
      final decode = decodeBusinessLogoUploadBody(const <String, Object?>{
        'filename': 'logo.png',
        'contentBase64': 'not-base64!@#',
      });
      expect(decode.ok, isFalse);
      expect(decode.body?['error'], equals('invalid_content'));
    });

    test('accepts valid PNG payload', () {
      final decode = decodeBusinessLogoUploadBody(<String, Object?>{
        'filename': 'logo.png',
        'contentBase64': base64Encode(<int>[
          ...kPngMagic,
          0x00,
          0x01,
          0x02,
          0x03,
        ]),
      });
      expect(decode.ok, isTrue);
      expect(decode.pngBytes, isNotNull);
      expect(decode.pngBytes!.length, equals(kPngMagic.length + 4));
    });
  });
}

class _StubBusinessLogoUploader implements BusinessLogoBlobUploader {
  _StubBusinessLogoUploader({required this.configured});

  final bool configured;
  int uploadCalls = 0;
  String? lastOperatorId;

  @override
  bool get isConfigured => configured;

  @override
  String get unconfiguredReason =>
      configured ? '' : 'stub uploader marked unconfigured';

  @override
  Future<BusinessLogoUploadResult> upload({
    required String operatorId,
    required List<int> pngBytes,
  }) async {
    uploadCalls += 1;
    lastOperatorId = operatorId;
    return BusinessLogoUploadResult(
      logoUrl: 'https://stub.example/operators/$operatorId/logo.png',
      sizeBytes: pngBytes.length,
    );
  }
}

class _RecordingAuditSink implements OperatorWriteAuditSink {
  final List<String> events = <String>[];

  @override
  Future<void> record({
    required String operatorId,
    required String actorUserId,
    required String actorKind,
    required String eventKind,
    required Map<String, Object?> payload,
    required DateTime occurredAt,
  }) async {
    events.add(eventKind);
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

Future<_HttpResponseSnapshot> _httpPost(
  HttpClient client,
  Uri uri, {
  required String authorization,
  required String idempotencyKey,
  required Map<String, Object?> jsonBody,
}) async {
  final request = await client.openUrl('POST', uri);
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
