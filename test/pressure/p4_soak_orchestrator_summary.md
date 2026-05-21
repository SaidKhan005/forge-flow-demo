# p4_soak_orchestrator — multi-pod soak driver + report

**Runner:** `test/pressure/p4_soak_orchestrator_test.dart`
(unit tests for `tool/pressure/p4_soak_orchestrator.dart` —
Wave 2 Lane Q slice Q-1)

**What it pressures:** the soak orchestrator that drives sustained
request traffic against the preview/staging proxy, aggregates per-pod
latency percentiles, and writes a Markdown report the B-2B triage
runbook consumes. Catches regressions in CLI arg parsing, the URL
allow-list guard, the per-pod request-rate / latency math, the heap-
snapshot section's skip behavior, and multi-pod fan-out.

**Status at f0bf2702:** PASS. Tests use an in-process loopback
`HttpServer` and lift Flutter's test `HttpOverrides` for the duration
of the soak run.

## Inputs

- Env-driven options via `parseSoakOrchestratorArgs`:
  - `--proxy-url=` (default `http://localhost:8080`)
  - `--pod-ids=pod-a,pod-b,pod-c`
  - `K_REVISION` fallback when `--pod-ids` is absent
  - `--workload-mix=` (0.0–1.0 bounds-checked)
  - `--run-id=`, `--duration-seconds=`, `--concurrency=`, etc.
- The heap-snapshot section reads `AzureBlobHeapSnapshotUploadTarget`
  env (see `p4_heap_snapshot_uploader_summary.md`).

## What it asserts

- Defaults: `localhost:8080` proxy, single pod from `K_REVISION` (or
  `local-dev` on a dev box).
- `--pod-ids` parses as a comma-separated list.
- `--workload-mix` outside `[0.0, 1.0]` throws `FormatException`.
- End-to-end against loopback HTTP: drives requests, computes
  percentiles, writes a Markdown report containing
  `# p4_soak_orchestrator — <run-id>` plus sections "Request volume
  + outcome", "Latency percentiles (ms)", "Per-pod breakdown",
  "Heap snapshots".
- Heap-snapshot section reports "Heap-snapshot upload skipped" when
  the Azure target is unconfigured.
- Multi-pod: every pod gets a row in the breakdown; non-first pods
  emit `soak.heap_snapshot.deferred` log lines + carry the
  `remote_capture_pending` note (control-plane endpoint is TODO).
- URL guard: a non-preview / non-staging / non-localhost proxy URL
  exits with code 2 and NEVER touches the wire (zero request count).

## How to read the output

- Healthy run: all tests pass; report file exists with all four
  required sections.
- Regression: missing section header (report-consumer breakage),
  non-zero request count for a rejected URL (URL guard regression),
  or a deferred-capture line missing for pods beyond the first.
- Operator run: live report lands under the `--output-dir=` path the
  CLI was invoked with; in-tree no committed findings JSONL — runs
  emit Markdown reports per invocation.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10
- Production code: `tool/pressure/p4_soak_orchestrator.dart`,
  `tool/pressure/p4_heap_snapshot_uploader.dart`,
  `tool/pressure/p4_audit_log_hierarchy_filter.dart`,
  `tool/pressure/p4_fd_watcher.dart`,
  `tool/pressure/p4_session_record_predicate.dart`
- Companion: B-2B triage runbook (cited in the test header)
- Last touched: see `git log -- test/pressure/p4_soak_orchestrator_test.dart`
