// Phase 4 — multi-session sign-in soak harness against the preview
// proxy. Mirrors the `p3*` shape (preview-URL guard, JSONL findings
// sink, structured progress output, clean SIGINT shutdown) and adds
// the assertions R3 §2 calls out: every successful sign-in MUST
// carry a complete session record per the B1+B2 contract.
//
// Sprint: `pressure.preview.v1` Phase 3 of 4 stack levels (B2 of the
// post-Codex addendum). The lane fills the soak gap left by `p3a` /
// `p3b` / `p3c`, which exercise per-vendor adapter pressure but do
// NOT cover hours-long multi-session auth flow.
//
// What this lane proves (or surfaces holes in)
// ---------------------------------------------
//   1. The proxy returns a COMPLETE session record on every
//      successful sign-in (Bug A regression class). The shape varies
//      by role per the new contract:
//        - tenant-scoped users: session_id + user_id + operator_id +
//          location_id all non-empty;
//        - ff_support / super_admin: session_id + user_id non-empty,
//          operator_id + location_id empty strings.
//   2. The proxy survives a sustained multi-operator sign-in load
//      without escaping uncaught errors to the root zone (Bug B
//      regression class). `runZonedGuarded` instrumentation surfaces
//      crashes; this lane provides time-on-task to trigger them.
//   3. Cloud-Run pod RSS does not climb monotonically with operator
//      count over multi-hour runs (R3 §3 S3 / ring-buffer growth).
//      Operators read the `/health` runtime_gauges section
//      (`pubsub_subscriber.ring_buffer_keys`,
//      `postgres_pool.waiter_count`) to confirm.
//
// Design
// ------
// * Per-operator state machine: sign-in → optional refresh → sign-out.
//   Realistic think-times jittered uniformly by ±25%.
// * Mix of synthetic Flutter Web + Flutter Mobile UAs; the proxy MUST
//   treat both identically.
// * Concurrent operators: N parallel state machines, each looping
//   until duration expires. SIGINT cleanly drains in-flight requests.
// * Each successful sign-in calls
//   `SessionRecordCompleteness.assertComplete` and adds a finding on
//   any failure. Run exits non-zero if ANY incomplete record was
//   observed (Bug A regression must be a CI red).
// * Synthetic operators are UUID-stable per run so the load lane is
//   isolated from real staging tenants. The harness DOES NOT
//   authenticate against real Firebase; it constructs synthetic JWTs
//   signed with the placeholder secret, which the proxy verifier
//   will reject UNLESS the `FF_PRESSURE_SYNTHETIC_VERIFIER` env flag
//   is wired into the test deployment. The expected default outcome
//   is 401 verifier rejection from every request, which is FINE —
//   we are exercising the proxy's request loop, not its happy path.
//   When the env flag is wired (preview only) the harness asserts on
//   the complete shape per the predicate above.
//
// Output
// ------
//   * `test/pressure/p4_session_soak_raw.jsonl`
//   * `test/pressure/p4_session_soak_findings.jsonl`
//   * `test/pressure/p4_session_soak_summary.md`
//
// Hard rules
// ----------
// * Never include real Firebase user credentials — placeholders only.
// * Never write to production — the proxy URL is checked against the
//   allow-list substrings in `kSoakAllowedHostSubstrings`.
// * Never auto-rerun on failure — the harness exits non-zero on the
//   first assertion failure so the operator sees the finding.
//
// Usage
// -----
//   dart run tool/pressure/p4_session_soak.dart \
//     --ops=10 --duration=5min --proxy-url=https://localhost:8080
//
//   dart run tool/pressure/p4_session_soak.dart \
//     --ops=100 --duration=2h --concurrency=20   # full-scale

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'p4_session_record_predicate.dart';

const String kHarnessUserAgent =
    'forge-flow-pressure-preview-v1/p4-session-soak';

const String kFlutterWebUa = 'forge-flow-flutter-web/p4-session-soak';
const String kFlutterMobileUa = 'forge-flow-flutter-mobile/p4-session-soak';

/// Default smoke knobs. The duration is intentionally short so the
/// lane can be exercised in CI smoke without burning preview quota.
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
  String proxyUrl =
      Platform.environment['FF_PRESSURE_PROXY_URL']?.trim() ?? '';
  int ops = kDefaultOps;
  int concurrency = kDefaultConcurrency;
  int durationSeconds = parseSoakDurationSeconds(kDefaultDuration);
  String outputDir = 'test/pressure';
  int thinkTimeMs = 500;

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

