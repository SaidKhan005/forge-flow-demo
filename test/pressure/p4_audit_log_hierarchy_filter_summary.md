# p4_audit_log_hierarchy_filter — audit-log hierarchy filter latency bucket

**Runner:** `test/pressure/p4_audit_log_hierarchy_filter_test.dart`
(unit tests for `tool/pressure/p4_audit_log_hierarchy_filter.dart`)

**What it pressures:** the bucketing math + recorder accumulation
contract for the `audit_log_hierarchy_filter_p95_ms{operator_id,
location_count}` health gauge. Pins both the location-count bucket
boundary set and the recorder's percentile / rolling-window behavior so
a `/health` consumer reading the snapshot sees stable values across
releases.

**Status at f0bf2702:** PASS. Pure-function unit tests; deterministic.

## Inputs

- No env vars. Hermetic.
- Bucket boundaries pinned: `0`, `1`, `2`, `4`, `8`, `16`, `32`, `64`,
  `128`, `256`, `256+`. Inputs round UP to the next boundary; negative
  inputs map to `0` defensively.
- Recorder accepts an injectable clock seam + a configurable
  `retainSamplesPerBucket` rolling-window cap.

## What it asserts

- `auditLogHierarchyLocationCountBucket(n)` maps inputs to the next
  boundary: 0→"0", 1→"1", 3→"4", 8→"8", 9→"16", 257→"256+", -1→"0".
- `record()` + `snapshot()` produce exactly one row per
  `(operator_id, location_count_bucket)` pair.
- p95 uses inclusive linear interpolation: rank = `0.95 * (n - 1)`;
  11 samples [0..100] → p95 == 95.
- Rolling window drops the oldest sample when `retainSamplesPerBucket`
  is exceeded.
- `clear()` empties the recorder; `snapshot()` then omits zero-observation
  buckets.
- Snapshot order: by operator ascending, then bucket ascending, `256+`
  last.
- `retainSamplesPerBucket <= 0` throws `ArgumentError`.
- `toJson()` shape is stable: `operator_id`, `location_count_bucket`,
  `count`, `p50_ms`, `p95_ms`, `max_ms` (no other keys).

## How to read the output

- Healthy run: all 8 unit tests pass; no committed findings file (pure
  in-memory recorder pinning).
- Regression: any bucket boundary change, percentile interpolation
  switch (e.g. exclusive vs inclusive), or `toJson` key drift breaks
  the gauge contract for downstream consumers reading `/health`.

## Related

- Authority: `docs/_audits/code_health/code_hardening_plan_2026_05_21.md`
  §2.4, backlog item #10
- Production code: `tool/pressure/p4_audit_log_hierarchy_filter.dart`
- Companion harnesses: `p4_soak_orchestrator_test.dart`
  (consumes the same recorder shape in the soak report)
- Last touched: see `git log -- test/pressure/p4_audit_log_hierarchy_filter_test.dart`
