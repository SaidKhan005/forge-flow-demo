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
