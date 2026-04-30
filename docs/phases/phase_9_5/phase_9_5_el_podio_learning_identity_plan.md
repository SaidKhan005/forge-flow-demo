# Phase 9.5 - El Podio Learning Identity

Updated: 2026-04-26
Status: Planned
Owner: Future El Podio learning lane

Last review: 2026-04-23 - Backend stack pivoted from Firestore to Postgres alongside Phase 9. Leaderboard tables use RLS policies for per-operator scoping; JWT claims from Firebase Auth drive the scoping.

**2026-04-26 — Postgres host re-locked to Azure DB Flexible Server (Canada Central, PG 16).** Throughout this plan, "Supabase Postgres" reads as "Azure Database for PostgreSQL Flexible Server". Trigger and mechanical impact: see `phase_9_auth_plan.md` 2026-04-26 banner. RLS pattern unchanged — same Postgres RLS policies, same JWT-derived `restaurant_id` scoping; the JWT verification + session-variable injection layer moves from Supabase's built-in path to the Cloud Run proxy backend.

## Goal

Replace demo users and demo points in El Podio with real authenticated users
and real learning-derived scores, so El Podio becomes a true restaurant-wide
multi-user learning leaderboard rather than a local per-device demo.

This phase is deliberately split from Phase 9 so the core auth rollout can
land without a parallel learning-identity rewrite, and so Phase 9.75 (Barrio
Staff Daily Companion) has a concrete standalone dependency target for the
Recognition badges -> El Podio points flow.

## Scope

Phase 9.5 owns:

- real authenticated `userId` as El Podio identity (replacing demo users)
- user-scoped completion points (mastery, streaks, completion state keyed
  by `uid`)
- learning leaderboard identity
- shared backend learning leaderboard state (not local-only
  `SharedPreferences`)
- `el_podio_demo_data.dart` removal / replacement with real data sources
- `BarrioStreakService` user-scoping if not already landed by Phase 9 core
- Recognition badges from Phase 9.75 funneling into El Podio points as a
  defined integration contract

Adjacent work that may land here or plug into this lane:

- shared leaderboard backend schema (Supabase Postgres tables, RLS
  policies, indexes)
- learning points model (what counts as a point per event type)
- ranking tie-breakers and time-window semantics (weekly, monthly, all-time)

## Scope Does Not Own

Phase 9.5 does not own:

- core auth, email/password login, Firebase Auth session (`Phase 9`)
- role and permission key authority (`Phase 9`); `barrio.el_podio.view`
  remains defined in Phase 9
- operational El Podio ranking (total sales, PPA, CPLH leaderboards); this
  is deliberately deferred to a later "Operations El Podio" phase after
  `Phase 8` attribution is real
- POS + labor vendor attribution (`Phase 8`)
- Barrio V1.1 UX shell for Recognition / Coaching Dashboard (`Phase 9.75`)

## Frontend Exposure

Phase 9.5 is UX-led — the El Podio leaderboard surfaces (Barrio) ARE
the deliverable. This section makes the operator/staff-visible
surfaces explicit per Hard Promise #10.

**Operator/staff-facing surfaces this phase requires:**

- `lib/screens/barrio/el_podio_leaderboard_screen.dart` (extend or
  rebuild from `el_podio_demo_data.dart` consumer): real authenticated
  user identity, real points / mastery / streaks; week / month /
  all-time tabs; rank badges; tie-breaker disclosure on hover.
- Personal stats card on Barrio Home (current rank, points-to-next,
  current streak).
- Shared widget for badge / rank chip (reused by 9.75 Recognition).

**Admin (11A) surfaces this phase requires:** none for 9.5. F&F-side
points-model administration is post-launch; not in 9.5 scope.

**UX sub-slice family:** owned inline by existing `9.5.x` slices.
Each `9.5.x` slice that ships operator/staff-visible capability adds
the `Operator walkthrough` block + walkthrough acceptance criterion.

**Demo-mode walkthrough (`kDemoMode = true`):**

- Sign in as a demo staff user → Barrio Home → personal stats card
  shows real points / streak.
- Tap leaderboard → see weekly tab → rank ordering matches points →
  switch to monthly / all-time → ordering updates.
- Tie-breaker disclosure renders when two users share points.
- Recognition badge from 9.75 (when wired) increments the user's
  points and re-ranks live.

Walkthrough evidence required at slice acceptance per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Runtime Contract

```text
authenticated user (Phase 9 identity)
-> user-scoped learning persistence (mastery, completion, streaks, points)
-> shared backend learning leaderboard
-> El Podio ranking surfaces inside Barrio
-> later: Recognition badge awards (Phase 9.75) feed points back in
```

Key rules:

- `userId` comes from Phase 9 auth; El Podio does not mint its own identity
- if the leaderboard is multi-user, the source of truth must be shared
  backend data, not per-device `SharedPreferences`
- leaderboard rows remain restaurant-scoped (`restaurant_id`); there is no
  cross-restaurant El Podio board in Phase 9.5
- El Podio does not pull from POS/labor attribution; that lives in the
  later Operations El Podio phase

## Dependencies

Required before Phase 9.5 can ship real:

- `Phase 9` auth identity and permission model in place
- Supabase Postgres project provisioned (per Phase 9 stack decision);
  leaderboard tables live in the same Postgres instance as profiles and
  roles

Consumers of Phase 9.5:

- `Phase 9.75` Recognition tab depends on the El Podio points model to
  award badge points to real users

## Non-Negotiables

- no demo users and no demo points in production
- no local-only `SharedPreferences` leaderboard state in production
- no operational (POS/labor-attributed) ranking; that is explicitly out of
  scope and belongs to the later Operations El Podio phase
- permission key `barrio.el_podio.view` gates access and is defined in
  Phase 9; it does not move here

## Implementation Prompts

### Prompt 9.5a - User-Scoped Learning Persistence

Goal:

- replace in-memory learning completion / streak state with real user-scoped
  data

In scope:

- mastery persistence
- completion persistence
- streak ownership by `uid`

### Prompt 9.5b - Shared El Podio Learning Leaderboard

Goal:

- move El Podio from demo users to real authenticated learning leaderboard
  data

In scope:

- learning points model
- ranking identity
- shared backend learning leaderboard state

Out of scope:

- live sales ranking
- live PPA ranking
- live CPLH ranking
- POS / labor-attributed leaderboard logic

## Later - Operations El Podio

Operational ranking is scoped outside Phase 9.5 because it depends on work
not yet done:

- `Phase 8` vendor data (POS, labor)
- external identity links (app user <-> POS / labor employee record)
- valid employee / shift / sales attribution rules

Examples of what lands later:

- total sales ranking
- PPA ranking
- CPLH ranking

Do not fold operational ranking into Phase 9.5 or the initial auth rollout.

## Source Material

This phase was extracted from the Phase 9 auth plan on 2026-04-22 so that
Phase 9.75 has a concrete standalone dependency target and so 9.5 content
is no longer scattered across a long auth doc.

- [phase_9_auth_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_9/phase_9_auth_plan.md)
- [phase_9_75_staff_daily_companion_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_9_75/phase_9_75_staff_daily_companion_plan.md)

## Placeholder Notes

- Tracker folding: add to `PROJECT_TRACKER.md` Active Planning Docs list on
  the next Codex pass.
- Shared backend schema (Supabase Postgres tables, RLS policies, indexes)
  must be expanded before implementation prompts start.
