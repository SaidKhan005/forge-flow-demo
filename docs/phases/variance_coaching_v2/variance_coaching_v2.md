# Variance Coaching V2 (Phase doc)

Status: Lane A IN-REVIEW (gated). Lanes B to G BLOCKED pending Lane A
operator approval.
Owner: orchestrator (Lane A is orchestrator-owned and gated).
Created: 2026-05-16.

## Authority order (for this phase)

1. The active worker prompt.
2. `docs/contracts/core_app_architecture.md` (canonical Phase 7.55
   architecture).
3. `docs/contracts/phase_7_58_primary_driver_contract.md` including the
   appended **V2 Revision** section (the binding presentation + copy
   spec for this phase).
4. UX + copy acceptance reference (behavioural):
   `docs/f&f Coaching/variance_tab_v2_mockup.html` and
   `docs/f&f Coaching/primary_driver_catalog_evolved.html`.
5. Driver-logic authority (reconciled, both win over current code in
   doubt): `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`
   and `docs/Knowledge_graph_docs/Bold By Design.md`.
6. Plan of record:
   `docs/f&f Coaching/variance_coaching_v2_implementation_plan.md`.
7. Reconciliation memo:
   `docs/_audits/variance_coaching_v2/driver_logic_reconciliation.md`.

The two HTML files are the behavioural acceptance reference: a slice
is done when the runtime matches the persisted HTML for that surface
(wording, sign, structure), not the pre-V2 code strings.

## 1. Scope

In scope (presentation + copy + contract; logic only where separately
gated):

1. Wording evolution. All 16 `LeverCards` + 4 `CrossAxisPairs`
   `metric` / `whatHappened` / `whatToDo` / `teachingNote` strings
   replaced with the evolved authoritative voice transcribed verbatim
   into contract section V2-1. App speaks in its own teaching voice;
   blip-vs-leak framing; OPZ / floor framing; zero em dashes; zero
   en dashes.
2. Sign + sentiment convention (contract V2-2). Explicit and global:
   a loss is a negative red value reading "below" / "lost"; a profit
   is a positive green value reading "above". Color is driven by a
   favorable / unfavorable flag, never the raw arithmetic sign. Hero,
   dollar-impact rows, attribution bars, arrow-chain result, Learn
   visuals all obey it.
3. Arrow chain (contract V2-3). A derived visual on This Week Primary
   Driver: driver axis, then dominant counter-axis from
   `LaborModel.attributeDollarImpactByAxis`, then net signed result.
   Full `whatHappened` sentence fused directly beneath, no
   chart-then-paragraph split.
4. Inline emphasis (contract V2-4). A render-agnostic markup the
   renderer promotes into colored causal spans + value chips; words
   preserved byte-for-byte; clean plain-text fallback on non-rendering
   surfaces.
5. 3-frame Learn (contract V2-5). Learn keeps the Recurring Leak /
   Repeatable Wins / Cross-Axis rail; Leak and Wins each render as a
   3-frame story (What happened, Why it matters, What to do + action
   card); Cross-Axis stays a 4-pair swipe; dots adapt to frame count.
6. Driver-logic reconciliation (Lane A memo). Verify (do not
   implement here) `LaborModel` lever determination,
   `attributeDollarImpactByAxis`, theoretical-floor, and OPZ banding
   against both authority docs. Any divergence becomes its own
   operator-gated micro-slice.

Hard guardrails (must not change, contract V2-6):

- WTD vs plan table, Dollar-impact figures math, Full Week Projection:
  structure and numbers untouched. Sign / label wording only where
  the convention demands.
- Telestrator is out (not selected). History keeps its existing OPZ
  band + previous-weeks list; only inline emphasis + sign convention
  apply.
- HP #2 (demo parity), HP #3 (no app-logic change before the 7.58
  revision lands; logic divergences are separately gated), HP #10
  (operator-facing UX + demo walkthrough every slice), metric-honesty
  doctrine, em-dash hard gate.
- `LeverCards` / `CrossAxisPairs` catalogs are LOCKED; the V2 Revision
  section IS the gated change that authorizes the V2-1 strings.

## 2. Lanes + dependency DAG

Condensed from
`docs/f&f Coaching/variance_coaching_v2_implementation_plan.md` section
4.

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

Parallelism after A is approved: B, C, D, E run concurrently in
isolated worktrees. F starts when B + E are merged. G attaches to
every lane's PR and the orchestrator runs a wave-close G pass.

### Lane scopes (condensed)

