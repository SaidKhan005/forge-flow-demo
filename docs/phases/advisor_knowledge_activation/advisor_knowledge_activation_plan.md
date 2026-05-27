# Advisor Knowledge Activation — Master Plan

> **Created:** 2026-05-24. **Last updated:** 2026-05-25 (Workstream A
> complete; operator-facing chat UI + go-live added; admin redesign
> locked to the committed preview). **Owner:** orchestrator (this
> session) drives slicing, prompt emission, audit, merge. Worker agents
> execute in isolated worktrees per CLAUDE.md "Agent-led slices".
>
> **Status:** PAUSED 2026-05-27. Workstreams A, B, C2, and D shipped +
> merged; the knowledge-graph activation (G1/G2/G4/G4b/G5a + follow-ups
> F1/F2/F3) is built + on `master`, inert until deploy. The lane is paused
> with the canonical phased resume plan, the remaining engineering (G5b
> advisor-reads-graph + the other HP#7 re-points), the open decisions, the
> documented-gaps reference, and the go-live action list in
> `advisor_graph_activation_resume_plan.md`. Resume after the refactor lane
> (R-1/R-2/R-3) and Per-Daypart Targets V1.

**Locked UX target for the admin surface:**
`docs/_mockups/knowledge_base_redesign_preview.html` (the agreed
content-first, plain-English redesign). Workstreams B and C2 below must
match it; it is the acceptance reference, not a loose inspiration.

## Why this exists

The advisor knowledge base was **schema-complete and data-loaded in
staging but unused at runtime, with its rich graph layer empty.**
Verified live against Azure staging Postgres (Canada Central) 2026-05-24:
`advisor_source_documents` = 8; `advisor_source_chunks` active = 233;
Voyage embeddings ready = 233 (`voyage-4-large`, 1024-dim, HNSW cosine);
contextual `chunk_context` filled on all 233; extensions live (`vector`
0.8.2, `age` 1.6.0, `pg_diskann` 0.6.4); simple graph seeds populated.

The three original gaps and where they now stand:

1. **Advisor does not use the knowledge.** CLOSED by Workstream A:
   retrieval, server-side query embedding, rerank, and a live agentic
   answer endpoint all shipped.
2. **Admin screen is machine-flavored and only half-real.** OPEN: the
   document side has real data and a file picker, but the screen does not
   yet match the agreed preview. (Workstream B + C2.)
3. **Rich graph is empty + switched off.** PARTIALLY CLOSED: the
   candidate-review gateway is wired and a candidate bundle is staged;
   the review screen redesign and the rich typed vocabulary remain.
   (Workstream C.)

## Current status (2026-05-25)

| Slice | What | Status |
|---|---|---|
| A1 | Corpus retrieval service + repo calling `advisor_search_chunks()` | DONE (merged) |
| A2 / A2b / A2b.1 | Server-side Voyage query embedding + route + HP #9 metering | DONE (merged) |
| A3 | Voyage rerank (`rerank-2.5`) + metered | DONE (merged) |
| A4.1 | Agentic answer engine + tool-use Anthropic gateway | DONE (merged) |
| A4.6 | Operational read tools (targets / week plan / shift variance) | DONE (merged) |
| A4-ENC | In-process AES-256-GCM conversation encryptor (encryption-first) | DONE (merged) |
| A4.2a | `retrieve_methodology` tool + shared retrieval pipeline | DONE (merged) |
| A4.2b | `POST /v1/advisor/answer` (agentic, encrypted history, memory, metered) | DONE (#1360) |
| B1 | Real file picker + drag-drop on the corpus screen | DONE (merged) |
| B3 | Sections-at-scale view (chunks grouped by document) | DONE (merged) |
| C1 | Graph-candidates gateway bound + candidate bundle staged | CODE-COMPLETE; needs runtime-artifact confirm + un-pause decision |
| Go-live runbook | `runbooks/advisor_answer_go_live_runbook.md` | DONE (#1364) |

**Net:** the advisor's brain is built and on `master`, fail-closed until
`ADVISOR_CONVERSATION_CMK` is provisioned (the only new secret; Anthropic
+ Voyage are already required at boot). What remains is operator-facing:
nobody can *talk* to the advisor (no chat screen), and the admin
Knowledge base does not yet match the agreed preview.

## Authority + promises this advances

- Defers to `docs/contracts/core_app_architecture.md` and the Tier-2
  contracts (Authority Order). Advances **Phase 11b** (HP #5) and honors
  **HP #4** (per-operator isolation; admin graph-curation is a documented
  cross-tenant carve-out with a manifest scope filter + RLS backstop),
  **HP #6** (advisor recommends, never commands), **HP #7** (provider
  keys server-side; chat encrypted at rest), **HP #9** (cost metered by
  class), and **HP #10** (operator-facing UX before phase close: the chat
  screen and the KB redesign are that UX).
- **CI dark until 2026-06-01**: high-risk merges run
  `tool/pre_merge_gate.sh` (or the manual analyze + changed-tests
  equivalent from worktrees) + `tool/verify_pr_landed.sh`.

