// Phase Production Cutover — `cutover.0b` Tier-M perf-gate runner.
//
// Authority:
//   * docs/phases/phase_production_cutover/phase_production_cutover_plan.md
//     (cutover.0b section).
//   * docs/phases/phase_11a/phase_11a_decision_register.md
//     — AGE benchmark gate (Lock 3 / Production Hardening Locks):
//       isolated p95 <= 500 ms; 10x concurrent p95 <= 1000 ms.
//     — LLM resilience (Lock 7): p99 latency > 3x baseline trips the
//       circuit breaker, so the synthesis stage red threshold is anchored
//       to that ratio.
//   * tool/vector_index_health/vector_index_health.dart
//     — `VectorIndexHealthBudgets.exampleStartingBudgets` is the first
//       checked-in budget set for HNSW filtered retrieval (p50 yellow=30 /
//       red=80; p95 yellow=100 / red=250; p99 yellow=200 / red=500;
//       filtered p95 yellow=150 / red=350). Mirrored here for the
//       advisor query mix.
//   * runbooks/tier_m_perf_gate_runbook.md — operator-facing runbook
//     this tool emits a plan into.
//
// What this tool does:
//   * Default mode is plan-only. Prints the Tier-M profile (one
//     holding-company operator at 250-500 locations / 5,000-25,000
//     staff per `phase_9_scalability_performance_audit_2026-04-27.md`
//     line 88-99), the four advisor query stages (BM25, vector, AGE,
//     synthesis), the per-stage iteration floor (1000), the locked
//     thresholds, and the live preflight checklist. No SQL written;
//     no database touched.
//   * `--preflight` runs a name-only preflight: confirms the three
//     inputs (Production1 connection name, Tier-M seed name, benchmark
//     harness name) are present in env / on disk. Prints `PREFLIGHT
//     BLOCKED` with the missing names and exits non-zero if anything
//     is missing.
//   * `--ingest-pgbench=<stage>=<path>` (repeatable, one entry per
//     Tier-M stage) parses pgbench `--log` files captured during the
//     authorized live run, builds the canonical RecordedResults
//     envelope, optionally writes it to disk via
//     `--write-results-json=<path>`, and runs the verdict path. This
//     is the bridge from raw pgbench output to the runner's input.
//   * `--record-results=<path>` reads the canonical RecordedResults
//     JSON file (which carries a `profile` block with operators,
//     iterations, stages, concurrency, and the recorded Tier-M
//     locations/staff metadata) and runs the verdict. The verdict
//     refuses to clear the gate if the recorded profile does not
//     match the locked Tier-M shape or if any stage's sample count
//     is below the per-stage iteration floor.
//
// What this tool does NOT do (slice hard constraints):
//   * Never imports `package:postgres`. There is no live connection
//     here. CLAUDE.md forbids raw `package:postgres` imports outside
//     `lib/infrastructure/persistence/postgres/`; this tool stays on
//     the right side of that line.
//   * Never mutates Production1. This is a read-only measurement
//     gate. The runbook executes the live SELECT/EXPLAIN ANALYZE
//     traffic; the tool computes percentiles and verdict.
//   * Never emits secrets. Preflight reports presence-or-absence by
//     env-var *name*; the tool never reads the value of a connection
//     string and never echoes it back.
//   * Never invents thresholds. Every red / yellow line traces to the
//     authority files listed above. If a threshold is not yet locked
//     for a stage, the verdict for that stage is `INCOMPLETE`, never
//     a silent green.
//
// Tier-M results JSON shape (consumed by `--record-results`, emitted
// by `--ingest-pgbench --write-results-json`). Every `profile` field
// below is REQUIRED — `tier_m_locations` and `tier_m_staff` are
// mandatory scale evidence and the parser rejects any envelope
// missing them with exit 2. `tier_m_locations` must be >= 250 and
// `tier_m_staff` must be >= 5000 (audit lower bound).
//
// ```
// {
//   "profile": {
//     "operators": 1,
//     "iterations": 1000,
//     "stages": ["bm25", "vector", "age", "synthesis"],
//     "concurrency": "isolated",       // required: "isolated" or "x10"
//     "tier_m_locations": 250,         // required, >= 250
//     "tier_m_staff": 5000             // required, >= 5000
//   },
//   "stages": {
//     "bm25":      {"latency_ms": [12.3, 15.1, ...]},
//     "vector":    {"latency_ms": [...]},
//     "age":       {"latency_ms": [...]},
//     "synthesis": {"latency_ms": [...]}
//   }
// }
// ```
//
// CLI shape:
//
//   # Plan only (default).
//   dart run tool/perf_gate/tier_m_runner.dart
//
//   # Name-only preflight.
//   dart run tool/perf_gate/tier_m_runner.dart --preflight
//
//   # Compute verdict from recorded timings.
//   dart run tool/perf_gate/tier_m_runner.dart \
//     --record-results=build/perf_gate/tier_m_results.json
//
//   # Specify a different concurrency profile (default: isolated).
//   dart run tool/perf_gate/tier_m_runner.dart \
//     --record-results=build/perf_gate/tier_m_results_x10.json \
//     --concurrency=x10

import 'dart:convert';
import 'dart:io';

// ─── Tier-M profile constants ────────────────────────────────────────

/// Tier-M is the per-operator holding-company scale defined in
/// `phase_9_scalability_performance_audit_2026-04-27.md` line 88-99:
/// 250-500 locations and 5,000-25,000 staff per operator, multi-brand
/// hierarchy, heavy ingest, high audit / advisor / reporting volume.
/// The cutover.0b advisor gate runs the advisor query mix against ONE
/// Tier-M holding-company operator (the launch worst-case
/// per-operator scale), distinct from the 500-OPERATOR rollups
/// Tier-M (B38) which exercises tenant breadth on a different code
/// path. The lower bound (250 locations / 5,000 staff) is the
/// minimum Tier-M shape the gate will accept; the upper bound is
/// recorded for documentation only.
const int kTierMOperators = 1;
const int kTierMLocationsMin = 250;
const int kTierMLocationsMax = 500;
const int kTierMStaffMin = 5000;
const int kTierMStaffMax = 25000;

/// Iteration count per stage per concurrency profile. 1000 iterations
/// give a stable p95 / p99 estimate at Tier-M scale without burning
/// multi-thousand-dollar provider budgets. The verdict path treats
/// any stage whose recorded sample count is below this floor as
/// INCOMPLETE rather than silently passing.
const int kTierMIterations = 1000;

