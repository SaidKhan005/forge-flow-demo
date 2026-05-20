# Next Deeper Gap Audit Execution Plan

Status: closed/superseded after PR #1020-era cleanup. Preserve this file as
historical execution context; do not dispatch new lanes from it.
Branch: `codex/next-deeper-gap-audit`
Started: 2026-05-19
Base: `origin/master` after PR #1019 landed and was verified.

## Plain English Summary

- The last PR fixed Admin role fixtures, Mobile Covers copy, and live role-contract wording.
- The next audit found deeper gaps that were active at dispatch time; the
  execution status below records the follow-up cleanup that closed them.
- Some old role names still appear in live launch scripts, checklists, comments, and success-path tests.
- Covers source behavior is not fully enforcing the operator's selected source.
- Admin Data Accuracy does not fully use configured service periods.
- Operator Web custom role creation hides business-wide permissions.
- Learn has per-daypart target data, but the analyzer still teaches from whole-day targets only.

## Confirmed Gaps

1. Role drift:
   - Launch account role tooling still grants retired v1 roles.
   - Operator Web comments/copy still mentioned phantom `operator_admin`.
   - Integration verification checklists still required `operator_admin` as the successful actor.
   - A few success-path tests still seed retired or phantom roles as normal current actors.

2. Covers source behavior:
   - `manual` can fall through to vendor/forecast when no manual value exists.
   - `forecast` is not handled as an explicit chosen source before vendor aggregation.
   - `reservation_plus_walkin` is saveable in one path but collapses to `vendor` in another.
   - Operator Web service-period saves reload keyed rows but can leave the main source cards stale.
   - Mobile manual Covers does not show the current effective Covers source/source label beside the form.

3. Admin and Operator Web parity:
   - Admin Data Accuracy bulk edit builds fields from existing rows, not from configured service periods.
   - Admin row edit falls back to raw service-period key typing.
   - Operator Web custom-role creation defaults to location scope and hides business-wide permission keys.

4. Learn:
   - Per-daypart benchmark context exists, but the service does not pass it through.
   - The teaching analyzer still narrates only whole-day targets.

## Scope Rules

- Do not rewrite historical migrations.
- Do not rewrite archive material.
- Do not change paused Barrio product behavior unless a live auth path is affected.
- Keep comments and docs aligned where they describe active behavior.
- Behavior changes must get focused tests before commit.
- Proxy-touching or auth-touching work must pass the repo pre-merge gate before merge.

## Parallel Execution Roles

- Orchestrator:
  - Owns this plan, baseline control, final integration, verification, commit, push, PR, merge, and landed-content verification.
  - Reviews every worker output before staging.

- Worker A, Role Drift:
  - Owns active role-name cleanup across launch tooling, runbooks, live checklists, Operator Web copy/comments, demo-mode audit payload, and success-path tests.
  - Must not edit historical migrations or archive docs.

- Worker B, Covers Behavior:
  - Owns closed-shift Covers source enforcement, four-source model alignment, and Operator Web service-period refresh.
  - Must add or update focused tests around manual missing-value behavior, forecast source behavior, and `reservation_plus_walkin` preservation.

- Worker C, Admin/Role Builder Parity:
  - Owns Admin Data Accuracy configured-service-period UX and Operator Web custom-role business-scope permission picker behavior.
  - Must add or update focused widget tests for both seams.

- Worker D, Learn Per-Daypart:
  - Owns wiring existing per-daypart benchmark context into the Learn context service and analyzer.
  - Must keep whole-day fallback behavior intact when per-daypart rows are absent.

## Verification Plan

- Run focused tests each worker names.
- Run `dart format` on changed Dart files.
- Run `dart analyze --fatal-infos` on changed Dart files.
- Run `dart run tool/ux_em_dash_lint.dart`.
- Run `git diff --check`.
- Run affected proxy/auth/widget tests.
- Open a PR.
- Run `tool/pre_merge_gate.sh <PR>` before merge because this batch touches `lib/**`, auth-adjacent logic, and proxy-adjacent code.
- After merge, run `tool/verify_pr_landed.sh <PR> ...` with real content symbols.

## Execution Status

- Role drift cleanup is implemented across launch tooling, active role copy,
  live integration checklists, active docs, and success-path tests.
- Covers source behavior is implemented for explicit manual, forecast, and
  reservation-plus-walk-in choices.
- Operator Web service-period saves now refresh the primary Covers state.
- Mobile Covers Setup now shows the selected period's effective Covers source
  from the synced service-period settings cache.
- Admin Data Accuracy now uses configured service periods for scope edit and
  row edit.
- Operator Web custom roles now default to business scope so business-wide
  permission keys stay visible.
- Learn now passes per-daypart targets into coaching copy, with whole-day
  fallback preserved.
- Worker C could not be spawned because the thread limit was reached, so the
  orchestrator completed that lane directly.

## Deferred Or Watch-Only

- Mobile Settings lacking broad team/settings write controls is intentionally read-only by contract.
- Operator Web Benchmarks override absence is intentionally deferred for V1.
- Historical migration references to retired roles are preserved as history.
