# dart_code_metrics Runbook (engineering-bar metrics)

Status: Active
Last updated: 2026-05-20

Codifies the §5.2 engineering bars from
`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` as
machine-checkable metrics. The tool surfaces the gap; it does NOT
block any build today.

> Naming note: the original `dart_code_metrics` package was discontinued
> (~2 years ago) in favor of the commercial DCM product. We use the
> maintained open-source fork `dart_code_linter` (Bancolombia, 4.0.3 as
> of 2026-05). Its CLI binary is still named `metrics`. This runbook
> keeps the historical `dart_code_metrics` filename for discoverability.

## How to run locally

```sh
# Full lib/ scan, human-readable console output:
dart run dart_code_linter:metrics analyze lib/

# Machine-readable (JSON) for scripting a baseline:
dart run dart_code_linter:metrics analyze lib/ --reporter=json
```

Config lives in the `dart_code_linter:` block of `analysis_options.yaml`.
The CLI reads that block directly; the analyzer plugin is intentionally
NOT enabled (see "Advisory posture" below), so `dart analyze` /
`flutter analyze` are unaffected.

## What each rule enforces (with §5.2 defense)

| Metric (config key)     | Bar | Audit §5.2 defense (abridged) |
|-------------------------|-----|-------------------------------|
| `source-lines-of-code`  | ≤ 80 | Bar #3 "Function length ≤ 80". Flutter `build()` overrides routinely exceed 60 lines without being "too long"; 80 catches genuinely long methods (proxy dispatchers, admin state machines) while exempting the well-formed Flutter pattern. New code can adopt ≤ 60 as a soft target. |
| `cyclomatic-complexity` | ≤ 12 | Bar #4. No baseline was measured at audit time; 12 is a reasonable starting point. Recalibrate after the first full run. |
| `maximum-nesting-level` | ≤ 5  | Bar #5. Spot-check of admin/proxy code showed 5–7 deep; 5 catches the worst offenders without flagging every nested Column/Row/async-await chain. |
| `number-of-parameters`  | ≤ 7  | Bar #6. Constructor-injection-heavy classes (auth gateways, repository constructors) regularly carry 6–10 named parameters; 7 + liberal `required`-named allowance is realistic. Soft target ≤ 5 for pure formula functions. |

Note: the audit labels the function-length bar "function-lines";
`dart_code_linter`'s matching metric is `source-lines-of-code` (SLOC —
blank and comment lines are not counted), so a function's reported SLOC
is usually a little under its raw line count.

## Expected initial violation counts (baseline 2026-05-20)

Captured by running `dart run dart_code_linter:metrics analyze lib/`
once against `origin/master` tip, after applying the `metrics-exclude`
(l10n + codegen + test). 886 files / 13,735 functions scanned.

| Metric                  | Bar | Violations | Worst offender |
|-------------------------|-----|-----------:|----------------|
| `source-lines-of-code`  | ≤ 80 | 342 | `operator_web_router.dart` `_buildPostOnboardingShell` (478 SLOC) |
| `cyclomatic-complexity` | ≤ 12 | 261 | `account_screen.dart` `_AccountScreenState.build` (CC 67) |
| `maximum-nesting-level` | ≤ 5  |   4 | `oracle_micros_simphony_production_api_client.dart` `_parseGuestChecksPage` (nesting 7) |
| `number-of-parameters`  | ≤ 7  | 122 | `advisor_conversation_log_repository.dart` `recordTurn` (20 params) |

These are the gap baseline. They are expected, not a regression. A
future ratchet slice measures progress against these numbers.

## Advisory posture (and when we promote)

- **Advisory, not blocking.** The four metrics are configured in
  `analysis_options.yaml`, but the `dart_code_linter` analyzer plugin is
  deliberately left OUT of `analyzer.plugins`. Consequence: `dart
  analyze` / `flutter analyze` behave exactly as before this tooling
  landed (no new findings). The gap appears only when the metrics CLI is
  run explicitly.
- **Why advisory.** With 342 long functions, 261 complex ones, etc., a
  blocking lint now would either fail every PR or force shotgun
  `// ignore` suppressions — both defeat the goal of honestly surfacing
  the gap.
- **Promotion gate.** Raising severity to `warning`/`error`, or wiring
  the CLI into a blocking hook / CI step, is a separate gated slice held
  under the operator's "surfaces happy" decision (2026-05-20) and the
  spirit of CLAUDE.md's Ceiling-Raise Rule R-2 (tightening an
  engineering bar needs explicit operator approval). Do NOT promote in a
  drive-by PR.

## Capture-and-track flow (future "ratchet down" slice)

A future operator-led ratchet slice would:

1. Re-run the JSON reporter and recompute per-metric counts (count
   functions whose metric `level` is `warning` or `alarm`, after the
   `metrics-exclude` filter). Compare to the baseline table; the count
   must not grow.
2. Pick one metric — likely `number-of-parameters` or
   `maximum-nesting-level` first (smallest counts, lowest risk) — and
   decompose the worst offenders until the count drops by an agreed
   delta.
3. Once a metric reaches an agreed floor, promote THAT metric to a
   blocking posture (enable the plugin for it, or add a `tool/` lint)
   with explicit operator approval so it cannot regress.
4. Repeat per metric. Split "reduce the count" work from "lock the bar"
   work — never refactor and promote in the same PR.

**Ratchet enforcer (active):** `tool/metrics_ratchet_check.dart` automates
step 1. It runs the JSON reporter, counts `warning`/`alarm` functions per
metric, and fails if any count grows past the committed baseline
`tool/metrics_ratchet_baseline.json`. When a count drops it prints a note
that the baseline can be lowered (a deliberate ratchet step) but never
auto-rewrites it. Raising a baseline needs operator approval (Ceiling-raise
rule R-2). Run: `dart run tool/metrics_ratchet_check.dart`.

## Exemptions

`metrics-exclude` in `analysis_options.yaml` skips:

- `lib/l10n/**` — generated localization (Flutter intl).
- `**/*.g.dart` — codegen output.
- `**/*.freezed.dart` — codegen output.
- `test/**` — different bars per audit §5.2 #2 (test files cap at ≤ 2000
  lines, not the prod function bars); revisit in a future slice.

## Authority

`docs/_audits/code_health/code_hardening_plan_2026_05_21.md` §5.2
(engineering bars) + §7 backlog item #2 + §8 tooling-gap list.
