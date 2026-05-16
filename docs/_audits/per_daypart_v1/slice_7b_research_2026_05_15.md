# Slice 7b — Sub-hour cutoff + hierarchy unification: research-only investigation

**Date:** 2026-05-15
**Author:** Claude 2 (parallel-lane orchestrator)
**Type:** Research-only — no production code changed. Produces the input to an operator decision (option (a) vs option (b)) before Slice 7b is dispatched.
**Companion gaps:** Gap 46 (sub-hour cutoff truncation) + Gap 47 (`locations.business_day_rollover_hour` vs `business_timing_profiles.business_day_start_local_time` drift) from `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` §"Vendor sink business_date gaps".
**Stop condition that produced this doc:** Main's Slice 1 has not yet merged (still gated by Gap 42 operator decision unlocking dispatch). Per the Claude 2 handoff v2 stop conditions, Slice 7b is not dispatched until (i) Tasks C + D land, (ii) operator decides (a) vs (b), and (iii) Slice 1 merges to avoid concurrent schema migration churn.

---

## TL;DR

Two viable options for closing Gaps 46 + 47. **Recommend Option (b)** if Slice 1 ships first; **Option (a)** is the sensible cheaper move if the operator wants to ship Slice 7b before Slice 1.

| Axis | Option (a): Widen `locations.business_day_rollover_hour` to TIME | Option (b): Per-sink resolve via `BusinessTimingProfileResolver` |
|---|---|---|
| Fixes Gap 46 (sub-hour cutoff) | ✅ | ✅ |
| Fixes Gap 47 (hierarchy inheritance) | ❌ — still bypasses operator/org_unit profile inheritance | ✅ — by construction |
| Schema migration | 1 column-type change in `public.locations` + SQL trigger update | None (re-uses existing schema) |
| Dart per-sink change | Trivial — call site param-type only | Moderate — each sink injects repository, runs resolver, threads through `BusinessDateResolver.resolve` |
| Sinks touched | 20 vendor sinks (each call site) | 20 vendor sinks (each call site, larger diff per site) |
| `IanaTimezoneConverter.toBusinessDate` change | Required: accept `String 'HH:MM'` instead of `int hour` | Optional: keep current API or deprecate; resolver replaces it at call site |
| Deprecates `locations.business_day_rollover_hour` | No — it stays, just widened | Yes — column becomes write-only legacy then drop |
| Concurrency risk vs Main's Slice 1 | Low (Slice 1 doesn't touch `locations`) | Low–medium (Slice 1's demo reseed touches some sink-write paths; coordination needed) |
| Future cost if/when we add per-shift cutoffs | High — needs another schema migration | Low — resolver is the canonical path |
| Total LoC estimate | ~80–120 lines across 20 sinks + 1 migration + 1 SQL trigger | ~250–400 lines across 20 sinks (constructor injection + new resolver call) |

**Architectural recommendation:** Option (b). The codebase already runs the canonical timing-profile chain (`listCandidateProfilesForLocation` → `BusinessTimingProfileResolver.resolve` → `BusinessDateResolver.resolve`) in one production caller (`lib/services/integration/open_shift_snapshot_projector.dart:32-94`). Adopting it across the sink fanout retires the duplicate `locations.business_day_rollover_hour` column, fixes both gaps in one move, and preserves the architecture's "one canonical timing path" property HP #11 implies.

**Pragmatic recommendation:** Option (a) ships in a day; Option (b) is a multi-day slice. If the operator wants Slice 7b done before Phase 12, ship (a) and accept Gap 47 stays open as a separate follow-up. If the operator's roadmap allows Slice 7b after Slice 1 + 2 merge, ship (b).

---

## Inventory

### Vendor sink files (20 total)

The plan and handoff prompt cite "19 vendor sinks." The actual count on master at `88a13ebe` is 20:

POS (10): [adp_postgres_sink.dart](lib/infrastructure/persistence/postgres/adp_postgres_sink.dart) (labor), [aloha_ncr_voyix_pos_postgres_sink.dart](lib/infrastructure/persistence/postgres/aloha_ncr_voyix_pos_postgres_sink.dart), [aloha_pos_postgres_sink.dart](lib/infrastructure/persistence/postgres/aloha_pos_postgres_sink.dart), [clover_pos_postgres_sink.dart](lib/infrastructure/persistence/postgres/clover_pos_postgres_sink.dart), [lightspeed_lsk_pos_postgres_sink.dart](lib/infrastructure/persistence/postgres/lightspeed_lsk_pos_postgres_sink.dart), [ncr_pos_postgres_sink.dart](lib/infrastructure/persistence/postgres/ncr_pos_postgres_sink.dart), [oracle_micros_simphony_postgres_sink.dart](lib/infrastructure/persistence/postgres/oracle_micros_simphony_postgres_sink.dart), [revel_pos_postgres_sink.dart](lib/infrastructure/persistence/postgres/revel_pos_postgres_sink.dart), [square_pos_postgres_sink.dart](lib/infrastructure/persistence/postgres/square_pos_postgres_sink.dart), [toast_pos_postgres_sink.dart](lib/infrastructure/persistence/postgres/toast_pos_postgres_sink.dart), [voyix_pos_postgres_sink.dart](lib/infrastructure/persistence/postgres/voyix_pos_postgres_sink.dart) (11 — Aloha/NCR/Voyix family carries three reseller sinks).

Labor (5): [agendrix_postgres_sink.dart](lib/infrastructure/persistence/postgres/agendrix_postgres_sink.dart), [humanity_postgres_sink.dart](lib/infrastructure/persistence/postgres/humanity_postgres_sink.dart), [push_operations_postgres_sink.dart](lib/infrastructure/persistence/postgres/push_operations_postgres_sink.dart), [quickbooks_time_postgres_sink.dart](lib/infrastructure/persistence/postgres/quickbooks_time_postgres_sink.dart), [seven_shifts_postgres_sink.dart](lib/infrastructure/persistence/postgres/seven_shifts_postgres_sink.dart).

Reservation (4): [libro_postgres_sink.dart](lib/infrastructure/persistence/postgres/libro_postgres_sink.dart), [opentable_reservation_postgres_sink.dart](lib/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart), [sevenrooms_reservation_postgres_sink.dart](lib/infrastructure/persistence/postgres/sevenrooms_reservation_postgres_sink.dart), [tock_reservation_postgres_sink.dart](lib/infrastructure/persistence/postgres/tock_reservation_postgres_sink.dart) (Tock fixed in Slice 7a).

All 20 currently project `business_date` from `public.locations.business_day_rollover_hour` (INTEGER 0..23) via `IanaTimezoneConverter.toBusinessDate`. Tock is the outlier today (raw UTC date, no converter at all — Slice 7a fixes this and brings Tock onto the same broken-but-uniform footing as the other 19).

### Server-side parallel surface

[db/migrations/202605071900_phase_8_set_business_date_hardening.sql:126-147](db/migrations/202605071900_phase_8_set_business_date_hardening.sql) — the `phase_8_set_business_date()` trigger function reads the same `(timezone, business_day_rollover_hour)` pair from `public.locations` and applies the same `coalesce(v_rollover, 0)` integer-hour math:

```sql
new.business_date := (
  (v_ts at time zone v_tz)
  - (coalesce(v_rollover, 0) * interval '1 hour')
)::date;
```

Two consequences for Slice 7b:

- **Fallback drift surfaced:** Libro's Dart sink defaults `business_day_rollover_hour` to `4` when missing ([libro_postgres_sink.dart:133](lib/infrastructure/persistence/postgres/libro_postgres_sink.dart)); OpenTable defaults to `0` ([opentable_reservation_postgres_sink.dart:279](lib/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart)); the SQL trigger defaults to `0`. Slice 7b should converge on one fallback. (Slice 7a's Tock fix uses `4` to match Libro and the operator-default convention; that may set the precedent.)
- **The trigger is a defense-in-depth backup** for sinks that omit `business_date` from the INSERT or pass it as NULL. None of the current 20 sinks rely on it (every one passes `business_date` explicitly). Whichever option the operator chooses, the trigger needs to be updated in lockstep so the backup math stays consistent with the app math.

