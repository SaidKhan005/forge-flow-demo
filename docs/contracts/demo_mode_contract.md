# Demo Mode Contract

**Status:** Locked. Audited end-to-end 2026-05-07.
**Authority:** CLAUDE.md → Hard Promise #2 ("Demo mode persists post-launch — `kDemoMode` is a writer-side switch; same tables, same reads, same UI either way").
**Scope:** Mobile (Forge & Flow + Barrio flavors), Admin Console, Operator Web Console.

This contract codifies the writer-side-switch architecture, lists the
four intentional reader-side carve-outs, and defines the rules for
adding new demo-aware code.

---

## Why writer-side?

If demo and prod fork at READ time, every screen becomes two screens to
maintain — and the reader-side branch becomes the place where data
shape, formulas, and UX silently drift. A single accidental
`if (kDemoMode) ...` in a widget can hide a regression in production
behind a passing demo walkthrough.

Writer-side keeps the contract tight: demo is a different SOURCE of
data into the SAME tables, read by the SAME repositories, rendered by
the SAME widgets. The only things that may differ are seed values and
labels.

---

## Architecture (mobile)

```
                    ┌────────────────────────────────────────┐
                    │  Build-time switch                     │
                    │  --dart-define=kDemoMode=true|false    │
                    └────────────┬───────────────────────────┘
                                 │
            ┌────────────────────┼─────────────────────────┐
            │                    │                         │
            ▼                    ▼                         ▼
   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐
   │ Carve-out #1     │  │ Carve-out #2     │  │ Writer selection     │
   │ login_screen     │  │ app_data_status  │  │ (no kDemoMode read   │
   │ → adds "Use      │  │ → label = DEMO   │  │  in screens/widgets) │
   │  demo operator"  │  │   (vs CURRENT).  │  │                      │
   │  button.         │  │  Same data shape,│  │                      │
   │ Same auth path.  │  │  same freshness  │  │                      │
   │                  │  │  math.           │  │                      │
   └──────────────────┘  └──────────────────┘  └──────────┬───────────┘
                                                          │
                                                          ▼
                                       ┌──────────────────────────────┐
                                       │ DataSourceProvider<T>        │
                                       │ (lib/domain/services/...)    │
                                       └──────────┬───────────────────┘
                                                  │
                              ┌───────────────────┼─────────────────────┐
                              │ kDemoMode=true    │  kDemoMode=false    │
                              ▼                   ▼                     ▼
                    ┌──────────────────┐  ┌────────────────────────┐  ┌──────────────────────┐
                    │ MockReplay       │  │ Phase 8 vendor sinks   │  │ HttpSyncProxyClient  │
                    │ DataSource       │  │ (toast_pos, 7shifts,   │  │ (server-truth pull)  │
                    │ Provider         │  │  square, clover, …)    │  │                      │
                    │                  │  │                        │  │                      │
                    │ Writes via       │  │ Write via              │  │ Writes via           │
                    │ _seedDemoData    │  │ *_postgres_sink.dart   │  │ standard repository  │
                    │ FromReplay       │  │ (Postgres) +           │  │ APIs                 │
                    │ → SQLite seed.   │  │ mirror to mobile       │  │                      │
                    └────────┬─────────┘  │ SQLite via the sync    │  └──────────┬───────────┘
                             │            │ runtime.               │             │
                             │            └───────────┬────────────┘             │
                             │                        │                          │
                             └────────────────────────┴──────────────────────────┘
                                                  │
                                                  ▼
                          ┌──────────────────────────────────────────────────┐
                          │ STANDARD SQLite TABLES (no demo_* tables exist)  │
                          │  • restaurant_locations                          │
                          │  • shift_records, week_records                   │
                          │  • open_shift_snapshots                          │
                          │  • target_cycles, target_profile_versions        │
                          │  • active_target_profiles                        │
                          │  • import_runs, raw_import_records               │
                          │  • baseline_selected_records                     │
                          │  • restaurant_timing_configs                     │
                          │ Demo rows: restaurant_id = 'demo_restaurant_001' │
                          └──────────────────────┬───────────────────────────┘
                                                 │
                                                 ▼
                          ┌──────────────────────────────────────────────────┐
                          │ Repositories / services / widgets                │
                          │ Read by restaurant_id; NO kDemoMode branch.      │
                          │  • SqliteShiftRecordRepository                   │
                          │  • SqliteWeekRecordRepository                    │
                          │  • SqliteOpenShiftSnapshotRepository             │
                          │  • TargetCycleService, ShiftService, etc.        │
                          └──────────────────────────────────────────────────┘
```

