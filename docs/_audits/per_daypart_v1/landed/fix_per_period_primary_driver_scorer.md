# Audit — Per-period primary-driver scorer: score against per-period targets with whole-day Gap-42 fallback

Branch: `claude/fix-per-period-primary-driver-scorer` · Base: `master` (`e5fe02de`)
Files: `lib/services/shift_service_period_read_service.dart`,
`test/services/shift_service_period_primary_driver_test.dart`

## The gap (as diagnosed)

`computePrimaryLeverId` scored per-period actuals against the **whole-day**
`profile.targetCPLH/SPLH/PPA` scalars even though Per-Daypart V1 Slice 1
shipped `ActiveTargetProfileDaypart` + `ActiveTargetProfile.daypartFor()`.
Consequence: the per-period driver could collapse / mislabel against the
wrong yardstick (Design Rule 1 mislabel; breaks the One Outcome Anchor) —
a read-side cause of the "all covers" symptom independent of the seed.

## The fix

1. Resolve a per-period target triple from
   `profile.daypartFor(bucket.servicePeriodId)`; per-axis Gap-42 fallback
   to the whole-day `profile.targetCPLH/SPLH/PPA` when the row is absent
   OR the per-period rate is `≤ 0` (degenerate). Never scores against `0`.
2. Wages untouched — `profile.fohWage/bohWage` (whole-day, Design Rule 5).
3. Stale docstring rewritten to state per-period targets ARE used with
   whole-day Gap-42 fallback.
4. All-missing case is byte-identical (fallback === pre-Slice-1 scalars).

## Pattern B — 14-lens self-audit (file:line)

| # | Lens | Verdict | Evidence |
|---|------|---------|----------|
| 1 | Slice intent satisfied | PASS | Per-period targets resolved `shift_service_period_read_service.dart:417-428`; threshold deltas + engine call now consume `targetCPLH/targetSPLH/targetPPA` resolved values (`:447,449,452,464-466`). |
| 2 | (a) Per-period targets now used | PASS | `daypart = profile.daypartFor(bucket.servicePeriodId)` then per-axis selection `:417-428`; engine `targetCPLH/targetSPLH/targetPPA` args `:464-466` are the resolved values, not `profile.target*`. Test "whole-day on-target but per-period CPLH target differs → driver flips" asserts `cplh_up` where whole-day-only returns null (`primary_driver_test.dart` per-period group). |
| 3 | (b) Gap-42 fallback — null row | PASS | `(daypart != null && daypart.daypartTargetX > 0) ? ... : profile.targetX` `:418-427`. Test "per-period row exists for a DIFFERENT period → daypartFor null → whole-day fallback" asserts `fallbackId == referenceId` (no-dayparts profile) == `covers_down`. |
| 4 | (b) Gap-42 fallback — degenerate `0` | PASS | `> 0` guard on each daypart rate `:418,422,426` → `0` rate falls back. Tests "degenerate/zero per-period rates → whole-day fallback, never scores against zero" (`covers_down`, no NaN/∞) and "mixed degeneracy: only per-period SPLH is 0" (`cplh_up`). |
| 5 | (c) Wages still whole-day | PASS | `profile.fohWage`/`profile.bohWage` unchanged `:434-435,442-443,445-446,468-471`; no daypart wage field read (none exists). Design Rule 5 honored. |
| 6 | (d) All-missing byte-identical | PASS | When `daypartFor` null for every period, every axis = `profile.targetX`; guard `targetCPLH<=0||targetPPA<=0` `:430` mirrors prior `profile.targetCPLH<=0||profile.targetPPA<=0`. Reference-equality test + full pre-existing suite (35 tests) green unchanged. |
| 7 | No scope creep | PASS | Diff = primary file + its test only (`git diff --stat`: 2 files). Notifier (`shift_service_period_notifier.dart`) untouched; `active_target_profile.dart` read-only consumed. |
| 8 | No banned ops | PASS | No merge, no tracker edit, no `--no-verify`. Hooks installed step 0. |
| 9 | Engine remains SoT | PASS | Id still minted solely by `LaborModel.determineLever` `:463-472`; only the target inputs changed. 7.58 F-2 `null` empty-candidate gate `:459` preserved. |
| 10 | Canonical id form | PASS | Existing "16 catalog ids" + lowercase R-STOR-1 tests unchanged & green. |
| 11 | Docstring accuracy | PASS | `:366-389` rewritten — states per-period targets used + whole-day Gap-42 fallback + wages whole-day + all-null byte-identical. No stale "not yet shipped" line. |
| 12 | Static analysis | PASS | `dart analyze` touched files → "No issues found!" |
| 13 | Tests | PASS | New per-period group (4 tests) + pre-existing primary-driver (18) + read-service (17) + lever_logic + 7.58/7.61 contracts + labor_model_boh_sales/dollar_attribution + fixture_lever_roundtrip all green. |
| 14 | Concurrency boundary | PASS | Only `shift_service_period_read_service.dart` + its test touched; no Slice-B seed, layout, auth, or benchmark files modified. |

