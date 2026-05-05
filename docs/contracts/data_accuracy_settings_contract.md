# Data Accuracy Settings Contract

Status: **Active authority** (Tier-2 contract)
Updated: 2026-05-04
Owner: Phase 8 spine-bridge sprint
Authority position:

- Below `docs/contracts/core_app_architecture.md` (Layer 2 + Layer 6
  bind to this contract for operator-controlled accuracy overrides)
- Below `docs/contracts/metric_card_honesty_contract.md` (provenance
  rules; this contract specifies the exact provenance strings)
- Beside `docs/contracts/integration_spine_architecture_contract.md`
  (the spine binds to this for cover/wage/cadence override resolution)

When this doc and a slice doc conflict, this doc wins.

## Why this exists

The architecture exposes three operator-controlled accuracy seams that
sit at the canonical-fact resolution boundary in the integration spine:

1. **Covers source** — when the POS vendor doesn't expose covers, the
   operator chooses between (a) F&F-derived forecast covers
   substitution and (b) manual entry per (business_date, daypart).
2. **Wage source** — when the labor vendor doesn't expose dollars, the
   operator chooses between (a) target wage × hours substitution and
   (b) manual wage-mix from `wage_role_rows`.
3. **Polling cadence + costing** — operator sets per-(operator,
   location, vendor) polling cadence above the framework default, with
   cost projection surfaced before commit.

Without this contract, those overrides would either be ad-hoc widget
state (architecture violation) or implicit default behavior (operator
can't trust their own dashboard). This contract makes the seams
first-class: schema-backed, RLS-isolated, surfaced through dedicated UI
on both the operator web console and the F&F Ops Console.

## Polling cadence — F&F-controlled tier model (binding)

**REVERSAL 2026-05-05.** Earlier drafts of this contract framed polling
cadence as a pure "cost pass-through" with operator-controlled cadence
per vendor. **That framing is REPLACED.** The new binding rule:

**F&F controls polling cadence per (operator, location) via tier
assignment.** F&F is the unit-economics arbiter. Vendor API costs are
absorbed by F&F and packaged into F&F's own tier pricing. The operator
sees tier names + tier prices, NOT vendor API per-call costs.

Per-location is normative — `connector_connection` rows are per
`(operator, location)`, so polling tier assignment is too. An operator
with three locations can have three different tiers (e.g., flagship
downtown on Premium, two satellite locations on Standard).

### Transport-bounded live-ness (unchanged)

### Transport-bounded live-ness

How "live" the operator's dashboard feels is bounded by the transport,
not by the polling setting:

- **Webhook vendors** (Toast, Square, Clover, Lightspeed K-Series,
  Revel, Aloha NCR Voyix, 7shifts, ADP, Libro, OpenTable, SevenRooms,
  Tock — i.e. every vendor with `webhookSupport in {autoRegister,
  manualPaste}`) push updates in real time. Polling cadence is
  **irrelevant** for these vendors. Note: ADP is `autoRegister` per
  the Wave B adapter capability profile (verified 2026-05-04 against
  `lib/integrations/labor/adp_labor_adapter.dart` line 561), NOT
  `pollOnly` as some earlier drafts described. The dashboard is as live as the
  webhook arrives (seconds, typically).

- **Poll-only vendors** (Oracle MICROS Simphony, QuickBooks Time,
  Humanity, Agendrix, Push Operations — i.e. every vendor with
  `webhookSupport == pollOnly`; **5 vendors total**, not 6) update only
  at the polling interval.
  The dashboard lags by up to that cadence. Set Oracle to 5 minutes
  → Oracle data lags up to 5 minutes; everything from your webhook
  vendors is still live within seconds.

The polling cadence picker on the Operator Web Console **only renders
poll-only vendors**. Webhook vendors do not appear; the picker would
have no effect on them.

### F&F controls cadence; operator sees tiers, not vendor calls (REVERSED)

**Old rule (REVERSED):** "F&F does NOT tier its own price by cadence."

**New binding rule:** F&F controls polling cadence per (operator,
location) via tier assignment. Operator-facing surface shows tier
name + tier price, NOT vendor per-call cost. F&F absorbs vendor API
costs (Oracle Simphony per-call charges; Cloud Run worker cost;
internal margin) and packages them into tier pricing.

**Three reference tiers** (final pricing TBD by F&F billing decision):

| Tier | Polling cadence | Use case |
|---|---|---|
| `standard` | Webhook vendors: real-time. Poll-only vendors: vendor-minimum cadence (Oracle 5min; QBT/Humanity/Agendrix/Push 5min default) | Default for new operators; subscription includes |
| `premium` | Webhook vendors: real-time. Poll-only vendors: 60s where vendor allows, vendor-minimum where not | Higher subscription tier; tighter mid-service awareness |
| `custom` | F&F admin sets cadence per vendor for this (operator, location) | Negotiated; uncommon |

**Operator-facing UX (Lane `.B`):** the polling card on the operator
web Data Accuracy tab is **display-only + request-change** flow.
Operators see "Your current tier: Standard. Polling cadences: Oracle
Simphony 5 min, QuickBooks Time 5 min." They DO NOT pick cadences in
the picker. To change tier, the card surfaces a "Request tier change"
button that opens a support ticket / billing-upgrade flow.

**F&F admin UX (Lane `.C`):** F&F Ops Console gains a new
per-(operator, location) tier-assignment surface. forge_admin role
required. Tier change writes audit_logs row. Cost-rollup panel shows
F&F's own vendor API spend per location per month + margin (tier
price - vendor cost).

