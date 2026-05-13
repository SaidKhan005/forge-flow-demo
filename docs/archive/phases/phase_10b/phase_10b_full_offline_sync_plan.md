# Phase 10b - Full Offline Sync (V2)

Updated: 2026-04-26
Status: Planned, post-launch
Owner: Future shared-state V2 lane

**2026-04-26 — Postgres host re-locked to Azure DB Flexible Server.** Throughout this plan, "Supabase Postgres" reads as "Azure Database for PostgreSQL Flexible Server". Phase 10a's "Supabase Realtime" is replaced by a Postgres LISTEN/NOTIFY → WebSocket bridge in the Cloud Run proxy backend (see `phase_10a_shared_state_v1_plan.md` 2026-04-26 update). Phase 10b inherits the bridge — optimistic-concurrency layering still works the same way (version column + `updated_at` LWW comparator). "Supabase Realtime V2 migration" placeholder is now obsolete; the Phase 10b parallel concern is the proxy WebSocket bridge's evolution (e.g., per-row filtering, presence). Trigger and broader rationale: see `phase_9_auth_plan.md` 2026-04-26 banner.

## Decisions Locked (2026-04-23 review)

- **Sequencing: post-launch (H1 2028).** Phase 10b ships after Phase 10a
  is live and has operated in production long enough to surface real
  pain points from the LWW + online-first pattern.
- **Scope: layer over Phase 10a, do not replace.** 10b extends 10a's
  shared-state foundation; it does not rebuild it. Existing Postgres
  tables, RLS policies, and proxy WebSocket bridge remain; 10b
  adds optimistic-concurrency, richer offline support, and conflict UI
  on top.
- **Trigger to start 10b work:** any one of:
  - Operator #3+ onboards (multi-team concurrency becomes routine)
  - Field reports of "I changed it on my phone but the tablet showed
    old data for minutes" in more than occasional frequency
  - High-stakes object needs concurrency protection (e.g., two managers
    simultaneously adjusting a benchmark override during a contentious
    shift)

## Goal

Evolve shared-state sync from "works fine with 2-3 online devices, LWW
on conflict" to "works perfectly across any connectivity pattern with
any number of devices, with explicit conflict resolution on high-stakes
objects."

This phase is the difference between "usable" multi-device and "trusted
for high-team-size restaurants in spotty-connectivity locations."

## Scope

Phase 10b owns:

- **Optimistic concurrency per object** for high-stakes tables:
  - Read includes row version (`version` column or `updated_at`
    timestamp)
  - Write conditional on version match (Postgres transaction with
    version check via the proxy backend repository, e.g.,
    `UPDATE ... WHERE id = $1 AND version = $2`)
  - On version mismatch, client receives rejection and handles via
    conflict resolution path
- **Offline write queue with reconciliation:**
  - Writes while offline persist to local IndexedDB/SQLite queue with
    client-generated idempotency key
  - On reconnect, queue flushes to Postgres
  - Rejections (version mismatch, RLS violation) trigger local
    rollback + user-facing conflict UI
- **Conflict UI surfaces:**
  - "Someone else changed this while you were offline. Here's their
    version, here's yours. Keep yours / accept theirs / merge."
  - Applies only to objects flagged as high-stakes; low-stakes objects
    continue LWW silently
- **Optimistic UI:**
  - Writes apply immediately to local state
  - Background sync to Postgres
  - Rollback on rejection (rare)
- **Tombstone handling:**
  - Deletes become soft-deletes with `deleted_at` timestamp
  - Devices reconcile to "deleted" state on next sync
  - Hard deletes only via admin ops after grace period
- **Causal ordering** for objects where LWW is dangerous (e.g.,
  sequential edits to the same weekly plan that should merge, not
  overwrite)

Adjacent work that may land here:

- Performance optimization on large per-operator datasets (pagination,
  selective subscriptions)
- Proxy WebSocket bridge enhancements (per-row filtering, presence, server-side fan-out optimizations) if production data justifies
- Cross-device edit-conflict analytics (measure how often conflicts
  actually happen; informs whether 10b was worth building when)

## Scope Does Not Own

Phase 10b does not own:

- Core shared-state infrastructure (`Phase 10a`)
- Auth, roles, permission keys (`Phase 9`)
- Full CRDT-based collaborative editing (different product shape;
  would be a separate phase if ever needed)
- Real-time cursor/presence indicators (different product shape)
- Cross-restaurant synchronization (each restaurant stays isolated)

