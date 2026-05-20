# Post-1023 Deeper Audit Fix Plan

Date: 2026-05-19
Branch: codex/post-1023-deeper-audit-fix
Base: origin/master after PR #1023 landed

## Plain English Findings

- Timing on mobile shows the final values, but not the source of those values.
- The mobile scope contract still has an old carve-out saying mobile does not need inherited-source labels. The product direction is now full coverage, so that carve-out is stale.
- The server already knows the Timing candidate chain. The mobile resolved Timing route drops that source information before the phone can cache it.
- Mobile SQLite and the `RestaurantTimingConfig` model cannot store Timing source labels yet.
- The mobile Timing settings card only says which location the settings apply to. It does not say whether the values are inherited from business, org unit, or set at location.
- Closed-shift Covers aggregation can still read raw service-period rows instead of the effective inherited Covers answer.
- Admin and mobile Covers screens can pair a raw value with an effective source label. That can make the label honest but the value stale.
- Some Covers UX copy and fallbacks still assume the old lunch, dinner, late night trio.
- Legacy Covers write keys remain for old clients. They are compatibility input now, not new implementation surface. Removal should be a separate deprecation step.

## Fix Plan

1. Timing provenance contract
   - Update the mobile scope contract so mobile still stays single-location, but settings surfaces that show inherited settings must show source labels.
   - Keep mobile free of hierarchy rollup dashboards. This is only about honest source labels for the selected location.

2. Timing provenance data path
   - Add optional source fields to `RestaurantTimingConfig`.
   - Add SQLite columns and a schema migration for selected scope, source scope, source label, and inherited flag.
   - Make the proxy resolved Timing route emit those fields from the same resolver result used for the effective values.
   - Make the HTTP sync client parse those fields and persist them locally.

3. Timing provenance UI
   - Show a small source line in mobile Settings Timing.
   - Use plain labels: `Source: Location override` or `Inherited from: Business default`.

4. Covers effective-value path
   - Route closed-shift Covers source resolution through the same effective hierarchy answer used by admin/proxy reads.
   - Keep date-aware behavior for historical closed shifts.
   - Keep raw keyed rows as compatibility/history data only.

5. Covers UI/source pairing
   - Where source metadata is shown, pair it with the matching effective keyed Covers value.
   - Use raw keyed rows only when they are explicitly the effective row for that period/date.

6. Covers copy and fallback labels
   - Replace hardcoded lunch/dinner/late-night examples with configured service-period labels when available.
   - If labels are unavailable, use generic examples instead of pretending the old trio is universal.

7. Verification
   - Run focused Timing sync/repository/UI tests.
   - Run focused Data Accuracy/Covers tests.
   - Run analyzer on changed Dart files.
   - Run migration drift and cutoff lints after schema changes.
   - Run UX copy lint and diff whitespace check.

## Parallel Work Split

- Orchestrator lane: Timing provenance, because it crosses server, schema, mobile model, cache, and UI.
- Worker lane A: Covers effective-value resolution in closed-shift aggregation.
- Worker lane B: Covers UI copy and fallback label cleanup.

Workers must use disjoint files, must not update trackers, and must not merge. The orchestrator audits and integrates their patches before the final PR.

## Deferred Follow-Up

- Remove legacy Covers write keys after old clients are formally sunset.
- Re-run the deeper audit after these fixes land to look for remaining bugs and architecture gaps.
