# Plans & Limits V1 — Pricing Model + Admin Redesign Plan

Status: Planned (not started)
Created: 2026-05-24
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

### Phase 5 — Operator plan screen + feature gating (L, LATER)
- Operator-web: "Your plan" surface (current plan, included features, trial time,
  upgrade intent).
- `feature_entitlements(tier_key, feature_slug, enabled)` + gate LMS / scoreboard /
  chatbots / workflows by tier; wire model routing (Haiku/Sonnet) to tier.
- **Gate / sequencing:** collides with Hard Promise #3 ("no app logic changes before
  7.58"). Schedule after 7.58; do not start gating logic before then.

### Phase 6 — Billing (XL, FUTURE)
- Seat counting (`operators.active_seat_count` or a seats table + nightly rollup),
  payments (Stripe adapter), invoices, payment methods.
- Deferred per decision register "Fixed-Cost Deferral Discipline."

## 4. Cross-cutting flags / decision stops

- **Feature gating vs 7.58:** Phase 5 must wait for the first logic-deciding slice
  (HP#3). Until then the app shows all features regardless of plan.
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
