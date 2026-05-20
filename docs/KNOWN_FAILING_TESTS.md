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
