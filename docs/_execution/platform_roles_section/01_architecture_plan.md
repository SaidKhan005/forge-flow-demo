# Forge & Flow access roles implementation plan

## Goal

Expose the existing seeded Forge & Flow platform roles in the Admin Console Roles & permissions tab as a same-tab section called **Forge & Flow access**, with low-friction permission editing for authorized platform admins.

## Architecture rules

- `super_admin` and `ff_support` remain global seeded role rows (`operator_id = NULL`). Do not create per-operator copies.
- Operator default roles remain in the existing Default roles section. Platform roles are separated in the UI but keep the same backend role identity and audit trail.
- Editing is permission-only. Role key, role name, delete, duplicate, and assignment management stay out of this surface.
- The UI uses human labels (`Ecosystem admin`, `Support access`) and does not expose a role-key input.
- All writes continue through the audited seeded-role permission endpoint with `admin_reason` and `Idempotency-Key`.
- `super_admin` keeps locked recovery permissions so the console cannot remove its own admin-role/configuration path.
- Demo fixtures must include both platform roles so local walkthroughs and widget tests match production visibility.

## Implementation slices

- Admin gateway: classify platform roles and expose an `editPlatformRole` method that reuses the audited seeded-role transport.
- Demo gateway: seed platform roles, enforce the same locked-permission rule, and keep idempotent audited mutations.
- Admin UI: render a separate `Forge & Flow access` section above Default roles, reuse the existing role editor popup, and disable locked permissions.
- Proxy: enforce the `super_admin` locked-permission invariant before applying seeded-role permission edits.
- Tests: cover section split, locked checkbox behavior, demo gateway lock rejection, and focused regression gates.

## Non-goals

- No new permission keys.
- No migrations.
- No cross-surface role assignment changes.
- No operator-web role editor changes, because platform roles are managed from the Admin Console platform section.
