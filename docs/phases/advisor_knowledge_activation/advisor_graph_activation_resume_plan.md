# Advisor Graph + Knowledge Activation — Paused Resume Plan

> **Created:** 2026-05-27. **Owner:** orchestrator. **Status:** PAUSED
> (operator-set 2026-05-27). Resume AFTER the refactor lane
> (NEXT_WAVE_PLAN Phase 3: R-1/R-2/R-3) and the current next lane
> (Per-Daypart Targets V1, Phase 2.5) are complete.
>
> This is the single "how to finish this" doc for the advisor
> knowledge-graph activation. It supersedes neither of its two source
> plans; it sequences the remaining work and records exact state so the
> lane can be picked up cold. Sources:
> `advisor_knowledge_activation_plan.md` (Workstreams A to E) and
> `graph_activation_subplan.md` (G1 to G5 + the operator decisions).

## One-paragraph state

The advisor "brain" and all its operator-facing UX are built and on
`master`, fully inert until the operator deploys. Everything that can be
built safely without a deploy, a secret, or paid AI has been built. What
remains is: merge three audited held PRs, deploy, provision one secret,
approve one paid-AI run, make the C1 un-pause call, and build one
product-fork slice (advisor reads the graph in its answers). Nothing
below is live; nothing below spends money until the operator acts.

## What is DONE and on `master` (inert until deploy)

