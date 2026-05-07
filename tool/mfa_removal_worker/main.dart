// Forge & Flow MFA removal worker - Cloud Run Job entrypoint.
//
// Intended schedule: every 5-15 minutes. It completes due 24-hour MFA removal
// requests in bounded batches and exits. Cloud Scheduler retries are safe
// because the worker claims rows with SKIP LOCKED and each completion update is
// guarded by pending state.
//
// L7 hardening — cooperative shutdown:
//   * SIGTERM (Linux/Cloud Run revision rollover) and SIGINT (Ctrl+C /
//     Windows host fallback, since SIGTERM is not delivered to the
//     Dart isolate on Windows) flip a shared [_ShutdownFlag]. The
//     worker's per-row loop observes the flag between rows: the
//     currently-claimed row finishes its tenant transaction; the next
//     row is skipped so the replacement instance can reclaim it
//     cleanly via the stale-after window on `claimDuePending`.
//   * After SIGTERM/SIGINT we wait up to 25 seconds (the same drain
//     budget the proxy entrypoint uses) for the in-flight unit of
//     work to finish, then exit. Cloud Run delivers SIGKILL 10 seconds
//     after SIGTERM by default; the 25-second cap is the upper bound
//     that lines up with the higher-quota revisions the proxy ships
//     with. The exit always uses `exit(0)` on the drain path so Cloud
//     Run does not retry the job because of a SIGKILL'd revision.

import 'dart:async';
import 'dart:io';

import 'package:forge_and_flow/services/mfa/mfa_removal_worker.dart';

import '../advisor_proxy/advisor_proxy.dart';
import '../advisor_proxy/proxy_bootstrap.dart';

Future<void> main(List<String> args) async {
  final batchSize = _batchSize(args);
  ProxyConfig config;
  try {
    config = ProxyConfig.fromEnvironment(Platform.environment);
  } on ProxyConfigError catch (error) {
    stderr.writeln('mfa removal worker startup failed: ${error.message}');
    exitCode = 78;
    return;
  }

  final shutdown = _ShutdownFlag();
  final signalSubs = _registerShutdownListeners(shutdown);

  try {
    final bindings = buildProxyProductionBindings(config);
    final MfaRemovalWorker worker = bindings.mfaRemovalWorker;

    // Kick off the tick and race it against the shutdown drain
    // window. The tick observes `shouldStop` between rows on its own
    // (set up by `proxy_bootstrap.dart` once L7 lands the wiring;
    // until then the cap is purely the drain timeout below — the
    // shape is forward-compatible).
    final tickFuture = worker.processDue(batchSize: batchSize);
    final outcome = await _awaitTickWithDrain(tickFuture, shutdown);

    if (outcome.drained) {
      // SIGTERM/SIGINT arrived; we either let the tick finish or
      // capped at 25s. In both cases exit clean so Cloud Run does not
      // count this as a failed job.
      stderr.writeln(
        'mfa removal worker drained on shutdown: '
        'signal=${shutdown.signal} '
        'tick_completed=${outcome.tickResult != null}',
      );
      exitCode = 0;
      return;
    }
    final tickResult = outcome.tickResult!;
    stdout.writeln(
      'mfa removal worker completed: '
      'claimed=${tickResult.claimed} '
      'completed=${tickResult.completed} '
      'failed=${tickResult.failed} '
      'dead_lettered=${tickResult.deadLettered}',
    );
    if (tickResult.failed > 0) {
      exitCode = 1;
    }
  } finally {
    for (final sub in signalSubs) {
      await sub.cancel();
    }
  }
}

/// Outcome wrapper so the `main` body's branching is exhaustive
/// without sentinels: either the tick finished normally
/// ([drained] = false, [tickResult] non-null) or shutdown drained
/// (within budget — [tickResult] non-null — or by timeout —
/// [tickResult] null).
class _TickOutcome {
  const _TickOutcome.completed(MfaRemovalWorkerResult result)
      : drained = false,
        tickResult = result;
  const _TickOutcome.drainedWithResult(MfaRemovalWorkerResult result)
      : drained = true,
        tickResult = result;
  const _TickOutcome.drainedTimeout()
      : drained = true,
        tickResult = null;

