# Audit — Demo data Slice A: multi-location + org hierarchy seed (foundation)

**Branch:** `claude/demo-slice-a-hierarchy`
**Base:** `master` @ `10cf59ca` (PR #786 merged)
**Authority:** this slice prompt → `docs/_audits/per_daypart_v1/full_demo_data_spec.md`
(§1.6, §1.7, §2c, "Slice A" in §5) → `CLAUDE.md` Demo Mode (HP #2) →
`docs/contracts/demo_mode_contract.md`.
**Contract:** branch → implement → self-audit → commit + push → open PR → STOP.

## Scope delivered

| # | Scope item | Status | Evidence |
|---|---|---|---|
| 1 | Seed 4 `restaurant_locations` rows; Downtown stays `demo_restaurant_001` | ✅ | `sqlite_database_seed.dart:649-690` `_seedDemoRestaurant` loops `DemoScope.locations`; `sqlite_database.dart:79-130` `DemoScope.locations` (Downtown first, `downtownRestaurantId == restaurantId == 'demo_restaurant_001'`) |
| 2 | `DemoScope` location constants / list | ✅ | `sqlite_database.dart:40-130` — `DemoLocation` class + `DemoScope.{downtown,northLoop,riverside,harbour}RestaurantId` + `DemoScope.locations` |
| 3 | Align operator-web org-unit fixture to §2c tree | ✅ | `demo_team_fixtures.dart:88-102` Harbour location + North Loop re-parented to `demo-org-metro`; `:118-129` `Metro District` org unit (district, parent `demo-org-east`) |
| 4 | `restaurant_scope_notifier.dart` read-only verification | ✅ (no edit) | Notifier unchanged; `availableScopes` already populates from every `restaurant_locations` row via `_seedAvailableScopesFromBootIfEmpty` (`restaurant_scope_notifier.dart:229-259`) → `SqliteRestaurantScopeRepository.listRestaurants()` → `RestaurantScopeDao.getAllRestaurants()` (`restaurant_scope_dao.dart:35-38`, unfiltered `SELECT *`). Test proves 4 scopes surface. No wiring gap → no edit needed (`git diff --name-only HEAD` lists only the 3 lib files). |
| 5 | "One watch item" investigation | ✅ | **Finding below.** |

### "One watch item" finding (§4 of the spec)

The mobile SQLite database has **no `org_units` table**. Verified:
`grep org_units` over `sqlite_database_schema.dart` + `sqlite_database_migrations.dart`
returns nothing; `restaurant_locations` (`sqlite_database_schema.dart:13-19`) is a
flat table (`restaurant_id`, `display_name`, `business_timezone`, timestamps) with
no parent/hierarchy column. **Conclusion (matches the spec's predicted branch):**
the multi-location requirement is satisfied by multiple `restaurant_locations`
rows + the `BusinessScope` list `RestaurantScopeNotifier` derives from them; the
org tree (corp → regions → district) lives in the operator-web fixture
`demo_team_fixtures.dart`. `DemoLocation.region`/`.district` are
documentation-only fields that make the cross-console alignment explicit. **No
`demo_*` table, no new `kDemoMode` reader branch.**

## §2c shape implemented

```
Barrio Hospitality Group        corp     operator-web fixture `demo-org-root` ("Demo Bistro" id/name kept — see deviation)
├── East Region                 region   `demo-org-east`
│   ├── Downtown                 location `demo-loc-downtown`  → mobile `demo_restaurant_001`     ("Barrio Legado")
│   └── Metro District           district `demo-org-metro` (NEW, parent demo-org-east)
│       └── North Loop           location `demo-loc-north-loop` → mobile `demo_restaurant_north_loop` ("Barrio Legado — North Loop")
└── West Region                 region   `demo-org-west`
    ├── Riverside                location `demo-loc-riverside` → mobile `demo_restaurant_riverside` ("Barrio Legado — Riverside")
    └── Harbour                  location `demo-loc-harbour` (NEW) → mobile `demo_restaurant_harbour` ("Barrio Legado — Harbour")
```

### Deliberate deviations from the §2c labels (authority: prompt #1 > spec #2)

1. **Downtown display name stays `'Barrio Legado'`** (not the spec's
   `'Barrio Legado — Downtown'`). The prompt's hard backward-compat constraint
   ("Downtown MUST stay `demo_restaurant_001`") plus
   `persistence_scope_alignment_test.dart:78-80,429` and
   `getOrCreateActiveRestaurant` (`sqlite_restaurant_scope_repository.dart:28-40`)
   assert that id → exactly `'Barrio Legado'`. Documented at
   `sqlite_database.dart:50-58`.
2. **Operator-web corp root keeps id `demo-org-root` / name "Demo Bistro" /
   path `demo_bistro`** rather than renaming to "Barrio Hospitality Group".
   ~15 existing 11W tests assert the current ids/names/paths (e.g.
   `hierarchy_screen_test.dart:340` `find.text('East Region (demo_bistro.east_region)')`,
   `operator_web_router_test.dart:288` `find.text('Downtown')`). The slice
   prompt's parenthetical alignment target is **structural** ("Corp → 2
   regions → 1 district → 4 locations"), which is met exactly. Renaming would
   be an out-of-scope refactor breaking unrelated merged tests; foundation
   slices "keep tight."

Both deviations preserve §2c's *structure and inheritance demonstrability*
(depth-3 path via Metro District; a no-district sibling, Harbour, for the
"inherited from Region" pill) while honouring the prompt's #1 backward-compat
order.

## Demo-contract compliance (HP #2)

| Requirement | Verdict | Evidence |
|---|---|---|
| Writes through existing tables only | ✅ | Only `restaurant_locations` rows added (`sqlite_database_seed.dart:662-685`). No schema change. |
| No `demo_*` table | ✅ | New locations are new `restaurant_id` values in the existing table. |
| No new `kDemoMode` reader branch | ✅ | No reader touched. Notifier unchanged. No `kDemoMode` token added (grep clean). |
| Determinism (reseed → same rows) | ✅ | `ConflictAlgorithm.ignore` + const `DemoScope.locations`; test "reseed is deterministic — same 4 rows" passes. |
| Backward compat | ✅ | Downtown = `demo_restaurant_001` / `'Barrio Legado'`; `per_daypart_v1_demo_seed_per_period_cycle_test` (Downtown cycle) still green. |

## Pattern B — 14-lens self-audit

| # | Lens | Verdict | Note (file:line) |
|---|---|---|---|
| 1 | Contract authority order honoured | ✅ | Deviations resolved by prompt #1 > spec #2; documented `sqlite_database.dart:50-58` + above. |
| 2 | Scope discipline (no broadening) | ✅ | Only the 4 listed files + 1 test. No operational data for new locations (Slice C). Timing config still Downtown-only (`sqlite_database_seed.dart:687-690`). |
| 3 | HP #2 demo-writer-side | ✅ | Same table, no `demo_*`, no reader branch (compliance table above). |
| 4 | HP #11 hierarchy-scoped | ✅ (foundation) | Tree now depth-3 (corp→region→district→location) so later HP #11 inherited/effective pills are demonstrable; actual override rows are Slice F. |
| 5 | Determinism / no RNG | ✅ | const list + `ignore`; reseed-idempotency test passes. |
| 6 | Schema / migration gate | ✅ N/A | No `db/migrations/*.sql`, no SQLite schema change → drift scanner / cutoff lint not triggered. |
| 7 | Backward compat | ✅ | `demo_restaurant_001`/`'Barrio Legado'` preserved; baseline tests unchanged. |
| 8 | Test proves the seam | ✅ | `per_daypart_v1_demo_slice_a_hierarchy_test.dart`: 4 rows, 4 `availableScopes`, Downtown still active, §2c org tree shape. 4/4 pass. |
| 9 | `dart analyze` clean | ✅ | `dart analyze` on all 5 touched files → "No issues found!". |
| 10 | No regression vs baseline | ✅ | `persistence_scope_alignment_test.dart` branch `+33 -8` == clean-HEAD baseline `+33 -8` (proven via a throwaway `git worktree` at HEAD). The 8 K/L failures pre-exist on master (old-schema migration paths lack `target_cycle_dayparts`, from merged PR #786's `TargetCycleDao.upsertCycle`) — **not PR-introduced**, not in `KNOWN_FAILING_TESTS.md`. |
| 11 | Reader symmetry | ✅ | Notifier read path identical demo/prod; demo just seeds more rows the same way prod would receive them. |
| 12 | Cross-console consistency | ✅ | Mobile `DemoScope.locations` (4) ↔ operator-web `kDemoTeamLocationsFixture` (4); names Downtown/North Loop/Riverside/Harbour; tree asserted in test. |
| 13 | Comment/doc hygiene | ✅ | Stale fixture header ("three locations, two org units") + class docs updated to "four locations, four org units"; deviation rationale inline. |
| 14 | Concurrency boundary | ✅ | Did not touch `mock_integration_replay_seed.dart` (Slice B), `shift_dashboard.dart`, Slice-1 models/migrations. Stayed in the 5 listed files. |

## Local verification (CI dark — disclosed)

- `flutter pub get` — Got dependencies (fresh worktree).
- `dart analyze` on the 5 touched files → **No issues found!**
- `flutter test test/per_daypart_v1_demo_slice_a_hierarchy_test.dart test/per_daypart_v1_demo_seed_per_period_cycle_test.dart` → **+7 All tests passed!** (4 Slice A new + 3 per-period; Downtown cycle unchanged).
- `flutter test test/persistence_scope_alignment_test.dart` → **`+33 -8`**, identical to clean-HEAD baseline **`+33 -8`** (groups K & L pre-existing). No PR-introduced regression.

## Verdict

**approve-for-merge** — scope met, HP #2/#11 honoured, deterministic, zero
PR-introduced regressions, deviations documented and resolved by authority
order. No auth/RLS/schema/proxy surface touched. Orchestrator audits the PR
diff and merges when clean.
