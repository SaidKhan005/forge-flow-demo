# Docs Mega Lean-Out + Consolidation Plan (analysis only)

Status: **PLAN ONLY — no doc deleted, moved, merged, or rewritten by this PR.**
Date: 2026-05-18
Author: Claude docs-architecture analyst
Method: token-aware inventory (`ls`/Glob/Grep + header-only reads; full reads
only to confirm a staleness/duplication call).

Authority guardrail honored: per `CLAUDE.md` "Authority Order", **no binding
Tier-2/Tier-3 contract under `docs/contracts/**` is proposed for retirement.**
Contracts may be consolidated/clarified or flagged STALE-FIX; never cut.
The 2026-05-18 doc-alignment audits
(`docs/_audits/doc_alignment/phase{1,2,3,4}_*.md`) are used as prior art:
they already found the `docs/contracts/**` set substantially aligned with
code, so this plan treats contracts as KEEP and only lists the few
already-known drifts as STALE-FIX (no new contract verdicts invented).

---

## 1. Excluded-scope note

Per the prompt, the following are **entirely out of scope** and were not
inventoried or classified:

- `docs/archive/**` — 328 md files. History; ignore unless named.
- `docs/business/**` — 1 file. Business collateral, excluded by instruction.
- `docs/f&f Coaching/**` — the F&F coaching folder (found at
  `docs/f&f Coaching/`, 2 files incl.
  `variance_coaching_v2_implementation_plan.md`). Excluded by instruction.
  NOTE: it is referenced as "Plan of record" by
  `docs/_indices/VARIANCE_COACHING_V2_LEDGER.md` — left untouched, just flagged.
- `CLAUDE.md` — handled separately by the operator. Noted, not edited, not
  proposed for edits.

Everything else in `docs/**`, root `PROJECT_TRACKER.md`, `runbooks/**`, and
root `*.md` authority/process files is in scope.

---

## 2. Folder-level verdict table