/// The advisor query mix executed in order per iteration: BM25 lexical
/// candidate retrieval, pgvector candidate retrieval, AGE traversal,
/// Anthropic synthesis (claude-haiku-4-5 classifier + claude-sonnet
/// answer). Stage names match `db/migrations/202604250003_advisor_vector_search.sql`
/// (`advisor_search_chunks` covers BM25 + vector inside one function),
/// `db/migrations/202604280008_phase_9_0sigma_i_graph_canonical.sql`
/// (AGE projection), and `lib/services/claude_llm_provider.dart`
/// (synthesis).
const List<String> kTierMStages = <String>[
  'bm25',
  'vector',
  'age',
  'synthesis',
];

// ─── Locked thresholds (per authority files) ─────────────────────────

/// AGE Lock 3 / phase_11a_decision_register.md line 474:
/// "Benchmark gate: isolated p95 must be <= 500ms".
const double kAgeP95RedIsolatedMs = 500.0;

/// AGE Lock 3 / phase_11a_decision_register.md line 474-475:
/// "10x concurrent p95 must be <= 1000ms".
const double kAgeP95RedConcurrentX10Ms = 1000.0;

/// HNSW filtered retrieval — `vector_index_health.dart`
/// `VectorIndexHealthBudgets.exampleStartingBudgets`. These are the
/// first checked-in budget set, mirrored here so the advisor perf
/// gate uses the same numbers the vector index health surface uses.
const double kVectorP50YellowMs = 30.0;
const double kVectorP50RedMs = 80.0;
const double kVectorP95YellowMs = 100.0;
const double kVectorP95RedMs = 250.0;
const double kVectorP99YellowMs = 200.0;
const double kVectorP99RedMs = 500.0;

/// BM25 lexical retrieval. Not locked in the decision register yet —
/// floors anchored to the same shape as vector retrieval until the
/// first live run sets a corpus-specific floor. The verdict path
/// flags BM25 thresholds as `provisional` so a future tuning slice
/// can re-anchor them without paper-over.
const double kBm25P50YellowMs = 30.0;
const double kBm25P50RedMs = 80.0;
const double kBm25P95YellowMs = 100.0;
const double kBm25P95RedMs = 250.0;
const double kBm25P99YellowMs = 200.0;
const double kBm25P99RedMs = 500.0;
const bool kBm25ThresholdsProvisional = true;

/// Synthesis stage red threshold is anchored to Lock 7 (LLM circuit
/// breaker open trigger): `p99 latency > 3x baseline`. The baseline
/// here is the synthesis median observed during the live preflight
/// (recorded into the runbook). The verdict treats `p99 > 3x p50` as
/// red; the absolute floor is recorded but not gated until a launch
/// baseline lands.
const double kSynthesisP99OverP50RedRatio = 3.0;

// ─── Pure data shapes ────────────────────────────────────────────────

enum ConcurrencyProfile {
  isolated,
  x10;

  String get jsonName {
    switch (this) {
      case ConcurrencyProfile.isolated:
        return 'isolated';
      case ConcurrencyProfile.x10:
        return 'x10';
    }
  }

  static ConcurrencyProfile parse(String value) {
    switch (value) {
      case 'isolated':
        return ConcurrencyProfile.isolated;
      case 'x10':
        return ConcurrencyProfile.x10;
      default:
        throw PerfGateException(
          'unknown --concurrency value "$value" '
          '(expected "isolated" or "x10")',
        );
    }
  }
}

/// One stage's verdict against its locked thresholds.
enum StageStatus {
  pass,
  fail,
  incomplete;

  String get jsonName {
    switch (this) {
      case StageStatus.pass:
        return 'PASS';
      case StageStatus.fail:
        return 'FAIL';
      case StageStatus.incomplete:
        return 'INCOMPLETE';
    }
  }
}

class StageThresholds {
  const StageThresholds({
    required this.stage,
    required this.p50YellowMs,
    required this.p50RedMs,
    required this.p95YellowMs,
    required this.p95RedMs,
    required this.p99YellowMs,
    required this.p99RedMs,
    this.p99OverP50RedRatio,
    this.provisional = false,
  });

  final String stage;
  final double? p50YellowMs;
  final double? p50RedMs;
  final double? p95YellowMs;
  final double? p95RedMs;
  final double? p99YellowMs;
  final double? p99RedMs;

  /// Anchored to Lock 7 for the synthesis stage. Absent for stages
  /// that gate on absolute percentiles only.
  final double? p99OverP50RedRatio;

  /// `true` when the threshold values are anchored by analogy
  /// (BM25 today) rather than by a contract-locked floor. The verdict
  /// surfaces this so a future tuning slice can re-anchor cleanly.
  final bool provisional;

  Map<String, Object?> toJson() => <String, Object?>{
    'stage': stage,
    'p50_yellow_ms': p50YellowMs,
    'p50_red_ms': p50RedMs,
    'p95_yellow_ms': p95YellowMs,
    'p95_red_ms': p95RedMs,
    'p99_yellow_ms': p99YellowMs,
    'p99_red_ms': p99RedMs,
    'p99_over_p50_red_ratio': p99OverP50RedRatio,
    'provisional': provisional,
  };
}

/// Builds the locked thresholds per stage given a concurrency
/// profile. AGE swaps its p95 red threshold for the 10x-concurrent
/// number when the operator records under that profile.
List<StageThresholds> lockedThresholds(ConcurrencyProfile profile) {
  final ageP95Red = profile == ConcurrencyProfile.x10
      ? kAgeP95RedConcurrentX10Ms
      : kAgeP95RedIsolatedMs;
  return <StageThresholds>[
    const StageThresholds(
      stage: 'bm25',
      p50YellowMs: kBm25P50YellowMs,
      p50RedMs: kBm25P50RedMs,
      p95YellowMs: kBm25P95YellowMs,
      p95RedMs: kBm25P95RedMs,
      p99YellowMs: kBm25P99YellowMs,
      p99RedMs: kBm25P99RedMs,
      provisional: kBm25ThresholdsProvisional,
    ),
    const StageThresholds(
      stage: 'vector',
      p50YellowMs: kVectorP50YellowMs,
      p50RedMs: kVectorP50RedMs,
      p95YellowMs: kVectorP95YellowMs,
      p95RedMs: kVectorP95RedMs,
      p99YellowMs: kVectorP99YellowMs,
      p99RedMs: kVectorP99RedMs,
    ),
    StageThresholds(
      stage: 'age',
      p50YellowMs: null,
      p50RedMs: null,
      p95YellowMs: null,
      p95RedMs: ageP95Red,
      p99YellowMs: null,
      p99RedMs: null,
    ),
    const StageThresholds(
      stage: 'synthesis',
      p50YellowMs: null,
      p50RedMs: null,
      p95YellowMs: null,
      p95RedMs: null,
      p99YellowMs: null,
      p99RedMs: null,
      p99OverP50RedRatio: kSynthesisP99OverP50RedRatio,
    ),
  ];
}