This rule is binding. Any future surface that gives operators a
direct cadence picker violates this contract.

### Two cost buckets

When the operator picks a cadence, the cost projection card shows the
$/month projection for that cadence in one of two buckets:

| Bucket | Vendors | Cost projection shape |
|---|---|---|
| Per-call charge | Oracle MICROS Simphony | Real $/month: `polls_per_month × cost_per_poll_request`. Cited from `api_consumed.md` pricing. (ADP previously listed here was wrong — ADP is webhook-driven autoRegister; not subject to polling cadence.) |
| Subscription-bucket | QuickBooks Time, Humanity, Agendrix, Push Operations | "$0/month additional — polling is included in your <vendor> subscription." Cited from the vendor's subscription pricing in `api_consumed.md`. |
| Pricing pending verification | All 5 poll-only vendors | The exact per-vendor pricing classification is subject to a queued vendor-research pass (see `session_handoff.md` 2026-05-04 entry). The Data Accuracy tab MUST render "Pricing pending — confirm with your account rep" instead of an estimated dollar amount until each vendor's `api_consumed.md` "Pricing" section is populated by the research pass. |

The bucket classification per vendor lives in
`docs/integrations/<vendor_id>/api_consumed.md` "Production environment
→ Rate-limit policy" + "Pricing" sections. The Data Accuracy tab reads
that classification at render time.

### Acknowledgement model

The resolver only honors a non-default cadence override after the
operator explicitly stamps `polling_cost_acknowledged_at`. Mechanism:

1. Operator picks a cadence in the picker.
2. Cost projection updates inline.
3. "Confirm and apply" button is the only path that writes both the
   override AND the acknowledgement timestamp.
4. If the operator changes the cadence later, the timestamp gets
   re-stamped on the next "Confirm and apply" — no silent
   reacknowledgement.
5. Resolver behavior when the override exists but the timestamp is
   null: ignore the override; use default; emit
   `cadence_override_unacknowledged` sync log row. Defensive default
   for any path that writes the override directly without going
   through the picker.

### Vendor min/max clamping

The resolver clamps every override to the vendor-allowed range:

- **Vendor minimum** comes from each vendor's documented rate-limit
  policy (Oracle Simphony documents 5min minimum; cited in
  `docs/integrations/oracle_micros_simphony/api_consumed.md`).
- **Framework maximum** is 3600s (1 hour) — beyond this the dashboard
  feels broken.
- An override outside the allowed range is clamped, NOT rejected. The
  resolver emits `cadence_override_clamped` sync log so the operator
  + ops can see what actually applied.

