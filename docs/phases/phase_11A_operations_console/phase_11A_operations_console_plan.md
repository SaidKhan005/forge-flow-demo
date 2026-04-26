# Phase 11A - F&F Operations Console

Updated: 2026-04-26
Status: Active next (opens after accepted `11a.11c-e` close, including the
`11a.11c.4-6` Postgres host migration to Azure)
Owner: F&F admin / operations lane

**2026-04-26 — Postgres host re-locked to Azure DB Flexible Server (Canada Central, PG 16).** Throughout this plan, "Supabase database" reads as "Azure Database for PostgreSQL Flexible Server". `11A.4` Integration management now manages Azure DB connection strings (in addition to Anthropic / Voyage keys) instead of Supabase project keys. `11A.6` Observability dashboard reads health + metrics from Azure Monitor (Postgres metrics) + Cloud Run + Anthropic / Voyage usage instead of Supabase + Cloud Run. Trigger: see `phase_9_auth_plan.md` 2026-04-26 banner.

> Naming note: capital `A` distinguishes this phase (`11A`, the F&F
> internal admin console) from `11a` (advisor infrastructure). They
> are separate surfaces with separate audiences. References elsewhere
> in the repo should use the capital-A form for this phase to avoid
> ambiguity.

## Why This Exists

`11a.11c-e` lights up the cloud infrastructure (Azure DB Flexible
Server, proxy backend, corpus). At that point, F&F has a working
back-end stack
but no human-facing way to operate it. Onboarding a new operator
means writing SQL by hand. Editing pricing means redeploying.
Debugging a customer complaint means grep-ing Cloud Run logs.
Rotating an API key means reaching into Cloud Run env vars.

Phase 11A is the F&F internal admin product that fixes this.
Web-hosted, desktop-accessible, brand-styled, lets the founder
(and eventually F&F support staff) manage operators, locations,
pricing, corpus, integrations, debugging, observability, feature
flags, and audit logs from any browser without on-premise tooling.

## Audience and Boundary

- **Audience.** F&F super-admin (Vanessa). Eventually F&F support
  staff with operator-scoped read access.
- **Boundary.** Phase 11A is **not** the operator-facing app. It
  does not own operator UX. It does not surface to operators ever.
  It is the internal back-office.
- **Auth.** Firebase Authentication admin tokens. Admin role gate
  on every `/v1/admin/*` route the proxy serves. RLS policies on
  every operator-scoped table apply same as anywhere else; admin
  role is the only role that bypasses with explicit
  `service_role` for cross-operator queries (Postgres
  `BYPASSRLS` granted only to the admin path).

## Tech Stack

**Flutter for Web.** Decided 2026-04-25. Reasons:

- Reuses the existing brand from `lib/theme/app_theme.dart`
  (Sunset / Peacock palette, Playfair Display + IBM Plex
  typography). Compiles for web identically.
- Single Dart codebase across mobile (operator app) and
  web/desktop (admin console). No new language, no new
  framework, no new hire profile to support.
- Flutter desktop targets Windows / Mac / Linux natively from
  the same codebase. Covers the desktop-access requirement
  without separate Electron / Tauri builds.
- Migration path exists: if Phase 11A outgrows Flutter for Web
  performance at very-heavy DOM scale, the proxy `/v1/admin/*`
  API contract is framework-agnostic; a React / Next.js client
  can replace the Flutter Web client without backend changes.

Hosting: separate Cloud Run service from the proxy backend, at
`admin.forgeflow.app` (or similar). Shares the Azure DB Flexible
Server (Postgres) instance with the proxy backend. ~$0-15/month at
idle (Cloud Run admin service); Azure DB cost shared with the proxy.

## Goal

Ship the F&F Operations Console that handles every internal
operations task without shell access, manual SQL, or redeploys.
Specifically:

- Onboard new operators in seconds via a form (vs SQL INSERT)
- Edit pricing per `(operator_id, location_id, usage_class)`
- Drag-and-drop markdown corpus updates from desktop
- Debug specific operator complaints via per-operator request
  log viewer (meta by default, full content per opt-in)
- See system health at a glance (Postgres, AGE, pgvector, Cloud
  Run, latency, error rate, cost-by-operator)
- Rotate Anthropic / Voyage API keys without an engineer
- Toggle feature flags per operator
- Manage status page incidents

## Sub-Slice Sequence

### Foundation (launch-blocking before 11b)

