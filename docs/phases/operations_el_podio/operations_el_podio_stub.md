# Operations El Podio - Stub

Updated: 2026-04-23
Status: Planned, skeleton only, post-launch
Owner: Future operations leaderboard lane

## Decisions Locked (2026-04-23 review)

- **This is distinct from Phase 9.5.** `Phase 9.5` owns learning identity,
  learning points, streaks, and the learning leaderboard. Operations El
  Podio gets its own planning home.

- **Post-launch only.** Do not fold operational ranking into the initial
  auth rollout or the launch-phase Barrio learning identity work.

- **Initial concept scope:** three operator-facing leaderboards
  - total sales
  - PPA
  - CPLH

- **Hard blockers are real attribution and shared identity.** No detailed
  design should start until authenticated app users can be tied honestly to
  POS / labor employee records.

- **Skeleton only.** Detailed design, ranking semantics, tie-breakers, and
  anti-gaming rules are deferred until Phase 8 attribution data exists to
  validate the approach.

## Goal

Give Operations El Podio a concrete planning home so the concept no longer
floats as an orphan note under Phase 9.5.

## Scope

Operations El Podio is expected to own, once its blockers are cleared:

- total sales leaderboard per operator
- PPA leaderboard per operator
- CPLH leaderboard per operator

The leaderboard identity should reuse the shared auth baseline from
`Phase 9` / `Phase 9.5`, not mint a separate identity system.

## Scope Does Not Own

Operations El Podio does not own:

- learning points, streaks, mastery, or the learning leaderboard
  (`Phase 9.5`)
- vendor attribution implementation (`Phase 8`)
- auth, roles, or permission keys (`Phase 9`)
- detailed design or implementation prompts yet

## Dependencies

Hard blockers:

- `Phase 8` vendor attribution landed (POS + Labor tied to authenticated
  employees)
- `Phase 9.5` learning identity live (shared auth baseline)
- external identity links exist between app `uid` and POS / labor vendor
  employee records

## Non-Negotiables

- no operational ranking without real employee attribution
- do not fold operational ranking into `Phase 9.5` or core auth work
- keep this doc as a skeleton until attribution data exists to validate
  the design

## Source Material

- [phase_9_5_el_podio_learning_identity_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_9_5/phase_9_5_el_podio_learning_identity_plan.md)

## Placeholder Notes

- Detailed design is intentionally deferred until real Phase 8 attribution
  data exists.
