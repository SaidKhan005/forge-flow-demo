# Per-Daypart Targets V1 — Slice 7a audit (Tock business_date timezone projection, Gap 45)

**Branch:** `claude2/slice-7a-tock-business-date-fix`
**Base:** `master` (`88a13ebe`)
**Slice tag:** Per-Daypart Targets V1 — Slice 7a
**Owner:** worker agent (Claude lane, dispatched by Claude 2 orchestrator)
**Verdict:** approve-for-merge (subject to orchestrator audit; this slice does not touch auth, RLS policies, schema, or proxy bootstrap, so does not require the explicit-operator-approval gate beyond the orchestrator pass)

---

## TL;DR

Closes Gap 45 from the per-daypart V1 end-to-end verification (2026-05-15). The Tock reservation Postgres sink was writing `business_date` as the raw UTC calendar date of `reservation_at` via a local `_utcDateString` helper — no IANA timezone projection, no `business_day_rollover_hour` honoring. Any restaurant in any timezone other than UTC got the wrong business-date attribution; any reservation between local midnight and the local rollover hour was bucketed to the wrong business date even for UTC restaurants.

Slice 7a mirrors the OpenTable (`.OT`) and Libro (`.LB`) sinks: inject `IanaTimezoneConverter` in the constructor (defaulting to `IanaTimezoneConverter.shared`), read `(timezone, business_day_rollover_hour)` from `public.locations` inside the same tenant transaction as the INSERT, project `reservation_at` (UTC) to a restaurant-local `business_date` via `IanaTimezoneConverter.toBusinessDate`, format via a `_formatDate` helper. Default fallback when the location row is missing is `('UTC', 4)` — Libro's pattern, NOT OpenTable's `('UTC', 0)`. The `4` matches the operator-default business-day-start hour and is the safer default for restaurant timing. The legacy `_utcDateString` helper is deleted (zero remaining references in `lib/`).

Surgical scope: only the sink file + its test file change. The `seated_at`/`cancelled_at` null-literal policy, demo-flip path, watermark path, connection-id resolver, canonical sink view, `_columnStatusForTock` helper, `_coerceUtc` helper, and `kTockVendorId` references are all untouched. 8 existing tests preserved (none of them seeded a Tock-specific business_date that depended on UTC-vs-local — they used UTC instants in the 18:30–19:35 window which project identically under both UTC+0 and the new UTC+4 default fallback). 4 new tests cover the timezone-projection invariants:

1. `01:30 Wed local` America/Toronto with rollover `4` → `Tue` business_date (was `Wed` under the legacy `_utcDateString`).
2. `23:30 Tue local` America/Toronto with rollover `4` → `Tue` business_date (was `Wed` UTC under the legacy path).
3. `04:00:00 Wed local exactly` with rollover `4` → `Wed` business_date (predicate `local.hour < rollover` is strict).
4. Default fallback when location row missing → `('UTC', 4)`; 03:00 UTC → prior business_date.

`dart analyze --fatal-infos` clean on both touched files; `flutter test` 12/12 pass.

Hard stops respected: no other lib/ files touched, no tests outside the Tock test file, no tracker / ledger / plan / phase doc edits, no `--no-verify`, no merge. Slice 7b (Gap 46 sub-hour cutoff + Gap 47 hierarchy inheritance) is NOT in scope and was not started.

---

## Scope