| Area | Slices | Note |
|---|---|---|
| Advisor uses knowledge (Workstream A) | A1, A2/A2b/A2b.1, A3, A4.1, A4.6, A4-ENC, A4.2a, A4.2b | Retrieval + embed + rerank + agentic `POST /v1/advisor/answer`; fail-closed (503) until the CMK secret exists |
| Admin Knowledge tab (Workstream B) | B1, B3, B-r1, B-r2, B-r3 | Matches the committed preview |
| Connections tab (Workstream C2) | C2, C2-map | Matches the preview |
| Advisor chat UI (Workstream D) | D1, D2-web, D2-mobile | Operator can ask + get a recommendation |
| Graph activation (sub-plan) | G1 (#1420), G2 (#1421), G4 (#1422), G4b (#1423), G5a (#1427) | Both-brands candidate bundle; C3 typed vocabulary; extraction tool; server-side extract endpoint; AGE rebuild 501 to real |

## What is HELD (built + audited CLEAN, awaiting operator merge)

These three are runtime-inert until deploy. The auto-merge guardrail
correctly blocked merging them on a build directive; they need an
explicit operator merge go-ahead (the schema one especially).

| PR | Slice | What | Gate |
|---|---|---|---|
| #1429 | F1 | Re-point the C3 extraction tool at the proxy endpoint (HP#7: tool no longer holds a provider key; it POSTs `/v1/admin/graph/extract`) | analyze clean; 34 mocked tests; scope tool+test only |
| #1430 | F2 | Wire HP#9 cap-check + `proxy_requests` idempotency on the extract endpoint (reuses the answer route's guard/store, no parallel stack) | size lint 19261/19900 (no raise); 24 mocked tests |
| #1428 | F3 | Grant least-privilege runtime DML on the `forgeflow` AGE schema so the G5a rebuild can project (was SELECT-only) | drift + cutoff lints clean; schema = explicit operator approval to merge |

## What is NOT built yet (remaining engineering)

| Item | Why it waits | Gate |
|---|---|---|
| **G5b: advisor READS the graph in answer generation** | Product-direction fork. The agentic answer engine has no graph-read seam today; how the advisor uses approved connections (which traversal, how it folds into the tool-use loop, HP#5 incremental) is an operator design call. G5a built the rebuild infra it would consume. | needs operator steer, then build (held) |
| **Other HP#7 re-points (flagged by F1)** | The corpus tool still calls Voyage embeddings and the `AdvisorContextGateway` (answer-context) providers directly. Each needs its own proxy-broker re-point. | build (held); op-gated proxy |
| **C3 paid extraction run** | Tool (G4) + endpoint (G4b) + metering (F2) are built, but the actual paid run over the corpus needs operator spend go-ahead. | operator spend OK, then run |

## What is OPERATOR-ONLY (go-live; no engineering)

1. **Merge the 3 held PRs** (#1429, #1430, #1428).
2. **Apply the migration queue** (incl. F3 grant + the G2 vocabulary), per the production1 migration-apply runbook.
3. **Deploy the proxy**: ships the candidate JSONL + `corpus_manifest.yaml` to the runtime path; exposes `/v1/admin/graph/extract` + `/v1/admin/age/rebuild`; injects the graph gateways (graph-candidates, extract, age-rebuild).
4. **Provision `ADVISOR_CONVERSATION_CMK`** (E1) and confirm `conversation_cmk_loaded: true`.
5. **Approve the paid AI-extraction spend** (then C3 runs).
6. **Make the C1 un-pause call** and verify at runtime (GET serves the diff; `commit-batch` writes canonical nodes/edges + audit; the Connections review screen lights up).

## Documented gaps reference

The lane's documented gaps live in three places; this plan folds them
into the phases above:

- `advisor_knowledge_activation_plan.md` (Workstreams A to E) and
  `graph_activation_subplan.md` (G1 to G5) — the source plans.
- `docs/_audits/deep_unrun_lane_audit_2026_05_27_report.md` — the
  2026-05-27 deep-audit gap list for the AI/advisor lane: live/demo
  advisor gateway binding, client `prior_turns`, advisor CMK
  deploy-secret mapping, advisor/Tier-M cutover wording alignment, graph
  candidate artifact/content cleanup, and the
  AI/corpus/pricing/observability admin-pressure placeholders. On resume,
  read this report for the itemized gap list; its advisor/graph items map
  onto R1 (gateway binding, CMK mapping, candidate artifacts), R2
  (candidate content cleanup), and R5 (cutover wording, smoke verify).
  The non-advisor placeholders (pricing/observability admin-pressure)
  belong to their own lanes, not this one.

## Phased resume sequence

Run in order on resume. Phases R0/R1 are operator/ops; R2 to R5 interleave
operator gates with orchestrator builds.

- **R0 — Land the held code.** Operator merges F1 #1429, F2 #1430, F3 #1428 (still inert).
- **R1 — Deploy + secret + migrations.** Apply migrations (incl. F3 grant); deploy the proxy with candidate artifacts + the new endpoints + injected gateways; provision the CMK (E1); confirm startup logs.
- **R2 — Activate C1 (candidates to canonical).** Un-pause decision (content = BOTH brands, already staged by G1); orchestrator verifies GET-diff + commit-batch + audit at runtime; the Connections review surface goes live.
- **R3 — Populate the rich graph (C3).** Operator OKs spend; run the extraction tool (now proxy-brokered + metered) over the corpus; review/approve typed nodes/edges in the Connections tab.
- **R4 — Project + read (AGE).** Run `/v1/admin/age/rebuild` (G5a + F3 grant) to project the approved graph into AGE; then **G5b**: operator steers the read strategy, orchestrator builds advisor-reads-graph in answer generation (held), then it activates.
- **R5 — Finish HP#7 + verify.** Re-point the remaining direct-provider calls (Voyage embeddings, `AdvisorContextGateway`); E2 smoke-test the live answer + extraction paths; confirm metering.

## Open decisions (operator decides before the dependent phase)

1. **G5b read strategy (blocks R4 build).** How should the advisor use approved connections when answering? (e.g., pull typed neighbors for a concept via the canonical graph vs AGE traversal; how it folds into the existing tool-use loop.) HP#5 says AGE lights up incrementally, so the first slice can be narrow.
2. **Candidate content for C1** is RESOLVED: operator chose BOTH brands (Forge & Flow + Barrio data only; Barrio app code stays paused). G1 staged it.

## Hard constraints carried forward

- Proxy ceiling `kAdvisorProxyMaxLines = 19900` (currently ~19261 with G4b+G5a merged); sibling files only; raises need explicit operator approval (R-2).
- One proxy-touching lane at a time; one admin-screen-editing lane at a time.
- Op-gated merges (proxy / schema / RLS / auth / canonical-graph-write) need explicit operator approval regardless of audit verdict.
- No em-dash in any operator-facing string.
- CI dark until 2026-06-01: high-risk merges run the pre-merge gate + verify-landed.

## Resume trigger

Pick this up when the operator signals the refactor lane (R-1/R-2/R-3)
and Per-Daypart Targets V1 are done. Start at R0.
