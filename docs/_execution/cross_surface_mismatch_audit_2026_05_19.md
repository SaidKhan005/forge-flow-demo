# Cross-Surface Mismatch Audit - 2026-05-19

## Scope

- Used the existing `graphify-out/graph.json` read-only. It was not regenerated.
- Scanned the active code and docs for the same class of mismatch across:
  - mobile vs Operator Web parity
  - admin vs operator UX parity
  - read path vs write path mismatches
  - inherited/default setting labels
  - hidden server routes not surfaced in UI

## Fixed In This Pass

- Default Data Accuracy provenance stays quiet in operator-facing UI.
  - The raw server metadata still exists for audit/debug.
  - Operator Web, Admin, and mobile Covers Setup no longer render `Source: Default`.
  - Non-default sources such as `Business`, `Org unit`, and `Location setting` still render.

## Actionable Gaps Found

### 1. Mobile Covers Setup is not full coverage yet

- Current app behavior:
  - Mobile can save and clear manual cover counts.
  - Mobile reads the service-period covers source.
  - Mobile cannot change the service-period covers source, so it cannot fully match Operator Web.
- Example:
  - Operator Web can say Breakfast uses vendor covers and Dinner uses manual covers.
  - Mobile can show that, but cannot change Dinner from vendor to manual.
- Fix plan:
  - Add a mobile source selector for each service period.
  - Write through the same proxy path Operator Web uses.
  - Keep manual cover count entry coupled to manual covers only.
  - Add tests for save, clear/reset, and read-after-sync.

### 2. Per-service-period wage source is editable but not used by projection

- Current app behavior:
  - Operator Web lets a manager save a wage source per service period.
  - The closed-shift projection still reads the older whole-location wage source.
  - The migration says per-period wage source was reserved for a future slice.
- Example:
  - Manager sets Dinner wages to manual mix.
  - Projection can still calculate Dinner using the location-level wage source.
- Fix plan:
  - Product-safe option: hide the per-period wage source control until projection uses it.
  - Full option: wire per-period wage source through effective settings, projection, mobile mirror, and tests.
  - Do not leave a visible write that does not change the calculation.

### 3. Service-period Data Accuracy overrides cannot be reset

- Current app behavior:
  - Operator Web can add or edit a service-period override.
  - There is no reset/delete path to fall back to inherited/default behavior.
- Example:
  - Manager sets Lunch covers to manual.
  - Later they cannot clear that override back to the inherited rule from the business/org/location hierarchy.
- Fix plan:
  - Add a clear/reset route for service-period rows.
  - Add a gateway method and reset button.
  - Return the effective inherited value after reset.
  - Test reset, idempotency, and inherited readback.

### 4. Scoped Data Accuracy overrides cannot be cleared cleanly

- Current app behavior:
  - Admin can set business/org-unit Data Accuracy overrides.
  - The effective SQL can fall through when fields are null.
  - The write route preserves old values and does not expose a clear command.
- Example:
  - Support sets org-unit wage source to manual mix.
  - There is no clean way to remove that org-unit value so locations inherit the business value again.
- Fix plan:
  - Add explicit clear fields or a scoped delete/reset route.
  - Audit the clear action.
  - Test that effective settings fall back to the next parent scope.

### 5. Business Timing reset is visible but disconnected

- Current app behavior:
  - Operator Web shows `Reset timing` when a location override exists.
  - Pressing it opens a dialog saying the route is not connected.
- Example:
  - Manager can see a reset action but cannot actually reset the location timing override.
- Fix plan:
  - Either wire the live reset route or hide the reset action until the route is live.
  - Preferred full fix: add audited reset, update Operator Web, and verify inherited timing after reset.

### 6. Business Timing timezone is in the profile payload but not actually owned there

- Current app behavior:
  - Business Timing profile create/patch includes `ianaTimezone`.
  - The repository does not write timezone to the profile.
  - Profile reads return `UTC` when no location timezone is joined.
  - The plan says location timezone is the final authority.
- Example:
  - A location in Toronto can display profile timing with a profile timezone fallback that does not come from the location authority.
- Fix plan:
  - Treat timezone as read-only on timing profiles.
  - Hydrate it from the location/timezone authority on reads.
  - Reject or omit timezone from timing profile writes.

### 7. Business Timing PATCH accepts fields it ignores

- Current app behavior:
  - PATCH accepts scope fields.
  - The update path ignores scope changes.
  - The repository says an empty service-period list can clear the override set, but validation rejects empty lists.
