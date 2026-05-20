# Post-1024 Timing Business-Date Fix Plan

Date: 2026-05-19
Branch: codex/post-1024-timing-business-date
Base: origin/master after PR #1024 landed

## Plain English Gap

- Mobile Timing provenance now shows where Timing values came from.
- One gap remained: the mobile Timing sync request did not send a business date.
- When no date was sent, the proxy used UTC today.
- That can pick the wrong effective Timing row for restaurants whose local business day is different from UTC day.

## Fix Plan

1. Mobile request
   - Add an optional business-date field to the resolved Timing sync method.
   - After open-shift snapshots are mirrored, read the current open business date from mobile SQLite.
   - Send that date when fetching resolved Timing.

2. Proxy fallback
   - If mobile does not send a business date, derive the date on the server from the location's timezone.
   - Resolve Timing once for the local calendar date, then use the resolved business-day start time to adjust to the true restaurant business date.
   - If that adjusted date differs, resolve Timing again with the corrected business date.

3. Tests
   - Prove the HTTP client sends `business_date`.
   - Prove mobile sync passes the current open-shift business date after open snapshots are stored.
   - Prove the proxy fallback no longer uses raw UTC today when the location-local date/time points to the prior business date.

4. Verification
   - Run focused sync/proxy tests and analyzer.
   - Run UX copy lint and whitespace check.
   - Run pre-merge gate before merging.
