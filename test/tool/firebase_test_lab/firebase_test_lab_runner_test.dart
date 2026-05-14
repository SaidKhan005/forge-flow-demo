// Wave 2 Q-2c — firebase_test_lab_runner unit tests.
//
// Pins the env-gated skip + matrix → gcloud argv wire shape +
// per-lane refusal contracts. The runner is exercised against a
// fake process runner so the suite never invokes the real gcloud
// binary.

import 'package:flutter_test/flutter_test.dart';

import '../../../tool/firebase_test_lab/firebase_test_lab_matrix.dart';
import '../../../tool/firebase_test_lab/firebase_test_lab_runner.dart';

void main() {
  group('FirebaseTestLabMatrix', () {
    test('default matrix has three Android entries + two iOS entries', () {
      final matrix = kDefaultFirebaseTestLabMatrix;
      expect(matrix.androidEntries.length, 3);
      expect(matrix.iosEntries.length, 2);
      expect(matrix.isComplete, isTrue);
    });

    test('matrix entry serialises to the gcloud --device flag shape', () {
      final entry = kDefaultFirebaseTestLabMatrix.androidEntries.first;
      final flag = entry.toGcloudDeviceFlag();
      expect(flag, contains('model=${entry.deviceModel}'));
      expect(flag, contains('version=${entry.osVersion}'));
      expect(flag, contains('locale=en_US'));
      expect(flag, contains('orientation=portrait'));
    });

    test('isComplete is false when a lane is empty', () {
      const matrix = FirebaseTestLabMatrix(
        entries: <FirebaseTestLabMatrixEntry>[
          FirebaseTestLabMatrixEntry(
            lane: FirebaseTestLabLane.android,
            deviceModel: 'Pixel6',
            osVersion: '33',
            locale: 'en_US',
            orientation: 'portrait',
          ),
        ],
      );
      expect(matrix.isComplete, isFalse);
      expect(matrix.iosEntries, isEmpty);
    });
  });

  group('FirebaseTestLabRunner.run', () {
    test(
      'returns projectIdUnset skip when '
      'FIREBASE_TEST_LAB_PROJECT_ID is unset',
      () async {
        final runner = FirebaseTestLabRunner(
          envLoader: (_) => null,
          processRunner: (_, __, {environment}) {
            fail('process runner should not be invoked on skip');
          },
        );
        final result = await runner.run(
          matrix: kDefaultFirebaseTestLabMatrix,
          lane: FirebaseTestLabLane.android,
          appPath: 'build/app/outputs/flutter-apk/app-forgeflow-release.apk',
        );
        expect(result.wasSkipped, isTrue);
        expect(result.skipReason, FirebaseTestLabRunSkipReason.projectIdUnset);
        expect(result.invocationArgv, isEmpty);
        expect(
          result.stdoutHead,
          contains('FIREBASE_TEST_LAB_PROJECT_ID is unset'),
        );
      },
    );

    test(
      'returns emptyLane skip when the lane has no matrix entries',
      () async {
        const matrix = FirebaseTestLabMatrix(
          entries: <FirebaseTestLabMatrixEntry>[
            FirebaseTestLabMatrixEntry(
              lane: FirebaseTestLabLane.android,
              deviceModel: 'Pixel6',
              osVersion: '33',
              locale: 'en_US',
              orientation: 'portrait',
            ),
          ],
        );
        final runner = FirebaseTestLabRunner(
          envLoader: (name) =>
              name == kFirebaseTestLabProjectIdEnvVar ? 'forge-flow-dev' : null,
          processRunner: (_, __, {environment}) {
            fail('process runner should not be invoked on empty lane');
          },
        );
        final result = await runner.run(
          matrix: matrix,
          lane: FirebaseTestLabLane.ios,
          appPath: 'ios.ipa',
        );
        expect(result.wasSkipped, isTrue);
        expect(result.skipReason, FirebaseTestLabRunSkipReason.emptyLane);
      },
    );

    test('happy path invokes gcloud with the expected argv', () async {
      late List<String> capturedArgv;
      late String capturedCommand;
      final runner = FirebaseTestLabRunner(
        envLoader: (name) {
          switch (name) {
            case kFirebaseTestLabProjectIdEnvVar:
              return 'forge-flow-test-lab-prod';
            case kFirebaseTestLabResultsBucketEnvVar:
              return 'gs://forge-flow-test-lab-results';
            default:
              return null;
          }
        },
        processRunner: (command, arguments, {environment}) async {
          capturedCommand = command;
          capturedArgv = List<String>.from(arguments);
          return const FirebaseTestLabProcessOutcome(
            exitCode: 0,
            stdout: 'matrix submitted',
            stderr: '',
          );
        },
      );
      final result = await runner.run(
        matrix: kDefaultFirebaseTestLabMatrix,
        lane: FirebaseTestLabLane.android,
        appPath: 'build/app.apk',
        testPath: 'build/app-test.apk',
      );
      expect(result.isPass, isTrue);
      expect(result.invocationArgv, capturedArgv);
      expect(capturedCommand, 'gcloud');
      expect(capturedArgv.take(4).toList(), <String>[
        'firebase',
        'test',
        'android',
        'run',
      ]);
      expect(capturedArgv, contains('--app'));
      expect(capturedArgv, contains('build/app.apk'));
      expect(capturedArgv, contains('--test'));
      expect(capturedArgv, contains('build/app-test.apk'));
      expect(capturedArgv, contains('--project'));
      expect(capturedArgv, contains('forge-flow-test-lab-prod'));
      expect(capturedArgv, contains('--results-bucket'));
      expect(capturedArgv, contains('gs://forge-flow-test-lab-results'));
      // Three --device flags per the default matrix's Android lane.
      final deviceFlagCount = capturedArgv.where((a) => a == '--device').length;
      expect(deviceFlagCount, 3);
    });

    test(
      'iOS happy path uses ios subcommand + --test for the IPA',
      () async {
        late List<String> capturedArgv;
        final runner = FirebaseTestLabRunner(
          envLoader: (name) =>
              name == kFirebaseTestLabProjectIdEnvVar ? 'fp' : null,
          processRunner: (_, arguments, {environment}) async {
            capturedArgv = List<String>.from(arguments);
            return const FirebaseTestLabProcessOutcome(
              exitCode: 0,
              stdout: '',
              stderr: '',
            );
          },
        );
        final result = await runner.run(
          matrix: kDefaultFirebaseTestLabMatrix,
          lane: FirebaseTestLabLane.ios,
          appPath: 'ios.ipa',
        );
        expect(result.isPass, isTrue);
        expect(capturedArgv[2], 'ios');
        expect(capturedArgv, contains('--test'));
        expect(capturedArgv, contains('ios.ipa'));
        // Two --device flags per the default matrix's iOS lane.
        final deviceFlagCount =
            capturedArgv.where((a) => a == '--device').length;
        expect(deviceFlagCount, 2);
      },
    );

    test(
      'non-zero gcloud exit propagates as a non-pass result',
      () async {
        final runner = FirebaseTestLabRunner(
          envLoader: (name) =>
              name == kFirebaseTestLabProjectIdEnvVar ? 'fp' : null,
          processRunner: (_, __, {environment}) async =>
              const FirebaseTestLabProcessOutcome(
            exitCode: 1,
            stdout: '',
            stderr: 'one device failed',
          ),
        );
        final result = await runner.run(
          matrix: kDefaultFirebaseTestLabMatrix,
          lane: FirebaseTestLabLane.android,
          appPath: 'build/app.apk',
        );
        expect(result.isPass, isFalse);
        expect(result.wasSkipped, isFalse);
        expect(result.exitCode, 1);
        expect(result.stderrHead, contains('one device failed'));
      },
    );
  });

  group('encodeResultsJson', () {
    test('serialises a result list to a stable wire shape', () {
      const result = FirebaseTestLabRunResult(
        lane: FirebaseTestLabLane.android,
        exitCode: 0,
        skipReason: null,
        stdoutHead: 'ok',
        stderrHead: '',
        invocationArgv: <String>['firebase', 'test', 'android', 'run'],
      );
      final encoded = encodeResultsJson(<FirebaseTestLabRunResult>[result]);
      expect(encoded, contains('"result_count":1'));
      expect(encoded, contains('"lane":"android"'));
      expect(encoded, contains('"exit_code":0'));
    });
  });
}
