# Plans & Limits V1 — Pricing Model + Admin Redesign Plan

Status: SHIPPED through Phase 5 Wave 1+2 plus scoped custom contracts and final QA polish (2026-05-26). Only 5d (real feature gates) remains DEFERRED until the gateable features exist; Phase 6 billing remains FUTURE.
Created: 2026-05-24
Updated: 2026-05-26

Progress (through 2026-05-26):
- SHIPPED to master: Phase 0 (six real plans incl. `elite`), Phase 1 (rebuilt admin
  "Plans & limits" screen) + the preset preview-diff, Phase 2 (live spend numbers +
  delete-a-limit), Phase 3 (editable `pricing_plan_catalog`), Phase 4a (operator
  `trial_mode` flag + `startPilotTrial` + `convertTrialToStarter`).
- DROPPED by operator decision: the rest of Phase 4 (Pilot sample-data preview, no
  web or mobile preview seeding); the mockup's "Reconcile" tab (one-time decision
  aid, intentionally out of the live operational screen).
- SHIPPED to master (Phase 5 Wave 1+2, 2026-05-25): 5a (feature_entitlements table +
  admin Features matrix), 5c (model routing by plan), selector cleanup (scope tree is the
  single business selector; redundant business list removed), 5b ("Your plan" on
  operator-web), 5b live-data follow-up (plan + trial on the operator account read). Plus
  a 5a test-compile regression fixed (#1343); full-package analyze is error-free.
- SHIPPED to master (scoped custom contracts + final QA, 2026-05-26): Enterprise is the
  custom-contract base plan; business, org-unit, and location scopes can carry custom terms;
  lower scopes override higher scopes; effective pricing now resolves through the hierarchy;
  admin Businesses tab can edit, clear, and inherit custom contracts; Operator Web "Your plan"
  is display-only; Business Accounts stale launch wording was removed. No billing checkout,
  invoices, or payment collection were added.
- ONLY REMAINING: 5d (actual feature gates) — DEFERRED (see Phase 5). Reality-check
  (2026-05-25) found the gateable features (LMS / scoreboard / SOPs / workflows) have NO
  real surfaces yet, so there is nothing to gate. Blocked by features-not-built, not by
  7.58. The 5a control panel is ready for when they ship.
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

Historical starting-state audit preserved for traceability. Current shipped state is
summarized in the progress and closeout sections above.

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
- Landed as `pricing_plan_catalog` (tier_key, monthly_usd, first_n_seats,
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

### Phase 5 — Plan entitlements + "Your plan" screen + model routing (L) — WAVE 1+2 SHIPPED 2026-05-25 (5d deferred)

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
- Operator-web had ZERO tier awareness before 5b; Phase 5b added the display-only
  "Your plan" surface.

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
- **5d — Actual feature gates — DEFERRED 2026-05-25 (reality-check done; nothing real to gate yet).**
  Reality-check complete: the gateable features the plans advertise (LMS, scoreboard,
  SOPs, workflows) have NO real operator-facing surfaces today. Evidence (2026-05-25):
  operator-web routes are only business-timing / roles / security / my-account /
  your-plan (`lib/operator_web/router/**`); mobile is the core dashboard + variance
  coaching (`lib/screens/**`); no LMS / scoreboard / SOPs / workflow-catalog screen
  exists in either. You cannot gate a screen that does not exist, so 5d is blocked by
  **features-not-built**, NOT by 7.58 (cleared) or app-logic. The 5a entitlements
  control panel (table + admin Features matrix) is the durable foundation and is READY:
  when any of these features ships, gating plugs straight in. Do NOT build speculative
  gating that hides nothing; revisit 5d when a gateable feature is actually built.
  - **UX note (operator directive 2026-05-25):** when 5d is built, its feature-gating /
    Features UX MUST use the unified premium switch — the shared `ConsoleSwitchRow` /
    `ConsoleChannelToggle` (`lib/widgets/console/console_switch_row.dart`) + the shared
    `SwitchThemeData` in `lib/theme/app_theme.dart` — so every toggle stays consistent
    and premium across both consoles. No bespoke switches.

**Decision feeding 5a:** confirm the exact "what's included per plan" matrix (a draft
exists in the `kPricingTierTemplates` plan summaries).
**Recommended start:** 5a + 5b + 5c (foundation + display + routing; web/server, low
risk) — ALL SHIPPED 2026-05-25, plus the selector cleanup and the 5b live-data follow-up.
5d's surface reality-check is DONE; result: DEFERRED (no features to gate yet, see 5d).

**UX standard (BINDING, operator directive 2026-05-25):** every new Phase 5
operator-web surface (especially 5b "Your plan", and any plan-related screen) MUST be
SIMPLE and follow the EXISTING operator-web console: same structure, navigation,
layout, shared theme, and components. It has to look and behave like the rest of the
ops web, not a one-off or a parallel style. Low clutter; plain English that reads as
training; no jargon; no em-dash punctuation (UX no-em-dash law). Reuse operator-web's
existing patterns and widgets; do not invent new ones. References: the operator-web
console structure in `lib/operator_web/**`, `runbooks/operator_web_qa_runbook.md`, and
the standing "Web/Mobile Visual Consistency" + "Admin-Web UX Parity" standards. The
admin-side Phase 5 entitlements editor (5a) likewise matches the existing Plans &
limits screen, not a new look.

### Scoped custom contracts - SHIPPED 2026-05-26

Enterprise is the custom-contract base plan. Business, org-unit, and location scopes
can carry custom commercial terms while preserving the hierarchy rule: location
overrides org unit, org unit overrides business, and business overrides the global
catalog. The shipped resolver returns the selected scope, inherited source, effective
terms, override status, and mutation target.

Shipped surfaces:
- `pricing_contract_overrides` plus effective-window follow-up migration.
- Repository/resolver + proxy routes:
  `GET /v1/admin/pricing/scoped-contracts/effective`,
  `PUT /v1/admin/pricing/scoped-contracts`, and
  `DELETE /v1/admin/pricing/scoped-contracts/{id}`.
- Admin gateway/models and in-memory behavior for edit/save/clear/inherit.
- Businesses tab scoped contract summary and editor.
- Plans tab Enterprise/custom copy.
- Operator Web "Your plan" display-only copy.
- Business Accounts stale launch wording cleanup.

Still not included: Stripe, invoices, payment methods, checkout, operator self-serve
plan changes, or real feature gates for features that do not exist yet. Details:
`docs/phases/plans_and_limits_v1/scoped_custom_contracts_plan.md`.

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
- **Pricing source:** prices now read/write through `pricing_plan_catalog`; scoped
  custom Enterprise terms resolve through `pricing_contract_overrides`. Any future
  billing work must use those server-side sources, not client constants.

## 5. Start here

No active implementation slice remains in this plan except deferred Phase 5d feature
gates and future Phase 6 billing. Use the scoped custom contracts plan for the shipped
custom-contract closeout details.

## 6. Links

- Decision: `docs/phases/phase_11a/phase_11a_decision_register.md` (Reconciled pricing model 2026-05-24).
- Mockup: `docs/_mockups/admin_plans_and_limits_redesign.html`.
- Scoped custom contracts closeout:
  `docs/phases/plans_and_limits_v1/scoped_custom_contracts_plan.md`.
