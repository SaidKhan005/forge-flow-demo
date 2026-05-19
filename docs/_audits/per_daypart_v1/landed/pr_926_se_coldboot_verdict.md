# Audit — PR #926 (SE: carry per-period verdict through cold-boot profile reattach)

Branch `claude/per-daypart-v1-se-coldboot-verdict-reattach` → `master`.
Verdict: **APPROVE pending operator merge sign-off** (runtime read-path; trivial, mirrors proven code).

## Root cause (verified against master, not assumed)
- Cold-boot seed rows DO carry verdict: `sqlite_database_seed.dart:_buildDemoSeedDayparts` sets `verdict`/`verdictReason` (~1421-1438).
- Refresh path DOES carry verdict onto the profile: `TargetCycleService._syncActiveTargetProfile` maps `verdict: d.verdict, verdictReason: d.verdictReason` (target_cycle_service.dart ~695-704). (Why it self-heals after a refresh.)
- Cold-boot READ path DROPPED it: `WageStandardContextService._reattachCycleDayparts` rebuilt `ActiveTargetProfileDaypart` from the cycle WITHOUT verdict/verdictReason → `daypartFor(period).verdict == null` on first boot → per-period chip fell back to whole-day.

## Change (surgical)
`lib/services/wage_standard_context_service.dart` `_reattachCycleDayparts`: **+2 lines** only —
`verdict: d.verdict,` / `verdictReason: d.verdictReason,` — making the mapping byte-identical to `_syncActiveTargetProfile`. Confirmed via diff: lib change is EXACTLY those 2 added lines, nothing else. Only other changed file: new regression test. No model/migration/widget/seeder/selection/copy/tracker/spec touched. `_matchesCycleProjection` only compares scalars (no verdict), so no sibling helper drops it — no second edit needed.

## Verification (independent)
- Diff inspected: lib hunk is the 2 additive passthrough lines in `_reattachCycleDayparts` only.
- Orchestrator end-to-end re-run: scratch = `origin/master` + SE (clean merge, 0 conflicts). Virgin-DB cold-boot via real `_seedColdBootDemo`, then the real screen read path (`loadOrBootstrapProfile` + `BenchmarkTrackerReadService` + honesty hydration):
  - whole-day badge `GOOD OPZ RANGE` target 4.69
  - **Lunch teachable 4.52 / Dinner teachable 4.90 / Late Night teachable 4.05** — every per-period chip now carries its own verdict on the FIRST cold boot. "RESULT: fixed." All tests passed.
- Agent's own new test `per_daypart_v1_se_coldboot_verdict_reattach_test.dart` + 2 neighbours: 76/76; `dart analyze` clean; no `--no-verify`.

## Gate
Runtime-exposed read-path change, but a trivial 2-line additive passthrough exactly mirroring an already-merged, proven mapping; end-to-end re-verified. Operator merge sign-off requested per workflow.
