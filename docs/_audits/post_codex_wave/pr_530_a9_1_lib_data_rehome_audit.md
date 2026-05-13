# PR #530 Audit — A9.1 `lib/data` Rehome

**Slice:** A9.1 (Lane A — code health)
**Owner:** Codex executor
**Branch:** `codex/a9-1-lib-data-rehome`
**Base:** `master`
**Gate:** `operator` per ledger + explicit `[operator-approval-required]` prefix (frozen `lib/data` surface / demo-mode parity)
**Size:** 90 additions / 90 deletions / 72 files (net-zero LoC; 3 file renames + 69 import-path updates)
**Chunking:** light variant — 72 files is large by count but the LoC delta is tiny and the change is mechanical (renames + import path updates). No new code, no new behavior.
**Dependency:** A0 merged ✓

## Pattern B compliance

PR body contains **BOTH** required audit tables (Sub-Agent Self-Audit + Executor Audit). All 14 lenses populated with file:line citations on most rows. Worker also discloses an internal **send-back finding A9-F1** (executor caught stale active-contract links to moved `lib/data/` paths and self-corrected before opening PR) — positive honesty pattern.

## Verdict

**approve-pending-operator** — escalating to operator per Gate=operator + explicit title prefix. Audit is clean; the gate is the frozen-surface / demo-mode-parity policy, not a finding.

## Executor spot-checks