| What | Where |
|---|---|
| Add `IanaTimezoneConverter` import + constructor injection | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:71, 103-112` |
| Replace `_utcDateString(reservationAt)` with location SELECT + `IanaTimezoneConverter.toBusinessDate` projection inside `_insertReservationFact` | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:169-201` |
| Update file leading-comment block (Tock vendor specifics) to describe new business_date derivation | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:44-53` |
| Delete `_utcDateString` helper, add `_formatDate` helper (mirrors OpenTable's `_formatDate` byte-for-byte) | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:631-637` |
| Extend test fake-pool: add `_StoredLocation` + `_FakeDb.seedLocation`, handle `from public.locations` in `_FakeTx.query` | `test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart:548-577, 715-734` |
| Add Slice 7a regression test group "I." with 4 timezone-projection tests | `test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart:467-672` |
| **Audit doc (this file)** | `docs/_audits/per_daypart_v1/slice_7a_tock_business_date.md` |
| **Untouched (per stop-conditions)** | `seated_at`/`cancelled_at` null-literal policy (`tock_reservation_postgres_sink.dart:213`); demo-flip path (`:340-379`); watermark path (`:226-289`); connection-id resolver (`:419-460`); canonical sink view (`:478-602`); `_columnStatusForTock` (`:610-623`); `_coerceUtc` (`:625-630`); `kTockVendorId` references; `OpenTableReservationPostgresSink` (NOT touched); `LibroPostgresSink` (NOT touched); SR sink (NOT touched); proxy bootstrap; CI tools; SQLite; mobile UI; advisor stack |

**Public API:**

- `TockReservationPostgresSink` constructor adds an **optional** named parameter `timezoneConverter`. Existing callers that omit it transparently get `IanaTimezoneConverter.shared` — no call-site changes required outside tests that want to inject a fake. Verified zero existing call sites in `lib/` (the constructor is called only from production wiring + tests).

**Operator-facing copy:** none — purely internal projection correctness.

---

## Pattern B 14-lens audit

