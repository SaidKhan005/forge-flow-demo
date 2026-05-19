// Lane B B11.1 — auth handoff (mobile→web) proxy route tests.
//
// Pins the contract for the two new routes:
//
//   POST /v1/auth/handoff/codes    (mint)
//   POST /v1/auth/handoff/redeem   (redeem)
//
// Coverage:
//   * mint happy path (200, code in BODY, audit fired)
//   * mint without Idempotency-Key → 400
//   * mint with too-long Idempotency-Key → 400
//   * mint replay (same key + same body) → cached identical response
//   * mint replay with different body → 409 idempotency_key_conflict
//   * mint over the per-user 10/hour rate limit → 429
//   * mint with invalid target_path (absolute URL, missing, too long) → 400
//   * redeem happy path → 200, returns (user/operator/location/target_path)
//   * redeem with replayed (consumed) code → 410 handoff_code_unusable
//   * redeem with expired code → 410 handoff_code_unusable
//   * redeem with code from a different operator → 403 wrong_operator
//   * redeem with malformed body → 400 missing_code
//   * cross-operator scope: opaque code from op-1 cannot be redeemed
//     by op-2 (predicate filter + cross-tenant classifier hand-off)
//   * URL discipline: redeem reads code from BODY, IGNORES query
//     parameter `?code=`
//   * router not configured → 503
//
// Authority:
//   * tool/advisor_proxy/auth_handoff_routes.dart (the route file)
//   * docs/archive/_execution/lane_b_features/03_execution_slices.md ("B11.1")
//   * docs/archive/_execution/lane_b_features/01_product_rule_and_ia.md
//     (addendum A1: code in body only)

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/repositories/handoff_codes_repository.dart';

const String _opA = 'op-1';
const String _locA = 'loc-1';
const String _userA = 'user-1';

const String _opB = 'op-2';

const String _validIdemKey = '0123456789abcdef0123456789abcdef';