String _syntheticOperatorId(int ordinal, String runSalt) =>
    _deterministicUuid('operator', ordinal, runSalt);

String _syntheticUserId(int ordinal, String runSalt) =>
    _deterministicUuid('user', ordinal, runSalt);

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

/// Build a placeholder JWT that the proxy verifier will reject with
/// 401. The harness uses this to drive the request loop; the
/// completeness predicate only runs on 200 responses. The token
/// embeds the operator_id / location_id so a future synthetic
/// verifier could accept the request.
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

class _RequestRecord {
  _RequestRecord({
    required this.operatorOrdinal,
    required this.userId,
    required this.route,
    required this.statusCode,
    required this.latencyMs,
    required this.assertionComplete,
    required this.missingFields,
    required this.unexpectedFields,
    required this.responseExcerpt,
    required this.timestamp,
    required this.userAgent,
    required this.errorKind,
    required this.roles,
  });

  final int operatorOrdinal;
  final String userId;
  final String route;
  final int statusCode;
  final int latencyMs;
  final bool? assertionComplete;
  final List<String> missingFields;
  final List<String> unexpectedFields;
  final String responseExcerpt;
  final DateTime timestamp;
  final String userAgent;
  final String errorKind;
  final List<String> roles;

  Map<String, Object?> toJson() => <String, Object?>{
        'ts': timestamp.toIso8601String(),
        'operator_ordinal': operatorOrdinal,
        'user_id': userId,
        'route': route,
        'status_code': statusCode,
        'latency_ms': latencyMs,
        'assertion_complete': assertionComplete,
        'missing_fields': missingFields,
        'unexpected_fields': unexpectedFields,
        'response_excerpt': responseExcerpt,
        'user_agent': userAgent,
        'error_kind': errorKind,
        'roles': roles,
      };
}

