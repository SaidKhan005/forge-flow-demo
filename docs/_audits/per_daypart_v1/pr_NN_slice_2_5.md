# Per-Daypart Targets V1 — Slice 2.5 audit

> PR number: TBD (rename file to `pr_<n>_slice_2_5.md` after `gh pr create`).

## Slice intent (from `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`)

Close Gap 28: operator-web's service period editor only writes 4 fields per period
(key, label, startLocal, endLocal). The canonical `ServicePeriodDefinition` carries
3 more — `applicableDays`, `shortLabel`, `sortOrder` — and the mobile app
displays them. Operators cannot express day-restricted periods (e.g.
"Weekend Brunch" Sat/Sun only). This slice closes the gap on the
operator-web write path.

## Scope (files modified)

- `lib/operator_web/widgets/service_period_editor.dart` — three new
  fields on `ServicePeriodDraft`, a 7-chip day-toggle row in
  `_ServicePeriodRow`, short-label / sort-order text fields, and an
  `invalid_applicable_days` error in `validateServicePeriods`.
- `lib/operator_web/services/web_business_timing_gateway.dart` — three
  new fields on `ServicePeriod`, `ServicePeriodCreate`, and
  `ServicePeriodPatch`. `ServicePeriod.fromJson` defaults the three
  fields when older payloads omit them so the gateway never throws
  `malformed_service_period` against pre-2.5 servers.
- `lib/operator_web/screens/business_timing_editor_screen.dart` — seed +
  save paths carry the three fields through end-to-end.
- `test/operator_web/widgets/service_period_editor_test.dart` — extended.
- `test/operator_web/screens/business_timing_editor_screen_test.dart` — extended.
- `test/operator_web/services/web_business_timing_gateway_test.dart` — extended.

## Pattern B audit table

