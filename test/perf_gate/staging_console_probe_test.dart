import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/perf_gate/staging_console_probe.dart';

void main() {
  test('percentile uses nearest-rank boundaries', () {
    expect(percentile(<double>[10, 20, 30], 50), 20);
    expect(percentile(<double>[100, 200, 300, 400], 95), 400);
    expect(percentile(<double>[], 99), 0);
  });

  test('probe plan keeps health off unless explicitly requested', () {
    final config = StagingProbeConfig(
      run: true,
      showHelp: false,
      jsonOnly: false,
      enforceBudgets: false,
      includeHealth: false,
      healthTotal: 3,
      healthConcurrency: 1,
      timeout: const Duration(seconds: 5),
      adminUrl: Uri.parse('https://admin.example.test'),
      proxyUrl: Uri.parse('https://proxy.example.test'),
    );

    expect(
      buildProbePlan(config).map((spec) => spec.name),
      isNot(contains(startsWith('proxy_health'))),
    );

    final withHealth = StagingProbeConfig(
      run: true,
      showHelp: false,
      jsonOnly: false,
      enforceBudgets: false,
      includeHealth: true,
      healthTotal: 4,
      healthConcurrency: 2,
      timeout: const Duration(seconds: 5),
      adminUrl: Uri.parse('https://admin.example.test'),
      proxyUrl: Uri.parse('https://proxy.example.test'),
    );

    expect(
      buildProbePlan(withHealth).map((spec) => spec.name),
      contains('proxy_health_c2_safe'),
    );
  });

  test('parser caps optional health load for staging safety', () {
    expect(
      () => StagingProbeConfig.parse(<String>[
        '--run',
        '--admin-url=https://admin.example.test',
        '--proxy-url=https://proxy.example.test',
        '--include-health',
        '--health-total=7',
      ]),
      throwsA(isA<UsageException>()),
    );
    expect(
      () => StagingProbeConfig.parse(<String>[
        '--run',
        '--admin-url=https://admin.example.test',
        '--proxy-url=https://proxy.example.test',
        '--include-health',
        '--health-concurrency=3',
      ]),
      throwsA(isA<UsageException>()),
    );
  });

  test('budget failures surface when a guarded probe regresses', () {
    final result = ProbeResult(
      spec: ProbeSpec(
        name: 'admin_index_c4',
        uri: Uri.parse('https://admin.example.test'),
        totalRequests: 1,
        concurrency: 1,
        timeout: const Duration(seconds: 5),
      ),
      samples: const <ProbeSample>[
        ProbeSample(statusCode: 200, latencyMs: 900, bytes: 10),
      ],
    );

    expect(result.budgetFailures, contains(contains('p95')));
  });

  test(
    'runProbe records status counts, latency, and gzip transfer bytes',
    () async {
      final server = await _ProbeServer.start();
      addTearDown(server.close);

      final result = await HttpOverrides.runWithHttpOverrides(
        () => runProbe(
          ProbeSpec(
            name: 'main_js',
            uri: server.baseUri.resolve('/main.dart.js'),
            totalRequests: 4,
            concurrency: 2,
            timeout: const Duration(seconds: 5),
            headers: const <String, String>{'Accept-Encoding': 'gzip'},
          ),
        ),
        _RealHttpOverrides(),
      );

      expect(result.successCount, 4);
      expect(result.statusCounts[200], 4);
      expect(result.p95Ms, greaterThanOrEqualTo(0));
      expect(result.minBytes, greaterThan(0));
      expect(result.maxBytes, lessThan(server.rawMainJsBytes));
    },
  );
}

class _RealHttpOverrides extends HttpOverrides {
  // Flutter tests install a fake HttpClient that returns 400 for all
  // traffic. This override deliberately restores the dart:io client
  // so the local loopback probe exercises real transfer bytes.
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

class _ProbeServer {
  _ProbeServer._(this._server, this.baseUri);

  final HttpServer _server;
  final Uri baseUri;
  final List<int> _mainJs = utf8.encode(
    List<String>.filled(1000, 'void main() {}\n').join(),
  );

  int get rawMainJsBytes => _mainJs.length;

  static Future<_ProbeServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final probeServer = _ProbeServer._(
      server,
      Uri.parse('http://${server.address.host}:${server.port}/'),
    );
    unawaited(probeServer._serve());
    return probeServer;
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _serve() async {
    await for (final request in _server) {
      if (request.uri.path == '/main.dart.js') {
        final acceptsGzip =
            request.headers
                .value(HttpHeaders.acceptEncodingHeader)
                ?.contains('gzip') ??
            false;
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType(
          'application',
          'javascript',
        );
        if (acceptsGzip) {
          request.response.headers.set(
            HttpHeaders.contentEncodingHeader,
            'gzip',
          );
          request.response.add(gzip.encode(_mainJs));
        } else {
          request.response.add(_mainJs);
        }
        await request.response.close();
        continue;
      }
      if (request.uri.path == '/readyz') {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('ok');
        await request.response.close();
        continue;
      }
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('not found');
      await request.response.close();
    }
  }
}
