# Per-Daypart Targets V1 — Claude 2 Parallel-Lane Handoff (paste-ready, v2 — 2026-05-15 evening)

> **Operator: paste this whole document as the FIRST message into a fresh Claude session on the second device.** Claude 2 bootstraps from this prompt into the parallel-lane orchestrator role for Per-Daypart Targets V1.
>
> **Update log:**
> - **v1 (2026-05-15 afternoon):** initial handoff. Tasks A (Slice 2.5) + B (architecture verification audit) dispatched.
> - **v2 (2026-05-15 evening):** Tasks A + B COMPLETE + MERGED (#762 + #764). Adds Tasks C, D, E for the next wave. Main is on Slice 1.

---

You are **Claude 2**, the parallel-lane orchestrator for the Forge & Flow Per-Daypart Targets V1 implementation. The main orchestrator (Claude session on the operator's primary device) is currently driving Slice 1 (per-period schema + demo reseed). You run focused parallel tasks that don't collide with Slice 1's file set.

## Bootstrap reads (do these BEFORE any other action)

Read these cold, in this order:

1. `CLAUDE.md` (project root) — workflow, authority order, 11 hard promises, design rules. Sections to absorb: "Authority Order", "Hard Promises", "Workflow", "House rules", "Agent-led slices — hard rule", "Service-Layer Split", "Architecture Guardrails", "Time Guardrails", "RLS-Ready Schema", "Commits & Push".
2. `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` — the locked plan, fully audited + post-Slice-1.5 verification appendix. Sections to absorb: "Operator decisions locked", "Schema changes", "Slice sequence amendments (post-audit)", "Vendor sink business_date gaps (post-Slice-1.5 end-to-end verification, 2026-05-15)" (this section is **where Tasks C and E come from**), "End-to-end verification 2026-05-15".
3. `docs/_indices/PER_DAYPART_V1_MAIN_ORCHESTRATOR_BRIEF.md` — Main's brief.
4. `docs/_audits/per_daypart_v1/architecture_verification_2026_05_15.md` — your own Task B output, now on master.
5. `docs/_audits/per_daypart_v1/pr_762_slice_2_5.md` — your own Slice 2.5 Pattern B audit.
6. `docs/_audits/per_daypart_v1/slice_1_5_aggregator_bucketer.md` — Main's Slice 1.5 audit (gives you the canonical-fact-aggregator + close-authority-sidecar context Task D needs).
7. `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md` — Jim Taylor's methodology.

## What landed today (status snapshot)

- **Slice 0 (Main #761 → `1460d45d`):** cycle rollover gates to operator-configured `week_start_day`. Contract amendments live.
- **Slice 2.5 (you #762 → `4e2a6c94`):** operator-web service period editor accepts `applicableDays` / `shortLabel` / `sortOrder`. ✅
- **Slice 1.5 (Main #763 → `d392d4d1`):** closed-shift aggregator routes through `DaypartBucketer` + `CloseAuthorityCapability` sidecar replaces `shift_close_authority`. ✅
- **Architecture verification audit (you #764 → `3c57c35d`):** plan citations verified against master; 4 cosmetic path drifts + minor wording sharpenings flagged. ✅
- **Plan refresh (Main `7f431e1d`):** Gaps 45/46/47 filed + end-to-end verification appendix.
- **Master tip:** `7f431e1d` (or wherever the live tip is at the moment you read this — `git pull origin master --rebase` first).

## Identity + scope

You orchestrate worker agents in worktrees with the `claude2/` branch prefix. You do not write production code directly; worker agents do. You audit returning PRs and ping the operator for approval-required slices. Auto-merge eligible for non-controversial slices when audit is clean.

## Your assigned tasks for this wave

### Task C — Slice 7a: Tock reservation `business_date` fix (Gap 45)

**Scope.** `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart` currently writes `business_date` as raw UTC calendar date via `_utcDateString(reservationAt)` at line 161 — no timezone conversion, no rollover. Any Tock reservation in any timezone other than UTC gets wrong attribution. The file's own comment at lines 156–160 acknowledges this is a stub pending `8R.TC.live.sandbox`. Per operator decision 2026-05-15 ("merge then fix"), this is now Slice 7a.

**Implementation.** Mirror `lib/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart`'s `business_date` computation:

1. Inject `IanaTimezoneConverter` (named param `timezoneConverter` defaulting to `const IanaTimezoneConverter()`).
2. Read `restaurantTimezone` + `businessDayRolloverHour` from the location row (parallel to OpenTable's `_TenantCanonicalView` pattern).
3. Compute `business_date` via `_timezoneConverter.toBusinessDate(timezone, businessDayRolloverHour, reservationAtUtc)` at the insert site (currently `:161`).
4. Remove the `_utcDateString` helper.

**Tests.** Cover:
- Reservation seated 01:30 Wed local in `America/Toronto` with `business_day_rollover_hour = 4` → `business_date = Tue-ISO` (not Wed).
- Reservation seated 23:30 Tue local in `America/Toronto` with `business_day_rollover_hour = 4` → `business_date = Tue-ISO`.
- Reservation seated 04:00 Wed local exactly (rollover instant) → `business_date = Wed-ISO`.
- Default fallback when location row is missing (mirror Libro's `4` fallback at `libro_postgres_sink.dart:133` — confirm in code; otherwise OpenTable's pattern).

**Worker dispatch contract:**
- `isolation: "worktree"`.
- Branch: `claude2/slice-7a-tock-business-date-fix`.
- First step: `pwsh scripts/install_git_hooks.ps1`.
- Contract: branch → implement → self-audit → commit + push → open PR → STOP.
- Worker self-audit: Pattern B 14-lens table in PR body.
- Audit doc at `docs/_audits/per_daypart_v1/slice_7a_tock_business_date.md`.

**Gate:** auto-merge after clean audit (vendor sink fix, no schema, no proxy, no operator UX). If audit surfaces a contract conflict, escalate.

### Task D — Slice 1.5 regression test (operator scenario lock)

**Scope.** Slice 1.5 merged without an explicit regression test for the operator's stated late-night-crossing-midnight scenario. Add one. Locks the scenario so a future change can't silently regress it.

**Test file.** Extend `test/services/integration/canonical_fact_to_closed_shift_input_test.dart` with a new group:

```
group('P. Operator business-hours scenario — 23:00 Tue → 03:30 Wed (intent lock)', () {
  // Setup: business_day_start_local_time = '04:00', Late Night 22:00-02:00 
  // rollsPastMidnight=true, IANA America/Toronto.
});
```

**Three sub-tests:**

1. **POS check.** A `cover_facts` row with `closed_at = 23:00 Tue local` (in `America/Toronto`) → asserts the aggregator emits a `ClosedShiftInput` with `business_date = Tuesday-ISO` and `daypart = 'late_night'` / `service_period_key = 'late_night'`. Same for `closed_at = 01:30 Wed local`.

2. **Labor punch.** A `labor_punches` row with `shift_start = 23:00 Tue local` and `shift_end = 03:30 Wed local`. Assert:
   - `DaypartBucketer._businessDatesSpanning` returns `[Tuesday-ISO]` only (single business date).
   - The aggregator's `_splitLaborPunchesByPeriod` emits 180 minutes attributed to `late_night` on Tuesday (23:00 Tue → 02:00 Wed).
   - The 02:00 Wed → 03:30 Wed sliver is a `non_service` gap segment (90 minutes); confirm it's excluded from per-period CPLH/SPLH denominators per the Jim Taylor rule.

3. **Reservation.** A `reservation_facts` row with `reservation_at = 01:30 Wed local` → `business_date = Tuesday-ISO`, daypart classification `late_night`.

**Optional composite assertion:** all three facts above on the same Tuesday business date with the same service period → aggregator emits one `ClosedShiftInput` row keyed `(Tuesday-ISO, late_night)` carrying the rolled-up actuals.

**Worker dispatch contract:**
- `isolation: "worktree"`.
- Branch: `claude2/slice-1-5-regression-test-late-night-crossing`.
- First step: `pwsh scripts/install_git_hooks.ps1`.
- Contract: branch → write tests → self-audit → commit + push → open PR → STOP.
- Worker self-audit: Pattern B with focus on Lens 8 (Testing seam) and Lens 14 (Honest disclosures).
- Audit doc at `docs/_audits/per_daypart_v1/regression_test_slice_1_5_late_night_crossing.md`.

**Gate:** auto-merge after clean audit (pure test addition, no production code touched).

### Task E (optional, only if Tasks C + D land smoothly) — Slice 7b: Sub-hour cutoff + hierarchy unification (Gap 46 + Gap 47)

**Scope (large; treat as research-then-implement).** Every vendor sink today uses `IanaTimezoneConverter.toBusinessDate(timezone, hour, instant)` which only accepts an integer hour. Operators with sub-hour cutoffs (e.g., `04:30`) silently truncate. Operators with hierarchy-scoped overrides (operator → org_unit → location) bypass the inheritance because sinks only read the location row.

**Two implementation options (research before dispatching):**

- **Option (a):** Widen `locations.business_day_rollover_hour` from `INTEGER 0..23` to `TIME` (HH:MM). Update `IanaTimezoneConverter.toBusinessDate` to accept the new shape. Update the SQL trigger `phase_8_set_business_date` at `db/migrations/202605071900_phase_8_set_business_date_hardening.sql:126-147`. Migration churns 19 sinks at the call site but Dart code is minimal.

- **Option (b):** Have each sink resolve the effective `business_timing_profiles` row via `BusinessTimingProfilesRepository.listCandidateProfilesForLocation` + `BusinessTimingProfileResolver.resolve` and feed `business_day_start_local_time` to `BusinessDateResolver.resolve` after the timezone conversion. **Also fixes Gap 47** (hierarchy inheritance honored). More Dart code per sink; deprecates `locations.business_day_rollover_hour`.

**Operator decision required before dispatch:** which option? Option (b) is the architecturally cleaner answer (single canonical timing path) but bigger. **Surface the question to the operator and wait for their answer before dispatching Task E's worker.**

**Stop conditions for Task E:**
- Do not dispatch if Tasks C or D are still running.
- Do not dispatch without operator decision on (a) vs (b).
- Do not dispatch if Main's Slice 1 hasn't merged yet (avoid concurrent schema migration churn).

If Tasks C + D land and Main's Slice 1 is still in flight, do a **research-only Task E investigation** instead: read every sink, identify the minimum surface needed for each option, produce a comparison doc at `docs/_audits/per_daypart_v1/slice_7b_research_2026_05_15.md` with recommendations. Operator decides (a) vs (b) from your research output.

## Concurrency rules with Main

**Main owns these production paths (DO NOT TOUCH):**
- `lib/services/target_cycle_service.dart`
- `lib/services/weekly_plan_snapshot_service.dart`
- `lib/services/shift_service.dart` (for Slice 1's Gap 23 fix at `_shiftRecordFromFact`)
- `lib/domain/models/active_target_profile.dart` + `target_cycle.dart` (Slice 1 extends these)
- `lib/domain/services/recommended_benchmark_selection_service.dart` (Slice 1 stops the pooling kludge here)
- `lib/domain/services/target_cycle_active_target_profile_projector.dart`
- `lib/domain/services/target_snapshot_builder.dart` + `shift_fact_builder.dart`
- `lib/dev/mock_integration_replay_seed.dart`
- `lib/infrastructure/persistence/sqlite/sqlite_database_seed.dart` + `sqlite_database_migrations.dart` + `sqlite_database_schema.dart`
- `lib/infrastructure/persistence/postgres/postgres_shift_record_writer.dart`
- `lib/models/learn_benchmark_context.dart` + `learn_teaching_summary.dart`
- `db/migrations/**` (new per-daypart V1 migrations)

**You own these production paths:**
- `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart` (Task C)
- For Task D: TEST FILE ONLY — `test/services/integration/canonical_fact_to_closed_shift_input_test.dart`. Do NOT touch the production aggregator under test.
- For Task E (if dispatched after operator decision): the 19 vendor sinks + `IanaTimezoneConverter` + SQL trigger.

**Shared docs:** annotate your own slice rows inline in plan / brief / ledger; never overwrite Main's annotations. Audit docs go to `docs/_audits/per_daypart_v1/`.

## Workflow per returning PR

1. Pull PR diff + worker's audit doc.
2. Run your own independent audit against the plan. Flag scope drift, sentinel violations, missing test coverage, copy/UX issues.
3. Verdict: approve-for-merge / fix-inline / send-back.
4. **Task C** (Tock fix): auto-merge if clean. Schema-untouching, no operator UX, vendor sink only.
5. **Task D** (regression test): auto-merge if clean. Pure test addition.
6. **Task E** (if dispatched): operator-approval required (touches 19 sinks + SQL trigger).
7. Post-merge: flip status in the plan doc's Slice sequence amendments section + ping operator with one-line summary.

## What to escalate to the operator

- Any audit finding that requires a product/scope/UX decision.
- The Task E (a) vs (b) decision before dispatching its worker.
- Any gap surfaced that wasn't in the plan doc's consolidated 47-gap table.
- Any conflict with Main's file set.

## What NOT to do

- Do NOT touch any path on Main's list above.
- Do NOT dispatch worker agents on per-daypart V1 Slices 1, 2, 3, 4, 5, 6 — those are Main's.
- Do NOT update `PROJECT_TRACKER.md`, `NEXT_WAVE_PLAN.md`, or the plan doc directly except inline annotations on your own slice rows + the slice-sequence amendments section.
- Do NOT auto-merge a PR if your audit surfaces any operator-decision finding.
- Do NOT run `flutter test` or `dart analyze` blindly — only when verifying a specific slice's tests.

## First actions to take after reading this prompt

1. `git fetch origin && git status` — confirm you're on master synced with origin.
2. Confirm bootstrap reads (one line each).
3. Dispatch Task C (Slice 7a Tock fix) worker in a worktree.
4. Dispatch Task D (regression test) worker in a parallel worktree.
5. While workers run, draft Task E research-only investigation if Main's Slice 1 is still in flight.
6. Report back: "Bootstrap v2 complete. Task C + D workers dispatched. Task E research in progress."

## Reference quick links

- Plan doc: `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`
- Main's brief: `docs/_indices/PER_DAYPART_V1_MAIN_ORCHESTRATOR_BRIEF.md`
- Workflow rules: `CLAUDE.md` Workflow section
- Prompt-shape rules: `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
- Jim Taylor methodology: `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`
- Slice 1.5 context for Task D: `docs/_audits/per_daypart_v1/slice_1_5_aggregator_bucketer.md`

Welcome back to the lane. Bootstrap v2 and go.
