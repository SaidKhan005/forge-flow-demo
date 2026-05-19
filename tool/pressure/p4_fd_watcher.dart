// Pressure preview v1 — Slice A11.2 (R3 §3 quick-win) — file-descriptor
// watcher for the long-running soak harnesses.
//
// Sprint authority: `docs/archive/_execution/lane_a_code_health/03_execution_slices.md`
// "Slice A11.2 - Soak Harness Durable Extensions". R3 §3 calls out
// FD-leak detection as one of the cheapest signals to surface during a
// multi-hour soak: the proxy and the harnesses both open `HttpClient`
// + `File` handles, and a leak compounds linearly with run length.
//
// What this watcher does
// ----------------------
// On Linux, periodically counts the number of entries under
// `/proc/self/fd` (the kernel's per-process FD table). On every poll the
// watcher emits ONE structured JSON line on a configurable [IOSink] so
// callers can route the metric to stdout, a file, or a test buffer.
//
//   {
//     "ts": "<iso>",
//     "metric": "soak.fd_count",
//     "value": <int>,
//     "threshold_exceeded": <bool>
//   }
//
// `threshold_exceeded` is `true` when an explicit `threshold` was passed
// to the constructor AND the observed count exceeds it. With the default
// `threshold == null`, the field is always `false` and operators rely on
// post-run trend analysis instead of a hard cap.
//
// Cross-platform behaviour
// ------------------------
// `/proc/self/fd` only exists on Linux. On Windows / macOS / any non-
// Linux host, [start] emits a single "no-op" JSON line documenting the
// platform mismatch and DOES NOT schedule a timer. This keeps the
// harness host-agnostic — operators running smoke probes on a Windows
// dev box see a clear log line instead of a thrown `FileSystemException`.
//
//   {
//     "ts": "<iso>",
//     "metric": "soak.fd_count",
//     "value": null,
//     "platform": "<Platform.operatingSystem>",
//     "note": "fd_watcher: /proc/self/fd not available; watcher is a "
//             "no-op on this platform"
//   }
//
// Lifecycle
// ---------
// [start] schedules the timer (Linux only). [stop] cancels the timer.
// Callers wire `stop()` into a `try/finally` in the harness shutdown
// path mirroring the existing `Timer.periodic` shape in
// `tool/pressure/p4_session_soak.dart` and
// `tool/pressure/p4_operator_day_soak.dart`.
//
// Test seam
// ---------
// The [FdWatcher] takes a [Directory] for the FD-listing root (defaults
// to `/proc/self/fd`) and a [String] platform identifier (defaults to
// `Platform.operatingSystem`). Tests inject both so the cross-platform
// branch can be exercised without a real Linux kernel and the FD count
// can be driven from a synthetic temp directory populated with stub
// files.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Periodic poller of `/proc/self/fd` that emits a structured JSON
/// gauge line on every tick. See file header for the contract.
class FdWatcher {
  /// Construct an FD watcher.
  ///
  /// * [pollInterval] — how often to sample. The shape matches the
  ///   `Timer.periodic` cadence used by the existing soak harnesses
  ///   (typically 30s).
  /// * [output] — sink to write the JSON line to. Defaults to
  ///   [stdout]; tests inject a buffered sink.
  /// * [threshold] — optional FD-count cap. When set, the emitted
  ///   `threshold_exceeded` field flips to `true` once `value` exceeds
  ///   the cap. Defaults to `null` (always reports `false`).
  /// * [fdDirectory] — directory whose entry count IS the FD count.
  ///   Defaults to `/proc/self/fd`. Tests override with a synthetic
  ///   temp directory.
  /// * [platformOverride] — host OS identifier. Defaults to
  ///   [Platform.operatingSystem]; tests inject `'windows'` /
  ///   `'macos'` to exercise the no-op branch.
  /// * [clock] — UTC clock for the `ts` timestamp. Tests inject a
  ///   fixed clock to make snapshot assertions deterministic.
  FdWatcher({
    required this.pollInterval,
    IOSink? output,
    this.threshold,
    Directory? fdDirectory,
    String? platformOverride,
    DateTime Function()? clock,
  })  : _output = output ?? stdout,
        _fdDirectory = fdDirectory ?? Directory('/proc/self/fd'),
        _platform = platformOverride ?? Platform.operatingSystem,
        _clock = clock ?? (() => DateTime.now().toUtc());

  /// How often [_poll] runs.
  final Duration pollInterval;

  /// Optional FD-count cap. See [FdWatcher] constructor docs.
  final int? threshold;

  final IOSink _output;
  final Directory _fdDirectory;
  final String _platform;
  final DateTime Function() _clock;

  Timer? _timer;
  bool _stopped = false;

  /// Whether the watcher is currently polling. False on non-Linux
  /// platforms after [start] (the no-op log was emitted but no timer
  /// is scheduled). Also false after [stop].
  bool get isPolling => _timer?.isActive == true;

  /// Schedule the periodic FD poll.
  ///
  /// On Linux, emits a JSON line every [pollInterval] until [stop] is
  /// called. On non-Linux platforms, emits ONE no-op line and returns
  /// without scheduling a timer.
  void start() {
    if (_stopped) {
      throw StateError('FdWatcher.start() called after stop()');
    }
    if (_timer != null) {
      // Already started; idempotent — silently no-op.
      return;
    }
    if (_platform != 'linux') {
      _emitNoOp();
      return;
    }
    // Emit one sample immediately so the harness's startup banner
    // includes a baseline FD count without waiting one full interval.
    _poll();
    _timer = Timer.periodic(pollInterval, (_) => _poll());
  }

  /// Cancel the timer. Safe to call multiple times. Idempotent across
  /// platforms (no-op when no timer was scheduled).
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  void _poll() {
    int? value;
    try {
      // `listSync(followLinks: false)` mirrors the kernel's view of
      // the FD table without dereferencing the symlinks (each entry
      // under `/proc/self/fd` is a symlink to the open file/socket).
      value = _fdDirectory.listSync(followLinks: false).length;
    } on FileSystemException catch (e) {
      _emit(<String, Object?>{
        'ts': _clock().toIso8601String(),
        'metric': 'soak.fd_count',
        'value': null,
        'error': 'fd_watcher: ${e.osError?.message ?? e.message}',
      });
      return;
    }
    final exceeded = threshold != null && value > threshold!;
    _emit(<String, Object?>{
      'ts': _clock().toIso8601String(),
      'metric': 'soak.fd_count',
      'value': value,
      'threshold_exceeded': exceeded,
    });
  }

  void _emitNoOp() {
    _emit(<String, Object?>{
      'ts': _clock().toIso8601String(),
      'metric': 'soak.fd_count',
      'value': null,
      'platform': _platform,
      'note': 'fd_watcher: /proc/self/fd not available; watcher is a '
          'no-op on this platform',
    });
  }

  void _emit(Map<String, Object?> line) {
    _output.writeln(jsonEncode(line));
  }
}
