# Brand + Account Scope Execution Plan

Date: 2026-05-20

## Operator Decisions

- Brand is a real hierarchy layer, not only display copy.
- Data Accuracy remains location-editable only.
- Vendor Integrations remain location-editable only.
- Business name and logo remain Business-level only.
- Contact email, contact phone, currency, and locale are editable at Business, Brand, Region, District, Location.
- Timezone is editable at Brand, Region, District, and Location so a group can set one timezone for all locations under it.

## Plain-English Target

- A restaurant group can manage settings at the right level.
- A Brand can sit between Business and Regions, or wherever the operator structures it.
- If a Brand/Region/District sets contact, currency, locale, or timezone, locations under it inherit those values unless the location sets its own override.
- Location-only operational surfaces stay intentionally location-only.

## Full Audit Lanes

- Hierarchy model:
  - Database `org_units.unit_type`.
  - Postgres repository validation.
  - Operator Web hierarchy screen.
  - Admin hierarchy screens.
  - Demo hierarchy fixtures.
  - Scope picker labels and icons.

- Account settings:
  - Operator Web Account screen.
  - Demo write gateway.
  - HTTP gateway path shapes.
  - Proxy write/read routes.
  - Postgres account override repositories.
  - Inheritance wording after save.

- Timezone:
  - Account timezone editor.
  - Location inherited value read path.
  - Business Timing resolution read path.
  - Runtime reads that currently use `locations.timezone`.

- Scope boundaries:
  - Data Accuracy must keep requiring a location.
  - Vendor Integrations must keep requiring a location.
  - Schedule/Plan must keep requiring a location.
  - Notifications stay operator/business-level.
  - Logo upload stays Business-level.

- Tests:
  - Operator Web Account widget tests.
  - Operator Web gateway tests.
  - Proxy route tests.
  - Org-unit repository tests.
  - Hierarchy screen/admin tests.
  - Business timing effective timezone tests.
  - Migration/lint tests after schema changes.

## Execution Slices

### Slice 1: Brand As A Real Hierarchy Type

- Add `brand` to the allowed `org_units.unit_type` values.
- Add a migration that safely replaces the old check constraint.
- Update repository validation to allow `brand`.
- Update operator/admin add-unit dropdowns to include Brand.
- Update labels/icons so Brand renders as Brand, not Group.
- Add a demo Brand node so the visual demo can actually reach the layer.
- Update tests that currently expect `brand` to be invalid.

### Slice 2: Scoped Account Overrides

- Add an org-unit account override store for Brand/Region/District.
- Add read/write gateway methods for org-unit account overrides.
- Add proxy routes for org-unit account overrides.
- Keep the existing location account override route working.
- Update location effective reads so a location can inherit from the nearest Brand/Region/District override.
- Keep Business name and logo out of scoped override tables.

### Slice 3: Account Screen Scope Behavior

- Enable contact email/phone at org-unit scopes.
- Enable currency/locale at org-unit scopes.
- Keep business name/logo disabled below Business.
- Save org-unit changes through the new org-unit route.
- Refresh source wording after save:
  - Unsaved: "Unsaved change here."
  - Saved at selected scope: "Set here at Brand/Region/District."
  - Inherited: "Inherits from nearest parent."
- Keep Data Accuracy and Integrations unchanged.

### Slice 4: Timezone Scope Behavior

- Let the Account timezone editor save at org-unit scopes.
- Make location effective timezone resolve in this order:
  - Location override.
  - Nearest Brand/Region/District override.
  - Existing location timezone fallback.
- Update Business Timing effective resolution to use the same effective timezone.
- Avoid bulk-updating child location rows unless the product later asks for a physical write-down.

### Slice 5: Verification

- Run focused Dart tests for changed screens, gateways, proxy routes, repositories, and migrations.
- Run `dart analyze` if dependency resolution allows it in this worktree.
- Run migration drift/cutoff checks because schema changes are included.
- Self-audit Data Accuracy and Integrations to confirm they remain location-only.