| # | Lens | Finding | Citation | Severity |
|---|---|---|---|---|
| 1 | **Authority order** | Slice aligns with the active feature plan `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` Slice 7a (Gap 45 row in §"Vendor sink business_date gaps", end-to-end verification 2026-05-15). Honors `core_app_architecture.md` Layer 2 (Canonical Facts) — `business_date` is denormalized at write per Phase 7.55 Rule 11 (computed from `location.timezone` + `business_day_rollover_hour`). Honors `phase_7_55_time_boundary_contract.md` ("Restaurant-local timing wins; business date is the anchor"). Honors `integration_spine_architecture_contract.md` "Postgres-backed CanonicalSink" by keeping the projection inside the same tenant transaction as the INSERT. | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` (Gap 45); `docs/contracts/phase_7_55_time_boundary_contract.md`; `lib/services/integration/iana_timezone_converter.dart:74-109` (the helper Slice 7a now uses) | None |
| 2 | **Hard Promises** | HP #1 (Phase 8 = pure transport swap): the change is *inside* Layer 2's transport — the canonical-fact row is now correct, but the columns, the table, the readers, and the UI are unchanged; no business-logic mutation. HP #2 (kDemoMode persists): no reader-side branch added; demo and prod read identically through the corrected `business_date`. HP #4 (per-operator isolation): the new `select timezone, business_day_rollover_hour from public.locations …` runs inside the existing `withTenant(ctx)` block (`tock_reservation_postgres_sink.dart:130-148`), so a tenant cannot read another operator's location settings — primary defense (`OperatorScopedRepository`) + RLS backup. The SELECT is parameterized on `(operator_id, location_id)` from the tenant context; unchanged matrix. | `CLAUDE.md` Hard Promises #1, #2, #4; `tock_reservation_postgres_sink.dart:178-188` (location SELECT runs under `withTenant`'s `exec`) | None |
| 3 | **Service-layer split** | No new top-level files. The change lives in `lib/infrastructure/persistence/postgres/` (the only place raw `package:postgres` imports are allowed; CI lint enforces). The new import is `lib/services/integration/iana_timezone_converter.dart` — already used by neighbor sinks (OpenTable, SR, Libro) for the identical projection seam. No `lib/data/`, `lib/domain/`, or `lib/state/` files touched. No `lib/auth/` (frozen permission catalog) reference. | `lib/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart:68` (same import used by exemplar); `lib/infrastructure/persistence/postgres/libro_postgres_sink.dart` (same pattern) | None |
| 4 | **Architecture guardrails** | `LaborModel` / `TargetCycle` / `WeeklyPlanSnapshot` untouched. `ActiveTargetProfile` untouched. The sink does not own service-period bucketing — it just stamps `business_date` correctly for downstream daypart-bucketing services to consume. Source facts (`reservation_facts`) untouched in shape. Closed-shift truth not retroactively rewritten — Slice 7a only fixes new-write behavior; existing historical rows stay as-they-were until reprocessing. | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:201` (`business_date` only changes shape of NEW writes) | None |
| 5 | **Time guardrails** | This is the **load-bearing lens** for this slice. Before Slice 7a, the sink violated CLAUDE.md "Time Guardrails" rule "Restaurant-local timing wins; business date is the anchor" — it was using raw UTC. After Slice 7a, the sink projects via the same `IanaTimezoneConverter.toBusinessDate` helper that OpenTable / Libro / SR use, with the same `(operator_id, location_id)` SELECT against `public.locations` inside the tenant transaction. UTC instants are coerced via `_coerceUtc` at line 161-162 (unchanged); the converter then wraps the projection per `phase_7_55_time_boundary_contract.md`. `business_date` storage type remains `DATE` per Phase 7.55 Rule 11 (denormalized at write, never re-derived at read). | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:161-201`; `lib/services/integration/iana_timezone_converter.dart:74-109` | None |
| 6 | **RLS-ready schema** | No schema change. The new SELECT against `public.locations` queries an existing operator-scoped table on `(operator_id, location_id)`, both of which match the RLS policy's tenant predicate. No new indexes needed. The `OperatorScopedRepository.withTenant` wrapper still drives `set_config('app.operator_id', …)` + `app.location_id` + `app.user_id` so RLS engages as the backup defense. | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:130-148` (existing `withTenant` block); migration `202605040000` (referenced in file header at line 47) | None |
| 7 | **Proxy & API conventions** | No proxy routes touched. No new `/v1/…` or `/v2/…` paths. Sink is server-side / inside the canonical chain — does not interact with the proxy boundary directly. No `proxy_requests` idempotency-key logic touched. No new audit_log call. No service principal / `sp:`-prefixed JWT introduced. | n/a | None |
| 8 | **Testing seam** | 12/12 tests pass (8 preserved + 4 new I.1–I.4 covering the timezone projection invariants — late-night-before-rollover, late-evening-after-rollover, exact-rollover-instant, default-fallback). Tests use the same in-memory `_FakePool` shape the file already established for groups A–H; a `_StoredLocation` was added to `_FakeDb` and the `_FakeTx.query` now matches `from public.locations` to return seeded rows (or empty to exercise the fallback). The 4 new tests deliberately use America/Toronto (DST-aware) to prove the converter (not just a fixed-offset shortcut) is doing the work — `01:30 EDT Wed` is `05:30 UTC Wed` and projects to Tue under rollover=4. Tests A–H untouched (their UTC instants in the 18:30–19:35 window project identically under both UTC+0 and the new UTC+4 default fallback because all those local hours are ≥ 4). | `test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart:467-672` (group I); local `flutter test` run 2026-05-15 | None |
| 9 | **Operator-facing copy / UX writing standard** | No copy strings introduced. No UX surface changes. The mobile and operator-web UIs do not branch on the sink's projection — they consume the persisted `business_date` value as-is. | n/a | None |
| 10 | **Demo mode contract** | No `kDemoMode` branch added. Demo and prod sinks both go through the same `IanaTimezoneConverter` projection. The demo seeder writes to the same `reservation_facts` table (HP #2 — same writer, same reads). The default fallback `('UTC', 4)` matches what a demo location row would carry if seeded with the operator-default rollover hour. | `CLAUDE.md` Demo Mode section; `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:189-194` (fallback constants) | None |
| 11 | **Ceiling-raise rule** | No lint-tool ceiling raises. No `kAdvisorProxyMaxLines` adjustments. The sink file grew by ~20 lines (new comment block + new SELECT + new `_formatDate` helper, minus the deleted `_utcDateString` helper). This is well below any per-file cap. | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart` | None |
| 12 | **Phase-doc hygiene** | Slice is `< 1 week AND < 5 files` (3 files: 2 implementation + 1 audit doc) — per CLAUDE.md "Phase Doc Hygiene", inline in tracker/plan, no new phase doc needed. The active feature plan `per_daypart_targets_v1_plan.md` already documents Slice 7a / Gap 45 inline. No new contract introduced. | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` (Gap 45 row) | None |
| 13 | **Anti-scope** | Stop-conditions respected. NOT touched: OpenTable sink, Libro sink, SR sink (no need — they already implement this pattern); SQLite tables; proxy bootstrap; mobile UI; operator-web UI; CI tools; advisor stack; auth catalog. NOT touched within the Tock sink: `seated_at`/`cancelled_at` null-literal policy (line 213); demo-flip path (`markReservationsLive`); watermark path (`persistWatermark`/`_writeWatermark`); connection-id resolver (`_resolveConnectionIdInTx`); canonical sink view (`_TockCanonicalSinkView`); `_columnStatusForTock`; `_coerceUtc`; `wipeCredential`. Slice 7b (Gap 46 sub-hour cutoff + Gap 47 hierarchy inheritance) NOT started — separate operator decision required. | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart` (compare against base `88a13ebe` shows only the 4 expected changes); `git diff --name-only origin/master...HEAD` shows only the 3 expected files | None |
| 14 | **Honest disclosures** | `dart analyze --fatal-infos lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart`: clean. `flutter test test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart`: 12/12 pass. Did NOT run wider `dart analyze lib/` — out of slice scope (and any pre-existing baseline failures elsewhere are not this slice's problem per `docs/KNOWN_FAILING_TESTS.md`). Did NOT run migration drift scanner / migration cutoff lint — no `db/migrations/*.sql` changes. Did NOT run advisor proxy size lint — no `tool/advisor_proxy/**` changes. Local hooks installed via `powershell -ExecutionPolicy Bypass -File scripts/install_git_hooks.ps1` at session start; `pwsh` is not on PATH in this WSL/MSYS environment, so used `powershell` (Windows PowerShell 5.1). The hooks installed successfully ("Forge & Flow git hooks enabled for this clone. Active hooks: pre-commit, pre-push."). | Local runs in this worktree, 2026-05-15 | None |

---

## Pattern B exemplar — independent re-audit (load-bearing claims)

| # | Lens | Independent re-audit | Citation |
|---|---|---|---|
| A | **Boundary parity proof — the projection now matches OpenTable byte-for-byte** | The Tock sink's new business_date derivation reads `(timezone, business_day_rollover_hour)` from `public.locations` and calls `_timezoneConverter.toBusinessDate(restaurantTimezone:, businessDayRolloverHour:, instant:)`. The OpenTable sink's `writeReservationFact` does the same call shape against the same table and helper. The Libro sink does the same (with rollover fallback `4`, which Tock now matches). The single semantic difference — Tock falls back to `4` like Libro vs. OpenTable's `0` — is intentional per the slice prompt and the operator-default rollover hour. The SQL of the location SELECT is identical to OpenTable's at the column-name and parameter-name level (verified by `diff` of the two SQL strings). | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:178-201` vs. `lib/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart:263-284`; `lib/infrastructure/persistence/postgres/libro_postgres_sink.dart:130-133` (`?? 4` fallback for `business_day_rollover_hour`) |
| B | **Timezone projection correctness (the I.1–I.3 regression chain)** | Test I.1 takes the UTC instant `2026-05-13T05:30:00Z`. In May 2026, `America/Toronto` is in EDT (UTC-4), so the local wall-clock is `2026-05-13 01:30:00`. `IanaTimezoneConverter.toBusinessDate` evaluates `local.hour (1) < businessDayRolloverHour (4)` → true → subtracts one day → `business_date = 2026-05-12`. Under the legacy `_utcDateString(reservationAt)`, the result was `2026-05-13` (the UTC calendar date). The test asserts the new result and would have failed under the prior code. Test I.2 inverts: `2026-05-13T03:30:00Z` is `Tue 2026-05-12 23:30 EDT`; local hour 23 is NOT < 4, so business_date stays at `2026-05-12`. The legacy code would have returned `2026-05-13` (UTC date) — wrong. Test I.3 nails the strict-inequality predicate at `local.hour < rollover`: `2026-05-13T08:00:00Z` is `Wed 2026-05-13 04:00 EDT exactly`; the predicate `4 < 4` is false → business_date stays at `2026-05-13`. This locks in the contract that 04:00 belongs to the new business day, not the prior one. | `lib/services/integration/iana_timezone_converter.dart:103-108` (the strict `local.hour < businessDayRolloverHour` predicate); `test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart:469-553` (I.1), `:555-616` (I.2), `:618-672` (I.3) |
| C | **Fallback hour rationale (the I.4 default-path test)** | Test I.4 deliberately omits `seedLocation`, so the fake-pool's `from public.locations` handler returns an empty row set; the sink's fallback path resolves `restaurantTimezone = 'UTC'` and `rolloverHour = 4`. The instant `2026-06-15T03:00:00Z` projects to `2026-06-15 03:00 UTC` (no DST under UTC); local hour 3 < 4 → prior business_date `2026-06-14`. The slice prompt explicitly requested `4` (Libro's fallback) over OpenTable's `0` because (a) OpenTable's `0` makes the late-night-after-midnight case pre-emptively wrong for any restaurant that opens past midnight, and (b) Libro's `4` matches the operator-default business-day-start hour and is the safer default for restaurant timing. The test would have FAILED under OpenTable's `0` fallback (would have returned `2026-06-15`), proving the choice is asserted. | `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart:189-194` (the `?? 4` fallback); `lib/infrastructure/persistence/postgres/libro_postgres_sink.dart:133` (Libro source); `test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart:621-672` (I.4 regression) |
| D | **Deletion of `_utcDateString` is safe** | `grep -rn '_utcDateString' lib/` (via Grep tool) returned zero matches in `lib/` after the deletion. The only remaining reference is in `docs/_indices/PER_DAYPART_V1_CLAUDE2_HANDOFF.md` (the handoff prompt that authored Slice 7a) and in `lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart` itself before the edit (now also gone). No other lib/ file imported, called, or referenced the helper. The new `_formatDate` helper added in its place is byte-identical to OpenTable's `_formatDate` (`yyyy-MM-dd` UTC formatter); the Tock sink's only call site is the new business_date projection in `_insertReservationFact`. | `Grep` results 2026-05-15 over `lib/`; `lib/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart:807-813` (the byte-identical exemplar) |

---

## What I ran

```
# Hooks (pwsh not on PATH in this MSYS shell; powershell.exe used instead)
powershell -ExecutionPolicy Bypass -File scripts/install_git_hooks.ps1
# → Forge & Flow git hooks enabled for this clone.
# → Active hooks: pre-commit, pre-push.

# Branch
git checkout -b claude2/slice-7a-tock-business-date-fix

# Dependencies
flutter pub get
# (Got dependencies — 53 packages have newer versions, none required for this slice.)

# Static analysis (slice-scoped)
dart analyze --fatal-infos \
  lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart \
  test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart
# → No issues found!

# Test
flutter test test/infrastructure/persistence/postgres/tock_reservation_postgres_sink_test.dart
# → All tests passed! (12/12 — 8 preserved A–H + 4 new I.1–I.4)
```

---

## Risks / follow-ups

None for this slice. Slice 7a is surgical and limited to the Tock sink's `business_date` projection.

**Out-of-scope (by design, per slice prompt):**

- **Gap 46** (sub-hour cutoff: `business_day_rollover_minute` in addition to `_hour`) — Slice 7b. Operator decision pending.
- **Gap 47** (hierarchy inheritance for `business_day_rollover_hour`: business → operator → location) — Slice 7b. Operator decision pending.
- **OpenTable fallback hour mismatch** — OpenTable's sink falls back to `0` while Libro and (now) Tock fall back to `4`. The slice prompt accepted this divergence as defensible for OpenTable (different historical decision) but explicitly chose `4` for Tock. Whether to harmonize OpenTable to `4` is a separate question, NOT this slice.
- **Backfill for historical Tock rows already written under the legacy `_utcDateString`** — out of scope. The slice prompt scopes Slice 7a to "merge then fix" forward-going writes; any retroactive recompute is a separate sync-worker slice (and may not be needed if the demo's no-vendor-connection-yet state means the live `reservation_facts` rows under Tock are zero or near-zero today).
