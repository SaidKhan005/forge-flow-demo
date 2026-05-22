# Known Failing Tests

Quarantine list for tests known to be red on `master` that are out of scope
for the current slice.

Read this before claiming a regression: a failure here is pre-existing and
does not block the current slice unless the slice explicitly names it.

Codex maintains this file. Add an entry when verification confirms a failure
is pre-existing on clean HEAD. Remove an entry once the failure is fixed.
Removed entries live in git history; do not keep a "resolved" section here.

## Open

| File | Notes | Discovered | Owning slice |
|------|-------|------------|--------------|
| operator-web router test — `management picker drives location-scoped vendor route` | Flaky `pumpAndSettle` timeout on the operator-web vendor-connections route: the test pumps the management picker → vendor-connections route and `tester.pumpAndSettle()` exceeds its deadline (a never-settling animation/timer on that route in the test harness, not a behavior regression). Reproduces on pristine master with no slice changes applied; unrelated to the cross-surface-parity / G-series slices. Re-flagged repeatedly by agents as a suspected regression — quarantined here so it stops being re-reported. | 2026-05-16 | follow-up — pump with a bounded `pump(Duration)` loop instead of unbounded `pumpAndSettle`, or stub the never-settling timer on the vendor-connections route under test |
| `test/operator_web/screens/business_setup_screen_test.dart` — `renders inherited timing demo data for owners` + `schedule timing uses the router callback when available` (2 cases) | **Stale tests, not a bug.** The operator-web business-timing UX was reworked: the nav title is now `'Business timing'` (was `'Business timing setup'`), the edit button reads `'Edit service periods'` (was `'Edit timing'`), and the in-screen schedule button + key `operator_web_business_timing_schedule_button` were removed (scheduling moved to the router; `onScheduleTiming` is now a dead param on `business_setup_screen.dart`). The test still asserts the old layout, so the two cases hard-error on `find.text`/`find.byKey`. Verified pre-existing on clean master; the live screen keeps coverage via the file's 3rd case + sibling tests. | 2026-05-22 | operator-web test-realign batch at surface-freeze (Codex lane): realign case 1 to current copy, delete the removed-schedule case, drop the dead `onScheduleTiming` param. |
| `test/operator_web/widgets/wage_source_toggle_test.dart` — `vendor wage option is disabled with no labor vendor` + `wage class label updates with connected labor vendor` (2 cases) | **Stale tests, not a bug.** Collateral of the active operator-web Data Accuracy rework (commits `dc319077` "Harden Data Accuracy source defaults", `b52123f2` "Ground Data Accuracy explanations", etc.): the wage-source toggle widget's disabled-state / label behavior changed and these two cases were not realigned. Broke mid-session 2026-05-22 (was green in an earlier same-day run), which is why it is treated as part of the operator-web churn, not a standalone regression. Diagnosis confirmed the failures are on clean master. | 2026-05-22 | operator-web test-realign batch at surface-freeze (Codex lane): realign to the current `WageSourceToggle` disabled/label behavior. |
