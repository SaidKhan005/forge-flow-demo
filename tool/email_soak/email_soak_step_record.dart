// Wave 2 Q-2a — per-step record emitted by the email soak orchestrator.
//
// Mirrors the shape of `p4_soak_orchestrator.dart`'s sample records:
// every step the orchestrator runs (trigger / inbox-poll / webhook-poll)
// emits one of these so the report writer can compute aggregate
// latencies + a per-path narrative.
//
// The orchestrator does NOT persist step records to disk by default;
// the per-scenario JSON outcome line carries the aggregate signal. The
// record type is exposed so a future deep-debug mode can opt into
// raw-step capture without changing the orchestrator's public surface.

class EmailSoakStepRecord {
  const EmailSoakStepRecord({
    required this.scenarioId,
    required this.stepName,
    required this.startedAt,
    required this.completedAt,
    required this.success,
    this.detail,
  });

  /// Stable scenario id (matches `EmailSoakScenario.scenarioId`).
  final String scenarioId;

  /// Short name of the step (e.g. `trigger`, `mailosaur_poll`,
  /// `webhook_probe_poll`). Stable across runs so a later JSONL
  /// reader can group by step.
  final String stepName;

  final DateTime startedAt;
  final DateTime completedAt;
  final bool success;

  /// Optional human-readable note (e.g. "received message at ...",
  /// "probe returned 503 — probe token unset").
  final String? detail;

  int get latencyMs =>
      completedAt.difference(startedAt).inMilliseconds;

  Map<String, Object?> toJson() => <String, Object?>{
        'scenario': scenarioId,
        'step': stepName,
        'started_at': startedAt.toUtc().toIso8601String(),
        'completed_at': completedAt.toUtc().toIso8601String(),
        'latency_ms': latencyMs,
        'success': success,
        if (detail != null) 'detail': detail,
      };
}