## Frontend Exposure

Phase 10b adds optimistic-concurrency, offline write queue, and
explicit conflict-resolution UI for high-stakes objects. The
operator-facing UX is the difference between "10a works fine for
2-3 online devices" and "trusted across spotty connectivity with any
device count."

**Operator-facing surfaces this phase requires:**

- Conflict-resolution surface: when an optimistic write rejects on
  version mismatch, the user sees a side-by-side view ("their
  version | your version") with three actions: Keep mine / Accept
  theirs / Merge (where mergeable). New file
  `lib/screens/_shared/conflict_resolution_screen.dart`.
- Offline-queue indicator in app shell: small chip showing pending
  write count when offline. Tappable to drill into queue.
- Offline-queue drill-down: list of pending writes with target table,
  operator action, queued-at timestamp, retry button.
  `lib/screens/_shared/offline_queue_screen.dart` (new).
- Optimistic-rollback toast: when a queued write rejects on
  reconnect, surface toast + deep-link to the conflict resolution
  surface for that write.
- Per-object freshness chrome: "version N · last updated 12 min ago
  by Maria" inline on high-stakes object screens (benchmark override,
  weekly plan snapshot edit, manager override calendar).

**Admin (11A) surfaces this phase requires:** conflict-rate +
queue-depth telemetry tiles in `11A.6` observability dashboard. No
additional 11A scope here.

**UX sub-slice family:** `10b.UX.0-1`

- `10b.UX.0` — conflict resolution surface + freshness chrome on
  high-stakes objects.
- `10b.UX.1` — offline queue indicator + drill-down + rollback toast.

**Demo-mode walkthrough (`kDemoMode = true`; uses fake bridge state
+ simulated version mismatches):**

- `10b.UX.0`: open benchmark override on device A → simulate device
  B writing the same row first → user on A taps Save → conflict
  surface renders side-by-side → tap Accept theirs → row reflects B's
  value → toast confirms.
- `10b.UX.1`: simulate offline → make 3 edits → offline-queue chip
  shows "3 pending" → tap chip → drill-down lists the 3 writes →
  simulate reconnect → 2 succeed silently, 1 rejects → toast surfaces
  + deep-link → conflict resolution → resolve.

Walkthrough evidence required at slice acceptance per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`.

## Runtime Contract (additive over 10a)

Same Postgres + Realtime substrate as 10a. Adds:

```text
optimistic concurrency write path (high-stakes objects only):
  client reads row with version
  client attempts update with `version = read_version` condition
  ↳ on match: update succeeds, version increments
  ↳ on mismatch: rejection, client handles via conflict UI

offline write path:
  client writes to local queue with idempotency key
  ↳ UI shows optimistic state
  ↳ on reconnect: flush queue
     - each write retried with its version check
     - rejections trigger conflict UI
     - successes confirm local state
```

## Dependencies

Required before Phase 10b can ship real:

- `Phase 10a` in production, stable, with enough usage data to
  validate pain points
- Specific high-stakes objects identified (not every table needs
  optimistic concurrency)
- Conflict UI designs (UX work, not just engineering)

## Non-Negotiables

- Never break 10a's foundation; 10b is additive
- Optimistic concurrency applies per-object, not globally (LWW remains
  the default for most tables)
- Conflict UI appears only for objects where silent LWW is dangerous;
  low-stakes objects stay silent
- Audit trail still captures every write (10a pattern preserved)

## Adjacent Phases

- `Phase 10a` provides the foundation 10b extends
- `Phase 9.75` Barrio V1.1 shared state uses 10a; 10b makes that
  sharing more resilient to spotty connectivity
- `Phase 11a` corpus writes are admin-only and infrequent; likely do
  not need 10b's protections (can stay on 10a LWW)

## Source Material

- [phase_10a_shared_state_v1_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_10a/phase_10a_shared_state_v1_plan.md)
- Postgres transaction and optimistic concurrency documentation
- Postgres optimistic-concurrency / version-column patterns

## Placeholder Notes

This is a skeleton. Detailed design is deferred until Phase 10a has
been in production long enough to validate:

- Which specific objects hit concurrency pain often enough to justify
  optimistic concurrency
- Whether spotty-connectivity offline scenarios are actual operator
  complaints or hypothetical
- How multi-operator scaling has shaped the concurrency profile

Tracker folding: add to `PROJECT_TRACKER.md` Active Planning Docs list
on next Codex pass (as a post-launch future-work phase).