## Hard constraints (read before dispatching any lane)

- **Proxy ceiling.** `tool/advisor_proxy/advisor_proxy.dart` is ~18,241
  lines against a 19,900 bleed-stop ceiling (headroom ~1,659), enforced
  by `tool/advisor_proxy_size_lint.dart`. Proxy-facing work lands in NEW
  sibling files with thin registration. A `kAdvisorProxyMaxLines` raise
  needs explicit operator approval (Ceiling-raise rule R-2).
- **One proxy-touching lane at a time** (Cost & Convergence #3).
- **One admin-screen-editing lane at a time.** Workstream B and C2 slices
  all touch `lib/admin/screens/corpus_admin_screen.dart` + siblings;
  serialize.
- **Operator-gated merges:** any slice touching the proxy, a migration
  (schema), RLS, auth, or the canonical graph write path merges ONLY with
  explicit operator approval, regardless of audit verdict.
- **No em-dash law** applies to every operator-facing string in the new
  UI (chat screen + KB redesign): colon for label/value, "to" for ranges.

## Workstreams + slices

Gate legend: `auto` = orchestrator merges when audit clean; `op-gated` =
needs explicit operator approval to merge.

### Workstream A — Advisor uses the knowledge (Phase 11b) — COMPLETE

A1 to A4.2b shipped (see status table). The retrieval pipeline (embed to
search to rerank), the operational tools, the encryptor, and the live
`POST /v1/advisor/answer` endpoint are all on `master`. The endpoint is
recommendation-only (HP #6), per-operator-scoped (HP #4), metered under
`advisor_answer` (HP #9), and writes an encrypted conversation row per
turn (HP #7). It fails closed (503) until the CMK is provisioned.

### Workstream D — Operator-facing advisor chat UI (NEW; HP #10 gap)

The endpoint exists but nothing calls it from the operator app
(confirmed: "advisor" appears in operator screens only under Settings).
This workstream is the surface where an operator actually asks a question
and gets a recommendation. **Web-first** (matches the active web-only
build posture); mobile is a follow-on.

| Slice | Scope | Surface | Gate | Depends | Parallel-safe |
|---|---|---|---|---|---|
| D1 | Client `AdvisorAnswerService` + models: POST `/v1/advisor/answer` with the operator JWT, send `prior_turns` (multi-turn memory) + `conversation_id`, parse `answer` / `citations` / `conversation_id` / `usage_class`; map the fail-closed 503 + cap-refusal 402 to typed states. Unit tests with a fake HTTP client. No proxy, no schema. | `lib/operator_web/services/**` (or `lib/services/**`), `test/**` | auto | A4.2b (done) | YES |
| D2 | Advisor chat screen + nav entry: question box, in-flight/loading state, recommendation render with expandable citations, multi-turn thread (carry `conversation_id` + `prior_turns`), HP #6 recommendation framing ("here is what I would consider", never a command), plain-English + no em-dash. Wire into operator-web nav. | `lib/operator_web/screens/**` or `lib/screens/**` + router | auto | D1 | NO (same screen across D slices) |
| D3 | States + polish: empty / loading / error; the fail-closed "advisor unavailable" message (friendly, no jargon); cap-refusal message; citation source display; demo-mode behavior. | advisor chat screen + siblings | auto | D2 | NO (same screen) |

### Workstream B — Admin Knowledge tab, matched to the preview

The preview's **Knowledge** tab is the spec. B1 (file picker) and B3
(sections at scale) shipped; the remaining work brings the tab to the
agreed look and language.

| Slice | Scope (from the preview) | Surface | Gate | Depends | Parallel-safe |
|---|---|---|---|---|---|
| B-r1 | Frame + theme + language: "What the advisor knows" header, warm F&F theme, "Staff only" badge, plain-English copy throughout; move machine IDs/hashes/confidence under a "Show technical details" toggle (off by default); Admin vs Support (view-only) mode that hides edit affordances + shows the read-only banner. | corpus admin screen + sibling widgets | auto | — | NO (same screen) |
| B-r2 | Topics grouped by source document (collapsible groups with counts), kind icons + plain-English kind labels + kind pills, search + kind filter (Documents/SOPs/Policies/Concepts/Metrics/Formulas/Risks/Roles), "Showing X of Y". | corpus admin screen + siblings | auto | B-r1 | NO (same screen) |
| B-r3 | "Change kind" modal: the plain-English kind picker (the rich vocabulary: SOP / Policy / Concept / Metric / Formula / Risk / Role / Word to know / Coaching move, each with an example). "Add knowledge" dropzone keeps B1's picker and adds the "what this update changes" preview. Update history + "go back to this version" rollback. | corpus admin screen + siblings | auto | B-r2 | NO (same screen) |

### Workstream C — Rich connections, Connections tab matched to the preview

| Slice | Scope | Surface | Gate | Depends | Parallel-safe |
|---|---|---|---|---|---|
| C1 | Graph-candidates un-pause: gateway is bound and a candidate bundle is staged (verified 2026-05-25). REMAINING: confirm the deployed proxy image ships the candidate JSONL + `corpus_manifest.yaml` to the runtime path; make the policy un-pause decision; verify GET serves the diff and `commit-batch` writes canonical nodes/edges with audit. | proxy (already wired) + `graph_repository.dart` (no change expected) | op-gated (proxy + canonical graph write) | content decision below | NO (proxy) |
| C2 | Connections tab redesign to the preview: summary chips (clear / worth checking / not sure), the focus **Map** (node-link visual centred on a chosen topic + legend), grouped connection cards with plain-English sentences + clarity chips + Looks right / Not right / Change, the unsure group forcing "Set how they connect" (mirrors the server `ambiguous_requires_edit` rule), bulk "Mark all N correct", the verbs modal, "Save my choices (N)". | corpus admin screen + sibling widgets | auto | C1 (data) | NO (same screen as B) |
| C3 | Semantic extraction (Phase 12): produce typed nodes/edges (Concept/SOP/Metric/Formula; INFORMS/CAUSES/...), expand the approved node/edge vocabulary, migrations. Large; its own sub-plan. Powers the rich kinds the B/C2 UI renders. | `tool/advisor_corpus/**`, `db/migrations/**` | op-gated (schema) | C1 | NO (schema chain) |

### Workstream E — Go-live (ops + operator action)

| Slice | Scope | Gate |
|---|---|---|
| E1 | Provision `ADVISOR_CONVERSATION_CMK` (base64 of 32 bytes) in Secret Manager + map to the proxy; redeploy; confirm `conversation_cmk_loaded: true` startup log. Per `runbooks/advisor_answer_go_live_runbook.md`. | operator action |
| E2 | Smoke-test live `POST /v1/advisor/answer` (200 + citations); confirm `advisor_answer` metering; confirm fail-closed when the key is absent. | operator / orchestrator |

## Wave schedule (remaining work)

The serialize-the-proxy and one-screen-at-a-time rules drive this.

- **Wave 5 (parallel, auto-merge after audit):** **D1** (advisor answer
  client service, operator-app lib) + **B-r1** (admin Knowledge tab frame
  + theme + tech-details toggle). Different apps/screens, non-overlapping.
- **Wave 6:** **D2** (chat screen + nav) + **B-r2** (topics grouped by
  document). Different screens (operator app vs admin), parallel-safe.
- **Wave 7:** **D3** (chat states/polish) + **B-r3** (kind modal + add +
  history). Serialize B-r3 after B-r2 on the admin screen.
- **Wave 8:** **C2** (connections redesign) after the B-r slices clear
  the admin screen. **C1** un-pause verification runs alongside (proxy
  lane) once the content decision is made.
- **Later / own sub-plan:** **C3** (semantic extraction, Phase 12,
  op-gated schema). **E1/E2** go-live whenever the operator is ready
  (independent of D/B/C, but D makes it usable).

## Decisions

**Resolved:**
1. **A4 scope** — full agentic answer generation IS in this initiative
   (operator chose "full agentic answer now"). DONE.
2. **Memory + encryption** — multi-turn memory via client `prior_turns`;
   encryption-first (no answer without an encrypted record). DONE.
3. **Proxy ceiling** — sibling files only, no raise (held).
4. **Rich vs lean kinds** — the preview commits to the RICH vocabulary
   (Metric / Formula / Word-to-know / Coaching-move included). The B/C2
   UI renders rich kinds now; the DATA to populate them fully needs C3
   semantic extraction, so until C3 the staged candidates stay
   document/`RELATES_TO`-flavored.

**Open (operator decides before the dependent slice runs):**
1. **Candidate content scope (blocks C1 un-pause).** The staged
   candidate bundle is Barrio-handbook-heavy, and Barrio is paused.
   Choose: commit the existing candidates as-is, or regenerate
   F&F-methodology-only candidates (`prepare-graphify-candidates`) before
   committing anything to the canonical graph.
2. **Chat UI reach (affects D scope).** Operator-web first (recommended,
   matches active build), or web + mobile together.
3. **AGE traversal timing.** The advisor does not yet *read* the approved
   graph (AGE rebuild is a 501 stub, ships in 11A.3c / Phase 12).
   Decide whether to schedule that slice now or after the review surface
   lands.

## Orchestration protocol

- Each slice = one worker agent in its own worktree. Contract:
  `branch → install hooks → implement → self-audit → commit + push →
  open PR → STOP`. Agents MUST NOT merge, MUST NOT `--no-verify`, MUST
  NOT edit trackers, MUST NOT raise the proxy ceiling.
- Orchestrator audits each PR (Pattern B: worker self-audit + independent
  audit, both with file:line citations), runs the pre-merge gate for
  high-risk PRs while CI is dark, merges clean PRs (op-gated ones only
  after operator approval), then `tool/verify_pr_landed.sh` to confirm
  content landed on `origin/master`.
- Status tracked in this doc's tables (orchestrator-owned).
