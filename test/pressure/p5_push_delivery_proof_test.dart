// Slice C-11 — `p5_push_delivery_proof` unit tests.
//
// Covers the harness's state-machine seam (pure function) plus the
// structured-log shape. The actual Patrol two-device proof is deferred
// (see harness file header) so there's nothing else to test here today.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/pressure/p5_push_delivery_proof.dart';

void main() {
  group('evaluatePushDeliveryState', () {
    test('Patrol missing from dev_dependencies → deferredPatrolMissing',
        () {
      final state = evaluatePushDeliveryState(
        env: const <String, String>{
          'PATROL_DEVICE_A_ID': 'emulator-5554',
          'PATROL_DEVICE_B_ID': 'emulator-5556',
          'PROXY_URL': 'https://preview.forgeflow.app',
          'PROXY_OPERATOR_TOKEN_A': 'tok-a',
          'PROXY_OPERATOR_TOKEN_B': 'tok-b',
        },
        devDependencies: const <String>['flutter_test', 'fake_async'],
      );
      expect(state, PushDeliveryHarnessState.deferredPatrolMissing);
    });

    test(
        'Patrol present but missing env vars → deferredEnvMissing for '
        'each required key', () {
      // Walk every required env var and confirm absence triggers the
      // env-missing state.
      const required = <String>[
        'PATROL_DEVICE_A_ID',
        'PATROL_DEVICE_B_ID',
        'PROXY_URL',
        'PROXY_OPERATOR_TOKEN_A',
        'PROXY_OPERATOR_TOKEN_B',
      ];
      for (final missing in required) {
        final env = <String, String>{
          for (final key in required)
            if (key != missing) key: 'placeholder',
        };
        if (missing != 'PROXY_URL') {
          // PROXY_URL needs to be allow-list valid to isolate the
          // single-missing-key case.
          env['PROXY_URL'] = 'https://preview.forgeflow.app';
        }
        final state = evaluatePushDeliveryState(
          env: env,
          devDependencies: const <String>['flutter_test', 'patrol'],
        );
        expect(state, PushDeliveryHarnessState.deferredEnvMissing,
            reason: 'missing $missing should yield deferredEnvMissing');
      }
    });

    test('production-looking PROXY_URL → deferredProxyValidationFailed',
        () {
      final state = evaluatePushDeliveryState(
        env: const <String, String>{
          'PATROL_DEVICE_A_ID': 'emulator-5554',
          'PATROL_DEVICE_B_ID': 'emulator-5556',
          'PROXY_URL': 'https://app.forgeflow.app',
          'PROXY_OPERATOR_TOKEN_A': 'tok-a',
          'PROXY_OPERATOR_TOKEN_B': 'tok-b',
        },
        devDependencies: const <String>['flutter_test', 'patrol'],
      );
      expect(state, PushDeliveryHarnessState.deferredProxyValidationFailed);
    });

    test('Patrol + env + preview URL → ready', () {
      final state = evaluatePushDeliveryState(
        env: const <String, String>{
          'PATROL_DEVICE_A_ID': 'emulator-5554',
          'PATROL_DEVICE_B_ID': 'emulator-5556',
          'PROXY_URL': 'https://preview.forgeflow.app',
          'PROXY_OPERATOR_TOKEN_A': 'tok-a',
          'PROXY_OPERATOR_TOKEN_B': 'tok-b',
        },
        devDependencies: const <String>['flutter_test', 'patrol'],
      );
      expect(state, PushDeliveryHarnessState.ready);
    });
  });

  group('buildSkippedLine', () {
    final ts = DateTime.utc(2026, 5, 13, 12, 0, 0);

    test('deferredPatrolMissing reason cites pubspec wire-up', () {
      final line = buildSkippedLine(
        state: PushDeliveryHarnessState.deferredPatrolMissing,
        ts: ts,
      );
      expect(line['metric'], 'push_delivery.skipped');
      expect(line['state'], 'deferredPatrolMissing');
      expect(line['reason'], contains('Patrol'));
      expect(line['reason'], contains('dev_dependencies'));
    });

    test('deferredEnvMissing reason enumerates the required env vars',
        () {
      final line = buildSkippedLine(
        state: PushDeliveryHarnessState.deferredEnvMissing,
        ts: ts,
      );
      expect(line['reason'], contains('PATROL_DEVICE_A_ID'));
      expect(line['reason'], contains('PROXY_URL'));
    });

    test(
        'deferredProxyValidationFailed reason cites the allow-list + '
        'refuses production', () {
      final line = buildSkippedLine(
        state: PushDeliveryHarnessState.deferredProxyValidationFailed,
        ts: ts,
      );
      expect(line['reason'], contains('preview.'));
      expect(line['reason'], contains('production'));
    });
  });

  group('runPushDeliveryProof', () {
    test(
        'Patrol-missing state emits ONE skipped line and exits 0 '
        '(env-gated inert)', () async {
      final sink = _BufferedSink();
      final exitCode = await runPushDeliveryProof(
        env: const <String, String>{
          'PATROL_DEVICE_A_ID': 'emulator-5554',
          'PATROL_DEVICE_B_ID': 'emulator-5556',
          'PROXY_URL': 'https://preview.forgeflow.app',
          'PROXY_OPERATOR_TOKEN_A': 'tok-a',
          'PROXY_OPERATOR_TOKEN_B': 'tok-b',
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        declaredDevDependencies: const <String>['flutter_test'],
      );
      await sink.close();

      expect(exitCode, 0);
      expect(sink.lines, hasLength(1));
      final decoded =
          jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['metric'], 'push_delivery.skipped');
      expect(decoded['state'], 'deferredPatrolMissing');
    });

    test(
        'env-missing state when Patrol is wired but creds absent → '
        'skipped line with env-missing reason, exit 0', () async {
      final sink = _BufferedSink();
      final exitCode = await runPushDeliveryProof(
        env: const <String, String>{
          // No PATROL_DEVICE_A_ID.
          'PATROL_DEVICE_B_ID': 'emulator-5556',
          'PROXY_URL': 'https://preview.forgeflow.app',
          'PROXY_OPERATOR_TOKEN_A': 'tok-a',
          'PROXY_OPERATOR_TOKEN_B': 'tok-b',
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        declaredDevDependencies: const <String>['flutter_test', 'patrol'],
      );
      await sink.close();

      expect(exitCode, 0);
      final decoded =
          jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['state'], 'deferredEnvMissing');
    });

    test('ready state emits the "ready-but-unimplemented" line + exit 0',
        () async {
      final sink = _BufferedSink();
      final exitCode = await runPushDeliveryProof(
        env: const <String, String>{
          'PATROL_DEVICE_A_ID': 'emulator-5554',
          'PATROL_DEVICE_B_ID': 'emulator-5556',
          'PROXY_URL': 'https://preview.forgeflow.app',
          'PROXY_OPERATOR_TOKEN_A': 'tok-a',
          'PROXY_OPERATOR_TOKEN_B': 'tok-b',
        },
        output: sink.ioSink,
        clock: () => DateTime.utc(2026, 5, 13),
        declaredDevDependencies: const <String>['flutter_test', 'patrol'],
      );
      await sink.close();

      expect(exitCode, 0);
      final decoded =
          jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['state'], 'ready_but_unimplemented');
      expect(decoded['reason'], contains('Follow-up'));
    });
  });

  test(
      'kDeclaredDevDependencies does NOT yet declare patrol — when it '
      'does, the wired branch unlocks', () {
    // Pinning test: if patrol is added to pubspec.yaml and the
    // const list updates accordingly, this test enforces a code
    // review by failing loudly.
    expect(kDeclaredDevDependencies.contains('patrol'), isFalse,
        reason: 'When patrol lands in pubspec.yaml dev_dependencies, '
            'add "patrol" to kDeclaredDevDependencies in '
            'tool/pressure/p5_push_delivery_proof.dart AND replace '
            'the ready-state stub with the actual two-device proof '
            'body; then update this pinning expectation to isTrue.');
  });
}

/// Buffered IOSink that captures every `writeln` line into an in-memory
/// list.
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
