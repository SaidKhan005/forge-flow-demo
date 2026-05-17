# Variance Coaching V2 — End-to-End Implementation Plan

Status: DRAFT for orchestrator review. Not yet sliced into ledger rows.
Owner: orchestrator. Origin synced to `89f397cc` before authoring.

## 0. Source of truth

| Concern | Authority |
| --- | --- |
| UX, layout, wording, behaviour, sign convention | `docs/f&f Coaching/variance_tab_v2_mockup.html` (composed: arrow chain + inline emphasis + 3-frame Learn) and `docs/f&f Coaching/primary_driver_catalog_evolved.html` (all 21 driver states in evolved voice). These are the agreed visual + copy spec. |
| Driver logic (lever determination, attribution, theoretical floor, OPZ, scheduling-to-covers) | `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md` (mechanics + formulas) **and** `docs/Knowledge_graph_docs/Bold By Design.md` (framework: Three Levers, Profit Gap, Core Labor Equation, OPZ, Scheduling Against Volume). Both must be reconciled; in doubt, these two win over current code. |
| Presentation contract | `docs/contracts/phase_7_58_primary_driver_contract.md` (binding: presentation split, tab-ownership, null→degraded, em-dash hard gate). This plan REVISES it. |
| Workflow | `CLAUDE.md` (orchestrator/executor pattern), `docs/CODEX_PROMPT_GENERATION_STANDARD.md` (3-block worker briefs, Agent-Led Slices), per-wave ledger. |

The two HTML files are the **behavioural acceptance reference**: a slice is done when the runtime matches the persisted HTML for that surface (wording, sign, structure), not the old code strings.

## 1. What V2 changes (and what it must not)

In scope (presentation + copy + contract; logic only where gated):
1. **Wording evolution** — all 16 `LeverCards` + 4 `CrossAxisPairs` `metric`/`whatHappened`/`whatToDo`/`teachingNote` rewritten to the evolved authoritative voice in the catalog HTML: speaks as the app's own authority (no "Jim"/"Ch."/"chapter"), blip-vs-leak teaching, OPZ/floor framing, zero em dashes.
2. **Sign + sentiment convention** — explicit and global: `−$ = loss = red = "below/lost"`, `+$ = profit = green = "above"`. Hero, dollar-impact rows, attribution bars, arrow-chain result, Learn visuals all obey it.
3. **Arrow chain** — derived visual on This Week Primary Driver: `driver axis → dominant counter-axis → net loss/profit`, with the full `whatHappened` sentence fused directly beneath (no split-attention gap).
4. **Inline emphasis** — teaching strings render with the causal phrase promoted and dollar values as chips, words 100% preserved.
5. **3-frame Learn** — Learn keeps the `Recurring Leak / Repeatable Wins / Cross-Axis` rail; Leak and Wins each render as a 3-frame story (What happened → Why it matters → What to do + action card); Cross-Axis stays a 4-pair swipe.
6. **Driver-logic reconciliation** — verify (and only where the authority docs require, adjust) `LaborModel` lever determination, `attributeDollarImpactByAxis`, theoretical-floor, and OPZ banding against both authority docs, with file:line citations.

Hard guardrails (must not change):
- **Tables are frozen.** WTD vs plan table, Dollar-impact figures math, Full Week Projection: structure and numbers untouched. Sign/label wording only where the convention demands.
- **Telestrator is out** (not selected). History keeps its existing OPZ band + weeks list; only inline emphasis + sign convention apply.
- HP#2 demo parity, HP#3 (no app-logic change before the 7.58 revision lands), HP#10 (operator-facing UX + demo walkthrough every slice), metric-honesty doctrine, em-dash hard gate.
- `LeverCards` / `CrossAxisPairs` catalogs are **LOCKED**: copy or entry changes require a contract-revision PR + explicit operator approval (same gate as auth/RLS/schema/proxy).

## 2. Code surface (real files)

