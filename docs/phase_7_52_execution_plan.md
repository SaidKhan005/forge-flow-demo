# Phase 7.52 Execution Plan

Updated: 2026-03-30
Owner: You
Status: Active planning contract for `7.52`

Current progress:

- `7.52a` complete
- `7.52b` complete
- `7.52c` complete
- current active block: `7.52d`

## Purpose

This document locks the execution scope for `Phase 7.52`.

`7.52` is not a new data-architecture phase.
It is a cleanup, product-identity, private-build, and Barrio shell phase that happens while:

- the aligned Phase 8 app-side architecture remains unchanged
- live POS and labor adapter work waits on vendor selection
- Phase 9 auth and permissions have not started yet

## What 7.52 Must Accomplish

`7.52` should leave the repo in a state where:

- Forge & Flow is clearly the shared product identity
- Barrio exists as a private internal build identity inside the same repo
- private Barrio source material no longer clutters the shared product root
- the repo is ready for a future dual-build setup
- the Barrio shell exists conceptually and visually before auth arrives
- private handbook and model content are planned as structured in-app experiences rather than raw document viewers
- the work can hand off cleanly into Phase 9 auth and Phase 10 shared sync

## Product Identity Contract

These rules are frozen for the rest of `7.52`:

- `Forge & Flow` is the shared product
- the restaurant name shown inside the app remains runtime-scoped
- `Barrio` is a private internal build identity
- customer restaurants and future vendor integrations belong to Forge & Flow, not to Barrio
- Barrio must remain an internal layer inside the same repo, not a forked customer product

## Phase Boundary Contract

These boundaries are frozen for the rest of `7.52`:

- `7.52` may change:
  - naming
  - repo/file structure
  - private content structure
  - private app shell structure
  - future build identity setup
  - branding boundaries
- `7.52` may not change:
  - canonical data flow
  - Phase 8 data contracts
  - target math
  - baseline logic
  - live vendor integration scope
- `Phase 9` owns:
  - login
  - roles
  - permissions
  - real access gating
- `Phase 10` owns:
  - shared multi-device state
  - cross-device mutation propagation

## Barrio Shell Vision

The Barrio build should become a private internal shell that can eventually route users by role.

During `7.52`, that means the shell should be designed with role-aware information architecture, even though enforcement will not exist yet.

The shell should eventually support these audience groups:

- all staff
- supervisors
- managers
- admins

## Planned Barrio Destinations

The Barrio shell should support the following private destinations:

- `Forge & Flow`
  - the shared product entry point
- `Company Handbook`
  - available to all staff
- `Interview Playbook`
  - manager and admin facing
- `Jim Taylor Labor Model`
  - manager and admin facing
- `Preston Lee Model`
  - future destination
  - can be shown as `Coming Soon`
- `Supervisor Content`
  - reserved area for supervisor-specific material
  - exact content can come later

## Role-Aware Structure Before Auth

Before Phase 9, the app may show role-aware structure, but it must not enforce real access control.

Allowed in `7.52`:

- sections grouped by future audience
- preview labels such as staff, supervisor, manager, or admin
- private navigation structure that assumes future gating

Not allowed in `7.52`:

- real login
- permission checks
- actual role enforcement
- shared restaurant user state

## Content Design Contract

Private source documents are not the final runtime experience.

The handbook PDF, model deep dives, and future playbooks should be treated as source material only.

The runtime target is:

- structured in-app content
- polished presentation
- sectioned navigation
- clear progress or hierarchy
- easy future searchability
- easy future role gating

The runtime target is not:

- raw PDF embed as the finished experience
- raw HTML dump as the finished experience

## Source Material Inventory

Current known private source material includes:

- `docs/internal/barrio/barrio_legado_business_plan.pdf` (moved from root in 7.52c)
- `docs/internal/barrio/jim_taylor_labor_model_deep_dive.html` (moved from root in 7.52c)
- `assets/internal/barrio/branding/logo.png` (moved from root `Logo.png` in 7.52c)

This source material was relocated into the private Barrio boundary during `7.52c` and should be translated into structured app content in later blocks.

## Planned 7.52 Execution Order

1. `7.52a`
   - tracker lock
   - shell scope lock
   - product and phase boundary lock
2. `7.52b`
   - product identity and naming cleanup
3. `7.52c`
   - legacy file cleanup
   - private root asset and doc cleanup
4. `7.52d`
   - private Barrio boundary creation
5. `7.52e`
   - dual-build foundation
6. `7.52f`
   - Barrio shell and navigation
7. `7.52g`
   - structured interactive content surfaces
8. `7.52h`
   - handoff into Phase 9

## Exit Criteria For 7.52a

`7.52a` is complete when:

- the naming contract is written down
- the phase boundary is written down
- the Barrio shell destinations are written down
- the role-aware but pre-auth rule is written down
- the structured-content rule is written down
- the execution order for `7.52b-h` is written down
- the trackers point to this document and move the active prompt to `7.52b`

## 7.52b Completion Note

`7.52b` completed the public product identity cleanup:

- `pubspec.yaml` now uses `forge_and_flow`
- the root IntelliJ module is now `forge_and_flow.iml`
- README now presents the repo as `Forge & Flow`
- Android, iOS, and Windows public-facing app strings now use `Forge & Flow`
- the default demo restaurant scope no longer uses the product name as the restaurant name
- the app title now stays `Forge & Flow` instead of reading restaurant scope as the product identity
- stale persisted `Forge & Flow Demo` restaurant scope rows now normalize back to the demo restaurant display name

## 7.52c Completion Note

`7.52c` completed the legacy file cleanup and private root file relocation:

- `lib/data/meridian_data.dart` renamed to `lib/data/legacy_fixture_data.dart`
- `lib/data/demo_data.dart` renamed to `lib/data/fixture_seed_data.dart`
- `Barrio Legado Business Plan.pdf` moved to `docs/internal/barrio/barrio_legado_business_plan.pdf`
- `jim_taylor_labor_model_deep_dive.html` moved to `docs/internal/barrio/jim_taylor_labor_model_deep_dive.html`
- `Logo.png` moved to `assets/internal/barrio/branding/logo.png`
- all Dart imports and doc/tracker references updated to new paths

## Handoff To 7.52d

The next active execution block is:

- `7.52d - Private Barrio boundary`

The goal of `7.52d` is to:

- create a private Barrio layer inside the same repo for internal-only docs, assets, routes, and content
- shared product logic must remain in Forge & Flow core
- Barrio must not become a forked codebase
