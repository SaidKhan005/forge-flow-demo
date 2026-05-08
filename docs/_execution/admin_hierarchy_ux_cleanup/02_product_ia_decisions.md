# Product And IA Decisions

## Current Product Rule

Business setup is hierarchy-first, function-second.

The admin should not be asked to choose scope in a popup after clicking a setup
tile. Instead, the selected business hierarchy row is the current scope. If no
row is selected, the current scope is the selected business.

## Clarified Decisions

These decisions are locked for implementation:

- Business/org-unit/location scope is editable now for Data Accuracy and
  Polling Setup. This requires real backend/schema/resolver work, not a
  read-only rollup.
- Admins can move both locations and org units.
- Admins can suspend and delete locations and hierarchy levels, with guarded
  confirmations and audit reasons.
- Opening a setup screen with no hierarchy row selected defaults to selected
  business scope. If no business is selected, all businesses show collapsed.
- The setup scope popup is removed for Business Setup functions.
- The Polling Setup calculator should use the most practical implementation
  inputs, such as vendor, estimated calls per day, selected scope size, API cost
  per call, monthly estimate, and margin. Manual entry remains an override.
- Poll-only vendors default to the Regular/Standard tier until changed.
- Connected Services live status means the vendor/API is reachable.
- Vendor unlock state uses the same API-reachable logic.
- Logs show full actor identity: name, role, and email.
- Relationship help and Account help are wired now.
- System Metrics moves to the AI section and is renamed `AI Metrics`.
- System Health, AI Metrics, Launch Controls, Knowledge Base, Plans and Limits,
  Connected Services, and Support Logs follow the same hierarchy behavior.
- Raw IDs, permission keys, hashes, and control names are hidden by default and
  exposed only in advanced details.
- The setup button grouping is confirmed as Profile, Operations, People, and
  Safety/support.

## Target Interaction Model

### Business Accounts

- Top header: larger and bolder admin identity, email, and sign-out in the shell.
- Page title: `Business accounts`.
- Remove subtitle text that starts with "Start with the business...".
- `New business` is larger and more visually dominant.
- Business profile card shows contact email, currency, plan, and the Account
  profile action.
- Hierarchy panel is the primary selector for business, org unit, and location.
- Selecting a hierarchy row updates the current scope for the setup launcher.
- Setup launcher opens functions directly with the current scope.

### Business Setup Launcher

Scope summary:

- Show one plain label such as `Selected business scope`,
  `Selected org unit scope`, or `Selected location scope`.
- Show the selected business/path name.
- Remove chips such as `Set at this scope`, `Effective: Business default`,
  `Editable`, `Read-only`, `Review`, `Ready`, and `Business default`.

Button groups:

| Group | Buttons | Tone |
|---|---|---|
| Operations setup | Integrations, Covers and Wage Data Accuracy, Timing | Same color |
| People setup | People/access/roles | Distinct color |
| Safety/support | Security/audit/sessions, Support logs | Same color |
| Profile | Account profile | Lives on the top business profile widget |

Button labels should keep only scope applicability when it helps:

- `Business scope`
- `Org unit scope`
- `Location scope`
- `Select a location`

### Split Or Tab Workspace

Every setup screen with business/location filters should use the same workspace:

1. Scope tab or left pane: all business accounts and their hierarchies.
2. Function tab or right pane: selected setup function.

Behavior:

- When opened from Business Accounts, expand the selected business and selected
  hierarchy row.
- When no business is selected, show all businesses collapsed.
- The old "Show all" filter becomes "All businesses" in the scope tab, not a
  button that clears context inside the function screen.
- Search lives in the scope tab and filters businesses, org units, and locations.
- On mobile/narrow width, use two tabs: `Scope` and the function name.
- On desktop, use split view where space allows.

## Surface Product Rules

### Covers And Wage Data Accuracy

- Rename `Data accuracy` to `Covers and Wage Data Accuracy`.
- It is not a per-location-only mental model. It opens with the shared hierarchy
  selector.
- Business, org-unit, and location scopes are editable. The implementation must
  add scoped storage or scoped override rows, effective-value resolution,
  conflict handling, and audit history for each write.
- Remove the top stat/header widget.
- Remove daypart subtitle copy that explains lunch/dinner/late night.
- Add vendor filter for the vendors whose covers or wage data affect the rows.
- Add a better sort model: business, hierarchy path, location, vendor, override
  status, last changed.
- Reorganize content into three blocks: Covers, Wage, Logs.
- Move Walk-ins into the Covers block.
- Logs show actor name and role, not just `Admin user`.

### Polling Setup

- Rename `Polling & pricing` to `Polling Setup`.
- Remove the top stat widget and dense F&F-controlled subtitle.
- Keep a plain-English "About this surface" widget.
- Tier definitions use `Regular`, not launch/operator jargon.
- Add a polling cost calculator. Direct key-in can remain as an override, but
  the main path should estimate cost from understandable inputs.
- Add a vendor filter for vendors that require polling.
- Poll-only vendors default to the Regular/Standard tier when no assignment
  exists.
- Business, org-unit, and location scopes are editable. The implementation must
  add scoped assignment/effective-value resolution and audit history.

### People, Access, Roles

- Remove the visible members stat widget.
- Permission catalogs should read as human permissions by default.
- Raw permission keys can remain in tooltips/details for debugging, not primary
  scan text.
- Active sessions should read like people and devices, not raw session records.
- Filter styling should match the shared setup workspace.

### Security, Audit, Support

- Group actions by intent: account recovery, session control, data protection,
  audit/export.
- Audit actors show name, role, and email across all log surfaces.
- Support logs explain Requests, Relationship help, and Account help.
- Relationship help and Account help are wired now.
- Decide whether the older Support Workspace remains as a hidden route. It
  should not silently fall back to Business Accounts when a handoff targets it.

### Connected Services

- Divide vendor integrations into POS, Labor, and Reservation.
- Show live status based on API reachability, not only static `Documented` rows.
- Service keys show plaintext only once after rotation, then stay hidden.
- Service access and shared services need short plain-English descriptions.
- Unlocking integrations when live must be tied to API reachability.

### System Health, Metrics, Launch Controls, Knowledge Base

- System Health explains Advisor data, App service, and Ecosystem checks.
- Service checks need a plain-English definition.
- System Metrics moves to AI as `AI Metrics`.
- System Health and System Metrics should keep the central run button and avoid
  middle stat widgets that duplicate the dialog.
- Launch controls should avoid control IDs in primary UI and use plain-English
  labels/descriptions.
- Knowledge Base should hide hashes, source file names, and index language from
  primary UI unless expanded for support diagnostics.
- Relationship review needs clearer states and next actions.
- Plans and Limits follows the same hierarchy selector model and keeps raw quota
  IDs or plan internals behind advanced details.

## Implementation Design Backlog

These are not product blockers, but the implementation slices must choose and
document them before merging.

| Design choice | Needed before |
|---|---|
| Exact database shape for scoped Data Accuracy overrides and inheritance. | Data Accuracy scoped mutation slice |
| Exact database shape for scoped Polling assignments and inheritance. | Polling scoped mutation slice |
| Exact calculator fields and rounding for vendor API cost. | Polling Setup calculator writes |
| Whether the hidden Support Workspace route is removed or explicitly registered. | Shared routing seam |
| Whether actor identity is denormalized into audit rows or joined at read time. | Cross-log actor display |
| Relationship help and Account help table/API names and permissions. | Support logs tab cleanup slice |
| Should org-unit labels be auto-generated from display names? | Hierarchy management UX slice |
