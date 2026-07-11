// Barrio Surface Polish V1 (BSP) compile-time surface flags.
//
// Plan: docs/phases/barrio_surface_polish_v1/barrio_surface_polish_v1_plan.md
//
// Doctrine: hide-only, never delete. Every flag here gates a reversible
// surface change; restoring the previous behavior is a one-line const flip.
// No files, routes, destinations, screens, or animation code are removed.

/// BSP.1: gates all POSITIONAL motion of the home-hub orbit bubbles.
///
/// When false (the shipped default), orbit bubbles hold their evenly
/// spaced base angles as static tap targets: no time-based orbit
/// rotation, no sway, no breathe radius wobble, no per-bubble float
/// drift. Background/ambient motion continues unchanged (orbit-ring
/// shimmer arc, rotating center arcs, glow pulses, entrance bloom,
/// press feedback, center idle breathing).
///
/// Flip to true to restore the full orbital motion verbatim.
const bool kBarrioBubbleOrbitEnabled = false;

/// BSP.2: gates the gold "EL PODIO" entry pill on the Barrio home screen.
///
/// When false (the shipped default), the pill is not rendered. Nothing
/// else changes: `_ElPodioButton`, `ElPodioScreen`, its route-map entry,
/// destination manifest, and demo content all stay in the tree.
///
/// Flip to true to restore the El Podio home entry verbatim.
const bool kBarrioShowElPodioEntry = false;

/// BSP.2: gates the role PREVIEW switcher row in the Barrio home header
/// (gold dot + `PREVIEW` label + Staff / Supervisor / Manager / Admin
/// chips) AND pins the preview-role fallback to
/// `BarrioPreviewRole.admin` while hidden.
///
/// When false (the shipped default), the row is not rendered and
/// `_resolvePreviewRole` short-circuits to Admin before the
/// override / session-role mapping (which stays in place, unexecuted).
/// The production `PermissionContext` visibility resolver (B18) is
/// independent of this flag and still wins whenever a
/// `PermissionContext` is present.
///
/// Flip to true to restore the switcher and session-role mapping verbatim.
const bool kBarrioShowRolePreviewChips = false;
