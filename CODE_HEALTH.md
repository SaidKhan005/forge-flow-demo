# Code Health — Closed (2026-05-08)

The 2026-05-06 audit and its remediation across Waves 0/1/2/3/4/5 (52 closed findings across 41 PRs) is closed. The full historical record lives at [`docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md`](docs/archive/code_health/CODE_HEALTH_2026-05-06_remediation.md).

All three original launch blockers are on master:
- LB1 — mobile per-operator isolation ([#294](https://github.com/SaidKhan005/forge-flow-demo/pull/294))
- LB2 — vendor sync log redaction across 17 sinks ([#302](https://github.com/SaidKhan005/forge-flow-demo/pull/302))
- LB3 — sync worker hardening ([#364](https://github.com/SaidKhan005/forge-flow-demo/pull/364))

Open residuals were consolidated into the project's normal tracking surfaces. To find them, follow the authority order from CLAUDE.md:

- **Open P0–P3 items:** [`docs/POST_HARDENING_FOLLOWUPS.md`](docs/POST_HARDENING_FOLLOWUPS.md) carries the bulk — operational items (audit anchor cron unpause), small bug fixes (`backfill_dispatch.dart` bare-catch), architecture cleanups (widget contract violations, monolith splits, common worker base, duplicated abstractions), and latent risks (SQLite singletons, two-slot key vs counter-store granularity).
- **AI-surface follow-ups (paused for V1):** [`docs/phases/phase_11a/phase_11a_decision_register.md`](docs/phases/phase_11a/phase_11a_decision_register.md) — cost-discipline lever wiring, Voyage embedding provider hardening, and the `labor_model.dart` rounding rewrite (the latter touches the 7.58 contract).
- **Phase 8 deferred work:** [`docs/phases/phase_8/phase_8_spine_bridge_plan.md`](docs/phases/phase_8/phase_8_spine_bridge_plan.md) — watermark transactional discipline (needs the 17-adapter executor refactor; was deferred from Wave 5 W5-DISPATCH).
- **Permission catalog additions:** [`docs/contracts/auth_permission_key_catalog.md`](docs/contracts/auth_permission_key_catalog.md) — pending tri-mirror namespace additions (`account.configure`, `business_timing.configure`).

If you reach this file looking for an open item, you're in the wrong place — check those four destinations.