### Mobile demo path with every demo-vs-prod fork marked

Every `[FORK]` marker is a place the code reads the `kDemoMode` flag.
There are exactly six reader-side reads in the mobile app
(two in `lib/screens/auth/login_screen.dart` behind the same const →
carve-out #1; one in `lib/services/app_data_status_service.dart` →
carve-out #2; one const + two conditional renders in
`lib/screens/settings_screen.dart` behind the same const → carve-out
#3). Everything else is the SAME code as production.

```
[App start: --dart-define=kDemoMode=true]
        │
        ▼
┌────────────────────────────────────────────────────────────────┐
│ Bootstrap (lib/main_forgeflow.dart / lib/main_barrio.dart)     │
│   • SqliteDatabase.instance.database  ← creates the SAME       │
│     schema as production. No demo branch in the schema.        │
│   • If first launch: _seedDemoDataFromReplay writes the demo   │
│     fixture into the SAME tables prod would receive vendor     │
│     data into.                                                 │
│   • [WRITER FORK] choice of DataSourceProvider impl            │
│       demo  → MockReplayDataSourceProvider                     │
│       prod  → vendor-specific *_pos_postgres_sink              │
│     (Both implement DataSourceProvider<T>; the only            │
│      difference is the data SOURCE.)                           │
└──────────────────┬─────────────────────────────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────────────────────────────┐
│ Login screen (lib/screens/auth/login_screen.dart)              │
│   • [READER FORK #1 — CARVE-OUT] _demoOperatorSignInEnabled    │
│       demo  → renders extra "Use demo operator" button         │
│       prod  → button hidden                                    │
│     ❶ The button only pre-fills credentials and calls          │
│       AuthSessionNotifier.signInWithEmailPassword — same       │
│       code path as the regular form. NO parallel auth.         │
└──────────────────┬─────────────────────────────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────────────────────────────┐
│ AuthSessionNotifier.signInWithEmailPassword                    │
│   No demo branch. Same gateway impl, same JWT, same audit.     │
└──────────────────┬─────────────────────────────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────────────────────────────┐
│ App shell + screens (no demo branch anywhere)                  │
│   • Repositories scoped by restaurant_id read demo rows the    │
│     same way they read live rows.                              │
│   • Widgets render whatever the repos return.                  │
│   • Service-layer formulas (LaborModel, TargetCycleService,    │
│     ShiftService, etc.) — NO kDemoMode branch.                 │
└──────────────────┬─────────────────────────────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────────────────────────────┐
│ App data status badge (lib/services/app_data_status_service)   │
│   • [READER FORK #2 — CARVE-OUT] _demoMode && hasOpenState     │
│       demo  → AppDataStatus.demo()      label = "DEMO"         │
│       prod  → AppDataStatus.current()   label = "CURRENT"      │
│     ❷ Label-only branch. The freshness math, the table reads,  │
│       and every other status code (noData, stale, …) are       │
│       identical in demo and prod.                              │
└──────────────────┬─────────────────────────────────────────────┘
                   │
                   ▼
┌────────────────────────────────────────────────────────────────┐
│ Closing a shift (write path)                                   │
│   • ShiftService.closeShift(...)                               │
│   • TargetSnapshotBuilder.fromActiveTargetProfile(...)         │
│   • ShiftFactBuilder.fromClosedShiftInput(...)                 │
│   • SqliteShiftRecordRepository.upsertClosedShift(...)         │
│       writes to shift_records — SAME table prod uses.          │
│   No kDemoMode branch on this path. The `restaurant_id` is     │
│   the only thing distinguishing the demo row.                  │
└────────────────────────────────────────────────────────────────┘

LEGEND
  [WRITER FORK] = legitimate writer-side switch (HP #2 endorses)
  [READER FORK — CARVE-OUT] = compile-time read of kDemoMode in
                              non-writer code. Strictly limited to
                              the two carve-outs above.
```

### Demo session entry

The mobile demo flow does NOT add a parallel auth path. The login
screen carve-out (#1 below) is a one-tap convenience that pre-fills
the credential fields and submits via the same
`AuthSessionNotifier.signInWithEmailPassword` call the regular form
uses.

In flavors that use the `requireAuth: false` shell variant (Barrio
demo embedding F&F), the same shell runs without an
`AuthSessionUnauthenticated` precondition, but the data path is still
SQLite-via-the-same-repositories. There is no demo-only widget that
would behave differently from a production widget.

### Demo writes (closing a shift in demo)

When a manager closes a shift in demo:
1. `ShiftService` builds a `ClosedShiftInput` with
   `restaurantId = 'demo_restaurant_001'`.
2. `TargetSnapshotBuilder` reads the active profile via
   `SqliteRestaurantScopeRepository.getActiveRestaurantId()`.
3. `ShiftFactBuilder` produces a `ShiftRecord`.
4. `SqliteShiftRecordRepository.upsertClosedShift(...)` writes to the
   same `shift_records` table production uses.

There is no `if (kDemoMode) ...` along this path. The only
demo-specific aspect is the `restaurant_id` value, which is just a
fixture id.

---

## Architecture (web flavors)

The Operator Web Console (`lib/main_operator_web.dart`) and Admin
Console (`lib/main_admin.dart`) follow the same pattern at the gateway
boundary:

- `--dart-define=OPERATOR_WEB_DEMO_AUTH=true` /
  `--dart-define=ADMIN_DEMO_AUTH=true` selects the demo
  `AuthSource` and falls back to in-memory `Demo*Gateway` impls.
- Live wiring (Firebase + HTTP gateways) is the production path. Demo
  wiring is a SOURCE swap, not a reader-side branch.
- `tool/release_build_demo_flag_lint.dart` enforces that release
  builds NEVER ship `ADMIN_DEMO_AUTH=true` /
  `OPERATOR_WEB_DEMO_AUTH=true`. Both `main_*.dart` files also
  `assert(!kDebugMode || !demoFlag)` at startup as belt-and-suspenders.

---

## Intentional reader-side carve-outs

Four reader-side carve-outs exist in the operator-app (mobile)
codebase. Carve-outs #1-#3 are compile-time `kDemoMode` branches and
are documented inline with `// kDemoMode carve-out:` comments.
Carve-out #4 is a runtime `demo_mode_state` UI fold with no
`kDemoMode` branch.

### Carve-out #1: Login screen "Use demo operator" button

- **Location:** `lib/screens/auth/login_screen.dart:17-19`
  (`_demoOperatorSignInEnabled` const).
- **What it does:** Renders an additional `OutlinedButton` below the
  regular "Sign in" button when the binary was built with
  `--dart-define=kDemoMode=true` or
  `--dart-define=FORGE_FLOW_DEMO_MODE=true`. Tapping it pre-fills
  `demo.operator@forgeflow.test` / `forge-flow-demo` and calls
  `_submit()`.
- **Why exempt:** The button is strictly additive. Production builds
  hide it via the `showDemoOperatorSignIn` constructor default. The
  sign-in path the button drives is identical to the regular form
  (same `AuthSessionNotifier.signInWithEmailPassword` call). Removing
  the button breaks the walkthrough flow without delivering any
  reader-side simplification — the data path that follows the
  successful sign-in is already production code.
- **What would replace it:** Nothing planned. The button stays.

### Carve-out #2: App data status badge label

- **Location:** `lib/services/app_data_status_service.dart:33` (the
  `_demoMode` const) and `:153` (the `if (_demoMode && hasOpenState)`
  branch). Line numbers reflect the inline carve-out comment block
  added 2026-05-07; the const moved when the comment was inserted.
- **What it does:** Returns `AppDataStatus.demo()` (label `DEMO`)
  instead of `AppDataStatus.current()` (label `CURRENT`) when the
  binary was built with `--dart-define=kDemoMode=true` AND the
  evaluator finds an open shift snapshot. All other status branches
  (`noData`, `firstSyncPending`, `backfillPending`,
  `backfillFailed`, `historicalOnly`, `failedImport`, `stale`) are
  returned identically in demo and prod.
- **Why exempt:** Label-only branch. The data shape, the freshness
  math, and every other status code path are unchanged. The badge
  exists so an operator (or a screenshot taker) can see at a glance
  that they are looking at fixture data rather than live data.
- **Relationship to runtime demo state:** The deeper "is this
  (operator, location, category) currently in demo mode" answer lives
  in `lib/services/integration/demo_mode_state.dart` (the Postgres
  `demo_mode_state.is_demo` column, flipped by `DemoModeFlipPolicy`
  after the first vendor backfill). Widgets that need to render a
  "demo mode active" banner per (operator, location, category) should
  read THAT surface, not this compile-time flag. The compile-time
  flag is purely a build-mode signal for the badge label.
- **What would replace it:** A future slice could route the badge
  label through `DemoModeStateGateway.readOrCreateDefault(...)`
  instead of the compile-time flag, in which case the carve-out would
  collapse. No such slice is currently scheduled.

### Carve-out #3: Settings screen demo-only management sections

- **Location:** `lib/screens/settings_screen.dart:31` (the `_kDemoMode`
  const), `:374` (gates the "Data reset" section), `:383` (gates the
  "Demo date" section). One const + two conditional renders, all
  behind the same flag, so this counts as one carve-out.
- **What it does:** When the binary was built with
  `--dart-define=kDemoMode=true`, the Settings tab renders two
  additional sections below "Latest updates":
  1. **Data reset** — `SettingsDataManagementSection` — operator
     affordance to clear local demo / operational data. No production
     analogue (production data clears come through the proxy + audit
     trail, not a local button).
  2. **Demo date** — `SettingsMockReplaySection` — advances the demo
     restaurant through sample business days so a walkthrough can
     show shift close → variance → history → next-day flow without
     waiting on real time.
  Production builds hide both sections. Every other Settings section
  (Account, MFA, Active Sessions, Data freshness, Wage authority,
  Team, Permissions, FF Support) renders identically in demo and
  prod.
- **Why exempt:** Both sections are demo-only operator affordances
  that have no production meaning. A "Demo date" picker in prod
  would let a real operator move the restaurant clock backward —
  which would corrupt closed truth. A "Data reset" button in prod
  would bypass the audit-anchored data-deletion path. Hiding them
  is the lower-risk choice compared to rendering disabled UI or
  inventing a "production data reset" alternative the operator does
  not need.
- **Relationship to runtime demo state:** Same as carve-out #2 — the
  per-(operator, location, category) runtime answer lives in the
  Postgres `demo_mode_state.is_demo` column. The compile-time flag
  here is purely a build-mode signal; widgets that need to render a
  per-(O, L, C) "in demo" banner should read the runtime state.
- **What would replace it:** A future slice could surface "Demo
  date" / "Data reset" only when `DemoModeStateGateway` reports
  `is_demo = true` for the active scope, but the build flag adds a
  belt-and-braces guarantee that release builds never ship the
  affordances. No replacement slice is currently scheduled.

### Carve-out #4: Settings screen master Demo -> Live switch

- **Location:** `lib/screens/settings/settings_demo_live_switch.dart`
  and `lib/screens/settings_screen.dart` (the Settings -> Data tab
  "Integrations" fold).
- **What it does:** Renders an operator-facing switch whose value is
  computed from `DemoModeStateNotifier.snapshot.hasDemoCategories`.
  Turning it off calls
  `POST /v1/operators/{operator_id}/locations/{location_id}/demo-mode-master-switch`,
  which flips every existing `demo_mode_state.is_demo = true` row for
  that location to `false` through the proxy and tenant-scoped
  Postgres repository. Turning it on is refused by the client, and the
  proxy rejects any Live -> Demo request with HTTP 409 and the
  operator-facing detail "live data has arrived".
- **Why exempt:** This is the documented operator gate for Decision
  #6. It is intentionally reader-visible because the operator needs a
  clear, audited one-way handoff from fixture/demo facts to live vendor
  facts. It does not read `kDemoMode`, does not create a `demo_*`
  table, does not fork reader repositories, and does not alter the
  existing auto-flip-on-first-backfill behavior.
- **Relationship to runtime demo state:** The switch is a UI fold over
  the same Postgres `demo_mode_state` rows that drive
  `DemoModeBanner`. The source of truth remains
  `(operator_id, location_id, category).is_demo`.
- **Operator gate:** Merge and production use require explicit
  operator approval. Runtime mutation is limited to operator owner /
  operator admin roles, requires an `Idempotency-Key` reserved and
  completed in `public.proxy_requests`, and is append-audited as
  `demo_mode.master_switch_to_live`.
- **What would replace it:** Nothing planned for V1. Future work may
  move the same one-way action to Operator Web, but it must keep the
  same proxy/repository path and Live -> Demo refusal.

---

## Proxy / server-side auth carve-outs (NOT mobile reader paths)

Two additional `bool.fromEnvironment('kDemoMode')` reads exist in
proxy/server-side auth code. They are NOT wired into either mobile
entrypoint (`lib/main_forgeflow.dart` / `lib/main_barrio.dart`) and
therefore do not influence the mobile demo→prod alignment. They are
listed here so future audits don't re-flag them as drift.

- `lib/services/auth/pepper_resolver.dart:64`
  (`EnvPepperResolver._demoMode`). When the
  `PASSWORD_HISTORY_PEPPER` env is empty AND `kDemoMode=true`, the
  resolver returns the empty pepper instead of throwing. Demo builds
  intentionally run without a real pepper because the demo SQLite db
  carries fixture password hashes; production proxy startup hard-fails
  if the pepper is missing.
- `lib/services/auth/repository_password_history_check.dart:131`
  (`_envDemoMode`). Same idea: in demo mode, the pepper-missing
  startup error is suppressed. In production the error is thrown so
  the proxy refuses to write un-peppered rows.

Both reads are server-side hardening: demo mode loosens a startup
precondition that exists only because production peppering is not yet
provisioned. Replacing them is part of the proxy hardening backlog,
not the mobile alignment backlog. They are documented here, not as
mobile carve-outs.

---

## Forbidden patterns

The following are violations of HP #2. Code review and (where
listed) CI lints reject them.

1. **No `demo_*` SQLite or Postgres tables.** Use existing tables
   with `restaurant_id = 'demo_restaurant_001'` (mobile) or the
   per-(operator, location, category) `demo_mode_state` row (Postgres).
2. **No `if (kDemoMode) ...` in screens, widgets, or services.**
   Reader paths must be branch-free with respect to demo/prod. New
   carve-outs require an explicit operator decision and an addition to
   this contract.
3. **No parallel demo-only repository or DAO.** Demo data must round-
   trip through the same repository APIs production uses.
4. **No release builds with demo auth.** `ADMIN_DEMO_AUTH=true` and
   `OPERATOR_WEB_DEMO_AUTH=true` are forbidden in release artifacts;
   see `tool/release_build_demo_flag_lint.dart` and the startup
   `assert()` in `lib/main_admin.dart` / `lib/main_operator_web.dart`.

---

## Acceptable patterns

These are NOT violations even though they reference `kDemoMode`:

- **Doc comments** referencing `kDemoMode` to explain wiring
  (e.g. `lib/dev/demo_fixture_data.dart` header comment, the
  `// kDemoMode only` comment in `lib/domain/constants/app_defaults.dart`).
- **Demo-only writers** under `lib/dev/`, `lib/services/mock_replay_data_source_provider.dart`,
  and the SQLite seed helpers — these are the writer side of the
  switch.
- **Demo gateway impls** under `lib/admin/services/demo_*` and
  `lib/operator_web/services/demo_*` — these are the in-memory
  fixtures the web flavors fall back to when no live HTTP gateway is
  wired.
- **Postgres `demo_mode_state` table + `DemoModeFlipPolicy`** — this
  is the runtime per-(operator, location, category) demo flag the
  Phase 8 vendor sinks flip on first-backfill commit. It is itself a
  shared Postgres table, not a `demo_*` parallel table.

---

## Test coverage

- `test/persistence_scope_alignment_test.dart` (groups B, C, E, G)
  asserts seeded demo rows live in the standard `restaurant_locations`,
  `shift_records`, `week_records`, `import_runs`, `raw_import_records`
  tables under `restaurant_id = 'demo_restaurant_001'`.
- `test/integration/demo_mode_state_test.dart` covers
  `DemoModeFlipPolicy` semantics (default `is_demo = true`, flip on
  connected + first backfill commit, no auto-revert on disconnect).
- `test/integration/demo_mode_writer_side_test.dart` (added 2026-05-07
  alongside this contract) asserts:
  - The schema has zero `demo_*` SQLite tables.
  - Demo `restaurant_locations`, `shift_records`, `week_records`,
    `import_runs`, `raw_import_records` rows live under
    `restaurant_id = 'demo_restaurant_001'`.
  - Production-side scoped repositories (`SqliteShiftRecordRepository`,
    `SqliteWeekRecordRepository`, `SqliteRestaurantScopeRepository`)
    surface those rows without a `kDemoMode` branch — proving the
    writer-side switch is honored end-to-end.

---

## Maintenance

- Adding a new carve-out requires:
  1. Operator sign-off (this contract docs the rationale).
  2. An inline `// kDemoMode carve-out: <reason>` comment at the
     site.
  3. An entry under "Intentional reader-side carve-outs" above.
  4. A line in CLAUDE.md → Demo Mode listing the new carve-out.
- Removing a carve-out only needs the inverse: drop the comment,
  remove the contract entry, drop the CLAUDE.md line. The branch
  itself is deleted from the source code.
