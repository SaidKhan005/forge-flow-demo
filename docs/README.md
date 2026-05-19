# Docs Layout

Updated: 2026-05-19

This describes the current `docs/` tree after the Waves 1 to 6 consolidation.
List only reflects folders and key files that actually exist now.

## Root authority docs (fastest entry)

- `PROJECT_TRACKER.md` (repo root): live project tracker.
- `docs/contracts/core_app_architecture.md`: canonical Phase 7.55 architecture
  authority. This is the architecture source of truth.
- `docs/DATA_ALIGNMENT_TRACKER.md`: data alignment tracker.
- `docs/POST_HARDENING_FOLLOWUPS.md`: post-hardening follow-up ledger.
- `docs/KNOWN_FAILING_TESTS.md`: pre-existing test failures (expected, not regressions).
- `docs/CODEX_PROMPT_GENERATION_STANDARD.md`: executor prompt-shape rules.
- `docs/ARCHITECTURE.md`: a personal study doc only. NOT a repo authority.
  Canonical architecture is `docs/contracts/core_app_architecture.md`.

## Folders

- `docs/contracts/`: active, binding architecture and timing rules
  (Tier-2/Tier-3). Other live docs point here instead of restating them.
- `docs/phases/`: still-live lane planning docs grouped by phase family.
  Live groups: `per_daypart_targets_v1/`, `phase_8/`,
  `phase_8_live_rollout/`, `phase_9/`, `phase_9_5/`, `phase_9_75/`,
  `phase_9_8/`, `phase_11a/`, `phase_11A_operations_console/`,
  `phase_11W/`, `phase_business_timing_live/`,
  `phase_production_cutover/`, `proxy_split/`, `variance_coaching_v2/`.
- `docs/_execution/`: active execution plans only (closed plans archived).
- `docs/_indices/`: forward plan, wave plan, active ledgers, handoff prompts.
- `docs/_audits/`: audit artifacts, including the doc consolidation plan
  and active per-daypart / parity audit work.
- `docs/_walkthroughs/`: open-slice runtime walkthroughs only
  (closed-phase walkthroughs archived).
- `docs/integrations/`: per-vendor doc packs, governed by
  `docs/contracts/per_vendor_doc_pack_contract.md` (folder shape is contractual).
- `docs/Knowledge_graph_docs/`: founder-authored RAG corpus governed by
  `corpus_manifest.yaml`. Load-bearing for retrieval.
- `docs/business/`: business plan, cost, funding, and IP collateral.
- `docs/f&f Coaching/`: coaching feature prototypes, mockups, and plans.
- `docs/archive/`: history. Completed phase slices, retired reference docs,
  internal notes, and tracker history. Ignore unless a prompt names it.

## Runbooks (now unified)

There is one runbook home: the repo-root `runbooks/` folder. The former
docs frameworks folder has been removed; its repeatable cross-surface
execution frameworks now live in root `runbooks/` alongside the
operational runbooks. The two prior runbook homes are unified into one.

## Working rule

If a doc is:

- an active, binding architecture rule: put it in `docs/contracts/`
- a repeatable cross-surface execution framework or operational procedure:
  put it in root `runbooks/`
- an active planning lane doc: put it in `docs/phases/<lane>/`
- an active execution plan: put it in `docs/_execution/`
- completed and no longer part of the live working spine: move it to
  `docs/archive/`

If a phase family is still live but an individual slice inside it is
complete, archive that slice under `docs/archive/phases/<lane>/` and keep
only the still-live planning docs in `docs/phases/<lane>/`.

The goal is simple: the docs root stays quiet, and the live authority
path is easy to scan.
