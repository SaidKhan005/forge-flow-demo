# Variance Coaching V2 Ledger

One row per lane. Lanes A–F MERGED to `origin/master`; Lane G
(wave-close verification) IN-REVIEW. Audit artifacts live at
`docs/_audits/variance_coaching_v2/pr_<n>_<lane>.md`.

Plan of record:
`docs/f&f Coaching/variance_coaching_v2_implementation_plan.md`.
Phase doc: `docs/phases/variance_coaching_v2/variance_coaching_v2.md`.
Contract delta: `docs/contracts/phase_7_58_primary_driver_contract.md`
(V2 Revision section).
Reconciliation memo:
`docs/_audits/variance_coaching_v2/driver_logic_reconciliation.md`.

| Lane | Scope | Depends-on | Gate | Status | PR | Audit-doc path |
| --- | --- | --- | --- | --- | --- | --- |
| A | Revise 7.58 contract (V2 Revision section: verbatim 21-state copy catalog, sign/sentiment convention, arrow-chain rule, inline-emphasis markup, 3-frame Learn, guardrails) + create phase doc + reconciliation memo + this ledger. Docs only. | none | GATED (contract-touching + catalog LOCKED + logic-deciding 7.58; operator sign-off before B to G) | MERGED | #892 squash `04c68b66` | `docs/_audits/variance_coaching_v2/pr_<n>_lane_a.md` (orchestrator) |
| B | Apply V2-1 strings to `lib/domain/constants/app_defaults.dart` (`LeverCards`) + `lib/domain/constants/cross_axis_pair_catalog.dart` (`CrossAxisPairs`) byte-for-byte. Golden test copy == V2-1; em-dash + en-dash lint. Pure metadata. | A approved | GATED (catalog LOCKED; rides on A's approved spec) | MERGED | #903 squash `4c76c68b` | `docs/_audits/variance_coaching_v2/pr_<n>_lane_b.md` |
| C | `dollar_impact_card.dart` + `lever_card.dart` + This Week hero: enforce V2-2; drive color from a favorable/unfavorable flag, never `value > 0` (reconciliation Subject 5b). Tables untouched. Golden tests incl. same-sign/opposite-sentiment case. | A approved | Normal audit-then-merge | MERGED | #902 squash `1b8e02ee` | `docs/_audits/variance_coaching_v2/pr_<n>_lane_c.md` |
| D | New `lib/widgets/variance/driver_arrow_chain.dart`, integrate into `variance_this_week_tab.dart` Primary Driver per V2-3; fed by existing attribution (no new math); `whatHappened` fused beneath; degraded suppresses chain. Widget test. | A approved | Normal audit-then-merge | MERGED | #898 squash `219662d5` | `docs/_audits/variance_coaching_v2/pr_<n>_lane_d.md` |
| E | Inline-emphasis markup convention (V2-4) + renderer producing colored causal spans + value chips; words preserved byte-for-byte; plain-text fallback test (no markup in Shift/exports). | A approved | Normal audit-then-merge | MERGED | #896 squash `350591d8` | `docs/_audits/variance_coaching_v2/pr_<n>_lane_e.md` |
| F | Restructure `variance_learn_tab.dart` + learn widgets per V2-5: rail preserved; Leak + Wins to 3-frame story + action card; Cross-Axis 4-pair swipe; dots adapt. Content from Lane B catalog. | B + E merged | Normal audit-then-merge | MERGED | #908 squash `24b25dc1` | `docs/_audits/variance_coaching_v2/pr_<n>_lane_f.md` |
| G | Cross-cutting verification: re-pin downstream metric-casing tests, engine-unchanged proof, full variance suite, em-dash lint, demo-mode walkthrough (HP #10). | rolls per lane | Normal audit-then-merge | IN-REVIEW | `claude/variance-v2-lane-g` (PR open) | `docs/_audits/variance_coaching_v2/lane_g_walkthrough.md` + `pr_<n>_lane_g.md` |

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

## Wave Definition of Done (plan §8) — Lane G verification @ master `24b25dc1`

| DoD item | Status | Evidence |
| --- | --- | --- |
| All lanes A–F merged | PASS | SHAs `04c68b66`/`4c76c68b`/`1b8e02ee`/`219662d5`/`350591d8`/`24b25dc1` (table above). |
| Downstream metric-casing test debt fixed | PASS | `test/baseline_manager_screen_test.dart` 4 stale `'CPLH ABOVE TARGET'`/`'SPLH BELOW TARGET'` expectations re-pinned to V2-1 sentence case (`'CPLH above target'`/`'SPLH below target'`); 46/46 green. (File subsequently split per test-suite tightening audit 2026-05-20 Bucket 5b; the V2-1 sentence-case expectations now live at `test/baseline_manager_screen_core_test.dart:310` (CPLH above target) and `test/baseline_manager_screen_calendar_and_navigation_test.dart:467` (SPLH below target).) `test/variance_history_widget_test.dart` was already green (no stale ALL-CAPS metric expectations; its `COVERS CAME IN LIGHT` refs are `findsNothing`). Each diff confirmed solely the V2-1 casing copy change (`git show 4c76c68b^` old vs merged), not a regression. |
| Attribution math / engine provably unchanged | PASS | `lib/services/labor_model.dart` identical blob `073304e7…` at V2 base `40cc12df` and HEAD `24b25dc1`; zero wave commits touched it. `labor_model_dollar_attribution` + `labor_model_boh_sales` + `lever_logic` = 65/65 green. |
| Full variance widget/screen suite green (wave-introduced failures = 0) | PASS | history/learn-coverage/learn-parity/projection/wtd/dollar-impact/lever-card/arrow-chain/inline-emphasis/sign-sentiment/7.58-contract suites all green. `variance_visual_widget_test.dart` 20/1: the **1 failure is the pre-existing externally-owned History "Previous Weeks" week-range test**, owned by branch `claude/fix-history-week-range-test` (commit `468c2528`); NOT touched by this wave, NOT fixed here. Zero wave-introduced failures. |
| em-dash lint green | PASS | `tool/ux_em_dash_lint.dart` clean (187 files, 13 roots); `ux_em_dash_lint_test` 11/11. |
| Demo-mode walkthrough recorded (HP #10) | PASS (with finding) | `lane_g_walkthrough.md` + `lane_g_shots/01_app_load.png`. Demo flavor compiles + boots clean; per-surface mockup conformance traced to merged code. |
| Runtime matches mockup (wording/sign/arrow/emphasis/3-frame/tables) | PASS except F-1 | All surfaces conform (trace in walkthrough §2). **Finding F-1 (OPEN):** dollar-impact disclosure title `Loss if this continues` (contract V2-2 l.578 / V2-6 l.712) is ABSENT — section keeps pre-V2 `'DOLLAR IMPACT'` header; Lane C (#902) shortfall. Documented for a follow-up Lane C-scoped presentation micro-slice; not Lane G's to fix (verify → STOP). |
| Revised 7.58 contract + phase doc landed | PASS | Lane A `04c68b66` (#892). |
| Operator visual sign-off vs `docs/f&f Coaching/*.html` | PENDING | Operator gate; not claimed by Lane G. |

### Out-of-wave repo-health flag (operator)

`lib/widgets/demo_mode_banner.dart` is **missing on master** while
`integration_test/in_app_notifications/_harness.dart:67` and
`integration_test/phase_4_emulator/_harness.dart:47` import it. This
breaks a whole-repo `flutter analyze` and a stale legacy
`.git/hooks/pre-commit`. Lane G confirmed it is **contained to the
integration_test harnesses** — the app build is unaffected (the demo
flavor `flutter build web` compiled clean). Out of V2 wave scope; NOT
fixed here; flagged for an operator-owned repo-health follow-up.
