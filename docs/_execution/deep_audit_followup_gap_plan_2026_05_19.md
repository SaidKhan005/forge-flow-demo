# Deep Audit Follow-Up Gap Plan

Date: 2026-05-19

## Plain-English Findings

- The last batch landed, but the next audit found a few real gaps.
- Projection retry evidence is now preserved, but the worker must stop trying
  to replay orphaned evidence rows whose live location or connector was hard
  deleted.
- Mobile can write manual covers, but it cannot clear a saved manual cover yet.
- One Data Accuracy repository read path still reads the base table instead of
  the effective/provenance view.
- One Operator Web explainer sentence overstates QuickBooks Time wage data.
- Business Timing editor still shows timezone as editable in timing setup even
  though timezone belongs to the location record.
- Older operators with no operator-scope Business Timing profile can hit a
  dead end when support tries to add a location.
- The starter Business Timing profile should use the restaurant-local business
  date, not database `current_date`.

## Fix Lanes

1. Projection Retry Worker
   - Exclude orphaned rows from due-scope scans.
   - Keep preserved evidence visible in admin observability.
   - Add a focused worker test.

2. Data Accuracy Mobile Clear
   - Add a mobile clear call for manual covers.
   - Let blanking a saved mobile manual cover call the clear route.
   - Keep validation for non-negative numeric writes.

3. Data Accuracy Effective Read
   - Make the repository read effective settings/provenance when available.
   - Keep existing write behavior and defaults stable.
   - Fix the QuickBooks Time wage explainer copy.

4. Business Timing Follow-Up
   - Remove fake timezone editing from the Business Timing editor.
   - Use location/account surfaces for timezone changes.
   - Seed starter timing with a restaurant-local effective date.
   - Give support a real way through the legacy-operator missing-profile case.

## Document Later

- Decide whether defaulted service periods should emit explicit per-period
  provenance objects, or whether "Vendor default" with no row remains the
  intended neutral default.
- Update stale historical execution docs only when they are on the active
  path. They are not current authority.
- `docs/contracts/migrations_summary.md` is stale for the newest migrations;
  do not treat it as the operational migration cutoff.

## Verification

- Each code lane gets focused tests for its edited seam.
- Proxy/schema/runtime lanes run `tool/pre_merge_gate.sh <PR>` before merge.
- After each merge, run `tool/verify_pr_landed.sh <PR> ...` with real landed
  symbols.
