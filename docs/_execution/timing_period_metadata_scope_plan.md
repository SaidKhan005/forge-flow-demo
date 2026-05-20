# Timing Period Metadata Scope Plan

Status: complete
Branch: `codex/timing-period-metadata-scope`
Worktree: `.codex_worktrees/timing-period-metadata-scope`
Base: `origin/master` at `495ed8cc`
Date: 2026-05-19

## Findings

- Operator Web already sends service-period metadata on the save wire:
  `applicableDays`, `shortLabel`, and `sortOrder` are part of the editor and
  web gateway create payloads.
- The shared validator model did not carry those fields, so repository-backed
  writes could only see key, label, times, and rollover state.
- The repository operator write gateway rebuilt period writes with all seven
  weekdays, a label-derived short label, and list-index sort order. That meant
  custom service periods could save back as every-day, label-derived,
  index-order rows.
- Partial route paths rebuild a `ValidatedBusinessTimingProfile` from existing
  records before validating a merge. Those adapters also needed to carry the
  existing metadata so a top-level patch or one-period patch does not strip the
  untouched rows.
- Org-unit authoring was originally not cleanly reachable from the live
  Business setup route. A later parity fix closed that route gap by mounting
  the timing editor on the selected org-unit management scope and preserving
  `org_unit` writes through the editor tests.

## Scope

- In scope:
  - `lib/services/business_timing/business_timing_profile_validator.dart`
  - `lib/services/business_timing/repository_operator_write_gateways.dart`
  - `tool/advisor_proxy/operator_routes.dart`
  - `tool/advisor_proxy/admin_business_timing_routes.dart`
  - `lib/operator_web/screens/business_timing_editor_screen.dart`
  - `lib/operator_web/services/web_business_timing_gateway.dart`
  - `lib/operator_web/widgets/service_period_editor.dart`
  - Focused timing, proxy, repository, and operator-web tests.
- Out of scope:
  - Tracker updates.
  - Migrations.
  - A new org-unit Business setup product route. That needs route ownership for
    selecting an org unit, loading the relevant hierarchy target, and passing an
    org-unit `scopeId` into the editor. Faking that with the current location
    route would hide the blocker.

## Lens Check

| Lens | Code or doc checked | Finding | Required action |
|---|---|---|---|
| Feature lens | `docs/contracts/core_app_architecture.md`; `docs/phases/phase_business_timing_live/business_timing_live_plan.md`; deep audit gap | Timing service periods are scoped timing settings and must round-trip metadata across web, validator, repository, and route adapters. | Preserve metadata in validator models and write adapters. |
| Validator | `lib/services/business_timing/business_timing_profile_validator.dart:109`; `lib/services/business_timing/business_timing_profile_validator.dart:713` | Validated periods previously had no metadata fields. | Add applicable-day, short-label, and sort-order parsing, validation, and merge preservation. |
| Repository write | `lib/services/business_timing/repository_operator_write_gateways.dart:347` | The adapter used fabricated metadata when creating SQL writes. | Write `period.shortLabel`, `period.sortOrder`, and `period.applicableDays` directly. |
| Partial route adapters | `tool/advisor_proxy/operator_routes.dart:1250`; `tool/advisor_proxy/admin_business_timing_routes.dart:431` | Existing profile reconstruction needed to keep untouched row metadata. | Include the three metadata fields when rebuilding validated profiles. |
| Authoring scope | `lib/operator_web/router/operator_web_router.dart:1201`; `lib/operator_web/screens/business_timing_editor_screen.dart:179`; `lib/operator_web/screens/business_timing_editor_screen.dart:610` | Business setup currently mounts only for location scope and editor scope choices are operator or location. | Document blocker instead of adding a misleading org-unit control. |

## Implementation

- Extended `ValidatedServicePeriod` with `applicableDays`, `shortLabel`, and
  `sortOrder`.
- Validated applicable days as unique ISO weekdays 1..7, short labels as trimmed
  strings of at most 8 characters, and sort order as 1..4 with legacy `0`
  normalized to the current list slot when old client data is revalidated.
- Made overlap validation weekday-aware to match the Postgres trigger behavior:
  periods may share the same clock window only when their applicable weekdays do
  not intersect.
- Preserved metadata through full-profile validation, top-level profile PATCH,
  service-period add, and service-period PATCH merge flows.
- Updated the repository write gateway to persist the validated metadata instead
  of deriving all-week or list-order values.
- Updated route fakes and tests so they preserve metadata instead of masking the
  same problem as the production path.
- Org-unit authoring route gap is now closed by the later Business setup
  parity pass. The editor can mount on a real org-unit target and write
  `org_unit` scope without borrowing a location route.

## Verification

- `flutter test test\services\business_timing\business_timing_profile_validator_test.dart test\proxy\operator_business_timing_routes_test.dart test\phase_business_timing_live_postgres_test.dart test\operator_web\screens\business_timing_editor_screen_test.dart test\operator_web\services\web_business_timing_gateway_test.dart test\operator_web\widgets\service_period_editor_test.dart` passed.
- `dart analyze lib\services\business_timing\business_timing_profile_validator.dart lib\services\business_timing\repository_operator_write_gateways.dart lib\operator_web\screens\business_timing_editor_screen.dart lib\operator_web\services\web_business_timing_gateway.dart lib\operator_web\widgets\service_period_editor.dart tool\advisor_proxy\operator_routes.dart tool\advisor_proxy\admin_business_timing_routes.dart test\services\business_timing\business_timing_profile_validator_test.dart test\proxy\operator_business_timing_routes_test.dart test\phase_business_timing_live_postgres_test.dart test\operator_web\screens\business_timing_editor_screen_test.dart test\operator_web\services\web_business_timing_gateway_test.dart test\operator_web\widgets\service_period_editor_test.dart` passed.
- `dart run tool\ux_em_dash_lint.dart` passed.

## Residual Risks

- Existing persisted or fixture data that omits sort order can still revalidate
  through the legacy `0` fallback, but new writes persist the explicit 1..4
  value required by the timing table.
- Org-unit timing authoring is no longer an open product-route gap in the
  current branch. Router and screen tests now cover opening the editor at
  org-unit management scope and writing `org_unit` scope with the selected
  group id.
