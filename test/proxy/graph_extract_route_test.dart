// Forge & Flow advisor proxy -- graph semantic-extraction endpoint tests.
//
// Slice G4b: POST /v1/admin/graph/extract (OP-GATED).
//
// All tests are MOCKED -- no real Anthropic calls, no network, no live DB.
//
// Proves:
//   1.  Gateway null (OP-GATED) -> 503 graph_extract_not_configured.
//   2.  Missing Idempotency-Key header -> 400 missing_idempotency_key.
//   3.  Non-super_admin actor -> 403 permission_denied.
//   4a. Missing chunk_text body field -> 400.
//   4b. Missing chunk_id body field -> 400.
//   4c. Missing content_sha256 body field -> 400.
//   4d. Missing document_title body field -> 400.
//   4e. Missing source_path body field -> 400.
//   5.  chunk_text exceeds max -> 400 chunk_text_too_long.
//   6.  Unsupported model override -> 400 unsupported_model.
//   7.  Missing ANTHROPIC_API_KEY (null) -> 503 graph_extract_key_unavailable.
//   8.  Gateway throws GraphExtractGatewayException -> 503.
//   9.  Successful extraction: 200 with nodes, edges, usage_class, tokens.
//  10.  HP #7: Anthropic API key NOT present in any response field.
//  11.  kGraphExtractionUsageClass appears in the 200 response body.
//  12.  Default model (claude-haiku-4-5) used when not supplied.
//  13.  Valid model override (claude-sonnet-4-6) accepted.
//  14.  ff_support role -> 403 (only super_admin for writes).
//  15.  AMBIGUOUS counts reflected in 200 response.
//
// F2 (HP #9 cap + proxy_requests idempotency wiring) -- MOCKED guard + store:
//  16.  Idempotent replay: a 2nd call with the same Idempotency-Key returns
//       the cached 200 response and does NOT re-invoke the gateway.
//  17.  Accounting cap refusal -> 402 usage_cap_reached; gateway NOT invoked.
//  18.  Usage-guard exhaustion -> 402 monthly_cap_reached; gateway NOT invoked
//       and NO reservation made (guard check precedes the reservation).
//  19.  Successful call commits ONE usage-log row under 'graph_extraction'
//       with the provider-reported tokens + the rate-derived cost, and one
//       completeRequest stats row attributed to the verified caller.
//  20.  HP #7: the server-side key is absent from the metered 200 body.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:forge_and_flow/domain/services/advisor_provider_constants.dart'
    show LlmCostRateRegistry;

import '../../tool/advisor_proxy/advisor_proxy.dart';
import '../advisor_proxy_test_helpers.dart';

// ── Mock gateway ────────────────────────────────────────────────────────────────

class _MockExtractGateway implements GraphSemanticExtractGateway {
  _MockExtractGateway({
    this.stubNodes = const <GraphExtractNode>[],
    this.stubEdges = const <GraphExtractEdge>[],
    this.stubInputTokens = 120,
    this.stubOutputTokens = 80,
    this.throwException = false,
  });

  final List<GraphExtractNode> stubNodes;
  final List<GraphExtractEdge> stubEdges;
  final int stubInputTokens;
  final int stubOutputTokens;
  final bool throwException;

  // Records calls for assertions.  HP #7: apiKey intentionally NOT captured.
  final List<Map<String, String>> calls = <Map<String, String>>[];

  @override
  Future<GraphExtractResult> extractFromChunk({
    required String apiKey, // HP #7: accepted, not stored
    required String model,
    required String documentTitle,
    required String sourcePath,
    required List<String> headingPath,
    required String chunkText,
    required String chunkId,
    required String contentSha256,
  }) async {
    calls.add(<String, String>{
      'model': model,
      'chunkId': chunkId,
      'documentTitle': documentTitle,
    });
    if (throwException) {
      throw const GraphExtractGatewayException('mock provider failure');
    }
    return GraphExtractResult(
      nodes: stubNodes,
      edges: stubEdges,
      inputTokens: stubInputTokens,
      outputTokens: stubOutputTokens,
    );
  }
}

