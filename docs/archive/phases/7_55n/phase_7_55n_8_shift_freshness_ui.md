# Phase 7.55n.8 - Shift Freshness UI

Updated: 2026-04-13
Owner: Claude implementation
Status: Landed

## Goal

Land the first manager-facing freshness behavior on Shift: pull-to-refresh
and explicit freshness display using the shared seam from 7.55n.7.

## Scope

- In: pull-to-refresh on Shift, freshness label in Shift header,
  honest current-state labeling (Live / Updated X min ago)
- Out: app resume refresh (7.55n.9), boundary auto-refresh (7.55n.10),
  vendor-live plumbing, Variance freshness UI, broad Shift redesign

## What This Establishes

1. **Pull-to-refresh** on both the data view and empty state via
   `RefreshIndicator` routing through `ShiftDashboardNotifier.refresh()`.
   Data stays visible during refresh (no spinner flash).

2. **Freshness label** in the Shift header `Wrap`, after the live clock:
   - `live` (green dot): "Live"
   - `updated` (amber dot): "Updated 3 min ago"
   - `stale` (muted dot): "Updated 2 hr ago"
   - `refreshing`: preserves prior age text
   - null freshness: no label rendered

3. **Notifier refresh path** no longer sets `_isLoading = true` during
   `refresh()` — the `RefreshIndicator` provides its own progress
   feedback and the current data stays visible. `_isLoading = true` is
   only for the initial cold load in the constructor.

## Touched Seams

| File | What changed |
|---|---|
| `lib/screens/shift_dashboard.dart` | Added `RefreshIndicator` on both data and empty views. Added `_FreshnessLabel` widget. `_ShiftHeader` now accepts and renders freshness. |
| `lib/data/shift_dashboard_notifier.dart` | `refresh()` no longer sets `_isLoading = true` — data stays visible during pull-to-refresh |
| `test/shift_freshness_ui_test.dart` | New. 9 widget tests: live/updated/stale labels, pull-to-refresh, refreshing state, null freshness, empty state non-regression |

## Remaining Gaps

- App resume / foreground refresh (7.55n.9)
- Automatic boundary invalidation (7.55n.10)
- Variance freshness UI: deferred, uses same shared seam when ready
- Freshness label does not tick live — re-evaluated on each refresh, not
  continuously. Continuous ticking would require a timer (7.55n.10 concern).
- Vendor live-data capability audit (7.55n.12)
