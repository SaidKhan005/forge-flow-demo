# Slice 4 — Shift daypart card full parity

**Branch:** `claude/per-daypart-slice-4-shift-card`
**Base:** `master`
**Slice tag:** per-daypart-targets-v1 Slice 4
**Owner:** worker agent (Claude lane)
**Verdict:** approve-for-merge (pending orchestrator independent audit)

---

## TL;DR

The Shift screen's daypart card stops being a flat actuals-only metric
grid (`_DaypartMetricGrid`, retired — plan Known Gap #16) and becomes a
full 1:1 mirror of the whole-day card's three-section grammar
(Decision 7): **OUTPUTS** (Sales forecast progress + Labor % side by
side, Covers + Blended Wage), **INPUTS** (PPA / CPLH / SPLH actual-vs-
target + FOH/BOH hours), **FOH PRODUCTIVITY** (the shared
`ZoneStatusCard` OPZ band scoped to this period's CPLH + locked band).

Per-period locked targets come from a new `DaypartTargetContext`
resolved on the `ShiftServicePeriodNotifier`: a **closed** shift reads
its own per-shift `daypart_*` stamp columns (Promise 2 — closed truth
keeps its stamp, never re-graded); an **open / not-yet-closed** period
falls back to `ActiveTargetProfile.daypartFor(periodId)`. When no
per-period target exists (Gap 42 fallback / no cycle) every target
sub-line renders "—" and the OPZ gauge is replaced with an honest
"no locked productivity zone" line — never a `0` sentinel (Design
Rule 2). The whole-day half of the screen is byte-untouched (Promise 3 /
Layer 9 — daypart is adjacent, never replaces).

---

## Files changed

| File | LoC | Note |
|---|---|---|
| `lib/state/shift_service_period_notifier.dart` | +156 −0 | New `DaypartTargetContext` value object (`source` + 5 nullable target fields + `hasOpzBand` + `none` sentinel). New `_daypartTargets` field, `daypartTargetFor(periodId)` accessor, `daypartTargets` test-constructor param, and `_resolveDaypartTargets` (closed-shift stamp read via `SqliteShiftRecordRepository.getClosedShiftsInDateRange(rid, bd, bd)` → open-shift profile fallback). New `shift_record.dart` + shift-record-repository imports. |
| `lib/screens/shift_dashboard.dart` | +422 −88 | `_DaypartScaffoldCard` rebuilt into a 3-section parity card; new `_DaypartSectionHeader`, `_DaypartOutputsSection`, `_DaypartLaborCard`, `_DaypartInputsSection`, `_DaypartFohProductivitySection`, `_DaypartTargetedCell`, `_dpFmt` honest formatter. Retired `_DaypartMetricGrid` (plan Gap #16). `_MetricCell` reused unchanged. |
| `test/widget/shift_dashboard_daypart_test.dart` | +37 −15 | Two existing cases that pinned the retired 10.5.2 flat grid (`$4200`, `$525`, `$22.50`) re-pointed at the new parity card structure (section headers, `$4,200` via shared `SalesForecastCard`, `Target —` honest empty). Intent preserved. |
| `test/widget/shift_dashboard_daypart_parity_test.dart` | +new | 5 Slice-4 tests: three-section parity render, closed-shift stamp read-back (Promise 2), open-shift profile fallback, null/empty honest state (Design Rule 2), whole-day half untouched (Promise 3). |

Total: **+615 / −103** across 4 files (3 lib/test + 1 new test).

---

## Pattern B audit — 14 lenses

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Slice prompt #1 → `core_app_architecture.md` #2 → plan doc #3 → `CLAUDE.md` #4. The plan's Decision 7 ("full parity with whole-day card") and Slice 4 scope section are followed verbatim: Outputs + Inputs + FOH Productivity, closed-stamp read, open-profile fallback, adjacent-not-replacing. No conflict with `core_app_architecture.md` Layer 9 (whole-day authoritative, daypart additive). | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md:75–77,332–339`; `CLAUDE.md` Hard Promises #3 | None |
| 2 | **Hard Promises** | HP #1/#2 untouched (no vendor wiring; no `kDemoMode` branch; no `demo_*` table; closed-shift read goes through the same `SqliteShiftRecordRepository` demo+prod share). HP #3 (no logic before 7.58) — Slice 4 is read+render only; no Primary Driver decision changed (the existing `computePrimaryLeverId` whole-day-profile behaviour is left exactly as-is per its own docstring; the daypart chip wiring is unchanged). HP #4 (per-operator isolation) — closed-shift read is scoped by `restaurantId` through the existing repository; no new scope surface. HP #10 (operator UX before phase close) — this slice IS the operator-facing UX exposure for the per-period data layer. | `lib/state/shift_service_period_notifier.dart:329–333`; `CLAUDE.md` "Demo Mode" rules | None |
| 3 | **Service-layer split** | `DaypartTargetContext` + resolver live on `lib/state/shift_service_period_notifier.dart` (state holder — correct layer; mirrors the existing `_primaryLeverIds` resolution already there). Widgets in `lib/screens/shifts`-equivalent `lib/screens/shift_dashboard.dart` own no source-truth or bucketing — they consume `bucket` (read service) + `DaypartTargetContext` (notifier). No `lib/data/` touch, no Postgres import, no `lib/auth/` touch. | `lib/state/shift_service_period_notifier.dart:64,168,324`; `lib/screens/shift_dashboard.dart:1266,1399,1492` | None |
| 4 | **Architecture guardrails** | `TargetCycle`/`WeeklyPlanSnapshot`/`LaborModel` untouched. Shift's whole-day view stays authoritative — `_wholeDaySlivers` is unchanged; the daypart card sits in `_servicePeriodSlivers` only, rendered only when a period chip is selected (Layer 9 / Promise 3). Source facts (bucket actuals) and locked targets (`DaypartTargetContext`) are kept as separate inputs to the widget; the widget derives display only. | `lib/screens/shift_dashboard.dart:181–230` (`_wholeDaySlivers` unchanged); `:240–263` (`_servicePeriodSlivers`) | None |
| 5 | **Time guardrails** | No timestamp logic added. Closed-shift selection uses `SqliteShiftRecordRepository.getClosedShiftsInDateRange(rid, businessDate, businessDate)` — the day's business-date string already resolved by the notifier's existing `_businessDate` (restaurant-local, business-date-anchored). No `TIMESTAMP WITHOUT TIME ZONE`, no schema change. Active-period / time-into-service resolvers untouched. | `lib/state/shift_service_period_notifier.dart:329–333`; `:226` (`_businessDate` resolution unchanged) | None |
| 6 | **RLS-ready schema** | No schema change — Slice 1 already added the `shift_records` per-shift `daypart_*` columns + `target_cycle_dayparts`. This slice only **reads** them. The closed-shift read uses the existing `restaurantId`-scoped repository method (`SELECT * FROM shift_records WHERE restaurant_id = ? AND status = 'closed' AND business_date BETWEEN ? AND ?`). No new table, column, or index. | `lib/infrastructure/persistence/sqlite/dao/shift_record_dao.dart:35–44` (unchanged, consumed); `lib/models/shift_record.dart:89–93` (Slice 1 columns, consumed) | None |
| 7 | **Proxy & API conventions** | No proxy route, no idempotency key, no `/v1`/`/v2` path, no service principal, no Postgres extension. Entirely client-side SQLite read + Flutter render. | n/a | None |
| 8 | **Testing seam** | Smallest set proving the seam: (a) three-section parity render; (b) closed-shift stamp read-back asserts the target sub-lines + OPZ band come from `source: 'closed_stamp'` not the live profile (Promise 2); (c) open-shift profile fallback asserts `source: 'open_profile'` row drives the sub-lines; (d) null/empty honest state asserts `Target —` + no-zone line + NO `$0.00`/`0.00`/`IN OPZ` (Design Rule 2); (e) whole-day half still renders (Promise 3). Two retired-grid cases re-pointed, not deleted (coverage preserved). | `test/widget/shift_dashboard_daypart_parity_test.dart:130–320`; `test/widget/shift_dashboard_daypart_test.dart:168–207` | None |
| 9 | **Operator-facing copy / UX writing standard** | Copy is plain operator English, no engineering jargon: section headers `OUTPUTS` / `INPUTS` / `FOH PRODUCTIVITY` (mirror the whole-day `SHIFT OUTPUTS` etc. grammar so the operator's eye doesn't relearn — plan "Operator-visible net story"); empty states read "No locked productivity zone for this period yet." and `Target —` (honest, training-tone, no zero). No "roadmap" word. | `lib/screens/shift_dashboard.dart:1191,1208,1219,1518`; plan doc:406–408 | None |
| 10 | **Demo mode contract** | No `kDemoMode` branch. The closed-shift read uses the same `SqliteShiftRecordRepository` demo and prod share; demo closed shifts already carry per-period stamps after the Slice 1 reseed, so the demo path exercises the `closed_stamp` branch identically to prod. No `demo_*` table. Existing `CLAUDE.md` "Demo Mode" carve-outs §1–4 untouched. | `lib/state/shift_service_period_notifier.dart:329–376`; `CLAUDE.md` "Demo Mode" | None |
| 11 | **Ceiling-raise rule** | No lint-tool ceiling changed. `shift_dashboard.dart` grew 1727 → ~2061 LoC; there is no per-file cap lint on `lib/screens/` (the gated ceiling is `kAdvisorProxyMaxLines` for `advisor_proxy` only). The growth is the parity-card requirement of the slice, not monolith creep in a gated file. | `tool/advisor_proxy_size_lint.dart` (not triggered — different file) | None |
| 12 | **Phase-doc hygiene** | Slice touches 4 files (< 5) but is part of the active multi-slice `per_daypart_targets_v1` plan, which is the controlling phase doc and stays in `docs/phases/`. No new phase doc. Audit doc placed at `docs/_audits/per_daypart_v1/slice_4_shift_card.md` per the agent-led-slice rule. No tracker/ledger edits. | `CLAUDE.md` "Phase Doc Hygiene" + "Agent-led slices"; this file | None |
| 13 | **Anti-scope** | Did NOT touch the concurrency-banned set: `target_cycle_service.dart`, `weekly_plan_snapshot_service.dart`, `data_alignment_audit_read_service.dart`, `lib/screens/benchmark*`, `lib/screens/plan_*`, the variance card, `schedule_builder*`, vendor sinks. Did NOT change `computePrimaryLeverId` (Slice-5/Gap-5 territory — left exactly as its docstring describes). Did NOT change the whole-day `_wholeDaySlivers`, read-model, or any migration. Stayed strictly in shift-detail-card scope (`shift_dashboard.dart` daypart card + `shift_service_period_notifier.dart` per-period target plumbing it needs). | `lib/services/shift_service_period_read_service.dart:394–461` (`computePrimaryLeverId` unchanged); `lib/screens/shift_dashboard.dart:181–230` (`_wholeDaySlivers` unchanged) | None |
| 14 | **Honest disclosures** | Local commands (CI dark until 2026-06-01 per `CLAUDE.md`): `dart analyze lib/screens/shift_dashboard.dart lib/state/shift_service_period_notifier.dart` → **No issues found!**. `dart analyze` on both test files → **No issues found!**. Full-tree `dart analyze lib test` → 63 pre-existing `info`/`warning`/`error` items, **all in unrelated files** (postgres repo tests, auth tests, provider credentials, recommended_benchmark deprecations); zero in any of the 4 touched files (grep of analyze output for `shift_dashboard`/`shift_service_period_notifier` = no matches). Tests: `test/widget/shift_dashboard_daypart_parity_test.dart` 5/5; `test/widget/shift_dashboard_daypart_test.dart` + `test/shift_dashboard_daypart_toggle_widget_test.dart` 15/15; `test/state/shift_service_period_notifier_test.dart` + `test/shift_dashboard_notifier_test.dart` + the two daypart files (combined run) 51/51. | Local runs in this worktree, 2026-05-15 | None |

---

## Pattern B — independent re-audit

| # | Lens | Independent re-audit | Citation |
|---|---|---|---|
| A | **Promise 2 is enforced, not just intended** | `_resolveDaypartTargets` checks `closedByPeriod[def.id]` FIRST. When a closed shift exists for the period its `daypart_*` stamp columns are used and the active profile is **never consulted** for that period — so a later cycle cannot re-grade a closed period. Critically, a closed shift whose stamps are all-null (cycle had no per-period row at close) yields `DaypartTargetContext.none`, NOT a silent back-fill from the live profile. Verified by the closed-stamp test asserting `Target 13.00` (the stamp) renders even though the fixture profile's whole-day target differs. | `lib/state/shift_service_period_notifier.dart:341–366`; `test/widget/shift_dashboard_daypart_parity_test.dart:170–215` |
| B | **Design Rule 2 — no `0` sentinel anywhere** | Every target render path is null-guarded: `_dpFmt` returns `'—'` for null; CPLH target uses an explicit `== null ? 'Target —'` branch; the FOH Productivity section gates the entire `ZoneStatusCard` behind `targetContext.hasOpzBand` (all-of targetCPLH+floor+ceiling present) and otherwise renders the honest "no locked productivity zone" line — it never feeds `0.0` into the gauge. Actuals are also guarded: PPA/CPLH/SPLH/blended/hours render `'—'` when `covers == 0` / `totalMinutes == 0` rather than a real-looking `0.00`. The empty-state test explicitly asserts `Target $0.00`, `Target 0.00`, `IN OPZ`, `BELOW OPZ` are all `findsNothing`. | `lib/screens/shift_dashboard.dart:1257–1261,1421–1469,1492–1531`; `test/widget/shift_dashboard_daypart_parity_test.dart:280–318` |
| C | **Partial stamp does not draw a partial gauge** | `hasOpzBand` requires targetCPLH AND opzFloorCPLH AND opzCeilingCPLH all non-null. A stamp with target CPLH but a null floor (degenerate cycle) keeps the gauge hidden rather than drawing a band off a missing bound. This is stricter than the whole-day card (which has non-null scalars by construction) — correct for the per-period nullable shape. | `lib/state/shift_service_period_notifier.dart:94–95`; `lib/screens/shift_dashboard.dart:1505` |
| D | **Open-shift fallback reads the right accessor** | The fallback path calls `profile?.daypartFor(def.id)` — the exact Slice-1 accessor the plan names for the open-shift case — and maps its `daypart`-prefixed fields (`daypartTargetCPLH` etc., Design Rule 1 naming) into the context. A null row (Gap 42 insufficient-recommendation fallback) yields `none`, not the whole-day pool — so the card honestly shows "—" rather than silently substituting whole-day scalars at the period scope. | `lib/state/shift_service_period_notifier.dart:368–376`; `lib/domain/models/active_target_profile.dart:110–115` |
| E | **Whole-day half is genuinely untouched** | `_wholeDaySlivers` and the read-model are not in the diff. The parity test toggles to a period and asserts both that the daypart `OUTPUTS` header appears AND that `SHIFT OUTPUTS`/`SHIFT INPUTS` rendered before the toggle — the whole-day sliver tree is still constructed (additive, the selector just swaps which sliver list is in the viewport per the pre-existing `_selectedServicePeriodId == null` branch). | `git diff master -- lib/screens/shift_dashboard.dart` (lines 181–230 unchanged); `test/widget/shift_dashboard_daypart_parity_test.dart:295–319` |
| F | **Retired-grid tests re-pointed, not deleted** | The two `shift_dashboard_daypart_test.dart` cases that asserted the retired flat-grid values (`$4200`, `$525`, `$22.50`, `12.50`) now assert the parity card (`OUTPUTS`/`INPUTS`/`FOH PRODUCTIVITY` headers, `$4,200` via the shared `SalesForecastCard` formatter, `Target —` honest empty). The test *intent* (per-period actuals render after toggling to a period; pull-to-refresh propagates) is preserved verbatim; only the surface assertions moved with Decision 7. No coverage lost — the remaining 13 cases in that file still pass unchanged. | `test/widget/shift_dashboard_daypart_test.dart:168–207,405–410`; combined run 15/15 |
| G | **`computePrimaryLeverId` Gap-5 left alone (correct anti-scope)** | The slice prompt scopes Slice 4 to the card; Gap #5 (the per-period read service reaching up to whole-day target) is Slice-5/未来 territory. The daypart primary-driver chip still consumes `periodNotifier.primaryLeverCardFor` exactly as before — its whole-day-profile basis is documented and intentional in the read service's own docstring, and changing it would broaden scope into a concurrently-running slice's surface. | `lib/screens/shift_dashboard.dart:1227–1231` (chip wiring unchanged); `lib/services/shift_service_period_read_service.dart:366–393` (docstring unchanged) |

---

## Verification commands run

```
powershell -ExecutionPolicy Bypass -File scripts/install_git_hooks.ps1
# -> Forge & Flow git hooks enabled for this clone. (pwsh unavailable; ran via powershell)

dart analyze lib/screens/shift_dashboard.dart lib/state/shift_service_period_notifier.dart
# -> No issues found!

dart analyze test/widget/shift_dashboard_daypart_parity_test.dart test/widget/shift_dashboard_daypart_test.dart
# -> No issues found!

dart analyze lib test
# -> 63 issues, ALL in unrelated pre-existing files (auth tests, postgres repo
#    tests, provider credentials, recommended_benchmark deprecations). Zero in
#    any of the 4 touched files (grep of output for the touched filenames = 0).

flutter test test/widget/shift_dashboard_daypart_parity_test.dart
# -> 5/5 pass

flutter test test/widget/shift_dashboard_daypart_test.dart test/shift_dashboard_daypart_toggle_widget_test.dart
# -> 15/15 pass

flutter test test/state/shift_service_period_notifier_test.dart \
  test/shift_dashboard_notifier_test.dart \
  test/shift_dashboard_daypart_toggle_widget_test.dart \
  test/widget/shift_dashboard_daypart_test.dart \
  test/widget/shift_dashboard_daypart_parity_test.dart
# -> 51/51 pass
```

CI not run (CI dark until 2026-06-01 per `CLAUDE.md` / memory).

---

## Baseline failure snapshot

Per the "Audit Baseline Test Snapshot" doctrine: the touched-surface
test files (both daypart widget files, the notifier test, the dashboard
notifier test) all pass on the post-change branch with 0 unrelated
failures. The 63 `dart analyze` items in the full-tree run are
pre-existing latent master state in unrelated files (postgres repository
tests with `Undefined class 'PackagePostgresPool'`, auth-test lints,
`recommended_benchmark` deprecation infos) — none introduced by this
slice and none in the 4 touched files.

---

## Risks / follow-ups

- **Per-period scheduled-vs-needed hours not tracked yet.** The Inputs
  section renders actual in-period FOH/BOH hours but the "needed" target
  line is not shown (the plan's Slice 4 description mentions
  scheduled/needed/excess; per-period scheduled hours are explicitly
  "not tracked yet" per `shift_service_period_read_service.dart:392–393`
  and the `weekly_plan_snapshot_day_dayparts` required-hours wiring is
  Slice 3's surface, which runs concurrently). The hours columns
  honestly show actuals only rather than a fabricated `0` target. If the
  orchestrator wants the full scheduled/needed/excess hours columns
  wired from `weekly_plan_snapshot_day_dayparts`, that is a clean
  follow-up once Slice 3 merges — flagged for awareness, intentionally
  out of scope to avoid colliding with the concurrent Slice 3 surface.
- **Per-period Labor % theoretical reference is actual-only.** The
  `_DaypartLaborCard` shows the period's actual labor % (wage dollars ÷
  sales). A per-period *theoretical* reference would need the per-period
  CPLH/SPLH/PPA + whole-day wages composed the same way the whole-day
  `targetLaborPct` is — but per-period theoretical % is explicitly
  deferred in the plan ("Per-period theoretical % shows up only where it
  has period-specific inputs (Variance non-closed rows)", Decision 11).
  The card therefore shows the honest actual without a theoretical
  delta pill, consistent with the plan's deferral.
- **`shift_dashboard.dart` is now ~2061 LoC.** No gated ceiling lint
  applies to `lib/screens/`, but the file is large. A future
  component-extraction pass (moving the daypart card family to
  `lib/screens/shifts/`) would be a clean refactor — not in scope here
  (the slice prompt said component extraction only "if already
  structured that way"; it is not — everything lives in the one file
  today).