/// Computed percentile triple for a stage.
class StagePercentiles {
  const StagePercentiles({
    required this.p50Ms,
    required this.p95Ms,
    required this.p99Ms,
    required this.sampleCount,
  });

  final double p50Ms;
  final double p95Ms;
  final double p99Ms;
  final int sampleCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'p50_ms': p50Ms,
    'p95_ms': p95Ms,
    'p99_ms': p99Ms,
    'sample_count': sampleCount,
  };
}

class StageVerdict {
  StageVerdict({
    required this.stage,
    required this.status,
    required this.thresholds,
    this.percentiles,
    this.failureReasons = const <String>[],
  });

  final String stage;
  final StageStatus status;
  final StageThresholds thresholds;
  final StagePercentiles? percentiles;
  final List<String> failureReasons;

  Map<String, Object?> toJson() => <String, Object?>{
    'stage': stage,
    'status': status.jsonName,
    'thresholds': thresholds.toJson(),
    'percentiles': percentiles?.toJson(),
    'failure_reasons': failureReasons,
  };
}

class GateVerdict {
  GateVerdict({
    required this.profile,
    required this.concurrency,
    required this.stageVerdicts,
  });

  final TierMProfile profile;
  final ConcurrencyProfile concurrency;
  final List<StageVerdict> stageVerdicts;

  /// Overall PASS only when every stage is PASS. Any FAIL → FAIL.
  /// Any INCOMPLETE without a FAIL → INCOMPLETE (do not silently
  /// upgrade missing samples to green).
  StageStatus get overall {
    var hasIncomplete = false;
    for (final v in stageVerdicts) {
      if (v.status == StageStatus.fail) {
        return StageStatus.fail;
      }
      if (v.status == StageStatus.incomplete) {
        hasIncomplete = true;
      }
    }
    return hasIncomplete ? StageStatus.incomplete : StageStatus.pass;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'profile': profile.toJson(),
    'concurrency': concurrency.jsonName,
    'overall': overall.jsonName,
    'stages': stageVerdicts.map((v) => v.toJson()).toList(),
  };
}

class TierMProfile {
  const TierMProfile({
    this.operators = kTierMOperators,
    this.iterations = kTierMIterations,
    this.stages = kTierMStages,
  });

  final int operators;
  final int iterations;
  final List<String> stages;

  Map<String, Object?> toJson() => <String, Object?>{
    'operators': operators,
    'iterations': iterations,
    'stages': stages,
  };
}

// ─── Percentile math ─────────────────────────────────────────────────

/// Nearest-rank percentile over a non-empty list. The list is sorted
/// in place (callers pass a fresh copy if they need the original
/// order). `percentile` is in `(0.0, 100.0]`.
double percentile(List<double> sortedAscending, double percentileValue) {
  if (sortedAscending.isEmpty) {
    throw PerfGateException(
      'percentile() requires a non-empty sample list',
    );
  }
  if (percentileValue <= 0 || percentileValue > 100) {
    throw PerfGateException(
      'percentile() requires percentile in (0, 100], got $percentileValue',
    );
  }
  final n = sortedAscending.length;
  final rank = (percentileValue / 100.0 * n).ceil();
  final idx = rank < 1 ? 0 : (rank > n ? n - 1 : rank - 1);
  return sortedAscending[idx];
}

StagePercentiles computeStagePercentiles(List<double> samples) {
  final sorted = List<double>.of(samples)..sort();
  return StagePercentiles(
    p50Ms: percentile(sorted, 50),
    p95Ms: percentile(sorted, 95),
    p99Ms: percentile(sorted, 99),
    sampleCount: sorted.length,
  );
}

// ─── Verdict logic ───────────────────────────────────────────────────

/// Evaluate one stage against its locked thresholds.
///
/// Comparison semantics: failures use strict `>` so the locked
/// thresholds (e.g. AGE Lock 3 "p95 must be <= 500ms"; Lock 7
/// "p99 latency > 3x baseline") are honored as PASS lines. Exact
/// boundary values (p95 = 500.0 ms, p99/p50 ratio = 3.0) PASS.
///
/// Sample-count floor: any stage whose recorded sample count is
/// below [requiredSamples] is INCOMPLETE, not PASS — under-sampled
/// runs do not silently clear the gate.
StageVerdict evaluateStage({
  required String stage,
  required StageThresholds thresholds,
  required List<double> samples,
  required int requiredSamples,
}) {
  if (samples.isEmpty) {
    return StageVerdict(
      stage: stage,
      status: StageStatus.incomplete,
      thresholds: thresholds,
      failureReasons: const <String>['no samples recorded for this stage'],
    );
  }
  final pcts = computeStagePercentiles(samples);
  if (pcts.sampleCount < requiredSamples) {
    return StageVerdict(
      stage: stage,
      status: StageStatus.incomplete,
      thresholds: thresholds,
      percentiles: pcts,
      failureReasons: <String>[
        'recorded ${pcts.sampleCount} samples; Tier-M requires $requiredSamples per stage',
      ],
    );
  }

  final reasons = <String>[];

  if (thresholds.p50RedMs != null && pcts.p50Ms > thresholds.p50RedMs!) {
    reasons.add(
      'p50 ${_fmt(pcts.p50Ms)} ms > red threshold '
      '${_fmt(thresholds.p50RedMs!)} ms',
    );
  }
  if (thresholds.p95RedMs != null && pcts.p95Ms > thresholds.p95RedMs!) {
    reasons.add(
      'p95 ${_fmt(pcts.p95Ms)} ms > red threshold '
      '${_fmt(thresholds.p95RedMs!)} ms',
    );
  }
  if (thresholds.p99RedMs != null && pcts.p99Ms > thresholds.p99RedMs!) {
    reasons.add(
      'p99 ${_fmt(pcts.p99Ms)} ms > red threshold '
      '${_fmt(thresholds.p99RedMs!)} ms',
    );
  }
  if (thresholds.p99OverP50RedRatio != null && pcts.p50Ms > 0) {
    final ratio = pcts.p99Ms / pcts.p50Ms;
    if (ratio > thresholds.p99OverP50RedRatio!) {
      reasons.add(
        'p99/p50 ratio ${_fmt(ratio)} > red threshold '
        '${_fmt(thresholds.p99OverP50RedRatio!)} (Lock 7 circuit breaker)',
      );
    }
  }

  return StageVerdict(
    stage: stage,
    status: reasons.isEmpty ? StageStatus.pass : StageStatus.fail,
    thresholds: thresholds,
    percentiles: pcts,
    failureReasons: reasons,
  );
}