### Pre-existing canonical-timing-resolver chain (already in production)

- [BusinessTimingProfilesRepository.listCandidateProfilesForLocation](lib/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart:60) — operator-tenant-scoped query that returns rows ordered operator → org_unit ancestors (root-to-leaf) → location, using `org_units` ltree path containment. Hierarchy compliance per HP #11 is built in.
- [BusinessTimingProfileResolver.resolve](lib/domain/services/business_timing_profile_resolver.dart:21) — pure inheritance resolver; consumes the candidate list in hierarchy order and returns an `EffectiveBusinessTimingProfile` carrying `businessTimezone` + `businessDayStartLocalTime` (TIME, HH:MM) + `weekStartDay` + `servicePeriodDefinitions`.
- [BusinessDateResolver.resolve](lib/domain/services/business_date_resolver.dart:25) — pure resolver: `(localTimestamp, 'HH:mm')` → ISO business-date string. Already sub-hour aware; `_parseHHmm` handles minutes.
- **Reference caller:** [open_shift_snapshot_projector.dart:32-94](lib/services/integration/open_shift_snapshot_projector.dart) — `PostgresOpenShiftTimingProfileSource.resolveForBusinessDate` runs the entire chain end-to-end. Option (b) generalizes this pattern from one consumer to 20 sinks.

