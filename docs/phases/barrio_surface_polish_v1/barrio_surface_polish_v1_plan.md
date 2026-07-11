# Barrio Surface Polish V1 (BSP)

Updated: 2026-07-11
Status: CODE-COMPLETE 2026-07-11, same day as directed. BSP.1 merged
(#1446), BSP.2 merged (#1447), plan + tracker carve-out landed (#1445);
all content verified on `origin/master`. Remaining before close: optional
operator on-device visual pass (advisory, not a blocker), then retire
this doc to `docs/archive/phases/` and restore the tracker Paused row to
a plain freeze entry. The freeze on all other Barrio work (`9.5.UX.*`,
`9.75`, everything else under `lib/internal/barrio/**`) stays in force.
Owner: Orchestrator (agent-led slices per CLAUDE.md "Agent-led slices")

## Operator direction (2026-07-11)

1. **Static bubbles.** The home-hub bubbles must not orbit. Background
   motion may continue; the bubbles themselves stay static for ease of
   use (stable tap targets).
2. **Hide El Podio and hide the role PREVIEW switcher for now.** Admin
   is the default, active, and only view.
3. **Hides only, not deletes.** Every change must be reversible by
   flipping a flag. No file deletions, no route removals, no
   destination-manifest changes, no screen deletions.

## Doctrine

- **Hide-only.** All three changes gate behind compile-time `const bool`
  flags in one new file: `lib/internal/barrio/barrio_surface_flags.dart`.
  Restoring the old behavior = flip the const. Nothing is deleted;
  `ElPodioScreen`, `BarrioPreviewRole`, the visibility resolvers, the
  route map, and all orbit-animation code stay in the tree.
- **Real permissions are untouched.** The B18
  `PermissionContextBarrioVisibilityResolver` wiring (production
  permission gating) is auth-adjacent and out of scope. Only the
  *preview* chip UI and the *preview-role* fallback are pinned to
  Admin. When a production `PermissionContext` is present it still
  wins, exactly as today.
- **Freeze carve-out is exactly these slices.** No scope growth into
  9.5.UX / 9.75 / El Podio internals / content surfaces.
- Execution: agent-led, `worktree → implement → self-audit → commit +
  push → PR → STOP`; orchestrator audits (Pattern B table in PR body)
  and merges. BSP.1 and BSP.2 touch the same screen surface, so they
  run **serialized** (BSP.1 first), per Cost & Convergence #3. Both
  slices extend the same new flags file.

## Slices

### BSP.1 — Static home-hub bubbles (background keeps moving)

**Files**
- `lib/internal/barrio/barrio_surface_flags.dart` (NEW) — add
  `const bool kBarrioBubbleOrbitEnabled = false;` with a doc comment
  naming this plan.
- `lib/internal/barrio/widgets/barrio_bubble_hub.dart` — gate all
  *positional* bubble motion on the flag.
- `test/barrio_bubble_hub_static_test.dart` (NEW) — smallest widget
  test proving the seam.

**Behavior with `kBarrioBubbleOrbitEnabled = false` (the shipped default)**
- Orbit bubbles render at their fixed base angles (evenly spaced,
  starting at top, exactly as the current `baseAngle` math) and DO NOT
  move: no time-based orbit rotation, no sway, no breathe radius
  wobble, no per-bubble float drift.
- Background/ambient motion continues unchanged: the orbit ring track
  and its traveling shimmer arc (`_OrbitRingPainter`), the rotating
  center arcs (`_CenterArcPainter`), the center glow pulse, and the
  home screen's scrim/leaves layers.
- One-shot entrance bloom, press scale feedback, haptics, dimming
  logic, and tap navigation are unchanged (feedback, not drift).
- Efficiency: while the flag is false, do not `repeat()` the
  controllers that only drive positional motion (float controllers;
  the orbit ticker if nothing else consumes it). Keep the code paths
  intact so flipping the flag restores today's behavior verbatim.

**Tests / verification**
- New widget test: pump the hub, advance several animation frames
  spanning multiple seconds, assert each orbit bubble's `Positioned`
  offset is identical across frames, and assert a bubble tap still
  fires `onDestinationTap`.
- `dart analyze` clean; `flutter test test/barrio_bubble_hub_static_test.dart
  test/barrio_shell_widget_test.dart` green.

**Acceptance criteria** (all verified in PR #1446 audit, merged 2026-07-11)
- [x] Bubble positions constant over time with flag false.
- [x] Ring shimmer + center arcs still animate.
- [x] Flag flip to true restores orbital motion (code inspection is
      sufficient; no test required for the true path).
- [x] No deletions; diff limited to the three files above.

### BSP.2 — Hide El Podio entry + hide PREVIEW switcher; pin Admin

**Files**
- `lib/internal/barrio/barrio_surface_flags.dart` — append
  `const bool kBarrioShowElPodioEntry = false;` and
  `const bool kBarrioShowRolePreviewChips = false;`.
- `lib/internal/barrio/screens/barrio_home_screen.dart` —
  - render `_ElPodioButton` only when `kBarrioShowElPodioEntry`;
  - render the `_RolePreviewRow` (gold dot + `PREVIEW` label + role
    chips) only when `kBarrioShowRolePreviewChips`;
  - while `kBarrioShowRolePreviewChips` is false,
    `_resolvePreviewRole` returns `BarrioPreviewRole.admin`
    unconditionally (session-role mapping code stays in place for
    reversal).
- `test/barrio_shell_widget_test.dart` — update the chips/El Podio
  expectations to the hidden state.
- `test/barrio_role_preview_widget_test.dart` — update the
  `PREVIEW`-row and chip-tap tests to the hidden/pinned-Admin state;
  the pure `BarrioPreviewRole` intent tests are unchanged.

**Leave alone**
- `lib/internal/barrio/screens/el_podio_screen.dart`,
  `el_podio_demo_data.dart`, streak/celebration widgets, the `barrio.dart`
  barrel exports, `barrio_preview_role.dart`,
  `barrio_destination_visibility_resolver.dart`, route map,
  destination manifest.

**Tests / verification**
- Updated widget tests assert: no `EL PODIO` text on home, no
  `PREVIEW` label, no role chips, and the hub renders with Admin
  (nothing dimmed) in dev/demo.
- `dart analyze` clean; `flutter test test/barrio_shell_widget_test.dart
  test/barrio_role_preview_widget_test.dart
  test/barrio_bubble_hub_static_test.dart` green (the last one guards
  BSP.1 against regression).

**Acceptance criteria** (all verified in PR #1447 audit, merged 2026-07-11)
- [x] Home screen shows neither the El Podio pill nor the preview row.
- [x] Preview role is pinned to Admin everywhere the fallback path is
      used; production `PermissionContext` path untouched.
- [x] Flag flips restore both surfaces (code inspection).
- [x] No deletions; hides only.

### BSP.3 — Tracker + docs (orchestrator-owned, no agent)

- `PROJECT_TRACKER.md`: Paused-table Barrio row gains the BSP
  carve-out note; Prompt Fetch Map gains `BSP.*` → this plan; Active
  Lanes notes the serialized BSP run. (Landed with this plan's PR,
  #1445; settled to "landed" state in the closeout PR.)
- On close: mark this plan's slices done (DONE 2026-07-11), then retire
  the plan to `docs/archive/phases/` per Phase Doc Hygiene; restore the
  Paused row to a plain freeze entry. Retirement waits on the optional
  operator visual pass.

## Runtime acceptance (advisory)

Widget tests + `dart analyze` are the merge gate. The Barrio flavor
(`lib/main_barrio.dart`, flavor `barrio`) has no mobile-pressure lane;
an on-device visual pass (bubbles static, ring shimmer moving, no El
Podio pill, no preview chips) is an operator option after merge, not a
blocker.

## Out of scope

Everything else Barrio: 9.5.UX real-leaderboard wiring, 9.75 staff
companion, El Podio internals, content updates, permission-catalog
`barrio.destination.*` keys, and any delete/refactor of the hidden
surfaces.