// ── Test scaffold ────────────────────────────────────────────────────────────────

/// Minimal valid extraction request body.
Map<String, Object?> _validBody({
  String chunkText = 'CPLH is cost per labor hour calculated by dividing '
      'total labor cost by total revenue for a given period.',
  String chunkId = 'chunk-abc123',
  String contentSha256 = 'aabbccdd',
  String documentTitle = 'Operations Guide',
  String sourcePath = 'docs/operations_guide.md',
  List<String>? headingPath,
  String? model,
}) {
  return <String, Object?>{
    'chunk_text': chunkText,
    'chunk_id': chunkId,
    'content_sha256': contentSha256,
    'document_title': documentTitle,
    'source_path': sourcePath,
    if (headingPath != null) 'heading_path': headingPath,
    if (model != null) 'model': model,
  };
}

// --- Metering doubles (F2) ----------------------------------------------------

/// An OPEN usage guard: zero usage, launch tier, always allows. Mirrors the
/// advisor answer route's `_openGuard()`.
ProxyUsageGuard _openGuard() => ProxyUsageGuard(
  store: FixedSnapshotProxyUsageStore(
    snapshot: UsageSnapshot(
      requestsThisMinute: 0,
      costCentsThisMonth: 0,
      minuteBucketStart: DateTime.utc(2026, 5, 27, 12, 0),
      monthBucketStart: DateTime.utc(2026, 5, 1),
    ),
  ),
  tierResolver: const FixedLaunchTierResolver(),
);

/// An EXHAUSTED usage guard: the monthly cost cap is already reached, so
/// `requireAllowed` raises `UsageRefusal` (402 monthly_cap_reached) BEFORE any
/// reservation or provider call. Mirrors the answer route's `_exhaustedGuard()`.
ProxyUsageGuard _exhaustedGuard() => ProxyUsageGuard(
  store: FixedSnapshotProxyUsageStore(
    snapshot: UsageSnapshot(
      requestsThisMinute: 0,
      costCentsThisMonth: PolicyTier.launch.maxMonthlyCostCents,
      minuteBucketStart: DateTime.utc(2026, 5, 27, 12, 0),
      monthBucketStart: DateTime.utc(2026, 5, 1),
    ),
  ),
  tierResolver: const FixedLaunchTierResolver(),
);

/// An accounting store whose per-tier monthly cap is already exhausted, so
/// `startRequest` returns `ProxyAccountingRefused` (route -> 402
/// usage_cap_reached) BEFORE the provider call. monthlyUsed == monthlyCap so
/// any positive pre-flight estimate trips `monthlyExceeded`.
InMemoryAccountingStore _refusingAccountingStore() => InMemoryAccountingStore(
  capStatus: const ProxyCapStatus(
    usageClass: 'graph_extraction',
    monthlyCapCents: 1,
    monthlyUsedCents: 1,
    perInvocationCapCents: 0,
    estimatedCostCents: 0,
  ),
);

// ── Tests ───────────────────────────────────────────────────────────────────────

