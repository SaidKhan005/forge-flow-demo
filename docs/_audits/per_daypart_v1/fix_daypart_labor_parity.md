# Audit — Shift daypart card: true 1:1 LABOR % parity (Theoretical + delta pill)

Branch: `claude/fix-daypart-labor-parity` · Base: `master` · Worker self-audit (Pattern B, 14-lens, file:line).

## Decision-11 supersession (explicit operator instruction)

The prior Per-Daypart V1 **Decision 11** deferred the per-period
*theoretical* labor % from the daypart card (whole-day-only theoretical;
wages stay whole-day). The operator instruction driving this fix
**explicitly and repeatedly supersedes that deferral**: the daypart
LABOR card must be a TRUE 1:1 layout mirror of the Whole Day card,
including the `Theoretical X.X%` sub-line and the `±X.X pts` delta pill.
This audit records that supersession. Design Rule 5 (wages stay
whole-day — no per-period wage variant) is **unchanged**: the per-period
theoretical still derives from per-period rate targets × the profile's
whole-day wages, via the pre-existing
`ActiveTargetProfile.daypartTheoreticalLaborPctFor`.

## What changed

| File | Change |
|---|---|
| `lib/state/shift_service_period_notifier.dart:71-90` | Added `DaypartTargetContext.theoreticalLaborPct` (nullable) + constructor param + doc. |
| `lib/state/shift_service_period_notifier.dart:361-420` | `_resolveDaypartTargets` resolves `profile?.daypartTheoreticalLaborPctFor(def.id)` once per period and threads it into every constructed context (closed_stamp, open_profile, and the none branches). |
| `lib/screens/shift_dashboard.dart:1449-1572` | `_DaypartLaborCard` rebuilt to mirror `_LaborVarianceSection` (`shift_dashboard.dart:1946-2010`): Theoretical sub-line + delta pill with identical spacing/alpha/radius/icon/text constants; honest degrade. |
| `test/widget/shift_dashboard_daypart_parity_test.dart:329-461` | +3 tests: target present (Theoretical + pill), labor-unconnected (actual `—`, Theoretical kept, no phantom pill), whole-day labor render unchanged. |

## Pattern B — 14-lens self-audit

| # | Lens | Verdict | Evidence |
|---|---|---|---|
| 1 | Slice intent met | PASS | Daypart LABOR card now renders label + actual + `Theoretical X.X%` + `±X.X pts` pill, structurally 1:1 with whole-day (`shift_dashboard.dart:1494-1571` vs `:1960-2008`). |
| 2 | Authority order | PASS | Prompt > CLAUDE.md (Metric Honesty, UX) > operator Decision-11 supersession honored. No Tier-2 contract contradicted; Design Rule 5 preserved. |
| 3 | Promise 3 / Layer 9 (whole-day byte-untouched) | PASS | `_LaborVarianceSection` / `_LaborCard` (`shift_dashboard.dart:1921-2010`) not edited (diff touches only `_DaypartLaborCard` 1449-1572). New test `whole-day LABOR card render is unchanged` green. |
| 4 | Promise 2 (closed truth keeps stamp) | PASS | Closed-period locked *rate* target sub-lines still read the closed stamp (`shift_service_period_notifier.dart:386-407`, unchanged logic). The theoretical *reference* parallels the whole-day card, which itself reads live `profile.theoreticalLaborPct` (`shift_dashboard_read_model.dart:404`) — not a stamp — so the per-period mirror reading the live profile is the correct 1:1, documented at `shift_service_period_notifier.dart:363-371`. |
| 5 | Metric Honesty / Design Rule 2 | PASS | actual null → `—`; theoretical null → sub-line hidden (no `Theoretical 0.0%`); pill hidden when either side null (`shift_dashboard.dart:1456-1474, 1519-1571`). No phantom `0.0%`/`0.0 pts`. Tests assert `findsNothing` for phantom strings. |
| 6 | Byte-consistent visual constants | PASS | Pill padding `sym(h6,v2)`, `alpha 0.10`, `radius 2`, icon `size 14`, `mono12 w700`, `SizedBox(3)`/`SizedBox(8)` all copied from `_LaborVarianceSection`; minus glyph U+2212 matches whole-day `'−'` (same codepoint/render). |
| 7 | Scope discipline | PASS | Only the 3 in-scope files touched (`git diff --stat`). SALES/COVERS/BLENDED-WAGE tiles, section headers, OPZ untouched. Concurrency files (`sqlite_database_seed.dart` etc.) not touched. |
| 8 | No app-logic regression | PASS | `daypartTheoreticalLaborPctFor` is pre-existing (`active_target_profile.dart:142`); no formula added/changed; notifier not rebuilt (profile already loaded at resolve site, `shift_service_period_notifier.dart:304/319`). |
| 9 | Null-safety / degrade paths | PASS | `theoreticalPct`/`variancePts` are `double?`; `(variancePts ?? 0)` guards `isOver`; conditional `if (… != null) ...[]` spreads. `dart analyze` clean. |
| 10 | Tests prove the seam | PASS | 3 new tests cover target-present, honest-empty, whole-day-unchanged; 19/19 in the 3 named files + ticker regression green. |
| 11 | Backward compat | PASS | `theoreticalLaborPct` optional → existing `DaypartTargetContext(...)` call sites + `.none` + `.fromBuckets` test constructor compile unchanged (analyze clean; closed-state + 10.5.2 tests green). |
| 12 | UX writing | PASS | No new copy strings; reuses whole-day `LABOR %` / `Theoretical` / `pts` wording verbatim. |
| 13 | House rules | PASS | No `db/migrations/*` change → drift scanner N/A. Hooks installed (step 0). No tracker edits. |
| 14 | Contract STOP | PASS | branch → implement → self-audit → commit + push → PR → STOP. No merge, no `--no-verify`. |

## Local verification (CI dark)

- `flutter pub get` — OK.
- `dart analyze lib/screens/shift_dashboard.dart lib/state/shift_service_period_notifier.dart test/widget/shift_dashboard_daypart_parity_test.dart` — **No issues found!**
- `flutter test` `shift_dashboard_daypart_parity_test.dart` + `shift_dashboard_daypart_closed_state_test.dart` + `shift_dashboard_daypart_test.dart` — **+19 All tests passed!**
- `flutter test shift_dashboard_ticker_test.dart` (whole-day regression) — **+4 All tests passed!**

## Residual / follow-ups

None blocking. The `0.0`-vs-`null` divide-by-zero sentinel inside
`daypartTheoreticalLaborPctFor` itself (a degenerate per-period row with
non-positive CPLH/PPA/SPLH returns `0.0`) is pre-existing and matches the
whole-day scalar's behaviour; out of scope per the read-only Slice-5
note at `active_target_profile.dart:136-141`.
