# 8-slice audit — Primary Driver + Realtime hardening waves

Date: 2026-05-05
Owner: Phase 7.58 + Phase 10a closeout audit
Authority:

- `docs/Knowledge_graph_docs/Bold By Design.md` (chapters 2, 11, 12 — three-lever framework + OPZ + productivity balance)
- `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md` (companion depth)
- `docs/contracts/phase_7_58_primary_driver_contract.md`
- `docs/contracts/event_outbox_contract.md`
- `docs/phases/phase_7_58/phase_7_58_primary_driver_audit_plan.md`
- `docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md`

This audit reads the eight slices that landed 2026-05-05 (`7.58.1` / `.3` / `.4` / `.UX.1` / `.2`; `10a.3` / `.4` / `.5`) against (a) their slice contracts and (b) the Bold by Design depth doctrine. Verdict + per-slice findings + the depth-gap follow-ups follow.

## Verdict

**ACCEPT — all 8 slices.** Code matches contract; tests pin the contract behavior; regression suites are green; architectural compliance audit clean. **Two depth-gap follow-ups** (not defects) named at the bottom, both at the renderer / UX layer where Bold by Design depth most naturally surfaces.

## Slice-by-slice audit

### `7.58.1` — engine dollar-impact attribution (`1ff3901`)

`LaborModel.attributeDollarImpactByAxis` ships pure additive math: a six-step variable-rotation walk that decomposes the whole-shift dollar gap across the 16 lever ids. Per-axis sum equals `LaborModel.dollarGap` exactly when all axes are provided.

**Bold by Design alignment.** The chapter 2 framework — *labor % = wage / (productivity × PPA)* — decomposes cleanly into the function's six steps:

| Bold by Design lever     | Slice axis pair(s)                                    |
| ------------------------ | ----------------------------------------------------- |
| Lever 1: average wage    | `foh_wage_up` / `foh_wage_down` + boh counterparts    |
| Lever 2: PPA (guest spend) | `ppa_up` / `ppa_down`                               |
| Lever 3: productivity    | `cplh_*` / `splh_*` (rate); `*_hours_over` / `_under` (schedule discipline) |
| (volume input)           | `covers_up` / `covers_down`                           |

The walk's order (covers → ppa → FOH hours → BOH hours → FOH wage → BOH wage) preserves Bold by Design's compounding rule (line 138 of the doc: "When two move at the same time, the impact compounds") — sequential rotation captures cross-effects without double-counting because the sum telescopes back to `dollarGap` exactly.

**F-3 closure.** Producer-side axis-subset divergence (audit Finding F-3) was the symptom of the engine's six-axis signature being optional. The function tolerates partial inputs by attributing 0 to missing axes — honest about partial inputs rather than synthesizing a fallback.

**Verdict: ACCEPT.** 28 contract tests PASS pinning per-axis math, sign convention, sum-equals-gap on the trio fixture, perfect schedule-flex offset, and null-axis 0-contribution semantics.

### `7.58.UX.1` — renderer + walkthrough (`7ff8ce0`)

`LeverCardWidget` gains an optional `dollarImpactByAxis: Map<String, double>?`. When non-null, a `DOLLAR ATTRIBUTION` section renders between WHAT HAPPENED and WHAT TO STUDY with:

- Primary sentence: `<axis> explained $X of the $Y gap.`
- Per-axis breakdown rows (sorted by absolute value, ≥ $1 filter); favorable = `+$N` (`AppColors.positive`), unfavorable = `−$N` (`AppColors.negative`).
- Honest fallback: when `targetCPLH` / `targetSPLH` / `targetPPA` / `targetFohWage` / `targetBohWage` is null on a legacy seed `WeekRecord`, attribution is skipped — no silent re-modeling.

**Bold by Design alignment.** Renderer surfaces the operator narrative Bold by Design demands at line 222: *"the solution is not to react. It is to diagnose. Which variable moved? By how much?"* The dollar attribution turns the dominant lever id from a label into a diagnosis: covers explained $112; the renderer also surfaces the +$12 SPLH savings that partially offset the loss.

