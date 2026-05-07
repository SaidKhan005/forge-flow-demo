# V1 Closure Dispatch Plan

Date: 2026-05-06
Baseline: master `f347cab1` (post-PR #195 + post-`11W.7` audit)
Status: dispatch record — durable list of the seven lanes Claude is
running on top of (a) Codex's `8.star-target-server-truth` sprint and
(b) the user's parallel sink-fanout work (Oracle Simphony / OpenTable /
7shifts capability extension).

## Goal

Close out V1 launch readiness so the ecosystem is fully connected and
live (cloud → proxy → mobile → consoles), and the trio
(Lightspeed K-Series · Libro · QuickBooks Time) can flip to
`*.live.sandbox` the moment vendor credentials arrive. Everything
beyond sandbox is partnership-blocked, not engineering-blocked.

## Authority

1. `docs/_execution/2026-05-05_v1_launch_punchlist.md`
2. `PROJECT_TRACKER.md`
3. `docs/_execution/2026-05-06_mobile_core_logic_data_wiring_contract.md` (Doc 1)
4. `docs/contracts/mobile_core_first_connection_backfill_contract.md` (CLOSED)
5. `docs/contracts/mobile_core_star_target_truth_contract.md` (Codex)
6. `docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`
7. `docs/POST_HARDENING_FOLLOWUPS.md`

## Forbidden file space (enforced per lane prompt)

User's three sink lanes (running elsewhere):

