# Deep Audit Follow-Up Gap Plan

Date: 2026-05-19
Status: closed on `origin/master` through PRs #1050 to #1057, with this
doc cleanup recording the closure.

## Plain-English Closure

- Projection retry evidence rows stay visible for support, and the worker no
  longer keeps retrying orphaned rows after a location or connector was hard
  deleted.
- Mobile can now write and clear manual covers through the canonical proxy
  path.
- Data Accuracy reads now use the effective/provenance view instead of falling
  back to the base settings table where that would hide inherited truth.
- Operator Web copy no longer says QuickBooks Time sends labor dollars. It now
  says QuickBooks Time sends hours and configured rates, then F&F computes the
  dollars.
- Business Timing setup no longer presents timezone as editable inside the
  timing profile. Timezone belongs to the location/account record.
- Support has a bootstrap path for older operators that do not yet have an
  operator-scope Business Timing profile.
- Starter Business Timing profiles use the restaurant-local business date, not
  database `current_date`.

## Fixed Lanes

1. Projection Retry Worker
   - PRs #1050 and #1054 preserved retry evidence and skipped orphan retry
     scopes.
   - Admin observability keeps the evidence visible.
   - Focused worker coverage landed for the skip path.

2. Data Accuracy Mobile Clear
   - PRs #1051 and #1056 added canonical manual-cover clear behavior across
     Operator Web, proxy, and mobile.
   - Blanking a saved mobile manual cover now clears the server value instead
     of only changing the local mirror.
   - Non-negative numeric validation stayed intact.

3. Data Accuracy Effective Read
   - PR #1055 made the repository read effective settings/provenance when the
     view is available.
   - Existing write behavior and default handling stayed stable.
   - QuickBooks Time wage explainer copy was corrected.

4. Business Timing Follow-Up
   - PRs #1052 and #1057 removed fake timezone editing from the Business
     Timing editor.
   - Timezone changes stay on location/account surfaces.
   - Starter timing uses a restaurant-local effective date.
   - Legacy operators with missing profiles can be bootstrapped by support.

## Product Decisions

- Default Data Accuracy provenance labels stay quiet. If a value is simply
  using F&F's built-in default, operator-facing clients should not add a visible
  "Vendor default" label. Show source labels for configured or inherited
  business, org-unit, location, base, scoped, or service-period rows.
- Archived execution docs remain historical and are not rewritten unless the
  prompt names them. Active docs were cleaned in this follow-up.
- `docs/contracts/migrations_summary.md` was regenerated from
  `db/migrations/*.sql` and now includes 145 migrations.

## Verification

- Each code lane ran focused tests for its edited seam.
- Proxy/schema/runtime lanes ran `tool/pre_merge_gate.sh <PR>` before merge.
- After each merge, `tool/verify_pr_landed.sh <PR> ...` confirmed real landed
  symbols on `origin/master`.
- This doc cleanup refreshed the migration summary and corrected active
  QuickBooks Time wording in the Data Accuracy docs.
