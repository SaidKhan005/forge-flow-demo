// Admin audit-integrity badge — admin/cross-tenant audit-chain-anchor
// proxy route tests.
//
// Pins the security contract for the new route:
//
//   GET /v1/admin/operators/:operatorId/audit-chain-anchors/latest
//
//   * (a) super_admin gets the URL operator's anchor + classified
//         status (cross-tenant read).
//   * (b) ff_support also admitted; a non-admin (operator_owner) role
//         is NOT admitted (403, gateway never reached).
//   * (c) operatorId comes from the URL (the gateway only ever sees
//         the URL operator, never a JWT operator).
//   * (d) status classification rides the SHARED `classifyAnchorStatus`
//         classifier (healthy / delayed / failed / unknown round-trip).
//   * gateway-not-configured → 503; unauthenticated → 401; non-GET →
//     not admitted; path parser disjoint from the profile route.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _kOpA = '11111111-1111-4111-8111-111111111111';
const String _kOpB = '22222222-2222-4222-8222-222222222222';
const String _kLocA = '33333333-3333-4333-8333-333333333333';
const String _kAdmin = '44444444-4444-4444-4444-444444444444';
const String _kOperatorUser = '55555555-5555-5555-5555-555555555555';

void main() {
  group('admin audit_chain_anchors proxy route', () {
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
        _FakeAdminAuditChainAnchorsGateway gateway,
      })
    >
    spinUp({
      ProxyJwtClaims? claims,
      AuditChainAnchorRow? row,
      DateTime? now,
      bool gatewayConfigured = true,
    }) async {
      final guard = ProxyRequestGuard(
        verifier: _SettableVerifier(
          claims ??
              const ProxyJwtClaims(
                userId: _kAdmin,
                operatorId: '',
                locationId: '',
                roles: <String>['super_admin'],
              ),
        ),
      );
      final gateway = _FakeAdminAuditChainAnchorsGateway(row);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final clock = now != null ? () => now : null;
      // ignore: unawaited_futures
      server.listen((request) async {
        await routeRequest(
          request,
          guard,
          adminAuditChainAnchorsGateway: gatewayConfigured ? gateway : null,
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

    Uri anchorUri(Uri baseUri, String operatorId) => baseUri.resolve(
      '/v1/admin/operators/$operatorId/audit-chain-anchors/latest',
    );

    test('super_admin gets the URL operator anchor + healthy status (a)(c)(d)',
        () async {
      await withRealHttp(() async {
        final now = DateTime.utc(2026, 5, 7, 6);
        final ctx = await spinUp(
          row: AuditChainAnchorRow(
            chainDate: DateTime.utc(2026, 5, 7),
            anchoredAt: DateTime.utc(2026, 5, 7, 2, 0, 14),
            rowCount: 1234,
            blobUri: 'https://example.blob/$_kOpB/2026-05-07.json',
            lastAnchorBlobUrl: 'https://example.blob/$_kOpB/2026-05-07.json',
            lastAnchorBlobAt: DateTime.utc(2026, 5, 7, 2, 0, 12),
          ),
          now: now,
        );
        try {
          final response = await _authedGet(ctx.client, anchorUri(ctx.baseUri, _kOpB));
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          // operatorId is the URL operator (cross-tenant) — never a JWT.
          expect(body['operator_id'], _kOpB);
          final anchor = body['anchor'] as Map<String, Object?>;
          expect(anchor['status'], 'healthy');
          expect(anchor['row_count'], 1234);
          expect(anchor['chain_date'], '2026-05-07');
          expect(
            anchor['blob_uri'],
            'https://example.blob/$_kOpB/2026-05-07.json',
          );
          // Gateway only ever saw the URL operator + the audit reason.
          expect(ctx.gateway.calls, <String>[_kOpB]);
          expect(
            ctx.gateway.lastReason,
            AdminAuditChainAnchorsRouter.auditReason,
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('ff_support is also admitted (b)', () async {
      await withRealHttp(() async {
        final now = DateTime.utc(2026, 5, 7, 6);
        final ctx = await spinUp(
          claims: const ProxyJwtClaims(
            userId: _kAdmin,
            operatorId: '',
            locationId: '',
            roles: <String>['ff_support'],
          ),
          row: AuditChainAnchorRow(
            chainDate: DateTime.utc(2026, 5, 7),
            anchoredAt: DateTime.utc(2026, 5, 7, 2),
            rowCount: 7,
            blobUri: 'https://example.blob/$_kOpB/2026-05-07.json',
          ),
          now: now,
        );
        try {
          final response = await _authedGet(ctx.client, anchorUri(ctx.baseUri, _kOpB));
          expect(response.statusCode, 200);
          expect(ctx.gateway.calls, <String>[_kOpB]);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('a non-admin (operator_owner) actor is NOT admitted (b) — gated',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          claims: const ProxyJwtClaims(
            userId: _kOperatorUser,
            operatorId: _kOpA,
            locationId: _kLocA,
            roles: <String>['operator_owner'],
          ),
        );
        try {
          // Operator A tries to read operator B's anchor via the admin
          // path. Must be rejected before the gateway runs.
          final crossResponse = await _authedGet(
            ctx.client,
            anchorUri(ctx.baseUri, _kOpB),
          );
          expect(crossResponse.statusCode, 403);
          final body = jsonDecode(crossResponse.body) as Map<String, Object?>;
          expect(body['error'], 'permission_denied');
          expect(ctx.gateway.calls, isEmpty);

          // Even reading "their own" operator via the admin path is
          // denied — the admin route is admin-gated, full stop.
          final ownResponse = await _authedGet(
            ctx.client,
            anchorUri(ctx.baseUri, _kOpA),
          );
          expect(ownResponse.statusCode, 403);
          expect(ctx.gateway.calls, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('classifies delayed via the shared classifier (d)', () async {
      await withRealHttp(() async {
        final now = DateTime.utc(2026, 5, 7, 6);
        final ctx = await spinUp(
          row: AuditChainAnchorRow(
            chainDate: DateTime.utc(2026, 5, 5),
            anchoredAt: now.subtract(const Duration(hours: 30)),
            rowCount: 800,
            blobUri: 'https://example.blob/$_kOpB/2026-05-05.json',
            lastAnchorBlobUrl: 'https://example.blob/$_kOpB/2026-05-05.json',
            lastAnchorBlobAt: now.subtract(const Duration(hours: 30)),
          ),
          now: now,
        );
        try {
          final response = await _authedGet(ctx.client, anchorUri(ctx.baseUri, _kOpB));
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

    test('classifies failed when blob_uri missing (d)', () async {
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
          final response = await _authedGet(ctx.client, anchorUri(ctx.baseUri, _kOpB));
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

    test('returns unknown anchor (null) when no row exists for the operator',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final response = await _authedGet(ctx.client, anchorUri(ctx.baseUri, _kOpB));
          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['operator_id'], _kOpB);
          expect(body['anchor'], isNull);
          expect(ctx.gateway.calls, <String>[_kOpB]);
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
          final request = await ctx.client.getUrl(anchorUri(ctx.baseUri, _kOpB));
          final response = await request.close();
          expect(response.statusCode, 401);
          expect(ctx.gateway.calls, isEmpty);
          await response.drain<void>();
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('returns 503 when the admin anchors gateway is not configured',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(gatewayConfigured: false);
        try {
          final response = await _authedGet(ctx.client, anchorUri(ctx.baseUri, _kOpB));
          expect(response.statusCode, 503);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], 'admin_audit_chain_anchors_not_configured');
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('rejects HTTP methods other than GET (router does not match)',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl('POST', anchorUri(ctx.baseUri, _kOpB));
          request.headers.set(HttpHeaders.authorizationHeader, 'Bearer token');
          final response = await request.close();
          // POST does not match the admin anchors route; the gateway is
          // never reached.
          expect(response.statusCode, isNot(200));
          expect(ctx.gateway.calls, isEmpty);
          await response.drain<void>();
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('path matcher only matches the GET anchors path', () {
      expect(
        AdminAuditChainAnchorsRouter.matches(
          '/v1/admin/operators/$_kOpB/audit-chain-anchors/latest',
          'GET',
        ),
        isTrue,
      );
      expect(
        adminAuditChainAnchorsOperatorIdOf(
          '/v1/admin/operators/$_kOpB/audit-chain-anchors/latest',
        ),
        equals(_kOpB),
      );
      // Disjoint from the admin business-timing profile route.
      expect(
        isAdminAuditChainAnchorsPath(
          '/v1/admin/operators/$_kOpB/business-timing-profiles',
        ),
        isFalse,
      );
      // The admin read gate mirrors the business-timing read gate.
      expect(
        kAdminAuditChainAnchorRoles,
        equals(<String>{'super_admin', 'ff_support'}),
      );
    });
  });
}

class _SettableVerifier implements ProxyJwtVerifier {
  _SettableVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _FakeAdminAuditChainAnchorsGateway
    implements AdminAuditChainAnchorsGateway {
  _FakeAdminAuditChainAnchorsGateway(this._row);

  final AuditChainAnchorRow? _row;
  final List<String> calls = <String>[];
  String? lastReason;

  @override
  Future<AuditChainAnchorRow?> latestForOperatorAsSystem({
    required String operatorId,
    required String reason,
  }) async {
    calls.add(operatorId);
    lastReason = reason;
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
