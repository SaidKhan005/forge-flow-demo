// Wave 2 Q-2a — email_soak_orchestrator unit tests.
//
// Pins the env-gated-inert + per-path-deferred + summary-aggregation
// contracts. Network-touching paths use a throwing `HttpClient` to
// prove the harness never reaches the wire under deferred / skipped
// branches.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/email_soak/email_soak_orchestrator.dart';

void main() {
  group('validateEmailSoakProxyUrl', () {
    test('preview-host URL is accepted', () {
      expect(
        validateEmailSoakProxyUrl('https://preview.forgeflow.app'),
        isNull,
      );
    });

    test('staging-host URL is accepted', () {
      expect(
        validateEmailSoakProxyUrl('https://staging.forgeflow.app'),
        isNull,
      );
    });

    test('localhost URL is accepted', () {
      expect(
        validateEmailSoakProxyUrl('http://localhost:8080'),
        isNull,
      );
    });

    test('127.0.0.1 URL is accepted', () {
      expect(
        validateEmailSoakProxyUrl('http://127.0.0.1:8080'),
        isNull,
      );
    });

    test('production-looking URL is rejected with a violation string', () {
      final violation = validateEmailSoakProxyUrl('https://app.forgeflow.app');
      expect(violation, isNotNull);
      expect(violation, contains('Refusing'));
    });
  });

  group('parseEmailSoakDurationSeconds', () {
    test('seconds with default unit', () {
      expect(parseEmailSoakDurationSeconds('30s'), 30);
      expect(parseEmailSoakDurationSeconds('30'), 30);
    });

    test('minutes and hours', () {
      expect(parseEmailSoakDurationSeconds('2m'), 120);
      expect(parseEmailSoakDurationSeconds('2min'), 120);
      expect(parseEmailSoakDurationSeconds('1h'), 3600);
    });

    test('empty input throws', () {
      expect(
        () => parseEmailSoakDurationSeconds('  '),
        throwsFormatException,
      );
    });

    test('unknown unit throws', () {
      expect(
        () => parseEmailSoakDurationSeconds('5x'),
        throwsFormatException,
      );
    });
  });

  group('deriveMailosaurInbox', () {
    test('combines prefix + slugified scenario + hash + server', () {
      final inbox = deriveMailosaurInbox(
        inboxPrefix: 'q2a-soak',
        scenarioId: 'invite_first_admin',
        runId: 'run-123',
        serverId: 'srv-xyz',
      );
      expect(inbox, startsWith('q2a-soak-invite-first-admin-'));
      expect(inbox, endsWith('@srv-xyz.mailosaur.net'));
    });

    test('idempotent for the same (scenario, run)', () {
      final a = deriveMailosaurInbox(
        inboxPrefix: 'pfx',
        scenarioId: 's1',
        runId: 'run-X',
        serverId: 'srv',
      );
      final b = deriveMailosaurInbox(
        inboxPrefix: 'pfx',
        scenarioId: 's1',
        runId: 'run-X',
        serverId: 'srv',
      );
      expect(a, b);
    });

    test('different runs produce different addresses', () {
      final a = deriveMailosaurInbox(
        inboxPrefix: 'pfx',
        scenarioId: 's1',
        runId: 'run-A',
        serverId: 'srv',
      );
      final b = deriveMailosaurInbox(
        inboxPrefix: 'pfx',
        scenarioId: 's1',
        runId: 'run-B',
        serverId: 'srv',
      );
      expect(a == b, isFalse);
    });
  });

  group('EmailSoakBudget', () {
    test('inboxWithinBudget honors the configured ceiling', () {
      const budget = EmailSoakBudget(
        inboxLatencyBudgetMs: 30000,
        webhookLatencyBudgetMs: 45000,
      );
      expect(budget.inboxWithinBudget(29999), isTrue);
      expect(budget.inboxWithinBudget(30000), isTrue);
      expect(budget.inboxWithinBudget(30001), isFalse);
    });

    test('webhookWithinBudget honors the configured ceiling', () {
      const budget = EmailSoakBudget(
        inboxLatencyBudgetMs: 30000,
        webhookLatencyBudgetMs: 45000,
      );
      expect(budget.webhookWithinBudget(45000), isTrue);
      expect(budget.webhookWithinBudget(45001), isFalse);
    });

    test('defaults match the documented numbers', () {
      final defaults = EmailSoakBudget.defaults();
      expect(defaults.inboxLatencyBudgetMs, 30000);
      expect(defaults.webhookLatencyBudgetMs, 45000);
    });
  });

  group('runEmailSoakOrchestrator — env-gated-inert', () {
    test('MAILOSAUR_API_KEY unset → ONE skipped line, exit 0', () async {
      final sink = _BufferedSink();
      final exitCode = await runEmailSoakOrchestrator(
        env: const <String, String>{
          'MAILOSAUR_SERVER_ID': 'srv',
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 14),
        httpClientFactory: () => _ThrowingHttpClient(),
      );
      await sink.close();
      expect(exitCode, 0);
      expect(sink.lines, hasLength(1));
      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['metric'], 'email_soak.skipped');
      expect(decoded['reason'], contains('MAILOSAUR_API_KEY'));
    });

    test('MAILOSAUR_SERVER_ID unset → ONE skipped line, exit 0', () async {
      final sink = _BufferedSink();
      final exitCode = await runEmailSoakOrchestrator(
        env: const <String, String>{
          'MAILOSAUR_API_KEY': 'tok',
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 14),
        httpClientFactory: () => _ThrowingHttpClient(),
      );
      await sink.close();
      expect(exitCode, 0);
      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['reason'], contains('MAILOSAUR_SERVER_ID'));
    });

    test('production-looking PROXY_URL → ONE skipped line, exit 0', () async {
      final sink = _BufferedSink();
      final exitCode = await runEmailSoakOrchestrator(
        env: const <String, String>{
          'MAILOSAUR_API_KEY': 'tok',
          'MAILOSAUR_SERVER_ID': 'srv',
          'PROXY_URL': 'https://app.forgeflow.app',
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 14),
        httpClientFactory: () => _ThrowingHttpClient(),
      );
      await sink.close();
      expect(exitCode, 0);
      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['metric'], 'email_soak.skipped');
      expect(decoded['reason'], contains('Refusing'));
    });
  });

  group(
    'runEmailSoakOrchestrator — deferred-only inventory never touches HTTP',
    () {
      test(
        'every deferred-trigger row emits ONE structured line + a summary, '
        'never opens a socket',
        () async {
          final sink = _BufferedSink();
          final exitCode = await runEmailSoakOrchestrator(
            env: const <String, String>{
              'MAILOSAUR_API_KEY': 'tok',
              'MAILOSAUR_SERVER_ID': 'srv',
              // No PROXY_URL — even the admin-test row falls back to
              // deferredTrigger.
            },
            output: sink.ioSink,
            clock: () => DateTime.utc(2026, 5, 14),
            httpClientFactory: () => _ThrowingHttpClient(),
            inventory: const <EmailSoakScenario>[
              EmailSoakScenario(
                scenarioId: 'audit_anchor_failure_fanout',
                templateId: 'audit_anchor_failure',
                triggerKind: EmailSoakTriggerKind.deferredTrigger,
                expectedSubjectSubstring:
                    'A daily integrity check on your audit log did not complete',
                deferralReason: 'upstream worker required',
              ),
              EmailSoakScenario(
                scenarioId: 'password_reset_firebase',
                templateId: 'firebase_password_reset',
                triggerKind: EmailSoakTriggerKind.deferredTrigger,
                expectedSubjectSubstring:
                    '(Firebase Identity Platform template)',
                deferralReason: 'Firebase-managed',
              ),
            ],
          );
          await sink.close();
          expect(exitCode, 0);
          final lines = sink.lines
              .map((l) => jsonDecode(l) as Map<String, Object?>)
              .toList();
          // 2 per-scenario lines + 1 summary.
          expect(lines, hasLength(3));
          expect(lines[0]['metric'], 'email_soak.scenario');
          expect(lines[0]['kind'], 'deferredTrigger');
          expect(lines[1]['metric'], 'email_soak.scenario');
          expect(lines[1]['kind'], 'deferredTrigger');
          expect(lines[2]['metric'], 'email_soak.summary');
          expect(lines[2]['scenarios_deferred_trigger'], 2);
          expect(lines[2]['scenarios_succeeded'], 0);
          expect(lines[2]['scenarios_trigger_failed'], 0);
        },
      );

      test(
        'admin-test row without PROXY_ADMIN_TOKEN reports deferredTrigger',
        () async {
          final sink = _BufferedSink();
          final exitCode = await runEmailSoakOrchestrator(
            env: const <String, String>{
              'MAILOSAUR_API_KEY': 'tok',
              'MAILOSAUR_SERVER_ID': 'srv',
              'PROXY_URL': 'http://localhost:8080',
              // No PROXY_ADMIN_TOKEN.
            },
            output: sink.ioSink,
            clock: () => DateTime.utc(2026, 5, 14),
            httpClientFactory: () => _ThrowingHttpClient(),
            inventory: const <EmailSoakScenario>[
              EmailSoakScenario(
                scenarioId: 'invite_first_admin_admin_test',
                templateId: 'operator_invite_first_admin',
                triggerKind: EmailSoakTriggerKind.adminTestRoute,
                expectedSubjectSubstring:
                    'Welcome to Forge & Flow: set up your account',
              ),
            ],
          );
          await sink.close();
          expect(exitCode, 0);
          final lines = sink.lines
              .map((l) => jsonDecode(l) as Map<String, Object?>)
              .toList();
          expect(lines, hasLength(2));
          expect(lines[0]['kind'], 'deferredTrigger');
          expect(lines[0]['error_reason'],
              contains('PROXY_URL + PROXY_ADMIN_TOKEN'));
          expect(lines[1]['scenarios_deferred_trigger'], 1);
        },
      );
    },
  );

  group('defaultEmailSoakInventory', () {
    final inventory = defaultEmailSoakInventory();

    test('exposes the slice-prompt-mandated 5 paths', () {
      // Slice prompt mandates: invite-send, password-reset, audit
      // anchor failure, vendor disconnect, first-connect backfill.
      const required = <String>{
        'operator_invite_first_admin',
        'firebase_password_reset',
        'audit_anchor_failure',
        'vendor_connection_auto_disabled',
        'backfill_complete',
      };
      final actual =
          inventory.map((s) => s.templateId).toSet();
      for (final id in required) {
        expect(actual, contains(id), reason: 'missing template $id');
      }
    });

    test('admin-test row is the only self-driveable trigger today', () {
      final selfTrigger = inventory
          .where((s) => s.triggerKind == EmailSoakTriggerKind.adminTestRoute)
          .toList();
      expect(selfTrigger, hasLength(1));
      expect(selfTrigger.single.templateId, 'operator_invite_first_admin');
    });

    test('every deferred-trigger row carries a deferralReason', () {
      final deferred = inventory
          .where((s) => s.triggerKind == EmailSoakTriggerKind.deferredTrigger)
          .toList();
      for (final s in deferred) {
        expect(s.deferralReason, isNotNull,
            reason: '${s.scenarioId} should carry a deferralReason');
        expect(s.deferralReason, isNotEmpty);
      }
    });
  });

  group('buildEmailSoakSummary', () {
    test('aggregates by outcome kind and computes p95', () {
      final outcomes = <EmailSoakOutcome>[
        EmailSoakOutcome(
          scenario: defaultEmailSoakInventory().first,
          kind: EmailSoakOutcomeKind.success,
          inboxLatencyMs: 1200,
          webhookLatencyMs: 4500,
        ),
        EmailSoakOutcome(
          scenario: defaultEmailSoakInventory()[1],
          kind: EmailSoakOutcomeKind.deferredTrigger,
        ),
        EmailSoakOutcome(
          scenario: defaultEmailSoakInventory()[2],
          kind: EmailSoakOutcomeKind.webhookMissing,
          inboxLatencyMs: 800,
        ),
      ];
      final summary = buildEmailSoakSummary(
        outcomes: outcomes,
        ts: DateTime.utc(2026, 5, 14),
      );
      expect(summary['metric'], 'email_soak.summary');
      expect(summary['scenarios_attempted'], 3);
      expect(summary['scenarios_succeeded'], 1);
      expect(summary['scenarios_deferred_trigger'], 1);
      expect(summary['scenarios_webhook_missing'], 1);
      // p95 of [800, 1200] is 1200 (sorted-index method).
      expect(summary['p95_inbox_latency_ms'], 1200);
      // Only one webhook latency in the set → p95 == that value.
      expect(summary['p95_webhook_latency_ms'], 4500);
    });

    test('empty outcomes list yields p95 = 0 for both metrics', () {
      final summary = buildEmailSoakSummary(
        outcomes: const <EmailSoakOutcome>[],
        ts: DateTime.utc(2026, 5, 14),
      );
      expect(summary['scenarios_attempted'], 0);
      expect(summary['p95_inbox_latency_ms'], 0);
      expect(summary['p95_webhook_latency_ms'], 0);
    });
  });
}

// ─── Test helpers ─────────────────────────────────────────────────────

/// Buffered IOSink that captures every `writeln` line. Mirrors the
/// helper used by `p4_heap_snapshot_uploader_test.dart` +
/// `p5_email_scenario_loopback_test.dart`.
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
/// resolves to deferredTrigger / providerStubbedInDemo / skipped.
class _ThrowingHttpClient implements HttpClient {
  Never _refuse(String name) => throw StateError(
        'Refusing _ThrowingHttpClient.$name — harness should not touch '
        'HTTP in this run',
      );

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

  @override
  dynamic noSuchMethod(Invocation invocation) {
    _refuse(invocation.memberName.toString());
  }
}