The operator cannot set Oracle to 60s by being willing to pay more;
the floor is the vendor's, not F&F's.

## Surface scope

### Operator Web Console — "Data Accuracy" tab

Mounted at `/data-accuracy` on `app.forgeflow.app` (the operator web
console; Phase 11W). Lives alongside Account / Vendor Connections in
the side nav.

The tab carries four cards in this order:

1. **Wage source card** — surfaces the existing wage adjuster (currently
   in mobile Settings) on web. Operator picks: "Use labor vendor's
   reported wages and dollars when available" (default) OR "Use my
   manual wage mix from Settings (the same rates the wage generator
   uses)". Vendor relativity label: "This setting applies when your
   labor vendor (currently: <vendor_displayname>) does not expose
   per-shift dollars. Vendors that do not expose dollars at V1: <list>."
2. **Covers source card** — per-daypart toggle. Three states: vendor /
   forecast / manual. When `manual` is chosen for a daypart, an inline
   sub-card opens for entering today's manual covers (lunch / dinner /
   late_night). Operator can copy yesterday's manual entry to today as
   a one-tap shortcut. Vendor relativity label: "This setting applies
   when your POS vendor (currently: <vendor_displayname>) does not
   expose covers as a first-class field. POS vendors that do not
   expose covers at V1: Square, Clover."
3. **Polling cadence card** — per-vendor cadence picker for poll-only
   vendors only (webhook vendors are filtered out per the
   transport-bounded live-ness rule above). Default cadence per vendor
   displayed (e.g., "Oracle Simphony: 5 minutes (vendor minimum)").
   Operator can pick faster or slower cadence within vendor-allowed
   bounds. Cost projection per the two-bucket model: real $/month for
   per-call vendors, "$0/month additional — included in your
   subscription" for subscription-bucket vendors. **Plain-English
   framing:** "F&F doesn't charge more for faster polling; this is
   what your vendor will charge for the additional API calls. Pick
   what feels right." Operator must hit "Confirm and apply" to stamp
   `polling_cost_acknowledged_at`. Vendor relativity label: "Polling
   cadence applies to vendors that do not push real-time webhooks
   (currently: Oracle MICROS Simphony, QuickBooks Time, Humanity,
   Agendrix, Push Operations). Your webhook vendors update in real
   time regardless of this setting."
4. **What this means card** — a brief inline explainer (per the UX
   writing standard `memory/project_ux_writing_standard.md`) that
   walks the operator through each setting in plain English with one
   example per setting.

### F&F Ops Console — per-location admin surface

Mounted at `/data-accuracy` on `admin.forgeflow.app` (Phase 11A).
Cross-operator visibility for support; per-location override capability
gated by `forge_admin` role + audit logged.

The admin surface has **two top-level tabs**: Data Accuracy
(operator-controlled overrides — covers source / wage source / walk-in
handling / 60-day seed) and Polling & Pricing (F&F-controlled tier
assignment + cost / margin rollup).

#### Tab 1: Data Accuracy (per-location overrides)

- Per-location data accuracy settings table (operator, location, covers
  source per daypart, wage source, walk-in handling mode, last modified
  by, last modified at).
- Audit history of admin overrides per operator.

#### Tab 2: Polling & Pricing (F&F-controlled, well-labeled)

The pricing surface is the F&F-internal control plane for the polling
tier model. Operators NEVER see this tab — `forge_admin` role only.

**Plain-English explainer card (always visible at top):**

> Polling cadence is how often F&F checks each vendor for new data.
> Webhook vendors (Toast, Square, Clover, Lightspeed, Revel, Aloha,
> 7shifts, ADP, Libro, OpenTable, SevenRooms, Tock) push updates in
> real time — cadence doesn't apply. Poll-only vendors (Oracle MICROS
> Simphony, QuickBooks Time, Humanity, Agendrix, Push Operations)
> update only at the cadence we set here.
>
> F&F absorbs vendor API costs and packages them into operator-facing
> tier prices. Operators see a tier name and a tier price on their
> bill — they don't see vendor per-call costs. This panel is where
> we set the cadences, the prices, and the cost basis.

**Card 1: Tier definitions (F&F-engineering presets)**

