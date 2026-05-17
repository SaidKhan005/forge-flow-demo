# Driver-logic Reconciliation Memo (Variance Coaching V2, Lane A)

Status: Lane A deliverable, IN-REVIEW (gated).
Scope: read-only reconciliation. Lane A implements NO code. Every
divergence below is scoped as its own operator-gated micro-slice that
a later lane (or F-logic) implements only after explicit operator
approval (HP #3: no app-logic change folded silently into a UI lane).

Method: for each subject, current behaviour with `file:line`, the
matching rule in `docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`
(chapter / section) AND in `docs/Knowledge_graph_docs/Bold By Design.md`
(chapter), a verdict (ALIGNED / DIVERGES), and the required change if
it diverges. Code read at worktree base `30d5af43`
(`lib/services/labor_model.dart` is byte-identical to the read used
for this memo; line numbers cited against that file).

Authority docs read:
`docs/Knowledge_graph_docs/jim_taylor_labor_model_deep_dive.md`
(chapters 4, 6, 7, 8, 9, 10, 11, 12) and
`docs/Knowledge_graph_docs/Bold By Design.md` (chapters 2 Three
Levers, 4 Profit Gap, 5 Core Labor Equation, 18 Scheduling Against
Volume, 19 to 21 OPZ / overstaffing / understaffing).

---

## Subject 1: `determineLever` / `determineLeverGated` (thresholds, priority order, on-model fallback)

### Current behaviour (file:line)

- Two public entry points share one candidate engine.
  `LaborModel.determineLever` at `lib/services/labor_model.dart:120-159`
  (legacy: empty-candidate returns the literal `'covers_down'`, line
  157). `LaborModel.determineLeverGated` at
  `lib/services/labor_model.dart:171-209` (empty-candidate returns
  `onModelSentinel` `'on_model'`, line 207; sentinel const at
  `:22`).
- Candidate engine `_leverCandidates` at
  `lib/services/labor_model.dart:230-303`. Relative-deviation
  thresholds (lines 259-264, 270-271, 277-278, 284-285, 291-292,
  298-299): covers +/-2% (`0.02`), PPA +/-3% (`0.03`), CPLH +/-5%
  (`0.05`), SPLH +/-5% (`0.05`), FOH/BOH wage +/-3% (`0.03`),
  FOH/BOH hours-flex +/-10% (`0.10`). Each axis read as relative
  deviation against its own denominator (lines 248-256); a null
  optional input silently skips that axis (guards at 268, 275, 282,
  289, 296).
- Winner: max `|delta|` wins (`_selectLever`,
  `lib/services/labor_model.dart:307-319`); ties resolve by
  `_priorityOrder` (`:213-222`), lower index wins. Priority families:
  covers > ppa > cplh > splh > foh_wage > boh_wage > foh_hours >
  boh_hours; within a family "down" before "up".
- Favorable classification `isFavorableLever` at
  `lib/services/labor_model.dart:522-536`.

### Jim Taylor match

- The five-lever diagnostic and its FOH/BOH split is Chapter 10 "The
  diagnostic - tracing which input moved"
  (`jim_taylor_labor_model_deep_dive.md:766-916`): covers, PPA, CPLH
  (FOH), SPLH (BOH), FOH wage, BOH wage each move labor % in a
  specific direction for a specific reason, each with a different
  fix; "Fix the specific input that moved" (callout at `:914-916`).
  The code's 16-id catalog is the up/down expansion of exactly these
  axes plus the hours-flex pair (the schedule-side view of the
  covers bleed, per Chapter 10's covers-down note at `:792` and
  Chapter 18 in Bold by Design).
- "The largest absolute deviation wins" + the covers-first ordering
  matches Chapter 12 "Step 5: Track variance weekly... If it moved,
  one of the five levers moved with it. Go to the lever cards in
  Chapter 10. Find the specific input"
  (`jim_taylor_labor_model_deep_dive.md:998-1000`) and the Chapter 1
  primacy of covers/volume as the demand anchor (`:39-110`).
- The thresholds themselves (the +/-2 / 3 / 5 / 10 percent bands)
  are NOT specified anywhere in Jim Taylor. The deep dive gives
  worked deltas (covers 1,200 -> 1,320; PPA $42 -> $46; CPLH 4.5 ->
  5.2 at `:772-912`) but never a "fires below X%" cutoff. The
  thresholds are an F&F engineering convention layered on top of the
  framework; they are not contradicted by it.

### Bold by Design match

- The covers > ppa / wage > productivity decomposition is the Three
  Levers + Core Labor Equation: labor % = wage / (productivity x
  guest spend) (`Bold By Design.md:118-152` Ch. 2, `:534-596`
  Ch. 5). Bold by Design's diagnostic ("Every change in labor
  percentage can be traced back to one of three causes. Wages
  changed. Guest spend changed. Productivity changed. There are no
  other explanations." `:582-588`) is the framework the 16-id
  catalog operationalizes (covers is the volume denominator beneath
  guest spend; hours-flex is the productivity lever seen from the
  schedule side per Ch. 18 `:2064-2118`).
- Bold by Design specifies NO numeric thresholds and NO tie-break
  ordering. It is framework-level only.

### Verdict: ALIGNED

The axis taxonomy, the FOH/BOH split, the "single dominant input"
selection, and the covers-first priority all match Jim Taylor Ch. 10
+ Ch. 12 and Bold by Design Ch. 2 / 5. The numeric thresholds and the
exact `_priorityOrder` are F&F conventions neither doc specifies; they
are not contradicted. The split between `determineLever` (legacy
`'covers_down'` fallback) and `determineLeverGated` (`on_model`
sentinel) is a contract-sanctioned honesty fix (7.58.0a, Finding
F-2) and is consistent with Bold by Design Ch. 4's "do not overclaim
a leak you cannot see" posture (`:404-420`); no divergence.

Required change: none.

---

## Subject 2: the "favorable covers week with soft CPLH is luck not design" behaviour

This is called out explicitly in the task and in the mockup
read-line ("A good week that hides a soft CPLH is luck, not design",
`variance_tab_v2_mockup.html:226`) and `covers_up.ws`
(`primary_driver_catalog_evolved.html:90`).

### Current behaviour (file:line)

- `determineLever` selects by max `|delta|` only
  (`lib/services/labor_model.dart:307-319`). In the mockup scenario
  covers ran `+82` over a `910` plan (~9% over, above the 2%
  threshold) and CPLH ran `4.59` vs `4.85` target (~5.4% below, just
  above the 5% threshold). The larger relative deviation (covers
  ~9%) wins, so `determineLever` returns `covers_up` and the card
  renders the favorable `covers_up` copy as the Primary Driver, even
  though the week posted a net dollar LOSS because CPLH was soft.
- The "luck not design" judgement is NOT in the lever-selection
  engine. It lives in the catalog COPY (`covers_up.whatHappened` /
  `.teachingNote`, contract V2-1: "check CPLH. If it held in the zone
  this was design. If it ran soft, the volume did work the schedule
  should have done.") and in the derived dollar attribution
  (`attributeDollarImpactByAxis`, Subject 3) that the arrow chain +
  read-line consume to show the net `−$247`.

### Jim Taylor match

- Chapter 12 Step 3: "Look for when CPLH, SPLH, and PPA are all high
  together. That is your team at their best"
  (`jim_taylor_labor_model_deep_dive.md:992`). Chapter 11 "the only
  zone where profit is consistently designed" is INSIDE the OPZ with
  CPLH at target (`:950-952`). A covers-up week with CPLH below
  target is, by Jim Taylor, NOT designed profit; it is volume
  masking a scheduling leak (Ch. 10 covers-up note "If consistent,
  recalibrate the forecast upward" `:781` paired with the CPLH-down
  note "FOH overstaffed for actual volume... Fix the schedule"
  `:840`). The framework wants the soft CPLH surfaced, not hidden
  behind the favorable covers headline.

### Bold by Design match

- Ch. 4 The Profit Gap: profit "leaks... A slight decline in
  productivity that goes unnoticed" and "Most operators focus on
  outcomes rather than the system that produces them"
  (`Bold By Design.md:410-425`). A favorable covers headline that
  buries a soft-CPLH productivity leak is exactly the Profit Gap
  staying invisible. Ch. 2 Lever Three warns productivity is "the
  most dangerous lever when misunderstood" (`:200-205`).

### Verdict: ALIGNED (with a note, no code change required for V2)

The engine correctly returns `covers_up` (covers genuinely was the
largest-magnitude single input). The framework does NOT require the
selector to suppress a favorable headline when the net dollars are
negative. It requires the soft CPLH to be made visible alongside it.
The V2 design satisfies the framework through PRESENTATION, not
selection:

- the evolved `covers_up` copy (contract V2-1) explicitly tells the
  operator to check CPLH and names the luck-vs-design test;
- the arrow chain (contract V2-3) renders the dominant opposing axis
  (CPLH `−$462`) as node 2 and the net `−$247` loss as node 3;
- the sign/sentiment convention (V2-2) renders the net red "below
  best possible" so a favorable lever id never reads as a green win
  when the week lost money.

Required change: none for the V2 wave. Optional future hardening
(NOT in scope, flagged for the operator's awareness only): a
"favorable-headline-with-net-loss" guard that annotates the Primary
Driver when `isFavorableLever(detectedId)` is true but the net
`attributeDollarImpactByAxis` sum is adverse. This would be its own
operator-gated `LaborModel`/read-model micro-slice (call it
`vc2.logic.1`); it is explicitly deferred and NOT authorized by Lane
A or any V2 presentation lane.

---

## Subject 3: `attributeDollarImpactByAxis` (telescoping decomposition + sign convention)

### Current behaviour (file:line)

- `attributeDollarImpactByAxis` at
  `lib/services/labor_model.dart:383-518`. Six-step rotation from
  baseline (forecast volume + target rates + target wages) to actual,
  one variable at a time, documented at `:335-382`:
  1. covers term `:441-449` (model FOH + BOH hours shift from
     forecast to actual covers, x target wages, negated);
  2. ppa term `:451-458` (BOH model shift from target PPA to actual
     PPA, x target BOH wage, negated);
  3. FOH schedule-vs-forecast-baseline term `:460-478` routed to
     `cplh_down`/`cplh_up` when `avgCPLH != null`, else to
     `foh_hours_over`/`foh_hours_under`;
  4. BOH schedule-vs-baseline term `:480-495` routed to
     `splh_down`/`splh_up` or `boh_hours_over`/`boh_hours_under`;
  5. FOH wage premium on actual hours `:497-505`;
  6. BOH wage premium on actual hours `:507-515`.
- Telescoping identity proven in the comment at
  `lib/services/labor_model.dart:347-353`: the six terms sum to
  `LaborModel.dollarGap(...)` (`:78-90`) exactly when all axes are
  provided, modulo integer rounding in `modelFohHours` /
  `modelBohHours`.
- Sign convention: positive term = adverse, negative = favorable
  (`lib/services/labor_model.dart:355` and the per-step `if (>0)
  adverse-id else if (<0) favorable-id` blocks); "Sign convention
  matches `isFavorableLever` polarity throughout" (`:375`). Missing
  optional axes contribute 0 (the F-3 partial-input tolerance,
  `:331-333`, `:377-382`).

### Jim Taylor match

- Chapter 8 Theoretical Labor + Chapter 10 "The three-part model"
  (`jim_taylor_labor_model_deep_dive.md:667-712`): variance = actual
  labor % minus theoretical labor %, and the dollar gap is actual
  labor cost vs theoretical labor cost for the volume actually worked
  ("If theoretical labor is 15% and actual is 19%, that 4-point gap
  isn't a wage problem. It's a productivity management gap.", quote
  at `:696`). The covers->ppa->FOH->BOH->FOH-wage->BOH-wage walk is
  the dollar realization of the Chapter 10 "trace which input moved"
  diagnostic at `:766-916`: each step isolates exactly one of Jim
  Taylor's named levers.
- Chapter 10 covers-down note "Hours didn't flex with volume. Both
  sides drift" (`:792`) is precisely the offset the comment at
  `lib/services/labor_model.dart:367-373` describes (covers term and
  cplh / hours-flex term net to zero when the schedule flexes
  perfectly with covers).

### Bold by Design match

- Ch. 5 Core Labor Equation: labor % = hours x wage / (covers x
  guest spend), and "A change in any one of these variables will
  move the number" (`Bold By Design.md:548-558`). The six-step walk
  rotating one variable at a time is the literal application of that
  decomposition. Ch. 4 The Profit Gap "It is the result of many
  small inefficiencies that accumulate across the system... Each of
  these changes seems insignificant on its own. Together, they
  create meaningful financial impact." (`:404-420`) is exactly what
  the per-axis dollar attribution surfaces.

### Verdict: ALIGNED

The telescoping decomposition is a faithful, sum-preserving dollar
realization of Jim Taylor Ch. 8 + Ch. 10's theoretical-vs-actual gap
and Bold by Design Ch. 5's Core Labor Equation. The sign convention
(positive = adverse, negative = favorable, polarity-matched to
`isFavorableLever`) is internally consistent and is what contract
V2-2 maps onto the red/green sentiment display.

Required change: none in `LaborModel`.

Note for Lane C (presentation, NOT a logic change): see Subject 5.
The function's sign is correct; the divergence is purely in how the
two WIDGETS color it.

---

## Subject 4: theoretical labor / closable gap (best possible vs actual)

### Current behaviour (file:line)

- `theoreticalLaborPct` at `lib/services/labor_model.dart:57-68`:
  FOH labor % = fohWage / (targetCPLH x targetPPA) x 100; BOH labor %
  = bohWage / targetSPLH x 100; total = sum. Comment cites "Jim
  Taylor Ch. 9 derivation from target rates and wages... a property
  of the targets and wages, not of volume" (`:49-56`); guards a zero
  denominator (`:64`).
- `dollarGap` at `lib/services/labor_model.dart:78-90`: actual labor
  dollar minus (theoretical FOH hours x fohWage + theoretical BOH
  hours x bohWage); "Positive = over model (unfavorable), Negative =
  under model (favorable)" (`:74-76`).
- The mockup "best possible 20.0% / actual 20.7% / closable gap 0.7
  pts" footer (`variance_tab_v2_mockup.html:257`) is the
  `theoreticalLaborPct` ("best possible") vs actual labor % framing;
  the `Loss if this continues` projection rows
  (`variance_tab_v2_mockup.html:252-258`) are the `dollarGap`
  extrapolated. Contract V2-6 freezes this math; V2 only re-labels
  sign + color and re-titles the disclosure.

### Jim Taylor match

- Chapter 8 "What it is" + Chapter 9 "How it assembles into your
  theoretical labor %"
  (`jim_taylor_labor_model_deep_dive.md:470-655`): theoretical labor
  is built from target CPLH, target SPLH, target PPA, and blended
  wage; FOH theoretical $ = model FOH hours x FOH wage, BOH = model
  BOH hours x BOH wage; total theoretical labor $ example at `:639`.
  The code's `theoreticalLaborPct` (rates+wages, volume-independent)
  and `dollarGap` (actual cost minus theoretical cost at the volume
  worked) are exactly the Chapter 8/9/10 construction. Chapter 10
  "What a 4-point gap actually costs" (`:692-696`) is the closable
  gap framing.

### Bold by Design match

- Ch. 3 "The Best Version of the Business" + Ch. 4 The Profit Gap:
  "Every restaurant operates in two realities... The distance
  between those two realities is what we call the Profit Gap... It
  is measurable." (`Bold By Design.md:302-466`, esp. `:396-466`).
  "Best possible" = the best-version labor %; "closable gap" = the
  Profit Gap; `dollarGap` annualized = the Profit Gap quantified.
  The mockup's "best possible / actual / closable" framing is the
  Profit Gap rendered.

### Verdict: ALIGNED

`theoreticalLaborPct` and `dollarGap` match Jim Taylor Ch. 8/9/10 and
Bold by Design Ch. 3/4. The "best possible / closable gap" labels in
the mockup are an honest rename of the existing theoretical-floor
math, which contract V2-6 freezes. No divergence.

Required change: none. (Reaffirm V2-6: the projection math and the
best-possible/actual/closable footer are FROZEN; Lane C only changes
the sign/color label and the disclosure title.)

---

## Subject 5: OPZ floor / ceiling + range-graph model; and sign- vs sentiment-driven color in code today

### 5a. OPZ floor / ceiling + range graph

#### Current behaviour (file:line)

- `BaselineAuthorityService.opzFloorCPLH` /
  `opzCeilingCPLH` at
  `lib/services/baseline_authority_service.dart:391-394`: floor =
  min CPLH, ceiling = max CPLH of the OPZ source records (selected
  benchmark / star shifts; source-set comment at `:319-322`,
  `:378-389`). `opzHeadroomCPLH` `:397`, `opzUsedPct` `:399-404`,
  `opzValidation` (above_ceiling / near_ceiling / below_floor /
  in_zone, with Chapter 11 messages) `:406-452`, `opzStatusForCplh`
  (below / in / above) `:454-461`, `opzStatusLabelForCplh`
  `:463-467`. The range graph reads through `rangeGraphModel`
  (seam noted at `:225`).
- The History tab OPZ band + "now" marker
  (`variance_tab_v2_mockup.html:276-288`) is this floor/ceiling +
  `opzStatusForCplh` rendered; contract V2-6 keeps History's OPZ
  band unchanged (telestrator excluded).

#### Jim Taylor match

- Chapter 11 The Optimal Productivity Zone
  (`jim_taylor_labor_model_deep_dive.md:928-974`): "The floor and
  the ceiling - why going above it costs you as much as going
  below"; below OPZ = too many staff, CPLH low, labor bleeds; above
  OPZ = too few staff, check-backs stop, PPA drops, best people quit;
  inside = the only zone where profit is consistently designed
  (`:950-952`). Jim's 30-day data table (`:960-966`) shows the
  floor/ceiling as the empirical min/max of the sustainable CPLH
  band. The code's min/max-of-source-records definition matches the
  Chapter 11 "range where your team was consistently comfortable and
  productive" (Chapter 9 `:575`).

#### Bold by Design match

- Ch. 19 to 21 (Psychology of Overstaffing / Understaffing / The
  Productivity System, `Bold By Design.md:2172-2400`) and Ch. 18
  Scheduling Against Volume (`:2064-2160`): the OPZ is the band
  between overstaffing (below) and understaffing (above); "Understaffing,
  like overstaffing, pushes the system outside the Optimal
  Productivity Zone" (`:2112`). The `opzValidation` near_ceiling /
  above_ceiling warnings (code `:419-433`) match Ch. 21 "the purpose
  of the Optimal Productivity Zone" (`:2372`) and Ch. 3 "Discovering
  Your Performance Range" (`:340-396`).

#### Verdict: ALIGNED

The OPZ floor/ceiling (min/max of the sustainable CPLH source set),
the headroom / used-% / validation banding, and the live
below/in/above status all match Jim Taylor Ch. 11 + Ch. 9 and Bold by
Design Ch. 18 to 21. No divergence. V2-6 keeps the History OPZ band
unchanged.

Required change: none.

### 5b. Is color sign-driven or sentiment-driven in code today?

This is called out explicitly in the task.

#### Current behaviour (file:line) - this is the one DIVERGENCE

- `lib/widgets/dollar_impact_card.dart:180-188`: `final isOver =
  value > 0; final color = isOver ? AppColors.negative :
  AppColors.positive; final sign = isOver ? '−' : '+';`. Color
  AND sign are both derived from the raw arithmetic sign of `value`.
- `lib/widgets/lever_card.dart:285-297`
  (`_AttributionRow`): `final isOver = row.value > 0; final color =
  isOver ? AppColors.negative : AppColors.positive; final sign =
  isOver ? '−' : '+';`. Same pattern: color from `row.value > 0`.
- Note this is currently NUMERICALLY consistent with the spec for
  these two widgets only because `attributeDollarImpactByAxis`
  pre-encodes sentiment into the sign (positive term = adverse, per
  Subject 3, `lib/services/labor_model.dart:355,375`). So today the
  red/green happens to land correctly for these dollar-gap rows.
- BUT the model already carries an explicit sentiment flag the
  widgets ignore: `LeverCardData.isFavorable`
  (`lib/domain/constants/app_defaults.dart:73`, "true = positive
  (green); false = unfavorable (red)") and
  `CrossAxisPairData.isFavorable`
  (`lib/domain/constants/cross_axis_pair_catalog.dart:59`), plus
  `LaborModel.isFavorableLever` (`lib/services/labor_model.dart:522-536`).
  The widgets drive color from `value > 0` rather than from this
  flag.

#### Authority match

- Neither Jim Taylor nor Bold by Design specifies UI color. The
  binding rule here is contract V2-2 (this wave's spec, reconciled
  from `variance_tab_v2_mockup.html`): "Color is driven by a
  favorable / unfavorable flag, never by the raw arithmetic sign of
  the underlying number." The mockup itself shows the failure mode
  V2-2 guards against: WTD `Covers +82` is green/good but `Blended
  Wage +$0.03` is red/bad (`variance_tab_v2_mockup.html:240-241`),
  same arithmetic sign, opposite sentiment. A `value > 0` rule
  cannot express that; only a sentiment flag can.

#### Verdict: DIVERGES (presentation-layer; not a `LaborModel` change)

Color is sign-driven in code today
(`dollar_impact_card.dart:180-181`, `lever_card.dart:285-286`),
whereas contract V2-2 requires it be sentiment-driven from a
favorable / unfavorable flag. It currently produces correct colors
for the dollar-gap rows only because the model pre-bakes sentiment
into the sign; it would mis-color any surface where arithmetic sign
and sentiment diverge (the WTD `+$0.03` wage case the mockup itself
shows). This is the gap V2-2 exists to close.

Required change (scoped as its OWN slice, this is Lane C, NOT Lane A
and NOT a `LaborModel` edit):

- Slice `vc2.C` (already the planned Lane C; recorded here as the
  reconciliation-mandated change, normal audit-then-merge gate):
  in `lib/widgets/dollar_impact_card.dart` and
  `lib/widgets/lever_card.dart` (and the This Week hero), replace the
  `value > 0` color derivation with a favorable / unfavorable flag:
  use `LeverCardData.isFavorable` / `CrossAxisPairData.isFavorable` /
  `LaborModel.isFavorableLever` for lever-keyed rows, and an explicit
  favorable predicate (loss vs gain to the operator) for the hero and
  the dollar-impact projection rows. The displayed sign glyph and the
  color must be decided together from the same sentiment source so a
  red value is always `−` and a green value always `+`. No
  `LaborModel` math change; `attributeDollarImpactByAxis` keeps its
  current sign output (Subject 3 ALIGNED). Golden test must include a
  same-arithmetic-sign / opposite-sentiment case (the WTD `+$0.03`
  wage scenario) to prove color follows sentiment, not sign.

This is a presentation-layer divergence fully contained by the
already-planned Lane C; it does NOT require a `LaborModel`
(F-logic) micro-slice and does NOT touch the engine.

---

## Summary of verdicts

| # | Subject | Jim Taylor | Bold by Design | Verdict |
| --- | --- | --- | --- | --- |
| 1 | `determineLever` / `determineLeverGated` thresholds, priority, on-model fallback | Ch. 10, 12 | Ch. 2, 4, 5 | ALIGNED |
| 2 | "favorable covers + soft CPLH = luck not design" | Ch. 11, 12 | Ch. 2, 4 | ALIGNED (satisfied by V2 presentation; optional future guard deferred + gated) |
| 3 | `attributeDollarImpactByAxis` telescoping + sign | Ch. 8, 10 | Ch. 5, 4 | ALIGNED |
| 4 | theoretical labor / closable gap (best possible vs actual) | Ch. 8, 9, 10 | Ch. 3, 4 | ALIGNED |
| 5a | OPZ floor / ceiling + range graph | Ch. 11, 9 | Ch. 18 to 21 | ALIGNED |
| 5b | color sign- vs sentiment-driven in code today | (no doc; contract V2-2) | (no doc; contract V2-2) | **DIVERGES** |

### Divergences requiring their own scoped slice

1. **5b (color is sign-driven, must be sentiment-driven).** Scope:
   Lane C, presentation-only, `dollar_impact_card.dart:180-181` +
   `lever_card.dart:285-286` + This Week hero. Drive color from
   `isFavorable` / a favorable predicate, never `value > 0`. No
   `LaborModel` change. Normal audit-then-merge gate (already a
   planned lane; this memo records it as reconciliation-mandated).

### Optional future hardening (deferred, NOT authorized by this wave)

- Subject 2 optional `vc2.logic.1`: a favorable-headline-with-net-loss
  annotation on the Primary Driver when `isFavorableLever(detectedId)`
  is true but the net `attributeDollarImpactByAxis` sum is adverse.
  Its own operator-gated `LaborModel` / read-model micro-slice. NOT
  in the V2 wave scope; flagged for operator awareness only. The V2
  presentation (arrow chain + sign convention + evolved copy) already
  makes the soft CPLH and the net loss visible, so this is hardening,
  not a correctness blocker.

No `LaborModel` engine edit is required by the V2 wave. The only
reconciliation-mandated change is the Lane C presentation fix (5b).