GateVerdict evaluateGate({
  required TierMProfile profile,
  required ConcurrencyProfile concurrency,
  required Map<String, List<double>> stageSamples,
}) {
  final thresholdsList = lockedThresholds(concurrency);
  final byStage = <String, StageThresholds>{
    for (final t in thresholdsList) t.stage: t,
  };
  final verdicts = <StageVerdict>[];
  for (final stage in profile.stages) {
    final t = byStage[stage];
    if (t == null) {
      verdicts.add(
        StageVerdict(
          stage: stage,
          status: StageStatus.incomplete,
          thresholds: const StageThresholds(
            stage: 'unknown',
            p50YellowMs: null,
            p50RedMs: null,
            p95YellowMs: null,
            p95RedMs: null,
            p99YellowMs: null,
            p99RedMs: null,
          ),
          failureReasons: <String>['no locked thresholds for stage "$stage"'],
        ),
      );
      continue;
    }
    final samples = stageSamples[stage] ?? const <double>[];
    verdicts.add(
      evaluateStage(
        stage: stage,
        thresholds: t,
        samples: samples,
        requiredSamples: profile.iterations,
      ),
    );
  }
  return GateVerdict(
    profile: profile,
    concurrency: concurrency,
    stageVerdicts: verdicts,
  );
}

// ─── Preflight (name-only) ───────────────────────────────────────────

class PreflightInputs {
  const PreflightInputs({
    required this.production1ConnectionEnvName,
    required this.tierMSeedManifestPath,
    required this.benchmarkHarnessPath,
  });

  /// Env-var NAME (not value) the proxy / runbook reads to reach
  /// Production1. `--preflight` checks `Platform.environment` for
  /// presence; never reads the value.
  final String production1ConnectionEnvName;

  /// Filesystem path to the Tier-M advisor seed manifest the live
  /// run consumes. Default: `build/perf_gate/tier_m_advisor_seed.manifest.json`.
  final String tierMSeedManifestPath;

  /// Filesystem path to the benchmark harness the live run executes.
  /// Default: `build/perf_gate/tier_m_advisor_harness.sql`.
  final String benchmarkHarnessPath;

  static const PreflightInputs defaults = PreflightInputs(
    production1ConnectionEnvName: 'FORGE_FLOW_PRODUCTION1_DATABASE_URL',
    tierMSeedManifestPath: 'build/perf_gate/tier_m_advisor_seed.manifest.json',
    benchmarkHarnessPath: 'build/perf_gate/tier_m_advisor_harness.sql',
  );
}

class PreflightResult {
  const PreflightResult({
    required this.cleared,
    required this.checks,
  });

  final bool cleared;
  final List<PreflightCheck> checks;
}

class PreflightCheck {
  const PreflightCheck({
    required this.name,
    required this.cleared,
    required this.evidence,
  });

  final String name;
  final bool cleared;

  /// Short presence-or-absence string. NEVER includes the value of
  /// the env var or the contents of the file.
  final String evidence;
}

PreflightResult runPreflight(
  PreflightInputs inputs, {
  Map<String, String>? environment,
  bool Function(String path)? fileExists,
}) {
  final env = environment ?? Platform.environment;
  final exists = fileExists ?? ((p) => FileSystemEntity.typeSync(p) !=
      FileSystemEntityType.notFound);

  final hasConn = env.containsKey(inputs.production1ConnectionEnvName);
  final hasSeed = exists(inputs.tierMSeedManifestPath);
  final hasHarness = exists(inputs.benchmarkHarnessPath);

  final checks = <PreflightCheck>[
    PreflightCheck(
      name: 'production1_connection',
      cleared: hasConn,
      evidence: hasConn
          ? 'env var ${inputs.production1ConnectionEnvName} is set '
                '(value not read)'
          : 'env var ${inputs.production1ConnectionEnvName} is NOT set',
    ),
    PreflightCheck(
      name: 'tier_m_seed_manifest',
      cleared: hasSeed,
      evidence: hasSeed
          ? '${inputs.tierMSeedManifestPath} present'
          : '${inputs.tierMSeedManifestPath} missing',
    ),
    PreflightCheck(
      name: 'benchmark_harness',
      cleared: hasHarness,
      evidence: hasHarness
          ? '${inputs.benchmarkHarnessPath} present'
          : '${inputs.benchmarkHarnessPath} missing',
    ),
  ];
  final cleared = checks.every((c) => c.cleared);
  return PreflightResult(cleared: cleared, checks: checks);
}

// ─── Plan rendering ──────────────────────────────────────────────────

String formatPlanReport({
  TierMProfile profile = const TierMProfile(),
  ConcurrencyProfile concurrency = ConcurrencyProfile.isolated,
}) {
  final sb = StringBuffer();
  sb.writeln('Tier-M perf gate (cutover.0b) — plan report');
  sb.writeln('');
  sb.writeln('Profile (from phase_9_scalability_performance_audit):');
  sb.writeln('  operators (one Tier-M operator)  : ${profile.operators}');
  sb.writeln(
    '  locations per operator            : '
    '$kTierMLocationsMin-$kTierMLocationsMax (lower bound enforced)',
  );
  sb.writeln(
    '  staff per operator                : '
    '$kTierMStaffMin-$kTierMStaffMax (lower bound enforced)',
  );
  sb.writeln(
    '  iterations per stage              : ${profile.iterations} (floor)',
  );
  sb.writeln('  stages                            : ${profile.stages.join(', ')}');
  sb.writeln('  concurrency                       : ${concurrency.jsonName}');
  sb.writeln('');
  sb.writeln('Locked thresholds:');
  for (final t in lockedThresholds(concurrency)) {
    sb.writeln('  - ${t.stage}:');
    if (t.p50RedMs != null) {
      sb.writeln('      p50 red       : ${_fmt(t.p50RedMs!)} ms');
    }
    if (t.p95RedMs != null) {
      sb.writeln('      p95 red       : ${_fmt(t.p95RedMs!)} ms');
    }
    if (t.p99RedMs != null) {
      sb.writeln('      p99 red       : ${_fmt(t.p99RedMs!)} ms');
    }
    if (t.p99OverP50RedRatio != null) {
      sb.writeln(
        '      p99/p50 ratio : '
        '<= ${_fmt(t.p99OverP50RedRatio!)} (Lock 7)',
      );
    }
    if (t.provisional) {
      sb.writeln(
        '      note          : provisional — not contract-locked yet',
      );
    }
  }
  sb.writeln('');
  sb.writeln('Live preflight checklist (name-only):');
  sb.writeln('  - env var FORGE_FLOW_PRODUCTION1_DATABASE_URL is set');
  sb.writeln('  - build/perf_gate/tier_m_advisor_seed.manifest.json exists');
  sb.writeln('  - build/perf_gate/tier_m_advisor_harness.sql exists');
  sb.writeln('');
  sb.writeln('Run channel:');
  sb.writeln(
    '  Live measurements are recorded by the authorized operator '
    'against',
  );
  sb.writeln(
    '  Production1 (read-only). The runbook at '
    'runbooks/tier_m_perf_gate_runbook.md',
  );
  sb.writeln(
    '  contains the EXPLAIN ANALYZE / pgbench / proxy-side commands. '
    'Recorded',
  );
  sb.writeln(
    '  per-iteration timings are written to a JSON file and fed back '
    'through',
  );
  sb.writeln('  --record-results=<path> for the verdict.');
  sb.writeln('');
  sb.writeln('Authority:');
  sb.writeln('  - phase_production_cutover_plan.md (cutover.0b)');
  sb.writeln('  - phase_11a_decision_register.md (Lock 3, Lock 7)');
  sb.writeln('  - tool/vector_index_health/vector_index_health.dart');
  return sb.toString();
}

