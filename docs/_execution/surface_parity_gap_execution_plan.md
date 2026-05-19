# Surface Parity Gap Execution Plan

Status: first execution slice implemented locally
Created: 2026-05-18
Updated: 2026-05-19
Owner: Codex orchestrator
Worktree: `.codex_worktrees/per-daypart-server-parity`
Branch: `codex/surface-parity-gap-plan`

## Plain English Summary

- The current cleanup slice is committed and pushed to `origin/master`.
- The main checkout stayed on `master`; the new work continues in a worktree.
- The deeper audit found real surface mismatches, not cosmetic issues.
- Data Accuracy is the biggest mismatch: the UI, proxy, mobile sync, and
  hierarchy rules are not all using the same keyed service-period model.
- Benchmark overrides have the opposite problem: operator-web UI was removed,
  but the old server write routes still exist.
- The fix must happen in small lanes so one surface does not silently break
  another.

## Gaps Found

### 1. Operator Web Data Accuracy uses a stale date

- `DataAccuracyScreen` defaults `businessDateIso` to `2026-05-05`.
- The operator-web router does not pass a live/current business date.
- Manual covers and keyed service-period overrides can therefore save against
  the wrong date.

Risk:

- Operators think they are editing the current date, but the write can land on
  a fixture date.

Fix plan:

- Resolve the current business date for the selected location before mounting
  Data Accuracy.
- Pass that date into `DataAccuracyScreen`.
- Add tests proving operator-web manual covers and keyed overrides no longer
  default to `2026-05-05`.

### 2. Operator Web sends keyed covers, but proxy still drops custom keys

- Operator Web sends `covers_source_per_service_period`.
- The proxy settings PATCH still reads only `covers_source_lunch`,
  `covers_source_dinner`, and `covers_source_late_night`.
- Breakfast, brunch, happy hour, or any fourth configured service period can be
  ignored on save.

Risk:

- The UI looks dynamic while the server still writes the old three-period
  shape.

Fix plan:

- Teach the proxy to parse `covers_source_per_service_period`.
- Upsert every supplied key into `data_accuracy_service_period_settings`.
- Keep legacy derived keys only as compatibility input, not as the only truth.
- Add proxy and operator-web gateway tests for a four-period payload.

### 3. Admin scoped Data Accuracy is still lunch/dinner/late-night only

- Admin scope edits pass only lunch, dinner, and late-night.
- The keyed admin service-period override writes only one concrete location.
- Business/org/location scoped keyed covers are not exposed holistically.

Risk:

- The hierarchy rule says settings can be set at business, org unit, or
  location, but custom service periods cannot be managed that way.

Fix plan:

- Add a scoped keyed map payload: `covers_source_per_service_period`.
- Let business/org/location scope writes include any configured service-period
  key.
- Update admin gateway, proxy route, screen dialog, and tests together.
- Keep old triplet inputs as compatibility only.

### 4. Mobile Covers Setup is local-only

- Mobile Settings exposes editable manual covers.
- The current write path stores local `ManualCoverEntry` rows.
- Canonical closed aggregation reads `DataAccuracySettings.manualCoversFor`,
  which comes from the sanctioned data-accuracy settings shape.

Risk:

- Mobile can show an edit that does not become canonical source truth.

Fix plan:

- Either route mobile manual covers through the proxy into canonical data
  accuracy settings, or make the mobile surface read-only with a handoff to
  Operator Web.
- Do not keep an editable local-only setting.
- Add tests for whichever product direction is implemented.

### 5. Effective settings lose inherited-source provenance

- The effective SQL view returns the resolved value map.
- It does not return per-key source provenance such as "set here" or
  "inherited from business".
- Admin and operator-web UI therefore show values but not the source of those
  values before mutation.

Risk:

- This misses the Hard Product Rule: selected scope, inherited source, and
  effective value must be visible before a setting change.

Fix plan:

- Add provenance beside the effective keyed map.
- Thread it through proxy DTOs.
- Render source labels before save.
- Test mixed business/org/location inheritance per service period.

### 6. Benchmark override server writes still exist after UI cut

- The Per-Daypart V1 plan says mobile Baseline Manager star selection is the
  only override path.
- Operator Web removed its benchmark override surface.
- The proxy still accepts `POST`, `PATCH`, `DELETE`, and admin-undo on
  `/v1/operator/benchmarks/overrides`.

Risk:

- A caller with the shared baseline override permission can mutate hidden scalar
  overrides outside the mobile source-of-truth UX.

Fix plan:

- Make legacy benchmark override writes fail closed by default.
- Leave read-only status only if it is still needed for cleanup.
- Keep the mobile selected-star route working.
- Replace green-path legacy write tests with rejection tests.

## Execution Order

### Lane A - Proxy keyed Data Accuracy writes

- Owns:
  - `tool/advisor_proxy/proxy_bootstrap.dart`
  - `tool/advisor_proxy/advisor_proxy.dart`
  - `test/proxy/data_accuracy_admin_routes_test.dart`
  - `test/per_daypart_v1_r7b_proxy_covers_keyed_test.dart`