The Postgres column for the cutoff is already `TIME` shape on `business_timing_profiles` ([business_timing_profiles_repository.dart:307,442](lib/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart) — `@business_day_start_local_time::time`). Sub-hour precision is already supported on the canonical path; only `locations.business_day_rollover_hour` truncates it.

---

## Option (a): Widen `locations.business_day_rollover_hour` to TIME

### Mechanics

1. **Schema migration** — alter `public.locations.business_day_rollover_hour` from `INTEGER` (0..23, NOT NULL with check constraint) to `TIME` (HH:MM:SS). Add a column comment that the new shape is the operator's local cutoff time. Backfill existing rows from `make_time(business_day_rollover_hour, 0, 0)`.

2. **`IanaTimezoneConverter.toBusinessDate`** — change signature from `int businessDayRolloverHour` to `String businessDayRolloverTime` (HH:MM). Re-use `BusinessDateResolver._parseHHmm` for the minute-aware comparison, or fold `BusinessDateResolver.resolve` into the converter. Either way, drop the existing `businessDayRolloverHour < 0 || businessDayRolloverHour > 23` validation and add a HH:MM format validation.

3. **SQL trigger** — `db/migrations/202605071900_phase_8_set_business_date_hardening.sql:126-147` rewrites to:

   ```sql
   select l.timezone, l.business_day_rollover_hour
     into v_tz, v_rollover_time
     from public.locations l
    where l.location_id = new.location_id;
   ...
   new.business_date := (
     (v_ts at time zone v_tz)
     - coalesce(v_rollover_time, time '00:00')
   )::date;
   ```

   Re-run `tool/migration_drift_scanner.dart --fix --strict-docs` and `tool/migration_cutoff_lint.dart` per CLAUDE.md house rule.

4. **Per-sink change** — exactly one line per sink: the local row binding changes type. e.g. in OpenTable's sink at [:278](lib/infrastructure/persistence/postgres/opentable_reservation_postgres_sink.dart):

   ```dart
   // before
   final rolloverHour = ((locationRows.single['business_day_rollover_hour'] as int?) ?? 0);
   final businessDate = _timezoneConverter.toBusinessDate(
     restaurantTimezone: restaurantTimezone,
     businessDayRolloverHour: rolloverHour,
     instant: fact.reservationAt.toUtc(),
   );

   // after
   final rolloverTime = ((locationRows.single['business_day_rollover_hour'] as String?) ?? '00:00');
   final businessDate = _timezoneConverter.toBusinessDate(
     restaurantTimezone: restaurantTimezone,
     businessDayRolloverTime: rolloverTime,
     instant: fact.reservationAt.toUtc(),
   );
   ```

   Multiply by 20 sinks. The Postgres driver returns `TIME` as a `String 'HH:MM:SS'` by default; the converter normalizes to HH:MM internally.

