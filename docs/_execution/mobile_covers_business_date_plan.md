# Mobile Covers Business Date Plan

Date: 2026-05-19
Branch: `codex/mobile-covers-business-date`
Base: `origin/master` after PR #1033 landed.

## Plain English Summary

- Mobile Covers now writes real server truth, but its default date still comes
  from the phone's local calendar.
- Restaurants are governed by the restaurant's local business date, not the
  phone timezone.
- If a manager records covers before the restaurant's business-day rollover,
  or from a phone in a different timezone, the default date can be wrong.
- The fix keeps the operator-selected date picker unchanged, but chooses the
  initial date from the persisted Timing config when available.

## Fix Plan

1. Read the active Timing config that Mobile Settings already uses for service
   periods.
2. Convert the current UTC instant into the restaurant's configured timezone.
3. Resolve the business date using the configured business-day start time.
4. Update the Covers date only when the operator has not already picked a date.
5. Keep the current device-local fallback when Timing config is unavailable or
   the timezone is invalid.
6. Remove stale active comments that still say this is a manual vendor
   override.

## Verification

- Add widget tests for:
  - restaurant-local prior business date before rollover,
  - no date reset after the operator changes the date,
  - existing save behavior still writes the selected date.
- Run focused Covers Setup widget tests.
- Run analyzer on touched files.
- Run UX em-dash lint.
- Run `git diff --check`.

## Guardrails

- No schema changes.
- No proxy changes.
- No live cloud, Firebase, provider, or database mutations.
- Shared checkout stays on `master`.
