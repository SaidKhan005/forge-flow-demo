// Slice C-11 — `p5_email_scenario_loopback` unit tests.
//
// Covers the non-trivial pure-function seams in the harness:
//   * `subjectMatches` substring rules (variable-bound vs literal).
//   * `bodyMatches` cross-body needle search.
//   * `p95LatencyMs` sorted-index computation (edge cases: empty, 1, N).
//   * `buildSummary` aggregates by outcome kind + computes p95.
//   * `buildScenarioLine` shapes per outcome kind.
//   * `validateProxyUrl` allow-list defense.
//   * `parseOutputPath` CLI flag parser.
//   * `runEmailLoopback` env-gated-inert: missing creds → ONE
//     "skipped" line, exit 0, NEVER attempts network.
//   * `runEmailLoopback` driver behavior: deferred / firebase-managed
//     surfaces all flow to a "deferred" log line without touching the
//     network.
//   * `emailLoopbackInventory` has the right wired/deferred split
//     (catches drift between renderer doc-strings and this harness).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/pressure/p5_email_scenario_loopback.dart';

void main() {
  group('subjectMatches', () {
    test('exact substring matches', () {
      expect(
        subjectMatches(
          observed: 'Historical sync complete',
          expectedSubstring: 'Historical sync complete',
        ),
        isTrue,
      );
    });

    test('variable-bound subject matches via substring', () {
      expect(
        subjectMatches(
          observed: 'Toast POS is ready to connect in Forge & Flow',
          expectedSubstring: 'is ready to connect in Forge & Flow',
        ),
        isTrue,
      );
    });

    test('empty expectation never matches', () {
      expect(
        subjectMatches(observed: 'anything', expectedSubstring: ''),
        isFalse,
      );
    });

    test('mismatched needle returns false', () {
      expect(
        subjectMatches(
          observed: 'Welcome to Forge & Flow',
          expectedSubstring: 'Audit chain anchor',
        ),
        isFalse,
      );
    });
  });

  group('bodyMatches', () {
    test('empty expectation list returns true (no body assertion)', () {
      expect(
        bodyMatches(
          htmlBody: '<p>anything</p>',
          textBody: 'anything',
          expectedContains: const <String>[],
        ),
        isTrue,
      );
    });

    test('needle in html body suffices even if text body is empty', () {
      expect(
        bodyMatches(
          htmlBody: '<p>Welcome F&F Test Admin</p>',
          textBody: '',
          expectedContains: const <String>['F&F Test Admin'],
        ),
        isTrue,
      );
    });

    test('needle in text body suffices even if html body is empty', () {
      expect(
        bodyMatches(
          htmlBody: '',
          textBody: 'Welcome F&F Test Admin',
          expectedContains: const <String>['F&F Test Admin'],
        ),
        isTrue,
      );
    });

    test('all needles must match — partial hit fails', () {
      expect(
        bodyMatches(
          htmlBody: '<p>Welcome F&F Test Admin</p>',
          textBody: '',
          expectedContains: const <String>['F&F Test Admin', 'Forge & Flow Demo'],
        ),
        isFalse,
      );
    });
  });

  group('p95LatencyMs', () {
    test('empty samples → 0', () {
      expect(p95LatencyMs(const <int>[]), 0);
    });

    test('single sample → that sample', () {
      expect(p95LatencyMs(const <int>[123]), 123);
    });

    test('10 samples → 95th percentile by ceil-index', () {
      // Sorted [10, 20, 30, 40, 50, 60, 70, 80, 90, 100].
      // p95Index = ceil(10 * 0.95) - 1 = ceil(9.5) - 1 = 10 - 1 = 9.
      // Sorted[9] = 100.
      expect(
        p95LatencyMs(const <int>[100, 90, 80, 70, 60, 50, 40, 30, 20, 10]),
        100,
      );
    });

    test('20 samples — ascending — p95 is the 19th element', () {
      final samples =
          List<int>.generate(20, (i) => (i + 1) * 5);
      // p95Index = ceil(20 * 0.95) - 1 = ceil(19) - 1 = 18.
      // Sorted[18] = (18+1)*5 = 95.
      expect(p95LatencyMs(samples), 95);
    });

    test('unsorted input still computes the right percentile', () {
      // Same data as above shuffled.
      final samples = <int>[50, 5, 95, 10, 45, 100, 15, 90, 20, 60];
      // 10 elements; p95 = sorted[9] = max = 100.
      expect(p95LatencyMs(samples), 100);
    });
  });

  group('buildSummary', () {
    final ts = DateTime.utc(2026, 5, 13, 12, 0, 0);
    const wiredScenario = EmailLoopbackScenario(
      templateId: 'operator_invite_first_admin',
      expectedSubject: 'Welcome to Forge & Flow',
      status: EmailLoopbackStatus.wired,
    );
    const deferredScenario = EmailLoopbackScenario(
      templateId: 'mfa_factor_changed_notice',
      expectedSubject: 'MFA',
      status: EmailLoopbackStatus.deferred,
      deferralReason: 'C-2 Draft C',
    );

    test('counts by kind and computes p95 over success latencies only',
        () {
      final outcomes = <EmailLoopbackOutcome>[
        const EmailLoopbackOutcome(
          scenario: wiredScenario,
          kind: EmailLoopbackOutcomeKind.success,
          latencyMs: 100,
          subjectMatch: true,
          bodyMatch: true,
          messageId: 'm-1',
        ),
        const EmailLoopbackOutcome(
          scenario: wiredScenario,
          kind: EmailLoopbackOutcomeKind.success,
          latencyMs: 200,
          subjectMatch: true,
          bodyMatch: true,
          messageId: 'm-2',
        ),
        const EmailLoopbackOutcome(
          scenario: deferredScenario,
          kind: EmailLoopbackOutcomeKind.deferred,
        ),
        const EmailLoopbackOutcome(
          scenario: wiredScenario,
          kind: EmailLoopbackOutcomeKind.failed,
          error: 'http 500',
        ),
        const EmailLoopbackOutcome(
          scenario: wiredScenario,
          kind: EmailLoopbackOutcomeKind.timeout,
          error: 'mailosaur timeout',
        ),
      ];
      final summary = buildSummary(outcomes: outcomes, ts: ts);
      expect(summary['metric'], 'email_loopback.summary');
      expect(summary['ts'], ts.toIso8601String());
      expect(summary['scenarios_attempted'], 5);
      expect(summary['scenarios_succeeded'], 2);
      expect(summary['scenarios_deferred'], 1);
      expect(summary['scenarios_failed'], 2);
      // p95 over [100, 200] → ceil(2*0.95)-1 = 1, sorted[1] = 200.
      expect(summary['p95_latency_ms'], 200);
    });

    test('empty outcomes → zero counters', () {
      final summary = buildSummary(
        outcomes: const <EmailLoopbackOutcome>[],
        ts: ts,
      );
      expect(summary['scenarios_attempted'], 0);
      expect(summary['scenarios_succeeded'], 0);
      expect(summary['scenarios_deferred'], 0);
      expect(summary['scenarios_failed'], 0);
      expect(summary['p95_latency_ms'], 0);
    });
  });

  group('buildScenarioLine', () {
    final ts = DateTime.utc(2026, 5, 13, 12, 0, 0);
    const scenario = EmailLoopbackScenario(
      templateId: 'operator_invite_first_admin',
      expectedSubject: 'Welcome',
      status: EmailLoopbackStatus.wired,
    );

    test('success → wired status + latency + match flags', () {
      final line = buildScenarioLine(
        outcome: const EmailLoopbackOutcome(
          scenario: scenario,
          kind: EmailLoopbackOutcomeKind.success,
          latencyMs: 1500,
          subjectMatch: true,
          bodyMatch: false,
          messageId: 'msg-abc',
        ),
        ts: ts,
      );
      expect(line['metric'], 'email_loopback.scenario');
      expect(line['scenario'], 'operator_invite_first_admin');
      expect(line['status'], 'wired');
      expect(line['latency_ms'], 1500);
      expect(line['subject_match'], true);
      expect(line['body_match'], false);
      expect(line['message_id'], 'msg-abc');
    });

    test('deferred → deferred status + reason', () {
      const deferredScenario = EmailLoopbackScenario(
        templateId: 'mfa_factor_changed_notice',
        expectedSubject: 'MFA',
        status: EmailLoopbackStatus.deferred,
        deferralReason: 'C-2 Draft C — server-side emission site pending',
      );
      final line = buildScenarioLine(
        outcome: const EmailLoopbackOutcome(
          scenario: deferredScenario,
          kind: EmailLoopbackOutcomeKind.deferred,
        ),
        ts: ts,
      );
      expect(line['status'], 'deferred');
      expect(line['reason'], contains('C-2 Draft C'));
    });

    test('failed → failed status + error', () {
      final line = buildScenarioLine(
        outcome: const EmailLoopbackOutcome(
          scenario: scenario,
          kind: EmailLoopbackOutcomeKind.failed,
          error: 'http 500',
        ),
        ts: ts,
      );
      expect(line['status'], 'failed');
      expect(line['error'], 'http 500');
    });

    test('timeout → timeout status + default error string when null', () {
      final line = buildScenarioLine(
        outcome: const EmailLoopbackOutcome(
          scenario: scenario,
          kind: EmailLoopbackOutcomeKind.timeout,
        ),
        ts: ts,
      );
      expect(line['status'], 'timeout');
      expect(line['error'], contains('mailosaur'));
    });
  });

  group('validateProxyUrl', () {
    test('preview substring passes', () {
      expect(
          validateProxyUrl('https://preview.forgeflow.app'), isNull);
    });

    test('staging substring passes', () {
      expect(
          validateProxyUrl('https://staging.forgeflow.app'), isNull);
    });

    test('localhost passes', () {
      expect(validateProxyUrl('http://localhost:8080'), isNull);
    });

    test('production-looking URL is rejected', () {
      final err = validateProxyUrl('https://app.forgeflow.app');
      expect(err, isNotNull);
      expect(err, contains('production'));
    });
  });

  group('parseOutputPath', () {
    test('absent → null', () {
      expect(parseOutputPath(const <String>[]), isNull);
    });

    test('present → extracts the path', () {
      expect(
        parseOutputPath(const <String>['--output=test/p5.jsonl']),
        'test/p5.jsonl',
      );
    });

    test('ignores unrelated flags', () {
      expect(
        parseOutputPath(const <String>[
          '--unknown=foo',
          '--output=path/here',
          '--also=bar',
        ]),
        'path/here',
      );
    });
  });

  group('runEmailLoopback', () {
    test('MAILOSAUR_API_KEY unset → ONE skipped line, exit 0', () async {
      final sink = _BufferedSink();
      final exitCode = await runEmailLoopback(
        env: const <String, String>{
          // No MAILOSAUR_API_KEY.
          'MAILOSAUR_SERVER_ID': 'srv-123',
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
      );
      await sink.close();
      expect(exitCode, 0);
      expect(sink.lines, hasLength(1));
      final decoded =
          jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['metric'], 'email_loopback.skipped');
      expect(decoded['reason'], contains('MAILOSAUR_API_KEY'));
    });

    test('MAILOSAUR_SERVER_ID unset → ONE skipped line, exit 0', () async {
      final sink = _BufferedSink();
      final exitCode = await runEmailLoopback(
        env: const <String, String>{
          'MAILOSAUR_API_KEY': 'tok-abc',
          // No MAILOSAUR_SERVER_ID.
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
      );
      await sink.close();
      expect(exitCode, 0);
      final decoded =
          jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['reason'], contains('MAILOSAUR_SERVER_ID'));
    });

    test('production-looking PROXY_URL is rejected with exit 2', () async {
      final sink = _BufferedSink();
      final exitCode = await runEmailLoopback(
        env: const <String, String>{
          'MAILOSAUR_API_KEY': 'tok-abc',
          'MAILOSAUR_SERVER_ID': 'srv-123',
          'PROXY_URL': 'https://app.forgeflow.app',
          'PROXY_ADMIN_TOKEN': 'admin-tok',
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
      );
      await sink.close();
      expect(exitCode, 2);
      final decoded =
          jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['metric'], 'email_loopback.skipped');
      expect(decoded['reason'], contains('production'));
    });

    test('with creds but no proxy → emits one deferred-or-firebase '
        'line per inventory row + a summary line, never touches HTTP',
        () async {
      final sink = _BufferedSink();
      final exitCode = await runEmailLoopback(
        env: const <String, String>{
          'MAILOSAUR_API_KEY': 'tok-abc',
          'MAILOSAUR_SERVER_ID': 'srv-123',
          // Intentionally no PROXY_URL → admin-test cannot self-drive.
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        // Use an HttpClient factory that throws on any access — the
        // harness must not touch HTTP when all scenarios are deferred.
        httpClientFactory: () => _ThrowingHttpClient(),
        // Restrict inventory to deferred + firebase-managed only so
        // the test doesn't depend on Mailosaur being reachable.
        inventory: const <EmailLoopbackScenario>[
          EmailLoopbackScenario(
            templateId: 'mfa_factor_changed_notice',
            expectedSubject: 'MFA',
            status: EmailLoopbackStatus.deferred,
            deferralReason: 'C-2 Draft C',
          ),
          EmailLoopbackScenario(
            templateId: 'firebase_password_reset',
            expectedSubject: '(Firebase)',
            status: EmailLoopbackStatus.firebaseManaged,
            deferralReason: 'Inventory 1.a',
          ),
        ],
      );
      await sink.close();
      expect(exitCode, 0);
      final decoded = sink.lines
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      // 2 deferred lines + 1 summary line.
      expect(decoded, hasLength(3));
      expect(decoded[0]['status'], 'deferred');
      expect(decoded[1]['status'], 'deferred');
      expect(decoded[2]['metric'], 'email_loopback.summary');
      expect(decoded[2]['scenarios_deferred'], 2);
      expect(decoded[2]['scenarios_succeeded'], 0);
      expect(decoded[2]['scenarios_failed'], 0);
    });

    test(
        'wired scenarios other than operator_invite_first_admin are '
        'reported as deferred (cannot self-trigger upstream workers)',
        () async {
      final sink = _BufferedSink();
      final exitCode = await runEmailLoopback(
        env: const <String, String>{
          'MAILOSAUR_API_KEY': 'tok-abc',
          'MAILOSAUR_SERVER_ID': 'srv-123',
          'PROXY_URL': 'https://preview.forgeflow.app',
          'PROXY_ADMIN_TOKEN': 'admin-tok',
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        httpClientFactory: () => _ThrowingHttpClient(),
        inventory: const <EmailLoopbackScenario>[
          EmailLoopbackScenario(
            templateId: 'backfill_complete',
            expectedSubject: 'Historical sync complete',
            status: EmailLoopbackStatus.wired,
            triggerPath: 'fanout/backfill_complete',
          ),
          EmailLoopbackScenario(
            templateId: 'audit_anchor_failure',
            expectedSubject: 'Audit chain anchor needs review',
            status: EmailLoopbackStatus.wired,
            triggerPath: 'fanout/audit_anchor_failure',
          ),
        ],
      );
      await sink.close();
      expect(exitCode, 0);
      final decoded = sink.lines
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList();
      // 2 wired-but-cannot-self-trigger → deferred + 1 summary.
      expect(decoded, hasLength(3));
      expect(decoded[0]['status'], 'deferred');
      expect(decoded[1]['status'], 'deferred');
      expect(decoded[2]['scenarios_deferred'], 2);
    });
  });

  group('emailLoopbackInventory', () {
    final inventory = emailLoopbackInventory();

    test('contains the operator-invite-first-admin wired surface', () {
      expect(
        inventory.where((s) => s.templateId == 'operator_invite_first_admin'),
        hasLength(1),
      );
      expect(
        inventory
            .firstWhere((s) => s.templateId == 'operator_invite_first_admin')
            .status,
        EmailLoopbackStatus.wired,
      );
    });

    test('flags all 5 C-2 deferred templates explicitly', () {
      const deferredIds = <String>[
        'mfa_factor_changed_notice',
        'vendor_sync_error_alert',
        'vendor_webhook_signature_alert',
        'vendor_connection_auto_disabled',
        'tos_version_updated_notice',
      ];
      for (final id in deferredIds) {
        final entries =
            inventory.where((s) => s.templateId == id).toList();
        expect(entries, hasLength(1), reason: 'missing inventory row $id');
        expect(entries.single.status, EmailLoopbackStatus.deferred,
            reason: '$id should be deferred per C-2 matrix');
        expect(entries.single.deferralReason, isNotNull);
      }
    });

    test('B3 fanout wired surfaces are present and wired', () {
      const b3WiredIds = <String>[
        'backfill_complete',
        'backfill_failed',
        'audit_anchor_failure',
        'vendor_now_available',
      ];
      for (final id in b3WiredIds) {
        final entries =
            inventory.where((s) => s.templateId == id).toList();
        expect(entries, hasLength(1), reason: 'missing inventory row $id');
        expect(entries.single.status, EmailLoopbackStatus.wired,
            reason: '$id should be wired per inventory matrix');
      }
    });

    test('firebase-managed paths are flagged distinctly from wired', () {
      final firebase = inventory
          .where((s) => s.status == EmailLoopbackStatus.firebaseManaged)
          .toList();
      expect(firebase, isNotEmpty);
      for (final entry in firebase) {
        expect(entry.templateId, startsWith('firebase_'),
            reason: 'firebase-managed entries should be id-prefixed');
      }
    });
  });
}

/// Buffered IOSink that captures every `writeln` line into an in-memory
/// list. Mirrors the helper used by `p4_heap_snapshot_uploader_test.dart`.
class _BufferedSink {
  _BufferedSink() {
    _controller = StreamController<List<int>>();
    _ioSink = IOSink(_controller.sink);
    _controller.stream.transform(utf8.decoder).listen(_buffer.write);
  }

  late final StreamController<List<int>> _controller;
  late final IOSink _ioSink;
  final StringBuffer _buffer = StringBuffer();

  IOSink get ioSink => _ioSink;

  List<String> get lines {
    final raw = _buffer.toString();
    if (raw.isEmpty) return const <String>[];
    return raw
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
  }

  Future<void> close() async {
    await _ioSink.flush();
    await _ioSink.close();
    await _controller.close();
  }
}

/// HttpClient that throws if any of its methods get exercised — used
/// to prove the harness never touches the network when every scenario
/// resolves to a deferred outcome.
class _ThrowingHttpClient implements HttpClient {
  Never _refuse(String name) =>
      throw StateError('Refusing _ThrowingHttpClient.$name — '
          'harness should not touch HTTP in deferred-only run');

  @override
  void close({bool force = false}) {
    // No-op: the harness closes the client in the finally block, even
    // when no requests were issued.
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _refuse('getUrl');

  @override
  Future<HttpClientRequest> postUrl(Uri url) => _refuse('postUrl');

  @override
  Future<HttpClientRequest> putUrl(Uri url) => _refuse('putUrl');

  // Every other method routes to _refuse via noSuchMethod so we don't
  // have to enumerate the full HttpClient surface.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    _refuse(invocation.memberName.toString());
  }
}