## Guardrails

- No changes to Data Accuracy write scope.
- No changes to Vendor Integration write scope.
- No logo or business-name overrides below Business.
- No destructive reset or main-checkout work.
- No graph refresh.
- No hidden admin route reuse in Operator Web.

## Execution Progress

- Done: Brand is now a real `org_units.unit_type` value with a migration,
  repository validation, Operator Web labels/icons, Admin labels/dropdowns,
  and a demo Brand node.
- Done: Operator Web's management scope option now carries the real org-unit
  type so Account can say Brand, Region, District, Location group, or Location
  instead of flattening every org unit to Region.
- Done: Demo Account settings can visually reach and save scoped contact,
  currency, locale, and timezone at Brand/Region/District/Location through the
  demo scoped-account gateway.
- Done: Business name and logo remain Business-only below Business scope.
- Done: Data Accuracy and Vendor Integrations were left location-only.
- Done: The live HTTP gateway now advertises the org-unit account-overrides
  route because the proxy and Postgres repository are wired.
- Done: Business-level contact email and phone now have real
  `public.operators` columns, so lower scopes inherit from an actual server
  field instead of a missing/default-only value.

## Remaining Live-Server Slice

- Add the production org-unit account override repository/table.
- Wire the proxy read/write route for Brand/Region/District account overrides.
- Teach location effective reads to inherit from nearest org-unit account
  settings before falling back to Business defaults.
- Teach Business Timing runtime timezone resolution to consume the same
  effective timezone chain.

## Live-Server Implementation Plan

- Schema:
  - Add `public.org_unit_account_overrides`.
  - Add Business-level `public.operators.contact_email` and
    `public.operators.contact_phone` defaults.
  - Store only scoped account fields:
    - timezone
    - currency
    - locale
    - contact email
    - contact phone
  - Do not store business name or logo below Business.
  - Do not store business-day rollover here; Business Timing owns that.
  - Use `(operator_id, org_unit_id)` as the key.
  - Add a composite FK to `public.org_units(operator_id, id)`.
  - Add RLS, service/admin grants, an operator-leading index, and updated_at trigger.

- Repository:
  - Add an org-unit account override repository.
  - Load the selected org-unit row and its ancestors.
  - For each field, use the nearest ancestor value when the selected org-unit has no value.
  - Business defaults remain the fallback when no org-unit value exists.
  - PATCH writes only supplied fields; explicit null clears that field back to inherited.

- Proxy route:
  - Add GET/PATCH `/v1/operator/account-overrides/org-unit/{org_unit_id}`.
  - Reuse the existing operator owner/admin gate and Idempotency-Key pattern.
  - Return the same effective / override / businessDefault shape the Account screen already understands.
  - Emit a new audit event on successful writes.

- Operator Web gateway:
  - Re-enable live scoped account overrides once the proxy route exists.
  - Keep demo using the same interface.
  - Keep Data Accuracy and Vendor Integrations location-only.
  - Keep Business name and logo Business-only.

- Effective reads:
  - Location Account effective values resolve:
    - location override
    - nearest org-unit override
    - Business/default fallback
  - Timezone resolves:
    - location account override, where present
    - nearest org-unit timezone override
    - physical location timezone
  - Business Timing uses that same effective timezone for runtime candidate chains.

- Tests:
  - Migration shape test for `org_unit_account_overrides`.
  - Proxy route tests for org-unit GET/PATCH, idempotency, validation, audit, and missing handler.
  - Web gateway tests for the scoped route.
  - Repository SQL tests for nearest-ancestor inheritance.
  - Business Timing SQL test for effective timezone inheritance.

- Boundaries:
  - No Data Accuracy scope expansion.
  - No Vendor Integration scope expansion.
  - No logo or business name overrides below Business.
  - No admin-only route reuse in Operator Web.