| Check | Outcome |
|---|---|
| **3 files moved out of `lib/data/`** (worker's claim) | ✓ — `git diff` confirms: `lib/data/app_defaults.dart` → `lib/domain/constants/app_defaults.dart` (similarity 99%), `lib/data/cross_axis_pair_catalog.dart` → `lib/domain/constants/cross_axis_pair_catalog.dart` (similarity 100%), `lib/data/mock_integration_replay_seed.dart` → `lib/dev/mock_integration_replay_seed.dart` (similarity 99%) |
| **`lib/data/` will be empty post-merge** (CLAUDE.md "delete-only legacy" doctrine fully honored) | ✓ — `git ls-tree -r origin/master --name-only -- lib/data/` currently returns exactly those 3 files; PR moves all 3 out. Post-merge `lib/data/` is empty (no `.gitkeep`, no leftovers per the diff). |
| **3 active contract docs updated with new paths** | ✓ — `docs/contracts/demo_mode_contract.md:385` (1 ref), `docs/contracts/phase_7_58_primary_driver_contract.md` (lines 63 + 265, 2 refs), `docs/contracts/phase_7_61_driver_key_contract.md` (5 refs across :51, :71, :133, :142, :215). All updates point to correct new paths |
| **Relative-import math is correct** for the rehome | ✓ — sample: `lib/dev/demo_fixture_data.dart` was `from data/` (sibling) → now `from domain/constants/` (sibling-then-deeper). The diff shows `../data/app_defaults.dart` → `../domain/constants/app_defaults.dart` which is correct from `lib/dev/`. Similarly `lib/infrastructure/persistence/sqlite/sqlite_database.dart` correctly bumps the `../../../data/` prefix to `../../../domain/constants/` and `../../../dev/` |
| **No `lib/data/` re-introductions** in the diff | ✓ — `gh pr diff --name-only` shows only `lib/{dev,domain/constants}/*.dart` net-new locations; no new files written into `lib/data/` |
| **No tracker / ledger / index modifications** | ✓ — diff scope: 3 contract docs, 3 file renames, 66 source/test import updates. Zero `PROJECT_TRACKER.md` / `WAVE_EXECUTION_LEDGER.md` / lane-index touches |
| **HP #2 demo-mode reader-parity preserved** — no new `kDemoMode` reader branches | ✓ — diff scope shows no changes to reader paths; the demo flag continues to live writer-side only (per Lens 6 self-audit row). The kDemoMode comment in `demo_mode_contract.md:385` is a doc-only path update |
| **Tests pass** — worker reports 198/198 across 8 targeted tests | ✓ — disclosed in PR body verification block: `flutter test test\mock_integration_replay_seed_test.dart test\provider_abstraction_test.dart test\replay_integrity_audit_test.dart test\runtime_fixture_retirement_test.dart test\fixture_lever_roundtrip_test.dart test\widgets\lever_card_test.dart test\services\history_cross_axis_pattern_test.dart test\variance_history_widget_test.dart → All tests passed!` |
| **`dart analyze` clean on all 69 touched Dart files** | ✓ — disclosed |
| **Active-doc sweep + code-import sweep clean** | ✓ — disclosed: `no lib/data/{app_defaults,cross_axis_pair_catalog,mock_integration_replay_seed}` hits in active docs; no `package:forge_and_flow/data/...` or `../data/...` imports for moved files |
| **A9.1 doctrine alignment** | ✓ — CLAUDE.md "Service-Layer Split" §52: *"`lib/data/` — frozen legacy. Delete-only."* + §54: *"`lib/dev/` — demo and dev-only."* The rehome routes `mock_integration_replay_seed` (writer-side demo seeder per HP #2) into `lib/dev/` and pure value catalogs (`app_defaults`, `cross_axis_pair_catalog`) into `lib/domain/constants/` — both per the doctrine |

## Honesty observations (POSITIVE)

1. **Internal send-back A9-F1 disclosed**: Worker caught stale active-contract links to moved `lib/data/` paths during their own audit pass, applied the fix, then re-ran all verification before opening the PR. This is exactly the "executor as mini-orchestrator with self-audit" pattern working as intended.

2. **Verification block is verifiable**: All sweep commands disclosed are reproducible by reviewer. The `dart analyze on all 69 touched files` + `targeted tests` + `active-doc sweep` + `code-import sweep` + `diff --check` ladder is the canonical pre-PR discipline.

3. **No `--no-verify` mentioned**: Worker pushed with the canonical hook installed (only `postgres_import_lint` ran per the disclosed pre-push hook line). Matches the canonical-hook pattern established earlier this wave.

## Operator-decision rationale (why this needs operator sign-off)

Per CLAUDE.md "Agent-Led Slices" durable rule:
> *"Auth-critical, RLS-touching, schema-touching, and proxy-touching slices require explicit operator approval before merge regardless of audit verdict."*

A9.1 doesn't fit any of those four critical categories directly, but the ledger explicitly marks it `Gate=operator` because:

1. **Frozen `lib/data/` surface** — CLAUDE.md §52 declares this surface delete-only. This PR is the final rehome that empties it. Operator should confirm the chosen new homes (`lib/domain/constants/` for pure value catalogs, `lib/dev/` for the writer-side demo seeder) match the architecture intent.

2. **Demo-mode parity sensitivity** — `MockIntegrationReplaySeed` is the canonical writer per HP #2 / `demo_mode_contract.md`. Moving it to `lib/dev/` reinforces its dev/demo-only classification, which is correct given Phase 8 vendor connectors are the eventual live-mode replacement. Operator confirms the rehome doesn't accidentally invite reader-side branching.

3. **72-file refactor blast radius** — even though the LoC delta is +90/-90 and behavior is preserved, a refactor this wide deserves operator-eyes regardless of audit verdict (per the ledger gate).

## Recommendation

**approve-for-merge.** The technical execution is excellent:
- Mechanical, behavior-preserving renames + import updates
- 198/198 targeted tests pass
- All 3 active contract docs updated to point to new paths
- Active-doc sweep and code-import sweep both clean
- Worker's internal A9-F1 send-back catch demonstrates self-audit discipline
- Doctrine alignment: `lib/data/` → fully empty (delete-only doctrine honored); pure value catalogs → `lib/domain/constants/`; demo seeder → `lib/dev/`

If approved, I will merge + update the ledger (A9.1 → merged).

## Authority anchors verified

- `docs/_execution/lane_a_code_health/03_execution_slices.md:312-332` (slice scope)
- `docs/_execution/lane_a_code_health/02_plumbing_audit_matrix.md:54` (Lens 4 finding that prompted the slice)
- `CLAUDE.md:52` (Service-Layer Split — `lib/data/` delete-only doctrine)
- `CLAUDE.md:137-139` (Demo Mode HP #2 — writer-side switch architecture)
- `docs/contracts/demo_mode_contract.md:363-370` (demo writer canonical reference)

## Findings

None blocking. Three positive observations (internal send-back catch, reproducible verification, no `--no-verify`).

## Status

Awaiting operator approval. Will merge + update ledger on go-ahead.
