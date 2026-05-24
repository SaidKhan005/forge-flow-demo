# AI Metrics Redesign V1 — End-to-End Implementation Plan

Status: PLANNED (awaiting execution go) · Created 2026-05-24 · Owner: orchestrator
Surface: admin console "AI Metrics" (Observability) screen, route `/observability`
(`lib/admin/screens/observability_admin_screen.dart`).

Authority: this plan defers to CLAUDE.md, `docs/contracts/core_app_architecture.md`,
the Metric Honesty Doctrine, HP#11 (hierarchy scope), and the standard workflow in
`docs/CODEX_PROMPT_GENERATION_STANDARD.md`. Built from four read-only deep audits
(frontend, proxy/auth, contracts/workflow, backend-feasibility) run 2026-05-24.

Mockup under review: `docs/_mockups/ai_metrics_redesign/index.html` (served locally).

---

## 1. Goal & non-goals

GOAL: Replace the dense 7-tab Observability screen with a cleaner, more visual,
plain-English, professional, hierarchy-scoped screen consistent with the rest of the
app (4 themes: Money / Customers / Reliability / Knowledge), AND build the backend
producers so every panel shows real data. Operator chose backend-first.

NON-GOALS: No operator-web twin (AI Metrics stays admin-only). No change to the
manual-run / no-auto-poll posture. No per-request usage logging in V1 (monthly
granularity accepted, decision #4).

---

## 2. Operator decisions (locked 2026-05-24)

1. **Pricing**: build a pricing table to power the "Losing money" (margin) panel.
2. **Limit hits**: add durable recording of cap refusals (new table + proxy write).
3. **Hosting**: wire a Google Cloud read for live instance counts.
4. **Time windows**: accept MONTHLY granularity (this month / last month). No 24h/7d
   in V1 (cost is stored as a monthly rollup).
5. **Greenlight**: operator pre-approved the schema + proxy + cloud changes below.
   Each PR still gets a Pattern B audit; the orchestrator surfaces anything that
   deviates from this plan before merge.

---

## 3. Data reality (why the plan is shaped this way)

- `usage_logs` is a **monthly rollup**, not per-request (UPSERT into
  `period_start = date_trunc('month', ...)`, `advisor_proxy.dart` ~6561/6573).
  → Top spenders and time windows are MONTH-granular only.
- **No revenue/pricing data exists** anywhere in `db/migrations` — only
  `operators.subscription_tier` (a text label). → margin needs a new pricing source.
- **Cap refusals are not persisted** — computed live, returned as 413/429
  (`ProxyAccountingRefused`, `advisor_proxy.dart` ~3491; `usage_caps` is definitions
  only). → "Limit hits" needs a new event table + a write at the refusal site.
- **Hosting counts are not in Postgres** — the Cloud Run client is write-only
  (`lib/infrastructure/cloud_run/cloud_run_admin_client.dart` ~50). → needs a GCP read.
- Endpoint is real and live: `/v1/admin/observability`
  (`tool/advisor_proxy/advisor_proxy.dart:15058-15114`, gateway
  `proxy_bootstrap.dart:9576-9770`, cross-op reads run under
  `runAsSystem`/BYPASSRLS at ~9603). Empty surfaces sit in `neutral_empty_surfaces`
  (`proxy_bootstrap.dart` ~9707/9720/9721/9754/9755).
- Access already gated to `{super_admin, ff_support}`
  (`advisor_proxy.dart:8234-8237`). "All businesses" = send `operator_id = null`
  (predicate `@operator_id::uuid is null` already in every query).

---

## 4. All-surface coverage map

| Layer | What changes | Slices |
|---|---|---|
| Database (`db/migrations/**`) | New `subscription_pricing` catalog; new `usage_cap_events` table (RLS-ready) | A1, A2 |
| Proxy SQL producers (`tool/advisor_proxy/**`) | top_expensive, margins, cap_events reads; time-window param (monthly) | B2, B3 |
| Proxy hot path | Write a cap-refusal row on 413/429 | B1 |
| Cloud integration (`lib/infrastructure/cloud_run/**`) | GCP read for instance counts / revision | B4 |
| Flutter gateway/contract | `ObservabilityFetchRequest` time-window field | C1 |
| Admin scope plumbing (`lib/admin/widgets/admin_setup_workspace.dart`) | "All businesses" platform scope option | D1 |
| Flutter screen (`lib/admin/screens/observability_admin_screen.dart`) | Full visual redesign: 4 tabs, hero cards, charts, plain labels, icons, drill-downs | E1-E4 |
| Tests | Rewrite `observability_admin_screen_test.dart` (7→4 tabs), fix `admin_shell_widget_test.dart` keys, new producer/migration tests | E5, per-slice |
| QA / acceptance | Admin console browser runbook (port 8186), walkthrough doc, runtime acceptance | F1 |
| Docs / trackers | This plan, walkthrough, audit verdict docs, tracker pointer | F1 |

---

## 5. Slice plan (agent-led: worktree → commit+push → PR → STOP; orchestrator audits + merges)

### Wave A — Schema foundations (serialize the migration chain; schema gate)
- **A1 `subscription_pricing` catalog**: platform-level tier→price (monthly base,
  optional per-seat). Read path for margin = price(tier) [× seats if a seat source is
  confirmed; else flat tier price]. Run `tool/migration_drift_scanner.dart --fix
  --strict-docs` then `tool/migration_cutoff_lint.dart`. OPEN DETAIL: seat-count
  source (members/grants) — resolve in A1; fall back to flat tier price if none.
- **A2 `usage_cap_events`**: append-only refusal log. Columns: `event_id`,
  `operator_id`, `location_id`, `usage_class`, `query_class`, `cap_usd`,
  `attempted_usd`, `occurred_at`. RLS-ready: `(operator_id, location_id)`, leading
  `operator_id` B-tree index, RLS policy stub (CLAUDE.md RLS-Ready Schema). Drift +
  cutoff lint.

### Wave B — Backend producers (serialize: all proxy-touching; proxy gate)
- **B1 cap-refusal write**: at the `ProxyAccountingRefused` site, insert an
  `usage_cap_events` row. Must not change refusal behavior or add latency on the happy
  path. Append-only; failure to log must not block the refusal response.
- **B2 producers**: implement top_expensive (monthly), margins (uses A1), cap_events
  (reads A2) in the observability gateway; remove them from `neutral_empty_surfaces`.
  Keep the `operator_id IS NULL` cross-operator path. Honest empties when no rows.
- **B3 time-window param (monthly)**: plumb `time_window` end-to-end on the proxy side
  (route parser `admin_route_group_part.dart`, gateway interface, SQL bound), capped to
  month buckets. Precedent: debug console `timeWindowSeconds` (`advisor_proxy.dart`
  ~8261; `make_interval` ~9821).
- **B4 hosting (GCP)**: add a read integration (Cloud Run Admin `services.get` or GCP
  Monitoring) for instance count / min-max / revision; populate `cloud_run`. Infra/auth
  gate (service-account scope). Can run as its own track; defer if scope balloons.

### Wave C — Flutter contract (frontend)
- **C1**: add the time-window field to `ObservabilityFetchRequest`
  (`lib/admin/services/observability_admin_gateway.dart`) + emit it; pairs with B3.

### Wave D — Scope plumbing (auth-posture gate; pre-approved)
- **D1 "All businesses"**: add a platform/no-scope option to `AdminSetupWorkspace`
  (shared by ~8 admin screens — blast radius; keep additive + default-off for other
  screens). Lets the screen fetch with `operator_id = null`. super_admin + ff_support
  see the cross-operator aggregate (decision pre-approved).

### Wave E — Frontend redesign (serialize on the screen file)
- **E1 shell + IA**: `OperatorWebScreenFrame`, shared header, `HierarchyScopeNotice`
  (HP#11 preserved), 4-tab structure, hero cards, manual-run posture kept. Honest
  empty-states (Metric Honesty: no phantom zeros).
- **E2 Money tab**: donut (cost by use case), saved-answer reuse bars, Cost controls
  (model mix + batch). Reuse `admin_human_labels`. Theme: add ocean/sand accent tokens
  to `AppColors` if needed (minor theme change, flag at PR).
- **E3 Customers tab**: top spenders bars + Needs attention (losing money, limit hits,
  inactive) + "View account" drill-downs via `AdminRouteHandoff`/`AdminRouteIntent`.
- **E4 Reliability + Knowledge tabs**: speed (link to /health), background jobs,
  hosting, live sync; knowledge counts + freshness.
- **E5 tests**: rewrite `test/admin/observability_admin_screen_test.dart` (7→4 tabs);
  preserve root `Key('admin_observability_screen')` + route title "AI Metrics"; fix
  `test/admin_shell_widget_test.dart`. No silent coverage drop.

### Wave F — Acceptance, QA, docs
- **F1**: browser QA per `runbooks/admin_console_browser_qa_runbook.md` (build flags
  `ADMIN_SHARE_PREVIEW`/`_AS_SUPER_ADMIN`/`ALLOW_PUBLIC_FIXTURE_AUTH`, serve port 8186,
  walk the "AI Metrics" route). Walkthrough doc (numbered click-path). Per-PR audit
  verdict docs at `docs/_audits/<wave>/pr_<n>_<topic>.md`. Tracker pointer update only.

---

## 6. Sequencing, dependencies, serialization

Order (backend-first): A1,A2 → B1 (needs A2), B2 (needs A1+A2), B3+C1, B4 →
D1 → E1→E2→E3(needs B2 producers + D1)→E4→E5 → F1.

Serialize (Cost & Convergence #3, one lane at a time): the migration chain (A1,A2),
all proxy slices (B1-B4), and the screen file (E1-E5). B4 (GCP) and Wave E scaffolding
may proceed on stable contracts but the screen file stays single-lane.

---

## 7. Gates & approvals (CLAUDE.md)

Operator pre-greenlit (decision #5): A1, A2 (schema), B1-B4 (proxy/cloud), D1 (auth
posture). Orchestrator still: pins an audit baseline per PR, runs `tool/pre_merge_gate.sh`
+ `tool/verify_pr_landed.sh` for high-risk PRs (CI dark until 2026-06-01), and re-pings
the operator only if a slice deviates from this plan. Pure-frontend E slices merge on a
clean Pattern B audit.

---

## 8. Compliance checklist (every slice)

- HP#11: keep `HierarchyScopeNotice` (selected scope + inherited source + effective
  value + platform-wide explainer).
- Metric Honesty: no phantom zeros; unavailable → empty-state, real red/yellow not
  laundered to green; `'—'` is the only allowed empty sentinel.
- UX no-em-dash law: `lib/admin/screens` is in `kUxCopyRoots`
  (`tool/ux_em_dash_lint.dart:46`); all new copy complies.
- Demo mode: no `kDemoMode` reader branch; same gateway interface; no `demo_*` tables.
- Runtime acceptance: keep manual-run + confirm + no-auto-poll + bounded/virtualized
  lists.

---

## 9. Open details to resolve in-slice (not blockers)

- A1: seat-count source for revenue (else flat tier price).
- B4: GCP read mechanism + service-account scope (could be deferred without blocking
  the rest).
- D1: AdminSetupWorkspace blast radius — keep the platform option additive so the 7
  other screens are byte-unaffected by default.
- E2: whether the two extra chart accent colors get added to the theme palette.

---

## 10. Test impact (headline)

`test/admin/observability_admin_screen_test.dart` pins all 7 tab keys + many
section/tooltip strings → full rewrite in lockstep with E1-E5. `admin_shell_widget_test.dart`
depends on root key `admin_observability_screen` + route title "AI Metrics" → preserve.
New tests: A1/A2 migration tests, B1-B3 producer tests, B4 integration test.
