# Admin Hierarchy Settings Overhaul — Closure Evidence (2026-05-12)

Status: **complete**.
Plan: `docs/_execution/admin_hierarchy_settings_overhaul_plan_2026-05-08.md`.

## Slice-to-PR map

All 12 slices (0–11) landed on master. PR / commit map:

| Slice | Subject | Landed via |
|---|---|---|
| 0 | Shared scope seam (`AdminHierarchyScopeIntent`) | `572d34de` "Implement admin setup no-popup scope seam (#466)" |
| 1 | Business accounts IA | `b509c522` business-accounts-launcher cleanup; `2af48d4b` tile label polish |
| 2 | Hierarchy CRUD route contracts | `dc11523e` route contract align; `f3c19323` org-unit create; `4979d4db` move gate |
| 3 | Hierarchy-aware location create | PR #488 `01c48921` lifecycle access hardening + migration `db/migrations/202605082200_admin_hierarchy_lifecycle.sql` |
| 4 | People / access / roles | PR #468 `8a0441af` merge people-access-roles |
| 5 | Security / audit / sessions | `722e384a` sessions under security/audit + PR #488 audit hardening |
| 6 | Account profile + contact email | `b700c8b8` contact-email polish |
| 7 | Timing | `3198630f` hierarchy timing provenance + PR #485 (`a2766824`) HP #11 inheritance-notice retroactive fix |
| 8 | Data accuracy + polling | `f84ee490` scoped data accuracy + migration `db/migrations/202605121200_admin_hierarchy_scoped_data_polling.sql` |
| 9 | Integrations | `808be4a8` location-scoped integrations + `018a6e07` hierarchy vendor settings + PR #467 |
| 10 | Support logs | `216ea301` scoped support logs |
| 11 | Final integration + cleanup | PR #481 `44e225a9` UX consolidation + `c2695c79` audit-gap close + PR #482 + PR #485 retroactive audit |

## Orchestrator audit chain (all on master)

- `docs/_audits/post_codex_wave/pr_481_retroactive_audit.md` — 7-chunk retroactive audit for PR #481 (the big-bang consolidation that bypassed the audit gate)
- `docs/_audits/post_codex_wave/pr_482_audit.md` — light-playbook audit
- `docs/_audits/post_codex_wave/pr_484_audit.md` — audit-log contract schema (PR C)
- `docs/_audits/post_codex_wave/pr_488_audit.md` — admin hierarchy lifecycle access hardening (PR B)
- `docs/_audits/post_codex_wave/pr_490_audit.md` — admin audit target attribution (PR A)
- `docs/_audits/post_codex_wave/pr_b_pr_a_rollup_audit.md` — recovery rollup (PR #492) after PR B + PR A's stacked-merge base drift

## Operator visual verification (2026-05-12)

Run mode: `flutter run --release -t lib/main_admin.dart -d web-server --dart-define=ADMIN_DEMO_AUTH=true --web-port=8090`. Driven via the Claude Preview MCP — Flutter semantics tree activated, taps dispatched as pointer-event sequences at semantic-node coordinates. Demo fixture: `super.admin@forgeflow.test` (Ecosystem admin). No live backend; demo source returned in-memory fixtures.

### PR #485 — admin timing scope inheritance notice (HP #11)

| Scope | Expected | Observed | Verdict |
|---|---|---|---|
| Business scope (Demo Diner Co., 2 covered locations) | Notice card renders: *"Showing timing from Toronto Yorkville. Other locations under this scope may have local overrides — review each location individually for accuracy."* | Exact text rendered above the timing detail card; key `admin_timing_scope_inheritance_notice` present | ✅ PASS |
| Location scope (Toronto Yorkville, 1 covered location) | Notice card **suppressed** | No "Showing timing from" anywhere on page; only the regular Effective timing card renders | ✅ PASS |

### PR #482 — admin shell back navigation (5 surfaces)

Every back arrow on every admin surface visited carries the aria-label `Back to Business accounts`. Click returned to the **Business accounts → Demo Diner Co.** detail (not all the way to admin home, not stuck on the current screen).

| Surface | Entry tile / nav | Title rendered | Back-nav target | Verdict |
|---|---|---|---|---|
| Timing | Business setup → Timing tile (business scope) | "Timing — Review timezone, business day, and service periods..." | Business accounts → Demo Diner Co. | ✅ PASS |
| Data Accuracy | Business setup → Covers and Wage Data Accuracy tile | "Covers and Wage Data Accuracy — Review covers, wage data, vendor filters, and audit history..." | Business accounts → Demo Diner Co. | ✅ PASS |
| Polling Setup | Business setup → Polling setup tile | "Polling Setup — Choose the hierarchy scope, assign vendor polling tiers, and estimate operating cost." | Business accounts → Demo Diner Co. | ✅ PASS |
| People, access, and roles | Business setup → People, access, and roles tile | "People, access, and roles — Manage members, invites, role assignments, and access policy..." | Business accounts → Demo Diner Co. | ✅ PASS |
| Support logs (Business scope tile) | Business setup → Support logs tile | "Support logs — Review support-safe requests, relationship help, and account help..." | Business accounts → Demo Diner Co. | ✅ PASS |

Naming note: the prior audit doc referenced "Audited Support Actions"; the PR #481 consolidation renamed this surface to "Support logs". Same screen, new label.

## Bug hunt during walkthrough

| Source | Findings |
|---|---|
| Browser console (`error` level + `warn` level, 100-line buffer) | **0 logs** across the entire session |
| Network failures (`gh preview_network filter=failed`) | 3 transient probes during build (1× `net::ERR_CONNECTION_REFUSED` and 2× `500 Internal Server Error`) — all before Flutter's first 200; no failures after the app loaded |
| Visible UI glitches | None |

## What was NOT tested

- **Live proxy backend.** Demo run used the in-memory `DemoAdminAuthSource` + fixture admin gateways. Mutating end-to-end with a real proxy is the next gate (preview environment) but is out of scope for the visual-only sign-off.
- **Cross-flavor parity.** Operator-web console + mobile carry-over of these settings were not driven in this session; tracked separately under `phase_11W.*`.
- **Permission-key gating per role.** The walkthrough drove as `super_admin`. Support / operator-owner role views were not exercised in this session.

## Out-of-scope drift observation (carried from prior audits, not a closure blocker)

`tool/advisor_proxy/proxy_bootstrap.dart:3640` emits `actorKind: 'user'` for the operator-location admin audit fan-out, which maps to `actor_kind = 'team_member'` in `audit_logs` rather than `'forge_admin'`. PR #490's stated scope was "preserve PR C contract" and explicitly NOT to flip this. Carried in `pr_490_audit.md` "Drift observation". Suggest adding to `docs/POST_HARDENING_FOLLOWUPS.md` for a future targeted fix; not required for this closure.

## Closure decision

**Engineering-complete.** All 12 slices on master, all 6 audit docs on master, all 5 PR #482 back-nav surfaces visually verified, PR #485 inheritance notice visually verified at both scopes, zero console errors during the walkthrough.