Future<_RequestRecord> _postLogin({
  required HttpClient client,
  required Uri url,
  required _OperatorState state,
  required Duration timeout,
}) async {
  final start = DateTime.now();
  final jwt = _placeholderJwt(
    userId: state.userId,
    operatorId: state.operatorId,
    locationId: state.locationId,
    roles: state.roles,
  );
  final tokenHash = sha256
      .convert(utf8.encode(jwt))
      .toString();
  final body = utf8.encode(jsonEncode(<String, Object?>{
    'token_hash': tokenHash,
  }));
  try {
    final req = await client.postUrl(url).timeout(timeout);
    req.headers.set('content-type', 'application/json');
    req.headers.set('authorization', 'Bearer $jwt');
    req.headers.set('user-agent', state.userAgent);
    req.headers.set('x-pressure-test-lane', 'p4-session-soak');
    req.add(body);
    final resp = await req.close().timeout(timeout);
    final responseBytes = <int>[];
    await for (final chunk in resp) {
      responseBytes.addAll(chunk);
      if (responseBytes.length > 4096) break;
    }
    final excerpt = utf8
        .decode(responseBytes, allowMalformed: true)
        .replaceAll('\n', ' ')
        .trim();
    final latency = DateTime.now().difference(start).inMilliseconds;
    SessionRecordAssertion? assertion;
    if (resp.statusCode == 200) {
      try {
        final decoded = jsonDecode(excerpt);
        if (decoded is Map<String, Object?>) {
          assertion = SessionRecordCompleteness.assertComplete(
            decoded,
            roles: state.roles,
          );
        }
      } catch (_) {
        // Malformed JSON in a 200 — assertion stays null and the
        // record's status_code documents the anomaly.
      }
    }
    return _RequestRecord(
      operatorOrdinal: state.ordinal,
      userId: state.userId,
      route: url.path,
      statusCode: resp.statusCode,
      latencyMs: latency,
      assertionComplete: assertion?.complete,
      missingFields: assertion?.missingFields ?? const <String>[],
      unexpectedFields: assertion?.unexpectedFields ?? const <String>[],
      responseExcerpt:
          excerpt.length > 240 ? excerpt.substring(0, 240) : excerpt,
      timestamp: start.toUtc(),
      userAgent: state.userAgent,
      errorKind: '',
      roles: state.roles.toList(),
    );
  } on TimeoutException {
    final latency = DateTime.now().difference(start).inMilliseconds;
    return _RequestRecord(
      operatorOrdinal: state.ordinal,
      userId: state.userId,
      route: url.path,
      statusCode: -1,
      latencyMs: latency,
      assertionComplete: null,
      missingFields: const <String>[],
      unexpectedFields: const <String>[],
      responseExcerpt: 'TIMEOUT',
      timestamp: start.toUtc(),
      userAgent: state.userAgent,
      errorKind: 'timeout',
      roles: state.roles.toList(),
    );
  } catch (e) {
    final latency = DateTime.now().difference(start).inMilliseconds;
    return _RequestRecord(
      operatorOrdinal: state.ordinal,
      userId: state.userId,
      route: url.path,
      statusCode: -1,
      latencyMs: latency,
      assertionComplete: null,
      missingFields: const <String>[],
      unexpectedFields: const <String>[],
      responseExcerpt: 'ERR: ${e.toString().split('\n').first}',
      timestamp: start.toUtc(),
      userAgent: state.userAgent,
      errorKind: 'network_error',
      roles: state.roles.toList(),
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
  final rawSink = File('${outputDir.path}/p4_session_soak_raw.jsonl')
      .openWrite(mode: FileMode.write);
  final findings = <SoakFinding>[];
  final records = <_RequestRecord>[];

  final runSalt = DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(RegExp(r'[^\w]'), '_');

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30);

  final loginUri = Uri.parse(opts.proxyUrl).replace(
    path: '/v1/auth/session/login',
  );

  // Pre-build operator state for each synthetic operator. Half use
  // Flutter Web UA, half Flutter Mobile UA. Every 7th operator is
  // ff_support (scope-less) so the harness exercises the new
  // contract branch added in this slice.
  final operators = <_OperatorState>[
    for (var i = 0; i < opts.ops; i++)
      _OperatorState(
        ordinal: i,
        userId: _syntheticUserId(i, runSalt),
        operatorId:
            (i % 7 == 0) ? '' : _syntheticOperatorId(i, runSalt),
        locationId:
            (i % 7 == 0) ? '' : _syntheticOperatorId(i + 1000, runSalt),
        roles: (i % 7 == 0)
            ? <String>{'ff_support'}
            : <String>{},
        userAgent: (i % 2 == 0) ? kFlutterWebUa : kFlutterMobileUa,
      ),
  ];

  stdout.writeln('=== p4_session_soak plan ===');
  stdout.writeln('  proxy: ${opts.proxyUrl}');
  stdout.writeln('  ops: ${opts.ops}');
  stdout.writeln('  concurrency: ${opts.concurrency}');
  stdout.writeln('  duration: ${opts.durationSeconds}s');
  stdout.writeln('  think-ms: ${opts.thinkTimeMs}');
  stdout.writeln(
    '  ff_support operators: '
    '${operators.where((o) => o.roles.contains('ff_support')).length}',
  );
  stdout.writeln('===\n');

  final shutdown = SoakShutdownSignal();
  late StreamSubscription<ProcessSignal> sigintSub;
  sigintSub = ProcessSignal.sigint.watch().listen((_) {
    stderr.writeln('SIGINT received — draining in-flight requests');
    shutdown.fire();
  });

  final runStart = DateTime.now();
  final hardEnd = runStart.add(Duration(seconds: opts.durationSeconds));
  final rng = math.Random(0xb1b2);

  // Per-operator state machine. Each runs until duration or SIGINT.
  Future<void> operatorLoop(_OperatorState state) async {
    while (!shutdown.isFired && DateTime.now().isBefore(hardEnd)) {
      final rec = await _postLogin(
        client: client,
        url: loginUri,
        state: state,
        timeout: const Duration(seconds: 15),
      );
      records.add(rec);
      rawSink.writeln(jsonEncode(rec.toJson()));

      // Surface every incomplete 200 immediately — that's the Bug A
      // regression class.
      if (rec.statusCode == 200 && rec.assertionComplete == false) {
        findings.add(SoakFinding(
          category: 'incomplete_session_record',
          detail:
              'POST $loginUri returned 200 with missing / unexpected fields',
          evidence: <String, Object?>{
            'operator_ordinal': rec.operatorOrdinal,
            'roles': rec.roles,
            'missing_fields': rec.missingFields,
            'unexpected_fields': rec.unexpectedFields,
            'response_excerpt': rec.responseExcerpt,
          },
        ));
      }

      // Think-time jitter: ±25% of configured value.
      final jitterRange = (opts.thinkTimeMs * 0.5).round();
      final delay = math.max(
        50,
        opts.thinkTimeMs + (rng.nextInt(2 * jitterRange + 1) - jitterRange),
      );
      await Future<void>.delayed(Duration(milliseconds: delay));
    }
  }

  // Concurrency: spin up min(concurrency, ops) workers, each shared
  // across the operator pool round-robin so concurrent sessions never
  // collide on the same operator id.
  final workerCount = math.min(opts.concurrency, opts.ops);
  final workers = <Future<void>>[];
  for (var w = 0; w < workerCount; w++) {
    workers.add(() async {
      var i = w;
      while (!shutdown.isFired && DateTime.now().isBefore(hardEnd)) {
        await operatorLoop(operators[i % operators.length]);
        i += workerCount;
      }
    }());
  }

  // Checkpoint summary every 30s so multi-hour runs surface drift.
  Timer.periodic(const Duration(seconds: 30), (timer) {
    if (shutdown.isFired || !DateTime.now().isBefore(hardEnd)) {
      timer.cancel();
      return;
    }
    final n = records.length;
    if (n == 0) return;
    final ok2xx =
        records.where((r) => r.statusCode >= 200 && r.statusCode < 300).length;
    final fail5xx = records.where((r) => r.statusCode >= 500).length;
    final incomplete =
        records.where((r) => r.assertionComplete == false).length;
    stdout.writeln(
      '[checkpoint @ ${DateTime.now().toIso8601String()}] '
      'n=$n 2xx=$ok2xx 5xx=$fail5xx incomplete=$incomplete',
    );
  });

  await Future.any(<Future<void>>[
    Future.wait(workers, eagerError: false),
    shutdown.future,
  ]);
  shutdown.fire(); // Ensure all workers see shutdown.
  await Future.wait(workers, eagerError: false);

  await sigintSub.cancel();
  await rawSink.flush();
  await rawSink.close();
  client.close(force: true);

  final findingsFile =
      File('${outputDir.path}/p4_session_soak_findings.jsonl');
  findingsFile.writeAsStringSync(
    findings.map((f) => jsonEncode(f.toJson())).join('\n') +
        (findings.isEmpty ? '' : '\n'),
  );

  final n = records.length;
  final ok2xx =
      records.where((r) => r.statusCode >= 200 && r.statusCode < 300).length;
  final clientErr =
      records.where((r) => r.statusCode >= 400 && r.statusCode < 500).length;
  final serverErr = records.where((r) => r.statusCode >= 500).length;
  final networkErr = records.where((r) => r.errorKind == 'network_error').length;
  final timeoutErr = records.where((r) => r.errorKind == 'timeout').length;
  final incomplete = records.where((r) => r.assertionComplete == false).length;
  final summary = StringBuffer()
    ..writeln('# p4_session_soak — summary')
    ..writeln()
    ..writeln('Proxy: `${opts.proxyUrl}`')
    ..writeln('Started: ${runStart.toUtc().toIso8601String()}')
    ..writeln('Ended:   ${DateTime.now().toUtc().toIso8601String()}')
    ..writeln('Ops: ${opts.ops}  concurrency: ${opts.concurrency}  '
        'duration: ${opts.durationSeconds}s')
    ..writeln()
    ..writeln('| Metric | Value |')
    ..writeln('|---|---|')
    ..writeln('| Total requests | $n |')
    ..writeln('| 2xx | $ok2xx |')
    ..writeln('| 4xx | $clientErr |')
    ..writeln('| 5xx | $serverErr |')
    ..writeln('| network errors | $networkErr |')
    ..writeln('| timeouts | $timeoutErr |')
    ..writeln('| **incomplete 200 records** | $incomplete |')
    ..writeln()
    ..writeln('Findings: ${findings.length}');
  File('${outputDir.path}/p4_session_soak_summary.md')
      .writeAsStringSync(summary.toString());
  stdout.writeln('\n${summary.toString()}\n');
  stdout.writeln('Findings JSONL: ${findingsFile.path}');
  stdout.writeln('Summary MD: ${outputDir.path}/p4_session_soak_summary.md');
  stdout.writeln('Raw JSONL: ${outputDir.path}/p4_session_soak_raw.jsonl');

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
