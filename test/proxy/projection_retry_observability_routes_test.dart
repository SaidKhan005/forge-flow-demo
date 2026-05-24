import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';

void main() {
  group('projection retry admin observability route', () {
    test('ff_support can read projection retry visibility shape', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingObservabilityGateway();
        final ctx = await _spinUp(
          gateway: gateway,
          claims: const ProxyJwtClaims(
            userId: 'support-user',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '$adminObservabilityPath?operator_id=op-1'
              '&location_ids=loc-a,loc-b',
            ),
          );

          expect(response.statusCode, equals(200));
          expect(gateway.calls, equals(1));
          expect(gateway.actorUserIds, equals(<String>['support-user']));
          expect(gateway.operatorIds, equals(<String?>['op-1']));
          expect(
            gateway.locationIdLists,
            equals(<List<String>?>[
              <String>['loc-a', 'loc-b'],
            ]),
          );
          // No `month=` param → the route clamps to the current month.
          expect(gateway.months, equals(<ObservabilityMonth>[
            ObservabilityMonth.current,
          ]));

          final projectionRetries =
              response.body['projection_retries'] as Map<String, Object?>;
          expect(
            projectionRetries['status_counts'],
            equals(<String, Object?>{
              'pending': 2,
              'running': 1,
              'succeeded': 0,
              'dead_lettered': 1,
            }),
          );
          expect(projectionRetries['recent_active'], isA<List<Object?>>());
          expect(projectionRetries['dead_lettered'], isA<List<Object?>>());
          final recent = projectionRetries['recent_active'] as List<Object?>;
          final activeRow = recent.single as Map<String, Object?>;
          expect(activeRow['claimability_label'], equals('Ready'));
          expect(activeRow['is_claimable'], isTrue);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('non-admin caller is rejected before gateway execution', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingObservabilityGateway();
        final ctx = await _spinUp(
          gateway: gateway,
          claims: const ProxyJwtClaims(
            userId: 'ordinary-user',
            operatorId: 'op-1',
            locationId: 'loc-1',
            roles: <String>['operator_owner'],
          ),
        );
        try {
          final response = await _httpGet(
            ctx.client,
            ctx.baseUri.resolve(adminObservabilityPath),
          );

          expect(response.statusCode, equals(403));
          expect(response.body['error'], equals('permission_denied'));
          expect(
            response.body['required_roles'],
            containsAll(<String>['super_admin', 'ff_support']),
          );
          expect(gateway.calls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('observability admin route month= parsing', () {
    // `usage_logs` is a monthly rollup, so the only honest cost windows
    // are the current and the immediately preceding calendar month. The
    // route maps `current`/`previous` through and clamps everything else
    // (missing, blank, garbage, mixed-case typos) to `current`.
    Future<ObservabilityMonth> recordedMonthFor(String? monthQuery) async {
      return _withRealHttp(() async {
        final gateway = _RecordingObservabilityGateway();
        final ctx = await _spinUp(
          gateway: gateway,
          claims: const ProxyJwtClaims(
            userId: 'support-user',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          ),
        );
        try {
          final uri = monthQuery == null
              ? ctx.baseUri.resolve(adminObservabilityPath)
              : ctx.baseUri.resolve('$adminObservabilityPath?month=$monthQuery');
          final response = await _httpGet(ctx.client, uri);
          expect(response.statusCode, equals(200));
          expect(gateway.calls, equals(1));
          return gateway.months.single;
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    }

    test('month=current maps to current', () async {
      expect(await recordedMonthFor('current'), ObservabilityMonth.current);
    });

    test('month=previous maps to previous', () async {
      expect(await recordedMonthFor('previous'), ObservabilityMonth.previous);
    });

    test('missing month clamps to current', () async {
      expect(await recordedMonthFor(null), ObservabilityMonth.current);
    });

    test('blank month clamps to current', () async {
      expect(await recordedMonthFor(''), ObservabilityMonth.current);
    });

    test('garbage month clamps to current (never a wider window)', () async {
      expect(await recordedMonthFor('24h'), ObservabilityMonth.current);
      expect(await recordedMonthFor('7d'), ObservabilityMonth.current);
      expect(await recordedMonthFor('last-quarter'), ObservabilityMonth.current);
    });

    test('mixed-case PREVIOUS still maps to previous', () async {
      expect(await recordedMonthFor('PREVIOUS'), ObservabilityMonth.previous);
    });
  });
}

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
  required ObservabilityAdminProxyGateway gateway,
  required ProxyJwtClaims claims,
}) async {
  final guard = ProxyRequestGuard(verifier: _FixedClaimsVerifier(claims));
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    await routeRequest(request, guard, observabilityAdminGateway: gateway);
  });
  final client = HttpClient();
  final baseUri = Uri.parse('http://${server.address.host}:${server.port}');
  return (server: server, client: client, baseUri: baseUri);
}

Future<({int statusCode, Map<String, Object?> body})> _httpGet(
  HttpClient client,
  Uri uri,
) async {
  final request = await client.getUrl(uri);
  request.persistentConnection = false;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer fake.token');
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  final decoded = text.isEmpty ? <String, Object?>{} : jsonDecode(text);
  return (
    statusCode: response.statusCode,
    body: decoded is Map
        ? decoded.cast<String, Object?>()
        : <String, Object?>{},
  );
}

class _FixedClaimsVerifier implements ProxyJwtVerifier {
  const _FixedClaimsVerifier(this.claims);

  final ProxyJwtClaims claims;

  @override
  Future<ProxyJwtClaims> verify(String bearerToken) async => claims;
}

class _RecordingObservabilityGateway implements ObservabilityAdminProxyGateway {
  int calls = 0;
  final actorUserIds = <String>[];
  final operatorIds = <String?>[];
  final locationIds = <String?>[];
  final locationIdLists = <List<String>?>[];
  final months = <ObservabilityMonth>[];

  @override
  Future<Map<String, Object?>> fetch({
    required String actorUserId,
    required String adminReason,
    required int costTelemetryLimit,
    String? queryClassFilter,
    String? operatorId,
    String? locationId,
    List<String>? locationIds,
    ObservabilityMonth month = ObservabilityMonth.current,
  }) async {
    calls += 1;
    actorUserIds.add(actorUserId);
    operatorIds.add(operatorId);
    this.locationIds.add(locationId);
    locationIdLists.add(locationIds);
    months.add(month);
    return <String, Object?>{
      'as_of': '2026-05-19T12:00:00.000Z',
      'contract': 'admin_observability.v1',
      'schema_version': 1,
      'projection_retries': <String, Object?>{
        'status_counts': <String, Object?>{
          'pending': 2,
          'running': 1,
          'succeeded': 0,
          'dead_lettered': 1,
        },
        'recent_active': const <Map<String, Object?>>[
          <String, Object?>{
            'job_id': 'job-active',
            'status': 'pending',
            'failure_stage': 'post_input',
            'claimability_state': 'ready',
            'claimability_label': 'Ready',
            'is_claimable': true,
          },
        ],
        'dead_lettered': const <Map<String, Object?>>[
          <String, Object?>{
            'job_id': 'job-dead',
            'status': 'dead_lettered',
            'failure_stage': 'pre_input',
            'claimability_state': 'dead_lettered',
            'claimability_label': 'Dead-lettered',
            'is_claimable': false,
          },
        ],
      },
    };
  }
}