- Example:
  - A client can send a scope move that appears accepted but is not applied.
  - A client cannot clear service periods even though the repository advertises that behavior.
- Fix plan:
  - Reject changed immutable fields on PATCH, or implement an audited move.
  - Add an explicit `clearServicePeriods` command, or allow empty list only for update/reset.
  - Test rejected scope changes and service-period clear behavior.

### 8. Admin Business Timing is read-only, but the plan says admin is the support editor

- Current app behavior:
  - Operator Web has the timing editor.
  - Admin shows timing for review only.
  - The phase plan says Admin Console should mount the same timing editor with required audit reason.
- Example:
  - Support can review a bad timing setup but cannot fix it from admin even though the plan says support/internal overrides exist.
- Fix plan:
  - Decide product direction:
    - admin stays read-only and docs say so, or
    - admin gets the audited timing editor.
  - If editor lands, require audit reason and keep support read-only roles blocked from mutation.

### 9. Manual cover sync does not hydrate the mobile recent-list cache

- Current app behavior:
  - Manual cover writes go to the proxy first, then update only the current device's local SQLite mirror.
  - Sync fetches canonical manual-cover entries but does not replace the SQLite `manual_cover_entries` recent list.
- Example:
  - Manager enters manual Dinner covers on Operator Web or another device.
  - The mobile recent list may not show that entry after sync.
- Fix plan:
  - Project canonical manual-cover entries into SQLite during mobile sync, including clears.
  - Or retire the SQLite recent-list table as the read source.
  - Test cross-device/server-to-mobile hydration.

### 10. Projection retry active list can show rows that workers cannot claim

- Current app behavior:
  - Retry evidence keeps original IDs when current foreign keys are nulled.
  - Workers only claim rows whose current IDs are still non-null.
  - Admin active retry list coalesces original IDs back into the visible location/connection fields.
- Example:
  - Admin can see a pending retry row as active even though the worker cannot claim it.
- Fix plan:
  - Split claimable active rows from orphaned evidence rows, or expose `claimable=false`.
  - Add a blocked reason for null-current-ID rows.
  - Keep original IDs visible as evidence, not as claimable routing fields.

### 11. Projection retry status is admin-only by default

- Current app behavior:
  - Admin Observability shows projection retry counts and dead letters.
  - Operator Web has no bounded freshness/status warning for the same location.
- Example:
  - A manager may see stale Data Accuracy or Vendor Integration results but no simple "updates are delayed" status.
- Fix plan:
  - Product decision needed:
    - keep projection retry evidence internal-only, or
    - expose a safe operator status that hides stack/input details.
  - If exposed, render it as a compact warning in Data Accuracy or Vendor Integrations.

### 12. Operator Web Data Accuracy is location-only while Admin can write broader scopes

- Current app behavior:
  - Admin can apply Data Accuracy at business/org-unit scope.
  - Operator Web requires a location and says rules are saved per location.
- Example:
  - An operator owner cannot set one Data Accuracy rule for a whole region from Operator Web.
- Fix plan:
  - Product decision needed:
    - operator owners get business/org-unit Data Accuracy editing, or
    - broader-scope Data Accuracy stays F&F support-only and docs/copy say so.
  - Do not leave the two surfaces implying different ownership.

## No-Gap Findings

- Old hidden benchmark override writes are intentionally fail-closed with HTTP 410.
- Mobile Star Shift selection is still the active proxy-backed write path.
- Polling tier/cost controls are correctly admin-owned and operator-visible only as status/request-change.
- Service-period covers-source keying is aligned for read/write/projection.
- Mobile Business Timing remains read-only by plan; Shift consumes resolved timing definitions.

## Execution Order

1. Land the quiet-label fix.
2. Fix Data Accuracy reset/clear paths before adding more mobile write controls.
3. Decide per-period wage direction: hide now or fully wire projection.
4. Fix Business Timing route truth: reset, timezone authority, PATCH semantics.
5. Decide Admin Timing editor vs read-only support gate.
6. Fix manual-cover sync hydration.
7. Fix projection retry claimability/read labels.
8. Decide whether operators should see a safe projection-delay warning.

## Safety Rules For The Fix Wave

- Keep the shared checkout on `master`.
- Use separate worktrees for high-risk proxy/schema/UI slices.
- Do not mix Business Timing, Data Accuracy, and projection retry fixes in one PR.
- For schema/proxy/high-risk PRs, run `tool/pre_merge_gate.sh <PR>` before merge and `tool/verify_pr_landed.sh <PR>` after merge.
- Keep the current branch limited to audit doc plus the quiet-label UI fix.
