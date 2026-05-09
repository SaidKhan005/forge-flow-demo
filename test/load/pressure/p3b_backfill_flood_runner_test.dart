// Pressure Preview v1 — Phase 3B runner test.
//
// Drives the backfill-flood harness in-process at smoke scale and
// asserts the contract the binary itself records as findings:
//
//   1. Every enqueued backfill job reaches a terminal state inside
//      the harness budget — no `backfill_stuck` finding.
//   2. The demo-flip race for the dedicated (operator, location)
//      triple resolves cleanly across all three categories — no
//      `demo_flip_race_lost` finding.
//   3. No worker pod claims the same job concurrently — no
//      `worker_collision` finding.
//   4. Every succeeded backfill emits a terminal-hook audit row —
//      no `audit_row_missing` finding.
//   5. Pod-restart resume keeps the cursor — no `cursor_lost_at_restart`
//      finding.
//
// `setup_skipped` IS expected (the test runs without `POSTGRES_URL`
// set and the harness records the limitation once). We assert it is
// the ONLY finding kind, which is the strongest contract a no-DB
// runner can express.
//
// The harness binary lives at `tool/pressure/p3b_backfill_flood.dart`;
// this test imports the library entrypoint and runs it in-process so
// `flutter test` can exercise the contract without spawning a Dart
// subprocess.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/pressure/p3b_backfill_flood.dart' as p3b;

void main() {
  group('p3b backfill flood — smoke contract', () {
    late Directory tmpDir;
    late String findingsPath;
    late String summaryPath;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('p3b_runner_');
      findingsPath = '${tmpDir.path}/findings.jsonl';
      summaryPath = '${tmpDir.path}/summary.md';
    });

    tearDown(() {
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('smoke run terminates every job and races demo-flip cleanly',
        () async {
      final config = p3b.HarnessConfig(
        ops: 3,
        vendorsPerOp: 2,
        recordsPerVendor: 50,
        workerPods: 2,
        simulateRestart: 1,
        findingsOut: findingsPath,
        summaryOut: summaryPath,
        quiet: true,
      );
      final findings = p3b.FindingsLog.openFresh(findingsPath);
      final result = await p3b.runHarness(
        config: config,
        findings: findings,
        environment: const <String, String>{}, // no POSTGRES_URL
      );
      await findings.flushAndClose();

      // 1. Every enqueued job (regular + race) reached terminal.
      expect(
        result.totalJobsTerminal,
        result.totalJobsEnqueued,
        reason: 'expected every job to reach terminal state '
            '(no backfill_stuck); enqueued '
            '${result.totalJobsEnqueued}, terminal '
            '${result.totalJobsTerminal}',
      );

      // 2. Demo-flip race resolved across all 3 categories.
      expect(
        result.demoFlipResult.allFlipped,
        isTrue,
        reason: 'demo-flip race for the dedicated triple did not '
            'resolve all 3 categories (flipped: '
            '${result.demoFlipResult.flippedCategories.join(", ")})',
      );

      // 3. No collision / resume / audit findings should fire under
      //    the smoke profile. Only setup_skipped is expected.
      const expectedKindsAtMost = <String>{'setup_skipped'};
      final unexpectedKinds = result.findingTally.keys
          .where((kind) => !expectedKindsAtMost.contains(kind))
          .toList()
        ..sort();
      expect(
        unexpectedKinds,
        isEmpty,
        reason:
            'unexpected finding kinds recorded: ${unexpectedKinds.join(", ")}'
            ' (full tally: ${result.findingTally})',
      );

      // setup_skipped is expected exactly once when env is empty.
      expect(
        result.findingTally['setup_skipped'],
        1,
        reason: 'expected exactly one setup_skipped finding when '
            'POSTGRES_URL is unset; got '
            '${result.findingTally['setup_skipped']}',
      );

      // Findings file + summary md were materialized.
      expect(File(findingsPath).existsSync(), isTrue);
      expect(File(summaryPath).existsSync(), isFalse,
          reason: 'this test path bypasses the CLI summary writer; '
              'the harness binary writes summary.md, the runner '
              'asserts on findings only');
    });

    test('CLI smoke wraps runHarness and writes summary.md', () async {
      // Drive the CLI entrypoint to confirm the summary md path
      // gets written and the exit code reflects success.
      final exitCode = await p3b.runCli(
        <String>[
          '--ops=2',
          '--vendors-per-op=2',
          '--records-per-vendor=20',
          '--worker-pods=2',
          '--simulate-restart=1',
          '--findings-out=$findingsPath',
          '--summary-out=$summaryPath',
          '--quiet',
        ],
        environment: const <String, String>{},
        out: (_) {},
        err: (_) {},
      );
      expect(exitCode, 0);
      expect(File(findingsPath).existsSync(), isTrue);
      expect(File(summaryPath).existsSync(), isTrue);
      // Summary md must include the full-scale invocation block so
      // operators can copy-paste it during scale-up.
      final summary = File(summaryPath).readAsStringSync();
      expect(
        summary.contains('--ops=10 --vendors-per-op=3'),
        isTrue,
        reason: 'summary.md should document the full-scale invocation',
      );
      expect(
        summary.contains('forge-flow-preview-backend-surface-additions'),
        isTrue,
        reason: 'summary.md should reference the operator-approved '
            'preview proxy URL',
      );
    });

    test('CLI rejects malformed flags with exit code 2', () async {
      final errLines = <String>[];
      final exitCode = await p3b.runCli(
        <String>['--ops=not-an-int'],
        environment: const <String, String>{},
        out: (_) {},
        err: errLines.add,
      );
      expect(exitCode, 2);
      expect(
        errLines.any((line) => line.contains('--ops')),
        isTrue,
        reason: 'expected an error line referencing the bad flag',
      );
    });

    test('CLI --help exits 0 without running the harness', () async {
      final outLines = <String>[];
      final exitCode = await p3b.runCli(
        <String>['--help'],
        environment: const <String, String>{},
        out: outLines.add,
        err: (_) {},
      );
      expect(exitCode, 0);
      expect(
        outLines.any((line) => line.contains('--ops=')),
        isTrue,
        reason: 'expected usage block on --help',
      );
    });
  });
}
