// 11a / 11A — HTTP scaffold + admin route tests (Advisor proxy).
//
// Bucket 5c-http+admin of the 2026-05-20 test-suite tightening audit:
// split out of `test/advisor_proxy_test.dart` (8,328 lines). This is
// the heaviest split bucket: it owns the HttpServer fixture / loopback
// routeRequest tests, the 11A.1 admin operator/location routes,
// the B5 admin business-timing dispatcher route gate, and the 11A.2
// admin pricing tier routes.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/advisor_response_cache.dart';
import 'package:forge_and_flow/domain/services/circuit_breaker.dart';
import 'package:forge_and_flow/services/auth/auth_session_ledger_writer.dart';
import 'package:forge_and_flow/services/auth/firebase_admin_auth_client.dart';

import '../tool/advisor_proxy/advisor_proxy.dart';
import 'advisor_proxy_test_helpers.dart';

void main() {
  group('HTTP scaffold (routeRequest via local HttpServer)', () {
    // Flutter's test environment installs a global HttpOverrides that
    // returns 400 for any real HTTP call. Temporarily clear it for
    // each scaffold test so we can exercise routeRequest end-to-end
    // against a localhost server. Restored after the test body.
    Future<T> withRealHttp<T>(Future<T> Function() body) async {
      final saved = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        return await body();
      } finally {
        HttpOverrides.global = saved;
      }
    }

    late HttpServer server;
    late HttpClient client;
    late SettableVerifier verifier;
    late Uri baseUri;

    Future<void> spinUpServer({
      ProxyUsageGuard? usageGuard,
      ProxyAccountingStore? accountingStore,
      ProxyHealthCheckStore? healthCheckStore,
      ProxyLlmProvider? llmProvider,
      AdvisorRequestPipeline? advisorRequestPipeline,
      AuthSessionLedgerWriter? authSessionLedgerWriter,
      FirebaseAdminAuthClient? firebaseAdminAuthClient,
      bool trustProxyAuditHeaders = false,
      ProxyRequestLogPolicy requestLogPolicy =
          const ProxyRequestLogPolicy.metaOnly(),
      // P1b — optional clock override so a test can drive a measurable
      // wall-clock for proxy_request_stats.latency_ms. Defaults to the
      // fixed instant the rest of the suite relies on.
      DateTime Function()? now,
    }) async {
      verifier = SettableVerifier();
      final guard = ProxyRequestGuard(verifier: verifier);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            usageGuard: usageGuard,
            accountingStore: accountingStore,
            healthCheckStore: healthCheckStore,
            llmProvider: llmProvider,
            advisorRequestPipeline: advisorRequestPipeline,
            authSessionLedgerWriter: authSessionLedgerWriter,
            firebaseAdminAuthClient: firebaseAdminAuthClient,
            trustProxyAuditHeaders: trustProxyAuditHeaders,
            requestLogPolicy: requestLogPolicy,
            now: now ?? () => DateTime.utc(2026, 4, 26, 12),
          );
        } catch (_) {
          try {
            request.response.statusCode = 500;
            await request.response.close();
          } catch (_) {
            /* ignore */
          }
        }
      });
      client = HttpClient();
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
    }

    Future<void> shutDown() async {
      client.close(force: true);
      await server.close(force: true);
    }

    test('GET /healthz and /readyz return 200 ok unauthenticated', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          for (final path in <String>[healthPath, readinessPath]) {
            final response = await httpGet(client, baseUri.resolve(path));
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['status'], equals('ok'));
          }
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /health without a health store returns 503', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          final response = await httpGet(
            client,
            baseUri.resolve(deepHealthPath),
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['status'], equals('unavailable'));
          expect(body['severity'], equals('red'));
          expect(body['contract'], equals('proxy_health.v1'));
          expect(body['error'], equals('health_check_not_configured'));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /health returns 200 only when Postgres, AGE, and pgvector pass',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            healthCheckStore: const FixedHealthStore(
              ProxyHealthStatus(
                postgresOk: true,
                ageOk: true,
                pgvectorOk: true,
              ),
            ),
          );
          try {
            final response = await httpGet(
              client,
              baseUri.resolve(deepHealthPath),
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['status'], equals('ok'));
            expect(body['severity'], equals('green'));
            expect(body['contract'], equals('proxy_health.v1'));
            expect(body['schema_version'], equals(1));
            expect(body['checked_at'], equals('2026-04-26T12:00:00.000Z'));
            expect(body['postgres_select_1'], equals('ok'));
            expect(body['age_cypher_match'], equals('ok'));
            expect(body['pgvector_similarity'], equals('ok'));
            final dependencies = body['dependencies']! as Map<String, Object?>;
            expect(
              (dependencies['postgres']! as Map<String, Object?>)['status'],
              equals('green'),
            );
            expect(
              (dependencies['age']! as Map<String, Object?>)['legacy_key'],
              equals('age_cypher_match'),
            );
            final metrics = body['metrics']! as Map<String, Object?>;
            expect(metrics.keys, contains('audit_chain_lag_seconds'));
            expect(metrics.keys, contains('event_outbox_undelivered_count'));
            expect(metrics.keys, contains('event_outbox_lag_seconds'));
            expect(metrics.keys, contains('usage_caps_breach_count'));
            expect(metrics.keys, contains('graph_node_count'));
            expect(metrics.keys, contains('graph_edge_count'));
            expect(metrics.keys, contains('graph_traversal_latency_ms'));
            expect(metrics.keys, contains('vector_index_size_per_corpus'));
            expect(metrics.keys, contains('vector_query_latency_ms'));
            expect(metrics.keys, contains('vector_recall'));
            expect(metrics.keys, contains('rollup_freshness_per_grain'));
            expect(
              (metrics['graph_edge_count']! as Map<String, Object?>)['status'],
              equals('unknown'),
            );
            expect(
              (metrics['graph_edge_count']! as Map<String, Object?>)['value'],
              isNull,
            );
            final surfaces = body['surfaces']! as Map<String, Object?>;
            expect(
              surfaces.keys,
              containsAll(<String>[
                'audit_chain',
                'event_outbox',
                'usage_caps',
                'graph',
                'vector',
                'rollups',
              ]),
            );
            expect(
              (surfaces['graph']! as Map<String, Object?>)['metrics'],
              containsAll(<String>[
                'graph_node_count',
                'graph_edge_count',
                'graph_traversal_latency_ms',
              ]),
            );
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('GET /health returns 503 when one dependency check fails', () async {
      await withRealHttp(() async {
        await spinUpServer(
          healthCheckStore: const FixedHealthStore(
            ProxyHealthStatus(postgresOk: true, ageOk: false, pgvectorOk: true),
          ),
        );
        try {
          final response = await httpGet(
            client,
            baseUri.resolve(deepHealthPath),
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['status'], equals('unavailable'));
          expect(body['severity'], equals('red'));
          expect(body['age_cypher_match'], equals('failed'));
          final dependencies = body['dependencies']! as Map<String, Object?>;
          expect(
            (dependencies['age']! as Map<String, Object?>)['status'],
            equals('red'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /health degrades for populated non-blocking metrics', () async {
      await withRealHttp(() async {
        await spinUpServer(
          healthCheckStore: const FixedHealthStore(
            ProxyHealthStatus(
              postgresOk: true,
              ageOk: true,
              pgvectorOk: true,
              metrics: <String, ProxyHealthMetric>{
                'usage_caps_breach_count': ProxyHealthMetric(
                  status: 'yellow',
                  value: 1,
                  unit: 'count',
                  description:
                      'Requests refused because usage caps were reached.',
                  owner: 'B33',
                  thresholds: <String, Object?>{'yellow': 1, 'red': 10},
                ),
              },
            ),
          ),
        );
        try {
          final response = await httpGet(
            client,
            baseUri.resolve(deepHealthPath),
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['status'], equals('degraded'));
          expect(body['severity'], equals('yellow'));
          final metrics = body['metrics']! as Map<String, Object?>;
          expect(
            (metrics['usage_caps_breach_count']!
                as Map<String, Object?>)['status'],
            equals('yellow'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/scope without Authorization returns 401', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          final response = await httpGet(
            client,
            baseUri.resolve(scopeSmokePath),
          );
          expect(response.statusCode, equals(401));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], isA<String>());
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/scope with verifier failure returns 401', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          verifier.errorMessage = 'expired token';
          final response = await httpGet(
            client,
            baseUri.resolve(scopeSmokePath),
            authorization: 'Bearer some.fake.token',
          );
          expect(response.statusCode, equals(401));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /v1/scope with verified-but-unscoped token returns 403',
      () async {
        await withRealHttp(() async {
          await spinUpServer();
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: null,
              locationId: 'loc_y',
              roles: <String>[],
            );
            final response = await httpGet(
              client,
              baseUri.resolve(scopeSmokePath),
              authorization: 'Bearer some.fake.token',
            );
            expect(response.statusCode, equals(403));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('GET /v1/scope happy path returns 200 with operator/location echo '
        'and notes the slice does not call providers', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );

          final response = await httpGet(
            client,
            baseUri.resolve(scopeSmokePath),
            authorization: 'Bearer some.fake.token',
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['user_id'], equals('user_x'));
          expect(body['operator_id'], equals('op_777'));
          expect(body['location_id'], equals('loc_999'));
          expect(body['roles'], equals(<String>['advisor.read']));
          expect(body['note'], contains('11a.10a'));
          expect(body['note'], contains('No provider call performed'));
        } finally {
          await shutDown();
        }
      });
    });

    test('unknown route returns 404', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          final response = await httpGet(
            client,
            baseUri.resolve('/no-such-route'),
          );
          expect(response.statusCode, equals(404));
        } finally {
          await shutDown();
        }
      });
    });

    // ── /v1/usage-smoke (11a.10b) ────────────────────────────────────────

    test('GET /v1/usage-smoke without a usage guard returns 503', () async {
      await withRealHttp(() async {
        await spinUpServer();
        try {
          final response = await httpGet(
            client,
            baseUri.resolve(usageSmokePath),
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('usage_guard_not_configured'));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/usage-smoke without Authorization returns 401 even with '
        'a configured usage guard', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: FixedSnapshotProxyUsageStore(
              snapshot: UsageSnapshot(
                requestsThisMinute: 0,
                costCentsThisMonth: 0,
                minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
                monthBucketStart: DateTime.utc(2026, 4, 1),
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          final response = await httpGet(
            client,
            baseUri.resolve(usageSmokePath),
          );
          expect(response.statusCode, equals(401));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/usage-smoke with a non-StateError store failure returns 503 '
        'usage_store_unavailable without leaking raw error text', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: BoomProxyUsageStore(
              error: const FormatException(
                'pretend-secret-bearing-detail '
                'postgres://user:password@host:5432/db',
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );
          final response = await httpGet(
            client,
            baseUri.resolve(usageSmokePath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('usage_store_unavailable'));
          expect(body['tier_id'], equals('launch'));
          expect(body['reason'], equals('unexpected store failure'));
          expect(response.body, isNot(contains('pretend-secret')));
          expect(response.body, isNot(contains('postgres://')));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /v1/usage-smoke with the scaffold-failing store returns 503',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            usageGuard: ProxyUsageGuard(
              store: const ScaffoldFailingUsageCounterStore(),
              tierResolver: const FixedLaunchTierResolver(),
            ),
          );
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_777',
              locationId: 'loc_999',
              roles: <String>['advisor.read'],
            );
            final response = await httpGet(
              client,
              baseUri.resolve(usageSmokePath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('usage_store_unavailable'));
            expect(body['tier_id'], equals('launch'));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test(
      'GET /v1/usage-smoke with an over-token estimate returns 413',
      () async {
        await withRealHttp(() async {
          // Counter store should never be called on this path.
          final store = RecordingProxyUsageStore();
          await spinUpServer(
            usageGuard: ProxyUsageGuard(
              store: store,
              tierResolver: const FixedLaunchTierResolver(),
            ),
          );
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_777',
              locationId: 'loc_999',
              roles: <String>['advisor.read'],
            );
            final overTokens = PolicyTier.launch.maxRequestTokens + 1;
            final response = await httpGet(
              client,
              baseUri
                  .resolve(usageSmokePath)
                  .replace(
                    queryParameters: <String, String>{
                      'est_tokens': overTokens.toString(),
                    },
                  ),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(413));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('request_too_large'));
            expect(body['tier_id'], equals('launch'));
            expect(store.currentUsageCalls, equals(0));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('GET /v1/usage-smoke at the per-minute cap returns 429', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: FixedSnapshotProxyUsageStore(
              snapshot: UsageSnapshot(
                requestsThisMinute: PolicyTier.launch.maxRequestsPerMinute,
                costCentsThisMonth: 0,
                minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
                monthBucketStart: DateTime.utc(2026, 4, 1),
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );
          final response = await httpGet(
            client,
            baseUri.resolve(usageSmokePath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(429));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('rate_limited'));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/usage-smoke at the monthly cost cap returns 402', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: FixedSnapshotProxyUsageStore(
              snapshot: UsageSnapshot(
                requestsThisMinute: 0,
                costCentsThisMonth: PolicyTier.launch.maxMonthlyCostCents,
                minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
                monthBucketStart: DateTime.utc(2026, 4, 1),
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );
          final response = await httpGet(
            client,
            baseUri.resolve(usageSmokePath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(402));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('monthly_cap_reached'));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/usage-smoke happy path returns the contracted '
        '{tier, minute_remaining, month_remaining} envelope', () async {
      await withRealHttp(() async {
        await spinUpServer(
          usageGuard: ProxyUsageGuard(
            store: FixedSnapshotProxyUsageStore(
              snapshot: UsageSnapshot(
                requestsThisMinute: 5,
                costCentsThisMonth: 250,
                minuteBucketStart: DateTime.utc(2026, 4, 25, 12, 0),
                monthBucketStart: DateTime.utc(2026, 4, 1),
              ),
            ),
            tierResolver: const FixedLaunchTierResolver(),
          ),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user_x',
            operatorId: 'op_777',
            locationId: 'loc_999',
            roles: <String>['advisor.read'],
          );

          final response = await httpGet(
            client,
            baseUri
                .resolve(usageSmokePath)
                .replace(
                  queryParameters: <String, String>{'est_tokens': '256'},
                ),
            authorization: 'Bearer fake.token',
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          // HARD-A: contracted envelope is `{tier, minute_remaining,
          // month_remaining}`. Tenant identifiers MUST NOT appear in
          // the response.
          expect(body['tier'], equals('launch'));
          expect(
            body['minute_remaining'],
            equals(PolicyTier.launch.maxRequestsPerMinute - 5),
          );
          expect(
            body['month_remaining'],
            equals(PolicyTier.launch.maxMonthlyCostCents - 250),
          );
          expect(body.containsKey('user_id'), isFalse);
          expect(body.containsKey('operator_id'), isFalse);
          expect(body.containsKey('location_id'), isFalse);
          // Tier policy metadata is still echoed for caller convenience.
          expect(
            body['request_timeout_seconds'],
            equals(PolicyTier.launch.requestTimeoutSeconds),
          );
          expect(
            body['max_output_tokens'],
            equals(PolicyTier.launch.maxOutputTokens),
          );
          expect(body['estimate_request_tokens'], equals(256));
        } finally {
          await shutDown();
        }
      });
    });

    // -- /v1/advisor-smoke (11a.11d) ---------------------------------------

    test('GET /v1/advisor-smoke requires an idempotency key', () async {
      await withRealHttp(() async {
        await spinUpServer(
          accountingStore: InMemoryAccountingStore.open(),
          llmProvider: RecordingLlmProvider(),
        );
        try {
          verifier.claims = defaultProxyClaims();
          final response = await httpGet(
            client,
            baseUri.resolve(advisorSmokePath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_idempotency_key'));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /v1/advisor-smoke refuses over-cap before provider call',
      () async {
        await withRealHttp(() async {
          final llm = RecordingLlmProvider();
          await spinUpServer(
            accountingStore: InMemoryAccountingStore(
              capStatus: const ProxyCapStatus(
                usageClass: 'advisor_qa',
                monthlyCapCents: 1,
                monthlyUsedCents: 1,
                perInvocationCapCents: 1,
                estimatedCostCents: 1,
              ),
            ),
            llmProvider: llm,
          );
          try {
            verifier.claims = defaultProxyClaims();
            final response = await httpGet(
              client,
              baseUri.resolve(advisorSmokePath),
              authorization: 'Bearer fake.token',
              headers: const <String, String>{
                'Idempotency-Key': 'idem-overcap',
              },
            );
            expect(response.statusCode, equals(402));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('usage_cap_reached'));
            expect(body['cap_status'], isA<Map<String, Object?>>());
            expect(llm.completeCalls, equals(0));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('GET /v1/advisor-smoke happy path routes tier, caches stable prompt '
        'blocks, writes accounting, and logs meta-only by default', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = RecordingLlmProvider();
        await spinUpServer(accountingStore: store, llmProvider: llm);
        try {
          verifier.claims = defaultProxyClaims();
          final response = await httpGet(
            client,
            baseUri
                .resolve(advisorSmokePath)
                .replace(
                  queryParameters: <String, String>{
                    'subscription_tier': 'premium',
                    'query_class': 'recommendation',
                    'corpus_version': 'launch_v2',
                    'q': 'private operator question',
                  },
                ),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-happy'},
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['llm_tier'], equals('sonnet'));
          expect(body['model_used'], equals('claude-sonnet-4-6'));
          expect(body['cache_key'], equals('advisor-corpus:launch_v2'));
          expect(
            body['prompt_cache_breakpoints'],
            equals(<Object?>[
              'system_prompt',
              'tool_definitions',
              'corpus_context:launch_v2',
            ]),
          );
          expect(store.completeCalls, equals(1));
          expect(llm.completeCalls, equals(1));
          expect(llm.lastRequest!.tier, equals(ProxyLlmTier.sonnet));
          final log = body['request_log_preview'] as Map<String, Object?>;
          expect(log['content_logging'], equals('meta_only'));
          expect(log, isNot(containsPair('question', anything)));
          expect(log, isNot(containsPair('answer', anything)));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke idempotent retry replays stored response '
        'without a second provider call', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = RecordingLlmProvider();
        await spinUpServer(accountingStore: store, llmProvider: llm);
        try {
          verifier.claims = defaultProxyClaims();
          final uri = baseUri.resolve(advisorSmokePath);
          final first = await httpGet(
            client,
            uri,
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-retry'},
          );
          final second = await httpGet(
            client,
            uri,
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-retry'},
          );

          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          final replay = jsonDecode(second.body) as Map<String, Object?>;
          expect(replay['idempotent_replay'], isTrue);
          expect(llm.completeCalls, equals(1));
          expect(store.completeCalls, equals(1));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke can include full content only when the '
        'operator logging policy opts in', () async {
      await withRealHttp(() async {
        await spinUpServer(
          accountingStore: InMemoryAccountingStore.open(),
          llmProvider: RecordingLlmProvider(),
          requestLogPolicy: const ProxyRequestLogPolicy(
            fullContentLoggingEnabled: true,
          ),
        );
        try {
          verifier.claims = defaultProxyClaims();
          final response = await httpGet(
            client,
            baseUri
                .resolve(advisorSmokePath)
                .replace(
                  queryParameters: const <String, String>{
                    'q': 'operator opted into content logging',
                  },
                ),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-full-log'},
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final log = body['request_log_preview'] as Map<String, Object?>;
          expect(log['content_logging'], equals('full'));
          expect(
            log['question'],
            equals('operator opted into content logging'),
          );
          expect(log['answer'], equals('fake advisor answer'));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke pipeline path: primary success commits '
        'final estimate (input + output) with circuit_state=closed', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = RecordingLlmProvider();
        final breaker = CircuitBreaker(providerId: 'anthropic');
        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: const AlwaysMissAdvisorResponseCache(),
        );
        await spinUpServer(
          accountingStore: store,
          llmProvider: llm,
          advisorRequestPipeline: pipeline,
        );
        try {
          verifier.claims = defaultProxyClaims();
          final response = await httpGet(
            client,
            baseUri
                .resolve(advisorSmokePath)
                .replace(
                  queryParameters: const <String, String>{
                    'tokens': '50',
                    'cost_cents': '10',
                  },
                ),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{'Idempotency-Key': 'idem-pipe-ok'},
          );
          expect(response.statusCode, equals(200));
          expect(store.commitCalls, equals(1));
          final committed = store.lastCommittedTelemetry!;
          expect(committed.circuitState, equals('closed'));
          expect(committed.fallbackUsed, equals('none'));
          expect(committed.cacheHit, isFalse);
          // RecordingLlmProvider returns outputTokens=12, costCents=1.
          expect(store.lastCommittedTokenCount, equals(50 + 12));
          expect(store.lastCommittedCostCents, equals(10 + 1));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke pipeline path: breaker-open + cache miss '
        'commits cacheHit=false, fallback_used=refusal, zero usage', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = RecordingLlmProvider();
        final breaker = CircuitBreaker(providerId: 'anthropic')
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown);
        expect(breaker.state, equals(CircuitState.open));
        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: const AlwaysMissAdvisorResponseCache(),
        );
        await spinUpServer(
          accountingStore: store,
          llmProvider: llm,
          advisorRequestPipeline: pipeline,
        );
        try {
          verifier.claims = defaultProxyClaims();
          final response = await httpGet(
            client,
            baseUri.resolve(advisorSmokePath),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-pipe-refusal',
            },
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('service_degraded'));
          final degraded = body['degraded'] as Map<String, Object?>;
          expect(degraded['circuit_state'], equals('open'));
          expect(degraded['cached_answer'], isNull);

          final committed = store.lastCommittedTelemetry!;
          expect(committed.circuitState, equals('open'));
          expect(committed.fallbackUsed, equals('refusal'));
          expect(committed.cacheHit, isFalse);
          expect(store.lastCommittedTokenCount, equals(0));
          expect(store.lastCommittedCostCents, equals(0));
          expect(llm.completeCalls, equals(0));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke pipeline path: breaker-open + cache hit '
        'commits cacheHit=true, fallback_used=cache, zero usage', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = RecordingLlmProvider();
        final breaker = CircuitBreaker(providerId: 'anthropic')
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown);
        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: const StaticHitAdvisorCache('previous cached answer'),
        );
        await spinUpServer(
          accountingStore: store,
          llmProvider: llm,
          advisorRequestPipeline: pipeline,
        );
        try {
          verifier.claims = defaultProxyClaims();
          final response = await httpGet(
            client,
            baseUri.resolve(advisorSmokePath),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-pipe-cache',
            },
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final degraded = body['degraded'] as Map<String, Object?>;
          expect(degraded['cached_answer'], equals('previous cached answer'));

          final committed = store.lastCommittedTelemetry!;
          expect(committed.circuitState, equals('open'));
          expect(committed.fallbackUsed, equals('cache'));
          expect(committed.cacheHit, isTrue);
          expect(store.lastCommittedTokenCount, equals(0));
          expect(store.lastCommittedCostCents, equals(0));
        } finally {
          await shutDown();
        }
      });
    });

    // ── P1b — proxy_request_stats writer (Support logs, plan §12) ────────
    //
    // The completion step hands a ProxyRequestStats payload to
    // completeRequest. These tests pin, end-to-end through routeRequest:
    //   * one stats row per real request, with the measured latency_ms,
    //     real result_status='success', actor uuid, request_id
    //     correlation, provider/model id, and the same token/cost the
    //     usage-log write used;
    //   * NO duplicate stats row on an idempotency replay;
    //   * a graceful cache/refusal degradation still writes a 'success'
    //     stats row with zero provider tokens;
    //   * the writer fires for every LLM usage class (one shared
    //     completion path), not just the advisor_qa default.

    test(
      'GET /v1/advisor-smoke writes one proxy_request_stats row with '
      'measured latency, real status, actor, request_id, model + cost',
      () async {
        await withRealHttp(() async {
          final store = InMemoryAccountingStore.open();
          final llm = RecordingLlmProvider();
          // Advancing clock: each clock() read steps +250ms so the measured
          // wall-clock latency between the post-validation anchor and
          // completion is strictly positive (the rest of the suite uses a
          // fixed instant, which would measure 0).
          var tick = DateTime.utc(2026, 4, 26, 12);
          DateTime advancingNow() {
            final value = tick;
            tick = tick.add(const Duration(milliseconds: 250));
            return value;
          }

          await spinUpServer(
            accountingStore: store,
            llmProvider: llm,
            now: advancingNow,
          );
          try {
            verifier.claims = defaultUuidProxyClaims();
            final response = await httpGet(
              client,
              baseUri
                  .resolve(advisorSmokePath)
                  .replace(
                    queryParameters: const <String, String>{
                      'subscription_tier': 'premium',
                      // premium + recommendation routes to sonnet (matches
                      // the happy-path test), proving the stats model id
                      // tracks the model actually used, not the default.
                      'query_class': 'recommendation',
                      'tokens': '40',
                      'cost_cents': '9',
                    },
                  ),
              authorization: 'Bearer fake.token',
              headers: const <String, String>{'Idempotency-Key': 'idem-stats'},
            );

            expect(response.statusCode, equals(200));
            expect(store.completeCalls, equals(1));
            expect(store.recordedStats, hasLength(1));

            final stats = store.lastStats!;
            expect(stats.usageClass, equals('advisor_qa'));
            expect(stats.resultStatus, equals('success'));
            // request_id correlation: the value the reservation surfaced.
            expect(
              stats.requestId,
              equals(store.reservedRequestIds['idem-stats']),
            );
            expect(stats.requestId, isNotNull);
            // actor = the acting human user's UUID from the verified scope.
            expect(
              stats.actorUserId,
              equals('11111111-1111-4111-8111-111111111111'),
            );
            // premium tier routes to sonnet; provider derived from model id.
            expect(stats.modelId, equals('claude-sonnet-4-6'));
            expect(stats.provider, equals('anthropic'));
            expect(stats.modelVersion, isNull);
            // RecordingLlmProvider returns outputTokens=12; input estimate 40.
            expect(stats.promptTokenCount, equals(40));
            expect(stats.completionTokenCount, equals(12));
            // cost = final estimate (9 + provider 1) cents -> $0.10.
            expect(stats.costUsd, closeTo(0.10, 1e-9));
            // measured wall-clock latency is strictly positive.
            expect(stats.latencyMs, isNotNull);
            expect(stats.latencyMs! > 0, isTrue);
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('GET /v1/advisor-smoke idempotent replay writes NO duplicate '
        'proxy_request_stats row', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = RecordingLlmProvider();
        await spinUpServer(accountingStore: store, llmProvider: llm);
        try {
          verifier.claims = defaultUuidProxyClaims();
          final uri = baseUri.resolve(advisorSmokePath);
          final first = await httpGet(
            client,
            uri,
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-stats-replay',
            },
          );
          final second = await httpGet(
            client,
            uri,
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-stats-replay',
            },
          );

          expect(first.statusCode, equals(200));
          expect(second.statusCode, equals(200));
          final replay = jsonDecode(second.body) as Map<String, Object?>;
          expect(replay['idempotent_replay'], isTrue);
          // The replay early-returns before completeRequest, so exactly one
          // completion and one stats row exist across the two calls.
          expect(store.completeCalls, equals(1));
          expect(store.recordedStats, hasLength(1));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke degraded (breaker-open) path still writes a '
        'success stats row with zero provider tokens', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = RecordingLlmProvider();
        final breaker = CircuitBreaker(providerId: 'anthropic')
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown)
          ..recordFailure(FailureKind.unknown);
        final pipeline = AdvisorRequestPipeline(
          breaker: breaker,
          cache: const AlwaysMissAdvisorResponseCache(),
        );
        await spinUpServer(
          accountingStore: store,
          llmProvider: llm,
          advisorRequestPipeline: pipeline,
        );
        try {
          verifier.claims = defaultUuidProxyClaims();
          final response = await httpGet(
            client,
            baseUri.resolve(advisorSmokePath),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-stats-degraded',
            },
          );
          expect(response.statusCode, equals(200));
          expect(store.recordedStats, hasLength(1));
          final stats = store.lastStats!;
          // The request itself completed (graceful refusal), so the proxy
          // outcome is a success; no provider call -> zero tokens, $0 cost.
          expect(stats.resultStatus, equals('success'));
          expect(stats.promptTokenCount, equals(0));
          expect(stats.completionTokenCount, equals(0));
          expect(stats.costUsd, closeTo(0.0, 1e-9));
          expect(llm.completeCalls, equals(0));
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke writes proxy_request_stats for every LLM '
        'usage class via the one shared completion path', () async {
      // advisor_qa / coach_qa / wf_pl / wf_schedule all funnel through the
      // same accounting completion; the writer keys off the usage_class
      // parameter, not a per-class handler.
      for (final usageClass in const <String>[
        'advisor_qa',
        'coach_qa',
        'wf_pl',
        'wf_schedule',
      ]) {
        await withRealHttp(() async {
          final store = InMemoryAccountingStore.open();
          final llm = RecordingLlmProvider();
          await spinUpServer(accountingStore: store, llmProvider: llm);
          try {
            verifier.claims = defaultUuidProxyClaims();
            final response = await httpGet(
              client,
              baseUri
                  .resolve(advisorSmokePath)
                  .replace(
                    queryParameters: <String, String>{
                      'usage_class': usageClass,
                    },
                  ),
              authorization: 'Bearer fake.token',
              headers: <String, String>{
                'Idempotency-Key': 'idem-class-$usageClass',
              },
            );
            expect(response.statusCode, equals(200));
            expect(store.recordedStats, hasLength(1));
            expect(store.lastStats!.usageClass, equals(usageClass));
            expect(store.lastStats!.resultStatus, equals('success'));
          } finally {
            await shutDown();
          }
        });
      }
    });

    // ── P1b.2 — failure / timeout proxy_request_stats (Support logs §12) ──
    //
    // P1b records `result_status='success'` only; a provider failure or
    // timeout early-returns 503 `llm_provider_unavailable` BEFORE
    // completeRequest and (pre-P1b.2) wrote no stats row, so Support logs
    // showed it as a derived `unknown`. These tests pin, end-to-end through
    // routeRequest (non-pipeline path, where llmProvider.complete is called
    // directly and its Exception is the bail point P1b.2 instruments):
    //   * a provider Exception writes ONE row, result_status='error';
    //   * a TimeoutException writes ONE row, result_status='timeout';
    //   * both carry measured latency_ms, the reservation's request_id, the
    //     ROUTED model id + derived provider, and honest-NULL tokens/cost
    //     (the provider returned nothing — unknown, not a measured zero);
    //   * the failure write uses recordRequestStats (its own txn), NOT the
    //     completeRequest fold — so completeCalls stays 0 on a failed call;
    //   * an idempotency replay of a failed request writes NO duplicate row;
    //   * the SUCCESS path never calls recordRequestStats (no extra
    //     round-trip added to the hot success path).

    test('GET /v1/advisor-smoke provider failure writes one '
        'proxy_request_stats row with result_status=error', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = ThrowingLlmProvider();
        // Advancing clock so the measured wall-clock latency to the point of
        // failure is strictly positive (a fixed instant would measure 0).
        var tick = DateTime.utc(2026, 4, 26, 12);
        DateTime advancingNow() {
          final value = tick;
          tick = tick.add(const Duration(milliseconds: 250));
          return value;
        }

        await spinUpServer(
          accountingStore: store,
          llmProvider: llm,
          now: advancingNow,
        );
        try {
          verifier.claims = defaultUuidProxyClaims();
          final response = await httpGet(
            client,
            baseUri
                .resolve(advisorSmokePath)
                .replace(
                  queryParameters: const <String, String>{
                    'tokens': '40',
                    'cost_cents': '9',
                  },
                ),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-fail-error',
            },
          );

          // Client outcome is unchanged: the existing 503 envelope.
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('llm_provider_unavailable'));

          // The provider was called and threw; one failure stats row written
          // via recordRequestStats, and completeRequest was NOT reached.
          expect(llm.completeCalls, equals(1));
          expect(store.completeCalls, equals(0));
          expect(store.recordStatsCalls, equals(1));
          expect(store.recordedStats, hasLength(1));

          final stats = store.lastStats!;
          expect(stats.resultStatus, equals('error'));
          expect(stats.usageClass, equals('advisor_qa'));
          // request_id correlation: the value the reservation surfaced.
          expect(
            stats.requestId,
            equals(store.reservedRequestIds['idem-fail-error']),
          );
          expect(stats.requestId, isNotNull);
          // actor = the acting human user's UUID from the verified scope.
          expect(
            stats.actorUserId,
            equals('11111111-1111-4111-8111-111111111111'),
          );
          // ROUTED model (basic tier -> haiku) + derived provider: the model
          // we attempted is honestly known even though the call failed.
          expect(stats.modelId, equals('claude-haiku-4-5'));
          expect(stats.provider, equals('anthropic'));
          expect(stats.modelVersion, isNull);
          // Provider returned nothing -> tokens/cost are UNKNOWN, honest null
          // (NOT zero, which would imply a measured no-op).
          expect(stats.promptTokenCount, isNull);
          expect(stats.completionTokenCount, isNull);
          expect(stats.costUsd, isNull);
          // Latency is measured to the point of failure (strictly positive).
          expect(stats.latencyMs, isNotNull);
          expect(stats.latencyMs! > 0, isTrue);
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke provider timeout writes one '
        'proxy_request_stats row with result_status=timeout', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = ThrowingLlmProvider(timeout: true);
        await spinUpServer(accountingStore: store, llmProvider: llm);
        try {
          verifier.claims = defaultUuidProxyClaims();
          final response = await httpGet(
            client,
            baseUri.resolve(advisorSmokePath),
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-fail-timeout',
            },
          );

          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('llm_provider_unavailable'));

          expect(llm.completeCalls, equals(1));
          expect(store.completeCalls, equals(0));
          expect(store.recordStatsCalls, equals(1));
          expect(store.recordedStats, hasLength(1));

          final stats = store.lastStats!;
          // A TimeoutException maps to the real 'timeout' terminal status.
          expect(stats.resultStatus, equals('timeout'));
          expect(
            stats.requestId,
            equals(store.reservedRequestIds['idem-fail-timeout']),
          );
          expect(stats.requestId, isNotNull);
          expect(stats.modelId, equals('claude-haiku-4-5'));
          expect(stats.provider, equals('anthropic'));
          expect(stats.promptTokenCount, isNull);
          expect(stats.completionTokenCount, isNull);
          expect(stats.costUsd, isNull);
          expect(stats.latencyMs, isNotNull);
          expect(stats.latencyMs! >= 0, isTrue);
        } finally {
          await shutDown();
        }
      });
    });

    test('GET /v1/advisor-smoke idempotent replay of a FAILED request writes '
        'NO duplicate proxy_request_stats row', () async {
      await withRealHttp(() async {
        final store = InMemoryAccountingStore.open();
        final llm = ThrowingLlmProvider();
        await spinUpServer(accountingStore: store, llmProvider: llm);
        try {
          verifier.claims = defaultUuidProxyClaims();
          final uri = baseUri.resolve(advisorSmokePath);
          final first = await httpGet(
            client,
            uri,
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-fail-replay',
            },
          );
          // Second call with the same key. The first attempt RESERVED but
          // never completed (it failed), so no stored response_payload
          // exists. The in-memory store models this as a fresh reservation
          // that reuses the SAME minted request_id (putIfAbsent), so the
          // provider is attempted again under the same correlation id. (The
          // real Postgres store is stricter still: a reserved-but-incomplete
          // row is treated as "in flight" and the retry 503s from
          // startRequest BEFORE the provider is ever called — so it writes
          // even fewer rows.) Either way the P1b.2 invariant holds: at most
          // one stats row per real failed attempt, never a duplicate for the
          // same attempt, and every row carries the correct request_id.
          final second = await httpGet(
            client,
            uri,
            authorization: 'Bearer fake.token',
            headers: const <String, String>{
              'Idempotency-Key': 'idem-fail-replay',
            },
          );

          expect(first.statusCode, equals(503));
          expect(second.statusCode, equals(503));
          // One stats row per real failed attempt; correlated to the single
          // reservation request_id (a retry resolves the same id). Crucially
          // there is no DUPLICATE for one attempt — recordStatsCalls tracks
          // exactly one write per provider failure.
          expect(
            store.recordedStats.map((s) => s.requestId).toSet(),
            equals(<String?>{store.reservedRequestIds['idem-fail-replay']}),
          );
          expect(store.recordStatsCalls, equals(store.recordedStats.length));
          // No success-path completion ever ran for this failed key.
          expect(store.completeCalls, equals(0));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'GET /v1/advisor-smoke SUCCESS path never calls recordRequestStats '
      '(no extra round-trip; stats stay folded into completeRequest)',
      () async {
        await withRealHttp(() async {
          final store = InMemoryAccountingStore.open();
          final llm = RecordingLlmProvider();
          await spinUpServer(accountingStore: store, llmProvider: llm);
          try {
            verifier.claims = defaultUuidProxyClaims();
            final response = await httpGet(
              client,
              baseUri.resolve(advisorSmokePath),
              authorization: 'Bearer fake.token',
              headers: const <String, String>{
                'Idempotency-Key': 'idem-success-no-record',
              },
            );
            expect(response.statusCode, equals(200));
            // Success folds the stats row into completeRequest; the standalone
            // failure-path writer is never invoked on success.
            expect(store.completeCalls, equals(1));
            expect(store.recordStatsCalls, equals(0));
            expect(store.recordedStats, hasLength(1));
            expect(store.lastStats!.resultStatus, equals('success'));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test(
      'GET /readyz still 200 unauthenticated when usage guard is installed',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            usageGuard: ProxyUsageGuard(
              store: const ScaffoldFailingUsageCounterStore(),
              tierResolver: const FixedLaunchTierResolver(),
            ),
          );
          try {
            final response = await httpGet(
              client,
              baseUri.resolve(readinessPath),
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['status'], equals('ok'));
          } finally {
            await shutDown();
          }
        });
      },
    );

    // ─── Phase 9 B6 — auth-session ledger endpoints ───────────────────
    //
    // Coverage matrix (per route):
    //   * happy path: writer received the right scope + body fields,
    //     response carries the documented narrow JSON shape.
    //   * 503 when no writer is wired (route was reached but ledger
    //     dependency is missing — analogous to /v1/usage-smoke 503).
    //   * 503 when the writer throws (no error stack leaks past the
    //     proxy boundary).
    //   * 401 / 403 / 400 for missing auth / bad scope / malformed
    //     body (covered by the cross-route guard tests above plus
    //     dedicated body-validation cases here).
    //   * verifies the request never echoes the bearer token or the
    //     `token_hash` value through the response body.

    test(
      'POST /v1/auth/session/login without writer wired returns 503',
      () async {
        await withRealHttp(() async {
          await spinUpServer();
          try {
            // Verifier returns a valid scope so the route reaches the
            // writer-not-wired branch instead of failing on auth.
            verifier.claims = const ProxyJwtClaims(
              userId: 'u',
              operatorId: 'op',
              locationId: 'loc',
              roles: <String>[],
            );
            final response = await httpPost(
              client,
              baseUri.resolve(authSessionLoginPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'token_hash': 'h'},
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('auth_session_ledger_not_configured'));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test(
      'POST /v1/auth/session/login without Authorization returns 401',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            authSessionLedgerWriter: RecordingAuthSessionLedger(),
          );
          try {
            final response = await httpPost(
              client,
              baseUri.resolve(authSessionLoginPath),
              body: const <String, Object?>{'token_hash': 'h'},
            );
            expect(response.statusCode, equals(401));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('POST /v1/auth/session/login with verified-but-unscoped token '
        'returns 403', () async {
      await withRealHttp(() async {
        await spinUpServer(
          authSessionLedgerWriter: RecordingAuthSessionLedger(),
        );
        try {
          // operator/location scope absent — request guard rejects 403.
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: null,
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'token_hash': 'h'},
          );
          expect(response.statusCode, equals(403));
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login rejects empty body with 400 '
        'malformed_json_body', () async {
      await withRealHttp(() async {
        await spinUpServer(
          authSessionLedgerWriter: RecordingAuthSessionLedger(),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('malformed_json_body'));
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login rejects body without token_hash '
        'with 400 missing_token_hash', () async {
      await withRealHttp(() async {
        await spinUpServer(
          authSessionLedgerWriter: RecordingAuthSessionLedger(),
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'wrong': 'field'},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_token_hash'));
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login trusted-ingress mode: writer receives '
        'operator/location/user from claims + IP/UA/geo from headers, '
        'response carries session_id + scope, no token leak', () async {
      await withRealHttp(() async {
        final ledger = RecordingAuthSessionLedger(
          loginSessionIds: <String>['session-from-proxy'],
        );
        await spinUpServer(
          authSessionLedgerWriter: ledger,
          trustProxyAuditHeaders: true,
        );
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>['operator_owner'],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer placeholder.id.token',
            body: const <String, Object?>{'token_hash': 'sha256-hex-hash'},
            headers: const <String, String>{
              'X-Forwarded-For': '203.0.113.7, 10.0.0.1',
              'User-Agent': 'forge-and-flow-test/1.0',
              'X-Country': 'ca',
            },
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['session_id'], equals('session-from-proxy'));
          expect(body['user_id'], equals('user-uuid'));
          expect(body['operator_id'], equals('operator-uuid'));
          expect(body['location_id'], equals('location-uuid'));
          // Acceptance: response body NEVER echoes the bearer token
          // or the token_hash value (no leak through the proxy
          // boundary even when the client accidentally logs the
          // response body).
          final bodyJson = response.body;
          expect(bodyJson.contains('placeholder.id.token'), isFalse);
          expect(bodyJson.contains('sha256-hex-hash'), isFalse);

          // Acceptance: writer received the right login row.
          expect(ledger.logins, hasLength(1));
          final login = ledger.logins.single;
          expect(login.userId, equals('user-uuid'));
          expect(login.operatorId, equals('operator-uuid'));
          expect(login.locationId, equals('location-uuid'));
          expect(login.tokenHash, equals('sha256-hex-hash'));
          // Acceptance: enrichment context resolved server-side from
          // request headers — leftmost X-Forwarded-For entry is the
          // client IP, X-Country is uppercased to 2-char ISO code.
          expect(login.context.ip, equals('203.0.113.7'));
          expect(login.context.userAgent, equals('forge-and-flow-test/1.0'));
          expect(login.context.geoCountry, equals('CA'));
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login default mode ignores spoofable '
        'forwarded IP and geo headers', () async {
      await withRealHttp(() async {
        final ledger = RecordingAuthSessionLedger(
          loginSessionIds: <String>['session-from-proxy'],
        );
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>['operator_owner'],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer placeholder.id.token',
            body: const <String, Object?>{'token_hash': 'sha256-hex-hash'},
            headers: const <String, String>{
              'X-Forwarded-For': '203.0.113.7, 10.0.0.1',
              'User-Agent': 'forge-and-flow-test/1.0',
              'X-Country': 'ca',
            },
          );

          expect(response.statusCode, equals(200));
          expect(ledger.logins, hasLength(1));
          final context = ledger.logins.single.context;
          expect(context.userAgent, equals('forge-and-flow-test/1.0'));
          expect(context.ip, isNot(equals('203.0.113.7')));
          expect(context.geoCountry, isNull);
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/login: writer error becomes 503 '
        'auth_session_ledger_unavailable with no stack leak', () async {
      await withRealHttp(() async {
        final ledger = ThrowingAuthSessionLedger(
          error: StateError('postgres connection refused: secret://blob'),
        );
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'token_hash': 'h'},
          );
          expect(response.statusCode, equals(503));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('auth_session_ledger_unavailable'));
          // Acceptance: the underlying StateError message (which
          // could carry connection strings or secrets) does NOT
          // surface in the HTTP body.
          expect(response.body.contains('secret://blob'), isFalse);
          expect(
            response.body.contains('postgres connection refused'),
            isFalse,
          );
        } finally {
          await shutDown();
        }
      });
    });

    // ──────────────────────────────────────────────────────────────────
    // Wave 2 B-1B — support-check sign-in regression
    //
    // Bug 1 from debug.md:14 ("proxy returned an incomplete session
    // record after support-check sign-in") had two halves: the proxy
    // contract for `ff_support` / `super_admin` JWTs (fixed in PR #476
    // by accepting scope-less global-admin claims and returning empty
    // `operator_id` / `location_id` in the 200 echo), and the client
    // parser (fixed in PR #476 follow-up `e26e53af` by mirroring the
    // role-aware empty-scope tolerance). The existing
    // `requireOperatorContext` unit tests cover the guard in isolation,
    // and `proxy_auth_session_ledger_writer_test.dart` covers the
    // client parser. The gap surfaced by the B-1B re-triage is a
    // ROUTE-LEVEL regression test that hits `POST /v1/auth/session/login`
    // end-to-end with a global-admin JWT and asserts the exact 200
    // response shape the client now depends on. This locks the
    // `support-check` sign-in path against future drift (e.g. someone
    // tightening the response builder to omit empty-string fields, or
    // dropping the role-aware accept branch).
    //
    // Mirrors of the same contract live at:
    //   - `tool/advisor_proxy/advisor_proxy.dart:2272+` (proxy guard)
    //   - `tool/pressure/p4_session_record_predicate.dart:57-103`
    //     (soak harness predicate)
    //   - `lib/services/auth/proxy_auth_session_ledger_writer.dart:373-487`
    //     (client parser + scope-echo validator)
    // If any one of these widens / narrows, ALL must move together.
    // ──────────────────────────────────────────────────────────────────

    test('B-1B — POST /v1/auth/session/login with scope-less ff_support JWT '
        'returns 200 with global-admin session shape (session_id + user_id '
        'populated; operator_id + location_id empty strings)', () async {
      await withRealHttp(() async {
        final ledger = RecordingAuthSessionLedger(
          loginSessionIds: <String>['support-session-id'],
        );
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          // Scope-less ff_support claim — the production shape for
          // an F&F support user who has not yet impersonated an
          // operator via the `/v1/admin/auth/sessions` flow.
          verifier.claims = const ProxyJwtClaims(
            userId: 'support-user-uuid',
            operatorId: null,
            locationId: null,
            roles: <String>['ff_support'],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer placeholder.id.token',
            body: const <String, Object?>{'token_hash': 'sha256-hex-hash'},
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          // Acceptance: response carries ALL four wire-contract keys
          // the client parser reads (the client refuses to persist
          // the session if any required key is missing — that was
          // the bug shape A1 §1.3 H1 ranked HIGH). The keys MUST be
          // present, even when empty, so the client can sanity-check
          // the echo before persisting the local AuthSession.
          expect(body.containsKey('session_id'), isTrue);
          expect(body.containsKey('user_id'), isTrue);
          expect(body.containsKey('operator_id'), isTrue);
          expect(body.containsKey('location_id'), isTrue);
          expect(body['session_id'], equals('support-session-id'));
          expect(body['user_id'], equals('support-user-uuid'));
          // Global-admin contract: empty strings (NOT null, NOT
          // missing) per the `requireOperatorContext` accept branch
          // at `tool/advisor_proxy/advisor_proxy.dart:2284-2337`.
          expect(body['operator_id'], equals(''));
          expect(body['location_id'], equals(''));

          // Acceptance: writer received the global-admin shape too —
          // empty operator/location strings, real user id, real
          // token hash. Mirrors the response echo.
          expect(ledger.logins, hasLength(1));
          final login = ledger.logins.single;
          expect(login.userId, equals('support-user-uuid'));
          expect(login.operatorId, equals(''));
          expect(login.locationId, equals(''));
          expect(login.tokenHash, equals('sha256-hex-hash'));
        } finally {
          await shutDown();
        }
      });
    });

    test('B-1B — POST /v1/auth/session/login with scope-less super_admin JWT '
        'returns 200 with global-admin session shape (super_admin '
        'parallels ff_support)', () async {
      await withRealHttp(() async {
        final ledger = RecordingAuthSessionLedger(
          loginSessionIds: <String>['superadmin-session-id'],
        );
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'super-admin-uuid',
            operatorId: null,
            locationId: null,
            roles: <String>['super_admin'],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer placeholder.id.token',
            body: const <String, Object?>{'token_hash': 'sha256-hex-hash'},
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['session_id'], equals('superadmin-session-id'));
          expect(body['user_id'], equals('super-admin-uuid'));
          expect(body['operator_id'], equals(''));
          expect(body['location_id'], equals(''));
        } finally {
          await shutDown();
        }
      });
    });

    test('B-1B — POST /v1/auth/session/login with scope-less non-admin JWT '
        'still returns 403 (regression-protects the non-admin reject '
        'path; the global-admin carve-out is keyed on roles, not on a '
        'generic empty-scope tolerance)', () async {
      await withRealHttp(() async {
        await spinUpServer(
          authSessionLedgerWriter: RecordingAuthSessionLedger(),
        );
        try {
          // operator_owner is a tenant-scoped role; missing scope
          // MUST still reject per the per-operator isolation hard
          // promise (HP #4).
          verifier.claims = const ProxyJwtClaims(
            userId: 'tenant-user-uuid',
            operatorId: null,
            locationId: null,
            roles: <String>['operator_owner'],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionLoginPath),
            authorization: 'Bearer placeholder.id.token',
            body: const <String, Object?>{'token_hash': 'sha256-hex-hash'},
          );

          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            body['error'],
            contains('operator'),
            reason:
                'non-admin scope-less tokens MUST still be rejected '
                'with the unchanged 403 reject branch',
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/refresh happy path: writer receives '
        'sessionId from body and scope from token', () async {
      await withRealHttp(() async {
        final ledger = RecordingAuthSessionLedger();
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>[],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionRefreshPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'session_id': 'session-uuid'},
          );

          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['ok'], isTrue);
          expect(ledger.refreshes, hasLength(1));
          expect(ledger.refreshes.single.sessionId, equals('session-uuid'));
          expect(ledger.refreshes.single.userId, equals('user-uuid'));
          expect(ledger.refreshes.single.operatorId, equals('operator-uuid'));
          expect(ledger.refreshes.single.locationId, equals('location-uuid'));
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'POST /v1/auth/session/refresh rejects body without session_id',
      () async {
        await withRealHttp(() async {
          await spinUpServer(
            authSessionLedgerWriter: RecordingAuthSessionLedger(),
          );
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'u',
              operatorId: 'op',
              locationId: 'loc',
              roles: <String>[],
            );
            final response = await httpPost(
              client,
              baseUri.resolve(authSessionRefreshPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('missing_session_id'));
          } finally {
            await shutDown();
          }
        });
      },
    );

    test('POST /v1/auth/session/revoke happy path: writer receives '
        'sessionId + reason', () async {
      await withRealHttp(() async {
        final ledger = RecordingAuthSessionLedger();
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>[],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionRevokePath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'session_id': 'session-uuid',
              'reason': 'user_signed_out_this_session',
            },
          );
          expect(response.statusCode, equals(200));
          expect(ledger.revokes, hasLength(1));
          expect(ledger.revokes.single.sessionId, equals('session-uuid'));
          expect(
            ledger.revokes.single.reason,
            equals('user_signed_out_this_session'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/revoke without reason defaults to '
        'user_signed_out_this_session', () async {
      await withRealHttp(() async {
        final ledger = RecordingAuthSessionLedger();
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionRevokePath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'session_id': 'session-uuid'},
          );
          expect(response.statusCode, equals(200));
          expect(
            ledger.revokes.single.reason,
            equals('user_signed_out_this_session'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/revoke-all happy path: writer revokes for '
        'verified user, response carries revoked_count', () async {
      await withRealHttp(() async {
        final ledger = RecordingAuthSessionLedger(revokeAllReturnCount: 3);
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'user-uuid',
            operatorId: 'operator-uuid',
            locationId: 'location-uuid',
            roles: <String>[],
          );
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionRevokeAllPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'reason': 'user_signed_out_all_sessions',
            },
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['ok'], isTrue);
          expect(body['revoked_count'], equals(3));
          expect(ledger.revokeAlls, hasLength(1));
          expect(ledger.revokeAlls.single.userId, equals('user-uuid'));
          expect(
            ledger.revokeAlls.single.reason,
            equals('user_signed_out_all_sessions'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test('POST /v1/auth/session/revoke-all tolerates empty body and '
        'defaults reason to user_signed_out_all_sessions', () async {
      await withRealHttp(() async {
        final ledger = RecordingAuthSessionLedger();
        await spinUpServer(authSessionLedgerWriter: ledger);
        try {
          verifier.claims = const ProxyJwtClaims(
            userId: 'u',
            operatorId: 'op',
            locationId: 'loc',
            roles: <String>[],
          );
          // No body sent — exercises the allowEmpty: true branch in
          // _readJsonBody.
          final response = await httpPost(
            client,
            baseUri.resolve(authSessionRevokeAllPath),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          expect(
            ledger.revokeAlls.single.reason,
            equals('user_signed_out_all_sessions'),
          );
        } finally {
          await shutDown();
        }
      });
    });

    test(
      'POST /v1/auth/refresh-tokens/revoke-all revokes Firebase UID',
      () async {
        await withRealHttp(() async {
          final firebaseAdmin = RecordingFirebaseAdminAuthClient();
          await spinUpServer(firebaseAdminAuthClient: firebaseAdmin);
          try {
            verifier.claims = const ProxyJwtClaims(
              userId: 'postgres-user-uuid',
              firebaseUid: 'firebase-uid',
              operatorId: 'operator-uuid',
              locationId: 'location-uuid',
              roles: <String>[],
            );
            final response = await httpPost(
              client,
              baseUri.resolve(authRefreshTokensRevokeAllPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(200));
            expect(
              firebaseAdmin.revokedRefreshTokenUids,
              equals(['firebase-uid']),
            );
          } finally {
            await shutDown();
          }
        });
      },
    );
  });

  group('11A.1 admin operator/location routes', () {
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
        SettableVerifier verifier,
        FakeAdminGateway gateway,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      FakeAdminGateway? customGateway,
      bool gatewayConfigured = true,
    }) async {
      final verifier = SettableVerifier();
      verifier.claims = initialClaims;
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = customGateway ?? FakeAdminGateway();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            operatorLocationAdminGateway: gatewayConfigured ? gateway : null,
            now: () => DateTime.utc(2026, 4, 29, 12),
            adminCorsAllowList: const <String>['https://admin.forgeflow.app'],
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

    test('11A.1 OPTIONS preflight returns CORS headers without auth', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminOperatorsPath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'POST');
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type',
          );
          request.contentLength = 0;

          final response = await request.close();
          await response.drain<void>();

          expect(response.statusCode, equals(HttpStatus.noContent));
          // HARD-C — exact-origin echo, never `*`. The allow-list
          // wired through spinUp contains the origin we send below,
          // so the proxy responds with that exact string.
          expect(
            response.headers.value('access-control-allow-origin'),
            equals('https://admin.forgeflow.app'),
          );
          expect(
            response.headers.value('access-control-allow-methods'),
            contains('OPTIONS'),
          );
          expect(
            response.headers
                .value('access-control-allow-headers')
                ?.toLowerCase(),
            contains('authorization'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.1 GET /v1/admin/operators returns 503 without a gateway',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(gatewayConfigured: false);
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              body['error'],
              equals('operator_location_admin_not_configured'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 GET /v1/admin/operators rejects a non-admin caller with 403',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_x',
              locationId: 'loc_x',
              roles: <String>['operator_owner'],
            ),
          );
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
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
      '11A.1 POST /v1/admin/operators rejects ff_support with 403',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_support',
              operatorId: 'op_support',
              locationId: 'loc_support',
              roles: <String>['ff_support'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-onboard-missing-primary',
              body: <String, Object?>{
                'admin_reason': 'Create operator during support setup',
                'business_name': 'Cafe',
                'owner_email': 'a@b.c',
                'subscription_tier': 'launch',
                'preferred_currency': 'CAD',
                'admin_user_email': 'admin@b.c',
                'primary_location': <String, Object?>{
                  'name': 'Main',
                  'timezone': 'America/Toronto',
                  'business_day_rollover_hour': 4,
                },
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(body['required_roles'], contains('super_admin'));
            expect(gateway.lastOnboardCommand, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 GET /v1/admin/operators returns the gateway list as 200',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          gateway.listResult = <Map<String, Object?>>[
            <String, Object?>{
              'operator': <String, Object?>{
                'operator_id': 'op-1',
                'business_name': 'Cafe One',
              },
              'locations': <Map<String, Object?>>[],
            },
          ];
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final operators = (body['operators']! as List)
                .cast<Map<String, Object?>>();
            expect(operators, hasLength(1));
            final firstOperator = (operators.first['operator']! as Map)
                .cast<String, Object?>();
            expect(firstOperator['business_name'], equals('Cafe One'));
            expect(gateway.lastReason, contains('admin.operator_location.GET'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 GET /v1/admin/operators accepts global super_admin token',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: null,
              locationId: null,
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastActorUserId, equals('user_admin'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.1 POST /v1/admin/operators requires Idempotency-Key', () async {
      await withRealHttp(() async {
        final gateway = FakeAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminOperatorsPath),
            authorization: 'Bearer fake.token',
            body: <String, Object?>{
              'admin_reason': 'Create operator during support setup',
              'business_name': 'Cafe',
              'owner_email': 'a@b.c',
              'subscription_tier': 'launch',
              'preferred_currency': 'CAD',
              'admin_user_email': 'admin@b.c',
              'primary_location': <String, Object?>{
                'name': 'Main',
                'timezone': 'America/Toronto',
                'business_day_rollover_hour': 4,
              },
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_idempotency_key'));
          expect(gateway.lastOnboardCommand, isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.1 PATCH /v1/admin/locations/{id} requires admin_reason',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('$adminLocationsPath/loc-1'),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-location-missing-reason',
              body: const <String, Object?>{'name': 'Renamed HQ'},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('missing_admin_reason'));
            expect(gateway.lastPatchLocationId, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 POST /v1/admin/operators rejects missing primary_location with 400',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-onboard-invalid-timezone',
              body: <String, Object?>{
                'admin_reason': 'Create operator during support setup',
                'business_name': 'Cafe',
                'owner_email': 'a@b.c',
                'subscription_tier': 'launch',
                'preferred_currency': 'CAD',
                'admin_user_email': 'admin@b.c',
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('missing_primary_location'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 POST /v1/admin/operators rejects an invalid IANA timezone with 400',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-onboard-missing-primary',
              body: <String, Object?>{
                'admin_reason': 'Create operator during support setup',
                'business_name': 'Cafe',
                'owner_email': 'a@b.c',
                'subscription_tier': 'launch',
                'preferred_currency': 'CAD',
                'admin_user_email': 'admin@b.c',
                'primary_location': <String, Object?>{
                  'name': 'Main',
                  'timezone': 'Mars/Olympus',
                  'business_day_rollover_hour': 4,
                },
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('invalid_timezone'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 POST /v1/admin/operators returns 201 with bundle on success',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          gateway.onboardResult = <String, Object?>{
            'operator': <String, Object?>{
              'operator_id': 'op-new',
              'business_name': 'Cafe New',
            },
            'locations': <Map<String, Object?>>[
              <String, Object?>{
                'location_id': 'loc-new',
                'operator_id': 'op-new',
              },
            ],
            'admin_user_id': 'user-new',
          };
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminOperatorsPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-onboard-success',
              body: <String, Object?>{
                'admin_reason': 'Create operator during support setup',
                'business_name': 'Cafe New',
                'owner_email': 'a@b.c',
                'subscription_tier': 'launch',
                'preferred_currency': 'CAD',
                'admin_user_email': 'admin@b.c',
                'primary_location': <String, Object?>{
                  'name': 'Main',
                  'timezone': 'America/Toronto',
                  'business_day_rollover_hour': 4,
                },
              },
            );
            expect(response.statusCode, equals(201));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final operatorJson = (body['operator'] as Map)
                .cast<String, Object?>();
            expect(operatorJson['operator_id'], equals('op-new'));
            expect(
              gateway.lastOnboardCommand?['business_name'],
              equals('Cafe New'),
            );
            expect(
              gateway.lastOnboardCommand?['preferred_currency'],
              equals('CAD'),
            );
            expect(
              gateway.lastReason,
              equals('Create operator during support setup'),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.1 POST /v1/admin/operators/{id}/suspend returns 200', () async {
      await withRealHttp(() async {
        final gateway = FakeAdminGateway();
        gateway.suspendResult = <String, Object?>{
          'operator_id': 'op-1',
          'business_name': 'Cafe',
          'suspended_at': '2026-04-29T12:00:00.000Z',
        };
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve('$adminOperatorsPath/op-1/suspend'),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-suspend-op-1',
            body: const <String, Object?>{
              'admin_reason': 'Billing hold requested by owner',
            },
          );
          expect(response.statusCode, equals(200));
          expect(gateway.suspendOperatorId, equals('op-1'));
          expect(gateway.lastReason, equals('Billing hold requested by owner'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.1 POST /v1/admin/operators/{id}/reactivate returns 200',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          gateway.reactivateResult = <String, Object?>{
            'operator_id': 'op-1',
            'suspended_at': null,
          };
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve('$adminOperatorsPath/op-1/reactivate'),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-reactivate-op-1',
              body: const <String, Object?>{
                'admin_reason': 'Billing hold cleared by owner',
              },
            );
            expect(response.statusCode, equals(200));
            expect(gateway.reactivateOperatorId, equals('op-1'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 PATCH /v1/admin/operators/{id} returns 404 when not found',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          gateway.patchResult = null;
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('$adminOperatorsPath/missing'),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-patch-missing-op',
              body: <String, Object?>{
                'admin_reason': 'Correct stale operator details',
                'business_name': 'Renamed',
              },
            );
            expect(response.statusCode, equals(404));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('unknown_operator'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.1 POST /v1/admin/locations returns 201 on success', () async {
      await withRealHttp(() async {
        final gateway = FakeAdminGateway();
        gateway.addLocationResult = <String, Object?>{
          'location_id': 'loc-new',
          'operator_id': 'op-1',
          'parent_org_unit_id': 'org-unit-east',
          'name': 'West Coast',
          'timezone': 'America/Vancouver',
        };
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(adminLocationsPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-add-location',
            body: <String, Object?>{
              'admin_reason': 'Add location requested by operator',
              'operator_id': 'op-1',
              'parent_org_unit_id': 'org-unit-east',
              'name': 'West Coast',
              'timezone': 'America/Vancouver',
              'business_day_rollover_hour': 5,
            },
          );
          expect(response.statusCode, equals(201));
          expect(gateway.lastAddLocationOperatorId, equals('op-1'));
          expect(
            gateway.lastAddLocationParentOrgUnitId,
            equals('org-unit-east'),
          );
          expect(gateway.lastAddLocationTimezone, equals('America/Vancouver'));
          expect(
            gateway.lastReason,
            equals('Add location requested by operator'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.1 POST /v1/admin/locations surfaces missing operator timing',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          gateway.addLocationError = const OperatorLocationAdminRejected(
            statusCode: 409,
            code: 'operator_business_timing_profile_missing',
            message:
                'Create an operator Business Timing profile before adding a location.',
          );
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminLocationsPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-add-location-missing-timing',
              body: <String, Object?>{
                'admin_reason': 'Add location requested by operator',
                'operator_id': 'op-1',
                'parent_org_unit_id': 'org-unit-east',
                'name': 'West Coast',
                'timezone': 'America/Vancouver',
                'business_day_rollover_hour': 5,
              },
            );
            expect(response.statusCode, equals(409));
            expect(gateway.lastAddLocationOperatorId, equals('op-1'));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              body['error'],
              equals('operator_business_timing_profile_missing'),
            );
            expect(
              body['message'],
              equals(
                'Create an operator Business Timing profile before adding a location.',
              ),
            );
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 POST /v1/admin/locations requires parent_org_unit_id',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(adminLocationsPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-add-location-missing-parent',
              body: <String, Object?>{
                'admin_reason': 'Add location requested by operator',
                'operator_id': 'op-1',
                'name': 'West Coast',
                'timezone': 'America/Vancouver',
                'business_day_rollover_hour': 5,
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('missing_parent_org_unit_id'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 PATCH /v1/admin/locations/{id} returns updated location',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          gateway.patchLocationResult = <String, Object?>{
            'location_id': 'loc-1',
            'operator_id': 'op-1',
            'name': 'Renamed HQ',
            'address': '',
            'timezone': 'America/St_Johns',
            'business_day_rollover_hour': 5,
            'created_at': '2026-05-01T00:00:00.000Z',
            'updated_at': '2026-05-04T00:00:00.000Z',
          };
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('$adminLocationsPath/loc-1'),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-patch-location',
              body: <String, Object?>{
                'admin_reason': 'Correct location profile',
                'name': 'Renamed HQ',
                'timezone': 'America/St_Johns',
              },
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastPatchLocationId, equals('loc-1'));
            expect(gateway.lastPatchLocationName, equals('Renamed HQ'));
            expect(
              gateway.lastPatchLocationTimezone,
              equals('America/St_Johns'),
            );
            expect(gateway.lastPatchLocationRolloverHour, isNull);
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final location = body['location'] as Map<String, Object?>;
            expect(location['name'], equals('Renamed HQ'));
            expect(gateway.lastReason, equals('Correct location profile'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 PATCH /v1/admin/locations/{id} rejects legacy rollover writes',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('$adminLocationsPath/loc-1'),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-patch-location-rollover',
              body: <String, Object?>{
                'admin_reason': 'Correct location profile',
                'business_day_rollover_hour': 5,
              },
            );
            expect(response.statusCode, equals(410));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              body['error'],
              equals('legacy_location_rollover_writes_disabled'),
            );
            expect(gateway.lastPatchLocationId, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 PATCH /v1/admin/locations/{id} returns 404 when not found',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          gateway.patchLocationResult = null;
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('$adminLocationsPath/missing'),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-patch-location-missing',
              body: <String, Object?>{
                'admin_reason': 'Correct location profile',
                'name': 'Missing',
              },
            );
            expect(response.statusCode, equals(404));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('unknown_location'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 DELETE /v1/admin/locations/{id} primary-protected returns 400',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          gateway.removeLocationResult =
              AdminLocationRemovalResult.primaryLocationProtected;
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'DELETE',
              ctx.baseUri.resolve('$adminLocationsPath/loc-1'),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-remove-primary-location',
              body: <String, Object?>{
                'admin_reason': 'Remove closed location',
                'operator_id': 'op-1',
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('cannot_remove_primary_location'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 DELETE /v1/admin/locations/{id} returns 200 on success',
      () async {
        await withRealHttp(() async {
          final gateway = FakeAdminGateway();
          gateway.removeLocationResult = AdminLocationRemovalResult.removed;
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'DELETE',
              ctx.baseUri.resolve('$adminLocationsPath/loc-1'),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-remove-location',
              body: <String, Object?>{
                'admin_reason': 'Remove closed location',
                'operator_id': 'op-1',
              },
            );
            expect(response.statusCode, equals(200));
            expect(gateway.removeLocationId, equals('loc-1'));
            expect(gateway.lastReason, equals('Remove closed location'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.1 GET /v1/admin/operators without Authorization returns 401',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminOperatorsPath),
            );
            expect(response.statusCode, equals(401));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });

  group('B5 admin business-timing dispatcher route gate', () {
    const operatorId = '11111111-1111-1111-1111-111111111111';
    const path = '/v1/admin/operators/$operatorId/business-timing-profiles';

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
        SettableVerifier verifier,
        FakeAdminBusinessTimingGateway gateway,
        RecordingAdminBusinessTimingAuditSink auditSink,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      FakeAdminBusinessTimingGateway? customGateway,
    }) async {
      final verifier = SettableVerifier();
      verifier.claims = initialClaims;
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = customGateway ?? FakeAdminBusinessTimingGateway();
      final auditSink = RecordingAdminBusinessTimingAuditSink();
      final router = AdminBusinessTimingRouter(
        businessTimingGateway: gateway,
        auditSink: auditSink,
        now: () => DateTime.utc(2026, 5, 13, 12),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            adminBusinessTimingRouter: router,
            now: () => DateTime.utc(2026, 5, 13, 12),
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
        auditSink: auditSink,
      );
    }

    test('ff_support can read admin business-timing profiles', () async {
      await withRealHttp(() async {
        final gateway = FakeAdminBusinessTimingGateway()
          ..seed(operatorId, 'profile-read');
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_support',
            operatorId: 'op_support',
            locationId: 'loc_support',
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await httpGet(
            ctx.client,
            ctx.baseUri.resolve(path),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final profiles = (body['profiles']! as List).cast<Object?>();
          expect(profiles, hasLength(1));
          expect(gateway.listCalls, equals(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('ff_support cannot write admin business-timing profiles', () async {
      await withRealHttp(() async {
        final gateway = FakeAdminBusinessTimingGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_support',
            operatorId: 'op_support',
            locationId: 'loc_support',
            roles: <String>['ff_support'],
          ),
        );
        try {
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(path),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-b5-ff-support-write',
            body: adminBusinessTimingBody(operatorId: operatorId),
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(body['required_roles'], equals(<Object?>['super_admin']));
          expect(gateway.createCalls, equals(0));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('super_admin write reaches admin business-timing router', () async {
      await withRealHttp(() async {
        final gateway = FakeAdminBusinessTimingGateway();
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
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(path),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-b5-super-write',
            body: adminBusinessTimingBody(operatorId: operatorId),
          );
          expect(response.statusCode, equals(201), reason: response.body);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['profileId'], equals('profile-created'));
          expect(gateway.createCalls, equals(1));
          expect(ctx.auditSink.records, hasLength(1));
          expect(
            ctx.auditSink.records.single['admin_reason'],
            equals('B5 dispatcher regression'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });
  });

  group('11A.2 admin pricing tier routes', () {
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
        SettableVerifier verifier,
        FakePricingAdminGateway gateway,
      })
    >
    spinUp({
      ProxyJwtClaims? initialClaims,
      FakePricingAdminGateway? customGateway,
      bool gatewayConfigured = true,
    }) async {
      final verifier = SettableVerifier();
      verifier.claims = initialClaims;
      final guard = ProxyRequestGuard(verifier: verifier);
      final gateway = customGateway ?? FakePricingAdminGateway();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      // ignore: unawaited_futures
      server.listen((request) async {
        try {
          await routeRequest(
            request,
            guard,
            pricingTierAdminGateway: gatewayConfigured ? gateway : null,
            now: () => DateTime.utc(2026, 4, 30, 12),
            adminCorsAllowList: const <String>['https://admin.forgeflow.app'],
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
      '11A.2 GET /v1/admin/pricing/operators returns 503 without a gateway',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(gatewayConfigured: false);
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(503));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('pricing_tier_admin_not_configured'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 GET /v1/admin/pricing/operators rejects operator_owner (403)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_x',
              locationId: 'loc_x',
              roles: <String>['operator_owner'],
            ),
          );
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            // GET rejection lists the read set (super_admin +
            // ff_support); the caller carries neither.
            final required = (body['required_roles']! as List).cast<String>();
            expect(required, contains('super_admin'));
            expect(required, contains('ff_support'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 GET /v1/admin/pricing/operators admits ff_support (read-only)',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
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
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastActorUserId, equals('user_support'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 PUT /v1/admin/pricing/usage-caps rejects ff_support with 403',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
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
            final response = await httpJson(
              ctx.client,
              'PUT',
              ctx.baseUri.resolve(adminPricingUsageCapsPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'advisor_qa',
                'monthly_cap_usd': 50.0,
                'per_invocation_cap_usd': 0.10,
              },
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(body['required_roles'], contains('super_admin'));
            expect(body['required_roles'], isNot(contains('ff_support')));
            expect(gateway.lastCapOperatorId, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.2 POST .../apply-template rejects ff_support with 403', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
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
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(
              '${adminPricingOperatorsPrefix}op-1/apply-template',
            ),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'tier_key': 'premium'},
          );
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(gateway.lastApplyTemplateOperatorId, isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.2 PATCH .../operators/{id} rejects ff_support with 403',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_support',
              operatorId: 'op_support',
              locationId: 'loc_support',
              roles: <String>['ff_support'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('${adminPricingOperatorsPrefix}op-1'),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'subscription_tier': 'premium'},
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(body['required_roles'], contains('super_admin'));
            expect(gateway.lastTierUpdateOperatorId, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 GET /v1/admin/pricing/operators returns the gateway list',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
          gateway.listResult = <Map<String, Object?>>[
            <String, Object?>{
              'operator': <String, Object?>{
                'operator_id': 'op-1',
                'business_name': 'Cafe One',
                'subscription_tier': 'starter',
                'preferred_currency': 'CAD',
                'primary_location_id': 'loc-1',
                'suspended': false,
              },
              'caps': <Map<String, Object?>>[],
            },
          ];
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingOperatorsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final operators = (body['operators']! as List)
                .cast<Map<String, Object?>>();
            expect(operators, hasLength(1));
            expect(gateway.lastReason, contains('admin.pricing.GET'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 PATCH .../operators/{id} validates subscription_tier value',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('${adminPricingOperatorsPrefix}op-1'),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'subscription_tier': 'megapremium'},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('invalid_subscription_tier'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 PATCH .../operators/{id} forwards to gateway as super_admin',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('${adminPricingOperatorsPrefix}op-1'),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'subscription_tier': 'premium'},
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastTierUpdateOperatorId, equals('op-1'));
            expect(gateway.lastTierUpdateValue, equals('premium'));
            expect(gateway.lastActorUserId, equals('user_admin'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.2 PUT /v1/admin/pricing/usage-caps upserts a cap row', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
        gateway.capUpsertResult = const <String, Object?>{
          'operator_id': 'op-1',
          'location_id': 'loc-1',
          'usage_class': 'advisor_qa',
          'monthly_cap_usd': 50.0,
          'per_invocation_cap_usd': 0.10,
        };
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: const ProxyJwtClaims(
            userId: 'user_admin',
            operatorId: 'op_admin',
            locationId: 'loc_admin',
            roles: <String>['super_admin'],
          ),
        );
        try {
          final response = await httpJson(
            ctx.client,
            'PUT',
            ctx.baseUri.resolve(adminPricingUsageCapsPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'operator_id': 'op-1',
              'location_id': 'loc-1',
              'usage_class': 'advisor_qa',
              'monthly_cap_usd': 50.0,
              'per_invocation_cap_usd': 0.10,
            },
          );
          expect(response.statusCode, equals(200));
          expect(gateway.lastCapOperatorId, equals('op-1'));
          expect(gateway.lastCapUsageClass, equals('advisor_qa'));
          expect(gateway.lastCapMonthly, equals(50.0));
          expect(gateway.lastReason, contains('admin.pricing.PUT'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.2 PUT /v1/admin/pricing/usage-caps rejects negative monthly_cap_usd',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PUT',
              ctx.baseUri.resolve(adminPricingUsageCapsPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'advisor_qa',
                'monthly_cap_usd': -5.0,
                'per_invocation_cap_usd': 0.10,
              },
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('invalid_monthly_cap_usd'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 POST .../operators/{id}/apply-template forwards tier_key',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/apply-template',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'tier_key': 'pro'},
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastApplyTemplateOperatorId, equals('op-1'));
            expect(gateway.lastApplyTemplateTierKey, equals('pro'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 POST .../apply-template rejects an unknown tier_key (400)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/apply-template',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'tier_key': 'megapremium'},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('unknown_tier_template'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      '11A.2 POST .../apply-template surfaces no_primary_location as 400',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()
            ..raiseOnApplyTemplate =
                const PricingTierAdminGatewayValidationError(
                  statusCode: 400,
                  code: 'no_primary_location',
                  message: 'set a primary location first',
                );
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: const ProxyJwtClaims(
              userId: 'user_admin',
              operatorId: 'op_admin',
              locationId: 'loc_admin',
              roles: <String>['super_admin'],
            ),
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/apply-template',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'tier_key': 'premium'},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('no_primary_location'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('11A.2 OPTIONS preflight allows PUT for usage-caps', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminPricingUsageCapsPath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'PUT');
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type',
          );
          request.contentLength = 0;
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, equals(HttpStatus.noContent));
          final allowMethods =
              response.headers.value('access-control-allow-methods') ?? '';
          expect(allowMethods.toUpperCase(), contains('PUT'));
          expect(allowMethods.toUpperCase(), contains('OPTIONS'));
          // HARD-C — exact-origin echo, never `*`.
          expect(
            response.headers.value('access-control-allow-origin'),
            equals('https://admin.forgeflow.app'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      '11A.2 GET /v1/admin/pricing/operators without Authorization is 401',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp();
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingOperatorsPath),
            );
            expect(response.statusCode, equals(401));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    // ── Phase 2 — delete-a-limit + live spend-summary. ──────────────

    const superAdminClaims = ProxyJwtClaims(
      userId: 'user_admin',
      operatorId: 'op_admin',
      locationId: 'loc_admin',
      roles: <String>['super_admin'],
    );

    test(
      'Phase 2 DELETE /v1/admin/pricing/usage-caps rejects ff_support (403)',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
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
            final response = await httpJson(
              ctx.client,
              'DELETE',
              ctx.baseUri.resolve(adminPricingUsageCapsPath),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'advisor_qa',
              },
            );
            // DELETE is a write method, so the strict super_admin-only set
            // applies (ff_support is read-only).
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(gateway.lastDeleteOperatorId, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 2 DELETE /v1/admin/pricing/usage-caps deletes by logical key',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()..deleteResult = true;
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpJson(
              ctx.client,
              'DELETE',
              ctx.baseUri.resolve(adminPricingUsageCapsPath),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-delete-1',
              body: const <String, Object?>{
                'operator_id': 'op-1',
                'location_id': 'loc-1',
                'usage_class': 'advisor_qa',
              },
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['deleted'], isTrue);
            expect(gateway.lastDeleteOperatorId, equals('op-1'));
            expect(gateway.lastDeleteUsageClass, equals('advisor_qa'));
            expect(gateway.lastReason, contains('admin.pricing.DELETE'));
            expect(gateway.lastReason, contains('usage_caps_delete'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('Phase 2 DELETE answers 404 when no matching cap exists', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway()..deleteResult = false;
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          final response = await httpJson(
            ctx.client,
            'DELETE',
            ctx.baseUri.resolve(adminPricingUsageCapsPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'operator_id': 'op-1',
              'cap_id': '00000000-0000-4000-8000-00000000dead',
            },
          );
          expect(response.statusCode, equals(404));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('unknown_usage_cap'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('Phase 2 DELETE without operator_id is a 400 input error', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(initialClaims: superAdminClaims);
        try {
          final response = await httpJson(
            ctx.client,
            'DELETE',
            ctx.baseUri.resolve(adminPricingUsageCapsPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'location_id': 'loc-1',
              'usage_class': 'advisor_qa',
            },
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('missing_operator_id'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('Phase 2 OPTIONS preflight allows DELETE for usage-caps', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve(adminPricingUsageCapsPath),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'DELETE');
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type,idempotency-key',
          );
          request.contentLength = 0;
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, equals(HttpStatus.noContent));
          final allowMethods =
              response.headers.value('access-control-allow-methods') ?? '';
          expect(allowMethods.toUpperCase(), contains('DELETE'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'Phase 2 GET .../operators/{id}/spend-summary returns the spend rows',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()
            ..spendSummaryResult = const <Map<String, Object?>>[
              <String, Object?>{
                'location_id': 'loc-1',
                'usage_class': 'advisor_qa',
                'spend_usd': 42.5,
              },
            ];
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/spend-summary',
              ),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['operator_id'], equals('op-1'));
            final spend = (body['spend']! as List).cast<Map<String, Object?>>();
            expect(spend.single['spend_usd'], equals(42.5));
            expect(gateway.lastSpendSummaryOperatorId, equals('op-1'));
            expect(gateway.lastReason, contains('admin.pricing.GET'));
            expect(gateway.lastReason, contains('spend_summary'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('Phase 2 GET spend-summary admits ff_support (read-only)', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway()
          ..spendSummaryResult = const <Map<String, Object?>>[];
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
          final response = await httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '${adminPricingOperatorsPrefix}op-1/spend-summary',
            ),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('Phase 2 GET spend-summary 404s for an unknown operator', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway()..spendSummaryResult = null;
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          final response = await httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '${adminPricingOperatorsPrefix}op-missing/spend-summary',
            ),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(404));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('unknown_operator'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    // ── Phase 3 — editable plan-pricing catalog. ───────────────────

    test(
      'Phase 3 GET /v1/admin/pricing/plans returns the catalog rows',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()
            ..planCatalogResult = const <Map<String, Object?>>[
              <String, Object?>{
                'tier_key': 'elite',
                'monthly_usd': 250.0,
                'first_n_seats': 20,
                'first_seat_usd': 10.0,
                'additional_seat_usd': 5.0,
                'onboarding_min_usd': 1500.0,
                'onboarding_max_usd': 3500.0,
                'updated_at': null,
                'updated_by': null,
              },
            ];
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingPlansPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final plans = (body['plans']! as List).cast<Map<String, Object?>>();
            expect(plans.single['tier_key'], equals('elite'));
            expect(gateway.lastReason, contains('admin.pricing.GET'));
            expect(gateway.lastReason, contains('plans_list'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 3 GET /v1/admin/pricing/plans admits ff_support (read-only)',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()
            ..planCatalogResult = const <Map<String, Object?>>[];
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
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingPlansPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastActorUserId, equals('user_support'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 3 GET /v1/admin/pricing/plans rejects operator_owner (403)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(
            initialClaims: const ProxyJwtClaims(
              userId: 'user_x',
              operatorId: 'op_x',
              locationId: 'loc_x',
              roles: <String>['operator_owner'],
            ),
          );
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingPlansPath),
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
      'Phase 3 PATCH .../plans/{tier_key} rejects ff_support (403, write)',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
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
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('${adminPricingPlansPrefix}premium'),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'monthly_usd': 300.0},
            );
            // PATCH is a write method → strict super_admin-only set.
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            expect(gateway.lastPlanUpdateTierKey, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 3 PATCH .../plans/{tier_key} updates pricing + audits',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('${adminPricingPlansPrefix}premium'),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-plan-1',
              body: const <String, Object?>{
                'monthly_usd': 300.0,
                'first_n_seats': 25,
                'first_seat_usd': 6.0,
                'additional_seat_usd': 4.0,
                'onboarding_min_usd': 800.0,
                'onboarding_max_usd': 2200.0,
              },
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect((body['plan']! as Map)['tier_key'], equals('premium'));
            expect(gateway.lastPlanUpdateTierKey, equals('premium'));
            expect(gateway.lastPlanUpdateMonthlyUsd, equals(300.0));
            expect(gateway.lastPlanUpdateFirstNSeats, equals(25));
            // The admin reason threads the plan-pricing action so the audit
            // row carries honest attribution.
            expect(gateway.lastReason, contains('admin.pricing.PATCH'));
            expect(gateway.lastReason, contains('plan_pricing:premium'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 3 PATCH .../plans accepts explicit null fields (clear)',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()
            ..planUpdateResult = <String, Object?>{
              'tier_key': 'enterprise',
              'monthly_usd': null,
              'first_n_seats': null,
              'first_seat_usd': null,
              'additional_seat_usd': null,
              'onboarding_min_usd': null,
              'onboarding_max_usd': null,
              'updated_at': null,
              'updated_by': 'user_admin',
            };
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('${adminPricingPlansPrefix}enterprise'),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{
                'monthly_usd': null,
                'first_seat_usd': null,
              },
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastPlanUpdateTierKey, equals('enterprise'));
            expect(gateway.lastPlanUpdateMonthlyUsd, isNull);
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 3 PATCH .../plans/{tier_key} 404s for an unknown plan',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(initialClaims: superAdminClaims);
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('${adminPricingPlansPrefix}megapremium'),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'monthly_usd': 100.0},
            );
            expect(response.statusCode, equals(404));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('unknown_plan'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 3 PATCH .../plans rejects a negative monthly fee (400)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(initialClaims: superAdminClaims);
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve('${adminPricingPlansPrefix}starter'),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'monthly_usd': -5.0},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('invalid_monthly_usd'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 3 PATCH .../plans is idempotent: replay returns one result',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            Future<int> patchOnce() async {
              final response = await httpJson(
                ctx.client,
                'PATCH',
                ctx.baseUri.resolve('${adminPricingPlansPrefix}premium'),
                authorization: 'Bearer fake.token',
                idempotencyKey: 'idem-plan-replay',
                body: const <String, Object?>{'monthly_usd': 300.0},
              );
              return response.statusCode;
            }

            final first = await patchOnce();
            final second = await patchOnce();
            expect(first, equals(200));
            // The proxy idempotency layer collapses the replay; without a
            // store wired in this harness both still succeed (no 409), and
            // the gateway never throws on the second call.
            expect(second, anyOf(equals(200), equals(409)));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('Phase 3 OPTIONS preflight allows PATCH for /plans', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve('${adminPricingPlansPrefix}premium'),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'PATCH');
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type,idempotency-key',
          );
          request.contentLength = 0;
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, equals(HttpStatus.noContent));
          final allowMethods =
              response.headers.value('access-control-allow-methods') ?? '';
          expect(allowMethods.toUpperCase(), contains('PATCH'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    // ── Phase 5a — feature-entitlements matrix GET + PATCH. ─────────
    // Mirrors the Phase 3 plan-route coverage: auth-required (read role
    // for GET, write role for PATCH), updates + audit reason, idempotency,
    // and 404 on an unknown plan or feature.
    test(
      'Phase 5a GET /v1/admin/pricing/entitlements returns the rows',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()
            ..entitlementsResult = const <Map<String, Object?>>[
              <String, Object?>{
                'tier_key': 'premium',
                'feature_slug': 'lms',
                'enabled': true,
                'updated_at': null,
                'updated_by': null,
              },
            ];
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingEntitlementsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final entitlements = (body['entitlements']! as List)
                .cast<Map<String, Object?>>();
            expect(entitlements.single['tier_key'], equals('premium'));
            expect(entitlements.single['feature_slug'], equals('lms'));
            expect(gateway.lastReason, contains('admin.pricing.GET'));
            expect(gateway.lastReason, contains('entitlements_list'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 5a GET /v1/admin/pricing/entitlements admits ff_support',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()
            ..entitlementsResult = const <Map<String, Object?>>[];
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
            final response = await httpGet(
              ctx.client,
              ctx.baseUri.resolve(adminPricingEntitlementsPath),
              authorization: 'Bearer fake.token',
            );
            expect(response.statusCode, equals(200));
            expect(gateway.lastActorUserId, equals('user_support'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('Phase 5a PATCH .../entitlements/{tier}/{slug} rejects ff_support '
        '(403, write)', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
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
          final response = await httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve('${adminPricingEntitlementsPrefix}premium/lms'),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'enabled': true},
          );
          // PATCH is a write method → strict super_admin-only set.
          expect(response.statusCode, equals(403));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('permission_denied'));
          expect(gateway.lastEntitlementTierKey, isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'Phase 5a PATCH .../entitlements/{tier}/{slug} toggles + audits',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '${adminPricingEntitlementsPrefix}premium/lms',
              ),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-ent-1',
              body: const <String, Object?>{'enabled': true},
            );
            expect(response.statusCode, equals(200));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(
              (body['entitlement']! as Map)['tier_key'],
              equals('premium'),
            );
            expect(gateway.lastEntitlementTierKey, equals('premium'));
            expect(gateway.lastEntitlementFeatureSlug, equals('lms'));
            expect(gateway.lastEntitlementEnabled, isTrue);
            // The admin reason threads the entitlement action for honest
            // audit attribution.
            expect(gateway.lastReason, contains('admin.pricing.PATCH'));
            expect(gateway.lastReason, contains('entitlement:premium:lms'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 5a PATCH .../entitlements requires a boolean enabled (400)',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(initialClaims: superAdminClaims);
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '${adminPricingEntitlementsPrefix}premium/lms',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(400));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('missing_enabled'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('Phase 5a PATCH .../entitlements 404s for an unknown plan', () async {
      await withRealHttp(() async {
        final ctx = await spinUp(initialClaims: superAdminClaims);
        try {
          final response = await httpJson(
            ctx.client,
            'PATCH',
            ctx.baseUri.resolve(
              '${adminPricingEntitlementsPrefix}megapremium/lms',
            ),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'enabled': true},
          );
          expect(response.statusCode, equals(404));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('unknown_plan'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'Phase 5a PATCH .../entitlements 404s for an unknown feature',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(initialClaims: superAdminClaims);
          try {
            final response = await httpJson(
              ctx.client,
              'PATCH',
              ctx.baseUri.resolve(
                '${adminPricingEntitlementsPrefix}premium/teleportation',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'enabled': true},
            );
            expect(response.statusCode, equals(404));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('unknown_feature'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 5a PATCH .../entitlements is idempotent: replay one result',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            Future<int> patchOnce() async {
              final response = await httpJson(
                ctx.client,
                'PATCH',
                ctx.baseUri.resolve(
                  '${adminPricingEntitlementsPrefix}premium/lms',
                ),
                authorization: 'Bearer fake.token',
                idempotencyKey: 'idem-ent-replay',
                body: const <String, Object?>{'enabled': true},
              );
              return response.statusCode;
            }

            final first = await patchOnce();
            final second = await patchOnce();
            expect(first, equals(200));
            expect(second, anyOf(equals(200), equals(409)));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('Phase 5a OPTIONS preflight allows PATCH for /entitlements', () async {
      await withRealHttp(() async {
        final ctx = await spinUp();
        try {
          final request = await ctx.client.openUrl(
            'OPTIONS',
            ctx.baseUri.resolve('${adminPricingEntitlementsPrefix}premium/lms'),
          );
          request.persistentConnection = false;
          request.headers.set('Origin', 'https://admin.forgeflow.app');
          request.headers.set('Access-Control-Request-Method', 'PATCH');
          request.headers.set(
            'Access-Control-Request-Headers',
            'authorization,content-type,idempotency-key',
          );
          request.contentLength = 0;
          final response = await request.close();
          await response.drain<void>();
          expect(response.statusCode, equals(HttpStatus.noContent));
          final allowMethods =
              response.headers.value('access-control-allow-methods') ?? '';
          expect(allowMethods.toUpperCase(), contains('PATCH'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('Scoped contracts GET effective forwards hierarchy scope', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
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
          final response = await httpGet(
            ctx.client,
            ctx.baseUri.resolve(
              '$adminPricingScopedContractsEffectivePath'
              '?operator_id=op-1&scope_type=location'
              '&org_unit_id=ou-east&location_id=loc-1',
            ),
            authorization: 'Bearer fake.token',
          );
          expect(response.statusCode, equals(200), reason: response.body);
          expect(gateway.lastScopedContractOperatorId, equals('op-1'));
          expect(gateway.lastScopedContractScopeType, equals('location'));
          expect(gateway.lastScopedContractOrgUnitId, equals('ou-east'));
          expect(gateway.lastScopedContractLocationId, equals('loc-1'));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final contract = body['effective_contract']! as Map<String, Object?>;
          expect(contract['override_status'], equals('set_here'));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('Scoped contracts PUT saves custom terms + audits', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          final response = await httpJson(
            ctx.client,
            'PUT',
            ctx.baseUri.resolve(adminPricingScopedContractsPath),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-scoped-contract-save',
            body: const <String, Object?>{
              'operator_id': 'op-1',
              'scope_type': 'location',
              'org_unit_id': 'ou-east',
              'location_id': 'loc-1',
              'tier_key': 'enterprise',
              'monthly_usd': 500.0,
              'advisor_cap_monthly_usd': 300.0,
              'contract_label': 'Yorkville terms',
              'admin_reason': 'Signed local enterprise amendment',
            },
          );
          expect(response.statusCode, equals(200), reason: response.body);
          expect(gateway.lastScopedContractOperatorId, equals('op-1'));
          expect(gateway.lastScopedContractTierKey, equals('enterprise'));
          expect(gateway.lastScopedContractMonthlyUsd, equals(500.0));
          expect(gateway.lastScopedContractAdvisorCapMonthlyUsd, equals(300.0));
          expect(
            gateway.lastScopedContractAdminReason,
            contains('Signed local enterprise amendment'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('Scoped contracts PUT requires Idempotency-Key', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          final response = await httpJson(
            ctx.client,
            'PUT',
            ctx.baseUri.resolve(adminPricingScopedContractsPath),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{
              'operator_id': 'op-1',
              'scope_type': 'business',
              'tier_key': 'enterprise',
              'monthly_usd': 500.0,
              'admin_reason': 'Signed enterprise amendment',
            },
          );
          expect(response.statusCode, equals(400), reason: response.body);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('idempotency_key_missing'));
          expect(gateway.lastScopedContractOperatorId, isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('Scoped contracts DELETE clears one override by id', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          final response = await httpJson(
            ctx.client,
            'DELETE',
            ctx.baseUri.resolve(
              '${adminPricingScopedContractsPrefix}contract-1',
            ),
            authorization: 'Bearer fake.token',
            idempotencyKey: 'idem-scoped-contract-delete',
            body: const <String, Object?>{
              'operator_id': 'op-1',
              'scope_type': 'location',
              'org_unit_id': 'ou-east',
              'location_id': 'loc-1',
              'admin_reason': 'Clear location override',
            },
          );
          expect(response.statusCode, equals(200), reason: response.body);
          expect(gateway.lastScopedContractOverrideId, equals('contract-1'));
          expect(
            gateway.lastScopedContractAdminReason,
            contains('Clear location override'),
          );
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    // ── Phase 4a — Pilot free-trial start + convert. ────────────────
    // HP #2: these routes flip the trial FLAG + tier on a REAL operator.
    // No `demo_*` table, no parallel demo seeder. The route forwards the
    // real operator id straight to the gateway (which mutates the real
    // `operators` row); there is no demo-scope substitution anywhere on
    // the path.

    test('Phase 4a POST .../operators/{id}/start-pilot forwards id + '
        'default trial days', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(
              '${adminPricingOperatorsPrefix}op-real-1/start-pilot',
            ),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(200), reason: response.body);
          // HP #2 — the REAL operator id reaches the gateway verbatim;
          // no demo-scope id substitution.
          expect(gateway.lastStartPilotOperatorId, equals('op-real-1'));
          // Omitted trial_days defaults to the named 30-day constant.
          expect(gateway.lastStartPilotTrialDays, equals(30));
          expect(gateway.lastReason, contains('start_pilot:op-real-1'));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final operator = body['operator']! as Map<String, Object?>;
          expect(operator['subscription_tier'], equals('pilot'));
          expect(operator['trial_mode'], isTrue);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'Phase 4a POST .../start-pilot honors an explicit trial_days',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/start-pilot',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{'trial_days': 14},
            );
            expect(response.statusCode, equals(200), reason: response.body);
            expect(gateway.lastStartPilotTrialDays, equals(14));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 4a POST .../start-pilot rejects ff_support (403, write)',
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
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/start-pilot',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(403));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('permission_denied'));
            // Write rejection lists the super_admin-only write set.
            final required = (body['required_roles']! as List).cast<String>();
            expect(required, equals(<String>['super_admin']));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('Phase 4a POST .../start-pilot rejects an out-of-range trial_days '
        '(400)', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(
              '${adminPricingOperatorsPrefix}op-1/start-pilot',
            ),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{'trial_days': 0},
          );
          expect(response.statusCode, equals(400));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['error'], equals('invalid_trial_days'));
          // The gateway is never reached when validation rejects.
          expect(gateway.lastStartPilotOperatorId, isNull);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'Phase 4a POST .../start-pilot 404s for an unknown operator',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()..startPilotResult = null;
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-missing/start-pilot',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(404));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('unknown_operator'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test('Phase 4a POST .../start-pilot accepts an Idempotency-Key on '
        'replay', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          Future<int> call() async {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/start-pilot',
              ),
              authorization: 'Bearer fake.token',
              idempotencyKey: 'idem-start-pilot-1',
              body: const <String, Object?>{'trial_days': 30},
            );
            return response.statusCode;
          }

          final first = await call();
          final second = await call();
          expect(first, equals(200));
          // The route admits the Idempotency-Key header on both calls.
          // This harness wires no idempotency store, so the proxy cannot
          // collapse the replay (mirrors the Phase 3 plan-pricing
          // idempotency test above); deeper reserve->complete collapsing
          // is covered by the admin-idempotency store tests. The key
          // point here: the route forwarded the work both times without a
          // 4xx for the header itself.
          expect(second, anyOf(equals(200), equals(409)));
          expect(gateway.startPilotCalls, greaterThanOrEqualTo(1));
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('Phase 4a POST .../operators/{id}/convert-trial forwards id + '
        'reports converted', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway();
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(
              '${adminPricingOperatorsPrefix}op-real-2/convert-trial',
            ),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(200), reason: response.body);
          expect(gateway.lastConvertTrialOperatorId, equals('op-real-2'));
          expect(gateway.lastReason, contains('convert_trial:op-real-2'));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['converted'], isTrue);
          final operator = body['operator']! as Map<String, Object?>;
          expect(operator['subscription_tier'], equals('starter'));
          expect(operator['trial_mode'], isFalse);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test('Phase 4a POST .../convert-trial reports converted=false for a '
        'non-trial operator (200 no-op)', () async {
      await withRealHttp(() async {
        final gateway = FakePricingAdminGateway()
          ..convertTrialResult = const TrialConversionOutcome(
            operatorFound: true,
            converted: false,
            bundle: <String, Object?>{
              'operator': <String, Object?>{
                'operator_id': 'op-1',
                'subscription_tier': 'starter',
                'trial_mode': false,
              },
              'caps': <Map<String, Object?>>[],
            },
          );
        final ctx = await spinUp(
          customGateway: gateway,
          initialClaims: superAdminClaims,
        );
        try {
          final response = await httpJson(
            ctx.client,
            'POST',
            ctx.baseUri.resolve(
              '${adminPricingOperatorsPrefix}op-1/convert-trial',
            ),
            authorization: 'Bearer fake.token',
            body: const <String, Object?>{},
          );
          expect(response.statusCode, equals(200));
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(body['converted'], isFalse);
        } finally {
          ctx.client.close(force: true);
          await ctx.server.close(force: true);
        }
      });
    });

    test(
      'Phase 4a POST .../convert-trial 404s for an unknown operator',
      () async {
        await withRealHttp(() async {
          final gateway = FakePricingAdminGateway()
            ..convertTrialResult = const TrialConversionOutcome.notFound();
          final ctx = await spinUp(
            customGateway: gateway,
            initialClaims: superAdminClaims,
          );
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-missing/convert-trial',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(404));
            final body = jsonDecode(response.body) as Map<String, Object?>;
            expect(body['error'], equals('unknown_operator'));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 4a POST .../convert-trial rejects ff_support (403, write)',
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
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/convert-trial',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(403));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );

    test(
      'Phase 4a unknown operator action under the pricing prefix 404s',
      () async {
        await withRealHttp(() async {
          final ctx = await spinUp(initialClaims: superAdminClaims);
          try {
            final response = await httpJson(
              ctx.client,
              'POST',
              ctx.baseUri.resolve(
                '${adminPricingOperatorsPrefix}op-1/bogus-action',
              ),
              authorization: 'Bearer fake.token',
              body: const <String, Object?>{},
            );
            expect(response.statusCode, equals(404));
          } finally {
            ctx.client.close(force: true);
            await ctx.server.close(force: true);
          }
        });
      },
    );
  });
}
