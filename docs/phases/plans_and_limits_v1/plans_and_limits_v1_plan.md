# Plans & Limits V1 — Pricing Model + Admin Redesign Plan

Status: SHIPPED through Phase 4a + preset-diff (2026-05-25); Phase 5 scoped below, now unblocked.
Created: 2026-05-24
Updated: 2026-05-25

Progress (2026-05-25):
- SHIPPED to master: Phase 0 (six real plans incl. `elite`), Phase 1 (rebuilt admin
  "Plans & limits" screen) + the preset preview-diff, Phase 2 (live spend numbers +
  delete-a-limit), Phase 3 (editable `pricing_plan_catalog`), Phase 4a (operator
  `trial_mode` flag + `startPilotTrial` + `convertTrialToStarter`).
- DROPPED by operator decision: the rest of Phase 4 (Pilot sample-data preview, no
  web or mobile preview seeding); the mockup's "Reconcile" tab (one-time decision
  aid, intentionally out of the live operational screen).
- NEXT: Phase 5 (below) is scoped + unblocked (7.58 confirmed shipped). Not started;
  awaiting operator go-ahead per slice.
Owner: Orchestrator (operator: Said / Vanessa)
Method: `runbooks/feature_implementation_lens_audit_runbook.md` (deep pass)

## 0. Authority / source of truth

- **Pricing model decision (canonical):** `docs/phases/phase_11a/phase_11a_decision_register.md`
  section "Reconciled pricing model (2026-05-24)".
- **Operator-approved visual:** `docs/_mockups/admin_plans_and_limits_redesign.html`
  (Reconcile + Plans + Businesses tabs).
- This plan doc is the durable home for the end-to-end audit + phased build.
  It does not restate rules owned by the decision register or CLAUDE.md.

## 1. Locked pricing model (one-line recap)

Six plans (Pilot, Starter, Premium, Elite, Pro, Enterprise). Every paid plan is
the full product (KPI dashboard, reporting, branded app) **plus** AI, not AI-only.
**Pilot = free preview** (full dashboard on demo/sample data + advisor, reusing
demo mode; converts to Starter when real POS/labor data is connected). Entry tier
named **Starter**. Elite seat $10/$5, Premium $5/$3, onboarding per plan. Full
detail + rationale: decision register section above.

## 2. End-to-end audit (2026-05-24)

Foundation exists; the app stores the tier but does almost nothing with it yet.