| Area | Files |
| --- | --- |
| Catalog (wording) | `lib/domain/constants/app_defaults.dart` (`LeverCards`, `LeverCardData`), `lib/domain/constants/cross_axis_pair_catalog.dart` (`CrossAxisPairs`) |
| Driver logic | `lib/services/labor_model.dart` (`determineLever`, `determineLeverGated`, `attributeDollarImpactByAxis`, theoretical labor), `lib/services/baseline_authority_service.dart` (OPZ Ch. 11 / range graph) |
| This Week render | `lib/screens/variance/variance_this_week_tab.dart`, `lib/widgets/lever_card.dart` (`LeverCardWidget`, `_DollarAttributionSection`, `LeverCardNotYetAvailable`), `lib/widgets/dollar_impact_card.dart` |
| Learn render | `lib/screens/variance/variance_learn_tab.dart`, `lib/widgets/learn/learn_carousel.dart`, `learn_chapter_rail.dart`, `learn_teaching_card.dart` |
| History render | `lib/screens/variance/variance_history_tab.dart` |
| Contract | `docs/contracts/phase_7_58_primary_driver_contract.md` (revision), new phase doc `docs/phases/variance_coaching_v2/variance_coaching_v2.md` |
| Tests/lints | em-dash lint, catalog golden tests, sign-convention golden tests, arrow-chain + 3-frame widget tests, attribution-math regression (must stay green/unchanged) |

## 3. Gate map (operator approval required)