| Lane | Scope | Depends on | Gate |
| --- | --- | --- | --- |
| A | Revise `phase_7_58_primary_driver_contract.md` (V2 Revision section), create this phase doc, create the reconciliation memo + ledger. No code. | none | GATED (contract-touching + catalog LOCKED + logic-deciding). Operator sign-off before any dependent lane merges. |
| B | Apply V2-1 strings to `lib/domain/constants/app_defaults.dart` (`LeverCards`) + `lib/domain/constants/cross_axis_pair_catalog.dart` (`CrossAxisPairs`). Pure metadata. Golden test copy == V2-1; em-dash + en-dash lint. | A approved | GATED (catalog LOCKED; rides on A's approved spec). |
| C | `lib/widgets/dollar_impact_card.dart` + `lib/widgets/lever_card.dart` + This Week hero: enforce V2-2. Color from a favorable / unfavorable flag, never raw arithmetic sign. Tables untouched. Golden tests for hero, dollar-impact rows, attribution colors. | A approved | Normal audit-then-merge. |
| D | New widget `lib/widgets/variance/driver_arrow_chain.dart`, integrated into `variance_this_week_tab.dart` Primary Driver, fed by detected lever + dominant counter-axis from existing attribution (no new math). Full `whatHappened` fused contiguously. Widget test incl. degraded suppression. | A approved | Normal audit-then-merge. |
| E | Markup convention (V2-4) + a renderer turning the convention into colored causal spans + value chips, applied to teaching strings. No wording change; words preserved byte-for-byte minus markup; plain-text fallback test. | A approved | Normal audit-then-merge. |
| F | Restructure `variance_learn_tab.dart` + learn widgets per V2-5: rail preserved; Leak + Wins to 3-frame story + action card; Cross-Axis to 4-pair swipe; dots adapt. Content from Lane B catalog. | B + E merged | Normal audit-then-merge. |
| G | Per-lane: `dart analyze`, targeted `flutter test`, em-dash + en-dash lint, runtime acceptance, demo-mode walkthrough (HP #10). Wave-close: full variance widget suite + attribution-math regression proving logic unchanged where not gated. | rolls per lane | Normal audit-then-merge. |
| F-logic (conditional) | Any `LaborModel` change the reconciliation memo flags. Each divergence is its own micro-slice with authority-doc citations. | A approved + per-divergence operator approval | GATED (logic-deciding per HP #3). |

## 3. Frontend Exposure (HP #10)

Every backend / logic phase ships operator-facing UX before close.
Lane A is docs-only and has no runtime surface of its own, so its
Frontend Exposure is the spec that constrains the visible lanes (B to
F) and the demo-mode walkthrough they each carry. The visible surface
this phase delivers, by lane:

| Lane | Operator-facing surface | What the operator sees |
| --- | --- | --- |
| B | Variance > This Week Primary Driver card, Variance > Learn, Variance > History, Shift whole-day card, Week Detail | Evolved teaching voice (V2-1 strings) on every lever / cross-axis surface; no engineering jargon; blip-vs-leak + OPZ framing. |
| C | Variance > This Week hero + dollar-impact disclosure + dollar-attribution bars | `−$247` red "below best possible" hero; `Loss if this continues` disclosure; green `+$686` covers bar, red `−$462` cplh bar; color follows sentiment not arithmetic sign. |
| D | Variance > This Week Primary Driver card | Three-node arrow chain (driver, counter-axis, net result) with the full `whatHappened` sentence fused directly beneath. Degraded rows show no chain. |
| E | Variance > This Week / History / Learn teaching prose | Causal phrase promoted in red/green; dollar values rendered as chips; same words, no markup leak into Shift / exports. |
| F | Variance > Learn tab | Rail preserved; Recurring Leak + Repeatable Wins each a 3-frame swipe story with a THE PLAY action card; Cross-Axis a 4-pair swipe; pager dots adapt (3 vs 4). |

### Demo-mode walkthrough outline (HP #10, every visible lane)

Per HP #2 the demo path uses the same tables / reads / UI. Each
visible lane's PR carries a demo-mode walkthrough at the click-path
bar set by `docs/archive/_walkthroughs/7.58.UX.5.md` (per
`docs/CODEX_PROMPT_GENERATION_STANDARD.md` Walkthrough Specificity).
The shared walkthrough spine:

1. Launch the demo flavor (`lib/main_forgeflow.dart`, `kDemoMode`),
   sign in as the demo operator.
2. Advance the demo restaurant (`demo_restaurant_001`) to a business
   day whose seeded WTD reproduces, when re-fed through
   `determineLever`, the `covers_up`-with-soft-CPLH scenario the
   mockup hero shows (`−$247`, covers `+$686`, cplh `−$462`).
3. Open Variance > This Week. Pin: hero `−$247` red + verdict pill
   `▼ $247 LOST · below best possible`; Primary Driver title
   `Volume came in above plan`; arrow chain
   `COVERS ↑ over plan -> CPLH ↓ soft -> −$247 lost`; the fused
   `whatHappened` sentence; the six attribution bars with the
   covers bar green and the rest red; the read-line chips.
4. Expand `Week to date vs plan` and `Loss if this continues`; pin
   the frozen numbers unchanged and the sign/color label per V2-2.
5. Open Variance > Learn. Pin the rail (Leak / Wins / Cross-Axis),
   the 3-frame Leak story + THE PLAY action card, the 3 pager dots;
   switch to Cross-Axis and pin the 4-pair swipe + 4 dots.
6. Open Variance > History. Pin the OPZ band + previous-weeks list
   unchanged, inline emphasis applied, no telestrator.
7. Open Shift whole-day for the same demo day; pin the same lever
   copy renders (tab-ownership: short / deep shape per the contract
   Presentation Split) with no markup leakage.

Each lane's PR names the demo seed shift, the rendered widgets, and
the named values its test pins.

## 4. Per-lane acceptance criteria (tied to the two HTML)

A lane is accepted only when its runtime matches the persisted HTML
for its surface AND its Pattern B audit table (worker self-audit +
independent audit, file:line / doc-section citations) is clean.

- **Lane A (this phase, gated):** contract V2 Revision section
  carries all 21 states verbatim from
  `primary_driver_catalog_evolved.html` (golden-verified, 0
  mismatches); V2-2 sign/sentiment table matches
  `variance_tab_v2_mockup.html` per-surface; V2-3 arrow-chain rule
  matches the mockup `.chain`; V2-4 markup convention defined with a
  plain-text fallback; V2-5 3-frame structure matches the mockup
  Learn pane; reconciliation memo cites BOTH authority docs per item
  with file:line; diff is docs/** only; zero em dash (U+2014), zero
  en dash (U+2013) in the V2 section. Requires operator approval
  before B to G dispatch.
- **Lane B:** every `LeverCards` + `CrossAxisPairs` entry's
  `metric` / `whatHappened` / `whatToDo` / `teachingNote` equals the
  contract V2-1 string byte-for-byte (golden test); em-dash +
  en-dash lint green; no `LaborModel` / logic file touched; degraded
  label `LeverCards.notYetOnModelLabel` unchanged.
- **Lane C:** This Week hero renders `−$247` in the bad color with
  verdict `▼ $247 LOST · below best possible`; dollar-impact
  disclosure titled `Loss if this continues` with red signed rows;
  attribution bars color from the favorable / unfavorable flag (not
  `value > 0`); golden tests pin hero, rows, and a same-arithmetic-
  sign / opposite-sentiment case; WTD table + projection math
  unchanged.
- **Lane D:** arrow chain renders the 3 nodes per V2-3 against the
  mockup scenario; degraded id renders no chain; `whatHappened`
  sentence fused directly beneath (no split); no `LaborModel` math
  change; widget test covers `covers_up`, `cplh_down`, and degraded.
- **Lane E:** rendered emphasis matches the mockup `.em-bad` /
  `.em-good` / `.chip` / `.chip.g` placement; stripped fallback
  equals the verbatim V2-1 string (test); no markup in Shift /
  exports / short badges.
- **Lane F:** Learn rail preserved; Leak + Wins render 3 frames + a
  THE PLAY action card with content from the Lane B catalog;
  Cross-Axis renders the 4 `CrossAxisPairs`; dots = 3 for Leak/Wins,
  4 for Cross-Axis; tab-ownership unchanged (no concept duplicated
  across tabs; WHAT TO DO only on Learn).
- **Lane G:** `dart analyze` clean; targeted `flutter test` green;
  em-dash + en-dash lint green; attribution-math regression proves
  `LaborModel` outputs unchanged on the non-gated lanes; demo-mode
  walkthrough recorded for every visible lane.

## 5. Risks

- Catalog is LOCKED. Lane B must not slip copy without operator
  sign-off (Lane B is itself gated, riding on A's approved spec).
- Driver-logic reconciliation may surface real divergences from the
  authority docs; each becomes its own gated micro-slice, not folded
  silently into a UI lane (HP #3).
- Inline-emphasis markup must not leak raw markup into any
  non-rendering surface (Shift, exports); Lane E owns the fallback.
- Split-attention regression: the arrow chain must sit contiguous
  with its sentence, never chart-then-paragraph.

## 6. Definition of done (wave)

All lanes merged; runtime of This Week / History / Learn matches the
two persisted HTML for wording, sign convention, arrow chain, inline
emphasis, and 3-frame Learn; tables and attribution math provably
unchanged; em-dash + en-dash lint green; demo-mode walkthrough
recorded per visible lane; revised 7.58 contract V2 Revision section +
this phase doc landed; any reconciliation divergence either resolved
via its own gated micro-slice or explicitly deferred with operator
sign-off; operator visual sign-off against `docs/f&f Coaching/*.html`.
