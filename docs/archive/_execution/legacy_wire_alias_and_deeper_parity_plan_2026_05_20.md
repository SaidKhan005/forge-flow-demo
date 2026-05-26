# Legacy Wire Alias and Deeper Parity Plan - 2026-05-20

## Supersession note

- The covers-source retirement pass has now moved past staged compatibility:
  old `covers_source_lunch`, `covers_source_dinner`, and
  `covers_source_late_night` write keys fail closed with HTTP 410.
- `lunch`, `dinner`, and `late_night` remain valid configured
  service-period keys. Only the old fixed write fields are retired.
- The broader `daypart` / `service_period_*` compatibility aliases stay
  outside this cleanup unless a future versioned API retirement approves them.

## Operator decisions

- Custom service periods stay supported. Examples: `breakfast`, `brunch`, `happy_hour`, and `supper_rush`.
- `lunch`, `dinner`, and `late_night` are not legacy by themselves. They are still valid configured service-period keys.
- The risky legacy pieces are old wire fields and aliases, not the period names.
- Superseded for covers-source writes: old fixed covers-source fields are now
  hard-rejected with HTTP 410 after the affected app paths were checked.
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
- If an old client still sends `covers_source_lunch`, the server now returns
  HTTP 410 and tells the client to use `covers_source_per_service_period`.
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
- Remaining items after the next sweep:
  - old alias retirement still needs a separate full-retirement pass before any compatibility route is removed,
  - shift-close authority is already automatic in code: vendor-reliable rows use vendor finalization, unknown/unreliable rows fall back to the operator's business-day start,
  - per-period walk-in split is now in scope for this follow-up,
  - hidden admin-only server actions should be classified before any UI is added. Role-catalog publish already has an admin surface; heap snapshot capture remains an internal support/pressure route unless an admin workflow needs it,
  - star-target fallback behavior remains as-is with the simple warning/reminder approach.

## Remaining audit action plan

- Correct stale docs that still describe shift close as an open admin-only decision. In the app, shift close should not be a user setting.
- Add walk-in support at service-period level without a schema migration:
  - keep the existing `walk_in_manual_entries` jsonb object,
  - keep old daily keys like `2026-05-06`,
  - add optional per-period keys like `2026-05-06|dinner`,
  - make the aggregator prefer the per-period value and split a legacy daily total across configured periods when no per-period value exists.
- Update Operator Web Data Accuracy so, when the operator chooses "Add walk-ins to reservations", they can enter counts for each configured service period instead of one whole-day number only.
- Keep mobile simple. Mobile can keep reading the same flat map; it does not need the full setup surface.
- Add focused tests for:
  - model parsing and per-period lookup,
  - aggregator use of a per-period walk-in count,
  - aggregator split of an old daily walk-in count,
  - Operator Web saving per-period walk-in counts,
  - gateway serialization of the new flat keys.

## Remaining audit execution results

- Shift close is not an app gap. It is already automatic:
  - reliable POS vendors use vendor finalization,
  - unknown or unreliable vendors fall back to the restaurant's business-day start,
  - no operator/admin UI setting is needed.
- Walk-ins are now per-period capable without a migration:
  - old daily keys like `2026-05-06` still work,
  - new keys like `2026-05-06|dinner` override the daily fallback for that period,
  - old daily totals are split across configured periods instead of being copied into every period.
- Operator Web Data Accuracy now lets an operator enter service-period walk-in counts when "Add walk-ins to reservations" is selected.
- Mobile remains simple and compatible because it still reads the same flat `walk_in_manual_entries` map.
- Hidden admin routes were classified:
  - role-catalog publish already has an Admin surface,
  - heap snapshot capture remains internal support/pressure tooling unless a real Admin workflow needs it.

## Continuation pass - non-low-priority scope

- Low-priority cleanup is intentionally skipped for now:
  - hidden/dead mobile wage editor cleanup,
  - polling tier per-period extensions unless a real workflow needs them,
  - heap snapshot UI.
- Service-period metadata and org-unit timing authoring are now closed in the
  current branch. Operator Web can edit day chips, short labels, sort order,
  and org-unit timing scope.
- Wage Authority scope parity is closed in the current branch. New rows can be
  saved at business, org-unit, or location scope, and inherited rows show where
  they came from.
- Benchmark override writes remain intentionally disabled on old server routes:
  old POST, PATCH, DELETE, and admin-undo calls return HTTP 410. The app path
  for changing active baselines is mobile Baseline Manager selected-star
  selection.
- Learn period-specific narration is in scope for this continuation pass:
  when the leak is in Friday Dinner, Learn should coach Friday Dinner using
  Friday Dinner's target row, not only the whole-day target.
- Timing source-label mismatches are also in scope for this continuation pass:
  Admin timezone source should be location-owned, Admin week-start needs a
  source row, Operator Web service periods need source labels, and the demo
  Shift-close setup row should stay removed because shift close is automatic.
- Wage Authority live-read/display parity is also in scope:
  inherited wage source fields must cross the proxy wire, and shadowed
  higher-scope rows should not duplicate the effective location row.
- Legacy alias retirement remains a staged future pass. Current code still
  accepts old fixed covers fields for compatibility, while new Admin and
  Operator Web writes use `covers_source_per_service_period`.

## Continuation pass results

- Learn now says the leaking service period directly. Example: Friday Dinner
  can coach to Friday Dinner's target numbers while contrasting Friday Lunch
  if Friday Lunch is holding on plan.
- Admin Timing now treats timezone as location-owned and labels week-start
  provenance.
- Operator Web Business Setup now shows service-period source labels.
- The demo timing fallback no longer shows Shift close authority.
- Wage Authority now carries scope/source fields through live reads.
- Wage Authority now shows the effective row only when a lower-scope wage
  overrides a higher-scope wage for the same role.
- Alias retirement is still documented as a future staged pass, not a silent
  compatibility break.
