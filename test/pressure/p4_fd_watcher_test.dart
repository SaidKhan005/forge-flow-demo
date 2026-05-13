// Slice A11.2 — FdWatcher unit tests.
//
// Covers:
//   * Linux happy path (synthetic FD directory injected via the
//     `fdDirectory` constructor seam; entries simulate `/proc/self/fd`
//     symlinks).
//   * Cross-platform no-op: when `platformOverride` is `'windows'` /
//     `'macos'`, [FdWatcher.start] emits ONE structured "no-op" line
//     and never schedules a timer (so `isPolling` stays `false`).
//   * Threshold-exceeded emission: when `threshold` is set and the
//     observed count crosses it, the emitted line carries
//     `"threshold_exceeded": true`.
//
// Mocks: an in-memory `_BufferedSink` captures the JSON lines; a temp
// directory + `File.create` calls produce synthetic FD entries; a
// fixed clock pins the `ts` field for deterministic snapshot
// assertions.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/pressure/p4_fd_watcher.dart';

void main() {
  group('FdWatcher', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('fd_watcher_test_');
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test(
        'Linux happy path: emits structured FD count from injected '
        'directory', () async {
      // Seed the synthetic FD directory with 4 placeholder files so
      // the watcher reports value=4.
      for (var i = 0; i < 4; i++) {
        File('${tempRoot.path}${Platform.pathSeparator}fd_$i').createSync();
      }
      final sink = _BufferedSink();
      final fixedClock = DateTime.utc(2026, 5, 12, 1, 2, 3);
      final watcher = FdWatcher(
        pollInterval: const Duration(seconds: 30),
        output: sink.ioSink,
        fdDirectory: tempRoot,
        platformOverride: 'linux',
        clock: () => fixedClock,
      );

      watcher.start();
      // The constructor calls _poll() once immediately on Linux; no
      // need to wait for the timer interval.
      watcher.stop();
      await sink.close();

      expect(sink.lines, hasLength(1));
      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['ts'], '2026-05-12T01:02:03.000Z');
      expect(decoded['metric'], 'soak.fd_count');
      expect(decoded['value'], 4);
      expect(decoded['threshold_exceeded'], false);
    });

    test(
        'cross-platform no-op: Windows host emits a single explanatory '
        'line and does not schedule a timer', () async {
      final sink = _BufferedSink();
      final watcher = FdWatcher(
        pollInterval: const Duration(seconds: 30),
        output: sink.ioSink,
        fdDirectory: tempRoot,
        platformOverride: 'windows',
        clock: () => DateTime.utc(2026, 5, 12, 1, 2, 3),
      );

      watcher.start();
      // Wait for any pending microtasks; on a non-Linux host no timer
      // should fire even if we wait.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(watcher.isPolling, isFalse);
      watcher.stop();
      await sink.close();

      expect(sink.lines, hasLength(1));
      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['metric'], 'soak.fd_count');
      expect(decoded['value'], isNull);
      expect(decoded['platform'], 'windows');
      expect(
        decoded['note'],
        contains('fd_watcher: /proc/self/fd not available'),
      );
    });

    test(
        'cross-platform no-op: macOS host also emits single explanatory '
        'line', () async {
      final sink = _BufferedSink();
      final watcher = FdWatcher(
        pollInterval: const Duration(seconds: 30),
        output: sink.ioSink,
        fdDirectory: tempRoot,
        platformOverride: 'macos',
        clock: () => DateTime.utc(2026, 5, 12, 1, 2, 3),
      );

      watcher.start();
      watcher.stop();
      await sink.close();

      expect(sink.lines, hasLength(1));
      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['platform'], 'macos');
    });

    test(
        'threshold_exceeded flips to true when observed count crosses '
        'the configured cap', () async {
      // Seed 7 files; threshold=5 → exceeded.
      for (var i = 0; i < 7; i++) {
        File('${tempRoot.path}${Platform.pathSeparator}fd_$i').createSync();
      }
      final sink = _BufferedSink();
      final watcher = FdWatcher(
        pollInterval: const Duration(seconds: 30),
        output: sink.ioSink,
        threshold: 5,
        fdDirectory: tempRoot,
        platformOverride: 'linux',
        clock: () => DateTime.utc(2026, 5, 12),
      );

      watcher.start();
      watcher.stop();
      await sink.close();

      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['value'], 7);
      expect(decoded['threshold_exceeded'], true);
    });

    test(
        'threshold_exceeded stays false when observed count is at or '
        'below the cap', () async {
      // Seed 5 files; threshold=5 → exceeded only when STRICTLY greater.
      for (var i = 0; i < 5; i++) {
        File('${tempRoot.path}${Platform.pathSeparator}fd_$i').createSync();
      }
      final sink = _BufferedSink();
      final watcher = FdWatcher(
        pollInterval: const Duration(seconds: 30),
        output: sink.ioSink,
        threshold: 5,
        fdDirectory: tempRoot,
        platformOverride: 'linux',
        clock: () => DateTime.utc(2026, 5, 12),
      );

      watcher.start();
      watcher.stop();
      await sink.close();

      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['value'], 5);
      expect(decoded['threshold_exceeded'], false);
    });

    test('start() after stop() throws StateError', () {
      final sink = _BufferedSink();
      final watcher = FdWatcher(
        pollInterval: const Duration(seconds: 30),
        output: sink.ioSink,
        fdDirectory: tempRoot,
        platformOverride: 'windows',
      );
      watcher.stop();
      expect(watcher.start, throwsStateError);
    });

    test(
        'missing fd directory on Linux emits an "error" line instead '
        'of throwing', () async {
      final sink = _BufferedSink();
      final missing = Directory(
        '${tempRoot.path}${Platform.pathSeparator}does_not_exist',
      );
      final watcher = FdWatcher(
        pollInterval: const Duration(seconds: 30),
        output: sink.ioSink,
        fdDirectory: missing,
        platformOverride: 'linux',
        clock: () => DateTime.utc(2026, 5, 12),
      );

      watcher.start();
      watcher.stop();
      await sink.close();

      expect(sink.lines, hasLength(1));
      final decoded = jsonDecode(sink.lines.single) as Map<String, Object?>;
      expect(decoded['metric'], 'soak.fd_count');
      expect(decoded['value'], isNull);
      expect(decoded['error'], contains('fd_watcher'));
    });
  });
}

/// Captures `IOSink.writeln(...)` calls into a list of decoded lines.
/// Mirrors the buffered-sink pattern in
/// `test/pressure/p3c_oauth_refresh_storm_runner_test.dart`.
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

  Future<void> close() async {
    await _ioSink.flush();
    await _ioSink.close();
    await _controller.close();
  }

  List<String> get lines => _buffer
      .toString()
      .split('\n')
      .where((line) => line.isNotEmpty)
      .toList();
}
