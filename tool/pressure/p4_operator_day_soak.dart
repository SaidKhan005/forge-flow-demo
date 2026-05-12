// Phase 4 — synthetic "operator day" workload soak harness against
// the preview proxy. R3 §5 calls this lane out as the integration
// surface that catches integration-level bugs the per-route lanes
// (`p3*`, `p4_session_soak`) miss.
//
// Sprint: `pressure.preview.v1` Phase 3 of 4 stack levels (B2 of the
// post-Codex addendum). Per-operator state machine traces a real
// daily journey:
//
//   sign-in → fetch dashboard → check notifications → settings nav →
//   sign-out → think → repeat.
//
// Each successful sign-in calls the shared
// `SessionRecordCompleteness.assertComplete` predicate (Bug A
// regression class). Each step records latency + status; the lane's
// `--duration` cap bounds wall-clock so the harness can be exercised
// in CI smoke without burning preview quota.
//
// What this lane proves (or surfaces holes in)
// ---------------------------------------------
//   1. The proxy returns a complete session record on every
//      successful sign-in across the full daily journey (Bug A class).
//   2. The proxy survives the sustained mixed-route traffic without
//      escaping uncaught errors to the root zone (Bug B class).
//   3. Multi-step flow integrity: when one step fails (e.g., 401 on
//      sign-in), subsequent steps are skipped — not retried into a
//      tight loop that floods the proxy with garbage traffic.
//
// Output
// ------
//   * `test/load/pressure/p4_operator_day_soak_raw.jsonl`
//   * `test/load/pressure/p4_operator_day_soak_findings.jsonl`
//   * `test/load/pressure/p4_operator_day_soak_summary.md`
//
// Usage
// -----
//   dart run tool/pressure/p4_operator_day_soak.dart \
//     --ops=10 --duration=10min --proxy-url=https://localhost:8080
//
//   dart run tool/pressure/p4_operator_day_soak.dart \
//     --ops=50 --duration=2h --concurrency=20   # full-scale

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'p4_session_record_predicate.dart';

const String kHarnessUserAgent =
    'forge-flow-pressure-preview-v1/p4-operator-day-soak';

const String kFlutterWebUa = 'forge-flow-flutter-web/p4-operator-day-soak';
const String kFlutterMobileUa = 'forge-flow-flutter-mobile/p4-operator-day-soak';

const int kDefaultOps = 5;
const int kDefaultConcurrency = 5;
const String kDefaultDuration = '60s';

class _Args {
  _Args({
    required this.proxyUrl,
    required this.ops,
    required this.concurrency,
    required this.durationSeconds,
    required this.outputDir,
    required this.thinkTimeMs,
  });

  final String proxyUrl;
  final int ops;
  final int concurrency;
  final int durationSeconds;
  final String outputDir;
  final int thinkTimeMs;
}

_Args _parseArgs(List<String> args) {
  String proxyUrl = Platform.environment['FF_PRESSURE_PROXY_URL']?.trim() ?? '';
  int ops = kDefaultOps;
  int concurrency = kDefaultConcurrency;
  int durationSeconds = parseSoakDurationSeconds(kDefaultDuration);
  String outputDir = 'test/load/pressure';
  int thinkTimeMs = 1500;

  for (final raw in args) {
    if (!raw.startsWith('--')) continue;
    final eq = raw.indexOf('=');
    if (eq <= 0) continue;
    final key = raw.substring(2, eq);
    final value = raw.substring(eq + 1);
    switch (key) {
      case 'proxy-url':
        proxyUrl = value.trim();
        break;
      case 'ops':
        ops = int.parse(value);
        break;
      case 'concurrency':
        concurrency = int.parse(value);
        break;
      case 'duration':
        durationSeconds = parseSoakDurationSeconds(value);
        break;
      case 'output-dir':
        outputDir = value;
        break;
      case 'think-ms':
        thinkTimeMs = int.parse(value);
        break;
      default:
        stderr.writeln('warning: unknown flag --$key');
    }
  }

  if (proxyUrl.isEmpty) {
    proxyUrl = 'http://localhost:8080';
  }

  return _Args(
    proxyUrl: proxyUrl,
    ops: ops,
    concurrency: concurrency,
    durationSeconds: durationSeconds,
    outputDir: outputDir,
    thinkTimeMs: thinkTimeMs,
  );
}

