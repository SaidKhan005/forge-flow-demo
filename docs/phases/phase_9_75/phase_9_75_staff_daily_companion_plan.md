# Phase 9.75 - Barrio Staff Daily Companion

Updated: 2026-04-23
Status: Planned
Owner: Future staff-facing Barrio lane
Product label: Barrio V1.1

## Decisions Locked (2026-04-22 review)

- **Badge catalog ownership:** globally curated by founders (Said + Vanessa).
  One master catalog shared across all operators. Operators cannot add or
  edit badge definitions. Implication: Phase 9.75 needs a shared backend
  collection (aligns with Phase 10a shared-state authority) and an internal
  authoring path, not per-restaurant admin UX. First-version badge list
  content is still TBD.

- **Coaching content source:** shared corpus of founder-authored training
  material, SOPs, and handbooks (Vanessa is the primary author). The corpus
  is ingested into the Phase 11a knowledge graph; Barrio coaching surfaces
  (My Shift coaching tip, Focus picker AI-assist) retrieve from that graph.
  Forge & Flow Learn continues to supply the "what matters from your own
  closed history" half; the shared corpus supplies the "why this works,
  here's the methodology" half. Mental model: upload new content -> graph
  expands -> advisor finds new connections.

  - Corpus storage location: locked by Phase 11a to Supabase Postgres
    (same project as Phase 9 / 10a / 11a). Founder-authored Markdown
    remains the ingestion source of truth before it is loaded into the
    graph.
  - Timing: Phase 11a runs in parallel with Phase 8 / 8R / 9, so the
    retrieval layer should be ready before 9.75 ships. Barrio AI-assisted
    coaching surfaces can light up at 9.75 launch without waiting on
    Phase 11b (the agent runtime + Coach Chatbot UX). Conversational chat
    is Phase 11b; pre-composed coaching tips and Focus suggestions are
    Phase 11a retrieval.

- **Recognition award UX:** keep it simple for V1.1. Fast path - one
  screen. Manager opens Recognition tab -> picks staff member from list
  -> picks badge from catalog -> optional free-text note -> taps Award.
  No contextual hooks from Coaching Dashboard or event-driven suggestions
  from post-shift recap in V1.1. UX is intentionally adjustable based on
  usage feedback post-launch; those richer flows can land as later
  iterations without reworking the data model.

## Goal

Add a staff-facing side to Barrio so line staff open the app before and after
every shift. The companion pulls Forge & Flow Variance, benchmarks, and Learn
content into a coaching and team-board experience that motivates repeat daily
engagement.

Forge & Flow remains the manager commercial tool. Phase 9.75 does not duplicate
manager analytics. It translates manager truth into staff-level coaching and
team visibility.

## Scope

Phase 9.75 owns:

- Barrio home shell additions: two new bubbles (Team Board, Schedule)
- Team Board tabs:
  - Daily Board (tonight's 86'd items, specials, VIP arrivals, service notes,
    forecast busyness derived from `DemandForecastContext` + reservation signal)
  - Announcements (manager-authored long-form posts, 2-week shelf life, read
    receipts, pin-to-my-shift behavior)
  - Focus (one weekly team goal; manager picks with assistance routed from
    last-week Variance + training content, or types their own)
  - Recognition (manager-only; manager awards shout-outs and named badges that
    feed El Podio points)
  - Coaching Dashboard (manager-only; 1:1 Variance-to-staff view surfacing who
    needs the most support this week, plus assisted coaching-moment routing)
- Schedule surface:
  - My Shift pre-shift briefing (shift time and role, tonight's personal goal
    from Personal Trends, busyness card, pinned announcement, weekly Focus,
    personalized coaching tip)
  - My Shift post-shift recap (verdict on weekly Focus, verdict on coaching
    tip, sales-vs-target summary, daypart breakdown, El Podio points earned)
  - My Shift off-day state ("No shift today" + next shift preview)
  - Personal Trends (staff's own sales numbers, coaching history, streaks,
    compared against restaurant benchmarks / targets)
  - Labor-system push integrations: My Schedule, Daily Schedule, Hours Worked,
    Availability, Shift Swaps, Shift Releases
- Push-notification triggers:
  - post-shift recap push, fired on clock-out timestamp
  - pinned-announcement push when manager pins
  - Focus-change push at week rollover
- Role-aware surfaces: staff view vs manager view (manager-only tabs are gated
  by Phase 9 permission keys)

Adjacent work that may land here or plug into this lane:

- Forge & Flow Learn -> Barrio coaching-content bridge (shared content store so
  staff tips and manager Focus suggestions draw from the same methodology pool)
- Badge catalog and taxonomy (Weedwhacker, Problem Solving Pro, etc.) as a
  shared data model used by Recognition + El Podio