void main() {
  group('auth handoff proxy routes', () {
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
        _FakeHandoffCodesGateway gateway,
        _RecordingAuditSink auditSink,
      })
    > spinUp({
      ProxyJwtClaims? claims,
      _FakeHandoffCodesGateway? gateway,
      bool installRouter = true,
      DateTime? now,
    }) async {
      final guard = ProxyRequestGuard(
        verifier: _SettableVerifier(
          claims ??
              const ProxyJwtClaims(
                userId: _userA,
                operatorId: _opA,
                locationId: _locA,
                roles: <String>['operator_owner'],
              ),
        ),
      );
      final fakeGateway = gateway ?? _FakeHandoffCodesGateway();
      final auditSink = _RecordingAuditSink();
      final router = installRouter
          ? AuthHandoffRouter(
              gateway: fakeGateway,
              auditSink: auditSink,
            )
          : null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final clock = now != null ? () => now : null;
      // ignore: unawaited_futures
      server.listen((request) async {
        await routeRequest(
          request,
          guard,
          authHandoffRouter: router,
          now: clock,
        );
      });
      return (
        server: server,
        client: HttpClient(),
        baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
        gateway: fakeGateway,
        auditSink: auditSink,
      );
    }

    // ─── mint ────────────────────────────────────────────────────────

    test('mint happy path returns code in BODY and fires '
        'auth.handoff.code_created audit', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          gateway: _FakeHandoffCodesGateway(mintCode: 'CODE_AAAA_1111_BBBB'),
        );
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{
              'target_path': '/operator-web/team',
              'source_device_fingerprint': 'fp-1',
            },
          );
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['code'], 'CODE_AAAA_1111_BBBB');
          expect(body['expires_in_seconds'], 60);

          // Gateway saw exactly one mint call.
          expect(ctx.gateway.mintCalls, hasLength(1));
          expect(ctx.gateway.mintCalls.single.operatorId, _opA);
          expect(ctx.gateway.mintCalls.single.userId, _userA);
          expect(
            ctx.gateway.mintCalls.single.targetPath,
            '/operator-web/team',
          );
          expect(
            ctx.gateway.mintCalls.single.sourceDeviceFingerprint,
            'fp-1',
          );

          // Audit sink saw exactly one code_created event with hashed code.
          expect(ctx.auditSink.created, hasLength(1));
          expect(ctx.auditSink.created.single.code, 'CODE_AAAA_1111_BBBB');
          expect(ctx.auditSink.created.single.targetPath, '/operator-web/team');
          expect(ctx.auditSink.created.single.actorUserId, _userA);
          expect(ctx.auditSink.created.single.operatorId, _opA);
          expect(ctx.auditSink.redeemed, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('mint without Idempotency-Key returns 400 idempotency_key_missing',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: const <String, String>{},
            body: <String, Object?>{'target_path': '/operator-web/team'},
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'idempotency_key_missing');
          expect(ctx.gateway.mintCalls, isEmpty);
          expect(ctx.auditSink.created, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('mint with too-long Idempotency-Key returns 400', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': 'x' * 201},
            body: <String, Object?>{'target_path': '/operator-web/team'},
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'idempotency_key_too_long');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('mint replay with same key + same body returns the same code '
        '(idempotency cache hits)', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          gateway: _FakeHandoffCodesGateway(mintCode: 'STABLE_CODE_VALUE'),
        );
        try {
          final first = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{
              'target_path': '/operator-web/team',
            },
          );
          final second = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{
              'target_path': '/operator-web/team',
            },
          );
          expect(first.statusCode, 200);
          expect(second.statusCode, 200);
          final firstBody = jsonDecode(first.body) as Map<String, Object?>;
          final secondBody = jsonDecode(second.body) as Map<String, Object?>;
          expect(firstBody['code'], secondBody['code']);
          // Gateway mint only called once — replay hit the cache.
          expect(ctx.gateway.mintCalls, hasLength(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('mint replay with same key + DIFFERENT body returns 409 conflict',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final first = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{
              'target_path': '/operator-web/team',
            },
          );
          expect(first.statusCode, 200);
          final second = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{
              'target_path': '/operator-web/billing',
            },
          );
          expect(second.statusCode, 409);
          final body = jsonDecode(second.body) as Map<String, Object?>;
          expect(body['error'], 'idempotency_key_conflict');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('mint over per-user 10/hour rate limit returns 429', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          gateway: _FakeHandoffCodesGateway(
            countRecentReturning: HandoffCodesRepository.kRateLimitPerHour,
          ),
        );
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{'target_path': '/operator-web/team'},
          );
          expect(response.statusCode, 429);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'rate_limit_exceeded');
          // No mint and no audit fired.
          expect(ctx.gateway.mintCalls, isEmpty);
          expect(ctx.auditSink.created, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('mint with absolute URL target_path returns 400 invalid_target_path',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{
              'target_path': 'https://evil.example/billing',
            },
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'invalid_target_path');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('mint with protocol-relative target_path (//evil) returns 400',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{
              'target_path': '//evil.example/billing',
            },
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'invalid_target_path');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('mint with missing target_path returns 400', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{},
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'missing_target_path');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    // ─── redeem ──────────────────────────────────────────────────────

    test('redeem happy path returns 200 + (user/operator/location/'
        'target_path) and fires auth.handoff.redeemed audit', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          gateway: _FakeHandoffCodesGateway(
            redeemReturns: HandoffCodeRedeemed(
              code: 'STABLE_CODE_VALUE',
              userId: _userA,
              operatorId: _opA,
              locationId: _locA,
              targetPath: '/operator-web/team',
              sourceDeviceFingerprint: 'fp-1',
              consumedAt: DateTime.utc(2026, 5, 12, 21, 30),
            ),
          ),
        );
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/redeem'),
            headers: const <String, String>{},
            body: <String, Object?>{'code': 'STABLE_CODE_VALUE'},
          );
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['user_id'], _userA);
          expect(body['operator_id'], _opA);
          expect(body['location_id'], _locA);
          expect(body['target_path'], '/operator-web/team');

          expect(ctx.auditSink.redeemed, hasLength(1));
          expect(ctx.auditSink.redeemed.single.code, 'STABLE_CODE_VALUE');
          expect(ctx.auditSink.redeemed.single.targetPath, '/operator-web/team');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('redeem with replayed (consumed) code returns 410 unusable',
        () async {
      await withRealHttp(() async {
        // Gateway returns null (predicate did not match), and
        // lookupForReplayCheck returns a state where the code belongs
        // to the same operator but is consumed.
        final consumedAt = DateTime.utc(2026, 5, 12, 21, 30);
        final ctx = await spinUp(
          gateway: _FakeHandoffCodesGateway(
            redeemReturns: null,
            replayState: HandoffCodeState(
              operatorId: _opA,
              expiresAt: consumedAt.add(const Duration(seconds: 60)),
              consumedAt: consumedAt,
            ),
          ),
        );
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/redeem'),
            headers: const <String, String>{},
            body: <String, Object?>{'code': 'STABLE_CODE_VALUE'},
          );
          expect(response.statusCode, 410);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'handoff_code_unusable');
          expect(ctx.auditSink.redeemed, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('redeem with expired code returns 410 unusable', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          gateway: _FakeHandoffCodesGateway(
            redeemReturns: null,
            replayState: HandoffCodeState(
              operatorId: _opA,
              // Expires_at in the past.
              expiresAt: DateTime.utc(2026, 5, 12, 18, 0),
              consumedAt: null,
            ),
          ),
        );
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/redeem'),
            headers: const <String, String>{},
            body: <String, Object?>{'code': 'STABLE_CODE_VALUE'},
          );
          expect(response.statusCode, 410);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'handoff_code_unusable');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('redeem with code from a different operator returns 403 wrong_operator',
        () async {
      await withRealHttp(() async {
        // Caller's JWT scopes them to op-1 (the spinUp default), but
        // the code in question lives in op-2. The gateway predicate
        // returns null (operator mismatch) and the cross-tenant
        // lookup returns op-2 → 403.
        final ctx = await spinUp(
          gateway: _FakeHandoffCodesGateway(
            redeemReturns: null,
            replayState: HandoffCodeState(
              operatorId: _opB,
              expiresAt: DateTime.utc(2026, 5, 12, 22, 30),
              consumedAt: null,
            ),
          ),
        );
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/redeem'),
            headers: const <String, String>{},
            body: <String, Object?>{'code': 'CROSS_TENANT_CODE'},
          );
          expect(response.statusCode, 403);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'wrong_operator');
          expect(ctx.auditSink.redeemed, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('redeem with malformed body returns 400 missing_code', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/redeem'),
            headers: const <String, String>{},
            body: <String, Object?>{},
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'missing_code');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('redeem IGNORES code in URL query parameter (addendum A1: code '
        'in body only)', () async {
      // The proxy contract says the code travels in the body. If a
      // misconfigured client sticks the code in the URL `?code=`
      // parameter AND also leaves the body empty, the route returns
      // 400 missing_code instead of pulling the code out of the URL.
      // This is the canary that prevents an accidental URL-leak surface.
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve(
              '/v1/auth/handoff/redeem?code=URL_LEAKED_CODE',
            ),
            headers: const <String, String>{},
            body: <String, Object?>{},
          );
          expect(response.statusCode, 400);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'missing_code');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    // ─── plumbing ────────────────────────────────────────────────────

    test('returns 503 when the router is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(installRouter: false);
        try {
          final response = await _authedPost(
            ctx.client,
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
            headers: <String, String>{'Idempotency-Key': _validIdemKey},
            body: <String, Object?>{'target_path': '/operator-web/team'},
          );
          expect(response.statusCode, 503);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'auth_handoff_router_not_configured');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('rejects unauthenticated mint with 401', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.postUrl(
            ctx.baseUri.resolve('/v1/auth/handoff/codes'),
          );
          request.headers.set('Idempotency-Key', _validIdemKey);
          request.headers.contentType = ContentType.json;
          final encoded = utf8.encode(jsonEncode(<String, Object?>{
            'target_path': '/operator-web/team',
          }));
          request.contentLength = encoded.length;
          request.add(encoded);
          final response = await request.close();
          expect(response.statusCode, 401);
          await response.drain<void>();
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });
}

class _SettableVerifier implements ProxyJwtVerifier {
  _SettableVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _MintCall {
  const _MintCall({
    required this.operatorId,
    required this.userId,
    required this.targetPath,
    required this.sourceDeviceFingerprint,
  });

  final String operatorId;
  final String userId;
  final String targetPath;
  final String? sourceDeviceFingerprint;
}

class _RecordedCreated {
  const _RecordedCreated({
    required this.operatorId,
    required this.actorUserId,
    required this.code,
    required this.targetPath,
  });

  final String operatorId;
  final String actorUserId;
  final String code;
  final String targetPath;
}

class _RecordedRedeemed {
  const _RecordedRedeemed({
    required this.code,
    required this.targetPath,
  });

  final String code;
  final String targetPath;
}

class _RecordingAuditSink implements HandoffAuditSink {
  final List<_RecordedCreated> created = <_RecordedCreated>[];
  final List<_RecordedRedeemed> redeemed = <_RecordedRedeemed>[];

  @override
  Future<void> recordCodeCreated({
    required String operatorId,
    required String locationId,
    required String actorUserId,
    required String code,
    required String targetPath,
    required String? sourceDeviceFingerprint,
    required DateTime occurredAt,
  }) async {
    created.add(_RecordedCreated(
      operatorId: operatorId,
      actorUserId: actorUserId,
      code: code,
      targetPath: targetPath,
    ));
  }

  @override
  Future<void> recordRedeemed({
    required HandoffCodeRedeemed row,
    required DateTime occurredAt,
  }) async {
    redeemed.add(_RecordedRedeemed(
      code: row.code,
      targetPath: row.targetPath,
    ));
  }
}

class _FakeHandoffCodesGateway implements HandoffCodesGateway {
  _FakeHandoffCodesGateway({
    this.mintCode = 'DEFAULT_TEST_CODE_AAAA',
    this.redeemReturns,
    this.replayState,
    this.countRecentReturning = 0,
  });

  final String mintCode;
  final HandoffCodeRedeemed? redeemReturns;
  final HandoffCodeState? replayState;
  final int countRecentReturning;

  final List<_MintCall> mintCalls = <_MintCall>[];
  final List<String> redeemCodeCalls = <String>[];
  final List<String> replayCheckCalls = <String>[];

  @override
  Future<String> mint({
    required String operatorId,
    required String locationId,
    required String userId,
    required String targetPath,
    required String? sourceDeviceFingerprint,
  }) async {
    mintCalls.add(_MintCall(
      operatorId: operatorId,
      userId: userId,
      targetPath: targetPath,
      sourceDeviceFingerprint: sourceDeviceFingerprint,
    ));
    return mintCode;
  }

  @override
  Future<HandoffCodeRedeemed?> redeem({
    required String callerOperatorId,
    required String callerLocationId,
    required String callerUserId,
    required String code,
  }) async {
    redeemCodeCalls.add(code);
    return redeemReturns;
  }

  @override
  Future<HandoffCodeState?> lookupForReplayCheck({
    required String code,
    required String adminReason,
  }) async {
    replayCheckCalls.add(code);
    return replayState;
  }

  @override
  Future<int> countRecentForUser({
    required String operatorId,
    required String locationId,
    required String userId,
  }) async {
    return countRecentReturning;
  }
}

Future<_HttpResult> _authedPost(
  HttpClient client,
  Uri uri, {
  required Map<String, String> headers,
  required Map<String, Object?> body,
}) async {
  final request = await client.postUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer token');
  for (final entry in headers.entries) {
    request.headers.set(entry.key, entry.value);
  }
  request.headers.contentType = ContentType.json;
  final encoded = utf8.encode(jsonEncode(body));
  request.contentLength = encoded.length;
  request.add(encoded);
  final response = await request.close();
  final responseBody = await utf8.decodeStream(response);
  return _HttpResult(response.statusCode, responseBody);
}

class _HttpResult {
  const _HttpResult(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