String _deterministicUuid(String role, int ordinal, String salt) {
  final raw = '$role-$ordinal-$salt';
  final digest = sha256.convert(utf8.encode(raw)).bytes;
  final hex = digest
      .sublist(0, 16)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final mutable = hex.codeUnits.toList();
  mutable[12] = '4'.codeUnitAt(0);
  mutable[16] = '8'.codeUnitAt(0);
  final fixed = String.fromCharCodes(mutable);
  return '${fixed.substring(0, 8)}-'
      '${fixed.substring(8, 12)}-'
      '${fixed.substring(12, 16)}-'
      '${fixed.substring(16, 20)}-'
      '${fixed.substring(20, 32)}';
}

String _placeholderJwt({
  required String userId,
  required String operatorId,
  required String locationId,
  required Set<String> roles,
}) {
  final header = base64Url
      .encode(utf8.encode(jsonEncode(<String, Object?>{
        'alg': 'none',
        'typ': 'JWT',
      })))
      .replaceAll('=', '');
  final payload = base64Url
      .encode(utf8.encode(jsonEncode(<String, Object?>{
        'sub': userId,
        'user_id': userId,
        'operator_id': operatorId,
        'location_id': locationId,
        if (roles.contains('ff_support')) 'is_ff_support': true,
        if (roles.contains('super_admin')) 'is_super_admin': true,
        'iat': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        'exp': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch ~/
            1000,
      })))
      .replaceAll('=', '');
  return '$header.$payload.placeholder';
}

class _OperatorState {
  _OperatorState({
    required this.ordinal,
    required this.userId,
    required this.operatorId,
    required this.locationId,
    required this.roles,
    required this.userAgent,
  });

  final int ordinal;
  final String userId;
  final String operatorId;
  final String locationId;
  final Set<String> roles;
  final String userAgent;
}

class _StepRecord {
  _StepRecord({
    required this.operatorOrdinal,
    required this.step,
    required this.route,
    required this.statusCode,
    required this.latencyMs,
    required this.assertionComplete,
    required this.missingFields,
    required this.responseExcerpt,
    required this.timestamp,
    required this.errorKind,
  });

  final int operatorOrdinal;
  final String step;
  final String route;
  final int statusCode;
  final int latencyMs;
  final bool? assertionComplete;
  final List<String> missingFields;
  final String responseExcerpt;
  final DateTime timestamp;
  final String errorKind;

  Map<String, Object?> toJson() => <String, Object?>{
        'ts': timestamp.toIso8601String(),
        'operator_ordinal': operatorOrdinal,
        'step': step,
        'route': route,
        'status_code': statusCode,
        'latency_ms': latencyMs,
        'assertion_complete': assertionComplete,
        'missing_fields': missingFields,
        'response_excerpt': responseExcerpt,
        'error_kind': errorKind,
      };
}