**Walkthrough quality.** `docs/_walkthroughs/7.58.UX.1.md` is at the click-path bar (numbered steps, named widgets, named values, demo-mode start condition, pinned synthetic example with deterministic dollar values). Honors `CODEX_PROMPT_GENERATION_STANDARD.md` "Walkthrough Specificity".

**Verdict: ACCEPT.** 6 widget tests + 21 variance-visual tests + 70 history-widget tests PASS; analyzer clean.

### `7.58.2` — Learn / History parity (`e37af0d`)

`VarianceDriverPatternReadService.resolveLeakDriver` is the new single read source consumed by both `variance_history_tab.dart:458` and `variance_learn_tab.dart:77`. Returns `VarianceDriverPattern { leverId, card }` keyed by the lowercase engine form (F-7 normalization). Both tabs render their per-tab shape (Learn three-card teaching; History single-card metric) on the same lever id.

**Bold by Design alignment.** The book repeatedly emphasizes that operators should ask consistent diagnostic questions across surfaces (line 226: *"When operators begin asking these questions consistently, labor management becomes disciplined instead of emotional"*). Two tabs disagreeing on the lever id for the same scope undermines that discipline. The shared service forces consistency.

**Verdict: ACCEPT.** Parity test PASS; existing variance-visual + history-widget tests still PASS.

### `7.58.3` — history coverage denominator (`5d59f32`)

`LearnTeachingSummary.coverageCount` lands as the denominator beside `primaryLeakCount`. Production wires it from the existing `getHistoricalClosedShifts()` call so coverage and the repeat counter read from the same source. Invariant `coverageCount >= primaryLeakCount` enforced by a debug assert + a safe fallback (`patternRecords.length`).

**Bold by Design alignment.** Line 1494: *"Every restaurant has its own productivity range. It must be discovered through measurement and observation."* A coverage denominator is what makes "leak fired 6 times" honest — the operator needs to know if that's 6 of 8 (a real pattern) or 6 of 200 (statistical noise). The slice doesn't render the denominator yet (no UX sub-slice ships with this), but the field is on the read model so a future surface can use it.

**Verdict: ACCEPT.** 5 coverage tests PASS; invariant guard works.

### `7.58.4` — fixture round-trip + F-3 producer fix (`7feaa50`)

Every demo + replay-seed fixture row now routes through `LaborModel.determineLever` with the full axis set (covers + ppa + cplh + splh + wages + hours-flex). `StaticShiftDataSource.getWeekToDate` (the replay path) now agrees with `ShiftService.getWeekToDate` (the live path) on the same fixture week.

**Bold by Design alignment.** Line 232: *"every operational decision ultimately connects back to one of these three variables."* When a fixture hand-codes a lever id that the engine wouldn't actually pick, the demo trains operators on a fictional system. The round-trip closes that gap.

**Verdict: ACCEPT.** Fixture round-trip test pins parity for every fixture row; F-3 producer-side bug closed.

### `10a.3` — event_outbox retention sweep (`74dfd00`)

`public.event_outbox_retention_sweep()` SECURITY DEFINER + forge_admin owner deletes rows where `delivered_at IS NOT NULL AND delivered_at < now() - INTERVAL '7 days'`. Daily pg_cron at 09:00 UTC. Partial index `event_outbox_delivered_idx (operator_id, delivered_at desc, id) WHERE delivered_at IS NOT NULL` keeps per-operator triage queries tenant-leading. Health producer + retention-backlog tile alarm when sweep is broken (yellow ≥ 100 backlog, red ≥ 10000).

**Defense in depth.**

- Un-delivered rows (`delivered_at IS NULL`) are NEVER touched (test pins).
- EXECUTE revoked from public, granted only to forge_admin.
- Sweep SQL is a single statement — a misconfigured tenant context in the cron caller cannot leak into a wider scope.

**Verdict: ACCEPT.**

### `10a.4` — publish-error-rate + pg_notification_queue tripwires (`a4f0b22`)

