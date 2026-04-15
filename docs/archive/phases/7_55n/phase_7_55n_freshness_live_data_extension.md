# Phase 7.55n - Freshness / Live Data Extension

Updated: 2026-04-13
Owner: Codex roadmap
Status: Active planning doc

## Goal

Make current-state behavior match the intended manager experience:

- show live floor data when the app can honestly treat it as current
- otherwise show explicit freshness age such as `Updated 7 min ago`
- prioritize Shift as the highest-urgency live surface
- move toward vendor-fed live behavior without pretending the current
  fixture/replay transport is already fully live

## Scope

- In: current-state freshness contract, pull-to-refresh, updated-age display,
  resume refresh, boundary invalidation, runtime/import freshness propagation,
  vendor live-data capability audit, proof cleanup
- Out: benchmark OPZ cleanup, broad UI polish, new push-notification product,
  extraction work, full Phase 8 adapter implementation

## Why This Lane Is Opened

The repo now has:

- shared refresh / invalidation policy (`7.55p.4a`)
- runtime invalidation bus (`7.55p.4b`)
- replay/mock-to-live honesty audit (`7.55p.4c`)
- persisted passive notifications (`7.55p.4d`)

But the intended product behavior is stricter:

- Shift should feel live while the manager is using it
- if it is not live, the app should say exactly how old the data is
- app resume and business-boundary changes should not quietly leave current
  surfaces behind

That work belongs more naturally under `7.55n` because it sits close to
runtime timing, current-state truth, and operational boundaries.

## Slice Map

### `7.55n.7` - Current-state freshness contract

Define the shared freshness states, triggers, display rules, and surface
priority. This is the authority slice.

### `7.55n.8` - Shift freshness UI

Land the first manager-facing behavior:

- pull-to-refresh on Shift
- `Updated x min ago` / `Live` freshness labeling
- stale-vs-current honesty on the Shift surface

### `7.55n.9` - App resume / foreground refresh

Ensure current-state surfaces revalidate when the app is opened or returns
from the background.

### `7.55n.10` - Automatic boundary invalidation

Refresh or invalidate current-state surfaces when the app crosses:

- business-date rollover
- week rollover
- 60-day cycle rollover

while still open.

### `7.55n.11` - Runtime write / import completion propagation

Extend the shared invalidation path so real connector/import writers can
refresh current-state surfaces the same way app/runtime writes do.

### `7.55n.12` - Vendor live-data capability audit

Document what real vendor APIs can support:

- event-driven updates
- polling fallback
- freshness SLA limits
- which surfaces can honestly be near-live

### `7.55n.13` - Proof and blocker cleanup

Close the remaining proof gaps so the freshness behavior can be validated
end-to-end, including the pre-existing SQLite schema blocker.

## Return Path

After the freshness/live-data extension is in place, resume:

- `7.55p.5` - Benchmark OPZ and graph honesty audit
- `7.55o.1` through `7.55o.6`
- then `7.55j.3` and `7.55j.4`

## Current Known Blocker

The pre-existing `snapshot_blended_wage` schema column gap still blocks all
SQLite-backed tests that call `reseedDemo()`. This is not the freshness lane
itself, but it constrains end-to-end proof until `7.55n.13` or an earlier
cleanup resolves it.
