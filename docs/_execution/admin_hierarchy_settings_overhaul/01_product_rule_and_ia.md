# 01 - Product Rule And Information Architecture

## Plain-English Product Rule

Forge & Flow manages businesses as a hierarchy:

- Business/operator
- Org units such as region, district, group, or brand
- Locations

Settings can be set high in the hierarchy and inherited down. A lower setting
overrides a higher setting. If a lower scope has no local setting, it inherits.

Every settings surface must make that visible:

- what scope is selected
- whether each value is inherited or local
- where inherited values come from
- what value is currently effective
- what the signed-in user is allowed to change

## Target Admin Console Flow

1. F&F staff signs in to the Admin Console.
2. Staff selects a business directly from Business Accounts.
3. The business detail opens with the location hierarchy as the primary
   management surface.
4. Staff selects business, org-unit, or location scope.
5. Staff opens one focused setup tile.
6. The tile shows effective values and allowed actions for that scope.
7. Mutations require permissions, confirmation copy, audit reason when needed,
   idempotency key, and route-level enforcement.

## Business Accounts Changes

- Remove the repeated `Click to manage` button.
- Make selecting the business row the action.
- Replace the flat Locations section with the full hierarchy manager.
- Hierarchy manager must become the canonical place to organize locations and
  hierarchy nodes.
- Keep unsupported actions disabled with plain copy instead of fake buttons.

## Business Setup Tiles

Only these setup tiles should remain in the selected-business workspace:

1. Account profile
2. Data accuracy
3. Polling and pricing
4. People, access, and roles
5. Security, audit, and sessions
6. Support logs
7. Integrations
8. Timing

Support Workspace stops being a top-level concept. Its useful functions move
into the scoped tiles above.

## Scope Prompt Behavior

Every scoped tile opens the same scope prompt:

- Business: applies to the whole operator unless lower scopes override.
- Org unit: applies to that branch unless descendants override.
- Location: applies only to one location.

Required labels:

- `Inherited from business`
- `Inherited from <org unit>`
- `Set at this scope`
- `Overridden at <child scope>`
- `Location only`

## Tile-Specific Scope Rules

| Tile | Scope rule |
|---|---|
| Account profile | Business-level edit. Show contact email, business setup details, billing/admin metadata, and status. |
| Data accuracy | Must support hierarchy before business/org-unit edit is enabled. Until then, business/org-unit views are read-only rollups or disabled. |
| Polling and pricing | Same as Data accuracy unless scoped assignment/resolver work is implemented. |
| People, access, and roles | Business, org-unit, and location scopes should be real because grants/invites already have scoped backend support. |
| Security, audit, and sessions | Use selected scope for filtering and effective access; include active sessions here. |
| Support logs | Business/org-unit selection should expand to covered locations or call a scoped aggregate route. |
| Integrations | Hierarchy prompt helps find context, but edit requires a location. |
| Timing | Reference implementation for inherited settings; include timezone handling. |

## UX Simplicity Rules

- One selected business.
- One hierarchy panel.
- One setup tile grid.
- One reusable scope prompt.
- One focused settings screen at a time.
- Consistent labels, empty states, loading states, and forbidden states.
- No duplicate concepts between People/access/roles and Security/audit/sessions.
- No hidden backend behavior presented as if it is editable.
