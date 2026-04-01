# Phase 7.52 Execution Plan

Updated: 2026-03-31
Owner: You
Status: Completed execution reference for `7.52`

Current progress:

- `7.52a` complete
- `7.52b` complete
- `7.52c` complete
- `7.52d` complete
- `7.52e` complete enough for shell execution
- `7.52f` complete
- `7.52g` complete
- `7.52h` complete
- `7.52i` complete
- `7.52` complete
- next active block outside this phase: `7.53`

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

The product principle for this shell is:

- this should not feel like a dead document library
- this should feel like an operating system for restaurant execution

Barrio itself is the private in-restaurant encyclopedia and operating shell.
Forge & Flow remains the shared commercial product and appears inside Barrio as one destination for internal roles.

The shell should eventually support these audience groups:

- all staff
- supervisors
- managers
- admins

### Future Access Intent

- `Admin`
  - everything
  - future admin controls
- `Manager`
  - everything except admin controls
- `Supervisor`
  - operational visibility plus learning surfaces
  - no manager-only override actions inside Forge & Flow
- `Staff`
  - learning surfaces only
  - no Forge & Flow runtime workspace

## Planned Barrio Destinations

The Barrio shell should support the following private destinations:

- `Forge & Flow`
  - the shared product entry point
- `Company Handbook`
  - available to all staff
- `Interview Playbook`
  - manager and supervisor facing
- `Jim Taylor Labor Model`
  - manager and admin facing
- `Preston Lee Model`
  - future destination
  - can be shown as `Coming Soon`
- `Supervisor Content`
  - reserved area for supervisor-specific material
  - exact content can come later

## Shell Experience Direction

The first real Barrio screen after login should be a premium hospitality-driven home hub.

Required mood:

- warm
- light teal
- premium
- playful
- polished
- grounded in the Barrio Legado business-plan palette and feel

Required shell behavior:

- destination-first home experience
- a living system map rather than a plain utility list
- animated bubble or orbit-style destination presentation
- `Forge & Flow` as the largest or most prominent destination
- all major tools visible immediately
- enough hierarchy that users understand what the system contains at a glance

## Role-Aware Structure Before Auth

Before Phase 9, the app may show role-aware structure, but it must not enforce real access control.

Allowed in `7.52`:

- show the full shell for layout and route work
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

The content interaction rule is:

- teach through interaction, not long passive reading
- use scenarios, decisions, quizzes, checkpoints, and progress where appropriate
- keep content chunked and navigable
- allow Claude visual creativity inside the Barrio aesthetic without letting the information architecture drift

The runtime target is not:

- raw PDF embed as the finished experience
- raw HTML dump as the finished experience

## Structured Destination Intent

### `Company Handbook`

- all-staff destination
- should be the most welcoming and approachable learning surface
- should use chapter structure, progress, quizzes, decision-based learning, and light game-style motivation
- source docs are input material only, not the final runtime UI

### `Jim Taylor Labor Model`

- more professional tone than the handbook
- should feel book-like and serious
- should still be interactive and scenario-driven

### `Interview Playbook`

- for managers and supervisors
- should be visual, guided, and interactive
- should support step-by-step walkthrough learning

### `Preston Lee Model`

- `Coming Soon` in `7.52`
- no full content build required yet

## Source Material Inventory

Current known private source material includes:

- `docs/internal/barrio/barrio_legado_business_plan.pdf` (moved from root in 7.52c)
- `docs/internal/barrio/company_handbook.pdf`
- `docs/internal/barrio/interview_playbook.pdf`
- `docs/internal/barrio/jim_taylor_labor_model_deep_dive.html` (moved from root in 7.52c)
- `docs/internal/barrio/barrio_visual_teaching_system_execution_blueprint.md`
- `assets/internal/barrio/branding/logo.png` (moved from root `Logo.png` in 7.52c)
- `assets/internal/barrio/inspiration/`

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
   - Barrio shell IA and home navigation
7. `7.52g`
   - Company Handbook experience
8. `7.52h`
   - manager/admin learning surfaces
9. `7.52i`
   - handoff into Phase 9

## Exit Criteria For 7.52a

`7.52a` is complete when:

- the naming contract is written down
- the phase boundary is written down
- the Barrio shell destinations are written down
- the role-aware but pre-auth rule is written down
- the structured-content rule is written down
- the execution order for `7.52b-i` is written down
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

## 7.52d Completion Note

`7.52d` completed the private Barrio boundary creation:

- `lib/internal/barrio/` now exists as the private code boundary
- the boundary includes `content/`, `routes/`, `screens/`, and `widgets/`
- `lib/internal/barrio/barrio.dart` defines the internal-only ownership/export boundary
- typed Barrio destination and source-material manifests are now checked in
- placeholder scaffolding remains dormant and is not wired into `lib/main.dart` or the public Forge & Flow navigation

## 7.52e Completion Note

`7.52e` is now considered complete enough for shell execution:

