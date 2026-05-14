// Wave 2 Q-2c — firebase_test_lab_orchestrator unit tests.
//
// Pins the CLI argv → options shape + per-lane fan-out + skip
// attribution + report shape. The orchestrator is exercised against
// an injected `FirebaseTestLabRunner` that records the lane each run
// was invoked for so the suite can assert without touching gcloud.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/firebase_test_lab/firebase_test_lab_matrix.dart';
import '../../../tool/firebase_test_lab/firebase_test_lab_orchestrator.dart';
import '../../../tool/firebase_test_lab/firebase_test_lab_runner.dart';

void main() {
  group('parseFirebaseTestLabOrchestratorArgs', () {
    test('parses output-dir + run-id overrides', () {
      final opts = parseFirebaseTestLabOrchestratorArgs(<String>[
        '--output-dir=test/out',
        '--run-id=local',
        '--android-app=build/app.apk',
        '--ios-app=ios.ipa',
        '--poll-budget-seconds=600',
      ]);
      expect(opts.outputDir, 'test/out');
      expect(opts.runId, 'local');
      expect(opts.androidAppPath, 'build/app.apk');
      expect(opts.iosAppPath, 'ios.ipa');
      expect(opts.pollBudget, const Duration(seconds: 600));
      expect(opts.matrix.entries.length,
          kDefaultFirebaseTestLabMatrix.entries.length);
    });

    test('poll-budget-seconds rejects non-positive integers', () {
      expect(
        () => parseFirebaseTestLabOrchestratorArgs(<String>[
          '--poll-budget-seconds=0',
        ]),
        throwsFormatException,
      );
      expect(
        () => parseFirebaseTestLabOrchestratorArgs(<String>[
          '--poll-budget-seconds=bad',
        ]),
        throwsFormatException,
      );
    });

    test('default run id is non-empty', () {
      final opts = parseFirebaseTestLabOrchestratorArgs(const <String>[]);
      expect(opts.runId, isNotEmpty);
    });
  });

  group('runFirebaseTestLabOrchestrator', () {
    test(
      'skip-only flow when PROJECT_ID is unset writes a report and '
      'records skip outcomes for each requested lane',
      () async {
        final tmp = await Directory.systemTemp.createTemp('q2c-test-');
        addTearDown(() async {
          await tmp.delete(recursive: true);
        });
        final opts = FirebaseTestLabOrchestratorOptions(
          outputDir: tmp.path,
          runId: 'skip-only',
          androidAppPath: 'build/app.apk',
          iosAppPath: 'ios.ipa',
          androidTestPath: null,
          iosTestPath: null,
          matrix: kDefaultFirebaseTestLabMatrix,
          pollBudget: const Duration(minutes: 5),
        );
        // envLoader returns null for everything → runner reports
        // projectIdUnset on every lane invocation.
        final runner = FirebaseTestLabRunner(
          envLoader: (_) => null,
          processRunner: (_, __, {environment}) {
            fail('process runner should never fire on a skip flow');
          },
        );
        final result = await runFirebaseTestLabOrchestrator(
          opts,
          runner: runner,
        );
        expect(result.exitCode, 0);
        expect(result.skipCount, 2);
        expect(result.passCount, 0);
        expect(result.failCount, 0);
        final reportText = File(result.reportPath).readAsStringSync();
        expect(reportText, contains('firebase_test_lab_orchestrator'));
        expect(reportText, contains('| Lanes skip | 2 |'));
        expect(reportText, contains('projectIdUnset'));
        // The per-device coverage table renders one row per matrix
        // entry, even on a fully-skipped flow.
        for (final entry in kDefaultFirebaseTestLabMatrix.entries) {
          expect(reportText, contains(entry.deviceModel));
          expect(reportText, contains(entry.osVersion));
        }
      },
    );

    test(
      'happy-path flow folds both lanes into a passing result',
      () async {
        final tmp = await Directory.systemTemp.createTemp('q2c-happy-');
        addTearDown(() async {
          await tmp.delete(recursive: true);
        });
        final opts = FirebaseTestLabOrchestratorOptions(
          outputDir: tmp.path,
          runId: 'happy',
          androidAppPath: 'build/app.apk',
          iosAppPath: 'ios.ipa',
          androidTestPath: null,
          iosTestPath: null,
          matrix: kDefaultFirebaseTestLabMatrix,
          pollBudget: const Duration(minutes: 5),
        );
        final runner = FirebaseTestLabRunner(
          envLoader: (name) =>
              name == kFirebaseTestLabProjectIdEnvVar ? 'fp' : null,
          processRunner: (_, __, {environment}) async =>
              const FirebaseTestLabProcessOutcome(
            exitCode: 0,
            stdout: 'matrix passed',
            stderr: '',
          ),
        );
        final result = await runFirebaseTestLabOrchestrator(
          opts,
          runner: runner,
        );
        expect(result.exitCode, 0);
        expect(result.passCount, 2);
        expect(result.skipCount, 0);
        expect(result.failCount, 0);
        final raw = File(result.rawJsonlPath).readAsStringSync();
        expect(raw, contains('"lane":"android"'));
        expect(raw, contains('"lane":"ios"'));
      },
    );

    test(
      'one-lane fail propagates exitCode 1',
      () async {
        final tmp = await Directory.systemTemp.createTemp('q2c-fail-');
        addTearDown(() async {
          await tmp.delete(recursive: true);
        });
        final opts = FirebaseTestLabOrchestratorOptions(
          outputDir: tmp.path,
          runId: 'fail',
          androidAppPath: 'build/app.apk',
          iosAppPath: null,
          androidTestPath: null,
          iosTestPath: null,
          matrix: kDefaultFirebaseTestLabMatrix,
          pollBudget: const Duration(minutes: 5),
        );
        final runner = FirebaseTestLabRunner(
          envLoader: (name) =>
              name == kFirebaseTestLabProjectIdEnvVar ? 'fp' : null,
          processRunner: (_, __, {environment}) async =>
              const FirebaseTestLabProcessOutcome(
            exitCode: 2,
            stdout: '',
            stderr: 'a device blew up',
          ),
        );
        final result = await runFirebaseTestLabOrchestrator(
          opts,
          runner: runner,
        );
        expect(result.exitCode, 1);
        expect(result.failCount, 1);
        expect(result.passCount, 0);
      },
    );
  });
}
