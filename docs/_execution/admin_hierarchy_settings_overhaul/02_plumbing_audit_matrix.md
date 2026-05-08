# 02 - Plumbing Audit Matrix

## Coverage Summary

The UX target is simple, but the implementation crosses Flutter admin UI,
operator web parity, proxy routes, repositories, migrations, RLS, audit,
deployment, tests, and Browser Use verification.

## Existing End-To-End Or Partial Plumbing

| Area | Current state | Required work |
|---|---|---|
| Business account profile | Admin `/v1/admin/operators` and repository paths list, onboard, patch, suspend, and reactivate operators. | Make Account profile the single edit entry point. Rename UI copy from Owner email to Contact email while preserving `owner_email` wire compatibility. |
| Location CRUD | Admin location gateway and proxy support add, patch, and hard delete. | Move into hierarchy UI. Add `parent_org_unit_id` to creation. Decide archive/suspend/delete lifecycle. |
| Org-unit hierarchy | `org_units` ltree schema, list, create, and location move plumbing exist. | Reconcile admin gateway route mismatch. Add edit/lifecycle only after schema/routes exist. |
| Role grants | `user_roles` supports `operator_wide`, `org_unit`, and `location`. | Use this in People/access/roles with clear inherited/effective copy. |
| Invites | `auth_invites` supports operator-wide, org-unit, and location scopes. | Fix UI/dialog assumptions that still require location. Add invite email delivery/resend if expected. |
| F&F support access | `operator_admins` allows one user across multiple operators. | Preserve multi-business F&F staff access. Do not apply a blanket one-email rule to support staff. |
| Active sessions | Admin and operator web session routes exist. | Move sessions into Security/audit/sessions. |
| Audit/security actions | MFA reset, reset password, suspend/reactivate, support actions, and audit routes exist. | Group under Security/audit/sessions and keep all actions gated/audited. |
| Vendor integrations | Per-location vendor connection and OAuth plumbing exists. | Keep edits location-only. Scope prompt can narrow the location list. |
| Timing | Business timing profiles already resolve operator/org-unit/location inheritance. | Use as the reference model. Add admin scoped surface and include timezone. |
| Data accuracy | Schema and repo are `(operator_id, location_id)` only. | Add hierarchy-scoped schema/resolver before business/org-unit edits. |
| Polling tier | Assignment model is location-only. | Add scoped assignment/resolver before business/org-unit edits. |
| Usage caps | Repository has `billing_owner_org_unit_id` and `scoped_org_unit_id`, but admin path uses root org unit for both. | Expose real hierarchy choice for usage caps separately from polling tier assignments. |
| Notifications | Operator/location scope only. | Either document as operator/location-only or add org-unit support through migration and routes. |
| Support logs | Current filters are operator/location. | Add business/org-unit expansion or aggregate route. |
| Preview deploy | DB-safe startup mode exists and is tested. | Use it when preview shares staging DB. Use data-isolated preview for full mutation sweeps when possible. |

## Must-Fix Before Live UI Claims

### Admin Hierarchy Routes

Inspected proxy routes expose:

- `GET /v1/admin/auth/org-units`
- `POST /v1/admin/auth/org-units`
- `PATCH /v1/admin/auth/locations/:location_id/org-unit`

The admin gateway currently calls:

- `POST /v1/admin/auth/org-units/:id/move`
- `POST /v1/admin/auth/locations/:id/move`

Implementation must either add matching proxy routes or update the gateway to
use the existing proxy contract. Add exact method/path/body tests.

### Add Location

`locations.parent_org_unit_id` is non-null after hierarchy migration. The flat
admin `insertLocation` path does not pass it. New location creation must:

- require a selected parent org unit, or
- explicitly default to root org unit and say so in UI copy.

### Org-Unit Lifecycle

`org_units` has no active/suspended/archived columns. Do not expose full delete,
suspend, or archive buttons until schema, repository, route, audit, and tests
exist. If the product says "delete", prefer designing archive/suspend semantics
first.

### Email Policy

Business Contact email is business metadata. Authenticated owner/team/support
emails are access identities. F&F staff support accounts need to access many
businesses through `operator_admins`.

The duplicate-email UX should show where the email is used:

- business
- role or pending invite
- hierarchy/location scope
- status
- revoke/transfer decision path

### Settings Inheritance

Do not reuse `user_effective_locations` as the settings resolver. It solves
access. Each settings family needs its own effective-value resolver, following
the business timing pattern.

## Testing Gaps To Fill

- Admin gateway route-contract tests for every hierarchy mutation.
- Proxy tests for hierarchy list/create/move and forbidden roles.
- Migration/repository tests for scoped settings tables before enabling edits.
- Widget tests for business/org-unit/location scope prompt labels.
- Tests proving location-only surfaces stay disabled above location scope.
- Tests proving demo gateways are not used as preview/live evidence.
- Browser Use evidence for all tiles, including mutations in a safe preview DB.