Token weight: S = small (folder is a few KB / quick scan), M = medium,
L = large (would dominate an agent's context if read whole).

| Folder / file group | md count | Verdict | One-line rationale | Token wt |
|---|---|---|---|---|
| `docs/contracts/` | 38 | **KEEP** (consolidate-only, gated) | Binding Tier-2/3; prior audit says substantially aligned. Never retire. | L |
| `docs/frameworks/` | 5 | **CONVERT → `runbooks/` then KILL folder** | All 4 content files are repeatable execution guides = runbooks. Operator's flagged example. | S |
| `docs/runbooks/` | 3 | **RELOCATE → root `runbooks/` then KILL folder** | Two runbooks dirs (`docs/runbooks/` + `runbooks/`) is needless split. | S |
| `runbooks/` (root) | 24 (+1 sub) | **KEEP** (absorb the above) | Canonical runbooks home; CLAUDE.md + tracker point here. | M |
| `runbooks/phase_production_cutover/` | 1 | **MERGE up** | 1 file in a folder; flatten into `runbooks/`. | S |
| `docs/phases/` | 30 across 14 subdirs | **KEEP + RETIRE closed subdirs** | Active plans stay; closed-phase subdirs go to archive. | L |
| `docs/_indices/` | 9 | **KEEP core + RETIRE dated one-offs** | 3 dated PER_DAYPART handoff/dispatch one-offs are spent. | M |
| `docs/_audits/` | 113 across 9 subdirs | **KEEP active + RETIRE closed-wave** | Audit history; closed waves are archive-class. | L |
| `docs/_audits/doc_alignment/` | 4 | **KEEP** | Current (2026-05-18) prior art; load-bearing for this plan. | S |
| `docs/_audits/repo_cleanup_v1/` | 2 (+3 logs) | **RETIRE** | Closed 2026-05-16 cleanup closeout + raw prune logs. | S |
| `docs/_audits/post_codex_wave/` | 12 | **RETIRE** | Post-Codex wave closed; superseded by Wave 2 + per-daypart. | M |
| `docs/_audits/wave_2/` | 7 (mostly .png) | **RETIRE** | Wave 2 operator-web/admin lanes CLOSED 2026-05-14. | S |
| `docs/_audits/variance_coaching_v2/` | 2 (+shots) | **RETIRE on close** | Lanes A–F merged; retire when Lane G closes. | S |
| `docs/_audits/cross_surface_parity_v1/` | 8 | **STALE-FIX / triage** | Some specs absorbed into per-daypart; confirm before archiving. | M |
| `docs/_audits/per_daypart_v1/` | 67 | **KEEP (active)** | Active feature work; do not touch. | L |
| `docs/_audits/code_health/` | 9 | **KEEP (reference)** | Monolith/decomposition maps still referenced. | M |
| `docs/_execution/` | 34 across 6 subdirs | **MOSTLY RETIRE** | Tracker says stale sprint-execution → `docs/archive/_execution/`. | M |
| `docs/_decisions/` | 3 | **RETIRE (absorbed)** | 2026-05-12 post-Codex decision locks; decisions now in trackers/contracts. | S |
| `docs/_research/post_codex/` | 4 | **RETIRE** | Post-Codex research inputs; wave closed. | S |
| `docs/_walkthroughs/` | 92 | **RETIRE closed-slice, KEEP index** | One file per shipped slice; vast majority are closed phases (8/9/10/11). | L |
| `docs/integrations/` | 109 across 18 dirs | **KEEP (governed)** | Per-vendor 6-file pack governed by a contract; structurally required. | L |
| `docs/Knowledge_graph_docs/` | 8 (+manifest) | **KEEP** | Founder-authored corpus governed by `corpus_manifest.yaml`; load-bearing for RAG. | M |
| `docs/ARCHITECTURE.md` | 1 (3586 ln) | **RETIRE → archive (superseded)** | Superseded by canonical `contracts/core_app_architecture.md` + plain-english companion. | L |
| `docs/README.md` | 1 | **STALE-FIX (rewrite later)** | Describes a 5-bucket layout that no longer matches reality (missing 8 folders, names dead folders). | S |
| `docs/CODEX_PROMPT_GENERATION_STANDARD.md` | 1 | **KEEP** | Live prompt-shape authority (tracker authority order #6). | M |
| `docs/DATA_ALIGNMENT_TRACKER.md` | 1 | **KEEP** | Active tracker (CLAUDE.md authority #4). | M |
| `docs/POST_HARDENING_FOLLOWUPS.md` | 1 | **KEEP** | Active P0–P3 ledger (CLAUDE.md authority #4). | M |
| `docs/KNOWN_FAILING_TESTS.md` | 1 | **KEEP** | Active known-fails list. | S |
| `PROJECT_TRACKER.md` (root) | 1 | **KEEP** | Routing index (CLAUDE.md authority #4 / tracker authority #1). | M |
| `README.md` (root) | 1 | **KEEP** | Repo front door. | S |
| `apple_todo.md` (root) | 1 | **RELOCATE → `docs/`** | Deferred-work list; not a root authority/process file. | S |
| `debug.md` (root) | 1 | **KEEP (referenced)** | Operator brain-dump; tracked by `DEBUG_MD_IMPLEMENTATION_STATUS.md`. Keep until that tracker closes. | S |
| `study.md` (root) | 1 | **RELOCATE → `docs/` or RETIRE** | Personal study/notes on env model; not authority. | S |

---

## 3. Folder-kill proposals (explicit)

**Target: 9 folders/dirs disappear entirely** (8 in-scope folder kills +
1 single-file runbook subdir flatten). Net direction: two runbook homes
become one; spent wave/research/decision/execution folders collapse into
the existing archive; the stale mega-architecture doc retires.

### KILL 1 — `docs/frameworks/` → `runbooks/` (operator's flagged example)

The 4 content files are "repeatable execution/prompt guides" — that is the
definition of a runbook in this repo. Move, then delete the folder.

| From | To |
|---|---|
| `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md` | `runbooks/feature_implementation_lens_audit_runbook.md` |
| `docs/frameworks/MOBILE_WEB_CONSOLE_E2E_FRAMEWORK.md` | `runbooks/mobile_web_console_e2e_runbook.md` |
| `docs/frameworks/PERFORMANCE_FRAMEWORK.md` | `runbooks/performance_audit_runbook.md` |
| `docs/frameworks/UX_ADJUSTMENT_FRAMEWORK.md` | `runbooks/ux_adjustment_runbook.md` |
| `docs/frameworks/README.md` | (delete — fold one line into `runbooks/` README if one is added) |

Folder `docs/frameworks/` is **deleted**.
**Reference-update cost (must ship in the same PR):** `CLAUDE.md` (5
references — operator handles CLAUDE.md separately, so coordinate),
`PROJECT_TRACKER.md` (authority order #7 + lens-audit line),
`docs/README.md`, and any `docs/_audits/**`/`docs/phases/**` that cite a
framework path. This is the highest-link-fanout kill — do it as its own
wave with a pre-flight `rg` of every `docs/frameworks/` string.

### KILL 2 — `docs/runbooks/` → root `runbooks/`

| From | To |
|---|---|
| `docs/runbooks/firebase_auth_email_templates_production1.md` | `runbooks/firebase_auth_email_templates_production1.md` |
| `docs/runbooks/mfa_removal_worker_deploy_runbook.md` | `runbooks/mfa_removal_worker_deploy_runbook.md` |
| `docs/runbooks/proxy_rollback_runbook.md` | `runbooks/proxy_rollback_runbook.md` |

Folder `docs/runbooks/` is **deleted**. Two runbook homes is exactly the
"needless folder/repetition" the operator wants gone.

### KILL 3 — flatten `runbooks/phase_production_cutover/`

One file (`cutover_4_stabilization_runbook.md`) in its own dir. Move to
`runbooks/cutover_4_stabilization_runbook.md`; delete the subdir.

### KILL 4 — `docs/_research/post_codex/` → `docs/archive/_research/post_codex/`

4 research input files for a closed wave. Folder gone from live tree.

### KILL 5 — `docs/_decisions/` → `docs/archive/_decisions/`

3 dated post-Codex decision-lock docs (2026-05-12). Decisions are absorbed
into trackers/contracts. Folder gone from live tree.

### KILL 6 — `docs/_audits/repo_cleanup_v1/` → `docs/archive/_audits/repo_cleanup_v1/`

Closeout + raw prune logs/TSV from the closed 2026-05-16 cleanup.

### KILL 7 — `docs/_audits/post_codex_wave/` → archive

12 wave-audit files; wave closed and superseded.

### KILL 8 — `docs/_audits/wave_2/` → archive

7 files (mostly screenshots); Wave 2 lanes CLOSED 2026-05-14.

(`docs/_execution/` is not a full folder-kill because
`per_daypart_server_parity_execution_plan.md` is 2026-05-18 active — see
§5; the spent subdirs inside it retire, the folder thins but survives for
the one active doc, or that doc relocates and the folder dies — operator
choice noted in §6 Wave 4.)

---

## 4. Repetition clusters (same thing said in many places → pick one winner)

### Cluster A — "What is the architecture" (3 docs, ~4700 lines total)

| Doc | Lines | Verdict |
|---|---|---|
| `docs/contracts/core_app_architecture.md` | 665 | **WINNER** — canonical (CLAUDE.md authority #2). |
| `docs/contracts/phase_7_55_plain_english_architecture.md` | 443 | KEEP — sanctioned plain-english companion. |
| `docs/ARCHITECTURE.md` | 3586 | **RETIRE** — pre-canonical (updated 2026-04-29, before the 7.55 canonical doc). A 3.5k-line near-duplicate is a token tax on every reader who lands on the root by name. |

Winner: the contracts pair. `docs/ARCHITECTURE.md` retires to
`docs/archive/reference/`; tracker/README references repoint to
`docs/contracts/core_app_architecture.md`. (Flagged operator-gated because
some onboarding text and `docs/README.md` name it as a "root authority doc".)

### Cluster B — Per-Daypart V1 orchestration handoffs (4 docs)

`docs/_indices/PER_DAYPART_V1_CLAUDE2_HANDOFF.md`,
`PER_DAYPART_V1_MAIN_ORCHESTRATOR_BRIEF.md`,
`PER_DAYPART_V1_POST_SLICE1_DISPATCH.md` all restate the same plan +
dispatch state that the canonical
`docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md` owns.
Winner: the plan doc. The 3 dated handoff/dispatch one-offs RETIRE (spent
the moment Slice 1 merged). The brief may stay if the orchestrator still
uses it; default = retire post-feature-close.

### Cluster C — Two runbook homes (`docs/runbooks/` vs root `runbooks/`)

Same doc class, two locations. Winner: root `runbooks/` (see KILL 2).

### Cluster D — Decision locks vs trackers (`docs/_decisions/**`)

The 3 decision-lock docs duplicate decisions now normative in
`PROJECT_TRACKER.md` / contracts / `docs/POST_HARDENING_FOLLOWUPS.md`.
Winner: the trackers/contracts. `_decisions/` retires (KILL 5).

### Cluster E — Closed-wave execution packets (`docs/_execution/**`)

`admin_hierarchy_settings_overhaul/`, `admin_hierarchy_ux_cleanup/`,
`lane_a_code_health/`, `lane_b_features/`, `lane_c_parity/`,
`b1_b2_proxy_soak_fix/`, `b3_email_silent_failure_fix/` are spent
parallel-lane packets (the overhaul packet is even marked
`complete (2026-05-12)` in the tracker). PROJECT_TRACKER.md line 5 already
declares "Stale sprint-execution docs: `docs/archive/_execution/`" — these
belong there. Winner: the tracker's own stated convention.

---

## 5. Staleness list (dated / superseded / contradicted)

| Doc | Problem | Verdict | Successor / authority |
|---|---|---|---|
| `docs/README.md` | Describes a 5-bucket layout updated 2026-05-08; names dead folders (`phase_8R/`, `phase_7_58/`, `phase_10a/`, `phase_10_5/`, `docs/app_store_release/`); never mentions `_audits/ _execution/ _indices/ _walkthroughs/ _decisions/ _research/ integrations/ Knowledge_graph_docs/`. Self-contradicts current tree. | **STALE-FIX** (rewrite in a later wave AFTER the kills land, so it documents the lean tree). | The post-lean folder tree itself. |
| `docs/ARCHITECTURE.md` | Updated 2026-04-29, reviewed through 2026-04-28 — predates the Phase 7.55 canonical contract. 3586 lines duplicating canonical architecture. | **RETIRE → `docs/archive/reference/`** | `docs/contracts/core_app_architecture.md` (+ plain-english companion). |
| `PROJECT_TRACKER.md` index table | References `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` + `CODEX_HANDOFF_PROMPT.md` as live paste-ready docs. **Those files do not exist in `docs/_indices/`** — only in `docs/archive/_indices/wave_2_closeout_2026_05_15/`. Dead pointer. (CLAUDE.md "Routing" also names these paths — note for the separate CLAUDE.md pass.) | **STALE-FIX** (repoint or restore; do NOT fix here). | Decide: restore canonical handoff prompts to `_indices/` or repoint the tracker to the archived copies. |
| `docs/_indices/PER_DAYPART_V1_*` (3 dated one-offs) | "paste this as FIRST message", "fire the moment Slice 1 (PR #767) merges" — single-use, Slice 1 long merged. | **RETIRE → `docs/archive/_indices/`** | `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`. |
| `docs/_decisions/*` (3) | Dated 2026-05-12 post-Codex locks; absorbed. | **RETIRE** | Trackers + contracts. |
| `docs/_research/post_codex/*` (4) | Closed-wave research inputs. | **RETIRE** | n/a (history). |
| `docs/_audits/repo_cleanup_v1/*` | Closeout marks itself "blocked / operator decision required" for a pass that has since closed (master moved well past 2026-05-16). | **RETIRE** | Repo state itself. |
| `docs/_audits/post_codex_wave/*`, `docs/_audits/wave_2/*` | Closed-wave audit artifacts. | **RETIRE** | Per-daypart audits + Wave 2 ledger. |
| `docs/_audits/cross_surface_parity_v1/*` | Specs (e.g. `fix4_hp11_effective_value_spec.md`, `onboarding_server_slice_spec.md`) likely absorbed by per-daypart / landed PRs (#831/#832 referenced). | **STALE-FIX (triage before archive)** | Confirm each spec's landed-state via `tool/verify_pr_landed.sh` before retiring. |
| `docs/_execution/**` spent packets | Tracker line 5 already routes stale sprint-execution to archive; one packet is tracker-marked complete. | **RETIRE** | `PROJECT_TRACKER.md` convention. |
| `docs/_walkthroughs/*` for closed phases (8.x, 9.x, 10.x, 11A/11W) | One file per shipped slice; phases retired (tracker line 16: phase_10b/11b/12/8_5 retired). Walkthroughs of closed slices are evidence-history. | **RETIRE closed-slice files; KEEP `README.md` + any open-slice (per-daypart) walkthrough** | The phase archive + per-daypart plan. |
| `apple_todo.md`, `study.md` (root) | Not root authority/process docs — a deferral list and a personal study note sitting in the repo root. | **RELOCATE** (`apple_todo.md`→`docs/`, `study.md`→`docs/` or retire) | n/a. |
| Known contract drifts (from `docs/_audits/doc_alignment/phase{1,4}`) | e.g. `core_app_architecture.md` 4 narrow factual lags (7shifts wage class, 5th metric state, provenance suffix, service-period rename); a few STALE citations elsewhere. | **STALE-FIX — list only, contracts are NOT cut** | Already enumerated in the 4 phase audits; fix is a separate gated contract-edit task, not this lean-out. |

**No `docs/contracts/*.md` is on the RETIRE list.** Contracts appear only
as STALE-FIX, exactly as the guardrail requires.

---

## 6. Sequenced execution plan (safe waves; each = one agent PR)

Ordering principle: lowest blast-radius first (closed history with near-zero
inbound links), highest-fanout last (frameworks kill rewrites authority
docs), contracts never in a lean-out wave at all. Every wave is
move-to-archive or relocate — **no content rewrites except the final
README refresh.** Each wave updates inbound references in the SAME PR and
runs a pre-flight `rg "<old path>"` sweep.

| Wave | Scope | Risk | Why this order |
|---|---|---|---|
| **0 (this PR)** | This plan doc only. | none | Analysis, no changes. |
| **1 — Closed audit/research/decision history** | KILL 4,5,6,7,8: move `docs/_research/post_codex/`, `docs/_decisions/`, `docs/_audits/{repo_cleanup_v1,post_codex_wave,wave_2}/` into `docs/archive/**`. | LOW | Zero/near-zero live inbound links; pure history. Safest possible start. |
| **2 — Closed execution packets** | RETIRE spent `docs/_execution/**` subdirs to `docs/archive/_execution/` (keep the 2026-05-18 active `per_daypart_server_parity_execution_plan.md` in place or relocate it; thin/kill the folder accordingly). | LOW-MED | Tracker already declares the archive route; one packet is tracker-marked complete. Update the 2 tracker lines that cite `_execution/` paths. |
| **3 — Closed-slice walkthroughs + dated index one-offs** | RETIRE closed-phase `docs/_walkthroughs/*` (keep README + open per-daypart walkthroughs); RETIRE the 3 `PER_DAYPART_V1_*` one-offs; relocate `apple_todo.md`/`study.md`. | MED | Large file count but evidence-class; keep the index + anything tied to active per-daypart. |
| **4 — Runbook unification** | KILL 2 (`docs/runbooks/`→root) + KILL 3 (flatten `runbooks/phase_production_cutover/`). Update tracker/CLAUDE-side runbook references. | MED | Moderate fanout; consolidates the two-home split. |
| **5 — `docs/ARCHITECTURE.md` retire** | Move to `docs/archive/reference/`; repoint `docs/README.md` + `PROJECT_TRACKER.md` + onboarding text to `docs/contracts/core_app_architecture.md`. | MED-HIGH (**operator-gated**) | It is named a "root authority doc"; retiring an authority-named doc needs operator sign-off even though it is superseded. |
| **6 — `docs/frameworks/` → `runbooks/` (the headline kill)** | KILL 1: move 4 frameworks, delete folder, rewrite ALL inbound references (PROJECT_TRACKER.md authority order #7 + lens line, docs/README.md, audit/phase cites; coordinate the CLAUDE.md 5 refs with the operator's separate CLAUDE.md pass). | HIGH | Highest link fanout + touches authority order; do it last, alone, with a full pre-flight `rg docs/frameworks` and a reference-update checklist in the PR. |
| **7 — `docs/README.md` rewrite + STALE-FIX list handoff** | Rewrite `docs/README.md` to document the now-lean tree; file the contract STALE-FIX list + dead-handoff-pointer + cross_surface_parity triage as separate gated tasks (NOT executed here). | LOW (content) | Done last so the README documents the final shape, not a moving target. |

Contracts: **never appear in any lean-out wave.** Their only follow-up is
the Wave 7 STALE-FIX handoff, which is a separate operator-gated
contract-edit task outside this consolidation.

---

## 7. Risks + "do NOT touch" list

### Do NOT touch (binding / active / load-bearing)

- **All of `docs/contracts/**`** — binding Tier-2/3 (CLAUDE.md authority
  #2/#3). Prior audit says aligned. Consolidate/clarify only with operator
  gate; never retire. Not in any lean-out wave.
- **`PROJECT_TRACKER.md`, `docs/DATA_ALIGNMENT_TRACKER.md`,
  `docs/POST_HARDENING_FOLLOWUPS.md`, `docs/KNOWN_FAILING_TESTS.md`** —
  active trackers/ledgers (CLAUDE.md authority #4). Edit only the specific
  reference lines a wave's moves invalidate, in that wave's PR.
- **`docs/phases/per_daypart_targets_v1/**` and
  `docs/_audits/per_daypart_v1/**`** — active feature work. Hands off.
- **`docs/_audits/doc_alignment/phase{1,2,3,4}_*.md`** — current (2026-05-18)
  load-bearing prior art. Keep.
- **`docs/integrations/**`** — structurally governed by
  `docs/contracts/per_vendor_doc_pack_contract.md` (6-file pack per vendor);
  the folder shape is contractual, not redundant.
- **`docs/Knowledge_graph_docs/**`** — founder-authored RAG corpus governed
  by `corpus_manifest.yaml`; load-bearing for retrieval.
- **`CLAUDE.md`** — operator's separate pass. This plan only *notes* its
  framework/handoff references so the operator can coordinate; it proposes
  no CLAUDE.md edits.
- **`docs/_decisions/**` content as decisions** — archive the *docs*, but
  the *decisions* must already be reflected in trackers/contracts before
  archiving (verify, don't assume).

### Risks

1. **Reference rot.** Every move orphans inbound links (tracker authority
   order, README, audits, CLAUDE.md). Mitigation: each wave runs a
   pre-flight `rg "<old path>"`, fixes refs in the same PR, and lists the
   ref-update checklist in the PR body. Frameworks (Wave 6) is the riskiest.
2. **"MERGED ≠ landed" / moving base.** Closed-wave artifacts may still be
   cited by an in-flight lane. Mitigation: before Wave 1–3, `rg` each
   target path across the *live* tree (excluding `docs/archive/**`); if a
   live non-archive doc cites it, downgrade that file to STALE-FIX instead
   of RETIRE.
3. **Spec-absorption uncertainty.** `cross_surface_parity_v1` specs may not
   be fully landed. Mitigation: `tool/verify_pr_landed.sh` per spec before
   archiving (STALE-FIX, not blind RETIRE).
4. **Authority-doc retirement.** Retiring `docs/ARCHITECTURE.md` (named a
   root authority doc) is correct (superseded) but must be operator-gated
   (Wave 5) — same gate class as contract/auth changes.
5. **Walkthrough evidence loss.** `_walkthroughs/` is HP#10 demo evidence.
   Mitigation: archive (not delete), keep README + all open-phase
   walkthroughs, never touch per-daypart ones.
6. **Contract STALE-FIX scope creep.** Tempting to "just fix" the 4 known
   `core_app_architecture.md` drifts here. Do NOT — that is a separate
   gated contract-edit task. This plan only lists them.

---

### Headline numbers

- **Folder kills proposed: 9** (frameworks; docs/runbooks; runbooks
  prod-cutover subdir; `_research/post_codex`; `_decisions`;
  `_audits/repo_cleanup_v1`; `_audits/post_codex_wave`; `_audits/wave_2`;
  `_execution` thinned-toward-empty).
- Roughly **KEEP ~9 folder classes, MERGE/CONVERT 9, RETIRE ~10
  folder-classes-or-large-file-groups, STALE-FIX 4** (README, ARCHITECTURE
  pointer, dead handoff pointer, cross-parity specs) plus the
  prior-audit-known contract drifts (list-only).
- **Top 3 highest-value consolidations:** (1) `docs/frameworks/` →
  `runbooks/` (kills the operator's flagged folder, unifies a doc class);
  (2) retire the 3586-line `docs/ARCHITECTURE.md` in favor of the
  665-line canonical contract (biggest single token-tax removal +
  kills the architecture triple-tell); (3) two-runbook-homes →
  one (`docs/runbooks/` into root `runbooks/`).