String formatVerdictReport(GateVerdict verdict) {
  final sb = StringBuffer();
  sb.writeln('Tier-M perf gate (cutover.0b) — verdict');
  sb.writeln('');
  sb.writeln(
    'Concurrency        : ${verdict.concurrency.jsonName}',
  );
  sb.writeln(
    'Operators          : ${verdict.profile.operators}',
  );
  sb.writeln(
    'Iterations / stage : ${verdict.profile.iterations}',
  );
  sb.writeln('');
  sb.writeln('Per-stage breakdown:');
  for (final v in verdict.stageVerdicts) {
    sb.writeln('  - ${v.stage}: ${v.status.jsonName}');
    final pcts = v.percentiles;
    if (pcts != null) {
      sb.writeln(
        '      samples : ${pcts.sampleCount}, '
        'p50=${_fmt(pcts.p50Ms)} ms, '
        'p95=${_fmt(pcts.p95Ms)} ms, '
        'p99=${_fmt(pcts.p99Ms)} ms',
      );
    }
    for (final reason in v.failureReasons) {
      sb.writeln('      reason  : $reason');
    }
    if (v.thresholds.provisional) {
      sb.writeln(
        '      note    : threshold is provisional '
        '(not contract-locked yet)',
      );
    }
  }
  sb.writeln('');
  sb.writeln('Overall: ${verdict.overall.jsonName}');
  return sb.toString();
}

String formatPreflightReport(PreflightResult result) {
  final sb = StringBuffer();
  sb.writeln('Tier-M perf gate (cutover.0b) — preflight (name-only)');
  sb.writeln('');
  for (final c in result.checks) {
    final marker = c.cleared ? '[OK]    ' : '[BLOCK] ';
    sb.writeln('  $marker${c.name}: ${c.evidence}');
  }
  sb.writeln('');
  sb.writeln(
    'Verdict: ${result.cleared ? 'PREFLIGHT OK' : 'PREFLIGHT BLOCKED'}',
  );
  if (!result.cleared) {
    sb.writeln('');
    sb.writeln(
      'cutover.0b is gated until every check above is OK. The '
      'runbook',
    );
    sb.writeln(
      'at runbooks/tier_m_perf_gate_runbook.md describes how the '
      'authorized',
    );
    sb.writeln(
      'operator stages each input. This tool never reads the value '
      'of the',
    );
    sb.writeln('connection env var; presence is the only signal.');
  }
  return sb.toString();
}

// ─── Results ingestion ───────────────────────────────────────────────

/// Parsed results envelope: per-stage samples plus the recorded
/// profile metadata that drives the validation. `tierMLocations`
/// and `tierMStaff` are required so the gate cannot clear without
/// evidence the live run hit the audit Tier-M lower bound.
class RecordedResults {
  const RecordedResults({
    required this.operators,
    required this.iterations,
    required this.stages,
    required this.concurrency,
    required this.stageSamples,
    required this.tierMLocations,
    required this.tierMStaff,
  });

  final int operators;
  final int iterations;
  final List<String> stages;
  final ConcurrencyProfile concurrency;
  final Map<String, List<double>> stageSamples;
  final int tierMLocations;
  final int tierMStaff;
}

