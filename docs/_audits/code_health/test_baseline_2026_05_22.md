# Test Baseline — 2026-05-22 (Refactor Phase A, slice A1)

Pre-refactor test-suite baseline captured so any later red is attributable to
the refactor, not to drift that was already present. Companion guardrails:
`tool/skip_quarantine_lint.dart` (A5) and `tool/flake_counter.dart` (A1).

- **Branch / base:** `claude/guardrail-test-integrity` off `origin/master`
  (`7ccfb588` at fetch time). The branch adds only the two `tool/*.dart`
  guardrails plus this doc; it does not touch `lib/**`, `test/**`, or
  migrations, so every count below reflects pristine `origin/master`.
- **Toolchain:** Flutter 3.35.7 (stable, revision adc9010625), Windows 11.
- **Command:** `flutter test --reporter json` (one run), parsed line-by-line
  from the JSON-lines stream.

## Full-suite counts (observed)

| Outcome | Count |
|---------|-------|
| Pass | 10449 |
| Fail | 0 |
| Error | 2 |
| Skipped | 8 |
| **Total (non-hidden)** | **10459** |

Notes on the numbers:

- The reporter also emitted 1031 *hidden* `testDone` events (the synthetic
  "loading ..." suite-load entries package:test injects). They are excluded
  from the table above; only real, non-hidden, non-skipped outcomes are
  counted.
- The reporter's run-level `done.success` flag was **`false`** — consistent
  with the 2 errors below.
- The 8 skips are exactly the suite's self-documenting skips (all classified
  `selfDocumenting` by `tool/skip_quarantine_lint.dart`; that lint exits 0 on
  this commit). The skip count here counts skipped *test cases*; the lint
  counts skip *sites* (12, because three sites resolve through the shared
  `postgresSkipReasonOrNull()` helper). No skip required a
  `docs/KNOWN_FAILING_TESTS.md` row.

## Errors observed (NOT clean — finding for the orchestrator)

The baseline is **not** green: 2 tests error on pristine `origin/master`, and
**neither is in `docs/KNOWN_FAILING_TESTS.md`** (which currently quarantines
only the operator-web *router* vendor-route `pumpAndSettle` flake — a
different test in a different file). Both errors are in the same file:

`test/operator_web/screens/business_setup_screen_test.dart`

| Test | Line | Failure |
|------|------|---------|
| `renders inherited timing demo data for owners` | 45 | `expect(find.text('Business timing setup'), findsOneWidget)` → found 0 widgets. |
| `schedule timing uses the router callback when available` | 142 | `tap()` on key `operator_web_business_timing_schedule_button` → finder matched 0 widgets. |

Diagnosis (for triage, not fixed here — out of slice scope):

- The test file is byte-identical to `origin/master` (`git diff origin/master`
  on it is empty), so these are pre-existing failures, not introduced by this
  branch.
- The widget key `operator_web_business_timing_schedule_button` and the text
  `'Business timing setup'` no longer live where the test pumps them: a repo
  search finds the key only in test files (none in `lib/`), and finds
  `'Business timing setup'` now in `lib/operator_web/router/operator_web_router.dart`,
  not in the business-setup screen the test renders.
- Most recent commit touching the test file:
  `e6906054 Align Operator Web business timing UX (#1145)` — the business-timing
  UX moved/changed but `business_setup_screen_test.dart` still asserts the old
  on-screen layout. This looks like a test that was not updated alongside the
  UX move, surfacing as 2 hard errors.

Recommended orchestrator action: triage `#1145`'s test alignment (update the
two assertions to the new business-timing UX surface) OR quarantine these two
tests in `docs/KNOWN_FAILING_TESTS.md` with an owning slice. Per slice
contract, this agent did **not** edit `docs/KNOWN_FAILING_TESTS.md` or the
failing test.

## Known-flaky quarantine status

`docs/KNOWN_FAILING_TESTS.md` lists exactly one open row: the operator-web
router test `management picker drives location-scoped vendor route` (a
`pumpAndSettle` timeout flake on the vendor-connections route). That test did
**not** error in this full-suite run — consistent with it being an
intermittent flake rather than a hard failure. It is unrelated to the two
`business_setup_screen_test.dart` errors above.

## Flake counter — `test/operator_web/screens` at N=3

`dart run tool/flake_counter.dart test/operator_web/screens 3`

| Metric | Value |
|--------|-------|
| Runs (seeds) | 3 |
| Distinct tests observed | 354 |
| Consistent across all 3 runs | 354 |
| Inconsistent (flaky) | 0 |
| Presence gaps (ran in some seeds only) | 0 |
| Per-run reporter verdict | RED (each run) |
| Flake-counter verdict / exit | **STABLE, exit 0** |

Reading this table: each of the 3 runs is RED because this directory contains
the 2 `business_setup_screen_test.dart` errors documented above — but those 2
tests fail *the same way every run*, so they are consistent, not flaky. The
flake counter measures run-to-run *consistency*, and on that axis
`test/operator_web/screens` is stable (exit 0). A hard, reproducible failure is
a separate signal from a flake; the full-suite section above is where the hard
failures are recorded.

## Guardrail self-verification (this slice)

- `dart analyze tool/skip_quarantine_lint.dart tool/flake_counter.dart` → clean
  ("No issues found!").
- `dart run tool/skip_quarantine_lint.dart` → exit 0 (12 skip sites, all
  self-documenting or quarantined). Planted a temporary `skip: true` and a
  `skip: 'TODO'` fixture → exit 1 (both flagged), then removed.
- `tool/flake_counter.dart` self-check confirmed it flags an inconsistent test
  and a presence-gap test, and that non-JSON reporter lines are skipped
  defensively.