- public Forge & Flow identity is already separated from Barrio-private source material
- private Barrio assets and branding references exist inside the repo boundary
- shell scaffolding and route metadata exist
- the next explicit hardening step after `7.52` is a native-build split rather than a Dart-runtime split
- that split should use permanent native build identities `forgeflow` and `barrio`
- Android should separate through product flavors and iOS should separate through schemes and build configurations
- package or bundle ids, display names, app icon sets, and splash assets should separate at the native layer first
- the shared Dart runtime should remain shared, including `lib/main.dart`, until the Forge & Flow and Barrio shells truly diverge
- launcher-icon and native-splash generation should move to flavor-specific config files instead of one shared single-brand generator block
- if iOS native flavor hardening happens from a working copy that lacks `ios/Podfile`, restore or generate the standard Podfile before mapping added schemes and configurations on macOS

## 7.52f Completion Note

`7.52f` completed the Barrio shell IA and home navigation block:

- the dormant Barrio home placeholder was replaced by a real private shell root
- the shell now uses a living-system-map home hub with `Forge & Flow` as the dominant destination
- typed route metadata and destination placeholder screens now exist for all current Barrio destinations
- `Preston Lee Model` is clearly presented as `Coming Soon`
- pre-auth visibility remains visual only; no real auth or permission enforcement was added
- focused Barrio shell widget coverage passed and the public Forge & Flow runtime remained untouched

## 7.52g Completion Note

`7.52g` completed the first real Company Handbook experience:

- the handbook placeholder destination was replaced by a real native Barrio handbook screen
- handbook source material is now represented as typed native content instead of a raw document-viewing path
- three real source-backed chapters landed and two additional chapters are scaffolded for later expansion
- the handbook now includes chapter switching, local visual progress, decision interactions, and checkpoint interactions
- focused handbook widget coverage passed and the existing Barrio shell navigation coverage still passed
- the public Forge & Flow runtime remained untouched

## 7.52h Completion Note

`7.52h` completed the manager/admin learning surfaces:

- the Interview Playbook placeholder was replaced by a real guided native learning screen for supervisors and managers
- the Jim Taylor placeholder was replaced by a real professional native learning screen for managers and admins
- the playbook now has two fully built source-backed sections and two scaffolded sections
- the Jim Taylor surface now has three fully built source-backed modules and one scaffolded module
- shared private learning-surface cards now support scenario and checkpoint interactions across the manager/admin destinations
- Preston Lee remains intentionally `Coming Soon` and Supervisor Content remains intentionally light
- focused manager/admin widget coverage passed and the public Forge & Flow runtime remained untouched

## 7.52i Completion Note

`7.52i` completed the Phase 9 handoff and role-preview polish block:

- a typed Barrio preview-role model now exists for `Staff`, `Supervisor`, `Manager`, and `Admin`
- the Barrio home shell now includes a local role-preview control with `Admin` as the default preview state
- destinations remain visible in every preview mode, but shell emphasis and messaging now react to the selected preview role
- typed route navigation now carries preview-role context into the private destination screens
- a shared access-intent banner now communicates current preview role, intended audiences, and the Phase 9 handoff contract across Barrio destinations
- focused preview-role, shell, handbook, playbook, and Jim Taylor widget coverage passed and the public Forge & Flow runtime remained untouched

## Handoff To 7.53

The next active execution block after `7.52` is:

- `7.53 - Forge & Flow / Barrio native build split`

The goal of `7.53` is to:

- preserve the completed shell, handbook, playbook, Jim Taylor, and role-preview surfaces
- split native build identity with Android flavors plus iOS schemes/configurations
- separate package or bundle ids, display names, app icon sets, and splash assets for Forge & Flow and Barrio
- keep one shared Dart runtime and `lib/main.dart` unless the two runtime shells truly diverge later
- stop before real auth, permissions, or cross-device sync work

After `7.53`, the next follow-on execution block should be:

- `9.1 - Restaurant identity + role model`
## Additional 7.52e Source-Truth Guidance

- `docs/internal/barrio/` is the canonical home for Barrio-private source documents, including the business plan, company handbook, interview playbook, and future private operating material
- `assets/internal/barrio/` is the canonical home for supporting visual source material such as logos, brand imagery, color inspiration, and reference imagery/style inspiration
- these private sources are inputs for future product fulfillment, not the runtime experience themselves
- later `7.52e`/`7.52f`/`7.52g`/`7.52h`/`7.52i` implementation has translated them into native Barrio screens/flows/content rather than raw PDF/HTML viewers
- that fulfillment should preserve the intended visual direction, staff learning/play-style teaching, and planned gamified staff motivation concepts such as leaderboard-style progress where called for by the source material
- `7.52e` should preserve these source-truth inputs so later prompts can fulfill them as native visual/staff-learning experiences instead of document viewers
- `docs/internal/barrio/barrio_visual_teaching_system_execution_blueprint.md` is the authoritative Barrio UX blueprint for future native fulfillment, covering the living-system bubble hierarchy, subtle falling-leaf atmosphere, card-based microlearning, decision-first teaching loop, and controlled gamification
- later Barrio UX prompts should preserve the blueprint's core rule: every visual element must help staff decide faster
- Forge & Flow is frozen during `7.52e`/`7.52f`/`7.52g`/`7.52h`/`7.52i`: do not modify its public screens, navigation, styling, copy, behavior, data flow, or operational UX as part of Barrio work
