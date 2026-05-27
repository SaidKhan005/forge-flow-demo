// F1 (HP#7): ProxyGraphExtractionGateway unit tests.
//
// These tests prove the C3 semantic-extraction tool now calls the PROXY route
// POST /v1/admin/graph/extract instead of the Anthropic provider directly.
//
// ALL tests are MOCKED: a package:http MockClient is injected, so there is NO
// real network, NO real proxy, NO real provider, and NO paid AI call. Each
// test asserts either the outgoing request shape (path, headers including the
// bearer token and Idempotency-Key, and body fields) or the parsing of a
// mocked proxy response (200 nodes/edges/tokens, 503, 400).
//
// Run with:
//   flutter test test/tool/advisor_corpus/proxy_graph_extraction_gateway_test.dart \
//     --reporter expanded

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;

import '../../../tool/advisor_corpus/advisor_corpus.dart';

/// A canonical successful proxy 200 body (matches graph_extract_route_part.dart).
String _proxy200Body({
  String chunkId = 'chunk-1',
  String contentSha256 = 'sha-1',
  int inputTokens = 321,
  int outputTokens = 87,
}) =>
    jsonEncode(<String, Object?>{
      'chunk_id': chunkId,
      'content_sha256': contentSha256,
      'model': 'claude-haiku-4-5',
      'usage_class': 'graph_extraction',
      'input_tokens': inputTokens,
      'output_tokens': outputTokens,
      'nodes': <Map<String, Object?>>[
        <String, Object?>{
          'node_key': 'CPLH',
          'kind': 'Metric',
          'label': 'EXTRACTED',
          'verbatim_text': 'CPLH must stay above 85.',
        },
        <String, Object?>{
          'node_key': 'food-safety',
          'kind': 'Concept',
          'label': 'INFERRED',
          'verbatim_text': 'food-safety compliance',
        },
      ],
      'edges': <Map<String, Object?>>[
        <String, Object?>{
          'from_node_key': 'CPLH',
          'to_node_key': 'food-safety',
          'edge_type': 'INFORMS',
          'label': 'EXTRACTED',
          'verbatim_text': 'CPLH informs food-safety.',
        },
      ],
      'node_count': 2,
      'edge_count': 1,
      'ambiguous_node_count': 0,
      'ambiguous_edge_count': 0,
      'extracted_at': '2026-05-27T00:00:00.000Z',
    });

Future<SemanticExtractionResponse> _callGateway(
  ProxyGraphExtractionGateway gateway, {
  String apiKey = 'proxy-bearer-token',
  String chunkId = 'chunk-1',
  String contentSha256 = 'sha-1',
}) {
  return gateway.extractFromChunk(
    apiKey: apiKey,
    model: 'claude-haiku-4-5',
    documentTitle: 'Sample Handbook',
    sourcePath: 'docs/Knowledge_graph_docs/sample.md',
    headingPath: const <String>['Food Safety'],
    chunkText: 'CPLH must stay above 85.',
    nodeKinds: kC3NodeKinds,
    edgeTypes: kC3EdgeTypes,
    edgeVerbPhrases: kC3EdgeVerbPhrases,
    chunkId: chunkId,
    contentSha256: contentSha256,
  );
}

