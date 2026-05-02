// Phase 11A.3a — Proxy `/v1/admin/corpus/*` route tests.
//
// Coverage:
//   * Method-scoped role gate: GET admits super_admin + ff_support;
//     POST admits super_admin only.
//   * Idempotency-Key header is required on every non-GET route.
//   * Validation: missing fields surface structured 4xx; gateway
//     `CorpusAdminGatewayValidationError` projects through to the
//     response.
//   * 503 when the gateway is not configured; 401 when unauthenticated.
//
// The proxy itself is shared with the 11A.1 / 11A.2 admin route
// tests in `test/advisor_proxy_test.dart`; this file isolates the
// 11A.3a paths so a regression in the corpus contract surfaces here
// rather than buried in the master proxy test suite.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
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
      _StubVerifier verifier,
      _FakeCorpusAdminGateway gateway,
    })
  > spinUp({
    ProxyJwtClaims? initialClaims,
    bool gatewayConfigured = true,
    _FakeCorpusAdminGateway? customGateway,
  }) async {
    final verifier = _StubVerifier();
    verifier.claims = initialClaims;
    final guard = ProxyRequestGuard(verifier: verifier);
    final gateway = customGateway ?? _FakeCorpusAdminGateway();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        await routeRequest(
          request,
          guard,
          corpusAdminGateway: gatewayConfigured ? gateway : null,
          now: () => DateTime.utc(2026, 5, 1, 12),
          adminCorsAllowList: const <String>[
            'https://admin.forgeflow.app',
          ],
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

  test('GET /v1/admin/corpus/versions returns 503 without a gateway',
      () async {
    await withRealHttp(() async {
      final ctx = await spinUp(gatewayConfigured: false);
      try {
        final response = await _httpGet(
          ctx.client,
          ctx.baseUri.resolve(adminCorpusVersionsPath),
          authorization: 'Bearer fake.token',
        );
        expect(response.statusCode, equals(503));
        final body = jsonDecode(response.body) as Map<String, Object?>;
        expect(body['error'], equals('corpus_admin_not_configured'));
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('GET /v1/admin/corpus/versions admits ff_support (read-only)',
      () async {
    await withRealHttp(() async {
      final gateway = _FakeCorpusAdminGateway();
      gateway.listResult = const <Map<String, Object?>>[];
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
          ctx.baseUri.resolve(adminCorpusVersionsPath),
          authorization: 'Bearer fake.token',
        );
        expect(response.statusCode, equals(200));
        expect(gateway.lastActorUserId, equals('user_support'));
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test(
    'GET /v1/admin/corpus/versions rejects operator_owner (403)',
    () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: 'user_op',
            operatorId: 'op_x',
            locationId: 'loc_x',
            roles: <String>['operator_owner'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(adminCorpusVersionsPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST /v1/admin/corpus/upload rejects ff_support with 403',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeCorpusAdminGateway();
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
            'POST',
            ctx.baseUri.resolve(adminCorpusPreviewDiffPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'k1',
            body: const <String, Object?>{
              'file_name': 'm.md',
              'content_type': 'text/markdown',
              'content_base64': 'SGVsbG8=',
            },
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(body['required_roles'], contains('super_admin'));
          expect(body['required_roles'], isNot(contains('ff_support')));
          expect(gateway.lastPreviewFileName, isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST /v1/admin/corpus/commit rejects ff_support with 403',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeCorpusAdminGateway();
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
            'POST',
            ctx.baseUri.resolve(adminCorpusCommitPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'k-commit',
            body: const <String, Object?>{
              'preview_token': 'tok',
              'summary': '',
            },
          );
          expect(response.statusCode, equals(403));
          expect(gateway.lastCommitToken, isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST /v1/admin/corpus/rollback rejects ff_support with 403',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeCorpusAdminGateway();
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
            'POST',
            ctx.baseUri.resolve(adminCorpusRollbackPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'k-rb',
            body: const <String, Object?>{
              'target_version_id': 'v-target',
              'summary': '',
            },
          );
          expect(response.statusCode, equals(403));
          expect(gateway.lastRollbackTargetId, isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test('POST /v1/admin/corpus/commit requires Idempotency-Key', () async {
    await withRealHttp(() async {
      final ctx = await spinUp(
        initialClaims: const ProxyJwtClaims(
          userId: 'user_super',
          operatorId: 'op_super',
          locationId: 'loc_super',
          roles: <String>['super_admin'],
        ),
      );
      try {
        final response = await _httpJson(
          ctx.client,
          'POST',
          ctx.baseUri.resolve(adminCorpusCommitPath),
          authorization: 'Bearer fake.token',
          // intentionally omit Idempotency-Key
          body: const <String, Object?>{
            'preview_token': 'tok',
            'summary': '',
          },
        );
        expect(response.statusCode, equals(400));
        final body = jsonDecode(response.body) as Map<String, Object?>;
        expect(body['error'], equals('missing_idempotency_key'));
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test(
    'POST /v1/admin/corpus/preview-diff forwards bytes + idempotency key',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeCorpusAdminGateway();
        gateway.previewResult = const <String, Object?>{
          'preview_token': 'tok-1',
          'added': <Map<String, Object?>>[],
          'modified': <Map<String, Object?>>[],
          'inactivated': <Map<String, Object?>>[],
          'summary': 'no changes',
        };
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_super',
            operatorId: 'op_super',
            locationId: 'loc_super',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminCorpusPreviewDiffPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'k-preview',
            body: <String, Object?>{
              'file_name': 'methodology_seed.md',
              'content_type': 'text/markdown',
              'content_base64': base64Encode(utf8.encode('# Hello')),
            },
          );
          expect(response.statusCode, equals(200));
          expect(gateway.lastPreviewFileName, equals('methodology_seed.md'));
          expect(gateway.lastIdempotencyKey, equals('k-preview'));
          expect(gateway.lastActorUserId, equals('user_super'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test('POST /v1/admin/corpus/commit forwards token + summary', () async {
    await withRealHttp(() async {
      final gateway = _FakeCorpusAdminGateway();
      gateway.commitResult = const <String, Object?>{
        'version_id': 'new-version',
        'created_at': '2026-05-01T12:00:00.000Z',
        'summary': 'committed',
        'is_current': true,
        'chunk_count': 3,
      };
      final ctx = await spinUp(
        customGateway: gateway,
        initialClaims: const ProxyJwtClaims(
          userId: 'user_super',
          operatorId: 'op_super',
          locationId: 'loc_super',
          roles: <String>['super_admin'],
        ),
      );
      try {
        final response = await _httpJson(
          ctx.client,
          'POST',
          ctx.baseUri.resolve(adminCorpusCommitPath),
          authorization: 'Bearer fake.token',
          idempotencyKey: 'k-commit-1',
          body: const <String, Object?>{
            'preview_token': 'tok-1',
            'summary': 'committed',
          },
        );
        expect(response.statusCode, equals(200));
        expect(gateway.lastCommitToken, equals('tok-1'));
        expect(gateway.lastCommitSummary, equals('committed'));
        expect(gateway.lastIdempotencyKey, equals('k-commit-1'));
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('POST /v1/admin/corpus/rollback returns 404 on unknown target',
      () async {
    await withRealHttp(() async {
      final gateway = _FakeCorpusAdminGateway();
      gateway.rollbackResult = null;
      final ctx = await spinUp(
        customGateway: gateway,
        initialClaims: const ProxyJwtClaims(
          userId: 'user_super',
          operatorId: 'op_super',
          locationId: 'loc_super',
          roles: <String>['super_admin'],
        ),
      );
      try {
        final response = await _httpJson(
          ctx.client,
          'POST',
          ctx.baseUri.resolve(adminCorpusRollbackPath),
          authorization: 'Bearer fake.token',
          idempotencyKey: 'k-rollback',
          body: const <String, Object?>{
            'target_version_id': 'unknown',
            'summary': '',
          },
        );
        expect(response.statusCode, equals(404));
        final body = jsonDecode(response.body) as Map<String, Object?>;
        expect(body['error'], equals('unknown_version'));
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test(
    'POST /v1/admin/corpus/preview-diff projects validation error to 400',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeCorpusAdminGateway();
        gateway.raiseOnPreview = const CorpusAdminGatewayValidationError(
          statusCode: 400,
          code: 'binary_or_unsupported_file',
          message: 'binary content not allowed',
        );
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_super',
            operatorId: 'op_super',
            locationId: 'loc_super',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminCorpusPreviewDiffPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'k-preview',
            body: const <String, Object?>{
              'file_name': 'm.md',
              'content_type': 'text/markdown',
              'content_base64': 'SGVsbG8=',
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('binary_or_unsupported_file'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test('GET /v1/admin/corpus/versions without Authorization is 401',
      () async {
    await withRealHttp(() async {
      final ctx = await spinUp();
      try {
        final response = await _httpGet(
          ctx.client,
          ctx.baseUri.resolve(adminCorpusVersionsPath),
        );
        expect(response.statusCode, equals(401));
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('OPTIONS preflight admits Idempotency-Key header on commit',
      () async {
    await withRealHttp(() async {
      final ctx = await spinUp();
      try {
        final request = await ctx.client.openUrl(
          'OPTIONS',
          ctx.baseUri.resolve(adminCorpusCommitPath),
        );
        request.persistentConnection = false;
        request.headers.set('Origin', 'https://admin.forgeflow.app');
        request.headers.set('Access-Control-Request-Method', 'POST');
        request.headers.set(
          'Access-Control-Request-Headers',
          'authorization,content-type,idempotency-key',
        );
        request.contentLength = 0;
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, equals(HttpStatus.noContent));
        final allowHeaders =
            response.headers.value('access-control-allow-headers') ?? '';
        expect(allowHeaders.toLowerCase(), contains('idempotency-key'));
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });
}

class _StubVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final value = claims;
    if (value != null) return value;
    throw ProxyJwtVerificationError('test verifier not configured');
  }
}

class _FakeCorpusAdminGateway implements CorpusAdminProxyGateway {
  List<Map<String, Object?>> listResult = const <Map<String, Object?>>[];
  Map<String, Object?>? fetchResult = <String, Object?>{
    'version': <String, Object?>{},
    'chunks': <Map<String, Object?>>[],
  };
  Map<String, Object?> previewResult = <String, Object?>{
    'preview_token': 'tok-default',
    'added': <Map<String, Object?>>[],
    'modified': <Map<String, Object?>>[],
    'inactivated': <Map<String, Object?>>[],
    'summary': '',
  };
  Map<String, Object?> commitResult = <String, Object?>{
    'version_id': 'committed',
    'created_at': '2026-05-01T00:00:00.000Z',
    'summary': '',
    'is_current': true,
    'chunk_count': 0,
  };
  Map<String, Object?>? rollbackResult = <String, Object?>{
    'version_id': 'rollback',
    'created_at': '2026-05-01T00:00:00.000Z',
    'summary': '',
    'is_current': true,
    'rollback_of': 'v-target',
    'chunk_count': 0,
  };
  Object? raiseOnPreview;

  String? lastActorUserId;
  String? lastReason;
  String? lastIdempotencyKey;
  String? lastPreviewFileName;
  String? lastCommitToken;
  String? lastCommitSummary;
  String? lastRollbackTargetId;

  @override
  Future<List<Map<String, Object?>>> listVersions({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return listResult;
  }

  @override
  Future<Map<String, Object?>?> fetchVersion({
    required String actorUserId,
    required String versionId,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    return fetchResult;
  }

  @override
  Future<Map<String, Object?>> previewDiff({
    required String actorUserId,
    required String fileName,
    required String contentType,
    required List<int> bytes,
    required String idempotencyKey,
    required String adminReason,
  }) async {
    final raise = raiseOnPreview;
    if (raise != null) throw raise;
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastPreviewFileName = fileName;
    lastIdempotencyKey = idempotencyKey;
    return previewResult;
  }

  @override
  Future<Map<String, Object?>> commitVersion({
    required String actorUserId,
    required String previewToken,
    required String summary,
    required String idempotencyKey,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastCommitToken = previewToken;
    lastCommitSummary = summary;
    lastIdempotencyKey = idempotencyKey;
    return commitResult;
  }

  @override
  Future<Map<String, Object?>?> rollbackVersion({
    required String actorUserId,
    required String targetVersionId,
    required String summary,
    required String idempotencyKey,
    required String adminReason,
  }) async {
    lastActorUserId = actorUserId;
    lastReason = adminReason;
    lastRollbackTargetId = targetVersionId;
    lastIdempotencyKey = idempotencyKey;
    return rollbackResult;
  }
}

class _HttpResponseSnapshot {
  _HttpResponseSnapshot({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

Future<_HttpResponseSnapshot> _httpGet(
  HttpClient client,
  Uri uri, {
  String? authorization,
}) async {
  final request = await client.getUrl(uri);
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(statusCode: response.statusCode, body: body);
}

Future<_HttpResponseSnapshot> _httpJson(
  HttpClient client,
  String method,
  Uri uri, {
  String? authorization,
  String? idempotencyKey,
  Map<String, Object?>? body,
}) async {
  final request = await client.openUrl(method, uri);
  request.persistentConnection = false;
  if (authorization != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authorization);
  }
  if (idempotencyKey != null) {
    request.headers.set('Idempotency-Key', idempotencyKey);
  }
  if (body != null) {
    request.headers.contentType = ContentType.json;
    final encoded = utf8.encode(jsonEncode(body));
    request.contentLength = encoded.length;
    request.add(encoded);
  } else {
    request.contentLength = 0;
  }
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  return _HttpResponseSnapshot(
    statusCode: response.statusCode,
    body: responseBody,
  );
}
