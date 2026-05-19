# Production Projector Binding Plan

Date: 2026-05-19

## Plain English Summary

- Production boot builds vendor adapters, but it does not give them the post-write projector wiring by default.
- That means canonical vendor facts can land in Postgres without refreshing the open-shift and closed-shift read models.
- The wrapper already exists, but production needs the missing context: restaurant id, business date, service period, timing profile, and target snapshot.
- This slice keeps the shared checkout untouched and fixes the production wiring in the worktree only.

## Scope

- Build the default production projector bundle inside the Phase 8 production binder.
- Keep test injection seams intact: explicit projector/resolver arguments still win.
- Create a production period resolver that can read real vendor fact maps and resolve:
  - business date from the fact or from the location timing profile,
  - service period from the fact or from timestamp bucketing,
  - open/current versus completed state from close/end/status fields,
  - week id and day label from the business date.
- Create a target snapshot resolver that loads the active target profile and locks the per-service-period target row when one exists.
- Keep boot safe: constructors may allocate repositories, but they must not run Postgres queries until a fact batch actually drains.
- Prove that binder calls with no explicit projector arguments now wire projecting sinks.

## Guardrails

- No schema changes.
- No live cloud, provider, or database calls during tests.
- Do not change vendor credential behavior.
- Do not change adapter dispatch behavior outside the projector wiring surface.
- Projection failures must keep failing soft through the existing wrapper log path.

## Verification

- Run focused analyzer on changed files.
- Run focused tests for:
  - production binder,
  - vendor integration factory projector wrapping,
  - projecting canonical sink.
- Run `git diff --check`.
- Run the pre-merge gate before merge because this touches proxy/runtime wiring.

## Follow-Up Watch

- Result: the adapter-specific write path still needs a follow-up slice. The factory now builds production-ready projecting sinks by default, and the wrapper can handle real vendor maps, but adapters still receive their vendor-specific sink interfaces. The next pass should add a projection tap to those direct adapter sinks or otherwise route adapter writes through the projecting wrapper without changing vendor behavior.