Three reference tiers. Defaults baked in code; admin can edit
per-tier without re-deploying.

| Field | Label shown to admin | Notes |
|---|---|---|
| `tier_key` | "Tier name" | `standard` / `premium` / `custom` |
| `description_md` | "What this tier includes" | free text + structured cadence list |
| `polling_cadence_per_vendor_seconds` | "Polling cadence per vendor (poll-only vendors only)" | per-vendor JSONB; rendered as table: vendor name + cadence in human format ("5 minutes" / "60 seconds") |
| `default_monthly_price_cents` | "Default tier price (USD/month/location)" | F&F's monthly billing; displayed as $X.XX |
| `vendor_api_cost_estimate_cents_monthly` | "Vendor API cost basis (USD/month/location)" | F&F's internal cost-of-goods estimate; displayed as $X.XX |
| `default_margin_cents` | "Default margin (USD/month/location)" | computed: price − cost; displayed with green/red color when positive/negative |
| `last_edited_at` / `last_edited_by` | "Last edited" | timestamp + admin id |

**Card 2: Per-(operator, location) tier assignment table**

Admin browses every operator-location and sees / edits assignments.

| Column | Label | Editable? |
|---|---|---|
| Operator | "Operator" | no (link out) |
| Location | "Location" | no |
| Current tier | "Tier" | yes (dropdown: standard / premium / custom) |
| Effective since | "Active since" | no (display) |
| Custom cadence override | "Custom cadences" | yes IFF tier=custom; per-vendor JSONB editor |
| Price override | "Price override (USD/month)" | yes; null = use tier default |
| Cost basis override | "Cost basis override (USD/month)" | yes; null = use tier default |
| Net margin (computed) | "Net margin" | display only |
| Notes | "Admin notes" | yes (free text; admin-only) |
| Action | "Assign / Update" | writes audit row |

Filter bar: by operator name, by tier, by location count, by margin
band (positive / break-even / negative).

**Card 3: Margin rollup**

| Metric | Label |
|---|---|
| Total monthly tier revenue | "Total monthly tier revenue (USD)" — sum across all assignments |
| Total monthly vendor API cost basis | "Total monthly vendor API cost basis (USD)" |
| Net monthly margin | "Net monthly margin (USD)" — green if positive, red if negative |
| Margin % | "Margin %" — net / revenue |
| Per-tier breakdown | small table: tier name, count of assignments, revenue, cost, margin |
| Per-vendor cost breakdown | small table: vendor name, total monthly cost basis across all locations, % of total cost |

Export-to-CSV button (forge_admin only).

**Card 4: Tier change requests (operator-submitted)**

Lists operator "Request tier change" tickets from Lane `.B`.

| Column | Label |
|---|---|
| Operator + location | "Operator / location" |
| Current tier | "Current tier" |
| Requested tier | "Requested tier" |
| Operator note | "Operator's reason" |
| Submitted at | "Submitted" |
| Status | "Status" — pending / approved / denied / negotiating |
| Action | "Approve" / "Deny" / "Open negotiation" — writes audit row + closes the ticket |

**Card 5: Audit history**

Per-operator-location audit log of every tier change. Diff display
shows prior tier → new tier, prior price → new price, prior cost basis
→ new cost basis. Admin actor + timestamp + reason note.

**Hard rule:** every write on the Polling & Pricing tab MUST insert
into `audit_logs` with `actor_kind = 'forge_admin'`, the diff payload,
and the reason note. No silent edits.

#### Both tabs

Admin overrides write `audit_logs` rows with
`actor_kind = 'forge_admin'` and the diff captured in the audit row
payload.

## Schema

Single new table `public.data_accuracy_settings`:

