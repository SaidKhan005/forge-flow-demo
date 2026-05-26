# Audit — PR #1312: P3 redesign Support logs screen

Date: 2026-05-24
PR: #1312 · branch `claude/support-logs-p3-screen-redesign` · base `master` · MERGEABLE/CLEAN
Slice: P3 (Support logs redesign §3/§12 — the visible screen redesign)
Category: FRONT-END (not gated by category); orchestrator audit + (front-end) merge.
Changed: 4 files, +1174/**-1406** (net leaner) — `debug_console_admin_screen.dart`,
`admin_human_labels.dart`, the screen test, `tool/ux_em_dash_lint.dart`.

## Verdict: CLEAN — ready to merge (front-end). Two follow-ups queued (below).

## Conflict / base
7 commits behind master, but those commits touched NONE of P3's 4 files → `MERGEABLE/CLEAN`,
no rebase needed.

## Structure verified (matches the mockup "After")
Grep on the new screen confirms: a plain **"What happened"** zone (What/Result/When/Who/Took)
+ a collapsible **"Technical reference (for engineering)"** zone; the `_formatMap` `{ }` dump
is GONE; **"Not recorded"** honesty sentinels ("never a fabricated value or phantom 0"); a
small **`_LiveChip`** replacing the full-width live bar; a Result filter (Any / Worked / Not
recorded); `adminRequestResultWording` display helper. Type dropdown folds the 3 tabs + the
request-type-key box (per the agent report + the test conversion).

## Independently re-run
| Check | Result |
|---|---|
| `dart analyze` (screen + labels) | No issues |
| `dart run tool/ux_em_dash_lint.dart` | clean (216 files / 14 roots; `admin_human_labels.dart` now in scope) |
| `flutter test debug_console_admin_screen_test.dart` | **21/21 pass** (incl. 800x600 no-overflow guard) |
| GitHub mergeable | MERGEABLE / CLEAN |
| agent-reported cross-suites | gateway/pricing/observability 70/70, proxy-routes 7/7, debug shell green |

## Scope held
Left scope tree / `AdminSetupWorkspace`, proxy, migrations, write path, data contract all
untouched. The 4 existing `adminRequestUseCases` labels + `requestLogStatusLabel` byte-unchanged
(observability/pricing safe). Added 9 support-class labels + a display result helper.

## Queued follow-ups (operator-visible)
- **P3.2 — actor name/role:** the row's "Who" currently shows a short user reference (the actor
  uuid), not "Name (Role)". Full resolution via the scoped members lookup was deferred (async
  per-operator lookup is more than a modest add). Mockup showed "Marco Lee (Manager)"; until
  P3.2, "Who" is an id or "—".
- **P1b.2 — failure/timeout telemetry** (from P1b): failed requests show "Not recorded" until wired.

## Pre-existing failure (not P3)
One `admin_shell` test (`per-business cluster navigates…`, a members-screen overflow) fails;
agent confirmed it red on the clean base SHA `1e7323cf` with no P3 changes. Not caused by P3;
out of scope (members screen, not support logs).

On merge: `tool/verify_pr_landed.sh 1312 'What happened'` (or a screen symbol). Then P4
(demo + admin-console browser QA) to show it live.
