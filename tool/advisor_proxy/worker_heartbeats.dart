// Wave 2 B-2B — worker heartbeat observability surface.
//
// Origin: `docs/_indices/WAVE_2_LEDGER.md` row B-2B ("BUG-2 triage: proxy
// crash after some time"). The A1 investigation
// (`docs/_audits/code_health/a1_proxy_bug_root_cause.md` §2.4) identified
// that worker silent-stall + tick-handler-throw paths are the most likely
// observability blind spot for the "crashes after some time" symptom:
//
//   * `worker_startup_wiring.dart` fans pg_cron NOTIFY ticks into
//     `unawaited(Future<void>(() async { ... }))` blocks with an
//     `onTickError` log hook, but the proxy /health envelope has no
//     surface that tells an operator "is the worker still ticking?"
//     A wedged consumer (deadlocked transaction, in-flight handler
//     stuck on a long Postgres call, lost LISTEN connection) emits
//     no signal until the operator-app-side symptom appears.
//   * The single-flight guards (`auditSweepInFlight`,
//     `piiErasureSweepInFlight`) leave `inFlight = true` if the
//     guarded handler throws AND the finally block fails to reset
//     the flag — defensive, but no /health surface shows the latch
//     state.
//   * Tick error counts go to logs only. There's no /health counter
//     an operator can grep for "tick error rate climbing" without
//     parsing log lines.
//
// This file ships three additions:
//
//   1. [WorkerHeartbeatRegistry] — per-channel snapshot of last tick
//      timestamps, success/failure counts, in-flight latch state, and
//      computed staleness (last tick older than the configured
//      threshold).
//   2. [WorkerHeartbeatRouter] — a `tryHandle(HttpRequest)`-shaped
//      pre-check the proxy entrypoint mounts above the monolithic
//      dispatcher so `GET /v1/health/workers` returns a JSON snapshot
//      without touching `advisor_proxy.dart` (the file is at its
//      bleed-stop ceiling — see `tool/advisor_proxy_size_lint.dart`).
//   3. Wiring contract enforced by passing the registry into
//      `wireProductionWorkers(... heartbeatRegistry: registry)`; the
//      listeners thread `recordStart` / `recordSuccess` /
//      `recordFailure` around each handler call.
//
// Posture:
//   * Read-only surface. Never alters worker behavior; pure observability.
//   * Auth: same as `/health` and `/health/deep` — public on Cloud Run
//     because the route surfaces no PII (channel names + integer counts
//     + ISO timestamps). Mirrors the existing `/health` posture.
//   * Defensive: every public method swallows its own exceptions so a
//     bug in the registry can never crash a worker tick (the whole
//     point is to OBSERVE crashes, not introduce new ones).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Default staleness threshold. A channel that has not ticked for
/// longer than this is reported as `stale: true` in the snapshot.
///
/// Chosen to be longer than every cron cadence the proxy listens for:
///
///   * audit_anchor: daily (1440 min)        — opt-out via `expectedTickIntervalSeconds`
///   * rollups: 1 minute                     — covered
///   * email_outbox: 1 minute                — covered
///   * mobile_push_outbox: 1 minute          — covered
///   * pii_erasure_grace: 6 hours (360 min)  — opt-out via `expectedTickIntervalSeconds`
///   * tripwire_poller: 60 s                 — covered
///
/// Per-channel overrides land via [WorkerHeartbeatRegistry.register]'s
/// `expectedTickIntervalSeconds`. The default is a "you should have
/// heard from me by now" floor.
const Duration kDefaultWorkerHeartbeatStaleness = Duration(minutes: 5);