/// Reads the recorded-results JSON file. The expected shape:
///
/// ```
/// {
///   "profile": {
///     "operators": 1,
///     "iterations": 1000,
///     "stages": ["bm25","vector","age","synthesis"],
///     "concurrency": "isolated",
///     "tier_m_locations": 250,
///     "tier_m_staff": 5000
///   },
///   "stages": {
///     "bm25":      {"latency_ms": [...]},
///     "vector":    {"latency_ms": [...]},
///     "age":       {"latency_ms": [...]},
///     "synthesis": {"latency_ms": [...]}
///   }
/// }
/// ```
///
/// Throws [PerfGateException] on shape errors so the CLI can fail
/// with exit code 2. Every `profile` field above is required —
/// `tier_m_locations` / `tier_m_staff` evidence is mandatory so an
/// under-sampled or under-scaled run cannot silently clear the gate.
RecordedResults parseResultsJson(String content) {
  Object? decoded;
  try {
    decoded = jsonDecode(content);
  } on FormatException catch (e) {
    throw PerfGateException('results JSON is not valid JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw PerfGateException('results JSON root must be an object');
  }

  final profileField = decoded['profile'];
  if (profileField is! Map<String, dynamic>) {
    throw PerfGateException(
      'results JSON must have a "profile" object recording the '
      'Tier-M scale + iteration count + stage list + concurrency '
      'profile of the captured run',
    );
  }
  final operatorsRaw = profileField['operators'];
  if (operatorsRaw is! int) {
    throw PerfGateException(
      'profile.operators must be an integer (got $operatorsRaw)',
    );
  }
  final iterationsRaw = profileField['iterations'];
  if (iterationsRaw is! int) {
    throw PerfGateException(
      'profile.iterations must be an integer (got $iterationsRaw)',
    );
  }
  final stagesRaw = profileField['stages'];
  if (stagesRaw is! List) {
    throw PerfGateException('profile.stages must be a list of strings');
  }
  final stages = <String>[];
  for (var i = 0; i < stagesRaw.length; i++) {
    final v = stagesRaw[i];
    if (v is! String) {
      throw PerfGateException(
        'profile.stages[$i] must be a string (got $v)',
      );
    }
    stages.add(v);
  }
  final concurrencyRaw = profileField['concurrency'];
  if (concurrencyRaw is! String) {
    throw PerfGateException(
      'profile.concurrency must be the string "isolated" or "x10" '
      '(got $concurrencyRaw)',
    );
  }
  final concurrency = ConcurrencyProfile.parse(concurrencyRaw);

  final locationsRaw = profileField['tier_m_locations'];
  if (locationsRaw is! int) {
    throw PerfGateException(
      'profile.tier_m_locations is required and must be an integer '
      '(audit Tier-M lower bound is $kTierMLocationsMin); the gate '
      'will not clear without scale evidence',
    );
  }
  final tierMLocations = locationsRaw;
  final staffRaw = profileField['tier_m_staff'];
  if (staffRaw is! int) {
    throw PerfGateException(
      'profile.tier_m_staff is required and must be an integer '
      '(audit Tier-M lower bound is $kTierMStaffMin); the gate '
      'will not clear without scale evidence',
    );
  }
  final tierMStaff = staffRaw;

  final stagesField = decoded['stages'];
  if (stagesField is! Map<String, dynamic>) {
    throw PerfGateException(
      'results JSON must have an object field "stages"',
    );
  }
  final stageSamples = <String, List<double>>{};
  for (final entry in stagesField.entries) {
    final stage = entry.key;
    final value = entry.value;
    if (value is! Map<String, dynamic>) {
      throw PerfGateException(
        'stages.$stage must be an object with "latency_ms"',
      );
    }
    final list = value['latency_ms'];
    if (list is! List) {
      throw PerfGateException(
        'stages.$stage.latency_ms must be a list of numbers',
      );
    }
    final samples = <double>[];
    for (var i = 0; i < list.length; i++) {
      final v = list[i];
      if (v is num) {
        samples.add(v.toDouble());
      } else {
        throw PerfGateException(
          'stages.$stage.latency_ms[$i] must be a number, got $v',
        );
      }
    }
    stageSamples[stage] = samples;
  }

  return RecordedResults(
    operators: operatorsRaw,
    iterations: iterationsRaw,
    stages: stages,
    concurrency: concurrency,
    stageSamples: stageSamples,
    tierMLocations: tierMLocations,
    tierMStaff: tierMStaff,
  );
}

/// Validates the recorded profile against the runner's locked
/// Tier-M shape. Returns a list of human-readable mismatches; an
/// empty list means the profile cleared validation.
List<String> validateRecordedProfile(
  RecordedResults results,
  ConcurrencyProfile expectedConcurrency,
) {
  final issues = <String>[];
  if (results.operators != kTierMOperators) {
    issues.add(
      'profile.operators is ${results.operators}; Tier-M is per-operator '
      'holding-company scale (kTierMOperators=$kTierMOperators)',
    );
  }
  if (results.iterations < kTierMIterations) {
    issues.add(
      'profile.iterations is ${results.iterations}; Tier-M requires '
      '>= $kTierMIterations',
    );
  }
  final expectedStages = kTierMStages;
  if (results.stages.length != expectedStages.length ||
      !_listsEqual(results.stages, expectedStages)) {
    issues.add(
      'profile.stages is ${results.stages}; Tier-M expects $expectedStages '
      'in that order',
    );
  }
  if (results.concurrency != expectedConcurrency) {
    issues.add(
      'profile.concurrency is "${results.concurrency.jsonName}"; '
      '--concurrency=${expectedConcurrency.jsonName} expected',
    );
  }
  if (results.tierMLocations < kTierMLocationsMin) {
    issues.add(
      'profile.tier_m_locations is ${results.tierMLocations}; Tier-M '
      'lower bound is $kTierMLocationsMin',
    );
  }
  if (results.tierMStaff < kTierMStaffMin) {
    issues.add(
      'profile.tier_m_staff is ${results.tierMStaff}; Tier-M lower '
      'bound is $kTierMStaffMin',
    );
  }
  return issues;
}

bool _listsEqual(List<String> a, List<String> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

// ─── pgbench log ingestion ───────────────────────────────────────────

/// One pgbench log line, per the standard pgbench `--log` format:
///
/// ```
/// client_id transaction_no time script_no time_epoch time_us [schedule_lag]
/// ```
///
/// Only `time` (microseconds) and `script_no` are consumed. Lines
/// that fail to parse are skipped with a count surfaced to the
/// caller; the runner refuses to clear the gate from a log file that
/// produced zero parseable lines.
class PgbenchLogLine {
  const PgbenchLogLine({
    required this.scriptNo,
    required this.timeMicros,
  });

  final int scriptNo;
  final int timeMicros;

  double get latencyMs => timeMicros / 1000.0;
}

class PgbenchLogParseResult {
  const PgbenchLogParseResult({
    required this.lines,
    required this.skipped,
  });

  final List<PgbenchLogLine> lines;
  final int skipped;
}

PgbenchLogParseResult parsePgbenchLog(String content) {
  final out = <PgbenchLogLine>[];
  var skipped = 0;
  for (final raw in const LineSplitter().convert(content)) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) {
      continue;
    }
    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length < 5) {
      skipped++;
      continue;
    }
    final time = int.tryParse(parts[2]);
    final scriptNo = int.tryParse(parts[3]);
    if (time == null || scriptNo == null) {
      skipped++;
      continue;
    }
    out.add(PgbenchLogLine(scriptNo: scriptNo, timeMicros: time));
  }
  return PgbenchLogParseResult(lines: out, skipped: skipped);
}

/// Builds a `RecordedResults` envelope from a per-stage map of
/// pgbench log file contents. The runbook runs one pgbench
/// invocation per stage (single-script `--file=<stage>.sql`) so each
/// log file maps cleanly to a single stage; `script_no` is therefore
/// not used to demultiplex but is recorded for cross-checks.
///
/// `tierMLocations` and `tierMStaff` are required so the constructed
/// envelope carries the Tier-M scale evidence the verdict path
/// validates against the audit lower bound.
RecordedResults buildResultsFromPgbenchLogs({
  required Map<String, String> stageLogContents,
  required ConcurrencyProfile concurrency,
  required int tierMLocations,
  required int tierMStaff,
  int operators = kTierMOperators,
  int iterations = kTierMIterations,
}) {
  final stageSamples = <String, List<double>>{};
  for (final stage in kTierMStages) {
    final content = stageLogContents[stage];
    if (content == null) {
      throw PerfGateException(
        'pgbench log for stage "$stage" was not provided '
        '(expected --ingest-pgbench=$stage=<path>)',
      );
    }
    final parsed = parsePgbenchLog(content);
    if (parsed.lines.isEmpty) {
      throw PerfGateException(
        'pgbench log for stage "$stage" produced 0 parseable lines; '
        'refusing to ingest (skipped=${parsed.skipped})',
      );
    }
    stageSamples[stage] = parsed.lines.map((l) => l.latencyMs).toList();
  }
  return RecordedResults(
    operators: operators,
    iterations: iterations,
    stages: List<String>.of(kTierMStages),
    concurrency: concurrency,
    stageSamples: stageSamples,
    tierMLocations: tierMLocations,
    tierMStaff: tierMStaff,
  );
}