Future<_StepRecord> _doStep({
  required HttpClient client,
  required Uri baseUrl,
  required String path,
  required String method,
  required String step,
  required _OperatorState state,
  required String jwt,
  Map<String, Object?>? body,
}) async {
  final url = baseUrl.replace(path: path);
  final start = DateTime.now();
  try {
    final req = method == 'POST'
        ? await client
            .postUrl(url)
            .timeout(const Duration(seconds: 15))
        : await client
            .getUrl(url)
            .timeout(const Duration(seconds: 15));
    req.headers.set('authorization', 'Bearer $jwt');
    req.headers.set('user-agent', state.userAgent);
    req.headers.set('x-pressure-test-lane', 'p4-operator-day-soak');
    req.headers.set('x-pressure-step', step);
    if (body != null) {
      req.headers.set('content-type', 'application/json');
      req.add(utf8.encode(jsonEncode(body)));
    }
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final bytes = <int>[];
    await for (final chunk in resp) {
      bytes.addAll(chunk);
      if (bytes.length > 4096) break;
    }
    final excerpt = utf8
        .decode(bytes, allowMalformed: true)
        .replaceAll('\n', ' ')
        .trim();
    final latency = DateTime.now().difference(start).inMilliseconds;
    SessionRecordAssertion? assertion;
    if (step == 'sign_in' && resp.statusCode == 200) {
      try {
        final decoded = jsonDecode(excerpt);
        if (decoded is Map<String, Object?>) {
          assertion = SessionRecordCompleteness.assertComplete(
            decoded,
            roles: state.roles,
          );
        }
      } catch (_) {
        // Malformed JSON in a 200; assertion stays null.
      }
    }
    return _StepRecord(
      operatorOrdinal: state.ordinal,
      step: step,
      route: path,
      statusCode: resp.statusCode,
      latencyMs: latency,
      assertionComplete: assertion?.complete,
      missingFields: assertion?.missingFields ?? const <String>[],
      responseExcerpt: excerpt.length > 240 ? excerpt.substring(0, 240) : excerpt,
      timestamp: start.toUtc(),
      errorKind: '',
    );
  } on TimeoutException {
    return _StepRecord(
      operatorOrdinal: state.ordinal,
      step: step,
      route: path,
      statusCode: -1,
      latencyMs: DateTime.now().difference(start).inMilliseconds,
      assertionComplete: null,
      missingFields: const <String>[],
      responseExcerpt: 'TIMEOUT',
      timestamp: start.toUtc(),
      errorKind: 'timeout',
    );
  } catch (e) {
    return _StepRecord(
      operatorOrdinal: state.ordinal,
      step: step,
      route: path,
      statusCode: -1,
      latencyMs: DateTime.now().difference(start).inMilliseconds,
      assertionComplete: null,
      missingFields: const <String>[],
      responseExcerpt: 'ERR: ${e.toString().split('\n').first}',
      timestamp: start.toUtc(),
      errorKind: 'network_error',
    );
  }
}