/// Channel metadata + live counters. Mutated by the worker startup
/// wiring on every tick. Snapshots are returned as immutable
/// [WorkerHeartbeatSnapshot] records so `/v1/health/workers` callers
/// see a consistent view.
class WorkerHeartbeatRegistry {
  WorkerHeartbeatRegistry({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, _ChannelState> _channels = <String, _ChannelState>{};

  /// Register a worker channel. Called once per consumer at
  /// `wireProductionWorkers` time. Safe to call again for the same
  /// channel (preserves the existing state — useful for hot-reload
  /// scenarios in dev / test).
  ///
  /// [expectedTickIntervalSeconds] is the per-channel staleness floor.
  /// Pass `null` to use [kDefaultWorkerHeartbeatStaleness]; pass a
  /// value larger than the default for channels whose cron cadence is
  /// hours / days (audit_anchor, pii_erasure_grace).
  void register(
    String channel, {
    int? expectedTickIntervalSeconds,
  }) {
    final existing = _channels[channel];
    if (existing != null) {
      // Preserve counters across re-registration; only refresh the
      // staleness floor. This makes test-time re-wiring safe and keeps
      // dev hot-reload from zeroing the surface.
      existing.staleAfter = _resolveStaleAfter(expectedTickIntervalSeconds);
      return;
    }
    _channels[channel] = _ChannelState(
      registeredAt: _clock().toUtc(),
      staleAfter: _resolveStaleAfter(expectedTickIntervalSeconds),
    );
  }

  /// Record the start of a tick handler. Sets the in-flight latch +
  /// updates `lastTickAt`. Safe to call on an unregistered channel
  /// (auto-registers with default staleness).
  void recordStart(String channel) {
    final state = _ensure(channel);
    try {
      state.inFlight = true;
      state.tickCount += 1;
      state.lastTickAt = _clock().toUtc();
    } catch (_) {
      // Never crash a tick handler from observability code.
    }
  }

  /// Record a successful tick completion. Clears the in-flight latch
  /// and updates `lastSuccessAt`.
  void recordSuccess(String channel) {
    final state = _ensure(channel);
    try {
      state.inFlight = false;
      state.successCount += 1;
      state.lastSuccessAt = _clock().toUtc();
    } catch (_) {
      // Never crash a tick handler from observability code.
    }
  }

  /// Record a failing tick. Clears the in-flight latch, increments
  /// the failure counter, captures the error type for the snapshot.
  void recordFailure(String channel, Object error) {
    final state = _ensure(channel);
    try {
      state.inFlight = false;
      state.failureCount += 1;
      state.lastFailureAt = _clock().toUtc();
      state.lastFailureType = error.runtimeType.toString();
    } catch (_) {
      // Never crash a tick handler from observability code.
    }
  }

  /// Returns a stable snapshot of every registered channel. Callers
  /// are free to serialize the result; the records are deeply
  /// immutable.
  List<WorkerHeartbeatSnapshot> snapshot() {
    final now = _clock().toUtc();
    final result = <WorkerHeartbeatSnapshot>[];
    for (final entry in _channels.entries) {
      final state = entry.value;
      final lastTickAt = state.lastTickAt;
      final stale = lastTickAt == null
          ? now.difference(state.registeredAt) > state.staleAfter
          : now.difference(lastTickAt) > state.staleAfter;
      result.add(
        WorkerHeartbeatSnapshot(
          channel: entry.key,
          registeredAt: state.registeredAt,
          lastTickAt: lastTickAt,
          lastSuccessAt: state.lastSuccessAt,
          lastFailureAt: state.lastFailureAt,
          tickCount: state.tickCount,
          successCount: state.successCount,
          failureCount: state.failureCount,
          inFlight: state.inFlight,
          lastFailureType: state.lastFailureType,
          staleAfter: state.staleAfter,
          stale: stale,
        ),
      );
    }
    // Stable sort for deterministic test assertions + readable JSON.
    result.sort((a, b) => a.channel.compareTo(b.channel));
    return result;
  }

  /// JSON envelope `/v1/health/workers` returns. Aggregates the
  /// snapshot list + a top-level `any_stale` boolean so a single grep
  /// can spot drift.
  Map<String, Object?> snapshotJson() {
    final snapshots = snapshot();
    return <String, Object?>{
      'ts': _clock().toUtc().toIso8601String(),
      'any_stale': snapshots.any((s) => s.stale),
      'any_in_flight': snapshots.any((s) => s.inFlight),
      'channels': snapshots.map((s) => s.toJson()).toList(growable: false),
    };
  }

  _ChannelState _ensure(String channel) {
    return _channels.putIfAbsent(
      channel,
      () => _ChannelState(
        registeredAt: _clock().toUtc(),
        staleAfter: kDefaultWorkerHeartbeatStaleness,
      ),
    );
  }

  Duration _resolveStaleAfter(int? expectedTickIntervalSeconds) {
    if (expectedTickIntervalSeconds == null) {
      return kDefaultWorkerHeartbeatStaleness;
    }
    // Allow 3x the cadence before flagging stale. A 1-minute cadence
    // tolerates a 3-minute hiccup; a 1-day cadence tolerates a 3-day
    // hiccup. The floor is the configured default so very fast cadences
    // (1 s tripwire poller) still get a reasonable threshold.
    final raw = Duration(seconds: expectedTickIntervalSeconds * 3);
    return raw < kDefaultWorkerHeartbeatStaleness
        ? kDefaultWorkerHeartbeatStaleness
        : raw;
  }
}

/// Immutable per-channel snapshot returned by
/// [WorkerHeartbeatRegistry.snapshot]. Fields are JSON-shaped: nullable
/// timestamps map to ISO-8601 strings, non-null integers map directly.
class WorkerHeartbeatSnapshot {
  const WorkerHeartbeatSnapshot({
    required this.channel,
    required this.registeredAt,
    required this.lastTickAt,
    required this.lastSuccessAt,
    required this.lastFailureAt,
    required this.tickCount,
    required this.successCount,
    required this.failureCount,
    required this.inFlight,
    required this.lastFailureType,
    required this.staleAfter,
    required this.stale,
  });

  final String channel;
  final DateTime registeredAt;
  final DateTime? lastTickAt;
  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;
  final int tickCount;
  final int successCount;
  final int failureCount;
  final bool inFlight;
  final String? lastFailureType;
  final Duration staleAfter;
  final bool stale;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'channel': channel,
      'registered_at': registeredAt.toIso8601String(),
      'last_tick_at': lastTickAt?.toIso8601String(),
      'last_success_at': lastSuccessAt?.toIso8601String(),
      'last_failure_at': lastFailureAt?.toIso8601String(),
      'tick_count': tickCount,
      'success_count': successCount,
      'failure_count': failureCount,
      'in_flight': inFlight,
      'last_failure_type': lastFailureType,
      'stale_after_seconds': staleAfter.inSeconds,
      'stale': stale,
    };
  }
}