/// Renders a `RecordedResults` back to the canonical results JSON
/// shape so `--write-results-json` produces a file the verdict path
/// can re-ingest.
String encodeResultsJson(RecordedResults results) {
  final encoder = const JsonEncoder.withIndent('  ');
  final stagesObject = <String, Object?>{};
  for (final stage in results.stages) {
    final samples = results.stageSamples[stage] ?? const <double>[];
    stagesObject[stage] = <String, Object?>{
      'latency_ms': samples,
    };
  }
  return encoder.convert(<String, Object?>{
    'profile': <String, Object?>{
      'operators': results.operators,
      'iterations': results.iterations,
      'stages': results.stages,
      'concurrency': results.concurrency.jsonName,
      'tier_m_locations': results.tierMLocations,
      'tier_m_staff': results.tierMStaff,
    },
    'stages': stagesObject,
  });
}

// ─── CLI ─────────────────────────────────────────────────────────────

const String _usageBlock = '''
Usage: dart run tool/perf_gate/tier_m_runner.dart [flags]

Modes:
  (default)                  Plan only. Print Tier-M profile, locked
                             thresholds, preflight checklist. No I/O.
  --preflight                Name-only preflight (env-var presence,
                             file presence). Never reads env values
                             or file contents. Exit 4 if BLOCKED.
  --record-results=<path>    Read recorded per-iteration timings and
                             emit PASS / FAIL verdict per stage.
                             Requires a profile block matching the
                             Tier-M shape.
  --ingest-pgbench=<stage>=<path>
                             (Repeatable.) Parse a pgbench --log
                             file for the given stage. Provide one
                             entry per stage (bm25, vector, age,
                             synthesis). REQUIRES --tier-m-locations
                             and --tier-m-staff. Emits a verdict and
                             (with --write-results-json) a
                             re-ingestible JSON envelope.

Flags:
  --concurrency=<isolated|x10>   default isolated. AGE p95 red flips
                                 from 500 ms to 1000 ms on x10.
  --tier-m-locations=<N>         REQUIRED with --ingest-pgbench.
                                 Locations-per-operator the live run
                                 covered. Recorded into the JSON
                                 envelope and validated against the
                                 Tier-M lower bound.
  --tier-m-staff=<N>             REQUIRED with --ingest-pgbench.
                                 Staff-per-operator the live run
                                 covered. Same validation.
  --write-results-json=<path>    With --ingest-pgbench, write the
                                 constructed RecordedResults JSON
                                 to <path> for replay through
                                 --record-results.
  --json                         emit verdict / preflight result as
                                 JSON instead of human-readable text.
  --help / -h                    print this usage and exit.

Exit codes:
  0  success (plan printed, preflight cleared, verdict PASS).
  2  configuration error (malformed flags, bad results JSON,
     profile mismatch).
  3  runtime error (cannot read input file, cannot write output).
  4  PREFLIGHT BLOCKED.
  5  verdict FAIL or INCOMPLETE.

This tool NEVER connects to a database. NEVER prints secrets.
''';

class _Flags {
  _Flags({
    required this.help,
    required this.preflight,
    required this.recordResultsPath,
    required this.ingestPgbench,
    required this.writeResultsJsonPath,
    required this.concurrency,
    required this.tierMLocations,
    required this.tierMStaff,
    required this.jsonOutput,
  });

  final bool help;
  final bool preflight;
  final String? recordResultsPath;
  final Map<String, String> ingestPgbench;
  final String? writeResultsJsonPath;
  final ConcurrencyProfile concurrency;
  final int? tierMLocations;
  final int? tierMStaff;
  final bool jsonOutput;
}

_Flags _parseFlags(List<String> args) {
  var help = false;
  var preflight = false;
  String? recordResults;
  final ingestPgbench = <String, String>{};
  String? writeResultsJson;
  var concurrency = ConcurrencyProfile.isolated;
  int? tierMLocations;
  int? tierMStaff;
  var jsonOutput = false;

  for (final raw in args) {
    if (raw == '-h' || raw == '--help') {
      help = true;
    } else if (raw == '--preflight') {
      preflight = true;
    } else if (raw.startsWith('--record-results=')) {
      recordResults = raw.substring('--record-results='.length);
      if (recordResults.isEmpty) {
        throw PerfGateException(
          '--record-results= requires a non-empty path',
        );
      }
    } else if (raw.startsWith('--ingest-pgbench=')) {
      final body = raw.substring('--ingest-pgbench='.length);
      final eq = body.indexOf('=');
      if (eq <= 0 || eq == body.length - 1) {
        throw PerfGateException(
          '--ingest-pgbench requires <stage>=<path> (got "$body")',
        );
      }
      final stage = body.substring(0, eq);
      final path = body.substring(eq + 1);
      if (!kTierMStages.contains(stage)) {
        throw PerfGateException(
          '--ingest-pgbench stage "$stage" is not a Tier-M stage '
          '(expected one of ${kTierMStages.join(', ')})',
        );
      }
      ingestPgbench[stage] = path;
    } else if (raw.startsWith('--write-results-json=')) {
      writeResultsJson = raw.substring('--write-results-json='.length);
      if (writeResultsJson.isEmpty) {
        throw PerfGateException(
          '--write-results-json= requires a non-empty path',
        );
      }
    } else if (raw.startsWith('--concurrency=')) {
      concurrency = ConcurrencyProfile.parse(
        raw.substring('--concurrency='.length),
      );
    } else if (raw.startsWith('--tier-m-locations=')) {
      final value = int.tryParse(
        raw.substring('--tier-m-locations='.length),
      );
      if (value == null || value <= 0) {
        throw PerfGateException(
          '--tier-m-locations= requires a positive integer',
        );
      }
      tierMLocations = value;
    } else if (raw.startsWith('--tier-m-staff=')) {
      final value = int.tryParse(raw.substring('--tier-m-staff='.length));
      if (value == null || value <= 0) {
        throw PerfGateException(
          '--tier-m-staff= requires a positive integer',
        );
      }
      tierMStaff = value;
    } else if (raw == '--json') {
      jsonOutput = true;
    } else {
      throw PerfGateException('unknown flag "$raw"');
    }
  }
  return _Flags(
    help: help,
    preflight: preflight,
    recordResultsPath: recordResults,
    ingestPgbench: ingestPgbench,
    writeResultsJsonPath: writeResultsJson,
    concurrency: concurrency,
    tierMLocations: tierMLocations,
    tierMStaff: tierMStaff,
    jsonOutput: jsonOutput,
  );
}