| # | Lens | Status | Evidence (file:line) |
|---|------|--------|----------------------|
| 1 | Scope match | PASS | Only the six files listed in `Scope` were touched (worker self-audit + executor independent audit confirmed via `git diff --name-only origin/master...HEAD`). No mobile, schema, proxy, services, or domain files modified. |
| 2 | Authority order | PASS | Plan doc + CLAUDE.md respected. No conflict with `docs/contracts/core_app_architecture.md` (operator-web client only). Slice intent matches plan row 2.5 + Gap 28. |
| 3 | Hard Promises | PASS | HP #11 (hierarchy-scoped settings): the editor already drives operator/location scope through `_scopeKind` + `_scopeId` (`business_timing_editor_screen.dart:166-176`); this slice only adds new fields inside the scope already in force. No new scope surface introduced. HP #2 / #6 untouched. |
| 4 | Service-layer split | PASS | UI in `lib/operator_web/widgets/`, screen in `lib/operator_web/screens/`, gateway DTOs in `lib/operator_web/services/`. Nothing crosses into `lib/services/`, `lib/domain/`, or `lib/data/`. |
| 5 | Design Rule 1 (field naming) | PASS | New fields scoped to `ServicePeriodDraft` (`service_period_editor.dart:55,60,64`), `ServicePeriodCreate` (`web_business_timing_gateway.dart:289-291`), `ServicePeriodPatch` (`web_business_timing_gateway.dart:316-318`), `ServicePeriod` (`web_business_timing_gateway.dart:217-219`). Names mirror canonical `ServicePeriodDefinition` (`lib/domain/models/service_period_definition.dart:18-34`). No whole-day collisions. |
| 6 | Design Rule 2 (null vs zero) | PASS | `sortOrder` default is `0` (canonical model treats 0 as a legitimate first slot, see `service_period_definition.dart:21`). `shortLabel` default is `''` (empty string is a legitimate value — mobile app falls back to long label). `applicableDays` empty list is INVALID and rejected by validator (`service_period_editor.dart:198-216`). |
| 7 | Demo-mode contract | PASS | No `kDemoMode` branch added or removed. Same UI in demo and prod; same JSON shape end-to-end. |
| 8 | RLS-ready schema | N/A | No schema change in this slice. The proxy backend may need to extend its route validation for the three new fields; flagged as follow-up below. |
| 9 | Time guardrails | N/A | No timestamp handling changed. `applicableDays` is a list of ISO weekday integers, not timestamps. |
| 10 | Test coverage | PASS | New tests: `service_period_editor_test.dart` adds (a) `empty applicableDays rejected with invalid_applicable_days` (line ~261), (b) `out-of-range applicableDays rejected` (~278), (c) `weekend-only Sat/Sun applicableDays accepted` (~295), (d) `default constructor seeds all 7 weekdays + empty short label + 0 sort` (~311), (e) `copyWith round-trips the three new fields without mutating others` (~324), (f) `copyWith leaving new fields null preserves the originals` (~344), (g) `addPeriod defaults applicableDays to all 7 weekdays` (~363), (h) `addPeriod defaults sortOrder to current period count` (~376), (i) `updateAt with copyWith propagates day-chip toggles` (~389), (j) `renders 7 day chips per period` (widget test ~409), (k) `tapping a day chip toggles applicableDays` (~432), (l) `renders the short label and sort order text fields` (~455). `business_timing_editor_screen_test.dart` adds (m) `seeds editor from existing profile carrying day-restricted period`, (n) `save sends applicableDays / shortLabel / sortOrder on the wire`, (o) `tapping day chips before save emits filtered applicableDays`. `web_business_timing_gateway_test.dart` adds (p) `ServicePeriodCreate.toJson emits applicableDays, shortLabel, sortOrder`, (q) defaults variant, (r) `ServicePeriodPatch.toJson emits only present fields`, (s) `ServicePeriod.fromJson defaults the three new fields when server omits them`, (t) `ServicePeriod.fromJson reads the three fields when present`, (u) `createProfile emits applicableDays / shortLabel / sortOrder on the wire`. |
| 11 | Validation parity | PARTIAL | Client-side `invalid_applicable_days` rejects empty list and out-of-range entries (`service_period_editor.dart:198-216`). The proxy backend's route validation may NOT yet validate `applicableDays` / `shortLabel` / `sortOrder`. Flagged as follow-up: backend slice should add the same checks server-side (sibling slice, not Slice 2.5 scope). |
| 12 | Backwards compatibility | PASS | `ServicePeriod.fromJson` defaults `applicableDays` -> `[1..7]`, `shortLabel` -> `''`, `sortOrder` -> `0` when the server omits them (`web_business_timing_gateway.dart:248-280`). Old payloads do NOT throw `malformed_service_period`. Verified by test (s) above. Also verified `_readApplicableDays` accepts both `int` and `num` list entries for resiliency against JSON number coercion. |
| 13 | No tracker edits | PASS | `git status` shows no modifications to `PROJECT_TRACKER.md`, `docs/_indices/NEXT_WAVE_PLAN.md`, `docs/phases/per_daypart_targets_v1/per_daypart_targets_v1_plan.md`, or any `_indices/*_LEDGER.md`. Only this audit doc + the six implementation files. |
| 14 | No merge / no `--no-verify` | PENDING | Branch will be pushed via `git push` (no `--no-verify`); PR opened via `gh pr create`; agent then STOPS. No merge. |

## Follow-ups (out of scope, not fixed in this slice)

1. **Proxy backend validation parity** — the proxy route handlers
   should be extended to validate `applicableDays` (non-empty, all 1-7),
   `shortLabel` (string), and `sortOrder` (int) on POST/PATCH. Today
   the operator-web client validates locally but the server may accept
   anything. Belongs in a sibling backend slice.
2. **Read seam parity** — `lib/operator_web/services/business_timing_gateway.dart`
   (the READ seam, distinct from `web_business_timing_gateway.dart`) currently
   surfaces `BusinessTimingServicePeriod` without the three new fields.
   The display surface (BusinessSetupScreen) does not yet show
   day-restricted periods or short labels in its read view. Belongs in
   a future read-side slice (NOT Slice 2.5).
3. **Mobile read-side parity** — `lib/screens/settings/settings_timing_authority_section.dart`
   already reads from canonical `ServicePeriodDefinition` and so will
   automatically pick up the new fields once they round-trip. No change
   needed in this slice.

## Verification

- `dart analyze lib/operator_web/widgets/service_period_editor.dart lib/operator_web/screens/business_timing_editor_screen.dart lib/operator_web/services/web_business_timing_gateway.dart test/operator_web/widgets/service_period_editor_test.dart test/operator_web/screens/business_timing_editor_screen_test.dart test/operator_web/services/web_business_timing_gateway_test.dart` -> `No issues found!`
- `flutter test test/operator_web/widgets/service_period_editor_test.dart test/operator_web/screens/business_timing_editor_screen_test.dart test/operator_web/services/web_business_timing_gateway_test.dart` -> `+49: All tests passed!`
