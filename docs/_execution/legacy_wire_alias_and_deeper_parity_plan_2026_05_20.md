# Legacy Wire Alias and Deeper Parity Plan - 2026-05-20

## Operator decisions

- Custom service periods stay supported. Examples: `breakfast`, `brunch`, `happy_hour`, and `supper_rush`.
- `lunch`, `dinner`, and `late_night` are not legacy by themselves. They are still valid configured service-period keys.
- The risky legacy pieces are old wire fields and aliases, not the period names.
- Do not hard-reject old compatibility payloads yet. Check all affected code first, keep old clients working, and retire aliases in stages.
- Leave whole-day fallback behavior alone. A save-time warning is enough when the user leaves a configured period without selected star shifts.

## Why this exists

- The app moved from three fixed periods to restaurant-configured service periods.
- Some older payloads still mention fields like `covers_source_lunch`, `covers_source_dinner`, and `covers_source_late_night`.
- Some target and sync paths still accept aliases such as `daypart`, `service_period_id`, `service_period_key`, and `servicePeriodId`.
- Those aliases are useful for backward compatibility, but new client writes should prefer the keyed shape so custom periods keep working.

## Current app examples

- If a restaurant adds `breakfast`, the normal data-accuracy write should send:
  - `covers_source_per_service_period: { "breakfast": "manual" }`
- It should not need a new server column called `covers_source_breakfast`.
- If an old client still sends `covers_source_lunch`, the server may still translate that into the keyed map for now.
- If Benchmark has no selected star shift for `happy_hour`, the app should warn at save time, then keep the existing fallback if the operator confirms.

## Execution scope for this wave

- Persist this plan before code edits.
- Update contract wording so it matches the staged-retirement decision:
  - old fixed covers fields are not for new implementation work,
  - but server compatibility can stay live until a full retirement pass proves no client still needs it.
- Add focused tests that pin normal admin client writes to the keyed covers map, with no accidental old scalar fields.
- Keep server acceptance tests for old aliases intact so compatibility is not broken silently.
- Continue the deeper audit after this patch for:
  - mobile vs Operator Web parity,
  - admin vs operator UX parity,
  - read path vs write path mismatches,
  - inherited setting labels,
  - hidden server write routes that are not surfaced in UI.

## Out of scope for this wave

- No migration that deletes wire compatibility.
- No rejection of `lunch`, `dinner`, or `late_night`.
- No rejection of `daypart` or `service_period_*` aliases on server read/write paths.
- No extra persistent UI clutter.
- No fallback rewrite.

## Safety checks

- Keep `master` on `origin/master`.
- Work only in `codex/deeper-parity-audit-wave`.
- Leave unrelated Knowledge Graph docs untouched.
- Run focused Dart or Flutter tests for any files changed.
- If proxy code changes later, run the proxy pre-merge gate before merge.

## Deeper audit notes to carry forward

- `docs/contracts/data_accuracy_settings_contract.md` currently says the old hardcoded covers shape is rejected. That wording is too strong for the staged compatibility decision.
- Normal Operator Web data-accuracy writes already send the keyed map and tests already assert old scalar fields are absent.
- Admin write tests need the same normal-client guard so future changes do not accidentally make new admin writes depend on the old scalar fields.
- Existing server tests intentionally prove old scalar fields still translate into keyed rows. Keep those until the retirement pass is explicitly approved.

## Execution results

- Contract wording was corrected: new writes use `covers_source_per_service_period`; old `covers_source_lunch`, `covers_source_dinner`, and `covers_source_late_night` remain compatibility-only.
- Admin normal writes now have tests proving they send the keyed map for custom periods, not the old fixed trio.
- Operator Web manual covers now uses the narrow manual-cover write route. Example: changing Tuesday breakfast covers writes only Tuesday + breakfast + the new number, instead of resaving the whole settings object.
- Operator Web service-period covers edits no longer write the hidden per-period wage field. The covers dialog only changes covers.
- Operator Web now reads the effective polling tier from the server. Example: if Admin sets a location to Premium, Operator Web shows Premium instead of the default Standard card.
- Operator Web Data Accuracy now uses server Business Timing for both today's business date and the configured service-period list. Example: if Business Timing has Breakfast, the Data Accuracy service-period dialog offers Breakfast, not just the old demo periods.
- Admin Data Accuracy source labels now use the effective setting source. Example: if Breakfast inherits from Business, Admin shows Business instead of a stale location row.
- Admin Polling and Pricing now counts the selected hierarchy scope, not only the currently visible filtered rows.
- Admin tier rows now show useful defaults. Example: `Tier default: $29.00` instead of only `Tier default`.
- Service-period source metadata now travels through the proxy and sync client. Example: Operator Web and mobile sync can tell whether a covers setting came from Location, Business, or a service-period row.
- Star-shift sync now keys selected rows by stable business date + service-period key when the server provides them.
- Star-shift clear now also clears the old week/day/daypart record key when needed, so old selected rows do not stay selected after a stable-key clear.
- Star-target projection now prefers the canonical `service_period_key` when both it and an old display alias are present, while still rejecting invalid stable keys.
- The deeper audit caught and fixed two smaller UX/runtime risks:
  - stale polling-tier data after switching locations,
  - a possible `Source: null` label when the source is a default.

## Deeper audit result

- Graph signal used: `graphify-out/graph.json` was read only. Graphify was not rerun.
- Mobile Covers Setup is not treated as a gap per operator decision. Mobile stays simple; full setup lives in Operator Web.
- No new blocker remains in the data-accuracy, polling, or star-shift paths covered by this wave.
- Remaining items are product or future-scope decisions, not bugs introduced by this patch:
  - old alias retirement still needs a separate full-retirement pass before any compatibility route is removed,
  - shift-close authority is still admin-only unless the operator decides it belongs in Operator Web,
  - per-period walk-in split remains out of V1 scope,
  - hidden admin-only server actions like heap snapshot capture and role-catalog publish should stay unsurfaced unless an admin workflow needs them,
  - star-target fallback behavior remains as-is with the simple warning/reminder approach.