```sql
create table if not exists public.data_accuracy_settings (
  setting_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,

  -- ── Covers source per daypart ─────────────────────────────────────
  -- One of: 'vendor' (default), 'forecast', 'manual'.
  covers_source_lunch text not null default 'vendor'
    check (covers_source_lunch in ('vendor', 'forecast', 'manual')),
  covers_source_dinner text not null default 'vendor'
    check (covers_source_dinner in ('vendor', 'forecast', 'manual')),
  covers_source_late_night text not null default 'vendor'
    check (covers_source_late_night in ('vendor', 'forecast', 'manual')),

  -- Manual entries per (business_date, daypart) when covers_source = 'manual'.
  -- jsonb shape: {"2026-05-04": {"lunch": 87, "dinner": 187, "late_night": 12}, ...}
  -- Sparse — only populated dates need entries. Missing date + manual setting =
  -- aggregator returns null for that daypart (no ShiftRecord written).
  covers_manual_entries jsonb not null default '{}'::jsonb
    check (jsonb_typeof(covers_manual_entries) = 'object'),

  -- ── Wage source ────────────────────────────────────────────────────
  -- 'vendor' (default; use labor vendor dollars when exposed) OR
  -- 'manual_mix' (always use wage_role_rows mix; ignore vendor dollars).
  wage_source text not null default 'vendor'
    check (wage_source in ('vendor', 'manual_mix')),

  -- ── Polling cadence (REVERSED 2026-05-05) ─────────────────────────
  -- Per the F&F-controlled tier model (above), polling cadence is NOT
  -- operator-controlled. It is set by F&F admin via a separate table
  -- `forge_flow_polling_tier_assignment` (see schema below). This row
  -- carries no polling-cadence fields. The earlier
  -- `polling_cadence_override_seconds` + `polling_cost_acknowledged_at`
  -- columns are NOT shipped — F&F admin controls cadence directly.

  -- ── Audit ──────────────────────────────────────────────────────────
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text,

  constraint data_accuracy_settings_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

-- One row per (operator, location).
create unique index if not exists data_accuracy_settings_unique_idx
  on public.data_accuracy_settings (operator_id, location_id);

-- Operator-leading B-tree per RLS-Ready Schema rules.
create index if not exists data_accuracy_settings_operator_idx
  on public.data_accuracy_settings (operator_id, location_id);

-- RLS — wrapper-only per Phase 9.0Σ.b item 4.
alter table public.data_accuracy_settings enable row level security;

drop policy if exists "data_accuracy_settings_per_tenant"
  on public.data_accuracy_settings;
create policy "data_accuracy_settings_per_tenant"
  on public.data_accuracy_settings for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.data_accuracy_settings from public;
grant select, insert, update on public.data_accuracy_settings to service_role;
grant select, insert, update on public.data_accuracy_settings to forge_admin;
```

### Polling tier assignment table (NEW 2026-05-05)

Per the F&F-controlled tier model. Per (operator, location) — same
key as `data_accuracy_settings`.

