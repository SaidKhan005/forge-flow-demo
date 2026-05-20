# Alias, Benchmark, and Learn Cleanup Plan - 2026-05-20

## Plain-English Scope

- Retire active old covers-source write aliases.
- Keep `lunch`, `dinner`, and `late_night` as valid configured service-period keys.
- Make benchmark override internals read-only so no hidden code path can write old whole-day benchmark overrides.
- Add service-period context to the visible Learn story card body/action copy.

## What This Fixes

- Old payload fields like `covers_source_lunch`, `covers_source_dinner`, and
  `covers_source_late_night` should no longer be accepted as active write
  input. New writes use `covers_source_per_service_period`.
- The old `benchmark_overrides` table can remain for read-only compatibility,
  but code should not expose repository methods that insert, patch, or clear
  whole-day override rows.
- Learn already detects the leaking period. The visible story card should now
  carry that period label in the text the operator reads, not only in the small
  caption.

## Non-Goals

- Do not remove valid configured service-period keys named `lunch`, `dinner`,
  or `late_night`.
- Do not drop database tables or columns in this pass.
- Do not change mobile Baseline Manager selected-star writes.
- Do not rewrite the shared `LeverCards` catalog globally.

## Execution Plan

- Update proxy/admin data-accuracy write paths so legacy scalar covers-source
  keys fail closed or disappear from active app writers.
- Update admin fake/live gateway and tests so keyed service-period maps are the
  only covers-source write shape.
- Remove unused benchmark override repository write methods while keeping
  read-only list/resolve behavior for any historical rows.
- Update benchmark docs/tests so the table is described as historical read-only
  compatibility, not an active write surface.
- Update Learn story composition so recurring leaks and repeatable wins prefix
  card body/action text with the period label when known.
- Run focused tests for admin data accuracy, benchmark override routing and
  repository behavior, Learn depth/copy, and the UX em-dash lint.

## Safety Checks

- Active UI writes should continue to support custom service periods.
- Old benchmark HTTP write routes should still return HTTP 410.
- Existing benchmark read/status routes should still work.
- Learn copy should stay readable and should not add extra cards or chrome.

## Execution Results

- Admin, mobile, and proxy data-accuracy writes now reject old
  `covers_source_lunch`, `covers_source_dinner`, and
  `covers_source_late_night` write keys with HTTP 410.
- Normal app writes now use `covers_source_per_service_period`, so custom
  periods such as `breakfast` and `happy_hour` remain first-class.
- `benchmark_overrides` is now read-only in the Dart repository; legacy HTTP
  write routes still fail closed, and the table is kept only as historical
  compatibility.
- Learn story cards now prefix their body/action copy with the detected period,
  such as `Tue Lunch:` or `Sat brunch:`, without changing the shared card
  catalog.
- Verification passed: focused analyzer, focused Flutter tests, UX em-dash
  lint, and `git diff --check`.
