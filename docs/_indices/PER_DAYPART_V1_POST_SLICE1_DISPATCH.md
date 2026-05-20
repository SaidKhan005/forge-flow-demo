# Per-Daypart V1 — Post Slice 1 Merge: Pre-staged Worker Dispatch

> Pre-staged worker prompts to fire as a single parallel wave the moment Slice 1 (PR #767) merges. Saves ~20–30 min of prompt drafting when the operator returns + approves.

## Dispatch order

Fire all 5 in one message (4 Main + 1 Claude 2). Each worker contracts to `worktree → implement → self-audit → PR → STOP`. Orchestrator audits + merges.

| # | Slice | Lane | Branch prefix | Reads from | Writes to |
|---|---|---|---|---|---|
| 1 | 2 — Benchmark tab redesign | Main | `claude/per-daypart-slice-2-benchmark-tab` | `target_cycle_dayparts` + `ActiveTargetProfile.dayparts` | UI only (lib/screens/benchmark_*) |
| 2 | 3 — Plan tab persistence wiring | Main | `claude/per-daypart-slice-3-plan-persistence` | `weekly_plan_snapshot_day_dayparts` | `schedule_builder` + Plan tab read seam |
| 3 | 4 — Shift daypart card full parity | **Claude 2** | `claude2/per-daypart-slice-4-shift-card` | `target_cycle_dayparts` + per-shift `daypart_*` stamps | `lib/screens/shifts/*` widgets |
| 4 | 5 — Variance read-seam swap | Main | `claude/per-daypart-slice-5-variance-read` | `ActiveTargetProfile.dayparts` | Variance card read paths |
| 5 | 6 — Audit scorer extension | Main | `claude/per-daypart-slice-6-audit-scorer` | both new child tables + `wage_at_lock_time_json` | `data_alignment_audit_read_service.dart` |

## Universal worker preamble (paste into all 5)

```
You are a slice worker for the Per-Daypart Targets V1 implementation.

Authority order:
1. This prompt.
2. `docs/contracts/core_app_architecture.md`.
3. `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` — slice scope.
4. `CLAUDE.md` — workflow + design rules + hard promises.

Contract: branch → implement → self-audit → commit + push → open PR → STOP.

Forbidden:
- `--no-verify`, `--no-gpg-sign`, any hook bypass.
- Merging your own PR.
- Updating trackers, ledgers, or memory files.
- Modifying files outside the slice's named paths.
- Sentinel-0 in place of null (Design Rule 2).
- Whole-day field reuse where per-period names are required (Design Rule 1).
- Bypassing the canonical write path (Design Rule 4).

Step 0: `pwsh scripts/install_git_hooks.ps1`.
Final step: open PR with Pattern B 14-lens audit table + file:line citations + audit doc at `docs/_audits/per_daypart_v1/slice_<N>_<topic>.md`.
```

## Slice 2 — Benchmark tab redesign (Main)

**Scope:**
- Daypart Breakdown table: swap avg→target columns; keep Avg Covers; fold OPZ floor + ceiling into one range column.
- Cut "Targets Derived from Benchmark" card. Rehome content as "Operating Wage Mix" + "Theoretical Labor %: The Floor" strip (Option B, no em dash).
- De-hardcode 4 UI sites (period labels) → read `ServicePeriodConfig.shortLabel` (now landed Slice 2.5).
- Reader swap: read `ActiveTargetProfile.daypartFor(periodId)` for per-period values; fall back to whole-day pool when `dayparts` is empty (Gap 42 path).
- Cut operator-web Benchmarks override surface entirely (Gap 35 resolution).

**Files (tentative):**
- `lib/screens/benchmark_screen.dart` + `lib/screens/benchmark/*` widgets.
- `lib/operator_web/screens/benchmarks_*.dart` — delete the override surface.
- 3 new tests for: per-period read-back, OPZ single column rendering, fallback path when `dayparts` empty.

**Concurrency:** no overlap with Claude 2 (operator-web service period editor + shift card). No overlap with Slices 3/5/6 (different files).

---

## Slice 3 — Plan tab persistence wiring (Main)

**Scope:**
- Allocator retirement: stop generating ad-hoc per-period values at read time. Read `weekly_plan_snapshot_day_dayparts` rows that Slice 1 now writes.
- Plan tab sub-row read swap: existing expandable sub-rows read from the new child table, not from on-the-fly compute.
- `schedule_builder` sentinel-0 cleanup: replace `0`-as-null with explicit `null` (Design Rule 2).
- **No target columns on Plan tab** (operator-locked decision: Plan owns demand, Benchmark owns targets).
- Allocator code: delete if no other consumer; otherwise mark deprecated.

**Files (tentative):**
- `lib/services/weekly_plan_*.dart` (read seams)
- `lib/screens/plan_*` (sub-row reads)
- `lib/services/schedule_builder*.dart` (sentinel cleanup)
- 4+ new tests covering reader swap + sentinel removal.

**Concurrency:** no overlap. Plan reads, Slice 4 writes for shift.

---

## Slice 4 — Shift daypart card full parity (Claude 2)

**Scope:**
- UX overhaul: shift daypart card mirrors whole-day card structure 1:1 — Outputs (sales, covers, labor) + Inputs (FOH/BOH hours, wages-as-disclosed) + FOH Productivity (CPLH/SPLH/PPA + OPZ band) per period.
- Read from per-shift `daypart_*` stamp columns (Promise 2: closed truth retains stamp); fall back to `ActiveTargetProfile.daypartFor` for open shifts.
- Keep whole-day card; daypart card sits adjacent per Promise 3 / Layer 9.

**Files (tentative):**
- `lib/screens/shifts/shift_detail_*` + daypart card widgets.
- Possibly `lib/screens/shifts/components/*` if extracted.
- 3+ new widget tests.

**Concurrency:** Claude 2 lane. No conflict with Main slices 2/3/5/6.

---

## Slice 5 — Variance read-seam swap (Main)

**Scope:**
- WTD-vs-Plan variance card: swap reads from whole-day-only to per-period (using `ActiveTargetProfile.dayparts`).
- Visual: Option B — flat layout, accurate underneath. No UX overhaul.
- Falls back to whole-day pool when `dayparts` empty (Gap 42).
- Verify changing hours dictated by operator timing config (NOT by hardcodes).

**Files (tentative):**
- `lib/screens/variance_*` or wherever WTD variance lives.
- 2+ tests for read swap + fallback.

**Concurrency:** small slice. No overlap.

---

## Slice 6 — Audit scorer extension (Main)

**Scope:**
- Extend `data_alignment_audit_read_service.dart` with per-period check shapes.
- New audit: pool-consistency invariant (read `target_cycle_dayparts`, compute the cover-weighted rollup, compare against parent's whole-day pool fields → flag drift).
- New audit: wage-at-lock-time provenance (read `weekly_plan_snapshots.wage_at_lock_time_json`; compare locked dollar values against THIS column, not against current `ActiveTargetProfile` wages — Design Rule 8).
- Structural ordering bug fix (Gap 38).

**Files (tentative):**
- `lib/services/data_alignment_audit_read_service.dart`
- `lib/screens/learn/*` (if narration tail picks up new audit shapes)
- 5+ new audit-scenario tests covering: pool drift, wage stamp mismatch, structural ordering, per-period edge cases.

**Concurrency:** depends on Slice 1 + Slice 1.5 (both merged). No overlap with Slices 2/3/4/5.

---

## Post-dispatch cadence

- Each worker estimates 30–90 min.
- Dispatch all 5 simultaneously; orchestrator handles 5 returning PRs in audit-queue order.
- Per the CLAUDE.md "Orchestrator Auto-Merges Audited-Approved PRs" rule (2026-05-13), clean Pattern B + no operator-decision findings → orchestrator merges without re-pinging.
- Slice 4 (UX-touching) and Slice 6 (audit-scorer-touching) might surface operator-decision findings; otherwise expect 5 clean auto-merges.

## Stop conditions

- If 2+ PRs await audit + 2+ operator-decision findings stack: pause new dispatches until operator returns.
- If Slice 6 audit finds drift in already-merged Slice 1 schema: file as Slice 1 follow-up, not Slice 6 send-back.
- Slice 7b dispatch waits for operator option pick.