```sql
create table if not exists public.forge_flow_polling_tier_assignment (
  assignment_id uuid primary key default gen_random_uuid(),
  operator_id uuid not null,
  location_id uuid not null,

  -- Tier key: 'standard' | 'premium' | 'custom'.
  tier_key text not null
    check (tier_key in ('standard', 'premium', 'custom')),

  -- Resolved cadence per vendor, seconds. F&F admin sets directly for
  -- 'custom'; for 'standard' / 'premium', the resolver reads from a
  -- F&F-maintained tier definitions table (out of scope for this
  -- contract; defaults to 'standard' presets baked in code).
  -- jsonb shape: {"oracle_micros_simphony": 300, "quickbooks_time": 60, ...}
  polling_cadence_per_vendor_seconds jsonb not null default '{}'::jsonb
    check (jsonb_typeof(polling_cadence_per_vendor_seconds) = 'object'),

  -- F&F's monthly price for this assignment, in cents. Null when
  -- billing is bundled with another product (grandfathered, comped,
  -- enterprise contract).
  monthly_price_cents integer
    check (monthly_price_cents is null or monthly_price_cents >= 0),

  -- F&F's internal vendor API cost basis for this assignment, in cents
  -- per month. Null when not yet measured. NOT operator-facing —
  -- internal margin analysis only.
  vendor_api_cost_estimate_cents_monthly integer
    check (vendor_api_cost_estimate_cents_monthly is null
           or vendor_api_cost_estimate_cents_monthly >= 0),

  effective_at timestamptz not null default now(),
  effective_until timestamptz,  -- null = currently active
  assigned_by_admin_user_id text,  -- forge_admin actor id
  created_at timestamptz not null default now(),

  constraint forge_flow_polling_tier_operator_location_fk
    foreign key (operator_id, location_id)
    references public.locations(operator_id, location_id)
    on delete cascade
);

-- One CURRENTLY-EFFECTIVE assignment per (operator, location).
-- History is preserved; effective_until null marks current.
create unique index if not exists forge_flow_polling_tier_current_idx
  on public.forge_flow_polling_tier_assignment (operator_id, location_id)
  where effective_until is null;

create index if not exists forge_flow_polling_tier_operator_idx
  on public.forge_flow_polling_tier_assignment (operator_id, location_id, effective_at desc);

-- RLS — wrapper-only; service_role + forge_admin only (operator never reads
-- this table directly; operator-facing tier name comes through
-- data_accuracy_settings join).
alter table public.forge_flow_polling_tier_assignment enable row level security;

drop policy if exists "forge_flow_polling_tier_per_tenant"
  on public.forge_flow_polling_tier_assignment;
create policy "forge_flow_polling_tier_per_tenant"
  on public.forge_flow_polling_tier_assignment for all to service_role
  using (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  )
  with check (
    operator_id = public.app_current_operator()
    and location_id = public.app_current_location()
  );

revoke all on public.forge_flow_polling_tier_assignment from public;
grant select on public.forge_flow_polling_tier_assignment to service_role;
grant select, insert, update on public.forge_flow_polling_tier_assignment to forge_admin;
```

The tier-definition presets (cadence-per-vendor for `standard` and
`premium`) live in code as a const lookup — they are F&F engineering
decisions, not operator-set state. F&F admin can override per
assignment via tier_key='custom' + explicit JSONB.

## Resolver contract

The aggregator (`8.spine-bridge.2`) reads
`data_accuracy_settings` for the (operator, location) at aggregation
time and applies the resolution rules below. Sync worker reads it for
polling cadence (`8.spine-bridge.0a`).

### Covers source resolution (per daypart)

```text
Given (operator, location, business_date, daypart):

  setting = data_accuracy_settings.covers_source_<daypart>

  if setting == 'manual':
    manual_value = covers_manual_entries[business_date][daypart]
    if manual_value is null:
      // Operator chose manual but did not enter a value for this date.
      // Aggregator returns null — no ShiftRecord written; dashboard
      // renders MetricCardNotYetAvailable until the operator enters
      // the value or switches the source.
      return null
    covers = manual_value
    coversSource = 'operator_manual_entry_per_daypart'
    sourceSystem = 'operator_manual_entry'

  elif setting == 'vendor' AND vendor_facts have covers populated:
    covers = SUM(cover_facts.covers for this daypart)
    coversSource = 'vendor_<id>'
    sourceSystem = vendor_<id>

  elif setting == 'vendor' AND vendor doesn't expose covers (capabilityProfile.coversFieldExposed=false):
    // Falls through to forecast substitution.
    covers = forecastSnapshot.coversFor(business_date, daypart)
    coversSource = 'vendor_<id>_covers_unavailable_app_forecast_substituted'
    sourceSystem = vendor_<id>

  elif setting == 'forecast':
    // Operator explicitly chose forecast even when vendor exposes covers.
    covers = forecastSnapshot.coversFor(business_date, daypart)
    coversSource = 'app_forecast_60_day_avg'
    sourceSystem = 'app_forecast'

  else:
    return null  // No covers source available
```

The forecast itself is **F&F-app-computed** per
`core_app_architecture.md` Layer 6 — never vendor-supplied. The
provenance string makes the substitution path explicit.

### Wage source resolution

Resolution is 4-way per the 2026-05-04 amendment. The operator's
binary toggle (`vendor` | `manual_mix`) sits on top of a vendor
capability classification (per Jim Taylor's wage model — per-position
is closer to model truth than per-employee because `wage_role_rows`
is per-role-weighted-up):

