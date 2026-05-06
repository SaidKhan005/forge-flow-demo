// Operator-web self-service vendor integrations proxy route tests.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/auth/permission_effect.dart';
import 'package:forge_and_flow/auth/permission_keys.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const _operatorOrigin = 'https://forge-flow-operator-web.test';

Future<T> _withRealHttp<T>(Future<T> Function() body) async {
  final saved = HttpOverrides.current;
  HttpOverrides.global = null;
  try {
    return await body();
  } finally {
    HttpOverrides.global = saved;
  }
}

Future<({HttpServer server, HttpClient client, Uri baseUri})> _spinUp({
  bool allowIntegrations = true,
}) async {
  final guard = ProxyRequestGuard(
    verifier: const _StaticVerifier(
      ProxyJwtClaims(
        userId: 'user-1',
        operatorId: 'op-1',
        locationId: 'loc-1',
        roles: <String>['operator_admin'],
      ),
    ),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    await routeRequest(
      request,
      guard,
      permissionSnapshotResolver: _StaticPermissionResolver(
        allowIntegrations: allowIntegrations,
      ),
      adminCorsAllowList: const <String>[_operatorOrigin],
      now: () => DateTime.utc(2026, 5, 6, 12),
    );
  });
  final client = HttpClient();
  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  return (server: server, client: client, baseUri: baseUri);
}

void main() {
  test('GET /v1/auth/locations/<id>/integrations returns empty bundle', () {
    return _withRealHttp(() async {
      final ctx = await _spinUp();
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-1/integrations'),
        );
        request.headers.set('Authorization', 'Bearer ok');
        request.headers.set('Origin', _operatorOrigin);
        request.contentLength = 0;
        final response = await request.close();
        final body =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;

        expect(response.statusCode, HttpStatus.ok);
        expect(
          response.headers.value('access-control-allow-origin'),
          _operatorOrigin,
        );
        expect(body['operator_id'], 'op-1');
        expect(body['location_id'], 'loc-1');
        expect(body['connections'], isEmpty);
        expect(body['demo_flags'], isA<Map<Object?, Object?>>());
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('GET integrations rejects another location in the URL', () {
    return _withRealHttp(() async {
      final ctx = await _spinUp();
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-other/integrations'),
        );
        request.headers.set('Authorization', 'Bearer ok');
        request.contentLength = 0;
        final response = await request.close();
        final body =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;

        expect(response.statusCode, HttpStatus.forbidden);
        expect(body['error'], 'location_scope_mismatch');
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });

  test('GET integrations requires an integration permission', () {
    return _withRealHttp(() async {
      final ctx = await _spinUp(allowIntegrations: false);
      try {
        final request = await ctx.client.openUrl(
          'GET',
          ctx.baseUri.resolve('/v1/auth/locations/loc-1/integrations'),
        );
        request.headers.set('Authorization', 'Bearer ok');
        request.contentLength = 0;
        final response = await request.close();
        final body =
            jsonDecode(await response.transform(utf8.decoder).join())
                as Map<String, Object?>;

        expect(response.statusCode, HttpStatus.forbidden);
        expect(body['error'], 'permission_denied');
      } finally {
        ctx.client.close(force: true);
        await ctx.server.close(force: true);
      }
    });
  });
}

class _StaticVerifier implements ProxyJwtVerifier {
  const _StaticVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _StaticPermissionResolver implements ProxyPermissionSnapshotResolver {
  const _StaticPermissionResolver({required this.allowIntegrations});

  final bool allowIntegrations;

  @override
  Future<ProxyPermissionSnapshot> load(OperatorContext scope) async {
    return ProxyPermissionSnapshot(
      userId: scope.userId,
      operatorId: scope.operatorId,
      locationId: scope.locationId,
      rolesVersion: 1,
      evaluatedAt: DateTime.utc(2026, 5, 6, 12),
      permissions: <String, PermissionEffect>{
        PermissionKeys.integrationToastView: allowIntegrations
            ? PermissionEffect.allow
            : PermissionEffect.deny,
      },
    );
  }
}