5. **Operator-web admin** — `lib/admin/screens/operator_location_admin_screen.dart` and `lib/operator_web/screens/business_timing_editor_screen.dart` (or the location-admin equivalent) get a HH:MM time picker for the location-row cutoff. (Today the operator-web business-timing editor already writes to `business_timing_profiles.business_day_start_local_time` as TIME; this widens the *location-row* surface to match.)

6. **Tests** — every sink test that constructs the fake-pool row needs the column type change. Slice 7a's Tock test scaffolding sets the precedent.

### What option (a) does NOT fix

- **Gap 47 — hierarchy inheritance.** The location-row column remains the source of truth for sinks. Operator-default and org-unit profile inheritance through `business_timing_profiles` is still bypassed. An operator who configures "all West-Coast locations roll at 03:30" via the org_unit profile sees the cutoff applied in the read path (because reads run through `BusinessTimingProfileResolver`) but the *write* path still uses whatever `locations.business_day_rollover_hour` carries — which is set by the location admin screen, not the org_unit profile. Drift between read and write attribution is preserved.
- **The duplicate column.** `locations.business_day_rollover_hour` and `business_timing_profiles.business_day_start_local_time` continue to coexist; the only convergence is they now share a TIME shape. Whichever code path mutates one without the other introduces the same Gap 47 drift as today.

### Risks

- **Migration of an operator-scoped table.** `public.locations` has RLS; the column-type change must run as `forge_admin` and be tested in the staging environment before production. Backfill window: trivial (one `UPDATE` per row, no concurrency).
- **`BusinessTimingProfileResolver.resolve` requires `shiftCloseAuthority` non-null** ([business_timing_profile_resolver.dart:96-100](lib/domain/services/business_timing_profile_resolver.dart)) — orthogonal to (a), but flagging because Slice 1.5 made the underlying Postgres column nullable with a deferred drop. Option (a) doesn't trip this; Option (b) might if any operator's profile row carries `close_authority = null` after the deprecation.

---

## Option (b): Per-sink resolve via `BusinessTimingProfileResolver`

### Mechanics

1. **No schema migration.** All required surface already exists.

