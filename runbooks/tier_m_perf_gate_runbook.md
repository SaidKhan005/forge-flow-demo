# Tier-M Perf Gate Runbook (cutover.0b)

Version: 0.1 (2026-05-01)
Status: SCAFFOLDED — NO LIVE MEASUREMENTS YET.
Owner: F&F launch lane operator + Cloud Run perf-gate driver.

This runbook is the operational procedure for the `cutover.0b`
read-only Tier-M performance gate against Production1. The gate
clears `cutover.0b` only after an authorized operator captures real
Production1 measurements that meet the locked thresholds in
[Locked thresholds](#locked-thresholds). The harness exists; this
document plus
[`tool/perf_gate/tier_m_runner.dart`](../tool/perf_gate/tier_m_runner.dart)
are the only checked-in pieces today. Production1 remains
intentionally empty and the Tier-M advisor seed is not yet on disk,
so the live run is BLOCKED on preflight today (see
[Today's preflight result](#todays-preflight-result-2026-05-01)).

## Authority

This runbook is governed by:

- `docs/phases/phase_production_cutover/phase_production_cutover_plan.md`
  (cutover.0b section) — read-only Tier-M perf gate that pairs with
  the rollups perf gate at row 8 of the perf-gate matrix.
- `docs/phases/phase_11a/phase_11a_decision_register.md`
  - Lock 3 (AGE benchmark gate): isolated p95 ≤ 500 ms; 10× concurrent
    p95 ≤ 1000 ms.
  - Lock 7 (LLM circuit breaker open trigger): p99 latency > 3×
    baseline trips the breaker. The synthesis stage red threshold is
    anchored to that ratio.
- `tool/vector_index_health/vector_index_health.dart`
  (`VectorIndexHealthBudgets.exampleStartingBudgets`) — checked-in
  HNSW filtered-retrieval budgets mirrored here for the vector and
  BM25 stages.
- `docs/phases/phase_9/phase_9_scalability_performance_audit_2026-04-27.md`
  (Prelaunch Performance Test Matrix) — rows 11 (Vector) and 12
  (Graph) plus the synthesis path.

## Scope and non-goals

In scope:

- Read-only EXPLAIN ANALYZE / SELECT traffic against Production1 to
  measure p50 / p95 / p99 latency for the four advisor query stages
  (BM25, vector, AGE, synthesis).
- One Tier-M holding-company operator (per
  `phase_9_scalability_performance_audit_2026-04-27.md` line 88-99:
  250-500 locations, 5,000-25,000 staff, multi-brand hierarchy,
  heavy ingest, high advisor / reporting volume). Distinct from the
  500-OPERATOR rollups Tier-M (B38), which gates cutover.0b row 8
  on a different code path.
- 1000 iterations per stage per concurrency profile (isolated and
  10× concurrent), captured to a JSON results envelope produced by
  `tier_m_runner.dart --ingest-pgbench=...` and replayed through
  `--record-results=<path>` for the verdict.

Not in scope:

- Any mutation against Production1. The benchmark scripts end with
  `ROLLBACK` and reference no `INSERT` / `UPDATE` / `DELETE`.
- Live AI-provider calls billed against the production Anthropic /
  Voyage keys for synthesis. Synthesis is exercised through the
  staging proxy with the Production1 corpus mirrored into staging
  for read-only candidate retrieval, OR through the Production1
  proxy with a staged "no-op" Anthropic key that returns canned
  responses. The runbook does not authorize either fallback in this
  draft — the launch decision lands during the live preflight.
- The rollups perf gate. That is
  `docs/archive/phases/phase_9/phase_9_rollups_tierm_load_result.md`
  (B38, cutover.0b row 8). Row 8 is gated separately and clears with
  its own evidence.

## Tier-M profile

| Axis                       | Value                                |
| -------------------------- | ------------------------------------ |
| Operators                  | 1 (one Tier-M holding-company shape) |
| Locations per operator     | 250-500 (lower bound enforced)       |
| Staff per operator         | 5,000-25,000 (lower bound enforced)  |
| Iterations / stage         | 1000 (floor — under-sample = INCOMPLETE) |
| Stages                     | bm25, vector, age, synthesis         |
| Concurrency profiles       | isolated (single client) + 10×       |
| Posture                    | read-only (no production mutations)  |

This is the **per-operator** Tier-M scale from the scalability
audit. Multi-tenant breadth (the 500-operator number) is covered
separately by the rollups Tier-M (B38). The 14-row reading of the
prelaunch performance matrix refers to the matrix's row count, not
to operator count.

## Locked thresholds

The verdict trips on **strict `>`** so the contract wording (`<= N
ms`, `> 3x baseline`) is honored at the boundary: an exact 500.0 ms
p95 PASSES; 500.01 ms FAILS. Same for the Lock 7 ratio: exactly 3.0
PASSES; 3.01 FAILS.

| Stage     | p50 red | p95 red                       | p99 red | Other                                 | Source                                      |
| --------- | ------- | ----------------------------- | ------- | ------------------------------------- | ------------------------------------------- |
| bm25      | 80 ms   | 250 ms                        | 500 ms  | provisional (mirrors vector budgets)  | `vector_index_health.dart` example budgets  |
| vector    | 80 ms   | 250 ms                        | 500 ms  | —                                     | `vector_index_health.dart` example budgets  |
| age       | —       | **≤ 500 ms** isolated, **≤ 1000 ms** at 10× concurrency | — | —                       | Decision register Lock 3                    |
| synthesis | —       | —                             | —       | p99 / p50 ratio ≤ 3.0 (Lock 7 anchor) | Decision register Lock 7                    |

BM25 thresholds are flagged `provisional` in the verdict so a future
tuning slice can re-anchor them to a corpus-specific floor without
papering over the gap. Synthesis percentiles are recorded but the
gate trips on the p99/p50 ratio, not on absolute floors, until the
launch baseline lands.

## Live preflight checklist

Every step is the responsibility of the authorized operator. The
runbook and the runner DO NOT execute any of these steps. Run
`dart run tool/perf_gate/tier_m_runner.dart --preflight` to capture
the name-only result; the runner never reads env-var values or file
contents.

- [ ] Env var `FORGE_FLOW_PRODUCTION1_DATABASE_URL` is set in the
      operator's shell. The runner reports presence-only; the value
      stays in the operator's environment and never leaves it.
- [ ] `build/perf_gate/tier_m_advisor_seed.manifest.json` exists.
      This manifest is generated by the corpus-load pipeline
      (`tool/advisor_corpus/main.dart prepare-load` plus the
      Production1 mirror flow) and records the Tier-M operator id
      plus the location/staff counts the harness exercises (250-500
      locations / 5,000-25,000 staff). The manifest itself contains
      no plaintext queries.
- [ ] `build/perf_gate/tier_m_advisor_harness.sql` exists. This is
      a multi-script artifact: per-stage scripts
      `tier_m_advisor_harness.bm25.sql`,
      `tier_m_advisor_harness.vector.sql`,
      `tier_m_advisor_harness.age.sql`, and
      `tier_m_advisor_harness.synthesis.sql`. Each mirrors the AGE
      benchmark template
      (`build/advisor_corpus/age/009_age_benchmark_harness.sql`)
      shape and is wrapped in a leading
      `RAISE NOTICE 'DRY RUN ONLY ...'` plus `ROLLBACK` posture.
- [ ] Production1 firewall / Private Link route lets the operator's
      session reach the DB. Confirmed via a one-off `SELECT 1`
      outside the gated window so the gated window starts clean.
- [ ] `pg_stat_statements` is reset before the measurement window so
      the captured numbers reflect the gate run only.

## Run channel

1. **Plan-only confirmation.**

   ```bash
   dart run tool/perf_gate/tier_m_runner.dart
   ```

   Prints the Tier-M profile, locked thresholds, preflight checklist,
   and authority. Exits 0. No I/O.

2. **Name-only preflight.**

   ```bash
   dart run tool/perf_gate/tier_m_runner.dart --preflight
   ```

   Reports `[OK]` or `[BLOCK]` per check. Exit 0 = preflight cleared.
   Exit 4 = `PREFLIGHT BLOCKED` — STOP. Do not proceed to step 3
   until every check is `[OK]`.

3. **Authorized live run (operator-driven).** Inside the approved
   read-only Production1 window. Run pgbench once per stage, with
   `--log` enabled so per-transaction latencies land on disk in the
   pgbench log file (one log line per transaction with the schema
   `client_id transaction_no time_us script_no time_epoch ...`).
   `--transactions=1000` pins the per-stage iteration count to the
   Tier-M floor; `--time=` is not used because the runner enforces
   sample count, not wall-clock duration.

   ```bash
   set -e
   cd build/perf_gate
   STAGES=(bm25 vector age synthesis)
   CLIENTS=1   # 10 for the x10 profile

   for stage in "${STAGES[@]}"; do
     pgbench \
       --no-vacuum \
       --client="${CLIENTS}" \
       --transactions=1000 \
       --log --log-prefix="pgbench_${stage}" \
       --file="tier_m_advisor_harness.${stage}.sql" \
       "$FORGE_FLOW_PRODUCTION1_DATABASE_URL"
   done
   ```

   pgbench writes per-transaction logs as `pgbench_<stage>.<pid>` (one
   per client). Concatenate the per-client logs into a single
   per-stage log so the runner ingests one file per stage:

   ```bash
   for stage in "${STAGES[@]}"; do
     cat pgbench_${stage}.* > "${stage}.log"
   done
   ```

   The synthesis stage script must NOT call any production AI
   provider. The launch-time decision (staging proxy + Production1
   corpus mirror, OR Production1 proxy + canned-response Anthropic
   stub) is recorded in the corpus-load result doc; the harness file
   simply emits the SELECT path.

4. **Build the runner input from the pgbench logs.**

   ```bash
   dart run tool/perf_gate/tier_m_runner.dart \
     --ingest-pgbench=bm25=build/perf_gate/bm25.log \
     --ingest-pgbench=vector=build/perf_gate/vector.log \
     --ingest-pgbench=age=build/perf_gate/age.log \
     --ingest-pgbench=synthesis=build/perf_gate/synthesis.log \
     --tier-m-locations=<actual> \
     --tier-m-staff=<actual> \
     --concurrency=isolated \
     --write-results-json=build/perf_gate/tier_m_results_isolated.json
   ```

   `--tier-m-locations` and `--tier-m-staff` are required: the
   runner refuses to construct the envelope without them, and the
   audit lower bound is `--tier-m-locations >= 250` and
   `--tier-m-staff >= 5000`. The runner records the values into the
   JSON envelope and re-validates them on every `--record-results`
   replay so a run that did not actually exercise the Tier-M scale
   cannot silently clear the gate.

   The same command with `--concurrency=x10` and the x10 logs
   produces `tier_m_results_x10.json`. The runner converts the
   pgbench log into the canonical RecordedResults envelope
   (`profile` block + per-stage `latency_ms` arrays) and runs the
   verdict in one step. Replay the saved JSON via
   `--record-results=<path>` if a re-evaluation is needed without
   re-running pgbench.

5. **Verdict (replay path).**

   ```bash
   dart run tool/perf_gate/tier_m_runner.dart \
     --record-results=build/perf_gate/tier_m_results_isolated.json

   dart run tool/perf_gate/tier_m_runner.dart \
     --record-results=build/perf_gate/tier_m_results_x10.json \
     --concurrency=x10
   ```

   The runner computes p50 / p95 / p99 per stage and prints PASS /
   FAIL with named-stage breakdown. Exit 0 = PASS. Exit 2 = profile
   mismatch (e.g. recorded JSON is for x10 but flag says isolated,
   or `tier_m_locations` below the audit lower bound). Exit 5 = FAIL
   or INCOMPLETE (under-sampled stage).

## Recorded measurements

Fill one row per `(stage, concurrency)` after the live run. Numbers
below are placeholders; do not treat any populated value here as
evidence of a live run until this notice is removed.

### Isolated profile (single client)

| Stage     | Iterations | p50 (ms) | p95 (ms) | p99 (ms) | Threshold (red) | Verdict |
| --------- | ---------- | -------- | -------- | -------- | --------------- | ------- |
| bm25      | TBD (≥ 1000) | TBD    | TBD      | TBD      | 80 / 250 / 500  | TBD     |
| vector    | TBD (≥ 1000) | TBD    | TBD      | TBD      | 80 / 250 / 500  | TBD     |
| age       | TBD (≥ 1000) | —      | TBD      | —        | p95 ≤ 500       | TBD     |
| synthesis | TBD (≥ 1000) | TBD    | —        | TBD      | p99/p50 ≤ 3.0   | TBD     |

### 10× concurrent profile

| Stage     | Iterations | p50 (ms) | p95 (ms) | p99 (ms) | Threshold (red) | Verdict |
| --------- | ---------- | -------- | -------- | -------- | --------------- | ------- |
| bm25      | TBD (≥ 1000) | TBD    | TBD      | TBD      | 80 / 250 / 500  | TBD     |
| vector    | TBD (≥ 1000) | TBD    | TBD      | TBD      | 80 / 250 / 500  | TBD     |
| age       | TBD (≥ 1000) | —      | TBD      | —        | p95 ≤ 1000      | TBD     |
| synthesis | TBD (≥ 1000) | TBD    | —        | TBD      | p99/p50 ≤ 3.0   | TBD     |

Capture sources:

- p50 / p95 / p99: per-transaction timings written by pgbench
  `--log` and ingested by
  `tier_m_runner.dart --ingest-pgbench=<stage>=<path>` (which writes
  the canonical RecordedResults JSON). The runner enforces the
  `≥ 1000` per-stage sample floor; under-sampled stages report
  INCOMPLETE rather than PASS.
- AGE p95 cross-check: `pg_stat_statements` filtered to the AGE
  Cypher `MATCH` queries the harness emits. Recorded for parity with
  the staging AGE benchmark (`docs/archive/phases/phase_11a/phase_11a_11e_staging_live_load_result.md`).
- Synthesis p50 / p99: Cloud Run proxy logs filtered to the canned-
  synthesis call class. The harness records start / stop timestamps
  per iteration; the proxy adds upstream latency in `usage_logs`.

## Threshold comparison

Filled by the runner. Do not edit by hand. After each `--record-results`
invocation, paste the runner output verbatim into one of the
following blocks. Any FAIL or INCOMPLETE line names the contingency
lane in [Contingency lanes](#contingency-lanes-decision-needed-for-this-slice).

### Isolated profile verdict

```
TBD — paste `tier_m_runner.dart --record-results=...` output here
after the authorized live run.
```

### 10× concurrent profile verdict

```
TBD — paste `tier_m_runner.dart --record-results=...
--concurrency=x10` output here after the authorized live run.
```

## Verdict

Filled at the end of the gated window:

- [ ] Preflight: cleared (every check `[OK]`).
- [ ] Live run: completed against Production1 read-only.
- [ ] Isolated verdict: PASS / FAIL.
- [ ] 10× concurrent verdict: PASS / FAIL.
- [ ] Overall: PASS → cutover.0b launch gate cleared. FAIL →
      contingency lane named below; cutover.0b stays gated.

Until cleared, cutover.0b does not open and `cutover.1` (production
corpus load) does not start.

## Contingency lanes (`Decision needed for this slice`)

If the verdict is FAIL on a stage, the contingency lane is locked
ahead of time so the gate failure converts directly into a follow-up
slice rather than ad-hoc triage:

- **bm25 FAIL** → tuning slice that revisits the `bm25_tsv` GIN
  index strategy and the `chunk_context` field weighting in
  `db/migrations/202604250006_advisor_contextual_retrieval_telemetry.sql`.
  Re-run cutover.0b after the tuning slice closes. BM25 thresholds
  are provisional, so a FAIL here may also trigger a threshold
  re-anchor in the same slice.
- **vector FAIL** → Q20 / HNSW→DiskANN cutover playbook
  (`docs/phases/phase_9/phase_9_vector_index_switch_trigger.md`),
  starting with the non-destructive shadow → benchmark → canary
  flow. Per Lock 1, evaluate DiskANN at provisioning before flipping
  the active strategy. Re-run cutover.0b after the playbook lands.
- **age FAIL (isolated p95 > 500 ms or 10× p95 > 1000 ms)** → Azure
  tier upgrade first (per the decision register Lock 3 wording: "If
  this fails, first try an Azure tier upgrade before flipping the
  resilience flag to vector-only"). Only if the upgrade does not
  recover the gate, flip the `graph_retrieval_mode = 'vector_only'`
  feature flag in `feature_flags` and document the launch decision
  in the decision register. Re-run cutover.0b after the change.
- **synthesis FAIL (p99 / p50 ≥ 3×)** → tighten the Lock 7 circuit
  breaker thresholds (open trigger and fallback chain) and re-run
  the synthesis-only profile. If the failure is upstream Anthropic
  latency, escalate to Anthropic support; do not paper over with a
  larger tolerance.

The contingency lanes are launch-gating. They are not parallel to
cutover.0b; they replace the failed gate run.

## Today's preflight result (2026-05-01)

This runbook ships scaffolded. The harness, the manifest, and the
live Production1 corpus do not exist yet:

- `FORGE_FLOW_PRODUCTION1_DATABASE_URL` — not set in the worktree
  shell. The Production1 connection lives in the operator's
  authorized environment, not in CI.
- `build/perf_gate/tier_m_advisor_seed.manifest.json` — missing.
  Production1 is intentionally empty (cutover.0 plan: "no corpus, no
  operator data, no live traffic"); the seed manifest is generated
  by the cutover.1 corpus-load pipeline and must record actual
  Tier-M location/staff counts (≥ 250 / ≥ 5,000) before the gate
  can clear.
- `build/perf_gate/tier_m_advisor_harness.sql` — missing. The four
  per-stage harness scripts (`...bm25.sql`, `...vector.sql`,
  `...age.sql`, `...synthesis.sql`) are downstream artifacts of the
  corpus-load pipeline plus the AGE benchmark generator
  (`tool/advisor_corpus/main.dart`, `009_age_benchmark_harness.sql`).

Verdict: **PREFLIGHT BLOCKED**.

This is consistent with the cutover.0b plan: cutover.0b cannot run
before cutover.1 lands the production corpus. The runbook plus
runner are the scaffolding that the cutover.0b operator picks up
once the seed is staged. No live measurements were captured by this
slice. The launch gate remains gated.

Reverification path:

1. After cutover.1 closes (production corpus loaded; smoke tests
   green; `phase_production_cutover_1_corpus_load_result.md`
   recorded), regenerate the harness and manifest in
   `build/perf_gate/`.
2. Re-run `dart run tool/perf_gate/tier_m_runner.dart --preflight`.
   When every check reports `[OK]`, proceed to the authorized live
   run.
3. Record measurements per
   [Recorded measurements](#recorded-measurements) and paste the
   runner verdict per [Threshold comparison](#threshold-comparison).
4. Update [Verdict](#verdict) and re-evaluate cutover.0b.

## Tool reference

Scaffolded runner:

- Source: [`tool/perf_gate/tier_m_runner.dart`](../tool/perf_gate/tier_m_runner.dart).
- Default mode: plan-only. Prints profile, thresholds, preflight
  checklist, and authority. No I/O.
- `--preflight`: name-only env-var + file presence check. Never
  reads env-var values or file contents.
- `--ingest-pgbench=<stage>=<path>` (repeatable, one entry per
  Tier-M stage): parse pgbench `--log` files, build the canonical
  RecordedResults envelope, run the verdict.
- `--write-results-json=<path>`: with `--ingest-pgbench`, also write
  the constructed JSON envelope so the verdict can be replayed.
- `--tier-m-locations=<N>` / `--tier-m-staff=<N>`: REQUIRED with
  `--ingest-pgbench`. Record the live scale into the JSON envelope.
  The runner refuses to construct an envelope without them and
  enforces the audit lower bounds (≥ 250 locations, ≥ 5,000 staff)
  on `--record-results`.
- `--record-results=<path>`: replays a saved JSON envelope through
  the verdict path. The envelope MUST carry every `profile` field
  (`operators`, `iterations`, `stages`, `concurrency`,
  `tier_m_locations`, `tier_m_staff`) — missing scale evidence is
  rejected with exit 2; under-sampled stages report INCOMPLETE
  rather than PASS.
- `--concurrency=<isolated|x10>`: AGE p95 red flips from 500 ms to
  1000 ms on x10. Comparisons use strict `>` so exact-boundary values
  PASS (e.g. AGE p95 = 500.0 ms isolated).
- `--json`: emit verdict / preflight result as JSON.
- Exit codes: 0 success, 2 config error / profile mismatch, 3 runtime
  error, 4 PREFLIGHT BLOCKED, 5 FAIL or INCOMPLETE.

The runner never imports `package:postgres`, never echoes secrets,
never mutates Production1.