| Slice | Why gated |
| --- | --- |
| Lane A — 7.58 contract revision (wording catalog spec + sign convention spec + driver-logic reconciliation findings) | Contract-touching + catalog LOCKED + logic-deciding (7.58). **Operator sign-off before any dependent lane merges.** |
| Lane B — apply catalog wording | Catalog LOCKED (rides on A's approved spec). |
| Lane F-logic — any `LaborModel` change | Logic-deciding per HP#3; needs operator approval and authority-doc citations. |

All other lanes are normal audit-then-merge (orchestrator auto-merges on clean Pattern B audit, no escalation), per `feedback_orchestrator_auto_merge_after_audit`.

## 4. Workstream lanes + dependency DAG

```
Lane A  (contract + spec + driver-logic reconciliation)   [GATED]
        |
        +--> Lane B  catalog wording (LeverCards + CrossAxisPairs)
        +--> Lane C  sign/sentiment convention (dollar_impact_card, lever_card, hero)
        +--> Lane D  arrow-chain widget + This Week integration
        +--> Lane E  inline-emphasis markup + renderer
                         |
                         +--> Lane F  3-frame Learn (depends on B copy + E renderer)
        Lane G  cross-cutting: tests, lints, demo-mode walkthrough,
                runtime acceptance  (rolls per lane, finalizes the wave)
```

Parallelism after A is approved: **B, C, D, E run concurrently** in isolated worktrees. F starts when B + E are merged. G attaches to every lane's PR (each PR carries its own tests/walkthrough) and the orchestrator runs a wave-close G pass.

### Lane scopes

- **Lane A — Spec & reconciliation (orchestrator-owned, gated).** Revise `phase_7_58_primary_driver_contract.md` + create `docs/phases/variance_coaching_v2/variance_coaching_v2.md`. Deliver: (1) the evolved copy table for all 21 states transcribed from `primary_driver_catalog_evolved.html`; (2) the explicit sign/sentiment spec; (3) arrow-chain derivation rule (driver → dominant counter-axis from `attributeDollarImpactByAxis` → net); (4) inline-emphasis markup convention; (5) 3-frame Learn structure with tab-ownership unchanged; (6) a driver-logic reconciliation memo: `LaborModel.determineLever` thresholds/priority, `attributeDollarImpactByAxis` decomposition, theoretical-floor, OPZ banding each checked against `jim_taylor_labor_model_deep_dive.md` **and** `Bold By Design.md` with file:line + doc-section citations, listing any required logic changes (each individually operator-gated). No code in Lane A.
- **Lane B — Catalog wording.** Apply the Lane-A-approved strings to `app_defaults.dart` + `cross_axis_pair_catalog.dart`. Pure metadata. Golden test asserting copy == catalog HTML; em-dash lint; no logic touched.
- **Lane C — Sign/sentiment convention.** `dollar_impact_card.dart` + `lever_card.dart` + This Week hero: enforce `−=loss/red/below`, `+=profit/green/above`. Drive color from a favorable/unfavorable flag, never raw arithmetic sign. Tables untouched. Golden tests for hero, dollar-impact rows, attribution colors.
- **Lane D — Arrow chain.** New widget `lib/widgets/variance/driver_arrow_chain.dart`, integrated into `variance_this_week_tab.dart` Primary Driver, fed by detected lever + dominant counter-axis from existing attribution (no new math). Full `whatHappened` sentence fused contiguously. Widget test for the 3-node derivation incl. degraded ("Not yet on-model") suppression.
- **Lane E — Inline emphasis.** Markup convention (per Lane A) + a renderer turning the convention into colored causal spans + value chips, applied to teaching strings. No wording change; words preserved byte-for-byte minus markup.
- **Lane F — 3-frame Learn.** Restructure `variance_learn_tab.dart` + learn widgets: rail preserved (Leak/Wins/Cross-Axis); Leak & Wins → 3-frame story + action card; Cross-Axis → 4-pair swipe; dots adapt to frame count. Content from Lane B catalog. Tab-ownership rule (7.58) unchanged: no concept duplicated across tabs.
- **Lane G — Verification.** Per-lane: `dart analyze`, targeted `flutter test`, em-dash lint, runtime acceptance per `docs/contracts/slice_runtime_acceptance_contract.md`, demo-mode walkthrough (HP#10). Wave-close: full variance widget suite + attribution-math regression proving logic unchanged where not gated.

## 5. Headless-agent execution shape

Each lane is dispatched as a background worker agent in its own worktree, contract = `commit + push + open PR → STOP` (per `CLAUDE.md` "Agent-Led Slices"). Worker prompt is the 3-block format (`docs/CODEX_PROMPT_GENERATION_STANDARD.md`); block 1 = operator-readable summary, blocks 2–3 = scope + acceptance. Mandatory step 0 in every worktree prompt: `pwsh scripts/install_git_hooks.ps1` (per `feedback_agent_worktree_hooks_first`). Every PR body carries the Pattern B audit table (worker self-audit + independent audit, both file:line). Orchestrator audits the PR diff against this plan + the two HTML + the two authority docs, fixes findings inline by default, and merges only when clean; Lane A and any `LaborModel` change escalate to the operator regardless of audit verdict.

Dispatch order:
1. Lane A (gated) → operator approves the revised contract + phase doc + reconciliation memo.
2. Concurrently dispatch B, C, D, E as 4 background agents (independent worktrees).
3. On B+E merged, dispatch F.
4. Orchestrator runs wave-close Lane G; ledger row flips on clean audit + demo walkthrough + operator visual sign-off vs the HTML.

Ledger: open `docs/_indices/VARIANCE_COACHING_V2_LEDGER.md` (one row per lane, status, PR, audit doc path `docs/_audits/variance_coaching_v2/pr_<n>_<lane>.md`). Trackers are not edited during implementation (per house rules); orchestrator advances them between waves.

## 6. Exemplar worker brief (Lane D, abbreviated 3-block)

```
BLOCK 1 (operator): Add the Primary Driver "arrow chain" visual to This Week so the
detected driver reads as cause → effect → net at a glance, with the full explanation
fused beneath. No wording or table change. Matches docs/f&f Coaching/variance_tab_v2_mockup.html.

BLOCK 2 (scope): worktree .claude/worktrees/<lane-d>. Step 0 install hooks. New widget
lib/widgets/variance/driver_arrow_chain.dart. Integrate in variance_this_week_tab.dart
Primary Driver slot above the fused whatHappened sentence. Nodes = [driver shortLabel +
direction] → [dominant counter-axis from LaborModel.attributeDollarImpactByAxis] →
[net, signed per the Lane A convention]. Degraded id → render nothing (LeverCardNotYetAvailable
path unchanged). No LaborModel math change. Tables untouched.

BLOCK 3 (acceptance): dart analyze clean; widget test covers covers_up, cplh_down,
and degraded; runtime screenshot matches the mockup arrow row; em-dash lint clean;
Pattern B audit table in PR body; commit + push + open PR → STOP.
```

## 7. Risks

- Catalog is LOCKED — Lane B/A must not slip copy without operator sign-off (gated).
- Driver-logic reconciliation may surface real divergences from the authority docs; each becomes its own gated micro-slice, not folded silently into a UI lane (HP#3).
- Inline-emphasis markup must not leak raw markup into any non-rendering surface (shift, exports); Lane E owns a fallback that degrades to plain text.
- Split-attention regression: arrow chain must sit contiguous with its sentence, never chart-then-paragraph (the core research finding).

## 8. Definition of done (wave)

All lanes merged; runtime of This Week / History / Learn matches the two persisted HTML for wording, sign convention, arrow chain, inline emphasis, and 3-frame Learn; tables and attribution math provably unchanged; em-dash lint green; demo-mode walkthrough recorded; revised 7.58 contract + phase doc landed; operator visual sign-off against `docs/f&f Coaching/*.html`.