## Local verification (CI dark)

- `flutter pub get` → `Got dependencies!`
- `dart analyze lib/services/shift_service_period_read_service.dart test/services/shift_service_period_primary_driver_test.dart` → **No issues found!**
- `flutter test test/services/shift_service_period_primary_driver_test.dart test/services/shift_service_period_read_service_test.dart` → **+35 All tests passed!**
- `flutter test test/lever_logic_test.dart test/contracts/phase_7_58_primary_driver_test.dart test/contracts/phase_7_61_driver_key_test.dart` → **+85 passed** (no failures; an earlier `-1` was a mistyped path, not a test failure)
- `flutter test test/labor_model_boh_sales_test.dart test/labor_model_dollar_attribution_test.dart test/fixture_lever_roundtrip_test.dart` → **+43 All tests passed!**

## Independent blocker re-verification (2026-05-15)

An independent-audit pass raised a merge blocker: *"the flip path returns
`null` — `computePrimaryLeverId` returns `null` instead of `cplh_up` when
only a per-period CPLH deviation exists; `:399` and `:501` are RED on the
committed code; the candidate/threshold gate still computes the CPLH
deviation against the whole-day `profile.targetCPLH`."*

**The blocker does not reproduce against the committed code (`8dd35f21`).**
Root-cause reconciliation:

- `shift_service_period_read_service.dart:421-430` resolves the per-period
  target triple via `profile.daypartFor(bucket.servicePeriodId)` with the
  per-axis `> 0` Gap-42 fallback.
- `:441` `cplhDelta = (bucket.cplh - targetCPLH) / targetCPLH` — the gate
  already divides by the **resolved per-period** `targetCPLH` (the local
  resolved at `:421-424`), **not** `profile.targetCPLH`. The blocker's
  hypothesis (gate uses the whole-day scalar → `anyCandidate` false →
  short-circuit `null`) is not present in the code on disk.
- `:476-488` the engine call consumes the same resolved
  `targetCPLH/targetSPLH/targetPPA`.
- `lib/domain/models/active_target_profile.dart` (daypart support:
  `ActiveTargetProfileDaypart`, `daypartFor`) is committed on this branch
  and byte-identical to `master` (`git diff master --stat` → empty;
  provenance Slice 1 `466d93f5` + Slice 5 `6226fdb3`), so
  `daypartFor('lunch')` returns the row and the +25% deviation mints
  `cplh_up`. The blocker likely diagnosed a stale / pre-`8dd35f21` state.

Independent re-run (clean tree, CI dark):

- `flutter test test/services/shift_service_period_primary_driver_test.dart`
  → **+18 All tests passed!** (includes `:399` and `:501`).
- `:399` in isolation (`--plain-name "per-period CPLH target differs"`)
  → **+1 All tests passed!** (rules out cross-test contamination).
- `:501` in isolation (`--plain-name "mixed degeneracy"`)
  → **+1 All tests passed!**
- `flutter test test/services/shift_service_period_read_service_test.dart`
  → **+18 All tests passed!**
- `dart analyze lib/services/shift_service_period_read_service.dart
  test/services/shift_service_period_primary_driver_test.dart`
  → **No issues found!**

No code change was required or made — the committed scorer already
implements the per-period gate correctly and the named tests pass for the
correct reason (`:399` asserts `cplh_up` where the whole-day-only control
returns `null`; `:501` asserts `cplh_up` with degenerate per-period SPLH
falling back to on-target whole-day).

## Verdict

Clean. Per-period targets scored with whole-day Gap-42 fallback (null +
degenerate), wages whole-day, all-missing case byte-identical to prior
behavior. No regressions in adjacent lever/LaborModel suites. The
independent merge blocker (flip path returns `null`) does **not**
reproduce against `8dd35f21`; `:399`/`:501` are green in isolation and in
the full suite.
