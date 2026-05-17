# Variance Coaching V2 — Lane G Runtime-Acceptance Walkthrough (HP #10)

Status: wave-close verification artifact (Lane G).
Branch: `claude/variance-v2-lane-g`. Base: `master` @ `24b25dc1` (Lane F merge #908).
Authority: `docs/f&f Coaching/variance_tab_v2_mockup.html` (behavioural
acceptance reference) + `docs/contracts/phase_7_58_primary_driver_contract.md`
V2 Revision (V2-1 .. V2-6). Acceptance pattern is advisory per
`docs/contracts/slice_runtime_acceptance_contract.md` (not a CI gate;
reviewer judgment).

## 1. Demo flavor boot proof (HP #2 / HP #10)

- Built the Forge & Flow demo flavor for web:
  `flutter build web --target=lib/main_forgeflow.dart --dart-define=kDemoMode=true`
  → `√ Built build\web` in 46.9s, **clean compile**.
- Served the bundle (`python -m http.server 8183 --directory build/web`,
  HTTP 200) and captured a headless-Chrome render at mobile width
  (430×932): `lane_g_shots/01_app_load.png`.
- Screenshot shows the demo flavor boots to the Forge & Flow login with
  the documented **"Use demo operator"** one-tap carve-out
  (`lib/screens/auth/login_screen.dart` `_demoOperatorSignInEnabled`,
  the contract-endorsed demo-auth source swap; CLAUDE.md Demo Mode
  carve-out 1). The demo flavor is healthy.

### Walkthrough method note (deterministic source-to-mockup trace)

Forge & Flow is a Flutter **CanvasKit** app: it renders to a single
`<canvas>` with no clickable DOM, so a headless-Chrome
`--screenshot` cannot drive Variance → This Week / History / Learn
navigation (no integration_test driver is in scope for a wave-close
worker, and the runtime-acceptance contract states Browser Use is "run
separately by the operator"). The boot screenshot proves the demo
flavor is alive; the per-surface mockup conformance below is verified
by **tracing every mockup acceptance marker to the merged V2 lane code
with file:line citations** — the contract names the persisted HTML as
the behavioural acceptance reference, so code that provably renders the
HTML's structure/wording/sign is the acceptance evidence. Operator
visual sign-off against the HTML (plan §8) remains the final gate and
is NOT claimed here.

## 2. Per-surface mockup conformance trace

Legend: PASS = merged code provably renders the mockup spec;
FINDING = a real conformance gap (documented, NOT papered over).

| Mockup requirement (variance_tab_v2_mockup.html) | Contract | Merged code (file:line) | Verdict |
| --- | --- | --- | --- |
| Hero shows the loss as `−$…` red with "below best possible"; sign = sentiment, never `value>0` | V2-2 | `lib/screens/variance/variance_this_week_tab.dart:297-326` `_ThisWeekHero`: single `MoneySentiment.fromDollarGap(gap)` source; `sentiment.sign`/`sentiment.color` paired; `verdictPlace = sentiment.favorable ? 'above best possible' : 'below best possible'`; `▼`/`▲` from `favorable`. Doc comment l.292-296 forbids `value > 0`. | PASS |
| Primary Driver arrow chain renders above the fused `whatHappened` | V2-3 | `lib/widgets/variance/driver_arrow_chain.dart:9-33` (3-node `driver → counter-axis → result`, mockup `.chain`/`.cnode`); integrated `variance_this_week_tab.dart:226-239` `DriverArrowChain` fused directly above the card `whatHappened` (no chart-then-paragraph split). Degraded `on_model`/unknown/null → renders nothing (l.26-33; `LeverCardNotYetAvailable` path untouched). | PASS |
| Dollar attribution colors: covers `+$` green, adverse axes `−$` red | V2-2 | `lib/widgets/lever_card.dart:213-222` `_DollarAttributionSection`: color from `MoneySentiment.fromAxisImpact(v).favorable`, "never re-evaluates `value > 0`" (l.216-218). Sentiment pre-encoded in the axis sign by `LaborModel.attributeDollarImpactByAxis`. | PASS |
| Dollar-impact disclosure titled **"Loss if this continues"** | V2-2 (l.578), V2-6 (l.712) | **ABSENT.** The dollar-impact section renders under the pre-V2 sticky header `'DOLLAR IMPACT'` (`variance_this_week_tab.dart:198`); the literal `Loss if this continues` exists nowhere in `lib/` (grep clean). `DollarImpactCard` (`lib/widgets/dollar_impact_card.dart`) renders no title; History uses the WeekDetail path, also untitled. Lane C (#902 `1b8e02ee`) reworked sentiment + added the hero but did not re-title the disclosure. | **FINDING F-1 (OPEN)** |
| Dollar-impact rows `−$` red, labelled this week/this month/last 60 days/annualized; math FROZEN | V2-2, V2-6 | `dollar_impact_card.dart:99-117` rows + labels intact; `:188` `MoneySentiment.fromDollarGap(value)` drives sign/color; row math reuses frozen `weekImpact`/`sixtyDayImpact`/`annualizedImpact` inputs (no recompute). | PASS (rows) |
| Learn keeps rail Recurring Leak / Repeatable Wins / Cross-Axis; Leak+Wins as 3-frame story + THE PLAY; Cross-Axis 4-pair swipe; dots adapt | V2-5 | `lib/screens/variance/variance_learn_tab.dart:175-177` rail preserved in mockup order; l.203-204 Leak/Wins → 3-frame story (dots adapt to 3); l.297-298 Cross-Axis = locked 4-pair swipe (dots → 4), "exactly as the mockup `#crossTrack`"; THE PLAY action card from `whatToDo`. | PASS |
| Tables WTD vs plan + Full Week Projection visually unchanged (FROZEN) | V2-6 | `git diff 40cc12df..HEAD -- variance_this_week_tab.dart` shows only **additive** presentation lines reading the existing `weekData.dollarGap`, explicitly commented "Presentation only … FROZEN math". No table row/value/math change by any lane. | PASS |
| Inline emphasis: causal span + value chip, words byte-for-byte; plain-text fallback (no markup in Shift/exports) | V2-4 | `lib/widgets/variance/inline_emphasis_text.dart:14-95` renderer for `[[bad:]]`/`[[good:]]`/`[[chip:]]`/`[[chipg:]]`; `stripMarkup` fallback emits inner text only; "no markup token may leak into a non-rendering surface" (l.27). Catalog strings carry NO markup (Lane B). `test/widgets/variance/inline_emphasis_text_test.dart` 19/19 green. | PASS |
| Zero em / en dashes anywhere in operator copy | V2-1, em-dash hard gate | `dart run tool/ux_em_dash_lint.dart` → clean, 187 operator-facing files, 13 roots. V2-1 catalog strings dash-free; the 12 dash hits in `app_defaults.dart` are comments + a pre-existing `Mon–Sun` label (line 492, outside V2 scope, not flagged by the canonical lint). | PASS |

## 3. Finding F-1 — dollar-impact disclosure title not applied (OPEN)

**What:** Contract V2-2 (`phase_7_58_primary_driver_contract.md:578`)
and V2-6 (`:712`) mandate the dollar-impact disclosure be **titled
`Loss if this continues`**; the mockup renders it as
`<details><summary>Loss if this continues …`. The merged runtime has
no such title — the section keeps the pre-V2 sticky header
`'DOLLAR IMPACT'` and the string is absent from the entire codebase.

**Root cause:** Lane C (#902) owned the sign/sentiment surface
including the dollar-impact card but applied only the sign/color rework
and the hero block; the contract-mandated re-title was not delivered.
This is a Lane C presentation deliverable shortfall, NOT a Lane G
verification item and NOT explained by the V2-1 metric-casing copy
change.

**Disposition:** Documented, NOT papered over. Lane G's contract is
`branch → verify → PR → STOP` (no merge, no implementing missing gated
lane work). Surfacing to the orchestrator/operator: this is a real
wave conformance gap requiring a follow-up Lane C-scoped micro-slice
(presentation-only: re-title the dollar-impact disclosure /
`'DOLLAR IMPACT'` section to `Loss if this continues` per V2-2, with a
golden test). It does NOT block the engine-unchanged proof or the test
debt fix; it is a copy/title gap on one surface element.

## 4. Artifacts

- `lane_g_shots/01_app_load.png` — demo flavor boot (mobile width),
  proves the Forge & Flow demo + "Use demo operator" carve-out is live
  on this branch's build.
- This document — source-to-mockup conformance trace + Finding F-1.

Operator visual sign-off against `docs/f&f Coaching/*.html` (plan §8
Definition of Done) is the remaining gate and is the operator's, not
this worker's.
