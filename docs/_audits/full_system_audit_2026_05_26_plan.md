# Full System Audit Plan - 2026-05-26

## Scope

Audit every active Forge & Flow surface and backend architecture lane for gaps,
bugs, unfinished wiring, contract drift, and missing verification. The admin
console knowledge base work is explicitly out of scope unless another surface
depends on it.

Binding sources already loaded:
- `CLAUDE.md`
- `PROJECT_TRACKER.md`

Additional authority to read before findings are final:
- `docs/contracts/core_app_architecture.md`
- `docs/contracts/**` touched by each lane
- `docs/POST_HARDENING_FOLLOWUPS.md`
- `docs/_indices/NEXT_WAVE_PLAN.md`
- `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`
- `docs/phases/advisor_knowledge_activation/advisor_knowledge_activation_plan.md`
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`
- `runbooks/feature_implementation_lens_audit_runbook.md`
- `runbooks/operator_web_qa_runbook.md`
- `runbooks/admin_console_browser_qa_runbook.md`
- `runbooks/mobile_web_console_e2e_runbook.md`
- deployment, performance, migration, and rollback runbooks as relevant

## Lanes

1. Authority and routing
   - Confirm active plans, hard gates, paused work, and launch blockers.
   - Check docs-to-code promises against current repo structure.

2. Mobile app
   - Audit routes, screens, state, services, demo/live boundaries, settings,
     per-daypart targets, variance, schedule, shift, onboarding, auth, and
     notification surfaces.

3. Operator web
   - Audit route table, shell, account/team/roles, hierarchy, business timing,
     plan, audit log, data accuracy, wage authority, schedule, and vendor
     connection wiring.

4. Admin console
   - Audit admin app routing, businesses, hierarchy, plans and limits,
     support/operations, data accuracy, auth/role gates, and provider
     credentials. Exclude knowledge base implementation work.

5. Backend and proxy
   - Audit `tool/advisor_proxy/**`, auth/session flows, AI/provider
     abstractions, admin/operator routes, idempotency, service principals,
     audit logging, projection retry, vendor sync, and health endpoints.

6. Data, migrations, and persistence
   - Audit SQLite schema, Postgres migrations, RLS-ready requirements,
     operator/location scoping, migration docs, seeders, drift scanners, and
     model/repository boundaries.

7. Infrastructure and runtime
   - Audit Dockerfiles, deploy scripts, Firebase config, Cloud Run manifests,
     monitoring alerts, env-var runbooks, preview/staging/prod assumptions, and
     rollback readiness.

8. Tests and guardrails
   - Audit test coverage, known skipped/quarantined tests, lint tools, release
     guardrails, CI-dark local verification path, and high-risk untested seams.

9. Cross-surface wiring
   - Reconcile mobile/operator/admin/backend/data flows for the same features:
     hierarchy-scoped settings, plans/limits, timing, data accuracy,
     per-daypart targets, vendor connections, auth, audit logs, and demo/live.

## Exhaustion Criteria

A lane is exhausted only after:
- Entry points and route registries are mapped.
- Relevant contracts/runbooks are checked.
- Main implementation files and tests are inspected.
- Mechanical scans are run where useful.
- Findings include concrete file/line evidence or are explicitly marked as
  doc/runbook/product gaps.
- Duplicates and intentional incompletes are removed.

## Status Ledger

- 2026-05-26: Created plan after reading `CLAUDE.md` and
  `PROJECT_TRACKER.md`. Local pre-existing changes observed in
  `web/index.html`, `web/index.prod.html.bak`, and `outputs/`; audit artifacts
  will avoid those paths.
- 2026-05-26: Completed first-wave mobile, operator-web, admin-console
  excluding Knowledge Base, backend/proxy, data/migrations, infra/tests, and
  cross-surface agent lanes. Ran local guardrails and spot checks. Final report:
  `docs/_audits/full_system_audit_2026_05_26_report.md`.
- 2026-05-26/27: Completed fix pass for the code-owned P0/P1/P2 gaps found in
  the audit, including the second-pass open-shift provenance, Operator Web
  plan snapshot, provider-key rotation, account timing ownership, guardrail,
  and orphan-pane cleanup lanes. Remaining items are environment proof,
  deferred vendor scope, production apply, or structural size-headroom work.
  Full analyzer, focused tests, CSP, UX-copy, proxy-size, Operator Web-size,
  release-demo-flag, skip-quarantine, ignore-justification, and
  vendor-completeness guardrails passed locally.