| Layer | What exists (file:line) | Gap / change needed |
|---|---|---|
| Schema: tier column | `db/migrations/202604250005_advisor_cloud_foundation.sql:77` (`operators.subscription_tier`, default `'launch'`) | No CHECK constraint; allows garbage. Add CHECK for the 6 keys; retire `'launch'`. |
| Schema: usage_caps | `202604250005_...sql:176-194` + `202604280006_a_phase_9_0sigma_g_usage_caps_two_slot_add.sql:79-82` (staff_id, workflow_id) | OK. No DELETE path (see proxy). |
| Schema: usage_logs + telemetry | `202604250005_...sql:150-174` + `202604250006_advisor_contextual_retrieval_telemetry.sql` (query_class, cache_hit, llm_tier, model_used, batch_mode) | OK. |
| Schema: seats / pricing catalog / entitlements / billing | none | Missing entirely. Needed for editable pricing, per-seat billing, feature gating. |
| Auth enum | `lib/auth/mfa_policy.dart:9-14` `OperatorSubscriptionTier` = {pilot, starter, premium, pro, enterprise} | **Missing `elite`.** `fromKey('elite')` returns null. Real bug. |
| Proxy pricing routes | `tool/advisor_proxy/advisor_proxy.dart` (`/v1/admin/pricing/operators`, `/usage-caps`, `/apply-template`) | No DELETE for usage-caps. Pricing (monthly/seat/onboarding) not stored/served. |
| Cap enforcement | proxy pre-flight monthly + per-invocation check (`advisor_proxy.dart` ~3498, ~6626-6628); breaches (~8328) | OK. Month-to-date spend not exposed via an admin endpoint. |
| Tier templates (prices/caps) | `lib/admin/models/pricing_tier_admin_models.dart:272-366` (hardcoded Dart const) | Hardcoded; pricing not editable / not server-side. |
| Admin pricing screen | `lib/admin/screens/pricing_tier_admin_screen.dart` (cap dialog 875-1043) | No live spend/margin/breach; no plan-pricing editor; no delete-limit; inheritance read-only. |
| Observability data | `lib/admin/models/observability_admin_models.dart` (CostTelemetryEntry 80-119, CapEvent 378-419, MarginEstimateEntry 343-371) | Modeled; producers **in-flight** (`observability_admin_gateway.dart:17-19`). Live data not wired; demo envelope only. |
| Operator web | `lib/operator_web/**` | **Zero** tier awareness: no plan display, no feature gating, no plan picker/onboarding. |
| Mobile | `lib/screens/**`, `lib/main_forgeflow.dart` | Zero tier awareness. |
| Demo mode | `DemoScope` (`lib/infrastructure/persistence/sqlite/sqlite_database.dart`); demo operators seeded `subscription_tier='launch'` (`lib/admin/admin_routes.dart:3064,3133`) | Demo is a writer-side QA switch (HP#2), NOT a per-operator trial. Pilot-as-trial needs its own flag + conversion path. |
| Billing/payments | none in `lib/` or `tool/` | Entirely future/manual per decision register. |
| Feature gating by tier | none | No code gates LMS/scoreboard/chatbots/workflows by tier. Model routing (Haiku/Sonnet) not wired to tier. |

## 3. Phased build

Order is by dependency + value. Sizes: S/M/L/XL. "Gate" = needs explicit operator
approval per CLAUDE.md (auth/RLS/schema/proxy-touching).

### Phase 0 — Make the six plans real (S, gate: schema + auth)
- Add `elite` to `OperatorSubscriptionTier` (`lib/auth/mfa_policy.dart`) + `fromKey`.
- Migration: CHECK constraint on `operators.subscription_tier` = the 6 keys.
- Retire/map demo `'launch'` seed (`lib/admin/admin_routes.dart`) to a real key.
- House rules: migration drift scanner + cutoff lint after migration.
- Tests: enum round-trip; migration constraint accept/reject.

### Phase 1 — Rebuild the admin "Plans & limits" screen (M, gate: light)
- Implement the approved mockup against existing gateways: plan map, plan/margin
  card, spend-vs-cap bars, recent cap-breach strip, use-case dropdowns, names,
  preset preview diff, inheritance display, Plans/Businesses/Reconcile structure.
- Reuses the pricing gateway + the observability gateway (works on demo data today).
- Delete-a-limit needs a small DELETE route (`/v1/admin/pricing/usage-caps`) — fold
  the route into Phase 2 or ship the UI disabled until then.
- Files: `lib/admin/screens/pricing_tier_admin_screen.dart` (+ models/gateway), widget tests.

### Phase 2 — Turn on live numbers (M, gate: proxy)
- Wire the observability producers (per-operator spend, margin, cap events) so the
  screen shows live figures, not the demo envelope.
- Add `GET /v1/admin/pricing/operators/{id}/spend-summary` (month-to-date spend vs
  cap) for accurate spend-vs-cap bars.
- Add `DELETE /v1/admin/pricing/usage-caps` (idempotent) for delete-a-limit.
- Files: `tool/advisor_proxy/**`, `observability_admin_gateway.dart`, proxy tests.

### Phase 3 — Make plan pricing editable (M, gate: schema + proxy)
- New `pricing_templates` table (tier_key, monthly_usd, first_n_seats,
  first_seat_usd, additional_seat_usd, onboarding_min/max, + cap rows).
- Move tier templates out of hardcoded Dart; admin routes to read/update the catalog.
- Wires the mockup's plan-pricing editor to a real save path.
- Files: migration, `tool/advisor_proxy/**`, `pricing_tier_admin_gateway.dart`, models.

### Phase 4 — Pilot as a real free trial (L, gate: schema + proxy; design care)
- Per-operator `trial_mode BOOL` / `trial_expires_at TIMESTAMPTZ` on `operators`.
- Pilot signup pre-seeds sample data under a real operator using the existing demo
  seeders (NOT `demo_*` tables — HP#2 doctrine: same tables/reads/UI).
- Conversion: when a real POS/labor connector succeeds, flip trial off + tier → Starter.
- Files: migration, proxy signup/convert logic, operator-web preview entry.

### Phase 5 — Plan entitlements + "Your plan" screen + model routing (L) — UNBLOCKED 2026-05-25

**Gate status:** 7.58 (Primary Driver) is SHIPPED and live (confirmed 2026-05-25:
`primaryDriver` / `LeverCard` logic across `lib/screens/variance/**`,
`lib/domain/services/**`, `lib/models/**`; contract
`docs/contracts/phase_7_58_primary_driver_contract.md`). HP#3's "no app logic before
7.58" precondition is therefore SATISFIED — feature gating is buildable now.

**Recon (2026-05-25), so we extend rather than duplicate:**
- Tier is real + stored per operator (Phase 0).
- An existing `feature_flags` admin system exists but is GLOBAL OPS toggles (KMS
  rollout, audit cutover, `advisor_enabled`), NOT per-tier product gating. Mirror its
  admin UI pattern; do NOT overload its table. (`db/migrations/202605020400_*`,
  `lib/admin/models/feature_flags_admin_models.dart`.)
- Model routing `ProxyLlmTier {haiku, sonnet}` exists
  (`tool/advisor_proxy/advisor_proxy.dart:2833`) but is NOT tier-driven today.
- Operator-web has ZERO tier awareness (`lib/operator_web/**`) — "Your plan" is greenfield.

**Slices (build order):**
- **5a — Entitlements foundation (M, gate: schema + proxy).** New GLOBAL
  `feature_entitlements(tier_key, feature_slug, enabled)` table (follow the Phase 3
  `pricing_plan_catalog` global-catalog precedent). Seed the per-tier matrix from the
  plan summaries in `kPricingTierTemplates` (Premium adds LMS + scoreboard; Pro adds
  workflows; etc.). Admin editor mirroring the Plans & limits look + the feature-flags
  admin pattern. GET/PATCH proxy routes (gated, idempotent, audited).
- **5b — "Your plan" on operator-web (M, gate: light / web-only).** Current plan,
  included features (reads entitlements), trial time left (reuses Phase 4a
  `trial_mode` / `trial_expires_at`), upgrade intent. Greenfield in `lib/operator_web/**`.
- **5c — Model routing by plan (S–M, gate: proxy).** Wire operator tier →
  `ProxyLlmTier` so plan drives Haiku vs Sonnet. Extend existing routing; no parallel stack.
- **5d — Actual feature gates (size: depends; gate: app logic, now allowed).**
  Hide / disable LMS / scoreboard / chatbots / workflows by tier. CAVEAT: only
  gateable where a real surface exists; recon found no finished operator-web surfaces
  for LMS / scoreboard / chatbots (several may be unbuilt or MOBILE = paused). Gate
  what exists; defer the rest. Needs a per-feature surface reality-check first.

**Decision feeding 5a:** confirm the exact "what's included per plan" matrix (a draft
exists in the `kPricingTierTemplates` plan summaries).
**Recommended start:** 5a + 5b + 5c (foundation + display + routing; web/server, low
risk). 5d after the surface reality-check.

### Phase 6 — Billing (XL, FUTURE)
- Seat counting (`operators.active_seat_count` or a seats table + nightly rollup),
  payments (Stripe adapter), invoices, payment methods.
- Deferred per decision register "Fixed-Cost Deferral Discipline."

## 4. Cross-cutting flags / decision stops

- **Feature gating vs 7.58:** RESOLVED 2026-05-25. 7.58 (Primary Driver) is shipped
  and live, so HP#3's precondition is satisfied and Phase 5 is unblocked. (Prior note:
  "must wait for the first logic-deciding slice." That gate has passed.) The app still
  shows all features regardless of plan until Phase 5d actually gates them.
- **Billing is future:** Phase 6 is a separate sprint; large blast radius.
- **Pilot ≠ demo mode:** Phase 4 must add a trial flag, not a parallel demo system,
  or it violates HP#2 (demo is a writer-side switch).
- **Pricing source split:** until Phase 3, prices live in Dart; any billing work
  must read the catalog table, not the client constants.

## 5. Start here

Phases **0 + 1** are the cheap, high-value start (correctness fixes + the approved
screen). Everything past Phase 1 touches schema/proxy and needs operator sign-off.

## 6. Links

- Decision: `docs/phases/phase_11a/phase_11a_decision_register.md` (Reconciled pricing model 2026-05-24).
- Mockup: `docs/_mockups/admin_plans_and_limits_redesign.html`.
- Links updated elsewhere: no (new doc; not yet referenced from NEXT_WAVE_PLAN).