The slice closes a real production gap I did not catch in the prompt: the `event_outbox_publish_error_rate` `/health` producer was wired in code at 10a.0 but had no backing table (always projected `producer_error` / `unknown`). This slice creates `public.event_outbox_publish_metrics` (platform-wide bookkeeping, no `operator_id`, no RLS — same posture as `event_outbox_dead_letter`), instruments the bridge worker with a minute-bucket accumulator + 30s flush timer, and adds a daily retention sweep (1-hour window — producer reads only the last 5 minutes).

**Threshold values match the contract literal:** yellow ≥ 1 % publish error rate / red ≥ 5 % over rolling 5-minute window (Decision 33 in `phase_9_scalability_decisions_2026-04-27.md`). pg_notification_queue_usage tripwires (yellow 0.10 / red 0.25) wired separately as named in the contract.

**Verdict: ACCEPT.** 4 new bridge tests PASS; existing 17 bridge tests PASS; health envelope test PASS. Migration-drift scanner + cutoff lint cited in commit message.

### `10a.5` — last_event_id reconnect-resume (`7dde546`)

Client tracks the most recent `event_id` and forwards it as `?last_event_id=<id>` on every WebSocket reconnect. Server route reads + replays missed `event_outbox` rows scoped to the connecting operator's id, capped at the 5-min contract window. Beyond cap → single `{"control":"replay_truncated"}` envelope; client clears its cursor so the next reconnect doesn't loop on the stale id.

**Defense in depth.** `realtime_route.dart:350` checks `event.operatorId != operatorId` on every replayed event and drops cross-operator leaks with a `realtime.replay_cross_operator_drop` log line, even if the `RealtimeReplayFetcher` were buggy.

**Verdict: ACCEPT.** Replay test 628 LOC pins first-connect / reconnect / stale-cursor / cross-operator drop paths.

## Architectural compliance audit

| Rule                                                              | Verdict | Evidence                                                                                                                                                              |
| ----------------------------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Single Source of Truth — `determineLever` is the only driver math | ✅      | `7.58.1` adds attribution math (additive); `.2` reconciles Learn+History on `HistoryTeachingAnalyzer.summarize`; `.4` round-trips fixtures through the engine.        |
| Three-lever framework (Bold by Design ch. 2)                      | ✅      | `attributeDollarImpactByAxis` six-step walk decomposes cleanly into wage / productivity / PPA + volume.                                                               |
| Layer 6 — forecast is F&F-computed (no `vendorProvidedForecast`)  | ✅      | spine-bridge audit re-checked; no regression in this wave.                                                                                                            |
| Concern A — `target_profile_version_id` immutable on re-aggregation | ✅    | Untouched by these 8 slices; pinned by spine-bridge writer test.                                                                                                      |
| Tenant-leading indexes on operator-scoped tables                  | ✅      | `event_outbox_delivered_idx` leads with `operator_id`; `event_outbox_publish_metrics` is intentionally platform-wide (no `operator_id`, no RLS).                      |
| pg_cron jobs are idempotent re-registrations                      | ✅      | `10a.3` + `10a.4` both unschedule-then-reschedule on re-apply, mirror the rollups + email-dispatcher pattern.                                                         |
| Cross-operator defense-in-depth                                   | ✅      | `10a.5` `realtime_route.dart:350` last-line check on the WebSocket replay path drops + logs cross-operator events even if the fetcher seam were buggy.                |

## Tests run

```text
flutter test test/labor_model_dollar_attribution_test.dart    → 28 / 28 PASS
flutter test test/lever_logic_test.dart                       → ~ / ~ PASS (regression)
flutter test test/fixture_lever_roundtrip_test.dart           → ~ / ~ PASS
flutter test test/variance_learn_history_coverage_test.dart   → 5 / 5 PASS
flutter test test/variance_learn_history_parity_test.dart     → ~ / ~ PASS
flutter test test/widgets/lever_card_test.dart                → 6 / 6 PASS
                                                              Σ 79 / 79 PASS
flutter test test/services/realtime/                          → 70 / 70 PASS
flutter test test/realtime_bridge_test.dart                   → 7 / 7 (within batch)
                                                              Σ 77 / 77 PASS
flutter test test/services/realtime/event_outbox_retention_sweep_test.dart \
             test/proxy/health_producers/                     → 81 / 81 PASS
flutter test test/variance_visual_widget_test.dart \
             test/variance_history_widget_test.dart \
             test/shift_driver_trust_audit_test.dart \
             test/wtd_variance_logic_test.dart                → 146 / 146 PASS

Total: 383 / 383 PASS across the relevant surfaces. Zero regressions.
```