- `11A.0` Flutter for Web project bootstrap. Brand styling
  shared with operator app via the same `app_theme.dart`. Route
  shell. Firebase Auth integration. Deploys to a separate Cloud
  Run service. Empty admin home page rendering with brand
  styling. Acceptance: navigable shell on `admin.forgeflow.app`
  with auth gate.
- `11A.1` **Operator + location management.** CRUD on
  `operators`, `locations`, `users`, `operator_admins`. Onboard
  new operator (creates rows, assigns subscription tier, sets
  `preferred_currency`, sets `primary_location_id`). Edit
  existing. Suspend / reactivate. Add / remove locations per
  operator. Set per-location `timezone` (IANA picker) and
  `business_day_rollover_hour`. Replaces "manual SQL INSERT"
  as the new-operator onboarding path.
- `11A.2` **Pricing tier admin.** Table editor for `usage_caps` per
  `(operator_id, location_id, staff_id NULL, workflow_id NULL,
  usage_class)` (Hard Promise #9 metering axes). Lists all operators,
  their tier, their cap rows. Edit inline. **Tier templates** for
  one-click onboarding match the locked tier model in
  `phase_11a_decision_register.md` Pricing Tier Model section:
  Pilot / Starter / Premium / Elite / Pro / Enterprise. Each
  template seeds:
  - Per-class monthly caps (advisor_qa, coach_qa, workflow_*)
  - Per-staff overrides where applicable
  - Per-workflow allowances + overage pricing for Pro tier
  - Subscription tier on `operators.subscription_tier` (drives
    per-tier model routing in proxy)
  Captures `created_by` / `updated_by` audit columns. **Replaces
  the earlier `11a.13` scope** (same UX, broader metering axes).
- `11A.3` **Corpus admin.** Drag-and-drop markdown upload.
  Per-chunk preview before commit. Diff view (what's new, what's
  changing, what's being inactivated). Rollback to prior corpus
  version. **Replaces the earlier `11a.12` cloud enablement
  scope** (same pipeline, better surface). Pipeline integrates
  with the corpus build tool (`tool/advisor_corpus/`) and
  enforces resumability + Voyage rate-limit backoff per
  `11a.11e` acceptance.

### Operations readiness (launch-blocking, lands alongside 11b)

- `11A.4` **Integration management.** View and rotate Anthropic
  and Voyage API keys (writes to Cloud Run env / KMS via admin
  API; never displays plaintext after creation). Vendor
  connector status placeholder (lights up when Phase 8 lands).
  FX-rate source status. Email provider status (when 9.8 lands).
- `11A.5` **Debug console.** Per-operator request log viewer.
  Filter by operator / location / usage_class / time-window /
  status. View request meta by default; toggle full content per
  operator (per `feature_flags` opt-in row). Search by
  `request_id` or `idempotency_key`. Live-tail latest requests
  for the active session. **This is the "remote debug" surface**
  - accessible from any browser, no shell access required.
- `11A.6` **Observability dashboard.** System health
  (Postgres + AGE + pgvector + Cloud Run via the `/health`
  probe). Latency p95 / p99 charts. Error rate by route.
  Cap-event stream (incoming alerts when operators hit cap).
  Cloud Run instance counts. Replaces "I'll figure out if
  something's broken from raw logs" as the path.

  **Cost telemetry surfaces** (Hard Promise #9 visibility):
  - Total cost-by-(`operator_id` / `location_id` / `staff_id` /
    `workflow_id` / `usage_class`)
  - Cost-by-`query_class` (advisor_qa / coach_qa / wf_pl /
    wf_schedule / etc.) — drives pricing-tier decisions
  - Cache hit rate per `query_class` (lever 3 effectiveness)
  - Model mix per `query_class` (Haiku vs Sonnet share — lever 2
    effectiveness)
  - Batch-mode share for async workloads (lever 5 effectiveness)
  - Top-N most-expensive operators / staff / workflows over
    rolling windows (1d / 7d / 30d)
  - Operator dormancy state (last_active_at relative to now;
    flag operators 30+ days silent for precompute skip)
  - Per-tier margin estimate (revenue from `subscription_tier`
    minus rolling cost = margin per operator)

### Polish (post-launch; can interleave with 11b.2 / 10b)

- `11A.7` **Feature flag admin.** Edit `feature_flags` rows from
  the UX (toggle Q12 retrieval-mode, toggle streaming when it
  lands, gate Phase 12 workflows per pilot operator, etc.).
- `11A.8` **API version management.** See what % of operator
  clients are on `/v1/` vs `/v2/`. Schedule deprecation
  announcements. View force-update conditions when needed.
- `11A.9` **Audit log review.** Who changed what when across
  `usage_caps`, `feature_flags`, `operators`, key rotations.
  Powered by `created_by` / `updated_by` columns; the UX makes
  the audit queryable.
- `11A.10` **Status page management.** Create incidents, write
  post-mortems, sync to public `status.forgeflow.app` page.
- `11A.11` (optional) **Replay tool.** Pick a past request,
  re-run it against current corpus + model, compare to original
  answer. Lights up if a real customer dispute ever surfaces.

## Sequencing in the Build Cadence

Updated locked sequence 2026-04-25:

```text
[7.57] -> 11a.11c -> 11a.11d -> 11a.11e ->
[11A.0 -> 11A.1 -> 11A.2 -> 11A.3 -> 11A.4 -> 11A.5 -> 11A.6] ->
9.8 -> 9 -> 10a -> 10.5 -> 9.5 ->
[7.58] -> 11b -> 9.75 -> 11b.2 ->
[11A.7 -> 11A.8 -> 11A.9 -> 11A.10 (interleave with above)] ->
10b -> [7.61] -> 8 -> 8R
```

Reasoning:
- `11A.0-6` ship before any operator-facing launch (ops
  readiness)
- `11A.7-10` are post-11b polish (admin works without them at
  MVP; they make admin good)
- The operator-facing `11b` advisor still ships when planned;
  `11A` runs alongside, not in front of, `11b`'s critical path

## Scope Does Not Own

Phase 11A does not own:

- the operator-facing Forge & Flow app (`lib/main_forgeflow.dart`)
- the operator-facing Barrio app (`lib/main_barrio.dart`)
- the proxy backend itself (that's `11a.10`); this phase consumes
  proxy admin routes
- corpus pipeline internals (those are `7.57.3b` / `11a.11e`); this
  phase consumes the pipeline as a service
- Phase 12 workflow automation runtime; that's a future phase
- public status page authoring (a free service handles authoring;
  `11A.10` is the F&F-side incident-creation UX)

## Dependencies

Required before Phase 11A can ship real:

- `11a.11c-e` complete (Azure DB Flexible Server live with AGE +
  pgvector + pg_diskann verified, proxy enforcement, corpus loaded)
- Firebase Authentication admin role configured
- Cloud Run service slot reserved for `admin.forgeflow.app`
- Brand assets in `lib/theme/` (already exist)

## Non-Negotiables

- All admin actions go through the proxy backend's `/v1/admin/*`
  API. Direct database access from the admin client is forbidden;
  same repository pattern + RLS as elsewhere.
- Audit columns (`created_by`, `updated_by`) populated on every
  admin write. The UX always shows who changed what when.
- No plaintext API keys ever displayed after rotation. The UX
  shows masked values; only the operator who created the key
  sees it once at creation time.
- Per-operator opt-in required to enable full-content request
  logging; UX must surface the privacy implication when a
  super-admin toggles it on.
- Brand styling identical to operator app; same `AppColors` and
  text styles. The admin product feels like the same product.

## Adjacent Phases

- `Phase 11a` lights up the Azure DB Flexible Server + proxy +
  corpus that 11A manages
- `Phase 9` issues admin auth tokens
- `Phase 9.8` provides the legal/compliance surfaces (T&Cs editor
  may live in 11A.10 or a 9.8 sub-slice)
- `Phase 11b` ships the operator-facing advisor; 11A's debug
  console is what handles 11b support tickets
- `Phase 12` workflow automation will need new admin surfaces
  (workflow registry, write-tool audit log) — extends `11A`
  rather than parallel-stacking

## Source Material

- [PROJECT_TRACKER.md](C:/Git%20Local%20Repos/forge_flow_demo/PROJECT_TRACKER.md)
- [phase_11a_advisor_infrastructure_plan.md](C:/Git%20Local%20Repos/forge_flow_demo/docs/phases/phase_11a/phase_11a_advisor_infrastructure_plan.md)
- [Architecture_Guide.pdf](C:/Git%20Local%20Repos/forge_flow_demo/Architecture_Guide.pdf)
- [lib/theme/app_theme.dart](C:/Git%20Local%20Repos/forge_flow_demo/lib/theme/app_theme.dart)
