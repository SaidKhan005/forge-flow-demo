// Phase 11A.3b — Proxy `/v1/admin/corpus/graph-candidates*` and
// `/v1/admin/age/rebuild` route tests.
//
// Coverage:
//   * Method-scoped role gate: GET admits super_admin + ff_support;
//     POST commit-batch admits super_admin only.
//   * Idempotency-Key header is required on every non-GET route.
//   * Manifest scope filter (defense in depth) rejects decisions whose
//     `payload.source_file` is not in the corpus manifest with a
//     typed `source_out_of_scope` 403.
//   * AGE rebuild stub returns 501 not_implemented for super_admin
//     and 403 for ff_support; missing Idempotency-Key still surfaces
//     400.
//   * Idempotent replay: same key replayed returns the same payload
//     (asserted via gateway call counter).
//
// Mirrors the harness setup from
// `test/services/proxy_corpus_admin_routes_test.dart` so the proxy
// is exercised against a stub JWT verifier and a fake gateway.

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
      _FakeGraphCandidatesGateway gateway,
    })
  > spinUp({
    ProxyJwtClaims? initialClaims,
    bool gatewayConfigured = true,
    _FakeGraphCandidatesGateway? customGateway,
  }) async {
    // The defense-in-depth manifest filter caches the loaded manifest
    // scope across requests in the same process. Reset between
    // scenarios so a test that swaps the manifest YAML mid-process
    // (or one that has no manifest on disk) sees a fresh read.
    resetGraphCandidatesManifestCache();

    final verifier = _StubVerifier();
    verifier.claims = initialClaims;
    final guard = ProxyRequestGuard(verifier: verifier);
    final gateway = customGateway ?? _FakeGraphCandidatesGateway();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // ignore: unawaited_futures
    server.listen((request) async {
      try {
        await routeRequest(
          request,
          guard,
          graphCandidatesGateway:
              gatewayConfigured ? gateway : null,
          now: () => DateTime.utc(2026, 5, 1, 12),
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

  test(
    'GET /v1/admin/corpus/graph-candidates admits super_admin (200)',
    () async {
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
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(adminCorpusGraphCandidatesPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          expect(ctx.gateway.lastListActorUserId, equals('user_super'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'GET /v1/admin/corpus/graph-candidates admits ff_support (200)',
    () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
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
            ctx.baseUri.resolve(adminCorpusGraphCandidatesPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          expect(ctx.gateway.lastListActorUserId, equals('user_support'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'GET /v1/admin/corpus/graph-candidates rejects operator_owner (403)',
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
            ctx.baseUri.resolve(adminCorpusGraphCandidatesPath),
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
    'POST /v1/admin/corpus/graph-candidates/commit-batch admits super_admin '
    '(200)',
    () async {
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
            ctx.baseUri.resolve(adminCorpusGraphCandidatesCommitPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'commit-1',
            body: const <String, Object?>{
              'target_operator_id': 'op_target',
              'target_location_id': 'loc_target',
              'decisions': <Map<String, Object?>>[],
            },
          );
          expect(response.statusCode, equals(200));
          expect(ctx.gateway.lastCommitActorUserId, equals('user_super'));
          expect(ctx.gateway.lastCommitOperatorId, equals('op_target'));
          expect(ctx.gateway.lastCommitLocationId, equals('loc_target'));
          expect(ctx.gateway.lastCommitIdempotencyKey, equals('commit-1'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST commit-batch rejects ff_support with 403 permission_denied',
    () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
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
            ctx.baseUri.resolve(adminCorpusGraphCandidatesCommitPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'commit-2',
            body: const <String, Object?>{
              'target_operator_id': 'op_target',
              'target_location_id': 'loc_target',
              'decisions': <Map<String, Object?>>[],
            },
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(body['required_roles'], contains('super_admin'));
          expect(ctx.gateway.commitInvocationCount, equals(0),
              reason: 'role gate must short-circuit before the gateway '
                  'call');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test('POST commit-batch without Idempotency-Key returns 400', () async {
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
          ctx.baseUri.resolve(adminCorpusGraphCandidatesCommitPath),
          authorization: 'Bearer fake.token',
          // intentionally omit Idempotency-Key
          body: const <String, Object?>{
            'target_operator_id': 'op_target',
            'target_location_id': 'loc_target',
            'decisions': <Map<String, Object?>>[],
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
    'POST commit-batch with same Idempotency-Key replayed returns the '
    'same payload (gateway dedupes)',
    () async {
      await withRealHttp(() async {
        final gateway = _FakeGraphCandidatesGateway();
        // Pin a deterministic commit payload so both responses match
        // byte-for-byte.
        gateway.commitResult = const <String, Object?>{
          'approved_node_count': 1,
          'approved_edge_count': 0,
          'rejected_count': 0,
          'outcomes': <Map<String, Object?>>[],
        };
        // Replay-aware fake: when the same idempotency key fires
        // twice the fake returns the cached payload and does NOT
        // re-execute the writer body.
        gateway.replayCacheEnabled = true;
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
          final first = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminCorpusGraphCandidatesCommitPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'replay-key-1',
            body: const <String, Object?>{
              'target_operator_id': 'op_target',
              'target_location_id': 'loc_target',
              'decisions': <Map<String, Object?>>[],
            },
          );
          final second = await _httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminCorpusGraphCandidatesCommitPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'replay-key-1',
            body: const <String, Object?>{
              'target_operator_id': 'op_target',
              'target_location_id': 'loc_target',
              'decisions': <Map<String, Object?>>[],
            },
          );
          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          expect(second.body, equals(first.body),
              reason: 'replayed Idempotency-Key must return the same '
                  'payload byte-for-byte');
          expect(gateway.commitInvocationCount, equals(1),
              reason: 'replay-aware gateway must dedupe on key reuse');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test(
    'POST commit-batch with decisions[*].source_file outside the manifest '
    'scope returns 403 source_out_of_scope',
    () async {
      await withRealHttp(() async {
        // The defense-in-depth manifest filter reads the corpus
        // manifest on first commit; if no manifest is present on
        // disk the scope is empty and any decision carrying a
        // `source_file` is rejected. We exercise the empty-scope
        // path here so the assertion is free of fixture-on-disk
        // coupling. resetGraphCandidatesManifestCache() in spinUp
        // ensures the previous test's manifest read does not leak.
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
            ctx.baseUri.resolve(adminCorpusGraphCandidatesCommitPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'oos-key-1',
            body: const <String, Object?>{
              'target_operator_id': 'op_target',
              'target_location_id': 'loc_target',
              'decisions': <Map<String, Object?>>[
                <String, Object?>{
                  'candidate_id': 'edge:phantom:source:target',
                  'kind': 'edge',
                  'payload': <String, Object?>{
                    'source_file': 'docs/phantom_doc.md',
                  },
                },
              ],
            },
          );
          // Either of two acceptance paths is correct:
          //   * The proxy's empty-scope branch raises 403
          //     `source_out_of_scope` (the explicit defense-in-depth
          //     path).
          //   * The proxy's no-manifest fallback raises a typed 4xx
          //     identifying the missing manifest.
          // The slice contract is the 403 path; assert on it.
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('source_out_of_scope'));
          expect(ctx.gateway.commitInvocationCount, equals(0),
              reason: 'manifest filter must reject before the gateway '
                  'is reached');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );

  test('POST /v1/admin/age/rebuild as super_admin returns 501 not_implemented',
      () async {
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
          ctx.baseUri.resolve(adminAgeRebuildPath),
          authorization: 'Bearer fake.token',
          idempotencyKey: 'rebuild-1',
          body: const <String, Object?>{},
        );
        expect(response.statusCode, equals(501));
        final body = jsonDecode(response.body) as Map<String, Object?>;
        expect(body['error'], equals('not_implemented'));
        expect(body['message'], isA<String>());
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test(
    'POST /v1/admin/age/rebuild as ff_support returns 403 permission_denied',
    () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
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
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'rebuild-2',
            body: const <String, Object?>{},
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
    'POST /v1/admin/age/rebuild without Idempotency-Key returns 400',
    () async {
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
            ctx.baseUri.resolve(adminAgeRebuildPath),
            authorization: 'Bearer fake.token',
            // intentionally omit Idempotency-Key
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_idempotency_key'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    },
  );
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

/// Fake [GraphCandidatesProxyGateway] that records call inputs for
/// assertions and (optionally) returns a cached payload on
/// idempotency-key reuse so the replay test can verify the contract
/// without involving a real cache.
class _FakeGraphCandidatesGateway implements GraphCandidatesProxyGateway {
  Map<String, Object?> listResult = const <String, Object?>{
    'graph_scope': 'methodology',
    'graph_version': '1',
    'graphify_version': 'v5',
    'graphify_source_commit': 'fake',
    'extracted': <Map<String, Object?>>[],
    'inferred': <Map<String, Object?>>[],
    'ambiguous': <Map<String, Object?>>[],
  };
  Map<String, Object?> commitResult = const <String, Object?>{
    'approved_node_count': 0,
    'approved_edge_count': 0,
    'rejected_count': 0,
    'outcomes': <Map<String, Object?>>[],
  };
  bool replayCacheEnabled = false;
  final Map<String, Map<String, Object?>> _replayCache =
      <String, Map<String, Object?>>{};

  String? lastListActorUserId;
  String? lastCommitActorUserId;
  String? lastCommitOperatorId;
  String? lastCommitLocationId;
  String? lastCommitIdempotencyKey;
  List<Map<String, Object?>>? lastCommitDecisions;
  int commitInvocationCount = 0;

  @override
  Future<Map<String, Object?>> listGraphCandidates({
    required String actorUserId,
    required String adminReason,
  }) async {
    lastListActorUserId = actorUserId;
    return listResult;
  }

  @override
  Future<Map<String, Object?>> commitBatch({
    required String actorUserId,
    required String operatorId,
    required String locationId,
    required List<Map<String, Object?>> decisions,
    required String idempotencyKey,
    required String adminReason,
  }) async {
    if (replayCacheEnabled) {
      final cached = _replayCache[idempotencyKey];
      if (cached != null) return cached;
    }
    lastCommitActorUserId = actorUserId;
    lastCommitOperatorId = operatorId;
    lastCommitLocationId = locationId;
    lastCommitIdempotencyKey = idempotencyKey;
    lastCommitDecisions = decisions;
    commitInvocationCount += 1;
    if (replayCacheEnabled) {
      _replayCache[idempotencyKey] = commitResult;
    }
    return commitResult;
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