- `lib/integrations/pos/oracle_micros_simphony_pos_adapter.dart`
- `lib/integrations/reservation/opentable_reservation_adapter.dart`
- `lib/integrations/labor/seven_shifts_labor_adapter.dart`
- `lib/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart`
- `lib/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart` (NEW in user's work)
- `lib/infrastructure/persistence/postgres/seven_shifts_labor_postgres_sink.dart` (might be NEW)

Codex's `8.star-target-server-truth` sprint:

- `lib/infrastructure/persistence/postgres/repositories/selected_star_shift_repository.dart` (NEW)
- `lib/infrastructure/persistence/postgres/repositories/target_cycle_repository.dart` (NEW)
- `lib/infrastructure/persistence/postgres/repositories/active_target_profile_repository.dart` (NEW)
- `tool/advisor_proxy/advisor_proxy.dart`
- `tool/advisor_proxy/proxy_bootstrap.dart` (LIMITED — V1.D may add a single GET route after coordination)
- `lib/services/target_cycle_service.dart`
- `lib/domain/services/target_cycle_active_target_profile_projector.dart`
- `lib/services/sync/http_sync_proxy_client.dart` (LIMITED — V1.A reads closed-row JSON; coordinate)
- `lib/services/sync/mobile_operational_sync_runtime.dart` (LIMITED — V1.D adds cancellation seam after Codex Lane 3 lands)
- `lib/screens/baseline_manager_screen.dart`
- `lib/services/baseline_manager_service.dart`
- `lib/services/app_data_status_service.dart`
- NEW migration `db/migrations/<timestamp>_phase_8_star_target_truth.sql`

## Seven-lane plan

| Lane | Slice id | V1-blocking | Dispatch | Branch |
|---|---|---|---|---|
| V1.A | `8.closed-row-proxy-timing-provenance` | YES | NOW | `claude/8-closed-row-proxy-timing-provenance` |
| V1.B | `8.timing-provenance-fk-posture` | YES | NOW | `claude/8-timing-provenance-fk-posture` |
| V1.C | `8.weekly-plan-server-truth.lane0` | NO | after Codex `star-target.Lane 0` merges | `claude/8-weekly-plan-server-truth-lane0` |
| V1.D | `8.mobile-scope-foundation` | NO (yes for `cutover.5`) | after Codex `star-target.Lane 3` merges | `claude/8-mobile-scope-foundation` |
| V1.E | `8.live.vendor-now-available-fanout` | YES (gates trio prod) | NOW | `claude/8-live-vendor-now-available-fanout` |
| V1.F | `8.connector-backfill-jobs.test-coverage` | NO (chip) | NOW | `claude/8-connector-backfill-jobs-test-coverage` |
| V1.G | `cutover.0.preflight-runbook-codification` | NO (operator-unblock helper) | NOW | `claude/cutover-0-preflight-runbook-codification` |

### V1.A — Closed-row proxy timing provenance

**Goal.** Mirror the open-snapshot timing triplet onto the closed-row
SELECT/mapper so mobile actually consumes the timing provenance Lane 0
stored. Lane 2's `ClosedTimingLabelResolver` is wired but inert on
mobile until this lands — closed rows arrive on mobile with null
triplet and the resolver falls back to mutable `daypart`.

**Files.**

- `tool/advisor_proxy/proxy_bootstrap.dart` (`_shiftRecordJson` mapper +
  `fetchShiftRecords` SELECT — narrow edits at lines `1278-1320` and
  `1575-1613` per `docs/POST_HARDENING_FOLLOWUPS.md` P1).
- `lib/services/sync/http_sync_proxy_client.dart` (closed-row JSON
  parser ingestion — additive field reads).
- `lib/infrastructure/persistence/sqlite/dao/shift_record_dao.dart`
  (verify columns; if missing, additive SQLite migration).
- Targeted proxy + sync tests.

**Coordination with Codex's Lane 3 (`mobile_operational_sync_runtime.dart`).**
V1.A only edits `http_sync_proxy_client.dart` (Codex also touches it).
The change is additive (new field reads); merge conflict risk is
low. If Codex's Lane 3 lands first the rebase is mechanical.

**Acceptance.**

- Closed `shift_records` proxy payload includes
  `business_timing_profile_id`, `business_timing_profile_version_id`,
  `service_period_key`.
- Mobile sync round-trip preserves the triplet.
- `ClosedTimingLabelResolver` resolves stable timing version on
  mobile (Variance/History/Learn show original-version labels).
- `dart analyze` clean. Targeted proxy + sync test suite green.
- Drift scanner + cutoff + RLS + index-leading + Postgres-import lints
  clean.

### V1.B — Timing provenance FK posture migration

**Goal.** Decide and implement FK posture on
`shift_records_business_timing_profile_fk` /
`shift_records_business_timing_profile_version_fk` and
`open_shift_snapshots_profile_version_fk` so closed historical truth
survives profile mutation per the
`core_app_architecture.md` "What never rewrites" rule. Recommended:
`ON DELETE SET NULL` (closed row degrades to null timing instead of
blocking the profile delete).

**Files.**

- `db/migrations/<timestamp>_phase_8_timing_provenance_fk_posture.sql`
  (NEW; `ALTER TABLE … DROP CONSTRAINT … ; ADD CONSTRAINT … ON DELETE
  SET NULL NOT VALID`).
- `docs/POST_HARDENING_FOLLOWUPS.md` (mark FK posture follow-up as
  CLOSED; cross-reference).
- `runbooks/phase_9_production1_migration_apply_runbook.md` (add to
  pending queue).
- Focused migration test in `test/db/migrations/`.

**Out-of-scope.** Dropping the version-equals-profile CHECKs (those wait
for Phase 8R divergence per the existing follow-up note).

**Acceptance.**

- Migration drift scanner + cutoff lint pass.
- Migration test asserts the post-migration FK action.
- All 5 hardening lints clean.

### V1.C — Weekly plan server truth Lane 0

**Goal.** Doc 1 Phase 7 — additive Postgres schema + server
repositories for `weekly_plan_snapshots` + `forecast_context`.
Read-only stub for now; mobile pull route returns honest
unavailable when row missing. Strictly the data spine; does NOT touch
existing `WeeklyPlanSnapshotService` (local SQLite owner).

**Files.**

- `db/migrations/<timestamp>_phase_8_weekly_plan_snapshots.sql` (NEW).
- `lib/infrastructure/persistence/postgres/repositories/weekly_plan_snapshot_repository.dart` (NEW).
- `lib/infrastructure/persistence/postgres/repositories/forecast_context_repository.dart` (NEW).
- Repo + migration tests.

**Sequencing.** Wait for Codex `8.star-target-server-truth.Lane 0` to
merge so the migration timestamp is stable and the FK to
`target_cycles` / `active_target_profiles` references the canonical
table. Acceptable to land additive-no-FK first if speed matters and
add FK in a follow-up.

**Acceptance.**

- Migrations drift+cutoff clean.
- Tables operator-scoped + RLS-enabled; hot-path indexes lead with
  `operator_id`.
- Repository tests green.
- `dart analyze` clean.

### V1.D — Mobile scope foundation

**Goal.** Doc 1 Phase 1 — server route for accessible business scopes +
mobile model + local active-scope repository. UI-shell scope drawer
ships in a follow-up; this lane delivers the data spine only.

**Files.**

- `tool/advisor_proxy/proxy_bootstrap.dart` (single new `GET
  /v1/operators/:operatorId/business_scopes` route — additive).
- `lib/services/scope/business_scope_repository.dart` (NEW).
- `lib/infrastructure/persistence/sqlite/repositories/sqlite_active_scope_repository.dart` (NEW).
- `lib/services/sync/mobile_operational_sync_runtime.dart` (additive
  cancellation API only — `cancelInFlightSync()` method).

**Sequencing.** Wait for Codex's `Lane 3` to merge before launching to
avoid `mobile_operational_sync_runtime.dart` merge conflict.

**Acceptance.**

- Proxy route returns scopes restricted by RBAC.
- SQLite repo round-trips.
- Sync runtime exposes `cancelInFlightSync` covered by test.
- No UI shipped (drawer is a follow-up).

### V1.E — Vendor-now-available email fan-out

**Goal.** Add `vendor_now_available` email template + dispatcher
fan-out worker. Required prerequisite for any `*.live.prod` slice
acceptance per `phase_8_live_rollout_plan.md`. Operator-blocked on
SendGrid domain auth before the email actually sends, but the code
lane is independent.

**Files.**

- `tool/advisor_proxy/email_templates/vendor_now_available.md` (NEW).
- `tool/advisor_proxy/email_dispatch/vendor_lifecycle_notification_dispatcher.dart` (NEW).
- Proxy route or `pg_cron` job to trigger dispatch on lifecycle
  promotion.
- Targeted tests.

**Acceptance.**

- Enqueueing N rows in `vendor_lifecycle_notification` for one
  `vendor_id` produces N `email_outbox` rows on lifecycle flip.
- Idempotent retry (no duplicate emails).
- Targeted test passes.
- All 5 lints clean.

### V1.F — Connector backfill jobs test coverage

**Goal.** Close P2 test coverage gap on the new
`connector_backfill_jobs` table + repository (added at
`…1800_…`). Pure additive test slice.

**Files.**

- `test/infrastructure/persistence/postgres/connector_backfill_jobs_repository_test.dart` (NEW; if not already present from PR #195 closeout).
- Additional integration tests under `test/services/integration/` for
  enqueue / claim / resume-from-cursor / idempotency on replay / RLS
  isolation.

**Acceptance.**

- ≥10 new tests, all green.
- One row of "18 of 29 repositories without dedicated tests" closed.

### V1.G — Cutover.0 preflight runbook codification

**Goal.** Codify `cutover.0` pre-flight as an executable harness so the
operator can run it the moment Production1 setup completes, without
Codex/Claude in the loop.

**Files.**

- `tool/cutover/preflight_smoke.dart` (NEW).
- `tool/cutover/README.md` (NEW).
- `runbooks/cutover_0_preflight_runbook.md` (NEW or augment existing).

**Acceptance.**

- Harness runs against staging green.
- Documents the production go/no-go output format named in
  `cutover.0` plan.
- Pure read-only; no mutations.

## Doc 1 remaining items (post-V1, future sprints)

Update 2026-05-07: `8.weekly-plan-server-truth` and the location-level
`8.business-scope-selector` mobile foundation have both merged after this
dispatch packet was authored. The table below is retained as dispatch history;
the live status is now called out in the Notes column.

Items 4–15 from the user's Doc 1 list that are NOT in this seven-lane
plan and require their own future sprints:

| Item | Sprint plan needed | Notes |
|---|---|---|
| 4. Server weekly plan snapshots + forecast context | `8.weekly-plan-server-truth` | Merged 2026-05-07 via PR #226; proof: `docs/_execution/2026-05-07_weekly_plan_server_truth_mobile_proof.md`. |
| 5. Mobile business scope selector + rollup truth | `8.business-scope-selector` | Location-level mobile foundation merged 2026-05-07 via PR #236; group/region/company rollup truth remains future until server rollup snapshots exist. |
| 6. Admin/web setting sync inventory | `audit.admin-web-setting-sync` | Audit-only at first; remediation lanes follow |
| 7. Connected-device E2E | `8.connected-device-e2e-smoke` | Needs physical device; operator-blocked |
| 8. Live provider proof | `8.<vendor>.live.sandbox` per vendor | Operator-blocked on creds |
| 9. Push proof | `8.push-notification-connected-device-proof` | Mobile push migration is code-ready; needs staging apply |
| 10. Larger pressure suite | `cutover.0b.tier-m-perf-gate` | Already on cutover sequence |

These do not block V1 sandbox-ready end state. They are V1.5/post-launch
hardening. The two contracts that need authoring before launch:

- `docs/contracts/mobile_core_weekly_plan_server_truth_contract.md`
- `docs/contracts/mobile_core_business_scope_contract.md`

Both are authored in this same dispatch pass so V1.C / V1.D have
authority docs to point at, and so the future-sprint lanes (Lanes 1–5
of each) have a stable starting point.

## Doc/tracker updates landing alongside this plan

1. **`PROJECT_TRACKER.md`** — Active Lanes block + Phase Board
2. **`docs/_execution/2026-05-05_v1_launch_punchlist.md`** — V1.A/B/E
   added as launch-blocking; V1.C/D/F/G as in-scope
3. **`docs/POST_HARDENING_FOLLOWUPS.md`** — P1 timing-provenance
   carry-forward marked `[~] in flight` for V1.A and V1.B; FK posture
   reference closed by V1.B
4. **`docs/phases/phase_8_live_rollout/phase_8_live_rollout_plan.md`**
   — V1.E noted as prerequisite for any `*.live.prod` slice
5. **`docs/contracts/mobile_core_weekly_plan_server_truth_contract.md`** (NEW)
6. **`docs/contracts/mobile_core_business_scope_contract.md`** (NEW)

## What this plan does NOT cover

- Anything operator-blocked (provisioning, lawyer T&Cs, DNS, SendGrid,
  sandbox creds, Voyage/Anthropic billing).
- Cutover sequence past `cutover.0` preflight harness.
- AI/Outward/Barrio paused phases.
- `.7S.upgrade` / Oracle Simphony / OpenTable sink work — user is
  running these in another worktree.
