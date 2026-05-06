# Known Failing Tests

Quarantine list for tests known to be red on `master` that are out of scope
for the current slice.

Read this before claiming a regression: a failure here is pre-existing and
does not block the current slice unless the slice explicitly names it.

Codex maintains this file. Add an entry when verification confirms a failure
is pre-existing on clean HEAD. Remove an entry once the failure is fixed.
Removed entries live in git history; do not keep a "resolved" section here.

## Open

| File | Notes | Discovered | Owning slice |
|------|-------|------------|--------------|
| `test/settings_permission_explainer_test.dart` | "location-scoped grant excluded at non-matching scope resolves to Not granted" — finder reports 0 widgets matching "No — grant excluded at this scope". Copy or scope-resolution drift in `SettingsPermissionExplainer`; pre-existing on master at the 2026-05-06 alignment-pass close. Single test in 14-case file; rest pass. | 2026-05-06 | follow-up — bounded test pin OR copy alignment in `lib/screens/settings/settings_permission_explainer.dart` |
| `test/admin/tier_definition_edit_audit_test.dart` | "Tab 2 tier definition edit round-trips with audit row standard tier description + price update writes admin.polling_tier_definition.update" — PASSES in isolation; fails only when run alongside other admin tests (cross-test interference / shared state). Discovered during 2026-05-06 deep-audit pass. | 2026-05-06 | follow-up — test isolation fix (likely shared mock state in `setUp` of sibling admin tests) |
