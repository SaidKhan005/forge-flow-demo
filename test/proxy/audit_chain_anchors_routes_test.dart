// Operator Web W4.B - audit_chain_anchors per-tenant proxy route
// tests.
//
// Pins the contract for the new route:
//
//   GET /v1/operator/audit-chain-anchors/latest
//
// Auth required, per-tenant scope, healthy / delayed / failed /
// unknown classification round-trip, cross-tenant 403, gateway-not-
// configured 503.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('audit_chain_anchors proxy route', () {
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
        _FakeAuditChainAnchorsGateway gateway,
      })
    >
    spinUp({
      ProxyJwtClaims? claims,
      AuditChainAnchorRow? row,
      DateTime? now,
    }) async {
      final guard = ProxyRequestGuard(
        verifier: _SettableVerifier(
          claims ??
              const ProxyJwtClaims(
                userId: 'user-1',
                operatorId: 'op-1',
                locationId: 'loc-1',
                roles: <String>['operator_owner'],
              ),
        ),
      );
      final gateway = _FakeAuditChainAnchorsGateway(row);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final clock = now != null ? () => now : null;
      // ignore: unawaited_futures
      server.listen((request) async {
        await routeRequest(
          request,
          guard,
          auditChainAnchorsGateway: gateway,
          now: clock,
        );
      });
      return (
        server: server,
        client: HttpClient(),
        baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
        gateway: gateway,
      );
    }

    test('returns the latest anchor for the caller scoped to the JWT',
        () async {
      await withRealHttp(() async {
        final now = DateTime.utc(2026, 5, 7, 6);
        final ctx = await spinUp(
          row: AuditChainAnchorRow(
            chainDate: DateTime.utc(2026, 5, 7),
            anchoredAt: DateTime.utc(2026, 5, 7, 2, 0, 14),
            rowCount: 1234,
            blobUri: 'https://example.blob/op-1/2026-05-07.json',
            lastAnchorBlobUrl: 'https://example.blob/op-1/2026-05-07.json',
            lastAnchorBlobAt: DateTime.utc(2026, 5, 7, 2, 0, 12),
          ),
          now: now,
        );
        try {
          final response = await _authedGet(
            ctx.client,
            ctx.baseUri.resolve('/v1/operator/audit-chain-anchors/latest'),
          );
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['operator_id'], 'op-1');
          final anchor = body['anchor'] as Map<String, Object?>;
          expect(anchor['status'], 'healthy');
          expect(anchor['row_count'], 1234);
          expect(anchor['chain_date'], '2026-05-07');
          expect(
            anchor['blob_uri'],
            'https://example.blob/op-1/2026-05-07.json',
          );
          expect(ctx.gateway.calls, <String>['op-1:loc-1']);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('returns delayed status when anchor is older than 26 hours',
        () async {
      await withRealHttp(() async {
        final now = DateTime.utc(2026, 5, 7, 6);
        final ctx = await spinUp(
          row: AuditChainAnchorRow(
            chainDate: DateTime.utc(2026, 5, 5),
            anchoredAt: now.subtract(const Duration(hours: 30)),
            rowCount: 800,
            blobUri: 'https://example.blob/op-1/2026-05-05.json',
            lastAnchorBlobUrl: 'https://example.blob/op-1/2026-05-05.json',
            lastAnchorBlobAt: now.subtract(const Duration(hours: 30)),
          ),
          now: now,
        );
        try {
          final response = await _authedGet(
            ctx.client,
            ctx.baseUri.resolve('/v1/operator/audit-chain-anchors/latest'),
          );
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final anchor = body['anchor'] as Map<String, Object?>;
          expect(anchor['status'], 'delayed');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('returns failed status when blob_uri missing', () async {
      await withRealHttp(() async {
        final now = DateTime.utc(2026, 5, 7, 6);
        final ctx = await spinUp(
          row: AuditChainAnchorRow(
            chainDate: DateTime.utc(2026, 5, 6),
            anchoredAt: now.subtract(const Duration(hours: 12)),
            rowCount: 50,
            blobUri: '',
          ),
          now: now,
        );
        try {
          final response = await _authedGet(
            ctx.client,
            ctx.baseUri.resolve('/v1/operator/audit-chain-anchors/latest'),
          );
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final anchor = body['anchor'] as Map<String, Object?>;
          expect(anchor['status'], 'failed');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('returns unknown anchor when no row exists', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _authedGet(
            ctx.client,
            ctx.baseUri.resolve('/v1/operator/audit-chain-anchors/latest'),
          );
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['operator_id'], 'op-1');
          expect(body['anchor'], isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('rejects an unauthenticated request with 401', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.getUrl(
            ctx.baseUri.resolve('/v1/operator/audit-chain-anchors/latest'),
          );
          final response = await request.close();
          expect(response.statusCode, 401);
          await response.drain<void>();
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('rejects a token without operator scope with 403', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          claims: const ProxyJwtClaims(
            userId: 'user-1',
            operatorId: null,
            locationId: null,
            // operator_owner without operator scope is genuinely unauthorized.
            // super_admin was the prior role here, but B1 sign-in contract
            // (c3f1ce0d, 2026-05-12) intentionally accepts scope-less
            // super_admin / ff_support → 200, so this assertion would drift.
            roles: <String>['operator_owner'],
          ),
        );
        try {
          final response = await _authedGet(
            ctx.client,
            ctx.baseUri.resolve('/v1/operator/audit-chain-anchors/latest'),
          );
          expect(response.statusCode, 403);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('cross-tenant calls are scoped to the caller operator', () async {
      // The gateway records every operatorId it was called with; the
      // proxy clamps to the token-resolved operator (op-1) so a
      // crafted request can never reach into op-2's anchors.
      await withRealHttp(() async {
        final ctx = await spinUp(
          claims: const ProxyJwtClaims(
            userId: 'user-2',
            operatorId: 'op-2',
            locationId: 'loc-2',
            roles: <String>['operator_owner'],
          ),
        );
        try {
          final response = await _authedGet(
            ctx.client,
            ctx.baseUri.resolve('/v1/operator/audit-chain-anchors/latest'),
          );
          expect(response.statusCode, 200);
          // Even though the path carries no operator id, the gateway
          // sees only op-2 (the JWT's clamp).
          expect(ctx.gateway.calls, <String>['op-2:loc-2']);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('returns 503 when the gateway is not configured', () async {
      await withRealHttp(() async {
        final guard = ProxyRequestGuard(
          verifier: _SettableVerifier(
            const ProxyJwtClaims(
              userId: 'user-1',
              operatorId: 'op-1',
              locationId: 'loc-1',
              roles: <String>['operator_owner'],
            ),
          ),
        );
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        // ignore: unawaited_futures
        server.listen((request) async {
          await routeRequest(request, guard);
        });
        final client = HttpClient();
        final baseUri =
            Uri.parse('http://${server.address.host}:${server.port}');
        try {
          final response = await _authedGet(
            client,
            baseUri.resolve('/v1/operator/audit-chain-anchors/latest'),
          );
          expect(response.statusCode, 503);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'audit_chain_anchors_not_configured');
        } finally {
          client.close(force: true);
          await server.close(force: true);
        }
      });
    });

    test('rejects HTTP methods other than GET with 404', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'POST',
            ctx.baseUri.resolve('/v1/operator/audit-chain-anchors/latest'),
          );
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer token');
          final response = await request.close();
          expect(response.statusCode, 404);
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

class _FakeAuditChainAnchorsGateway implements AuditChainAnchorsGateway {
  _FakeAuditChainAnchorsGateway(this._row);

  final AuditChainAnchorRow? _row;
  final List<String> calls = <String>[];

  @override
  Future<AuditChainAnchorRow?> latestForOperator({
    required String operatorId,
    required String locationId,
    String? userId,
  }) async {
    calls.add('$operatorId:$locationId');
    return _row;
  }
}

Future<_HttpResult> _authedGet(HttpClient client, Uri uri) async {
  final request = await client.getUrl(uri);
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer token');
  final response = await request.close();
  final body = await utf8.decodeStream(response);
  return _HttpResult(response.statusCode, body);
}

class _HttpResult {
  const _HttpResult(this.statusCode, this.body);

  final int statusCode;
  final String body;
}
