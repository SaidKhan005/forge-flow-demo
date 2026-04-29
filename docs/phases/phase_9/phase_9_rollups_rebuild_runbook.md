# Phase 9 Rollups Rebuild Runbook

Operational runbook for the bounded-rebuild path locked in
`docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
Q3.8 ("Rollup Rebuild Strategy") and Q3.9 ("Rollup Error Handling").

This runbook is the single source of truth for any operator who
needs to rebuild rollup data after a vendor correction, a rule-version
change, or a worker incident. Every rebuild MUST run through one of
the procedures below — ad-hoc `UPDATE rollup_<grain> SET …` writes
are forbidden because they bypass the deterministic UPSERT key, the
freshness/status flag, and the lease.

## Authority

This runbook is governed by:

- `docs/phases/phase_9/phase_9_scalability_decisions_2026-04-27.md`
  Q3.5 (late-arriving data), Q3.6 (idempotency), Q3.7 (freshness UI),
  Q3.8 (rebuild strategy), Q3.9 (error handling), Q3.10 (observability).
- `db/migrations/202604280010_a_phase_9_0sigma_k_aggregation_state.sql`
  for the `aggregation_state` table shape and rebuild bookkeeping
  columns.
- `db/migrations/202604280010_b_phase_9_0sigma_k_rollup_tables.sql`
  for the seven physical rollup tables and the deterministic UPSERT
  key shape.
- `db/migrations/202604280010_c_phase_9_0sigma_k_pg_cron_jobs.sql`
  for the lease primitive (`public.rollup_acquire_lease`) and the
  hot/cold cron schedules. The cron functions (`rollup_run_hot_path`
  / `rollup_run_cold_path`) emit `pg_notify('rollups_tick', …)`
  ONLY — they never take a lease themselves. The Dart worker is
  the sole caller of `rollup_acquire_lease`.
- `lib/services/rollups/rollup_worker.dart` for the in-process worker
  primitives (`claimBatch`, `flushBatch`, `recordFailure`, `markStale`).

## Bounded rebuild scope

Per Q3.8, every rebuild is bounded by these axes. Pick one value per
axis (or "all"); do not run an unbounded rebuild.

| Axis              | Source                                                                |
| ----------------- | --------------------------------------------------------------------- |
| operator          | `operators.operator_id`                                               |
| org unit          | `org_units.id` (any node — corp / region / district / location_group) |
| location          | `locations.location_id` (NULL → all locations under the org unit)     |
| metric family     | `rollup_<grain>.metric_family` (sales, labor, variance, …)            |
| date range        | half-open `[from_business_date, to_business_date)`                    |
| grain             | one of the seven Q3.3 grains                                          |
| rule_version      | `v1`, `v2`, … the rule version the rebuild is targeting               |

The rebuild scope is recorded on `aggregation_state.rebuild_scope` as
a free-form audit string. Recommended format:

```
operator=<op_id>/org_unit=<ou_id>/location=<loc_id|all>/metric=<family>/dates=<from>..<to>/grain=<grain>/rule=<version>
```

## Standard procedure

The four-phase sequence (Q3.8 lock):

### 1. Stage

- Set `aggregation_state.rebuild_in_progress = true`,
  `rebuild_started_at = now()`, `rebuild_target_rule_version =
  '<new>'`, `rebuild_scope = '<scope string>'`,
  `last_run_status = 'rebuilding'` for the affected `(rollup_table,
  grain)` rows.
- Mark every existing rollup row inside the rebuild scope
  `freshness_status = 'rebuilding'` so the dashboard renders the
  "Rebuilding…" label (Q3.7) instead of "Updated N minutes ago".
- The worker stops advancing the watermark for `(rollup_table,
  grain)` rows whose `rebuild_in_progress = true` so a normal
  incremental advance does not race the rebuild writer.

### 2. Rebuild

- The rebuild writer aggregates the scope's raw facts into a
  staging set keyed by the new `rule_version`.
- Each staging row uses the same deterministic UPSERT key as the
  production rollup row (operator + scope + period + metric_family +
  dimensions_fingerprint + grain-specific cols), so a re-run inside
  the rebuild produces the same rows (Q3.6 idempotency).
- The rebuild writer batches at `defaultBatchSize` (1000 rows per
  flush) by default. The runbook authorizes lowering this for a
  "tighter-cancel" rebuild — pass `--batch-size 100` to the
  `rollups rebuild` admin CLI when the rebuild needs to be
  interruptible at finer granularity.
- The rebuild writer runs through `forge_admin` BYPASSRLS (same
  posture as the Dart rollup worker) so it can write across operators
  inside an admin-driven multi-operator rebuild without a
  per-operator tenant transaction.

### 3. Validate

- Compare row counts and metric totals between the staging set and
  the prior rollup rows for the same scope. The validator MUST
  fail-closed if:
  - the staging total drops by more than the configured tolerance
    (default 5% per metric_family) without a documented vendor
    correction, OR
  - the staging row count drops by more than 10% without a documented
    vendor correction, OR
  - any staging row violates the table's CHECK constraints (e.g.
    `dimensions_fingerprint` NULL, `freshness_status` outside the
    enum).
- The validator records its findings on a Dev/Admin Health row tied
  to the rebuild_scope string. If validation fails, the rebuild
  pauses and the runbook operator decides whether to (a) accept the
  drop with an explanatory note, (b) re-stage with a corrected
  source, or (c) abort the rebuild and roll back to the prior rule
  version.

### 4. Promote

- Within a single transaction:
  1. UPSERT the staging rows into the production rollup table using
     the deterministic UPSERT key. Existing rows for the same key are
     replaced; their `freshness_status` flips back to `'fresh'`,
     `last_failure_at` / `last_failure_reason` clear,
     `rule_version` updates to the new value.
  2. Delete or archive any prior rows inside the rebuild scope that
     do NOT have a matching staging row (the rebuild concluded those
     rows are no longer accurate).
  3. Update `aggregation_state` for the affected `(rollup_table,
     grain)`: `rebuild_in_progress = false`, `last_run_status =
     'succeeded'`, `attempt_count = 0`, `last_error_at = null`,
     `last_error = null`, `lease_owner = null`, `leased_until =
     null`, `updated_at = now()`. Leave `last_processed_seq`
     unchanged — the rebuild was retroactive against historical
     facts, not a forward watermark advance.
- Resumption: the next scheduled hot/cold cron tick wakes the Dart
  worker via `pg_notify('rollups_tick', …)`. The worker observes
  `rebuild_in_progress = false` (the lease primitive's rebuild guard
  no longer rejects the take) and resumes incremental advances from
  the existing watermark.

## Failure handling (Q3.9 last-known-good)

If the rebuild writer throws while inside steps 1-3, the runbook
operator MUST:

1. Set `aggregation_state.last_run_status = 'failed'`, increment
   `attempt_count`, set `last_error_at = now()` and `last_error =
   '<short reason>'`.
2. Leave `rebuild_in_progress = true` until either the rebuild is
   retried successfully or the operator explicitly cancels it.
3. Roll back any uncommitted staging writes. Production rollup rows
   keep their prior values — Q3.9 "last known good" — and the
   dashboard surfaces the failure via the freshness label.

If the failure is during step 4 (promote), the transaction rolls back
and production rollup rows are unchanged; `aggregation_state` rolls
back too. The operator can re-run promotion after fixing the
underlying issue.

## Freshness behaviour during a rebuild (Q3.7)

- `aggregation_state.last_run_status = 'rebuilding'` →
  Dev/Admin Health renders the affected rollup tables with the
  "Rebuilding…" label.
- Existing rollup rows with `freshness_status = 'rebuilding'` →
  operator-facing dashboard renders the "Rebuilding…" label per row.
- Rows promoted in step 4 flip back to `'fresh'` immediately;
  `computed_at` reflects the promotion timestamp.
- If a rebuild is cancelled, the operator MUST clear the per-row
  `freshness_status = 'rebuilding'` markers so the dashboard returns
  to the prior "Updated N minutes ago" label and reports the prior
  data as the operator-facing truth.

## Stale sweep coordination (Q3.7)

The independent staleness sweep (`RollupWorker.markStale`) is
allowed to run during a rebuild because the SQL guard
(`last_run_status not in ('leased', 'rebuilding')`) prevents the
sweep from flipping a `rebuilding` row to `stale`. Operators do NOT
need to disable the freshness sweep before starting a rebuild.

## Observability (Q3.10)

Every rebuild surfaces these signals in Dev/Admin Health:

- Active rebuilds: `select rollup_table, grain, rebuild_started_at,
  rebuild_scope, rebuild_target_rule_version from aggregation_state
  where rebuild_in_progress;`
- Failed rebuilds (last 24h): rows with `last_run_status = 'failed'`
  whose `rebuild_in_progress` flipped from `true` → `false` recently.
- Rebuild duration: `now() - rebuild_started_at` while in progress;
  difference between `rebuild_started_at` and `last_run_completed_at`
  after promotion.
- Affected reports: the Dev/Admin Health UX joins the rebuild_scope
  axes against the dashboard surface map to render "rebuilding
  affects: Sales / Labor / Variance" in the right-rail context panel.

## Reading the `rollup_freshness_per_grain` health metric (B42 / B45)

The B42 `/health` envelope reserves a `rollup_freshness_per_grain`
key. The payload is produced by `RollupFreshnessReporter.snapshot()`
in `lib/services/rollups/rollup_worker.dart` — one read against
`aggregation_state`, one entry per locked Q3.3 grain. The route
envelope is owned by B42; B45 owns the producer wiring, data shape, UI
integration, and severity bucketing described here.

### Envelope shape

```json
{
  "rollup_freshness_per_grain": {
    "severity": "degraded",
    "observed_at": "2026-04-29T10:30:00.000Z",
    "grains": {
      "daypart":           { "severity": "ok",        "status": "succeeded",  "last_run_completed_at": "...", "age_seconds": 30,   ... },
      "business_day":      { "severity": "degraded",  "status": "stale",      "last_run_completed_at": "...", "age_seconds": 7200, ... },
      "week":              { "severity": "ok",        "status": "succeeded",  "last_run_completed_at": "...", "age_seconds": 60,   ... },
      "accounting_period": { "severity": "unhealthy", "status": "failed",     "last_run_completed_at": "...", "last_error_reason": "...", ... },
      "month":             { "severity": "degraded",  "status": "rebuilding", "rebuild_in_progress": true, ... },
      "quarter":           { "severity": "ok",        "status": "leased",     "lease_owner": "host:42", ... },
      "year":              { "severity": "unhealthy", "status": "missing",    "last_run_completed_at": null, ... }
    }
  }
}
```

Top-level `severity` is the worst across all grains (unhealthy >
degraded > ok). The 11A operations console renders this as the
collapsed-row headline color; the operator can expand to see the
per-grain detail.

#### `last_run_completed_at` — NOT a "last success" timestamp

The JSON field is deliberately named `last_run_completed_at`
(matching the SQL column) and NOT `last_success_at`, because
`RollupWorker.recordFailure` also stamps `last_run_completed_at =
now()` when a batch fails. On a `failed` row the timestamp is the
failure-completion time, not the last-good-data time. Consumers
must branch on `status` to tell the two apart:

- `status = 'succeeded'` → `last_run_completed_at` is the time the
  worker last advanced the watermark.
- `status = 'failed'` → `last_run_completed_at` is the time the
  failure landed; the operator-facing "last known good" data lives
  on the `rollup_<grain>` rows themselves (Q3.9 — those rows keep
  their prior `computed_at` + `freshness_status = 'last_known_good'`).
- `status = 'idle'` or synthetic `'missing'` → `last_run_completed_at`
  is `null`.

### Severity meaning per status

| `status` (from `aggregation_state.last_run_status`) | Severity decision |
| --------------------------------------------------- | ----------------- |
| `succeeded`                                         | `ok` if `age_seconds < warningAge`; `degraded` if `< criticalAge`; `unhealthy` if past critical. The age is `now() - last_run_completed_at` and only this status path uses age — every other status takes precedence over the age check. |
| `leased`                                            | `ok` while `leased_until > now()` (worker is actively processing). `degraded` once the lease expires — the next `rollup_acquire_lease` call recovers it but the operator still sees that a worker died mid-flight. |
| `idle`                                              | `degraded`. Bootstrap row that has never run a batch. Should clear on the next cron tick; investigate if it persists past one full hot-path period (60 s). |
| `stale`                                             | `degraded`. `RollupWorker.markStale` already flipped this row because no batch advanced the watermark within the staleness window. |
| `rebuilding` (or `rebuild_in_progress = true`)      | `degraded`. Q3.8 rebuild is in-flight; production data is the prior-rule-version "last known good" until step 4 (Promote) lands. |
| `failed`                                            | `unhealthy`. Most recent batch threw; `last_error_reason` carries a short string. The watermark has NOT advanced (Q3.6) — re-run picks up the same window. `last_run_completed_at` here is the failure-completion time, NOT the last-good-data time (see "`last_run_completed_at` — NOT a 'last success' timestamp" above). |
| `missing` (synthetic — no `aggregation_state` row)  | `unhealthy`. The grain has never bootstrapped. The first call to `rollup_acquire_lease` for that `(rollup_table, grain)` seeds the row; if a grain stays missing the worker is not running for that path. |

### Threshold defaults (and how to tune)

`RollupFreshnessThresholds` defaults are pinned to the Q3.1 locked
cron cadence and the B38 load-test tripwires so the dashboard
flips to `degraded`/`unhealthy` BEFORE the alarm fires:

| Path | Grain set                                                  | Q3.1 cadence | B45 warning | B45 critical | B38 alarm |
| ---- | ---------------------------------------------------------- | ------------ | ----------- | ------------ | --------- |
| Hot  | `daypart`, `business_day`                                  | 60 s         | 90 s        | 120 s        | > 120 s   |
| Cold | `week`, `accounting_period`, `month`, `quarter`, `year`    | 300 s (5 m)  | 600 s (10 m)| 900 s (15 m) | > 900 s   |

`warning` lands at ~1.5×–2× the cron cadence — the next-tick miss
is a real signal, but the band is narrow enough that the operator
sees `degraded` before B38 trips. `critical` matches the B38
tripwire exactly so the dashboard color and the alarm fire on the
same threshold.

These defaults intentionally do NOT mask a missed cron window — a
hot rollup that has not advanced for >2 cron cycles paints
`degraded` immediately and `unhealthy` the moment B38 would alarm.

Tune by passing a non-default `RollupFreshnessThresholds` to the
reporter constructor — call `validate()` in the wiring code or in
a test so a misconfiguration (warning >= critical) fails closed at
startup instead of silently producing meaningless severities.

### Reconciling freshness with the staleness sweep (Q3.7)

The reporter and `RollupWorker.markStale` are independent:

- `markStale` flips `last_run_status = 'stale'` once the
  `aggregation_state.updated_at` is older than `staleAfter`. Its
  guard (`last_run_status not in ('leased', 'rebuilding')`) means
  active or rebuilding rows are NEVER marked stale by the sweep.
- `RollupFreshnessReporter` reads the same row but additionally
  computes `now() - last_run_completed_at` against the configured
  thresholds. It can flag a `succeeded` row as `degraded`/`unhealthy`
  even before the sweep flips the status — useful when the sweep
  itself is not running (e.g., during a cron outage).

Both signals are observable from the same `aggregation_state` row;
the operations console renders whichever paints the loudest color.

### Lease ownership and recovery (worker leasing safety)

The B42 envelope carries `lease_owner` and `leased_until` per grain
so an operator can identify which worker holds a lease that has
gone past its `leased_until`. The recovery path is automatic — the
SQL `rollup_acquire_lease` primitive reclaims any lease whose
`leased_until` is null or in the past — but a persistent
`leased_until` in the past with no progress over multiple ticks
indicates either:

1. the cron job is not firing (check `cron.job` rows / Azure
   `Postgres-Maintenance` cron database), or
2. every worker is failing the same window (check `last_error` on
   the row).

`RollupLeaseLostException` is the worker-side counterpart: any
flush or failure write that loses its lease (because another worker
took over OR a rebuild started) throws and rolls back the entire
transaction. No partial UPSERTs land under a lease the worker no
longer owns.

## Out of scope for this runbook

- The rebuild writer CLI itself is a follow-up slice. Until it ships,
  rebuilds run through ad-hoc psql under the existing `forge_admin`
  BYPASSRLS connection, with the operator manually following the
  four-phase sequence above.
- Cross-operator backfills (legal-hold corrections, F&F internal
  corrections affecting multiple operators) inherit this runbook but
  also require the F&F internal cross-operator audit trail described
  in `phase_9_scalability_decisions_2026-04-27.md` Q1. The cross-
  operator audit attribution path is queued separately.