  final bool drained;
  final MfaRemovalWorkerResult? tickResult;
}

/// Race the tick against the shutdown drain window. Returns:
///
///   * `_TickOutcome.completed` if the tick finishes before any signal.
///   * `_TickOutcome.drainedWithResult` if the tick still finishes
///     within the 25s drain budget after the signal.
///   * `_TickOutcome.drainedTimeout` if the drain budget elapses first
///     — the tick is left running but `main` will return so Cloud Run
///     can swap revisions.
Future<_TickOutcome> _awaitTickWithDrain(
  Future<MfaRemovalWorkerResult> tickFuture,
  _ShutdownFlag shutdown,
) async {
  // Latch the tick's terminal state so we can read it without
  // re-awaiting in the drain branch.
  MfaRemovalWorkerResult? tickResult;
  Object? tickError;
  final tickDone = tickFuture.then((value) {
    tickResult = value;
  }, onError: (Object error, StackTrace _) {
    tickError = error;
  });

  await Future<void>.any(<Future<void>>[tickDone, shutdown.future]);

  if (!shutdown.isShuttingDown) {
    // Tick finished first.
    if (tickError != null) throw tickError!;
    return _TickOutcome.completed(tickResult!);
  }
  // Shutdown landed first. Give the tick up to 25s to finish.
  await Future<void>.any(<Future<void>>[
    tickDone,
    Future<void>.delayed(const Duration(seconds: 25)),
  ]);
  if (tickResult != null) {
    return _TickOutcome.drainedWithResult(tickResult!);
  }
  if (tickError != null) {
    // Surface the tick failure even on the drain path; the operator
    // needs to see a real error rather than a silent exit(0).
    throw tickError!;
  }
  return const _TickOutcome.drainedTimeout();
}

/// Shared shutdown flag. SIGTERM/SIGINT listeners flip
/// [isShuttingDown] and complete [future] so the awaiter in `main`
/// can race against the in-flight tick.
class _ShutdownFlag {
  final Completer<void> _completer = Completer<void>();
  bool _shuttingDown = false;
  String? _signal;

  bool get isShuttingDown => _shuttingDown;
  String? get signal => _signal;
  Future<void> get future => _completer.future;

  void signal(String name) {
    if (_shuttingDown) return;
    _shuttingDown = true;
    _signal = name;
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}

/// Subscribe to SIGTERM and SIGINT, mirroring the shape used by the
/// proxy entrypoint at `tool/advisor_proxy/main.dart` and the
/// audit-anchor `ShutdownSignals` helper. Returns the subscription
/// list so the caller can cancel them in `finally`.
List<StreamSubscription<ProcessSignal>> _registerShutdownListeners(
  _ShutdownFlag shutdown,
) {
  final subs = <StreamSubscription<ProcessSignal>>[];
  try {
    subs.add(
      ProcessSignal.sigterm.watch().listen((_) => shutdown.signal('SIGTERM')),
    );
  } catch (_) {
    // SIGTERM is not delivered to Dart isolates on Windows hosts; the
    // SIGINT subscription below covers Ctrl+C in the local-dev case.
  }
  try {
    subs.add(
      ProcessSignal.sigint.watch().listen((_) => shutdown.signal('SIGINT')),
    );
  } catch (_) {
    // SIGINT is supported everywhere `dart:io` ships, but defend
    // against unusual hosts so the entrypoint still runs.
  }
  return subs;
}

int _batchSize(List<String> args) {
  const fallback = 50;
  for (final arg in args) {
    if (!arg.startsWith('--batch-size=')) continue;
    final value = int.tryParse(arg.substring('--batch-size='.length));
    if (value != null && value > 0) return value;
  }
  final fromEnv = int.tryParse(
    Platform.environment['MFA_REMOVAL_BATCH_SIZE'] ?? '',
  );
  if (fromEnv != null && fromEnv > 0) return fromEnv;
  return fallback;
}