```text
Given (operator, location):

  setting = data_accuracy_settings.wage_source

  if setting == 'manual_mix':
    // Operator override: ignore vendor data unconditionally.
    // Use operator's wage_role_rows mix.
    laborDollars = SUM(actualHours[role] * wage_role_rows[role].hourly_rate)
    laborDollarsSource = 'target_wage_substituted'

  elif setting == 'vendor':
    wageClass = LaborWageSourceClass.lookup(vendor_id)  // sidecar lookup
    switch (wageClass):

      case perEmployeeWithDollars:  // 7shifts, QBT, ADP, Push Operations
        laborDollars = SUM(labor_punches.labor_dollars)
        laborDollarsSource = 'vendor_<id>_per_employee_actual_dollars'

      case perPositionWithRates:    // Humanity, Agendrix
        laborDollars = SUM(position.pay_rate * scheduled_hours per role)
        laborDollarsSource = 'vendor_<id>_per_position_actual_dollars'
        // Aggregator also writes vendor-populated wage_role_row
        // candidates for the post-spine-bridge wage editor seeding
        // follow-up (8.wage-editor-seed).

      case hoursOnly | noLaborData:
        // Fall through to target wage × hours.
        laborDollars = actualFohHours * targetSnapshot.fohWage
                     + actualBohHours * targetSnapshot.bohWage
        laborDollarsSource = 'vendor_<id>_dollars_unavailable_target_wage_substituted'

  else:
    laborDollars = null  // ShiftFactBuilder sets state = unavailable
```

The operator-facing toggle stays binary (`vendor` | `manual_mix`) — the
4-way classification is internal. The Data Accuracy tab's wage source
card surfaces the active class via the vendor relativity label:

- `perEmployeeWithDollars`: "Your scheduling system (QuickBooks Time)
  reports per-employee labor dollars. F&F uses those directly."
- `perPositionWithRates`: "Your scheduling system (Humanity) reports
  per-position pay rates. F&F multiplies those by scheduled hours.
  This is what the wage model needs — your wage editor's role rows
  reflect what your scheduler reports."
- `hoursOnly` / `noLaborData`: "Your scheduling system doesn't expose
  dollars or rates. F&F substitutes target wage × hours from your
  TargetCycle. Switch to 'manual mix' to use your operator-set wage
  editor mix instead."

### Polling cadence resolution

```text
Given (operator, location, vendor_id):

  override = data_accuracy_settings.polling_cadence_override_seconds[vendor_id]
  framework_default = 60s
  vendor_minimum = capabilityProfile.minimumPollCadenceSeconds (e.g., Oracle = 300s)
  vendor_maximum = 3600s (1 hour, framework cap)

  if override is null:
    cadence = max(framework_default, vendor_minimum)

  elif data_accuracy_settings.polling_cost_acknowledged_at is null:
    // Operator set an override but never acknowledged the cost.
    // Resolver IGNORES the override; uses default; logs a warning.
    cadence = max(framework_default, vendor_minimum)
    appendSyncLog('cadence_override_unacknowledged', ...)

  else:
    cadence = clamp(override, vendor_minimum, vendor_maximum)
    if cadence != override:
      appendSyncLog('cadence_override_clamped', ...)
```

## Costing surface

See "Polling cadence & cost pass-through model" section above for the
binding framing — F&F does NOT tier its own pricing by cadence; this
is a pass-through projection of the vendor's cost. The acknowledgement
mechanism + two-bucket classification are normative there.

The cost projection card on the polling cadence picker reads:

- `cost_per_poll_request` (per-vendor; cited from each vendor's API
  pricing in `docs/integrations/<vendor_id>/api_consumed.md`
  "Production environment → Pricing" section)
- `cadence_seconds`
- `hours_per_month` (730)

Formula (per-call vendors only):

```text
polls_per_month = (3600 / cadence_seconds) * 730
monthly_cost_dollars = polls_per_month * cost_per_poll_request
```

Subscription-bucket vendors render "$0/month additional — polling is
included in your <vendor> subscription" without invoking the formula.

Per-vendor bucket classification:

