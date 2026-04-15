# Phase 7.55p.5e - Blended Wage Refinement and Testing

Updated: 2026-04-13
Owner: Claude audit
Status: Landed (audit/doc only — no code changes needed)

## Goal

Audit whether the current blended wage derivation is the right formula
and source package for Benchmark / Variance / downstream consumers.

## Scope

- In: formula audit, source-input audit, surface consistency verification,
  Jim Taylor authority check
- Out: code changes (none needed), package-contract redesign, Shift
  target-package changes

## Audit Question

> Is the blended wage formula correct, consistent, and honest across
> Benchmark and Variance?

## Answer

**Yes. The formula is correct per Jim Taylor Ch. 1. No refinement needed.**

## Jim Taylor Authority

From the deep-dive doc (Ch. 1, lines 174-191):

> "Wage Mix — blended average hourly rate across all roles"
>
> "This single number — $17.62 — is what goes into the labor % formula
> as 'wage.' Every role, every pay rate, collapsed into one blended
> average."

The blended wage is defined as:

```
Blended Wage = Total Labor Dollars / Total Labor Hours
             = (FOH Hours × FOH Wage + BOH Hours × BOH Wage) / Total Hours
```

The variable is WHICH hours you weight by. The formula itself is always
the same.

## Four Blended Wage Instances in the Repo

All four use the same core formula. They differ only in the hour basis:

### 1. Benchmark Theoretical Blended Wage

**Location:** `_targetBlendedWage()` in `baseline_tracker.dart`

**Formula:**
```
modelFohHours(historicalWeeklyAvgCovers, targetCPLH) × fohWage
+ modelBohHours(historicalWeeklyAvgCovers × targetPPA, targetSPLH) × bohWage
÷ totalModelHours
```

**Hour basis:** Model hours from 60-day average weekly covers × target
rates

**Meaning:** "What is the blended wage if we staff to target for average
weekly demand?"

**Source inputs (7.55p.5a):** `ActiveTargetProfile` wages + target
CPLH/PPA/SPLH; `BaselineData.historicalWeeklyAvgCovers` for demand.

**Verdict:** ✅ Correct. Uses cycle-locked target rates to compute the
theoretical staffing mix, then blends. The demand input
(`historicalWeeklyAvgCovers`) is 60-day context, not target authority —
appropriate for a cycle-level theoretical blend.

### 2. WTD Variance Theoretical Blended Wage

**Location:** `WeekData.theoreticalBlendedWage` in `week_data.dart`

**Formula:**
```
targetFohHoursWtd × fohWage + targetBohHoursWtd × bohWage
÷ totalHours
```

**Hour basis:** Plan hours from locked `WeeklyPlanSnapshot` (with model
hours fallback)

**Meaning:** "What is the blended wage if we staff to this week's plan?"

**Verdict:** ✅ Correct. Uses the locked weekly plan hours to compute
the planned staffing mix, then blends. This is plan-aligned (consistent
with the WTD context) while still using profile wages (consistent with
the theoretical package).

### 3. WTD Variance Actual Blended Wage

**Location:** `WeekData.avgBlendedWage` in `week_data.dart`

**Formula:**
```
totalLaborDollar / totalHours
```

**Hour basis:** Actual closed-shift hours and labor dollars

**Meaning:** "What did we actually pay per hour this week?"

**Verdict:** ✅ Correct. Pure actual derivation — no target inputs.

### 4. Full Week Per-Shift Target Blended Wage

**Location:** Inline in `variance_report.dart` (line 964-966)

**Formula:**
```
(modelFohHours × lockedFohWage + modelBohHours × lockedBohWage)
÷ totalModelHours
```

**Hour basis:** Actual-volume model hours (Jim Taylor Ch. 10: "given
the actual covers that walked in, how many hours should you have used?")
× locked per-shift target wages

**Meaning:** "Given this shift's actual volume and locked targets, what
should the blended wage have been?"

**Verdict:** ✅ Correct. Uses actual-volume model hours (appropriate
for shift-level variance analysis) with locked-at-close wages
(appropriate for historical truth).

## Consistency Check

| Surface | Formula | Hour basis | Wage source |
|---|---|---|---|
| Benchmark | FOH/BOH model hours × wages / total | 60-day avg covers × target rates | Profile |
| WTD target | Plan hours × wages / total | Locked snapshot plan hours | Profile |
| WTD actual | Total labor $ / total hours | Actual closed hours + dollars | Actual |
| Full Week target | Model hours × wages / total | Actual-volume × locked rates | Locked per-shift |

All four use `(FOH hours × FOH wage + BOH hours × BOH wage) / total`.
They differ only in hour source — which is correct because each context
answers a different question about the hour mix.

## Why No Code Change Is Needed

1. **The formula is Jim Taylor Ch. 1 compliant** — always
   `totalLaborDollars / totalHours` regardless of hour source.

2. **Each surface uses the appropriate hour basis** — Benchmark uses
   cycle-level model hours; WTD uses plan hours; Full Week uses
   actual-volume model hours; actuals use real hours.

3. **Wage sources are already correct** — Benchmark uses profile wages
   (7.55p.5a); WTD uses profile wages (injected); Full Week uses
   locked-at-close wages (per-shift truth).

4. **The surfaces are intentionally different** — just as the
   theoretical vs planned labor % packages serve different purposes
   (7.55p.5c), the blended wage hour basis serves different purposes
   per surface. Unification would be dishonest.

## Existing Test Coverage

| Test | What it covers |
|---|---|
| `wtd_variance_logic_test.dart` | `theoreticalBlendedWage` derivation from plan/model hours × wages; `avgBlendedWage` from actual dollars/hours |
| `variance_visual_widget_test.dart` | Full Week rendering with `ActiveTargetProfile` injection; blended wage appears in shift detail |
| `target_consistency_opz_test.dart` Group G | Profile-precedence on `_BaselineTargetsCard` including BLENDED WAGE row |

The formula itself is simple enough (`hours × wage / total`) that
additional isolated unit tests would not add meaningful coverage beyond
what the integration tests already prove.

## Remaining Gaps

- **`BaselineData.historicalWeeklyAvgCovers` as demand input** — the
  Benchmark blended wage uses the 60-day average weekly covers for its
  model-hour computation. This is demand context, not target authority,
  and is reasonable. If a future profile-level demand field is added,
  this could migrate — but no urgency.
- **Per-daypart blended wage** (Phase 10.5) — lunch and dinner have
  different FOH/BOH mixes, so a per-daypart blended wage would be more
  precise. Deferred to daypart-aware work.
- **Actual labor dollars from vendor** — when live labor data arrives
  (Phase 8), actual blended wage will use real imported dollars instead
  of `hours × configuredWage` fallbacks. The formula does not change;
  only the input quality improves.
