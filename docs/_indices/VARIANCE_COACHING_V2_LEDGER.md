# Variance Coaching V2 Ledger

One row per lane. Lane A is gated and IN-REVIEW after its PR; Lanes B
to G are BLOCKED until the operator approves Lane A. Audit artifacts
live at `docs/_audits/variance_coaching_v2/pr_<n>_<lane>.md`.

Plan of record:
`docs/f&f Coaching/variance_coaching_v2_implementation_plan.md`.
Phase doc: `docs/phases/variance_coaching_v2/variance_coaching_v2.md`.
Contract delta: `docs/contracts/phase_7_58_primary_driver_contract.md`
(V2 Revision section).
Reconciliation memo:
`docs/_audits/variance_coaching_v2/driver_logic_reconciliation.md`.

| Lane | Scope | Depends-on | Gate | Status | PR | Audit-doc path |
| --- | --- | --- | --- | --- | --- | --- |
| A | Revise 7.58 contract (V2 Revision section: verbatim 21-state copy catalog, sign/sentiment convention, arrow-chain rule, inline-emphasis markup, 3-frame Learn, guardrails) + create phase doc + reconciliation memo + this ledger. Docs only. | none | GATED (contract-touching + catalog LOCKED + logic-deciding 7.58; operator sign-off before B to G) | IN-REVIEW | `claude/variance-v2-lane-a` (PR to be opened) | `docs/_audits/variance_coaching_v2/pr_<n>_lane_a.md` (orchestrator) |
| B | Apply V2-1 strings to `lib/domain/constants/app_defaults.dart` (`LeverCards`) + `lib/domain/constants/cross_axis_pair_catalog.dart` (`CrossAxisPairs`) byte-for-byte. Golden test copy == V2-1; em-dash + en-dash lint. Pure metadata. | A approved | GATED (catalog LOCKED; rides on A's approved spec) | BLOCKED | (pending) | `docs/_audits/variance_coaching_v2/pr_<n>_lane_b.md` |
| C | `dollar_impact_card.dart` + `lever_card.dart` + This Week hero: enforce V2-2; drive color from a favorable/unfavorable flag, never `value > 0` (reconciliation Subject 5b). Tables untouched. Golden tests incl. same-sign/opposite-sentiment case. | A approved | Normal audit-then-merge | BLOCKED | (pending) | `docs/_audits/variance_coaching_v2/pr_<n>_lane_c.md` |
| D | New `lib/widgets/variance/driver_arrow_chain.dart`, integrate into `variance_this_week_tab.dart` Primary Driver per V2-3; fed by existing attribution (no new math); `whatHappened` fused beneath; degraded suppresses chain. Widget test. | A approved | Normal audit-then-merge | BLOCKED | (pending) | `docs/_audits/variance_coaching_v2/pr_<n>_lane_d.md` |
| E | Inline-emphasis markup convention (V2-4) + renderer producing colored causal spans + value chips; words preserved byte-for-byte; plain-text fallback test (no markup in Shift/exports). | A approved | Normal audit-then-merge | BLOCKED | (pending) | `docs/_audits/variance_coaching_v2/pr_<n>_lane_e.md` |
| F | Restructure `variance_learn_tab.dart` + learn widgets per V2-5: rail preserved; Leak + Wins to 3-frame story + action card; Cross-Axis 4-pair swipe; dots adapt. Content from Lane B catalog. | B + E merged | Normal audit-then-merge | BLOCKED | (pending) | `docs/_audits/variance_coaching_v2/pr_<n>_lane_f.md` |
| G | Cross-cutting verification: per-lane `dart analyze`, targeted `flutter test`, em-dash + en-dash lint, runtime acceptance, demo-mode walkthrough (HP #10); wave-close full variance widget suite + attribution-math regression. | rolls per lane | Normal audit-then-merge | BLOCKED | (pending) | `docs/_audits/variance_coaching_v2/pr_<n>_lane_g.md` |

## Notes

- Lane A is the GATED lane. Lanes B to G do not dispatch until the
  operator explicitly approves Lane A's PR (revised contract + phase
  doc + reconciliation memo).
- Reconciliation outcome (memo): Subjects 1, 2, 3, 4, 5a ALIGNED;
  Subject 5b DIVERGES (color is sign-driven, must be
  sentiment-driven) and is contained by the already-planned Lane C
  (presentation-only, no `LaborModel` edit). One optional future
  `LaborModel` hardening (`vc2.logic.1`) is deferred and NOT
  authorized by this wave.
- No `LaborModel` engine change is required by the V2 wave.