void main() {
  // Restore any Flutter HttpOverrides that are set in the test environment
  // so the raw dart:io HttpServer/HttpClient used here work correctly.
  Future<T> withRealHttp<T>(Future<T> Function() body) async {
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      return await body();
    } finally {
      HttpOverrides.global = saved;
    }
  }

  group('POST $graphExtractPath', () {
    late HttpServer server;
    late HttpClient client;
    late Uri baseUri;
    late SettableVerifier verifier;

    Future<void> spinUp({
      GraphSemanticExtractGateway? graphExtractGateway,
      String? anthropicApiKey,
      Set<String> roles = const <String>{'super_admin'},
      // F2 -- HP #9 metering + proxy_requests idempotency seams. Optional so
      // the 19 pre-F2 tests keep driving the gateway-only path unchanged.
      ProxyUsageGuard? usageGuard,
      ProxyAccountingStore? accountingStore,
    }) async {
      verifier = SettableVerifier();
      verifier.claims = ProxyJwtClaims(
        userId: 'user_g4b_test',
        operatorId: 'op_g4b_test',
        locationId: 'loc_g4b_test',
        roles: roles.toList(),
      );
      final guard = ProxyRequestGuard(verifier: verifier);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        try {
          await routeRequest(
            req,
            guard,
            graphExtractGateway: graphExtractGateway,
            anthropicApiKeyForGraphExtract: anthropicApiKey,
            usageGuard: usageGuard,
            accountingStore: accountingStore,
          );
        } catch (_) {
          try {
            req.response.statusCode = 500;
            await req.response.close();
          } catch (_) {/* ignore */}
        }
      });
      client = HttpClient();
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
    }

    Future<void> shutDown() async {
      client.close(force: true);
      await server.close(force: true);
    }

    Future<HttpResponseSnapshot> postExtract({
      Map<String, Object?>? body,
      String? idempotencyKey = 'test-idem-key',
      Map<String, String>? extraHeaders,
    }) async {
      final headers = <String, String>{
        if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
        ...?extraHeaders,
      };
      return httpPost(
        client,
        baseUri.resolve(graphExtractPath),
        authorization: 'Bearer test-token',
        body: body ?? _validBody(),
        headers: headers,
      );
    }

    // 1. OP-GATED: gateway null -> 503.
    test('gateway null returns 503 graph_extract_not_configured', () async {
      await withRealHttp(() async {
        await spinUp(graphExtractGateway: null, anthropicApiKey: 'k');
        try {
          final r = await postExtract();
          expect(r.statusCode, 503);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'graph_extract_not_configured');
        } finally {
          await shutDown();
        }
      });
    });

    // 2. Missing Idempotency-Key -> 400.
    test('missing Idempotency-Key returns 400', () async {
      await withRealHttp(() async {
        await spinUp(
          graphExtractGateway: _MockExtractGateway(),
          anthropicApiKey: 'k',
        );
        try {
          final r = await postExtract(idempotencyKey: null);
          expect(r.statusCode, 400);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'missing_idempotency_key');
        } finally {
          await shutDown();
        }
      });
    });

    // 3. Non-super_admin -> 403.
    test('operator role returns 403 permission_denied', () async {
      await withRealHttp(() async {
        await spinUp(
          graphExtractGateway: _MockExtractGateway(),
          anthropicApiKey: 'k',
          roles: <String>{'operator'},
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 403);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'permission_denied');
        } finally {
          await shutDown();
        }
      });
    });

    // 4a-4e. Missing required body fields.
    for (final missingField in <String>[
      'chunk_text',
      'chunk_id',
      'content_sha256',
      'document_title',
      'source_path',
    ]) {
      test('missing $missingField returns 400', () async {
        await withRealHttp(() async {
          await spinUp(
            graphExtractGateway: _MockExtractGateway(),
            anthropicApiKey: 'k',
          );
          try {
            final body = Map<String, Object?>.from(_validBody());
            body.remove(missingField);
            final r = await postExtract(body: body);
            expect(r.statusCode, 400,
                reason: 'Expected 400 for missing $missingField');
            final decoded = jsonDecode(r.body) as Map<String, Object?>;
            expect(
              decoded['error'].toString(),
              contains(missingField),
              reason: 'Error code should mention $missingField',
            );
          } finally {
            await shutDown();
          }
        });
      });
    }

    // 5. chunk_text too long -> 400.
    test('chunk_text too long returns 400 chunk_text_too_long', () async {
      await withRealHttp(() async {
        await spinUp(
          graphExtractGateway: _MockExtractGateway(),
          anthropicApiKey: 'k',
        );
        try {
          final r = await postExtract(
            body: _validBody(chunkText: 'x' * 12001),
          );
          expect(r.statusCode, 400);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'chunk_text_too_long');
        } finally {
          await shutDown();
        }
      });
    });

    // 6. Unsupported model override -> 400.
    test('unsupported model returns 400 unsupported_model', () async {
      await withRealHttp(() async {
        await spinUp(
          graphExtractGateway: _MockExtractGateway(),
          anthropicApiKey: 'k',
        );
        try {
          final r = await postExtract(
            body: _validBody(model: 'gpt-4o-not-allowed'),
          );
          expect(r.statusCode, 400);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'unsupported_model');
        } finally {
          await shutDown();
        }
      });
    });

    // 7. Null API key -> 503.
    test('null anthropicApiKey returns 503 graph_extract_key_unavailable',
        () async {
      await withRealHttp(() async {
        await spinUp(
          graphExtractGateway: _MockExtractGateway(),
          anthropicApiKey: null,
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 503);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'graph_extract_key_unavailable');
        } finally {
          await shutDown();
        }
      });
    });

    // 8. Gateway exception -> 503.
    test('gateway exception returns 503 graph_extract_provider_error',
        () async {
      await withRealHttp(() async {
        await spinUp(
          graphExtractGateway: _MockExtractGateway(throwException: true),
          anthropicApiKey: 'k',
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 503);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'graph_extract_provider_error');
        } finally {
          await shutDown();
        }
      });
    });

    // 9. Successful extraction: 200 with expected fields.
    test('successful extraction returns 200 with nodes, edges, tokens',
        () async {
      await withRealHttp(() async {
        final gateway = _MockExtractGateway(
          stubNodes: <GraphExtractNode>[
            const GraphExtractNode(
              nodeKey: 'CPLH',
              kind: 'Metric',
              label: 'EXTRACTED',
              verbatimText: 'CPLH is cost per labor hour',
            ),
          ],
          stubEdges: <GraphExtractEdge>[
            const GraphExtractEdge(
              fromNodeKey: 'CPLH',
              toNodeKey: 'Labor Cost',
              edgeType: 'MEASURES',
              label: 'EXTRACTED',
              verbatimText: 'CPLH measures labor cost',
            ),
          ],
          stubInputTokens: 150,
          stubOutputTokens: 90,
        );
        await spinUp(graphExtractGateway: gateway, anthropicApiKey: 'k');
        try {
          final r = await postExtract();
          expect(r.statusCode, 200);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['node_count'], 1);
          expect(decoded['edge_count'], 1);
          expect(decoded['input_tokens'], 150);
          expect(decoded['output_tokens'], 90);
          expect(decoded['chunk_id'], 'chunk-abc123');

          final nodes = decoded['nodes'] as List<Object?>;
          final firstNode = nodes.first as Map<String, Object?>;
          expect(firstNode['kind'], 'Metric');
          expect(firstNode['label'], 'EXTRACTED');

          final edges = decoded['edges'] as List<Object?>;
          final firstEdge = edges.first as Map<String, Object?>;
          expect(firstEdge['edge_type'], 'MEASURES');
        } finally {
          await shutDown();
        }
      });
    });

    // 10. HP #7: API key NOT in response.
    test('HP #7: Anthropic API key not present in response body', () async {
      await withRealHttp(() async {
        const testKey = 'super-secret-hp7-check-key-999';
        await spinUp(
          graphExtractGateway: _MockExtractGateway(),
          anthropicApiKey: testKey,
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 200);
          expect(
            r.body.contains(testKey),
            isFalse,
            reason: 'HP #7: the Anthropic API key must never appear in response',
          );
        } finally {
          await shutDown();
        }
      });
    });

    // 11. HP #9: usage_class in response.
    test('HP #9: usage_class is kGraphExtractionUsageClass in 200', () async {
      await withRealHttp(() async {
        await spinUp(
          graphExtractGateway: _MockExtractGateway(),
          anthropicApiKey: 'k',
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 200);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['usage_class'], kGraphExtractionUsageClass);
        } finally {
          await shutDown();
        }
      });
    });

    // 12. Default model used when body omits 'model'.
    test('default model is kGraphExtractionDefaultModel', () async {
      await withRealHttp(() async {
        final gateway = _MockExtractGateway();
        await spinUp(graphExtractGateway: gateway, anthropicApiKey: 'k');
        try {
          final r = await postExtract(body: _validBody());
          expect(r.statusCode, 200);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['model'], kGraphExtractionDefaultModel);
          expect(gateway.calls.first['model'], kGraphExtractionDefaultModel);
        } finally {
          await shutDown();
        }
      });
    });

    // 13. Valid model override accepted.
    test('claude-sonnet-4-6 model override is accepted', () async {
      await withRealHttp(() async {
        final gateway = _MockExtractGateway();
        await spinUp(graphExtractGateway: gateway, anthropicApiKey: 'k');
        try {
          final r = await postExtract(
            body: _validBody(model: 'claude-sonnet-4-6'),
          );
          expect(r.statusCode, 200);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['model'], 'claude-sonnet-4-6');
          expect(gateway.calls.first['model'], 'claude-sonnet-4-6');
        } finally {
          await shutDown();
        }
      });
    });

    // 14. ff_support role -> 403.
    test('ff_support role returns 403 (write-only super_admin gate)', () async {
      await withRealHttp(() async {
        await spinUp(
          graphExtractGateway: _MockExtractGateway(),
          anthropicApiKey: 'k',
          roles: <String>{'ff_support'},
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 403);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'permission_denied');
        } finally {
          await shutDown();
        }
      });
    });

    // 15. AMBIGUOUS node count in 200 response.
    test('AMBIGUOUS counts surfaced in 200 response', () async {
      await withRealHttp(() async {
        final gateway = _MockExtractGateway(
          stubNodes: <GraphExtractNode>[
            const GraphExtractNode(
              nodeKey: 'Unknown',
              kind: 'Concept',
              label: 'AMBIGUOUS',
              verbatimText: 'unclear text',
            ),
          ],
          stubEdges: <GraphExtractEdge>[
            const GraphExtractEdge(
              fromNodeKey: 'A',
              toNodeKey: 'B',
              edgeType: 'RELATES_TO',
              label: 'AMBIGUOUS',
              verbatimText: 'vague connection',
            ),
          ],
        );
        await spinUp(graphExtractGateway: gateway, anthropicApiKey: 'k');
        try {
          final r = await postExtract();
          expect(r.statusCode, 200);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['ambiguous_node_count'], 1);
          expect(decoded['ambiguous_edge_count'], 1);
        } finally {
          await shutDown();
        }
      });
    });
  });

  // --- F2: HP #9 cap + proxy_requests idempotency wiring --------------------
  //
  // MOCKED ONLY. No real DB, no real provider, no paid AI. A loopback
  // HttpServer drives the real `routeRequest` dispatch with an injected mock
  // `ProxyUsageGuard` (built from a fixed-snapshot counter store) and the
  // shared in-memory `ProxyAccountingStore` fake. Proves the dispatcher's two
  // metering closures behave like the advisor answer route: replay returns the
  // cached response WITHOUT re-invoking the gateway; either cap path returns
  // the refusal shape WITHOUT invoking the gateway; a success commits a usage
  // log under 'graph_extraction' with the provider-reported tokens + cost.
  group('POST $graphExtractPath (F2 metering + idempotency)', () {
    late HttpServer server;
    late HttpClient client;
    late Uri baseUri;
    late SettableVerifier verifier;

    Future<void> spinUp({
      required GraphSemanticExtractGateway graphExtractGateway,
      String? anthropicApiKey = 'k',
      ProxyUsageGuard? usageGuard,
      ProxyAccountingStore? accountingStore,
    }) async {
      verifier = SettableVerifier();
      verifier.claims = const ProxyJwtClaims(
        userId: 'user_g4b_test',
        operatorId: 'op_g4b_test',
        locationId: 'loc_g4b_test',
        roles: <String>['super_admin'],
      );
      final guard = ProxyRequestGuard(verifier: verifier);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        try {
          await routeRequest(
            req,
            guard,
            graphExtractGateway: graphExtractGateway,
            anthropicApiKeyForGraphExtract: anthropicApiKey,
            usageGuard: usageGuard,
            accountingStore: accountingStore,
          );
        } catch (_) {
          try {
            req.response.statusCode = 500;
            await req.response.close();
          } catch (_) {/* ignore */}
        }
      });
      client = HttpClient();
      baseUri = Uri.parse('http://${server.address.host}:${server.port}');
    }

    Future<void> shutDown() async {
      client.close(force: true);
      await server.close(force: true);
    }

    Future<HttpResponseSnapshot> postExtract({
      Map<String, Object?>? body,
      String idempotencyKey = 'test-idem-key',
    }) async {
      return httpPost(
        client,
        baseUri.resolve(graphExtractPath),
        authorization: 'Bearer test-token',
        body: body ?? _validBody(),
        headers: <String, String>{'Idempotency-Key': idempotencyKey},
      );
    }

    // 16. Idempotent replay: a second call with the same Idempotency-Key
    //     returns the cached 200 response WITHOUT re-invoking the gateway.
    test('idempotent replay returns cached response, gateway not re-invoked',
        () async {
      await withRealHttp(() async {
        final gateway = _MockExtractGateway(
          stubNodes: <GraphExtractNode>[
            const GraphExtractNode(
              nodeKey: 'CPLH',
              kind: 'Metric',
              label: 'EXTRACTED',
              verbatimText: 'CPLH is cost per labor hour',
            ),
          ],
          stubInputTokens: 150,
          stubOutputTokens: 90,
        );
        final accounting = InMemoryAccountingStore.open();
        await spinUp(
          graphExtractGateway: gateway,
          usageGuard: _openGuard(),
          accountingStore: accounting,
        );
        try {
          // First call: real extraction, provider invoked once, persisted.
          final first = await postExtract();
          expect(first.statusCode, 200);
          final firstDecoded = jsonDecode(first.body) as Map<String, Object?>;
          expect(firstDecoded['idempotent_replay'], isFalse);
          expect(firstDecoded['node_count'], 1);
          expect(gateway.calls.length, 1);
          expect(accounting.completeCalls, 1);

          // Second call, SAME key: cached replay, provider NOT invoked again.
          final second = await postExtract();
          expect(second.statusCode, 200);
          final secondDecoded =
              jsonDecode(second.body) as Map<String, Object?>;
          expect(secondDecoded['idempotent_replay'], isTrue);
          // Body otherwise matches the first response (node_count carried).
          expect(secondDecoded['node_count'], 1);
          expect(secondDecoded['chunk_id'], firstDecoded['chunk_id']);
          // The gateway was NOT called a second time.
          expect(gateway.calls.length, 1,
              reason: 'replay must not re-invoke the extraction gateway');
          // No second completion either (replay early-returns).
          expect(accounting.completeCalls, 1);
        } finally {
          await shutDown();
        }
      });
    });

    // 17. Accounting-store cap refusal: startRequest refuses -> 402
    //     usage_cap_reached, gateway NOT invoked.
    test('accounting cap refusal returns 402, gateway not invoked', () async {
      await withRealHttp(() async {
        final gateway = _MockExtractGateway();
        final accounting = _refusingAccountingStore();
        await spinUp(
          graphExtractGateway: gateway,
          usageGuard: _openGuard(),
          accountingStore: accounting,
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 402);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'usage_cap_reached');
          expect(decoded['cap_status'], isA<Map<String, Object?>>());
          // Refused BEFORE the provider call.
          expect(gateway.calls, isEmpty,
              reason: 'cap refusal must not invoke the extraction gateway');
          expect(accounting.startCalls, 1);
          expect(accounting.completeCalls, 0);
          expect(accounting.commitCalls, 0);
        } finally {
          await shutDown();
        }
      });
    });

    // 18. Usage-guard cap exhaustion: requireAllowed raises UsageRefusal ->
    //     402 monthly_cap_reached, gateway NOT invoked, NO reservation made.
    test('usage guard exhaustion returns 402 monthly_cap_reached, '
        'gateway not invoked', () async {
      await withRealHttp(() async {
        final gateway = _MockExtractGateway();
        final accounting = InMemoryAccountingStore.open();
        await spinUp(
          graphExtractGateway: gateway,
          usageGuard: _exhaustedGuard(),
          accountingStore: accounting,
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 402);
          final decoded = jsonDecode(r.body) as Map<String, Object?>;
          expect(decoded['error'], 'monthly_cap_reached');
          expect(gateway.calls, isEmpty,
              reason: 'guard refusal must not invoke the extraction gateway');
          // The guard check precedes the reservation, so no row was reserved.
          expect(accounting.startCalls, 0);
          expect(accounting.completeCalls, 0);
        } finally {
          await shutDown();
        }
      });
    });

    // 19. Successful call commits a usage-log row under 'graph_extraction'
    //     with the provider-reported tokens + the rate-derived cost.
    test('successful extraction commits usage under graph_extraction class',
        () async {
      await withRealHttp(() async {
        // 1,000,000 input + 1,000,000 output tokens -> a non-zero cost that
        // proves the wiring end-to-end (haiku: 100/500 cents per MTok).
        final gateway = _MockExtractGateway(
          stubInputTokens: 1000000,
          stubOutputTokens: 1000000,
        );
        final accounting = InMemoryAccountingStore.open();
        await spinUp(
          graphExtractGateway: gateway,
          usageGuard: _openGuard(),
          accountingStore: accounting,
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 200);

          // Exactly one usage-log commit + one completion.
          expect(accounting.commitCalls, 1);
          expect(accounting.completeCalls, 1);

          // token_count carries the summed provider totals (input + output).
          expect(accounting.lastCommittedTokenCount, 2000000);

          // Cost DERIVED from the provider tokens via the model rate, not a
          // constant. Cross-check directly against the registry.
          final rate = LlmCostRateRegistry.rateFor(kGraphExtractionDefaultModel);
          expect(rate, isNotNull);
          expect(
            accounting.lastCommittedCostCents,
            rate!.costCentsFor(inputTokens: 1000000, outputTokens: 1000000),
          );
          expect(accounting.lastCommittedCostCents, greaterThan(0));

          // Metered under the dedicated graph class.
          expect(
            accounting.lastCommittedTelemetry?.modelUsed,
            kGraphExtractionDefaultModel,
          );

          // The completion stats row carries the same class + real tokens.
          final stats = accounting.lastStats;
          expect(stats, isNotNull);
          expect(stats!.usageClass, kGraphExtractionUsageClass);
          expect(stats.resultStatus, 'success');
          expect(stats.promptTokenCount, 1000000);
          expect(stats.completionTokenCount, 1000000);
          // HP #4: stats actor is the verified caller (super_admin user id).
          expect(stats.actorUserId, 'user_g4b_test');
        } finally {
          await shutDown();
        }
      });
    });

    // 20. HP #7 under metering: the server-side key never appears in the
    //     200 body even when the full metering path runs.
    test('HP #7: key absent from response on the metered success path',
        () async {
      await withRealHttp(() async {
        const testKey = 'super-secret-hp7-metered-key-123';
        final gateway = _MockExtractGateway();
        final accounting = InMemoryAccountingStore.open();
        await spinUp(
          graphExtractGateway: gateway,
          anthropicApiKey: testKey,
          usageGuard: _openGuard(),
          accountingStore: accounting,
        );
        try {
          final r = await postExtract();
          expect(r.statusCode, 200);
          expect(r.body.contains(testKey), isFalse,
              reason: 'HP #7: the key must never appear in the response');
        } finally {
          await shutDown();
        }
      });
    });
  });
}