void main() {
  group('ProxyGraphExtractionGateway request shape (mocked http)', () {
    test('POSTs the proxy graph-extract path on the configured base URL',
        () async {
      late http.Request seen;
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(_proxy200Body(), 200,
              headers: <String, String>{'content-type': 'application/json'});
        }),
      );

      await _callGateway(gateway);

      expect(seen.method, 'POST');
      expect(seen.url.path, advisorGraphExtractPath);
      expect(seen.url.path, '/v1/admin/graph/extract');
      // HP#7: target is the proxy, never api.anthropic.com.
      expect(seen.url.host, 'proxy.example');
      expect(seen.url.toString().contains('anthropic.com'), isFalse);
    });

    test('joins a base URL that already has a trailing path without doubling',
        () async {
      late http.Request seen;
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example/base/'),
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(_proxy200Body(), 200,
              headers: <String, String>{'content-type': 'application/json'});
        }),
      );

      await _callGateway(gateway);

      expect(seen.url.path, '/base/v1/admin/graph/extract');
      expect(seen.url.path.contains('//'), isFalse);
    });

    test('sends bearer token, Idempotency-Key, and JSON content-type headers',
        () async {
      late http.Request seen;
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(_proxy200Body(), 200,
              headers: <String, String>{'content-type': 'application/json'});
        }),
      );

      await _callGateway(gateway, apiKey: 'super-secret-proxy-token');

      // http lowercases header keys when read back.
      expect(seen.headers['authorization'], 'Bearer super-secret-proxy-token');
      final idem = seen.headers['idempotency-key'];
      expect(idem, isNotNull);
      expect(idem, isNotEmpty);
      expect(seen.headers['content-type'], contains('application/json'));
    });

    test('Idempotency-Key is stable for the same content + chunk (retry dedup)',
        () {
      final a = ProxyGraphExtractionGateway.idempotencyKeyFor(
        contentSha256: 'sha-xyz',
        chunkId: 'chunk-9',
      );
      final b = ProxyGraphExtractionGateway.idempotencyKeyFor(
        contentSha256: 'sha-xyz',
        chunkId: 'chunk-9',
      );
      final different = ProxyGraphExtractionGateway.idempotencyKeyFor(
        contentSha256: 'sha-xyz',
        chunkId: 'chunk-10',
      );
      expect(a, b);
      expect(a, isNot(different));
      expect(a, startsWith('graph-extract-'));
    });

    test('request body carries every field the proxy route requires', () async {
      late http.Request seen;
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          seen = request;
          return http.Response(_proxy200Body(), 200,
              headers: <String, String>{'content-type': 'application/json'});
        }),
      );

      await _callGateway(gateway, chunkId: 'chunk-77', contentSha256: 'sha-77');

      final body = jsonDecode(seen.body) as Map<String, Object?>;
      expect(body['chunk_text'], 'CPLH must stay above 85.');
      expect(body['chunk_id'], 'chunk-77');
      expect(body['content_sha256'], 'sha-77');
      expect(body['document_title'], 'Sample Handbook');
      expect(body['source_path'], 'docs/Knowledge_graph_docs/sample.md');
      expect(body['heading_path'], <String>['Food Safety']);
      expect(body['model'], 'claude-haiku-4-5');
    });
  });

  group('ProxyGraphExtractionGateway response parsing (mocked http)', () {
    test('maps proxy 200 nodes/edges + token counts into the tool model',
        () async {
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            _proxy200Body(inputTokens: 444, outputTokens: 111),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final result = await _callGateway(gateway);

      expect(result.nodes, hasLength(2));
      expect(result.nodes.first.nodeKey, 'CPLH');
      expect(result.nodes.first.kind, 'Metric');
      expect(result.nodes.first.label, 'EXTRACTED');
      expect(result.nodes.first.verbatimText, 'CPLH must stay above 85.');
      expect(result.nodes[1].label, 'INFERRED');

      expect(result.edges, hasLength(1));
      expect(result.edges.first.fromNodeKey, 'CPLH');
      expect(result.edges.first.toNodeKey, 'food-safety');
      expect(result.edges.first.edgeType, 'INFORMS');
      expect(result.edges.first.label, 'EXTRACTED');

      // HP#9: token counts come straight from the proxy-reported usage.
      expect(result.estimatedInputTokens, 444);
      expect(result.estimatedOutputTokens, 111);
    });

    test('skips nodes with empty node_key and edges missing endpoints',
        () async {
      final body = jsonEncode(<String, Object?>{
        'input_tokens': 10,
        'output_tokens': 5,
        'nodes': <Map<String, Object?>>[
          <String, Object?>{
            'node_key': '',
            'kind': 'Concept',
            'label': 'EXTRACTED',
            'verbatim_text': 'x',
          },
          <String, Object?>{
            'node_key': 'kept',
            'kind': 'Concept',
            'label': 'EXTRACTED',
            'verbatim_text': 'x',
          },
        ],
        'edges': <Map<String, Object?>>[
          <String, Object?>{
            'from_node_key': '',
            'to_node_key': 'b',
            'edge_type': 'RELATES_TO',
            'label': 'EXTRACTED',
            'verbatim_text': 'x',
          },
        ],
      });
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          return http.Response(body, 200,
              headers: <String, String>{'content-type': 'application/json'});
        }),
      );

      final result = await _callGateway(gateway);
      expect(result.nodes, hasLength(1));
      expect(result.nodes.first.nodeKey, 'kept');
      expect(result.edges, isEmpty);
    });

    test('absent token counts parse to zero (fail-open)', () async {
      final body = jsonEncode(<String, Object?>{
        'nodes': const <Object?>[],
        'edges': const <Object?>[],
      });
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          return http.Response(body, 200,
              headers: <String, String>{'content-type': 'application/json'});
        }),
      );

      final result = await _callGateway(gateway);
      expect(result.nodes, isEmpty);
      expect(result.edges, isEmpty);
      expect(result.estimatedInputTokens, 0);
      expect(result.estimatedOutputTokens, 0);
    });
  });

  group('ProxyGraphExtractionGateway error handling (mocked http)', () {
    test('mocked 503 (key unavailable) surfaces a CorpusManifestException',
        () async {
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'graph_extract_key_unavailable',
              'message': 'Anthropic API key is not configured server-side.',
            }),
            503,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      await expectLater(
        _callGateway(gateway),
        throwsA(
          isA<CorpusManifestException>().having(
            (e) => e.message,
            'message',
            allOf(contains('503'), contains('chunk chunk-1')),
          ),
        ),
      );
    });

    test('mocked 400 (unsupported_model) surfaces a CorpusManifestException',
        () async {
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'unsupported_model',
              'message': 'model must be one of: claude-haiku-4-5',
            }),
            400,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      await expectLater(
        _callGateway(gateway),
        throwsA(
          isA<CorpusManifestException>().having(
            (e) => e.message,
            'message',
            contains('400'),
          ),
        ),
      );
    });

    test('mocked 403 (permission_denied) surfaces a CorpusManifestException',
        () async {
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          return http.Response(
            jsonEncode(<String, Object?>{
              'error': 'permission_denied',
              'message': 'caller lacks the required role',
            }),
            403,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      await expectLater(
        _callGateway(gateway),
        throwsA(isA<CorpusManifestException>()),
      );
    });

    test('non-JSON 200 body surfaces a CorpusManifestException', () async {
      final gateway = ProxyGraphExtractionGateway(
        proxyBaseUrl: Uri.parse('https://proxy.example'),
        httpClient: http_testing.MockClient((request) async {
          return http.Response('not json at all', 200,
              headers: <String, String>{'content-type': 'application/json'});
        }),
      );

      await expectLater(
        _callGateway(gateway),
        throwsA(
          isA<CorpusManifestException>().having(
            (e) => e.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
    });
  });
}
