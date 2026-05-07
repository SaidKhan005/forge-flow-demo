// Phase 11W.8 follow-up — HTTP-level tests for
// `GET /v1/operator/vendor-lifecycle/recently-available`.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

const String _kOpA = '11111111-1111-1111-1111-111111111111';
const String _kOpB = '22222222-2222-2222-2222-222222222222';
const String _kLoc = '33333333-3333-3333-3333-333333333333';
const String _kUser = '44444444-4444-4444-4444-444444444444';

void main() {
  group('GET /v1/operator/vendor-lifecycle/recently-available', () {
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
        _RecordingRecentlyAvailableGateway gateway,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      bool routerConfigured = true,
      List<OperatorRecentlyAvailableVendorRow>? seed,
      DateTime Function()? now,
      Map<String, String>? displayNames,
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
      final gateway = _RecordingRecentlyAvailableGateway(
        seed: seed ?? const <OperatorRecentlyAvailableVendorRow>[],
      );
      final router = OperatorVendorLifecycleRecentlyAvailableRouter(
        gateway: gateway,
        displayNameResolver: (id) =>
            (displayNames ?? const <String, String>{})[id],
        now: now,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            vendorLifecycleRecentlyAvailableRouter:
                routerConfigured ? router : null,
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {}
        }
      });
      final client = HttpClient();
      final baseUri = Uri.parse(
        'http://${server.address.host}:${server.port}',
      );
      return (
        server: server,
        client: client,
        baseUri: baseUri,
        gateway: gateway,
      );
    }

    test('200 with the gateway-projected vendor list', () async {
      await withRealHttp(() async {
        final fixedNow = DateTime.utc(2026, 5, 7, 12);
        final ctx = await spinUp(
          seed: <OperatorRecentlyAvailableVendorRow>[
            OperatorRecentlyAvailableVendorRow(
              vendorId: 'toast',
              promotedAt: DateTime.utc(2026, 5, 5),
            ),
            OperatorRecentlyAvailableVendorRow(
              vendorId: 'seven_shifts',
              promotedAt: DateTime.utc(2026, 5, 6),
            ),
          ],
          displayNames: const <String, String>{
            'toast': 'Toast',
            'seven_shifts': '7shifts',
          },
          now: () => fixedNow,
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              operatorVendorLifecycleRecentlyAvailablePath,
            ),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['operator_id'], equals(_kOpA));
          // Default since = now - 14 days.
          expect(
            body['since'],
            equals(
              fixedNow.subtract(const Duration(days: 14)).toIso8601String(),
            ),
          );
          final vendors = body['vendors'] as List<Object?>;
          expect(vendors, hasLength(2));
          final first = vendors.first as Map<String, Object?>;
          expect(first['vendor_id'], equals('toast'));
          expect(first['vendor_display_name'], equals('Toast'));
          expect(first['lifecycle_state'], equals('productionCredentialed'));
          expect(ctx.gateway.calls, equals(1));
          expect(ctx.gateway.lastOperatorId, equals(_kOpA));
          expect(ctx.gateway.lastLocationId, equals(_kLoc));
          expect(
            ctx.gateway.lastSince,
            equals(fixedNow.subtract(const Duration(days: 14))),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
        'falls back to the raw vendor id when display-name resolver returns null',
        () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          seed: <OperatorRecentlyAvailableVendorRow>[
            OperatorRecentlyAvailableVendorRow(
              vendorId: 'unknown_vendor',
              promotedAt: DateTime.utc(2026, 5, 5),
            ),
          ],
          now: () => DateTime.utc(2026, 5, 7, 12),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              operatorVendorLifecycleRecentlyAvailablePath,
            ),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final vendors = body['vendors'] as List<Object?>;
          final first = vendors.first as Map<String, Object?>;
          expect(first['vendor_id'], equals('unknown_vendor'));
          expect(first['vendor_display_name'], equals('unknown_vendor'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('since query param narrows the gateway call', () async {
      await withRealHttp(() async {
        final fixedNow = DateTime.utc(2026, 5, 7, 12);
        final ctx = await spinUp(now: () => fixedNow);
        try {
          final since = DateTime.utc(2026, 5, 1);
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri
                .resolve(operatorVendorLifecycleRecentlyAvailablePath)
                .replace(queryParameters: <String, String>{
              'since': since.toIso8601String(),
            }),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          expect(ctx.gateway.lastSince, equals(since));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('400 when since is malformed', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(now: () => DateTime.utc(2026, 5, 7, 12));
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri
                .resolve(operatorVendorLifecycleRecentlyAvailablePath)
                .replace(queryParameters: <String, String>{
              'since': 'not-a-date',
            }),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_since'));
          expect(ctx.gateway.calls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
        'clamps a since older than the 90-day max window',
        () async {
      await withRealHttp(() async {
        final fixedNow = DateTime.utc(2026, 5, 7, 12);
        final ctx = await spinUp(now: () => fixedNow);
        try {
          // Request a 365-day window. The proxy clamps to 90 days.
          final since = fixedNow.subtract(const Duration(days: 365));
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri
                .resolve(operatorVendorLifecycleRecentlyAvailablePath)
                .replace(queryParameters: <String, String>{
              'since': since.toIso8601String(),
            }),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          expect(
            ctx.gateway.lastSince,
            equals(fixedNow.subtract(const Duration(days: 90))),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('503 when the router is not configured', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(routerConfigured: false);
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              operatorVendorLifecycleRecentlyAvailablePath,
            ),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            body['error'],
            equals(
              'vendor_lifecycle_recently_available_router_not_configured',
            ),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('403 when caller lacks any operator-web role', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(
          initialClaims: const ProxyJwtClaims(
            userId: _kUser,
            operatorId: _kOpA,
            locationId: _kLoc,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              operatorVendorLifecycleRecentlyAvailablePath,
            ),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('forbidden'));
          expect(ctx.gateway.calls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'cross-tenant impossible: gateway sees the JWT operator, never URL',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final aResp = await _httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                operatorVendorLifecycleRecentlyAvailablePath,
              ),
              authorization: 'Bearer fake.token',
            );
            expect(aResp.statusCode, equals(200));
            expect(ctx.gateway.lastOperatorId, equals(_kOpA));

            // Spin up a second server pinned to operator B; the gateway
            // there only sees op-B even with the same URL shape.
            final verifier = _SettableVerifier();
            verifier.claims = const ProxyJwtClaims(
              userId: _kUser,
              operatorId: _kOpB,
              locationId: _kLoc,
              roles: <String>['operator_admin'],
            );
            final guard = ProxyRequestGuard(verifier: verifier);
            final gatewayB = _RecordingRecentlyAvailableGateway();
            final routerB = OperatorVendorLifecycleRecentlyAvailableRouter(
              gateway: gatewayB,
              displayNameResolver: (_) => null,
            );
            final serverB =
                await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            // ignore: unawaited_futures
            serverB.listen((request) async {
              await routeRequest(
                request,
                guard,
                vendorLifecycleRecentlyAvailableRouter: routerB,
              );
            });
            final clientB = HttpClient();
            try {
              final bResp = await _httpGet(
                clientB,
                Uri.parse(
                  'http://${serverB.address.host}:${serverB.port}',
                ).resolve(operatorVendorLifecycleRecentlyAvailablePath),
                authorization: 'Bearer fake.token',
              );
              expect(bResp.statusCode, equals(200));
              expect(gatewayB.lastOperatorId, equals(_kOpB));
            } finally {
              clientB.close(force: true);
              await serverB.close(force: true);
            }
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });
}

class _RecordingRecentlyAvailableGateway
    implements OperatorRecentlyAvailableVendorsGateway {
  _RecordingRecentlyAvailableGateway({
    List<OperatorRecentlyAvailableVendorRow> seed =
        const <OperatorRecentlyAvailableVendorRow>[],
  }) : _seed = seed;

  final List<OperatorRecentlyAvailableVendorRow> _seed;
  int calls = 0;
  String? lastOperatorId;
  String? lastLocationId;
  DateTime? lastSince;
  String? lastActorUserId;

  @override
  Future<List<OperatorRecentlyAvailableVendorRow>> listRecentlyPromoted({
    required String operatorId,
    required String locationId,
    required DateTime since,
    String? actorUserId,
  }) async {
    calls += 1;
    lastOperatorId = operatorId;
    lastLocationId = locationId;
    lastSince = since;
    lastActorUserId = actorUserId;
    return _seed;
  }
}

class _SettableVerifier implements ProxyJwtVerifier {
  ProxyJwtClaims? claims;
  Object? error;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async {
    final err = error;
    if (err != null) throw err;
    final c = claims;
    if (c == null) {
      throw ProxyJwtVerificationError('no claims set');
    }
    return c;
  }
}

class _HttpResponseSnapshot {
  const _HttpResponseSnapshot({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
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
