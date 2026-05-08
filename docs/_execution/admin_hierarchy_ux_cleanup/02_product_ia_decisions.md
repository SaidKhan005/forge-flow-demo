# Product And IA Decisions

## Current Product Rule

Business setup is hierarchy-first, function-second.

The admin should not be asked to choose scope in a popup after clicking a setup
tile. Instead, the selected business hierarchy row is the current scope. If no
row is selected, the current scope is the selected business.

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
- Clarify whether poll-only vendors default to the Regular/Standard tier when
  no assignment exists.

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
- Audit actors show name and role across all log surfaces.
- Support logs explain Requests, Relationship help, and Account help.
- If Relationship help or Account help are not wired, label them honestly as not
  available yet and describe where the current workflow lives.
- Decide whether the older Support Workspace remains as a hidden route. It
  should not silently fall back to Business Accounts when a handoff targets it.

### Connected Services

- Divide vendor integrations into POS, Labor, and Reservation.
- Show live status and health source, not only static `Documented` rows.
- Service keys show plaintext only once after rotation, then stay hidden.
- Service access and shared services need short plain-English descriptions.
- Unlocking integrations when live must be tied to vendor lifecycle state and
  health, not hard-coded copy.

### System Health, Metrics, Launch Controls, Knowledge Base

- System Health explains Advisor data, App service, and Ecosystem checks.
- Service checks need a plain-English definition.
- System Metrics should move to AI as `AI Metrics` if the surface is only AI
  cost/model/usage telemetry.
- System Health and System Metrics should keep the central run button and avoid
  middle stat widgets that duplicate the dialog.
- Launch controls should avoid control IDs in primary UI and use plain-English
  labels/descriptions.
- Knowledge Base should hide hashes, source file names, and index language from
  primary UI unless expanded for support diagnostics.
- Relationship review needs clearer states and next actions.

## Product Decision Backlog

| Decision | Needed before |
|---|---|
| Are business/org-unit Data Accuracy edits in scope now, or do we ship read-only rollups first? | Data Accuracy scoped mutation slice |
| Are business/org-unit Polling Setup edits in scope now, or do we ship read-only rollups first? | Polling scoped mutation slice |
| What exact calculator inputs are authoritative for vendor API cost? | Polling Setup calculator writes |
| What source owns Connected Services live health? | Connected Services live status slice |
| Should the hidden Support Workspace route be removed or explicitly registered? | Shared routing seam |
| Should audit actor names/emails be denormalized, joined at read time, or kept privacy-preserving? | Cross-log actor display |
| Should System Metrics move under AI as AI Metrics? | System nav rename/move slice |
| What is the MVP for Relationship help and Account help in Support logs? | Support logs tab cleanup slice |
| Should org-unit labels be auto-generated from display names? | Hierarchy management UX slice |
