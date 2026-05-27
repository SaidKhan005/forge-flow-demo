# Deep Unrun-Lane Audit Plan - 2026-05-27

Scope: second audit pass across lanes that were excluded, deferred, newly
landed after the first audit, or only lightly checked in the full-system pass.

Explicit focus:

- Admin Knowledge Base integration and shell boundaries.
- Advisor Knowledge Activation and graph candidate bundle/runtime wiring.
- 11A operations backlog: support audit, cross-operator reads, impersonation.
- Production cutover and migration-apply gates.
- Vendor live rollout and vendor-now-available handoff paths.
- Connected-device and push-delivery proof lanes.
- Business-timing-live hierarchy/settings follow-ups.
- Barrio/frozen flavor boundaries, only for accidental active-code drift.
- Broad placeholder/deferred/unwired route scans outside the prior fix set.

Method:

- Re-read `CLAUDE.md`, `PROJECT_TRACKER.md`, and the active lane docs.
- Compare docs promises to code routes, services, tests, and runbooks.
- Search for placeholder, deferred, not-configured, and no-op surfaces.
- Run cheap static guardrails where useful.
- Record only actionable gaps with concrete file evidence.

Status ledger:

- 2026-05-27: Plan created after the first full-system audit fix pass landed
  on `origin/master` at `ff416729`.
- 2026-05-27: Operator directed Advisor/AI gaps to stay deferred; non-AI
  follow-up fixed admin-pressure placeholders, business suspend reason gating,
  Data Accuracy tab expectations, and the manual covers-row overflow.