- Tasks:
  - Parse `covers_source_per_service_period` on operator and admin settings
    writes.
  - Upsert all supplied keyed covers.
  - Keep compatibility with old triplet inputs.
  - Add four-period tests.

### Lane B - Admin keyed scoped UX and gateway

- Owns:
  - `lib/admin/services/data_accuracy_admin_gateway.dart`
  - `lib/admin/screens/per_location_data_accuracy_screen.dart`
  - admin widget tests for data accuracy scope editing
- Tasks:
  - Replace hard-coded scope dialog covers fields with configured/keyed rows.
  - Send `covers_source_per_service_period` for scoped mutations.
  - Keep the location-specific keyed service-period editor intact.
  - Add tests for business/org/location scoped custom period writes.

### Lane C - Benchmark legacy write shutdown

- Owns:
  - `tool/advisor_proxy/operator_benchmark_overrides_routes.dart`
  - `tool/advisor_proxy/main.dart`
  - `test/proxy/operator_benchmark_overrides_routes_test.dart`
- Tasks:
  - Block legacy benchmark write verbs by default.
  - Preserve any read-only route that is still needed for status/cleanup.
  - Update comments and tests so future work cannot accidentally re-enable the
    removed operator-web surface.

### Lane D - Operator Web date and provenance follow-up

- Owns:
  - `lib/operator_web/router/operator_web_router.dart`
  - `lib/operator_web/screens/data_accuracy_screen.dart`
  - `lib/operator_web/widgets/keyed_service_period_accuracy_card.dart`
  - operator-web data accuracy tests
- Tasks:
  - Remove stale fixture date default from live writes.
  - Prefer configured service periods over free-text keys where possible.
  - Add inherited/effective labels once the proxy exposes provenance.

### Lane E - Mobile canonical covers decision

- Owns:
  - `lib/screens/settings/settings_covers_setup_section.dart`
  - sync/proxy client mobile tests
- Tasks:
  - Choose one product-safe path: canonical proxy write or read-only handoff.
  - Do not leave local-only editable settings.
  - Add a test proving the mobile behavior matches canonical truth.

## First Execution Slice

- Lanes A, B, and C were implemented in parallel workers.
- Lane D's stale-date part was implemented locally by the orchestrator because
  it did not overlap worker-owned files.
- No migrations were touched.
- Lane D provenance rendering still waits on a response-shape/provenance
  follow-up.
- Lane E remains planned but not implemented in this slice because it is a
  product decision with mobile UX implications.

## Execution Results

- Lane A: proxy operator/admin Data Accuracy writes now accept
  `covers_source_per_service_period`; legacy lunch/dinner/late-night inputs
  remain compatibility input, and explicit keyed values win.
- Lane B: admin scoped Data Accuracy edits now send keyed covers maps for
  business/org/location scope mutations, including custom periods such as
  breakfast.
- Lane C: legacy benchmark override `POST`, `PATCH`, `DELETE`, and
  admin-undo now return HTTP 410 `legacy_benchmark_override_writes_disabled`;
  read-only list/status paths remain.
- Lane D partial: operator-web Data Accuracy now derives its default business
  date from the session timezone and rollover hour instead of the stale
  `2026-05-05` fixture date.
- A flaky router test was stabilized by replacing an infinite
  `pumpAndSettle` wait around the hierarchy picker with fixed pumps.

## Remaining Gaps

- Provenance gap remains: effective Data Accuracy values still need per-key
  "set here" / "inherited from ..." source labels from proxy to UI.
- Mobile covers gap remains: mobile manual covers are still local-only until a
  product decision chooses canonical proxy write or read-only Operator Web
  handoff.
- Operator Web service-period UX still allows free-text keys in the keyed
  override dialog; it should prefer configured service periods once provenance
  and response shape are complete.

## Verification Gates

- `dart analyze --fatal-infos` on all touched Dart files
- `flutter test test/proxy/data_accuracy_admin_routes_test.dart`
- `flutter test test/per_daypart_v1_r7b_proxy_covers_keyed_test.dart`
- `flutter test test/admin/data_accuracy_polling_hierarchy_scope_screen_test.dart`
- `flutter test test/proxy/operator_benchmark_overrides_routes_test.dart`
- Targeted operator-web Data Accuracy tests after Lane D changes
- `dart run tool/postgres_import_lint.dart`
- `dart run tool/permission_key_lint.dart`
- `dart run tool/ux_em_dash_lint.dart`
- `dart run tool/advisor_proxy_size_lint.dart`

## Guardrails

- Main checkout remains on `master`.
- All code edits happen in the worktree branch.
- Workers own disjoint file sets.
- Workers must not revert edits made by other workers.
- No live Firebase, provider, Postgres, staging, or cloud mutation.
- No migration edits in the first slice unless implementation proves schema is
  truly missing.