2. **Per-sink change — every sink injects `BusinessTimingProfilesRepository`** (or a narrower `BusinessTimingProfileSource` interface mirroring `OpenShiftTimingProfileSource` to keep the constructor surface honest). Each sink's `_insertReservationFact` / `_insertCoverFact` / `_insertLaborPunch` runs:

   ```dart
   // 1. Coarse local-date pre-conversion to seed the profile lookup.
   //    The profile lookup is keyed by business_date; chicken-and-egg.
   //    Use the calendar date in restaurant timezone as a coarse seed.
   final localTs = _timezoneConverter.toBusinessLocal(
     restaurantTimezone: restaurantTimezone,
     instant: fact.reservationAt.toUtc(),
   );
   final coarseBusinessDate = _formatDate(localTs);  // YYYY-MM-DD

   // 2. Resolve the effective profile for that coarse date.
   final candidates = await _profilesRepository.listCandidateProfilesForLocation(
     operatorId: fact.operatorId,
     locationId: fact.locationId,
     businessDate: coarseBusinessDate,
   );
   final effective = BusinessTimingProfileResolver.resolve(
     candidates.map(_toBusinessTimingProfile).toList(),
   );

   // 3. Resolve the actual business_date with the effective cutoff.
   final businessDate = BusinessDateResolver.resolve(
     localTimestamp: localTs,
     businessDayStartLocalTime: effective.businessDayStartLocalTime,
   );

   // 4. (defensive) If the profile boundary moved the business_date by ±1
   //    relative to the coarse seed, re-resolve once with the corrected
   //    boundary. In practice this only matters if the operator changed
   //    the cutoff overnight and the instant straddles the change — rare,
   //    but the loop is bounded at 1 iteration.
   ```

   The chicken-and-egg in step 1 (the resolver lookup keys on business_date, which is what we're computing) is bounded: profiles change at business-date boundaries by design (the lookup query at [business_timing_profiles_repository.dart:110-113](lib/infrastructure/persistence/postgres/repositories/business_timing_profiles_repository.dart) is `effective_from_business_date <= @business_date::date AND (effective_until_business_date IS NULL OR @business_date < effective_until_business_date)`). The coarse calendar date is correct for 99.99% of inputs; the rare edge case is an operator who changes the cutoff overnight on the same calendar date the instant lands on, and even there the re-resolve loop converges in one extra hop.

3. **`locations.business_day_rollover_hour` becomes legacy.** Deprecate (don't drop yet — staging needs the deprecation cycle). Add a CI lint that flags new readers of the column outside the legacy SQL trigger.

4. **SQL trigger update.** Two paths:
   - **(b1):** keep the trigger as a defense-in-depth backup using the location-row column (which becomes legacy data). The app math is the source of truth; the trigger fires only on broken sinks. Acceptable but weakens the backup.
   - **(b2):** rewrite the trigger to call a SECURITY DEFINER PL/pgSQL helper that runs the equivalent profile-resolution query. Adds DB-side complexity but keeps the backup math honest. Pick at slice scope time.

5. **Operator-web admin screens already in place.** The business-timing editor at `lib/operator_web/screens/business_timing_editor_screen.dart` already writes to `business_timing_profiles.business_day_start_local_time` with HH:MM precision and hierarchy scope. **No new operator UI is needed for Slice 7b — Slice 2.5 already covered the canonical write path.** This is the architectural payoff of option (b): the operator surface for the cutoff is already correct; option (b) just makes the sink writers consume what the operator surface produces.

6. **Tests** — every sink test extends to inject a fake `BusinessTimingProfilesRepository` returning a pre-baked profile candidate list. Boilerplate-heavy but mechanical. The existing test pattern at `test/services/integration/open_shift_snapshot_projector_test.dart` (if it exists; otherwise mirror the projector's runtime caller) is the template.

### What option (b) fixes that option (a) doesn't

- **Hierarchy inheritance (Gap 47):** by construction. Sink reads use `listCandidateProfilesForLocation` which honors operator → org_unit → location precedence per HP #11. An operator who sets "West-Coast org_unit rolls at 03:30" via the operator-web business-timing editor sees that cutoff applied to *every* sink write under West-Coast locations, with no extra location-row config.
- **Single canonical timing path.** Read and write paths converge on the same resolver chain. The Slice 1.5 audit's "byte-identical to live read" property extends to the write side.

### Risks

- **Per-sink complexity.** ~10–20 lines added per sink × 20 sinks. Easy to get one sink wrong (e.g. forget the chicken-and-egg re-resolve, miscompute the coarse seed, mis-cast the TIME column). Slice 7b's worker prompt would need a strict per-sink checklist.
- **Database lookup per write.** The profile resolution adds a tenant-scoped `SELECT … FROM business_timing_profiles JOIN org_units …` to every sink write. The query is cheap (operator-scoped, indexed) but the round-trip cost matters at high write volume. Mitigation: an in-memory cache keyed by `(operator_id, location_id, business_date_truncated_to_day)` with a 1-hour TTL, populated lazily inside the same tenant transaction as the first write of the batch. Defer the cache decision to slice scope time; without it, write-path latency increases by one round-trip per record.
- **Coordination with Main's Slice 1.** Slice 1's demo reseed extension (Gap 22) touches sink-write paths to populate timing fields on `shift_records`. Option (b) refactors the constructor surface of every sink. Concurrent dispatch courts merge conflicts. Sequencing: Slice 1 → merge → Slice 7b option (b) → merge.

---

## Comparison summary

| Concern | Option (a) | Option (b) |
|---|---|---|
| Closes Gap 46 | ✅ | ✅ |
| Closes Gap 47 | ❌ | ✅ |
| Schema churn | 1 column-type migration + trigger update | None |
| Per-sink Dart churn | Trivial (param-type only) | Moderate (constructor + 3-step resolution at write site) |
| Total LoC estimate | ~80–120 | ~250–400 |
| Adds DB round-trip per write | No | Yes (one profile lookup, cacheable) |
| Adds operator UX | Time picker on location admin | None (operator-web business-timing editor already correct) |
| Concurrency risk vs Main's Slice 1 | Low | Medium (sink constructor refactor overlaps Slice 1's sink-write extensions) |
| Deprecates duplicate column | No (just widens it) | Yes |
| Future-proof for per-shift cutoffs / per-period rollovers | Poor — needs another migration | Good — resolver is the canonical surface |
| Estimated dispatch-to-merge | 1–2 days | 4–7 days |
| Walks back if wrong | Hard (column type already changed) | Easy (per-sink revert) |

---

## Open questions for the operator

1. **Which option?** (a) or (b).
2. **If (b): which trigger sub-option?** (b1 keep trigger as legacy backup) vs (b2 rewrite trigger to use profile resolver via PL/pgSQL helper). Default recommendation: (b1) — legacy trigger is rarely hit and rewriting it adds DB-side complexity for marginal correctness gain.
3. **Fallback hour convergence.** Today three values coexist: Libro's Dart fallback `4`, OpenTable's Dart fallback `0`, the SQL trigger's `coalesce(…, 0)`. Slice 7a's Tock fix proposes `4` (matching Libro and the operator-default `business_day_start_local_time = '04:00'` in the demo seed). Should Slice 7b converge all three on `4`?
4. **Sequencing.** Slice 7b dispatch only after Slice 1 merge (avoid concurrent sink-write churn)? Or carve a contention-free window before Slice 1 if (a) is chosen (option (a) doesn't touch sink constructors)?
5. **`locations.business_day_rollover_hour` retention if (b) is chosen.** Deprecate-and-drop in Slice 7b, or deprecate-only and drop in a follow-up?

---

## What this research does NOT cover

- **Test scaffolding.** Each option's test impact is sketched at the per-sink level but not enumerated test-by-test. A worker dispatched under either option will need to update ~20 sink test files; the count of new tests per option (≈4 timezone projection cases × 20 sinks under (a); ≈4 cases × 20 sinks + new resolver-chain integration tests under (b)) is similar.
- **Performance.** Option (b)'s per-write profile lookup cost is plausibly cacheable but not benchmarked here. If the operator's Wave B vendors push >100 records/second into a single location, the cache becomes load-bearing.
- **`shiftCloseAuthority` non-nullness assumption** in `BusinessTimingProfileResolver.resolve` ([business_timing_profile_resolver.dart:96-100](lib/domain/services/business_timing_profile_resolver.dart)) — Slice 1.5 made the Postgres column nullable as a deprecation step. Option (b) consumes the resolver, which currently throws on null `shiftCloseAuthority`. If the operator's profile rows carry NULL after the Slice 1.5 deprecation, option (b) breaks until either the resolver is relaxed or the deprecation is reverted on the read path. Worth re-checking before option (b) dispatches.
- **Whether to also extend mobile/SQLite sinks** to use the same resolver. The 20 vendor sinks under `lib/infrastructure/persistence/postgres/` are server-side; mobile/SQLite paths use a different read seam (`SqliteRestaurantTimingConfigRepository` returns the already-resolved cutoff). Out of scope for Slice 7b but worth confirming before close.

---

## Recommendation to operator

If Slice 1 lands by EoD 2026-05-16: **go with (b)**. The architecture is asking for it; the canonical path is already in production for one consumer; HP #11 hierarchy compliance is a real promise to operators that today's vendor sinks silently break.

If Slice 1 slips past 2026-05-17 and the operator wants Gap 46 closed before Phase 12 cutover: **go with (a)** as a tactical bleed-stop. File Gap 47 as a separate post-launch follow-up. Document the trade-off in `docs/POST_HARDENING_FOLLOWUPS.md`.

Either way, **do not dispatch Slice 7b until the operator picks**. Per the Claude 2 handoff v2 stop conditions, the option matters enough that the prompt itself should be specialized to the chosen path — there is no generic Slice 7b prompt.
