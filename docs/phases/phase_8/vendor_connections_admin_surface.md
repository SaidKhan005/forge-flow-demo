# Vendor Connections — Surface Design

Updated: 2026-05-03
Status: Planned (widget lands as part of Phase 8 `8.0` framework slice; F&F Ops Console mounts at Phase 8 launch; Operator Web Console mounts at Phase 11W `11W.8`)
Owner: Phase 8 framework lane

This doc specifies the per-(operator, location) Vendor Connections surface where vendor integrations (POS, Reservations, Scheduling) are configured. The widget tree is **dual-surface hosted** — same widget code, two host shells:

- **F&F Operations Console** (Phase 11A) — F&F internal staff (`forge_admin` / `ff_support`) configure connections cross-operator during onboarding or support escalations.
- **Operator Web Console** (Phase 11W) — operator senior roles (`operator_admin` / `operator_owner`) self-serve their own operator's connections.

The operator-facing mobile app has no integration configuration page; only a `kDemoMode` banner indicating which mode the data is in.

## Dual-surface hosting

| Console | Host shell | URL pattern | User roles | Scope |
|---|---|---|---|---|
| F&F Operations Console (Phase 11A) | `lib/admin/screens/...` | `admin.forgeflow.app/operators/[op]/locations/[loc]/vendor-connections` | `forge_admin`, `ff_support` (read-only) | Cross-operator |
| Operator Web Console (Phase 11W) | `lib/operator_web/screens/...` | `app.forgeflow.app/locations/[loc]/vendor-connections` | `operator_admin`, `operator_owner` | Single-operator (own only) |

The widget code itself is shared and operator/location-aware via host context. Proposed shared path: `lib/integrations/ui/vendor_connections/` (finalized in Phase 8 `8.0` slice). RLS via `OperatorScopedRepository` enforces scoping — operator_admin sees their own operator only; forge_admin sees all via admin-role RLS bypass.

Both shells consume the same backend routes (Cloud Run admin endpoints under `/v1/admin/integrations/*`). `forge_admin` requests carry `service_role` for cross-operator queries; `operator_admin` requests are scoped to their own operator via session claims.

## Where it lives in each console

```
F&F Operations Console (Phase 11A)
├─ Connected services        ← existing tab; F&F infra-keys (Anthropic / Voyage / Azure / Gemini)
└─ Operators
   └─ [Operator]
      └─ Locations
         └─ [Location]
            ├─ Overview
            ├─ ...
            └─ Vendor connections     ← shared widget mounted here
               ├─ POS section
               ├─ Reservations section
               └─ Scheduling section


Operator Web Console (Phase 11W)
├─ Members
├─ Roles
├─ Locations
│  └─ [Location]
│     ├─ Overview
│     └─ Vendor connections           ← shared widget mounted here
│        ├─ POS section
│        ├─ Reservations section
│        └─ Scheduling section
├─ Sessions
├─ Audit Log
├─ Security
└─ Account
```

The existing "Connected services" tab in the F&F Ops Console stays as-is — its scope is F&F's own platform infrastructure secrets (the keys F&F itself uses to call Anthropic/Voyage/etc.). Vendor connections are operator-scoped and live in the new dual-surface widget.

The **placeholder vendor-connector rows** in the existing "Connected services" tab (currently empty) are removed when this widget lands. The FX-rate / email rows in that tab wait on Phase 9.8 for their own home decision.

## Page structure

Each location's "Vendor connections" page is one screen with three sections (POS, Reservations, Scheduling). Each section shows one card corresponding to that category's connection state for the location. Empty state when no vendor is selected, full card when a vendor is connected.

## UX writing standard for this surface

This surface is operator-facing and most operators will hit it once a quarter at most. Every action, status, button, and error message follows the F&F UX writing standard so the surface itself trains the operator as they use it. See `memory/project_ux_writing_standard.md` for the rule. Concretely:

**Buttons get a 1-line "what this is" header and a 1 to 2 sentence "what happens when you click" explainer.** Example for Connect:

> **Connect to Toast**
> When you click below, Toast will ask you to sign in to your Toast account and confirm Forge & Flow can read your orders. We never see your password. After you confirm, we start pulling the last 60 days of sales so your dashboard has historical context.
> [Sign in with Toast]

**Status badges have tooltips** explaining what the state means and what to do (covered in Status states below).

**Error messages explain what happened, why, and what to do next.** Example:

> **Toast revoked our access**
> This usually means someone changed the Toast password or revoked an integration in your Toast portal. Your historical data is safe.
> Click Reconnect Toast and sign in with your current password. We will fill any gap from when sync broke.

**Empty states explain context and suggest the next step.** Example for empty POS card:

> **Connect your Point-of-Sale system**
> Forge & Flow needs to read sales and order data from your POS to power your dashboard, baseline math, and Shift live view. We support 7 POS systems. Pick yours and we walk you through connecting it.
> [Choose your POS]

**Confirmation dialogs explain consequences as bullets, not paragraphs.** Already shown in the Disconnect flow section.

Engineering must include the operator-facing copy in the slice that ships the screen, not as a follow-up. Acceptance criterion: a manager who has never used Forge & Flow can navigate the surface without engineering glossary support.

## Per-vendor card layout

```
┌──────────────────────────────────────────────────────────────────┐
│ [logo]  Lightspeed Restaurant K-Series         [Connected ✓]    │
│                                                                  │
│ Last sync: 2 min ago · 47 orders · 0 errors                     │
│ Webhook URL: https://api.forgeflow.app/v1/webhooks/lsk/[abc...] │
│ [Copy]                                                           │
│                                                                  │
│ [Test connection] [Reconnect] [Disconnect] [View logs]          │
│                                                                  │
│ ▾ Configuration (collapsed by default)                          │
│   Poll interval: 5 min                                           │
│   Backfill window: 60 days                                       │
│   Revenue centers: All                                           │
│   Role mapping: 12 roles → FOH/BOH/manager [Edit mappings]      │
└──────────────────────────────────────────────────────────────────┘
```

**Header**: vendor logo + display name + status badge.
**Body**: last-sync metadata; webhook URL with Copy button (when applicable).
**Action row**: Test / Reconnect / Disconnect / View logs.
**Configuration drawer** (collapsed): poll interval, backfill window, vendor-specific knobs (revenue centers, role mappings, module selection).

## Status states

V1 keeps the state machine simple: 3 states plus a demo-mode display state. Each badge has a tooltip explaining what the state means and what the operator should do, written in plain English so the operator does not need engineering glossary support.

