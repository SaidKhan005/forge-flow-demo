import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/postgres_executor.dart';
import 'package:forge_and_flow/infrastructure/persistence/postgres/tenant_transaction.dart';

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../../tool/advisor_proxy/proxy_bootstrap.dart';

void main() {
  group('Admin debug-console proxy routes', () {
    test('GET requests forwards multi-location support-log filters', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingDebugConsoleGateway();
        final ctx = await _spinUp(gateway);
        try {
          final uri = ctx.baseUri.resolve(
            '$adminDebugRequestsPath?operator_id=op-1'
            '&location_ids=loc-a,loc-b&limit=25',
          );
          final response = await _httpGet(ctx.client, uri);

          expect(response.statusCode, equals(200));
          expect(gateway.operatorIds, equals(<String?>['op-1']));
          expect(gateway.locationIds, equals(<String?>[null]));
          expect(
            gateway.locationIdLists,
            equals(<List<String>?>[
              <String>['loc-a', 'loc-b'],
            ]),
          );
          expect(gateway.limits, equals(<int>[25]));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'GET relationship-help forwards exact typed use-case filters',
      () async {
        await _withRealHttp(() async {
          final gateway = _RecordingDebugConsoleGateway();
          final ctx = await _spinUp(gateway);
          try {
            final uri = ctx.baseUri.resolve(
              '$adminDebugRelationshipHelpPath?operator_id=op-1'
              '&support_use_case=relationship_review&limit=25',
            );
            final response = await _httpGet(ctx.client, uri);

            expect(response.statusCode, equals(200));
            expect(gateway.operatorIds, equals(<String?>['op-1']));
            expect(
              gateway.usageClasses,
              equals(<String?>['relationship_review']),
            );
            expect(gateway.limits, equals(<int>[25]));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('GET account-help rejects use cases outside the typed tab', () async {
      await _withRealHttp(() async {
        final gateway = _RecordingDebugConsoleGateway();
        final ctx = await _spinUp(gateway);
        try {
          final uri = ctx.baseUri.resolve(
            '$adminDebugAccountHelpPath?support_use_case=relationship_review',
          );
          final response = await _httpGet(ctx.client, uri);

          expect(response.statusCode, equals(400));
          expect(response.body['error'], equals('invalid_support_use_case'));
          expect(gateway.usageClasses, isEmpty);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  // ── P2 — proxy_request_stats read projection (Support logs, plan §12) ────
  //
  // The RepositoryDebugConsoleAdminProxyGateway drives the real projection
  // SQL (`_debugRequestProjectionSql` / `_debugRequestBaseSelect`) and the
  // real row->JSON mapping (`_debugRequestRowJson`). These tests use a fake
  // pool that returns canned projection rows so the Dart-side contract is
  // pinned without a live database:
  //   * when the LEFT JOIN matched a stats row, the new telemetry keys
  //     (provider/model/tokens/cost/actor uid) plus the REAL latency/status
  //     are surfaced;
  //   * when no stats row exists, the telemetry keys are ABSENT (honest null,
  //     never 0) and the derived latency/status still populate the wire.
  // The SQL itself is also guarded for the JOIN + coalesce shape (the
  // coalesce/JOIN semantics run live; CI is dark until 2026-06-01).
  group('P2 read projection mapping (proxy_request_stats join)', () {
    test('SQL LEFT JOINs proxy_request_stats and coalesces latency/status', () {
      // The projection constant is private; assert its shape through the SQL
      // the gateway actually issues (captured by the fake transaction below).
      final captured = <String>[];
      final gateway = RepositoryDebugConsoleAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(
          _ProjectionFakePool(onSql: captured.add, rows: const []),
        ),
      );
      return gateway
          .listRequests(
            actorUserId: 'admin',
            adminReason: 'test:list',
            limit: 50,
            includeFullContent: false,
          )
          .then((_) {
            final projectionSql = captured.firstWhere(
              (s) => s.contains('from public.proxy_requests pr'),
              orElse: () => '',
            );
            expect(projectionSql, isNotEmpty);
            expect(
              projectionSql,
              contains('left join public.proxy_request_stats prs'),
            );
            expect(projectionSql, contains('prs.request_id = pr.request_id'));
            expect(projectionSql, contains('coalesce(\n      prs.latency_ms'));
            expect(
              projectionSql,
              contains('coalesce(\n      prs.result_status'),
            );
            expect(projectionSql, contains('prs.actor_user_id::text'));
          });
    });

    test('listRequests surfaces real telemetry when a stats row matched',
        () async {
      final gateway = RepositoryDebugConsoleAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(
          _ProjectionFakePool(
            rows: <PostgresRow>[
              <String, Object?>{
                'request_id': 'req-1',
                'idempotency_key': 'idem-1',
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'advisor_qa',
                // Real outcome from prs.result_status (coalesced in SQL).
                'status': 'error',
                'started_at': '2026-05-03T11:58:12.000Z',
                // Real measured latency (coalesced from prs.latency_ms).
                'latency_ms': 412,
                'provider': 'anthropic',
                'model_id': 'claude-sonnet-4-6',
                'prompt_token_count': 1840,
                'completion_token_count': 318,
                'cost_usd': 0.0117,
                'actor_user_id': '11111111-1111-4111-8111-111111111111',
                'request_meta': <String, Object?>{
                  'request_type': 'advisor',
                  'response_recorded': true,
                  'content_logging': 'meta_only',
                },
                'full_content_opt_in': false,
              },
            ],
          ),
        ),
      );

      final rows = await gateway.listRequests(
        actorUserId: 'admin',
        adminReason: 'test:list',
        limit: 50,
        includeFullContent: false,
      );

      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row['provider'], equals('anthropic'));
      expect(row['model_id'], equals('claude-sonnet-4-6'));
      expect(row['prompt_token_count'], equals(1840));
      expect(row['completion_token_count'], equals(318));
      expect(row['cost_usd'], equals(0.0117));
      expect(
        row['actor_user_id'],
        equals('11111111-1111-4111-8111-111111111111'),
      );
      // Real outcome + measured latency flow through unchanged.
      expect(row['status'], equals('error'));
      expect(row['latency_ms'], equals(412));
    });

    test('listRequests emits honest nulls when no stats row matched',
        () async {
      final gateway = RepositoryDebugConsoleAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(
          _ProjectionFakePool(
            rows: <PostgresRow>[
              <String, Object?>{
                'request_id': 'req-2',
                'idempotency_key': 'idem-2',
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'account_help',
                // Derived ledger status survives the coalesce fallback.
                'status': 'unknown',
                'started_at': '2026-05-03T11:25:04.000Z',
                // Derived row-lifetime latency survives the coalesce fallback.
                'latency_ms': 0,
                // No prs row => these arrive null from the LEFT JOIN.
                'provider': null,
                'model_id': null,
                'prompt_token_count': null,
                'completion_token_count': null,
                'cost_usd': null,
                'actor_user_id': null,
                'request_meta': <String, Object?>{
                  'request_type': 'account_help',
                  'response_recorded': false,
                  'content_logging': 'meta_only',
                },
                'full_content_opt_in': false,
              },
            ],
          ),
        ),
      );

      final rows = await gateway.listRequests(
        actorUserId: 'admin',
        adminReason: 'test:list',
        limit: 50,
        includeFullContent: false,
      );

      expect(rows, hasLength(1));
      final row = rows.single;
      // Telemetry keys are ABSENT (not present-with-null) => honest empty.
      expect(row.containsKey('provider'), isFalse);
      expect(row.containsKey('model_id'), isFalse);
      expect(row.containsKey('prompt_token_count'), isFalse);
      expect(row.containsKey('completion_token_count'), isFalse);
      expect(row.containsKey('cost_usd'), isFalse);
      expect(row.containsKey('actor_user_id'), isFalse);
      // The wire-contract keys stay populated from the derived fallback.
      expect(row['status'], equals('unknown'));
      expect(row['latency_ms'], equals(0));
    });

    test('getByRequestId single-row select carries the same join + mapping',
        () async {
      final captured = <String>[];
      final gateway = RepositoryDebugConsoleAdminProxyGateway(
        adminWrapper: TenantTransactionWrapper(
          _ProjectionFakePool(
            onSql: captured.add,
            rows: <PostgresRow>[
              <String, Object?>{
                'request_id': 'req-9',
                'idempotency_key': 'idem-9',
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'coach_qa',
                'status': 'success',
                'started_at': '2026-05-03T11:30:00.000Z',
                'latency_ms': 250,
                'provider': 'anthropic',
                'model_id': 'claude-haiku-4-5',
                'prompt_token_count': 900,
                'completion_token_count': 64,
                'cost_usd': 0.0009,
                'actor_user_id': '22222222-2222-4222-8222-222222222222',
                'request_meta': <String, Object?>{
                  'request_type': 'coach',
                  'response_recorded': true,
                  'content_logging': 'meta_only',
                },
                'full_content_opt_in': false,
              },
            ],
          ),
        ),
      );

      final row = await gateway.getByRequestId(
        actorUserId: 'admin',
        adminReason: 'test:by_id',
        requestId: 'req-9',
        includeFullContent: false,
      );

      expect(row, isNotNull);
      expect(row!['model_id'], equals('claude-haiku-4-5'));
      expect(row['cost_usd'], equals(0.0009));
      // The single-row base select also joins proxy_request_stats.
      final baseSql = captured.firstWhere(
        (s) => s.contains('from public.proxy_requests pr'),
        orElse: () => '',
      );
      expect(
        baseSql,
        contains('left join public.proxy_request_stats prs'),
      );
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

Future<({HttpServer server, HttpClient client, Uri baseUri})> _spinUp(
  DebugConsoleAdminProxyGateway gateway,
) async {
  final guard = ProxyRequestGuard(
    verifier: _FixedClaimsVerifier(
      const ProxyJwtClaims(
        userId: 'admin-user',
        operatorId: null,
        locationId: null,
        roles: <String>['super_admin'],
      ),
    ),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    await routeRequest(request, guard, debugConsoleAdminGateway: gateway);
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

class _RecordingDebugConsoleGateway implements DebugConsoleAdminProxyGateway {
  final operatorIds = <String?>[];
  final locationIds = <String?>[];
  final locationIdLists = <List<String>?>[];
  final usageClasses = <String?>[];
  final limits = <int>[];

  @override
  Future<List<Map<String, Object?>>> listRequests({
    required String actorUserId,
    required String adminReason,
    String? operatorId,
    String? locationId,
    List<String>? locationIds,
    String? usageClass,
    String? status,
    int? timeWindowSeconds,
    String? searchText,
    required int limit,
    required bool includeFullContent,
  }) async {
    operatorIds.add(operatorId);
    this.locationIds.add(locationId);
    locationIdLists.add(locationIds);
    usageClasses.add(usageClass);
    limits.add(limit);
    return const <Map<String, Object?>>[];
  }

  @override
  Future<Map<String, Object?>?> getByIdempotencyKey({
    required String actorUserId,
    required String adminReason,
    required String idempotencyKey,
    required bool includeFullContent,
  }) async => null;

  @override
  Future<Map<String, Object?>?> getByRequestId({
    required String actorUserId,
    required String adminReason,
    required String requestId,
    required bool includeFullContent,
  }) async => null;

  @override
  Future<List<Map<String, Object?>>> listFullContentOptIns({
    required String actorUserId,
    required String adminReason,
  }) async => const <Map<String, Object?>>[];

  @override
  Future<List<Map<String, Object?>>> tailRecent({
    required String actorUserId,
    required String adminReason,
    required int limit,
    required bool includeFullContent,
  }) async => const <Map<String, Object?>>[];
}

/// Fake pool for the P2 projection-mapping tests. Hands out a transaction
/// that captures every SQL string (so the JOIN/coalesce shape can be
/// asserted) and returns [rows] for the projection SELECT — the SET LOCAL
/// ROLE / audit-marker statements that `runAsSystem` issues first are
/// swallowed (return empty / affected-rows 1) so only the projection query
/// produces rows.
class _ProjectionFakePool implements PostgresPool {
  _ProjectionFakePool({required this.rows, this.onSql});

  final List<PostgresRow> rows;
  final void Function(String sql)? onSql;

  @override
  Future<PostgresTransaction> beginTransaction() async =>
      _ProjectionFakeTransaction(rows: rows, onSql: onSql);
}

class _ProjectionFakeTransaction implements PostgresTransaction {
  _ProjectionFakeTransaction({required this.rows, this.onSql});

  final List<PostgresRow> rows;
  final void Function(String sql)? onSql;

  @override
  Future<List<PostgresRow>> query(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    onSql?.call(sql);
    // Only the projection SELECT returns rows; anything else (the audit
    // marker uses query in some paths) returns empty.
    if (sql.contains('from public.proxy_requests pr')) return rows;
    return const <PostgresRow>[];
  }

  @override
  Future<int> execute(
    String sql, {
    PostgresParameters parameters = const <String, Object?>{},
  }) async {
    onSql?.call(sql);
    return 1;
  }

  @override
  Future<void> commit() async {}

  @override
  Future<void> rollback() async {}
}
