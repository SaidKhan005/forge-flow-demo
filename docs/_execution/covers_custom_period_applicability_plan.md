# Covers Custom Period Applicability Plan

Status: complete
Branch: `codex/covers-custom-period-applicability`
Worktree: `.codex_worktrees/covers-custom-period-applicability`
Base: `origin/master` at `7cbe865b`
Date: 2026-05-19

## Findings

- Covers vendor applicability metadata already exposes `service_periods`, but
  the validator still allowed only `breakfast`, `lunch`, `dinner`, and
  `late_night`.
- Current timing and Data Accuracy contracts make service periods
  restaurant-owned settings. Applicability metadata should validate safe stable
  service-period keys, not reject keys such as `brunch` or `happy_hour` just
  because they are operator-defined.
- Existing persistence already validates metadata before opening a Postgres
  transaction, so the fix belongs in the shared metadata schema and its direct
  callers.

## Scope

- In scope:
  - `lib/services/settings/applicability_metadata_schemas.dart`
  - `test/services/settings/applicability_metadata_schemas_test.dart`
  - `test/infrastructure/persistence/postgres/repositories/vendor_applicability_repository_test.dart`
  - `test/admin/vendor_applicability_admin_screen_test.dart`
- Out of scope:
  - Timing editor files.
  - Wage files.
  - Database migrations.
  - Tracker updates.

## Lens Check

| Lens | Code or doc checked | Finding | Required action |
|---|---|---|---|
| Authority | `docs/contracts/core_app_architecture.md`; `docs/contracts/data_accuracy_settings_contract.md`; `docs/contracts/phase_7_55_time_boundary_contract.md` | Service periods are stable restaurant-owned keys, not a fixed product enum. | Validate key shape only. |
| Repository and service layer | `lib/services/settings/applicability_metadata_schemas.dart:190`; `lib/infrastructure/persistence/postgres/repositories/vendor_applicability_repository.dart` | Repository already calls metadata validation before writes. | Change the schema rule and prove pre-transaction rejection remains. |
| Admin surface | `lib/admin/screens/vendor_applicability_admin_screen.dart` | Admin dialog uses the same schema assertion before sending writes. | Add a widget test for custom covers periods. |
| Tests and evidence | Focused schema, repository, admin widget tests | Built-ins, custom keys, and invalid keys need direct proof. | Add focused tests and run analyzer plus scoped lint. |

## Implementation

- Replaced the fixed covers `service_periods` allow-list with validation for a
  unique non-empty list of service-period keys matching
  `^[a-z][a-z0-9_]{0,63}$`.
- Kept the rule conservative: blanks, whitespace, uppercase, hyphenated,
  path-like, duplicate, non-string, and over-length keys fail.
- Added tests proving:
  - Built-in period keys still pass.
  - Custom keys such as `brunch`, `happy_hour`, and `supper_rush` pass.
  - Invalid keys fail before repository transactions open.
  - The admin covers add dialog accepts custom service-period metadata.

## Verification

- `flutter test test\services\settings\applicability_metadata_schemas_test.dart test\infrastructure\persistence\postgres\repositories\vendor_applicability_repository_test.dart test\admin\vendor_applicability_admin_screen_test.dart` passed.
- `dart analyze lib\services\settings\applicability_metadata_schemas.dart test\services\settings\applicability_metadata_schemas_test.dart test\infrastructure\persistence\postgres\repositories\vendor_applicability_repository_test.dart test\admin\vendor_applicability_admin_screen_test.dart` passed.
- `dart run tool\ux_em_dash_lint.dart` passed.

## Residual Risks

- This validator confirms key safety, not whether a key is active on a
  particular operator's current timing profile. That is intentional for global
  vendor applicability metadata because the repository does not receive an
  operator timing profile during validation.