| State | Badge | What it means | What the operator should do |
|---|---|---|---|
| **Connected** | green check | Live data is flowing. Sync is healthy. Last sync timestamp visible on the card. | Nothing. Things are working. |
| **Disconnected** | grey | Sync is paused. Historical data stays. New events from the vendor are not coming in. | Click Reconnect to resume. |
| **Error** | red | Something is wrong. Most often the vendor revoked our access (for example, someone changed the password in the vendor's portal). | Usually fixed by clicking Reconnect and signing back in. Click the badge for the specific reason and remediation steps. |
| **Demo** | blue info | This location is in demo mode. Live data only flows after a vendor is connected for this category. | Connect a vendor to switch to live data. |

V1 explicit non-goals: `connecting` transient state, `degraded` warning state. These are added later when monitoring justifies them. Until then, in-flight OAuth shows as "Connected (first backfill running)" via the card's last-sync metadata, and intermittent failures are caught by the OAuth refresh cron and surface as `Error` only on 3 consecutive failures.

## Connect flow

The first-time connect for an empty section:

```
[Empty state in POS section]
  "No POS connected for this location."
  [Connect a POS]  ← button

  ↓ (click)

[Vendor picker dialog]
  "Which POS does this location use?"
  → dropdown: Lightspeed K-Series ▾
                Toast
                Square
                Clover
                Revel
                Aloha (NCR Voyix)
                Oracle MICROS Simphony
  
  [Some vendors require partner approval — flagged in dropdown]
  
  → [Continue]

  ↓ (per vendor)

[Module disambiguation dialog — only for ADP / QuickBooks]
  "Which ADP product does this location use?"
  → ADP Workforce Now ▾
    ADP Workforce Manager
    ADP RUN — not supported
  
  → If RUN selected: dialog explains "RUN is payroll-only; please pick a
    different scheduling vendor" and aborts the flow.

  ↓

[OAuth-led flow for vendors that support it]
  Redirect to vendor OAuth → callback at /v1/admin/integrations/oauth/{vendor}/callback
  → Token exchange → vendor_credentials row written → return to admin console
  → Card flips to "Connected" state, first backfill starts in background

[Key-paste flow for legacy auth (Humanity v1, etc.)]
  → Form: paste API key + (if needed) username
  → Validate against vendor → vendor_credentials row written
  → Card flips to "Connected" state
```

### Pick-then-show vs browse-then-pick

**Pick-then-show.** Operator clicks "Connect a POS" → vendor picker dialog → choose one → that vendor's card renders. This avoids cluttering the page with 7 disconnected POS cards. To switch vendor later, "Switch vendor" action in the configuration drawer.

## Test connection (heavy on-demand)

Two tiers:

- **Light auth-check on page load** (5-min cached). Hits vendor's `/me` or auth-validation endpoint to confirm credentials are still valid. Updates status badge.
- **Heavy sample-pull on button press**. Operator clicks "Test connection" → adapter pulls a real sample order/reservation/punch from yesterday → displays in a modal. **No fixed response-time SLA at V1** — surfaces within the client's 30s default timeout. Vendor APIs are not consistently fast enough to honor a 5-second hard SLA; tightening the SLA later is purely additive.

```
┌──────────────────────────────────────────────┐
│ Test connection — Lightspeed K-Series        │
│                                              │
│ ✓ Auth valid                                 │
│ ✓ Sample order pulled in 1.2s                │
│                                              │
│ Sample: Order #12345                         │
│   Date: 2026-05-02                           │
│   Total: $42.50                              │
│   Covers: 3                                  │
│   Items: 4                                   │
│                                              │
│ Field mapping: covers → 3 ✓                  │
│                opened_at → 2026-05-02 18:45 ✓│
│                closed_at → 2026-05-02 19:42 ✓│
│                                              │
│ [Close]                                      │
└──────────────────────────────────────────────┘
```

Operator gets confidence that not just auth but the **field mapping** works correctly.

## Disconnect flow

When the operator clicks "Disconnect", the confirmation dialog explains in plain English what will happen:

> **Disconnect Toast for Brio - Chicago Loop?**
>
> When you confirm:
> - Your historical sales data **stays** in Forge & Flow. Nothing is deleted.
> - Live sync **stops** immediately. New orders from Toast will not appear in your dashboard.
> - We **wipe** the credentials we have for Toast and tell Toast to stop sending us your data.
> - If you reconnect Toast later, we resume from where we left off, so you do not need to re-pull 60 days.
>
> [Cancel]   [Yes, disconnect Toast]

Behind the scenes: live sync stops, stored credentials are wiped from `vendor_credentials`, the sync watermark is preserved so reconnect resumes from the last successful point, and the webhook subscription is unregistered via the vendor's API where supported. Audited row is written to `audit_logs`.

A separate **"Forget all data from this connector"** advanced action exists with stronger confirmation (re-type vendor name) for compliance scenarios. Rare. Gated behind `forge_admin` only, not `operator_admin`.

## Multi-location connect flow

Different vendors have different rules about how authentication and identity scope work. V1 supports two patterns and the connect-flow UI adapts based on the vendor's declared `grant_scope` in `vendor_capability_profile`.

### Per-location OAuth (Toast, OpenTable)

Each F&F location requires its own separate OAuth flow with the vendor. The operator runs the auth flow once per location they want to connect. Each completed OAuth writes a `vendor_credentials` row with `location_id` set, plus a `connector_connection` row for that (op, loc, vendor).

### Operator-wide OAuth (7shifts, Square, QuickBooks Time, ADP Workforce Now)

A single OAuth grant covers all of the operator's locations on this vendor. After the grant completes, the operator confirms which F&F locations should use this connection through a checkbox list.

When the vendor account contains multiple distinct vendor-side locations (each with its own ID), F&F support handles vendor-side location mapping during onboarding for V1. The operator's vendor account knows which physical restaurants are which; we record those vendor location IDs in `connector_connection.metadata` per F&F location during the onboarding session. One `vendor_credentials` row with `location_id IS NULL`, one `connector_connection` row per enabled F&F location, all sharing the single credential.

V1 keeps mapping simple. Self-service vendor-location-to-F&F-location mapping UI for operators is post-V1, added when operator volume justifies the engineering work.

## Switching vendors

When an operator decides to migrate a location from one vendor to another (for example, Brio Chicago Loop moves from Toast to Lightspeed), V1 supports the simple flow: disconnect the old vendor, then connect the new one. Expect roughly 1 day of data gap during the transition. Historical data from the old vendor stays in canonical tables and is still queryable. The new vendor takes over going forward.

V1 explicit non-goal: simultaneous-overlap migration with primary-source filtering across two active connections. Add this only if operators frequently need to migrate without data gaps. Until then, the simple disconnect-then-reconnect flow handles the rare migration case cleanly.

## Webhook URL provisioning

Per vendor, the framework auto-registers webhook URLs via the vendor's API where possible:

| Vendor category | Auto-register | Manual paste fallback |
|---|---|---|
| Toast, Lightspeed, Libro, Revel, OpenTable | Auto | — |
| Square, Clover | Auto | — |
| 7shifts, QuickBooks Time | Auto where webhooks supported | Manual where not |
| Humanity, Agendrix, Push Operations | Manual paste (no webhook support documented) | Required |
| ADP WFN/WFM | Auto via Marketplace event subscription | — |
| SevenRooms, Tock | Vendor-portal manual paste | Required |

When manual paste is required, the card displays:

```
Webhook URL (paste this into your SevenRooms admin portal):
https://api.forgeflow.app/v1/webhooks/sevenrooms/[operator-id]/[location-id]
[Copy]

Webhook signing secret (paste this into your SevenRooms portal):
hmac-sha256:[hidden, copy-only]
[Copy]

Status: ⚠ Webhook not yet received. After pasting in SevenRooms,
trigger a test event to confirm.
```

Status badge updates from `Connecting (webhook pending)` → `Connected` once first webhook arrives.

## Permission model

A new permission key `integrations.configure` gates this surface. Same key works in both console shells via the role assignments below; RLS handles the operator-scope difference automatically.

Granted to:

- **`forge_admin`** (F&F internal staff) — always. Cross-operator via admin RLS bypass through F&F Ops Console.
- **`operator_admin`** / **`operator_owner`** (operator's GM-level role) — yes, scoped to their own operator's locations only via existing `OperatorScopedRepository` + RLS through Operator Web Console.

Denied to:

- **`location_manager`** (floor manager) — NO. Misconfigured vendor credentials can cascade into broken cost/labor data; reserve for senior roles.
- **`ff_support`** — read-only in F&F Ops Console (can view status, cannot rotate or disconnect). Same pattern as the existing "Connected services" tab.

The permission key is added to `docs/contracts/auth_permission_key_catalog.md` as part of the `8.0` framework slice.

## Module disambiguation

Two scheduling vendors require pre-card module disambiguation:

| Vendor | Modules | Outcome |
|---|---|---|
| **ADP** | Workforce Now / Workforce Manager / RUN | RUN aborts with refusal; others proceed to OAuth |
| **QuickBooks** | Time / Accounting / Payroll | Time proceeds; Accounting redirects to Phase 8.5 surface; Payroll aborts |

Pattern: vendor picker dialog includes the module-bearing vendor but with a "(asks for module)" tag. Selecting it opens a sub-dialog asking which module before proceeding to OAuth.

## Configuration drawer (per-vendor)

Each card has an expandable Configuration section with vendor-agnostic and vendor-specific knobs:

**Common (all vendors)**:
- Poll interval (5 min default; range 1 min - 1 hour)
- Backfill window (60 days default; range 7 days - 365 days)

**POS-specific**:
- Revenue center / dining option filter (where vendor exposes; "All" by default)
- Daypart override (off by default — app owns dayparts; operator can override per location)

**Scheduling-specific**:
- Role mapping (FOH/BOH/manager/excluded for each vendor role; auto-mapped by name heuristic on first connect, override available)
- Wage source (Vendor / App-fallback — readonly indicator)

**Reservation-specific**:
- VIP-tag opt-in (off by default for privacy; future Barrio surface unblocks)

## Logs viewer

"View logs" opens a modal showing the last 100 sync events for this connector:

```
┌──────────────────────────────────────────────────────┐
│ Sync logs — Lightspeed K-Series                      │
│ Brio - Chicago Loop                                  │
│                                                      │
│ Filter: [All events ▾]  Date: [Last 7 days ▾]      │
│                                                      │
│ 2026-05-03 14:32:01 ✓ Polled 3 new orders           │
│ 2026-05-03 14:27:00 ✓ Polled 5 new orders           │
│ 2026-05-03 14:22:00 ⚠ Rate-limit retry (1/3)        │
│ 2026-05-03 14:22:01 ✓ Polled 2 new orders           │
│ ...                                                  │
│                                                      │
│ [Export CSV]                                         │
└──────────────────────────────────────────────────────┘
```

Backed by a `sync_log` table with rolling 90-day retention.

## Identity binding (F&F to vendor IDs)

The architecturally load-bearing concept in this surface is the binding from F&F's internal `(operator_id, location_id)` namespace to each vendor's namespace. Every vendor has its own way of identifying the same physical restaurant. Toast calls it `restaurantGuid`, Lightspeed K-Series calls it `business_id`, OpenTable calls it `rid`, 7shifts has both `company_id` and `location_id`, QuickBooks Time has `realm_id` plus optional `group_id`.

The binding lives in `connector_connection.metadata` (JSONB). Every connection row stores the vendor-side IDs that identify this `(operator_id, location_id)` to that specific vendor. Example for one F&F location across multiple connected vendors:

| Connection | metadata (JSONB) |
|---|---|
| `(brio, loop, toast)` | `{"restaurant_guid": "abc-toast-loop-7c2f"}` |
| `(brio, loop, opentable)` | `{"rid": 8821}` |
| `(brio, loop, seven_shifts)` | `{"company_id": 776, "vendor_location_id": 88812}` |

The binding is consulted on every webhook (signature passes, then the adapter cross-checks the payload's claimed vendor location ID against this stored binding) and on every poll. It is the security check that prevents cross-tenant data leakage from URL-path tampering or vendor mis-routing.

When vendor capability profiles are filled in for new vendors per `7.55j.3` template, they declare which fields go into `metadata` for that vendor.

## Backend contract

### New routes (Phase 8 `8.0` framework slice)

- `GET /v1/admin/operators/:operator_id/locations/:location_id/integrations` — list connected vendors for this location.
- `POST /v1/admin/integrations/oauth/{vendor}/start?operator_id=...&location_id=...` — start OAuth (returns redirect URL).
- `GET /v1/admin/integrations/oauth/{vendor}/callback` — OAuth callback handler.
- `POST /v1/admin/integrations/{vendor}/connect-key` — key-paste auth flow.
- `POST /v1/admin/integrations/{vendor}/test-connection` — heavy sample-pull diagnostic.
- `POST /v1/admin/integrations/{vendor}/disconnect` — wipe credentials, stop sync, optionally unregister webhook.
- `GET /v1/admin/integrations/{vendor}/logs` — sync log viewer.

### New schema (Phase 8 `8.0`)

```sql
-- Per-(operator, location, vendor) connection state
connector_connection (
  connection_id UUID PRIMARY KEY,
  operator_id UUID NOT NULL,
  location_id UUID NOT NULL,
  vendor_id TEXT NOT NULL,                 -- 'toast', 'lightspeed_lsk', etc.
  category TEXT NOT NULL,                  -- 'pos' / 'reservation' / 'scheduling'
  status TEXT NOT NULL,                    -- 'connecting' / 'connected' / 'degraded' / 'disconnected' / 'error'
  module TEXT,                             -- e.g., 'workforce_now' for ADP
  metadata JSONB,                          -- Vendor's external IDs (the binding from F&F to the
                                           -- vendor namespace) plus per-vendor knobs. See the
                                           -- "Identity binding" section for examples.
  last_sync_at TIMESTAMPTZ,
  last_error_at TIMESTAMPTZ,
  last_error_message TEXT,
  webhook_url_provisioned BOOL DEFAULT false,
  created_at, updated_at, created_by, updated_by
)

-- Per-(operator, location, vendor, resource) watermarks
connector_sync_watermark (
  watermark_id UUID PRIMARY KEY,
  connection_id UUID REFERENCES connector_connection,
  resource TEXT NOT NULL,                  -- 'orders' / 'punches' / 'reservations' / 'roles'
  last_synced_at TIMESTAMPTZ,
  last_modified_seen TIMESTAMPTZ,          -- vendor's modified-since cursor
  cursor_token TEXT,                       -- vendor's pagination cursor
  updated_at TIMESTAMPTZ
)

-- Sync event log for the "View logs" viewer
connector_sync_log (
  log_id UUID PRIMARY KEY,
  connection_id UUID REFERENCES connector_connection,
  event_kind TEXT NOT NULL,                -- 'poll_success' / 'poll_error' / 'webhook_received' / 'auth_refresh' / 'rate_limit_retry'
  records_count INT,
  duration_ms INT,
  error_message TEXT,
  payload_preview JSONB,
  occurred_at TIMESTAMPTZ
)
-- Partitioned by occurred_at, 90-day rolling retention via pg_partman.
```

`vendor_credentials` table (already specified in Phase 8.5 plan) is reused — same encrypted-token storage pattern.

## Acceptance criteria

This surface ships as part of `8.0` framework slice. Acceptance:

- All routes functional against staging proxy.
- Pick-then-show flow works for at least the 3 reference vendors (Lightspeed, Libro, QuickBooks Time).
- Heavy test-connection returns sample data within client default timeout (~30s); no fixed sub-30s SLA at V1.
- Module disambiguation flow rejects ADP RUN with the correct refusal message.
- Multi-location apply-to-all flow works for an operator with 2+ test locations.
- Webhook URL display + Copy button works for both auto-register and manual-paste vendor classes.
- Disconnect preserves historical facts; reconnect resumes from preserved watermark. After disconnect, operator-app dashboard metric cards flip to `MetricCardNotYetAvailable` (per `docs/contracts/metric_card_honesty_contract.md`); no phantom zeroes. Top-left dashboard pill summarizes the disconnect state.
- Permission gate: `location_manager` role gets a 403; `operator_admin` and `forge_admin` succeed.
- Demo-mode banner renders correctly in operator app when no vendor is connected at any (operator, location).
- Walkthrough at acceptance is a click-path per `docs/CODEX_PROMPT_GENERATION_STANDARD.md` Walkthrough Specificity section — numbered steps, named widgets, named values.

## Cross-references

- `docs/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` — `8.0` framework slice ships this widget; F&F Ops Console mounts it at Phase 8 launch.
- `docs/phases/phase_11W/phase_11W_operator_web_console_plan.md` — Operator Web Console; `11W.8` mounts this widget operator-side.
- `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md` — F&F Operations Console; the host shell that mounts this widget cross-operator.
- `docs/phases/phase_8/vendor_master_list.md` — vendor list, partnership applications, source URLs.
- `docs/phases/phase_8R/phase_8R_official_reservation_connector_plan.md` — reservation cards plug into this surface.
- `docs/phases/phase_8S/phase_8S_scheduling_connector_plan.md` — scheduling cards plug into this surface.
- `docs/phases/phase_8_5_external_integrations/phase_8_5_external_integrations_plan.md` — Phase 8.5 finance integrations follow the same dual-surface hosting pattern (different widget tree, same two consoles).
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` — RLS / OperatorScopedRepository pattern that connection state follows.
- `docs/contracts/auth_permission_key_catalog.md` — `integrations.configure` permission key (added by `8.0`).