/// Mutable per-channel state. Held in a private map so the public
/// surface is the immutable [WorkerHeartbeatSnapshot] record.
class _ChannelState {
  _ChannelState({required this.registeredAt, required this.staleAfter});

  final DateTime registeredAt;
  Duration staleAfter;
  DateTime? lastTickAt;
  DateTime? lastSuccessAt;
  DateTime? lastFailureAt;
  int tickCount = 0;
  int successCount = 0;
  int failureCount = 0;
  bool inFlight = false;
  String? lastFailureType;
}

/// Pre-check router for `GET /v1/health/workers`. Mounted in the proxy
/// entrypoint above the monolithic dispatcher so the existing /health
/// + /health/deep surfaces are untouched.
///
/// Returns 200 with the registry snapshot. Returns 503 with
/// `{"error": "any_stale"}` when one or more channels has missed its
/// staleness floor, so a Cloud Run liveness probe can opt into the
/// stale signal. The Cloud Run startup probe should continue using
/// `/health` (which is always 200 once the listener is bound).
class WorkerHeartbeatRouter {
  WorkerHeartbeatRouter({required WorkerHeartbeatRegistry registry})
      : _registry = registry;

  static const String _path = '/v1/health/workers';

  final WorkerHeartbeatRegistry _registry;

  /// Returns `true` when the request was handled. The caller must NOT
  /// delegate to the main dispatcher in that case.
  Future<bool> tryHandle(HttpRequest request) async {
    if (request.uri.path != _path) return false;
    if (request.method != 'GET') {
      _writeJson(request.response, 405, <String, Object?>{
        'error': 'method_not_allowed',
        'allowed': 'GET',
      });
      return true;
    }
    try {
      final envelope = _registry.snapshotJson();
      final anyStale = envelope['any_stale'] == true;
      _writeJson(request.response, anyStale ? 503 : 200, envelope);
    } catch (error) {
      // Defensive: a bug in the registry must not crash the listener.
      // The /health envelope's design (`pool_gauge_collector_failed`
      // pattern in `ProxyRuntimeGauges.snapshotJson`) is the same
      // posture — collapse to a uniform error field.
      _writeJson(request.response, 500, <String, Object?>{
        'error': 'worker_heartbeat_snapshot_failed',
        'error_type': error.runtimeType.toString(),
      });
    }
    return true;
  }
}

void _writeJson(HttpResponse response, int statusCode, Map<String, Object?> body) {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  response.close();
}

/// Channel identifiers — mirrors the constants from the consumer
/// modules so callers do not have to import the LISTEN constants
/// just to register a heartbeat. Re-exported as readable names so
/// the JSON envelope stays grep-friendly.
const String kHeartbeatChannelAuditAnchor = 'audit_anchor_tick';
const String kHeartbeatChannelRollups = 'rollups_tick';
const String kHeartbeatChannelEmailOutbox = 'email_outbox_tick';
const String kHeartbeatChannelMobilePush = 'mobile_push_outbox_tick';
const String kHeartbeatChannelPiiErasure = 'pii_erasure_grace_tick';
const String kHeartbeatChannelTripwirePoller = 'outbox_tripwire_poller';
