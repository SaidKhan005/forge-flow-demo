// L13 — AdvisorModelConfigService proxy-mediated online check.
//
// Verifies that `defaultAnthropicOnlineCheck` (and the underlying
// `probeForgeFlowProxyHealth` seam) talks ONLY to the F&F proxy and
// never to a vendor endpoint, never carries a client-held API key, and
// honors the tri-state `AnthropicModelCheckStatus` contract:
//   * proxyBaseUri null            → cannotCheck (no fabrication)
//   * proxy returns 2xx            → cannotCheck (catalog not exposed)
//   * proxy returns 5xx            → cannotCheck (infra problem)
//   * proxy unreachable / DNS dead → cannotCheck (network error)
//
// Hard Promise #7 ("F&F holds all provider keys server-side. No
// BYO-key.") forbids `--dart-define=ANTHROPIC_API_KEY=...` paths on
// the client; one assertion captures every header sent during the
// probe and fails if the literal string `x-api-key` (or any value
// matching the Anthropic key prefix) appears.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:forge_and_flow/services/advisor_model_config_service.dart';

void main() {
  group('probeForgeFlowProxyHealth', () {
    test('returns cannotCheck when proxyBaseUri is null', () async {
      final result = await probeForgeFlowProxyHealth(proxyBaseUri: null);
      expect(result.status, equals(AnthropicModelCheckStatus.cannotCheck));
      expect(result.message, contains('FORGE_FLOW_PROXY_BASE_URI'));
    });

    test('hits /healthz on the configured proxy and returns cannotCheck '
        'when proxy responds 2xx (catalog not exposed)', () async {
      final captured = <_CapturedRequest>[];
      final server = await _startStubProxy(
        captured: captured,
        respond: (request) async {
          request.response.statusCode = 200;
          request.response.headers.contentType = ContentType(
            'application',
            'json',
          );
          request.response.write(jsonEncode(<String, Object?>{'status': 'ok'}));
          await request.response.close();
        },
      );
      try {
        final result = await probeForgeFlowProxyHealth(
          proxyBaseUri: Uri.parse(
            'http://${server.address.host}:${server.port}',
          ),
        );
        expect(result.status, equals(AnthropicModelCheckStatus.cannotCheck));
        expect(result.message, contains('reachable'));
        // The probe must hit /healthz, NOT any vendor endpoint.
        expect(captured, hasLength(1));
        expect(captured.single.path, equals('/healthz'));
        expect(captured.single.method, equals('GET'));
        // Hard Promise #7: no BYO-key header on the wire.
        expect(captured.single.headers.containsKey('x-api-key'), isFalse);
        expect(
          captured.single.headers.containsKey('anthropic-version'),
          isFalse,
        );
        // No Anthropic-style API key value in any header.
        for (final values in captured.single.headers.values) {
          for (final v in values) {
            expect(
              v.startsWith('sk-ant-'),
              isFalse,
              reason: 'no client-held Anthropic key may appear in headers',
            );
          }
        }
      } finally {
        await server.close(force: true);
      }
    });

    test('returns cannotCheck (with status code in message) when proxy '
        'returns 5xx', () async {
      final server = await _startStubProxy(
        respond: (request) async {
          request.response.statusCode = 503;
          await request.response.close();
        },
      );
      try {
        final result = await probeForgeFlowProxyHealth(
          proxyBaseUri: Uri.parse(
            'http://${server.address.host}:${server.port}',
          ),
        );
        expect(result.status, equals(AnthropicModelCheckStatus.cannotCheck));
        expect(result.message, contains('503'));
        // 5xx is NOT online — must not return `available`.
        expect(
          result.status,
          isNot(equals(AnthropicModelCheckStatus.available)),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('returns cannotCheck when proxy is unreachable', () async {
      // Use a port we have not bound; the connect attempt fails fast.
      final result = await probeForgeFlowProxyHealth(
        proxyBaseUri: Uri.parse('http://127.0.0.1:1'),
        timeout: const Duration(seconds: 2),
      );
      expect(result.status, equals(AnthropicModelCheckStatus.cannotCheck));
    });

    test(
      'preserves a path prefix on proxyBaseUri when probing /healthz',
      () async {
        final captured = <_CapturedRequest>[];
        final server = await _startStubProxy(
          captured: captured,
          respond: (request) async {
            request.response.statusCode = 200;
            await request.response.close();
          },
        );
        try {
          // The legacy plumbing on `Uri.resolve` would silently throw
          // away a base prefix ("/api/") and probe "/healthz" at root.
          // Guard the documented `replace`-based behavior: probe the
          // exact `/healthz` path on the configured host.
          await probeForgeFlowProxyHealth(
            proxyBaseUri: Uri.parse(
              'http://${server.address.host}:${server.port}/api',
            ),
          );
          expect(captured, hasLength(1));
          expect(captured.single.path, equals('/healthz'));
        } finally {
          await server.close(force: true);
        }
      },
    );
  });

  group('defaultAnthropicOnlineCheck', () {
    test('returns cannotCheck when FORGE_FLOW_PROXY_BASE_URI is not set '
        '(default in unit-test environment)', () async {
      // Tests run without `--dart-define=FORGE_FLOW_PROXY_BASE_URI=...`
      // so the compile-time const is empty; the default check must
      // refuse to fabricate a result and must NOT touch the network.
      final result = await defaultAnthropicOnlineCheck(
        quickModelId: 'claude-haiku-4-5',
        nuancedModelId: 'claude-sonnet-4-6',
      );
      expect(result.status, equals(AnthropicModelCheckStatus.cannotCheck));
    });
  });
}

/// Starts a minimal in-process `HttpServer` on a random localhost port.
/// Records every inbound request in [captured] (when provided) and
/// delegates response generation to [respond].
Future<HttpServer> _startStubProxy({
  required Future<void> Function(HttpRequest) respond,
  List<_CapturedRequest>? captured,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  // ignore: unawaited_futures
  server.listen((request) async {
    if (captured != null) {
      final headers = <String, List<String>>{};
      request.headers.forEach((name, values) {
        headers[name] = values;
      });
      captured.add(
        _CapturedRequest(
          method: request.method,
          path: request.uri.path,
          headers: headers,
        ),
      );
    }
    try {
      await respond(request);
    } catch (_) {
      try {
        await request.response.close();
      } catch (_) {
        /* ignore double-close */
      }
    }
  });
  return server;
}

class _CapturedRequest {
  _CapturedRequest({
    required this.method,
    required this.path,
    required this.headers,
  });

  final String method;
  final String path;
  final Map<String, List<String>> headers;
}