Future<int> runHarness(List<String> args) async {
  final opts = _parseArgs(args);

  if (!isSoakProxyUrlAllowed(opts.proxyUrl)) {
    stderr.writeln(
      'FATAL: proxy URL "${opts.proxyUrl}" is not a preview/staging/local '
      'URL. Refusing to run pressure load against an unknown target.',
    );
    return 2;
  }

  final outputDir = Directory(opts.outputDir);
  outputDir.createSync(recursive: true);
  final rawSink =
      File('${outputDir.path}/p4_operator_day_soak_raw.jsonl')
          .openWrite(mode: FileMode.write);
  final findings = <SoakFinding>[];
  final records = <_StepRecord>[];

  final runSalt = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[^\w]'), '_');

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);

  final baseUrl = Uri.parse(opts.proxyUrl);

  final operators = <_OperatorState>[
    for (var i = 0; i < opts.ops; i++)
      _OperatorState(
        ordinal: i,
        userId: _deterministicUuid('user', i, runSalt),
        operatorId: _deterministicUuid('operator', i, runSalt),
        locationId: _deterministicUuid('location', i, runSalt),
        roles: <String>{},
        userAgent: (i % 2 == 0) ? kFlutterWebUa : kFlutterMobileUa,
      ),
  ];

  stdout.writeln('=== p4_operator_day_soak plan ===');
  stdout.writeln('  proxy: ${opts.proxyUrl}');
  stdout.writeln('  ops: ${opts.ops}');
  stdout.writeln('  concurrency: ${opts.concurrency}');
  stdout.writeln('  duration: ${opts.durationSeconds}s');
  stdout.writeln('  think-ms: ${opts.thinkTimeMs}');
  stdout.writeln('===\n');

  final shutdown = SoakShutdownSignal();
  late StreamSubscription<ProcessSignal> sigintSub;
  sigintSub = ProcessSignal.sigint.watch().listen((_) {
    stderr.writeln('SIGINT received — draining in-flight requests');
    shutdown.fire();
  });

  final runStart = DateTime.now();
  final hardEnd = runStart.add(Duration(seconds: opts.durationSeconds));
  final rng = math.Random(0xDA12);

  Future<void> operatorDay(_OperatorState state) async {
    while (!shutdown.isFired && DateTime.now().isBefore(hardEnd)) {
      final jwt = _placeholderJwt(
        userId: state.userId,
        operatorId: state.operatorId,
        locationId: state.locationId,
        roles: state.roles,
      );
      final tokenHash =
          sha256.convert(utf8.encode(jwt)).toString();

      // 1) Sign-in.
      final signIn = await _doStep(
        client: client,
        baseUrl: baseUrl,
        path: '/v1/auth/session/login',
        method: 'POST',
        step: 'sign_in',
        state: state,
        jwt: jwt,
        body: <String, Object?>{'token_hash': tokenHash},
      );
      records.add(signIn);
      rawSink.writeln(jsonEncode(signIn.toJson()));

      if (signIn.statusCode == 200 && signIn.assertionComplete == false) {
        findings.add(SoakFinding(
          category: 'incomplete_session_record',
          detail: 'sign_in 200 returned an incomplete session record',
          evidence: <String, Object?>{
            'operator_ordinal': signIn.operatorOrdinal,
            'missing_fields': signIn.missingFields,
            'response_excerpt': signIn.responseExcerpt,
          },
        ));
      }

      // Multi-step integrity guard: skip downstream steps unless
      // sign-in succeeded with status 200. The proxy verifier will
      // reject placeholder JWTs with 401 in default deployments, so
      // the common path here is "sign-in returned 401, skip and
      // think". This prevents the harness from amplifying garbage
      // traffic on broken auth.
      if (signIn.statusCode == 200) {
        // 2) Fetch /v1/auth/account (dashboard prime).
        records.add(await _doStep(
          client: client,
          baseUrl: baseUrl,
          path: '/v1/auth/account',
          method: 'GET',
          step: 'dashboard',
          state: state,
          jwt: jwt,
        ));
        rawSink.writeln(jsonEncode(records.last.toJson()));

        // 3) Check notifications (/v1/operator/notification-preferences
        //    is a read-only operator scope; close enough for an
        //    integration shape probe).
        records.add(await _doStep(
          client: client,
          baseUrl: baseUrl,
          path: '/v1/operator/notification-preferences',
          method: 'GET',
          step: 'notifications',
          state: state,
          jwt: jwt,
        ));
        rawSink.writeln(jsonEncode(records.last.toJson()));

        // 4) Settings nav — hit /healthz as a stand-in for "fetch
        //    settings snapshot" since the harness does not have real
        //    auth and the settings route requires fresh-MFA. Still
        //    exercises the proxy's request loop the same way.
        records.add(await _doStep(
          client: client,
          baseUrl: baseUrl,
          path: '/healthz',
          method: 'GET',
          step: 'settings_nav',
          state: state,
          jwt: jwt,
        ));
        rawSink.writeln(jsonEncode(records.last.toJson()));

        // 5) Sign-out (placeholder — POSTs the same body to the
        //    session refresh path; without a real session_id this
        //    will 400 / 401, which is correct for the harness).
        records.add(await _doStep(
          client: client,
          baseUrl: baseUrl,
          path: '/v1/auth/session/refresh',
          method: 'POST',
          step: 'sign_out',
          state: state,
          jwt: jwt,
          body: <String, Object?>{'session_id': ''},
        ));
        rawSink.writeln(jsonEncode(records.last.toJson()));
      }

      // Think-time jitter: ±25%.
      final jitterRange = (opts.thinkTimeMs * 0.5).round();
      final delay = math.max(
        100,
        opts.thinkTimeMs +
            (rng.nextInt(2 * jitterRange + 1) - jitterRange),
      );
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
  }

  final workerCount = math.min(opts.concurrency, opts.ops);
  final workers = <Future<void>>[];
  for (var w = 0; w < workerCount; w++) {
    workers.add(() async {
      var i = w;
      while (!shutdown.isFired && DateTime.now().isBefore(hardEnd)) {
        await operatorDay(operators[i % operators.length]);
        i += workerCount;
      }
    }());
  }

  Timer.periodic(const Duration(seconds: 30), (timer) {
    if (shutdown.isFired || !DateTime.now().isBefore(hardEnd)) {
      timer.cancel();
      return;
    }
    final n = records.length;
    final completedJourneys =
        records.where((r) => r.step == 'sign_out').length;
    final incomplete =
        records.where((r) => r.assertionComplete == false).length;
    stdout.writeln(
      '[checkpoint @ ${DateTime.now().toIso8601String()}] '
      'requests=$n journeys=$completedJourneys '
      'incomplete=$incomplete',
    );
  });

  await Future.any(<Future<void>>[
    Future.wait(workers, eagerError: false),
    shutdown.future,
  ]);
  shutdown.fire();
  await Future.wait(workers, eagerError: false);

  await sigintSub.cancel();
  await rawSink.flush();
  await rawSink.close();
  client.close(force: true);

  final findingsFile =
      File('${outputDir.path}/p4_operator_day_soak_findings.jsonl');
  findingsFile.writeAsStringSync(
    findings.map((f) => jsonEncode(f.toJson())).join('\n') +
        (findings.isEmpty ? '' : '\n'),
  );

  final n = records.length;
  final journeysCompleted =
      records.where((r) => r.step == 'sign_out').length;
  final incomplete = records.where((r) => r.assertionComplete == false).length;
  final serverErr = records.where((r) => r.statusCode >= 500).length;
  final summary = StringBuffer()
    ..writeln('# p4_operator_day_soak — summary')
    ..writeln()
    ..writeln('Proxy: `${opts.proxyUrl}`')
    ..writeln('Started: ${runStart.toUtc().toIso8601String()}')
    ..writeln('Ended:   ${DateTime.now().toUtc().toIso8601String()}')
    ..writeln(
      'Ops: ${opts.ops}  concurrency: ${opts.concurrency}  '
      'duration: ${opts.durationSeconds}s',
    )
    ..writeln()
    ..writeln('| Metric | Value |')
    ..writeln('|---|---|')
    ..writeln('| Total step requests | $n |')
    ..writeln('| Completed journeys | $journeysCompleted |')
    ..writeln('| 5xx responses | $serverErr |')
    ..writeln('| **incomplete sign-in records** | $incomplete |')
    ..writeln()
    ..writeln('Findings: ${findings.length}');
  File('${outputDir.path}/p4_operator_day_soak_summary.md')
      .writeAsStringSync(summary.toString());
  stdout.writeln('\n${summary.toString()}\n');
  stdout.writeln('Findings JSONL: ${findingsFile.path}');
  stdout.writeln('Summary MD: '
      '${outputDir.path}/p4_operator_day_soak_summary.md');
  stdout.writeln('Raw JSONL: '
      '${outputDir.path}/p4_operator_day_soak_raw.jsonl');

  if (incomplete > 0) {
    stderr.writeln('FAIL: $incomplete incomplete session records observed');
    return 3;
  }
  return 0;
}

Future<void> main(List<String> args) async {
  final exitCodeValue = await runHarness(args);
  exit(exitCodeValue);
}
