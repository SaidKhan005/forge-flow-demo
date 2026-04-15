# Phase 7.55 - Current-State Freshness Contract

Updated: 2026-04-13
Owner: Codex architecture
Status: Active authority

## Why This Exists

The app now has enough current-state plumbing that we need one explicit
contract for freshness behavior, not just reload mechanics.

The intended manager-facing behavior is:

- show live floor data when it is fresh enough to be treated as current
- if it is not live, say exactly how old it is
- prioritize Shift as the highest-urgency live surface
- never let stale current-state masquerade as live truth

Without this contract, "freshness" will keep drifting between notifier
behavior, screen assumptions, manual refresh buttons, and future vendor
transport decisions.

For the surrounding runtime and ownership rules that this contract sits on
top of, also see:

- `docs/contracts/phase_7_55_architecture_contract.md`
- `docs/contracts/phase_7_55_time_boundary_contract.md`
- `docs/contracts/phase_7_55_target_cycle_weekly_plan_rules.md`

## Core Principle

```text
Current-state surfaces should be as live as the runtime can honestly support.
When live freshness cannot be guaranteed, the UI must say how old the data is.
```

The app may continue showing the last known state when needed, but it must
not present that state as current without freshness context.

## Surface Priority

### Shift

Highest-priority live surface.

This is the manager's "what is my floor at right now?" view, so it should:

- refresh most aggressively
- be the first surface to get live/near-live behavior
- show freshness age explicitly when not confirmed live
- support manual pull-to-refresh

### Variance

Current-state surface, but lower urgency than Shift.

It should participate in the same freshness model, but Shift owns the
strictest manager-facing freshness expectations.

### History and Learn

Not live-critical.

These remain closed-truth / evidence-backed surfaces and should not be
treated as real-time dashboards.

## Freshness States

Every current-state surface should be representable in one of these states.

### `live`

The surface has been refreshed within its accepted freshness window and the
app is willing to present it as current.

### `updated`

The surface has usable last-known data, but the app is not claiming live
freshness. The UI should show age text such as:

- `Updated just now`
- `Updated 3 min ago`
- `Updated 14 min ago`

### `stale`

The data is older than the accepted freshness window or could not be
revalidated. The UI should remain usable, but it must not read as if it is
current live truth.

### `refreshing`

The app is actively revalidating current-state data. This may coexist with
showing the last known state.

## Display Rules

### Live-first, honesty always

- If the data is fresh enough to be treated as live, the app may present it
  as current.
- If the data is not live, the app should show explicit age text.
- If the app cannot confirm freshness, it should prefer honest age/stale
  labeling over silent optimism.

### Minimum UX expectations

- Shift should support pull-to-refresh.
- Shift should show freshness age when not explicitly live.
- Variance should follow the same honesty model, even if it refreshes less
  aggressively than Shift.

### Stale data must not masquerade as live

The app may show last-known current-state data, but not without freshness
context.

## Refresh Triggers

These are the events that should participate in current-state freshness.

### Manual refresh

The user can explicitly revalidate current-state data.

Minimum contract:

- pull-to-refresh on Shift
- optional equivalent manual refresh on other current-state surfaces

### App launch / foreground / resume

When the app opens or returns from the background, current-state surfaces
should revalidate instead of trusting old in-memory state indefinitely.

### App/runtime writes

When the app changes operational truth itself, current-state surfaces should
refresh through one shared invalidation seam.

Examples:

- close shift
- reseed demo
- clear data
- mock replay day advance

### Vendor/import completion

When future connector/import writers finish persisting fresher current-state
data, they should call the same shared invalidation seam.

### Time/business boundary crossing

If the app remains open across:

- business-date rollover
- week rollover
- 60-day cycle rollover

current-state surfaces should invalidate and refresh automatically.

## Architecture Rules

### One freshness policy, not widget-local hacks

Widgets should render freshness state, not invent freshness truth.

The app should own:

- freshness status
- age text source
- refresh triggers
- invalidation rules

through shared runtime seams.

### Event-driven vendor updates are the preferred end state

For real integration, the preferred shape is:

```text
vendor events / imports -> canonical persisted state -> shared invalidation
-> app state refresh -> UI freshness state
```

Device-only screen polling is not the long-term source of truth strategy.

### Foreground truth is stronger than background guarantees

The app should aim to be as live as possible while foregrounded.
Background exactness is not assumed as a contract.

## What This Contract Does Not Promise

- exact real-time background delivery
- OS push notification delivery guarantees
- permanent socket/subscription behavior in every vendor path
- that every surface is equally live-sensitive

The contract is about honest current-state behavior, not pretending mobile
runtime constraints do not exist.

## Planned Implementation Lane

This contract is implemented through the `7.55n` freshness/live-data
extension:

- `7.55n.7` - freshness contract and shared freshness model
- `7.55n.8` - Shift freshness UI, pull-to-refresh, updated-age display
- `7.55n.9` - app resume / foreground refresh
- `7.55n.10` - automatic boundary invalidation / refresh
- `7.55n.11` - write/import completion propagation
- `7.55n.12` - vendor live-data capability audit
- `7.55n.13` - proof cleanup and blocker closeout

## Current Open Constraint

The pre-existing `snapshot_blended_wage` schema column gap still blocks
SQLite-backed tests that call `reseedDemo()`. That does not change this
freshness contract, but it does limit how much end-to-end confidence can be
proven until the gap is fixed.
