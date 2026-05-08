# Pressure Preview v1 — Sprint Plan

Date: 2026-05-08
Sprint: `pressure.preview.v1`
Owner: Pressure-test wave (Claude worktrees + master coordination)
Status: Phase 0 (scaffolding)

## Goal

Drive realistic vendor payloads through every infrastructure layer during
the preview environment to find holes that synthetic / unit tests miss.
Use the resulting findings to drive a Postgres unit-test backfill so the
27 of 47 uncovered repositories (per `docs/POST_HARDENING_FOLLOWUPS.md`
P2) are covered by tests grounded in real vendor payload shapes rather
than fabricated fixtures.

The preview proxy URL is:

```
https://forge-flow-preview-backend-surface-additions-prox-rf7nosnoka-pd.a.run.app
```

The preview environment is runtime-isolated (separate Cloud Run revision)
but shares the staging Postgres cluster — operator-approved for Phase 3
load runs, with the understanding that the load lane is bounded.

## Phases

| Phase | Scope | Driver |
|---|---|---|
| 0 | Sprint scaffolding (this) — directories, README format spec, findings doc skeleton, AI-freeze item migration | Claude (this prompt) |
| 1 | 17 vendor payload corpus — verbatim vendor docs JSON per scenario × A–F + happy/sparse + DST + cross-tz | 17 worktrees, one per vendor |
| 2 | 4 pipeline harnesses — adapter (2A) → sink (2B) → spine (2C) → mobile-sync (2D) | 4 worktrees |
| 3 | 3 load harnesses — webhook flood (3A), backfill flood (3B), OAuth-refresh storm (3C) | 3 worktrees |
| 4 | Emulator E2E click-path | User-driven (out of agent scope) |
| 5 | Findings consolidation | Master / Codex |
| 6 | Postgres test backfill driven by Phase 5 findings | Multiple worktrees |

## Vendor Roster (17)

POS (7):

- Lightspeed K-Series (`lightspeed_lsk`)
- Toast (`toast`)
- Clover (`clover`)
- Oracle Simphony (`oracle_micros_simphony`)
- Aloha — NCR Voyix (`aloha_ncr_voyix`)
- Revel (`revel`)
- Square (`square`)

Reservation (4):

- Libro (`libro`)
- Tock (`tock`)
- OpenTable (`opentable`)
- SevenRooms (`sevenrooms`)

Labor (6):

- QuickBooks Time (`quickbooks_time`)
- ADP (`adp`)
- 7shifts (`seven_shifts`)
- Humanity (`humanity`)
- Agendrix (`agendrix`)
- Push Operations (`push_operations`)

Vendor folder names match the existing `docs/integrations/<vendor>/`
directory names verbatim (so cross-references are mechanical).

## Constraints

- **GitHub Actions billing block in effect.** Local Flutter validation
  (`flutter analyze`) must suffice for now; CI is unavailable until the
  block clears. Phases 1–6 plan around this.
- **Vendor sandbox API access is in `*.live.sandbox` slices**, not this
  sprint. Phase 1 fixtures come from public vendor docs only — verbatim
  payload shapes with cited source URLs and retrieval dates. No live
  vendor calls.
- **Preview env runtime-isolated; Phase 3 load hits staging Postgres.**
  Operator-approved with load bounded. Do not run Phase 3 against
  Production1.
- **AI lane frozen.** Phase 11b / 12 advisor work is paused until the
  freeze-thaw checklist (see `phase_11b_advisor_ux_plan.md` "Freeze-thaw
  pre-conditions") clears. Pressure work avoids the advisor surfaces.

## Deliverable Artifact Paths

Per phase:

- **Phase 1:** `test/fixtures/vendor_payloads/<vendor>/<scenario>.json`
  + `<scenario>.source.md` (source URL, retrieval date) + per-vendor
  `README.md` listing scenarios and outcomes.
- **Phase 2:** `test/integration/pressure/<level>/` — 2A adapter, 2B
  sink, 2C spine, 2D mobile-sync.
- **Phase 3:** `test/load/pressure/<lane>/` — 3A webhook flood, 3B
  backfill flood, 3C OAuth-refresh storm.
- **Phase 5:** `docs/_execution/2026-05-08_pressure_preview_findings.md`
  filled with results.
- **Walkthrough:** `docs/_walkthroughs/pressure.preview.v1.md`
  (operator-facing per HP #10; created in Phase 5 alongside findings).

## Phase 0 Scope (this commit)

- Directory tree under `test/fixtures/vendor_payloads/`,
  `test/integration/pressure/`, `test/load/pressure/`.
- README format spec at `test/fixtures/vendor_payloads/README.md`.
- Per-layer harness READMEs at `test/integration/pressure/README.md` and
  `test/load/pressure/README.md`.
- Findings doc skeleton at
  `docs/_execution/2026-05-08_pressure_preview_findings.md`.
- AI-freeze item migration: move 2 items out of
  `docs/POST_HARDENING_FOLLOWUPS.md` Audit-additions section into the
  proper phase docs so they're not stranded under POST_HARDENING when
  the AI freeze lifts.

## Out of Scope (Phase 0)

- No fixture content (Phase 1).
- No harness code (Phases 2–3).
- No load runs (Phase 3).
- No findings beyond skeleton placeholders (Phase 5 fills).
- No vendor sandbox credentials, OAuth flows, or live HTTP calls.

## References

- `docs/archive/phases/phase_8/phase_8_live_pos_labor_adapter_plan.md` —
  binding A-F scenario set adopted by every vendor in Phase 1.
- `docs/POST_HARDENING_FOLLOWUPS.md` — the test-coverage gap
  (47 repos / 20 covered) Phase 6 closes.
- `docs/_execution/2026-05-08_preview_proxy_deferred_startup_execution.md`
  — preview proxy state at sprint start.
- `docs/integrations/<vendor>/` — per-vendor lifecycle + adapter notes
  (already exists; Phase 1 cross-references but does not modify).