| Vendor | Bucket | Source |
|---|---|---|
| Oracle MICROS Simphony | per-call (TBD) | `docs/integrations/oracle_micros_simphony/api_consumed.md` |
| QuickBooks Time | subscription-bucket (TBD) | `docs/integrations/quickbooks_time/api_consumed.md` |
| Humanity | subscription-bucket (TBD) | `docs/integrations/humanity/api_consumed.md` |
| Agendrix | subscription-bucket (TBD) | `docs/integrations/agendrix/api_consumed.md` |
| Push Operations | subscription-bucket (TBD) | `docs/integrations/push_operations/api_consumed.md` |

ADP removed from this table: Wave B `lib/integrations/labor/adp_labor_adapter.dart` declares `webhookSupport: VendorWebhookSupport.autoRegister`. Polling cadence does not apply.

All "TBD" classifications above are pending the vendor-research pass queued in `session_handoff.md`.

When a per-vendor `api_consumed.md` lacks the pricing reference (Wave
B doc packs may not have surfaced production pricing yet), the Data
Accuracy tab renders "Pricing pending — confirm with your account
rep" instead of an estimated dollar amount. The card does NOT
fabricate a number.

## Vendor relativity rules

Each setting card in the Operator Web Console + F&F Ops Console must
display a vendor-relativity label that names which vendors the setting
affects. Reference data (sourced from `docs/integrations/<vendor_id>/`):

| Setting | Vendors that REQUIRE it (vendor doesn't expose) | Vendors where it's OPTIONAL (vendor exposes; operator can override) |
|---|---|---|
| Covers source = manual | Square, Clover | Toast, Lightspeed K-Series, Revel, Aloha NCR Voyix, Oracle MICROS Simphony |
| Wage source = manual_mix | QuickBooks Time, Humanity, Agendrix | 7shifts, ADP Workforce Now, ADP Workforce Manager, Push Operations |
| Polling cadence override | Oracle MICROS Simphony, QuickBooks Time, Humanity, Agendrix, Push Operations, ADP (all poll-only vendors) | N/A — webhook vendors ignore polling cadence |

The vendor-relativity label updates dynamically based on which vendors
the operator has actually connected. If an operator has connected
Toast (POS), the covers source card surfaces: "Toast exposes covers
directly — this setting only applies if you switch to a POS that does
not (Square, Clover)."

## Acceptance criteria for slices touching data accuracy

A slice that touches any data accuracy seam ships only when:

- [ ] Schema migration applied; RLS policies + grants present.
- [ ] Repository round-trip tested (idempotent upsert; per-daypart
      partial updates).
- [ ] Resolver applies the rules above deterministically; tests cover
      every path (vendor / forecast / manual / unavailable for covers;
      vendor / target_wage / manual_mix for wages; default / clamped /
      unacknowledged for cadence).
- [ ] Operator Web Console card renders + writes back via repository.
- [ ] Vendor relativity label dynamically reflects the operator's
      connected vendors.
- [ ] Cost projection surfaces correct $/month per cadence.
- [ ] F&F Ops Console admin surface writes `audit_logs` row on every
      override.
- [ ] No card-level chrome violates the metric honesty renderer rules
      (numbers stay clean; pill summarises non-live state).
- [ ] Banned items list (V1 lean cut 2) absent from every new file.

## Cross-references

- `docs/contracts/core_app_architecture.md` — Layer 2 (canonical
  facts), Layer 6 (forecast is F&F-computed), the operator-controlled
  accuracy seam section
- `docs/contracts/metric_card_honesty_contract.md` — provenance string
  rules; renderer chrome rules
- `docs/contracts/integration_spine_architecture_contract.md` — spine
  resolution + Concern A/B/C
- `docs/contracts/hardening_rls_and_repository_pattern_contract.md` —
  RLS-Ready Schema rules this table honors
- `docs/contracts/auth_permission_key_catalog.md` — `forge_admin` role
  for F&F Ops Console overrides
- `memory/project_ux_writing_standard.md` — UX writing rules every
  card label honors
- `docs/integrations/<vendor_id>/api_consumed.md` — per-vendor pricing
  + minimum poll cadence reference data