## Scope Does Not Own

Phase 9.75 does not own:

- POS + Labor connector transport (`Phase 8`)
- reservation connector transport (`Phase 8R`); consumes the `Phase 7.56`
  signal for forecast busyness and the later `Phase 8R` feed for VIP + party
  detail on the Daily Board
- auth, roles, permission keys (`Phase 9`)
- El Podio learning identity + shared leaderboard data (`Phase 9.5`)
- shared multi-device state across devices (`Phase 10a`); required for
  cross-device read receipts and pinned-announcement consistency
- live service-period / daypart Shift behavior (`Phase 10.5`); Barrio staff
  see whole-day Shift context through Forge & Flow Variance until `10.5`
- AI Coach Chatbot (staff + manager variants) (`Phase 11b` Agentic Advisor UX)
- another internal architecture rewrite

## Runtime Contract

```text
Forge & Flow runtime (ActiveTargetProfile, WeeklyPlanSnapshot, Variance, Learn)
-> shared read models + coaching content store
-> Barrio staff-facing read services
-> Team Board + Schedule surfaces
-> staff UI + manager-only surfaces (role-gated)
```

The rule carried forward from the architecture docs is:

- Barrio consumes Forge & Flow canonical facts, standards, and locked weekly
  plan truth. It does not recompute them.
- Widgets in Barrio do not own source-truth or bucketing rules; they read
  from app-owned read models only.
- Manager-only tabs (Recognition, Coaching Dashboard) require real
  authenticated permission checks, not preview-only role bridges.

## Dependencies

Required before Phase 9.75 can ship real:

- `Phase 8` live POS + Labor transport so Variance + Personal Trends show
  real numbers
- `Phase 8R` reservation transport so Daily Board VIP + party details are real
- `Phase 9` auth so staff vs manager role gating is enforced
- `Phase 9.5` El Podio learning identity so Recognition badges can award real
  El Podio points to real users
- `Phase 10a` shared multi-device state so read receipts, pinned announcements,
  and Focus rollover stay consistent across devices

Helpful but not required:

- `Phase 10.5` live daypart Shift so post-shift recap can break down by
  daypart without falling back to whole-day context
- `Phase 11a` Advisor Infrastructure so the AI-assisted Focus picker and
  the personalized coaching-tip suggestions retrieve from the shared
  knowledge graph (expected to land before 9.75 given parallel sequencing
  with Phase 8 / 8R / 9)

## Non-Negotiables

- one Barrio account system, one Forge & Flow account system - same credentials
  (locked in `Phase 9`)
- no second source-of-truth path inside Barrio
- no vendor secrets in Flutter
- no in-memory-only state for any surface that must stay consistent across
  devices (announcements, Focus, Recognition, read receipts)
- keep manager-only features gated by Phase 9 permission keys from day one;
  no temporary role bridges in production

## Adjacent Phases

- `Phase 7.56` ships the reservation-book signal that the Daily Board consumes
  for forecast busyness
- `Phase 8R` replaces that signal with live reservation data for VIP + party
  detail
- `Phase 9` owns identity + permissions + role-gated surfaces
- `Phase 9.5` owns the El Podio learning-identity data model that Recognition
  awards points into
- `Phase 10a` owns the shared-state plumbing that read receipts, pinned
  announcements, and Focus require
- `Phase 10.5` owns daypart-aware Shift; Barrio post-shift recap dayparts hook
  into this when it lands
- `Phase 11a` owns the knowledge graph + ingestion pipeline + MCP tool
  layer that Barrio coaching surfaces retrieve from
- `Phase 11b` owns the Agentic Advisor + AI Coach Chatbot; Barrio hosts
  the chat UI when its shell is ready, but does not own the reasoning layer

## Source Material

This phase is being split out from the new product spec + the archived staff
companion behavior notes:

- [barrio_staff_companion.docx](C:/Git%20Local%20Repos/forge_flow_demo/docs/app_store_release/barrio_staff_companion.docx)
- [barrio_staff_companion_behavior_spec.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/archive/reference/barrio_staff_companion_behavior_spec.md)
- [phase_7_56_reservation_book_signal_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/7_56/phase_7_56_reservation_book_signal_plan.md)
- [phase_9_auth_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_9/phase_9_auth_plan.md)
- [phase_9_5_el_podio_learning_identity_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_9_5/phase_9_5_el_podio_learning_identity_plan.md)

## Placeholder Notes

- This doc is a skeleton. Detailed UI contract, data model additions, and
  per-tab read-service surface area must be expanded before implementation
  prompts start.
- Tracker folding: add to `PROJECT_TRACKER.md` Active Planning Docs list on
  the next Codex pass.