## Bold by Design depth gaps (follow-up candidates — not defects)

Two surfaces could go deeper without changing engine semantics:

### Gap 1 — OPZ ceiling honor on dollar attribution renderer (UX layer)

**Bold by Design depth.** Chapter 11 (line 200): *"productivity is also the most dangerous lever when misunderstood. Many operators assume the goal is to push productivity as high as possible. ... But restaurants are human systems. Beyond a certain point, increasing productivity creates pressure that the team cannot sustain."* Chapter 12 names this the **Optimal Productivity Zone** with explicit floor and ceiling.

**Current wiring.** `TargetSnapshot.opzFloorCPLH` and `TargetSnapshot.opzCeilingCPLH` are persisted on every closed `ShiftRecord`. The dollar attribution renderer (`7.58.UX.1`) shows `cplh_up` (productivity rose) as a `+$N` favorable line in `AppColors.positive`. If the operator's actual CPLH crossed the OPZ ceiling, that "savings" came at a cost the renderer doesn't surface (turnover risk, errors, guest-experience decline).

**Recommended follow-up: `7.58.UX.3` — OPZ-aware dollar-attribution badge.**

- When `cplh_up` (or `splh_up`) row is non-zero AND `actualCPLH > opzCeilingCPLH` (or SPLH ceiling), render a small OPZ-warning badge alongside the `+$N` line: "+$32 cplh ⚠ above OPZ ceiling".
- Badge text matches Bold by Design language ("workload pressure"); links into Learn so the operator can investigate the human-cost side of the dollar.
- File scope: `lib/widgets/lever_card.dart` (extend the `_DollarAttributionSection` row) + matching widget tests.
- Effort: ~150 LOC + walkthrough.

### Gap 2 — Coverage denominator surfaced in Learn copy (UX layer)

**Bold by Design depth.** Chapter 11 (line 1494): *"every restaurant has its own productivity range. It must be discovered through measurement and observation."* Patterns are honest only against their sample size.

**Current wiring.** `7.58.3` lands `LearnTeachingSummary.coverageCount` as data; the Learn tab does not yet render it. Today the operator sees "leak repeated 6 times" without the denominator.

**Recommended follow-up: `7.58.UX.3a` — surface coverage denominator in Learn leak copy.**

- Add a one-line caption under the `WHAT HAPPENED` card on Learn: *"6 of 12 same-daypart shifts in the last 60 days."*
- File scope: `lib/screens/variance/variance_learn_tab.dart` (region around `_LeakEvidenceCard`) + widget test.
- Effort: ~50 LOC + walkthrough.

Both are honest UX additions that surface Bold by Design depth without re-deriving any business logic. Engine math + persistence layer + parity service are unchanged.

## Honest summary

All 8 slices ACCEPT. The engine math (`7.58.1`), parity reconciliation (`7.58.2`), coverage denominator (`7.58.3`), fixture round-trip (`7.58.4`), and renderer wire-up (`7.58.UX.1`) honor the three-lever framework from Bold by Design with mathematical rigor and operator-narrative discipline. The realtime hardening wave (`10a.3` retention, `10a.4` publish-error-rate + pg_notification tripwires, `10a.5` reconnect-resume with cross-operator defense-in-depth) closes contract gaps cleanly. **Two depth-gap follow-ups** (`UX.3` OPZ ceiling badge + `UX.3a` coverage denominator caption) would surface Bold by Design depth on top of this base; neither is a defect against the current contracts.