Future<int> runCli(
  List<String> args, {
  void Function(String line)? writeOut,
  void Function(String line)? writeErr,
  Map<String, String>? environment,
  bool Function(String path)? fileExists,
  Future<String> Function(String path)? readFile,
}) async {
  final outLine = writeOut ?? _defaultOutLine;
  final errLine = writeErr ?? _defaultErrLine;
  final reader = readFile ?? ((p) => File(p).readAsString());

  _Flags flags;
  try {
    flags = _parseFlags(args);
  } on PerfGateException catch (e) {
    errLine('tier_m_runner: ${e.message}');
    errLine('');
    errLine(_usageBlock);
    return 2;
  }
  if (flags.help) {
    outLine(_usageBlock);
    return 0;
  }

  final encoder = const JsonEncoder.withIndent('  ');

  if (flags.preflight) {
    final result = runPreflight(
      PreflightInputs.defaults,
      environment: environment,
      fileExists: fileExists,
    );
    if (flags.jsonOutput) {
      outLine(
        encoder.convert(<String, Object?>{
          'mode': 'preflight',
          'cleared': result.cleared,
          'checks': result.checks
              .map(
                (c) => <String, Object?>{
                  'name': c.name,
                  'cleared': c.cleared,
                  'evidence': c.evidence,
                },
              )
              .toList(),
        }),
      );
    } else {
      outLine(formatPreflightReport(result).trimRight());
    }
    return result.cleared ? 0 : 4;
  }

  if (flags.recordResultsPath != null && flags.ingestPgbench.isNotEmpty) {
    errLine(
      'tier_m_runner: --record-results and --ingest-pgbench are '
      'mutually exclusive; use one or the other',
    );
    return 2;
  }

  if (flags.recordResultsPath != null) {
    final path = flags.recordResultsPath!;
    String content;
    try {
      content = await reader(path);
    } catch (e) {
      errLine('tier_m_runner: cannot read --record-results=$path: $e');
      return 3;
    }
    RecordedResults results;
    try {
      results = parseResultsJson(content);
    } on PerfGateException catch (e) {
      errLine('tier_m_runner: ${e.message}');
      return 2;
    }
    final issues = validateRecordedProfile(results, flags.concurrency);
    if (issues.isNotEmpty) {
      errLine('tier_m_runner: recorded profile does not match Tier-M:');
      for (final issue in issues) {
        errLine('  - $issue');
      }
      return 2;
    }
    final verdict = evaluateGate(
      profile: TierMProfile(
        operators: results.operators,
        iterations: results.iterations,
        stages: results.stages,
      ),
      concurrency: results.concurrency,
      stageSamples: results.stageSamples,
    );
    if (flags.jsonOutput) {
      outLine(encoder.convert(verdict.toJson()));
    } else {
      outLine(formatVerdictReport(verdict).trimRight());
    }
    switch (verdict.overall) {
      case StageStatus.pass:
        return 0;
      case StageStatus.fail:
      case StageStatus.incomplete:
        return 5;
    }
  }

  if (flags.ingestPgbench.isNotEmpty) {
    final missingStages = kTierMStages
        .where((s) => !flags.ingestPgbench.containsKey(s))
        .toList();
    if (missingStages.isNotEmpty) {
      errLine(
        'tier_m_runner: --ingest-pgbench is missing stage(s) '
        '${missingStages.join(', ')}; provide one --ingest-pgbench '
        'entry per Tier-M stage',
      );
      return 2;
    }
    if (flags.tierMLocations == null || flags.tierMStaff == null) {
      errLine(
        'tier_m_runner: --ingest-pgbench requires both '
        '--tier-m-locations=<N> and --tier-m-staff=<N> so the '
        'recorded envelope carries Tier-M scale evidence (audit '
        'lower bound: $kTierMLocationsMin locations / $kTierMStaffMin '
        'staff)',
      );
      return 2;
    }
    final stageContents = <String, String>{};
    for (final stage in kTierMStages) {
      final logPath = flags.ingestPgbench[stage]!;
      try {
        stageContents[stage] = await reader(logPath);
      } catch (e) {
        errLine(
          'tier_m_runner: cannot read --ingest-pgbench=$stage=$logPath: $e',
        );
        return 3;
      }
    }
    RecordedResults results;
    try {
      results = buildResultsFromPgbenchLogs(
        stageLogContents: stageContents,
        concurrency: flags.concurrency,
        tierMLocations: flags.tierMLocations!,
        tierMStaff: flags.tierMStaff!,
      );
    } on PerfGateException catch (e) {
      errLine('tier_m_runner: ${e.message}');
      return 2;
    }
    if (flags.writeResultsJsonPath != null) {
      try {
        final outFile = File(flags.writeResultsJsonPath!);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsStringSync(encodeResultsJson(results));
      } catch (e) {
        errLine(
          'tier_m_runner: cannot write '
          '--write-results-json=${flags.writeResultsJsonPath}: $e',
        );
        return 3;
      }
    }
    final issues = validateRecordedProfile(results, flags.concurrency);
    if (issues.isNotEmpty) {
      errLine('tier_m_runner: ingested profile does not match Tier-M:');
      for (final issue in issues) {
        errLine('  - $issue');
      }
      return 2;
    }
    final verdict = evaluateGate(
      profile: TierMProfile(
        operators: results.operators,
        iterations: results.iterations,
        stages: results.stages,
      ),
      concurrency: results.concurrency,
      stageSamples: results.stageSamples,
    );
    if (flags.jsonOutput) {
      outLine(encoder.convert(verdict.toJson()));
    } else {
      outLine(formatVerdictReport(verdict).trimRight());
    }
    switch (verdict.overall) {
      case StageStatus.pass:
        return 0;
      case StageStatus.fail:
      case StageStatus.incomplete:
        return 5;
    }
  }

  // Default: plan only.
  if (flags.jsonOutput) {
    outLine(
      encoder.convert(<String, Object?>{
        'mode': 'plan',
        'profile': const TierMProfile().toJson(),
        'concurrency': flags.concurrency.jsonName,
        'thresholds': lockedThresholds(flags.concurrency)
            .map((t) => t.toJson())
            .toList(),
      }),
    );
  } else {
    outLine(
      formatPlanReport(concurrency: flags.concurrency).trimRight(),
    );
  }
  return 0;
}

void _defaultOutLine(String line) => stdout.writeln(line);
void _defaultErrLine(String line) => stderr.writeln(line);

String _fmt(double v) {
  if (v == v.roundToDouble()) {
    return v.toStringAsFixed(1);
  }
  return v.toStringAsFixed(2);
}

class PerfGateException implements Exception {
  PerfGateException(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
