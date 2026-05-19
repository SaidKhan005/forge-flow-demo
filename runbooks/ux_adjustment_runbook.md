# UX Adjustment Framework

Status: Active
Last updated: 2026-05-05

This framework is the repeatable prompt and execution guide for UX copy,
layout, navigation, button, modal, empty-state, and browser-polish passes across
the Forge & Flow operator app, operator web console, and Operations Console.

Use it when a future prompt mentions UX polish, content polish, copy cleanup,
plain English, admin-console clarity, user-friendly wording, button styling,
navigation grouping, tab organization, filters, keys, tooltips, modal styling,
visual consistency, icon polish, favicon/browser-tab polish, or no-regression
UX adjustments.

## Core Promise

UX adjustment work must make the product easier to understand without changing
product logic by accident.

The goal is to turn the interface into a practical translator for the backend.
Users should see human names, useful keys, plain labels, predictable actions,
and consistent visual hierarchy. They should not see raw backend vocabulary,
surprising technical IDs, inconsistent action words, or UI that makes support
staff copy fragile values by hand.

Every UX adjustment pass follows this order:

1. Confirm the branch, runtime, and exact surface being adjusted.
2. Create or confirm a backup branch or clean pushed branch before broad polish.
3. Run the real app or console, not a replacement UI.
4. Inventory visible screens, tabs, buttons, forms, filters, modals, and states.
5. Classify the requested change as copy, layout, information architecture,
   visual styling, workflow, or a surfaced backend wiring bug.
6. Make the smallest coherent UX batch.
7. Preserve existing gateway, auth, permission, tenant, and API behavior unless
   a named bug fix is explicitly in scope.
8. Add or update tests that lock the visible behavior and any bug fix.
9. Rebuild and verify the real browser/runtime surface.
10. Report the exact screens checked, tests run, actions not taken, and risks.

## Hard Boundaries

Allowed:

- Rename visible labels for clarity.
- Replace technical terms with human labels.
- Add explanatory keys, tooltips, captions, and filter chips.
- Reorganize navigation when route behavior stays unchanged.
- Improve button consistency, size, hierarchy, and wording.
- Improve modal layout, spacing, confirmation copy, and visual consistency.
- Add search bars, dropdown search, filters, and filter buttons.
- Add disabled, faded, or coming-soon states for unavailable work.
- Change favicon, browser title, manifest text, and app icon assets.
- Improve date/time readability.
- Add tests that prove labels, routes, disabled states, and actions still work.
- Fix a backend wiring bug discovered during UX testing when the bug is named,
  scoped, and covered by focused tests.

Not allowed without explicit approval:

- Changing business rules, pricing rules, plan logic, or usage caps.
- Changing auth, role, permission, tenant isolation, or Firebase claims.
- Changing API contracts, request shapes, response shapes, or migrations.
- Hiding red/yellow/unknown backend truth.
- Removing important operational data because it looks technical.
- Replacing the console or rebuilding the product shell from scratch.
- Submitting live writes while testing unless action-time approval was given.
- Shipping demo auth or fixture-only behavior to public staging or production.
- Bulk rewriting unrelated docs, tests, or comments just for style.

## Golden Rule

The UI is a translator, not a raw backend surface.

When a backend value is needed, the screen should explain what it means and
give the user a safer workflow than manual detective work. If an ID must appear
for support, it should be paired with a clear name, copy affordance, filter
button, or lookup path. If an acronym, status, use case, or metric appears, add
a short key or tooltip that explains why it matters.

Examples from the staging admin polish branch:

- `Customers` became `Operators`.
- `Main location` became `Primary location`.
- `View support logs` and `View logs` became one wording: `View logs`.
- Raw use-case IDs became filter buttons with a key.
- System metrics received keys and column tooltips.
- Times and dates were made human-readable.
- The old `Ecosystem` group split into `System monitoring` and `Service setup`.
- `Forge & Flow AI plan` is faded and marked coming soon where it is not yet
  editable.
- The admin web tab uses the Forge & Flow logo and plain hyphen title text.

## Prompt Intake Checklist

Every future UX adjustment prompt should start by answering:

1. Which surface is in scope: mobile app, operator web, Operations Console, or
   a backend-powered admin tab?
2. What exact branch, commit, deployment revision, URL, auth mode, and proxy are
   being tested?
3. Is the request copy-only, layout-only, information architecture, workflow, or
   a possible backend bug?
4. Which screens, tabs, modals, forms, filters, and buttons are visible to the
   user?
5. Which actions are read-only and safe to click?
6. Which actions submit, mutate, suspend, delete, rotate, publish, invite, or
   otherwise need action-time approval?
7. What existing tests protect this surface?
8. What browser or device evidence will prove the UX change without regression?

If those answers are unknown, gather them before editing.

## UX Inventory Matrix

Before editing, inventory the visible surface:

- Page title and subtitle.
- Navigation group and tab labels.
- Primary, secondary, destructive, disabled, and coming-soon buttons.
- Search bars, dropdowns, filter chips, and filter reset paths.
- Data labels, table columns, cards, badges, and status chips.
- Empty states, loading states, error states, and stale states.
- Modal titles, body copy, typed confirmation prompts, and close paths.
- Tooltips, keys, captions, helper text, and support notes.
- Date, time, timezone, currency, plan, operator, and location labels.
- Icon usage and whether the icon matches the action.
- Browser title, favicon, web manifest, and mobile install metadata.

Record mismatches as plain findings:

- unclear wording
- duplicate wording
- raw backend term
- missing key
- inconsistent button style
- awkward layout
- unsafe workflow
- missing disabled or faded state
- backend error surfaced during normal use

## Content Rules

Use human language first.

Preferred patterns:

- `Operator` for the business account that runs locations.
- `Primary location` for the default or main location.
- `View logs` for support-log navigation.
- `Manage integrations` for vendor-service setup.
- `Click to manage` for a simple list-level manage action.
- `Coming soon` for visible but unavailable work.
- `System monitoring` for health, support logs, and metrics.
- `Service setup` for connected services and launch controls.

Avoid:

- raw table names
- unexplained IDs
- duplicate status words like `Needs review` beside another `Needs review`
- vague labels like `Subscription tier` without naming what the tier controls
- backend-only acronyms without a key
- em dashes in visible copy or browser metadata
- instructional text that describes obvious UI instead of helping a decision

When a technical value is unavoidable, pair it with context:

- `Request use case` plus a key.
- `Cost risk` plus what action to take.
- `Cap event` plus why the request was stopped.
- `Inactive operator` plus the inactivity window.
- `Graph health` plus what a bad value means.

## Information Architecture Rules

Group routes by user intent, not by implementation ownership.

For the Operations Console, the current side-nav standard is:

1. `Operations`
   - Operators
2. `AI`
   - Plans and limits
   - Knowledge base
   - Badge: `Work in progress`
3. `System monitoring`
   - System health
   - Support logs
   - System metrics
4. `Service setup`
   - Connected services
   - Launch controls

When moving a route:

- Keep the route ID and path stable unless a route rename is explicitly in
  scope.
- Update shell/widget tests that assert nav order and grouping.
- Browser-test every moved route.
- Do not mix setup actions with monitoring screens unless the user flow truly
  requires it.

## Button And Action Rules

Buttons should communicate action type, risk, and availability.

Use consistent verbs:

- `Add` for creation.
- `Edit` for form-based changes.
- `View logs` for read-only support-log navigation.
- `Manage integrations` for provider or vendor setup.
- `Suspend` and `Reactivate` for access state.
- `Remove` for local entity removal.
- `Publish`, `Rotate`, `Enable`, and `Disable` only when the backend action is
  truly that specific.

Style rules:

- Primary actions are visually stronger and should appear once per section.
- Destructive actions use destructive styling and typed confirmations when the
  existing flow requires it.
- Disabled actions explain themselves with disabled state, tooltip, helper
  text, or coming-soon chip.
- Buttons should not grow or shrink the layout when text changes.
- Icon buttons need an icon that matches the action and a tooltip when the icon
  is not obvious.
- Repeated actions across cards, rows, and modals should share wording and
  styling.

Live testing rule:

- Opening a modal is usually safe.
- Submitting a modal, toggling a flag, suspending, deleting, rotating keys,
  publishing corpus content, or creating an operator is a write action. Stop for
  action-time approval unless the user already gave narrow approval for that
  exact action.

## Modal And Confirmation Rules

Modals should be calm, short, and specific.

Every modal should have:

- a plain title that names the action
- one short explanation of the result
- fields grouped in the order the user thinks about the task
- clear primary and secondary actions
- destructive styling for destructive actions
- validation copy that tells the user how to fix the issue
- loading, success, and error states that do not lose the user's context

Typed confirmations should:

- name the exact object being changed
- say what will happen
- keep the typed phrase visible and short
- avoid generic panic copy
- preserve the existing backend audit/idempotency path

## Support And Monitoring Rules

Support and monitoring tabs must translate backend state into operator-safe
workflows.

Support logs:

- Prefer operator/location names in filters.
- Use IDs only when needed for exact support lookup.
- Provide filter buttons for common request use cases.
- Provide a key for use-case IDs.
- Use human-readable time and date everywhere.
- Keep full-content reveal gated by existing role rules.
- Do not expose secrets, tokens, raw prompts, or sensitive payloads casually.

System health:

- Show a key for critical and important systems.
- Keep red/yellow/unknown truth visible.
- Remove repetitive labels that do not add signal.
- Separate read-only status from manual run-check controls.
- Keep expensive diagnostics manual, scoped, and clear.

System metrics:

- Add keys for labels such as losing money, cap events, inactive, graph health,
  and hosting metrics.
- Add tooltips or captions for columns whose meaning is not obvious.
- Keep cost, risk, and activity labels practical, not backend-ish.
- Preserve limits, filters, and query bounds.

## Workflow Rules

A good UX flow reduces typing, guessing, and memory work.

Preferred workflow improvements:

- Search bars for long operator, location, timezone, vendor, and log lists.
- Filter buttons for common cases instead of requiring manual ID entry.
- Human-readable names first, IDs second.
- Copy buttons or direct filter handoffs when users need exact identifiers.
- Read-only route handoffs from entity cards to support logs.
- Coming-soon states for visible future work instead of fake controls.
- Faded or disabled affordances for suspended or unavailable entities.
- Stable layout dimensions so cards, rows, and buttons do not jump.

Avoid:

- making users copy from canvas text when the browser cannot reliably select it
- asking support users to know database names
- using raw IDs as filter labels when a name is available
- hiding an unavailable action without explaining why when the user naturally
  expects it

## Browser And Runtime Loop

Use the real existing runtime.

Local admin QA path:

```powershell
flutter build web -t lib\main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true --pwa-strategy=none
Set-Location build\web
python -m http.server <fresh-port> --bind 127.0.0.1
```

Live admin QA path:

```powershell
scripts\deploy_admin_console.ps1 -AdminProxyBaseUri https://staging-api.feflow.org
```

Browser rules:

- Use a production-shaped static build for Flutter web QA.
- Use a fresh port or fresh cache-busting query when visual behavior looks
  stale.
- Remember `localhost` and `127.0.0.1` are different origins.
- Confirm the browser title and favicon when web metadata changes.
- Sweep moved nav routes after information-architecture changes.
- Capture the exact URL tested.
- Capture console errors after route sweeps.
- Keep live staging sweeps read-only unless action-time approval is given.

## Required Tests And Guardrails

UX changes need tests when they affect routes, button state, forms, labels that
drive workflows, or backend wiring.

Good test examples:

- side nav lists every route in the expected group and order
- operator list shows simple manage actions
- AI plan controls are disabled or coming soon
- primary-location wording is consistent
- location rows fade for suspended operators
- support-log handoff uses exact filters
- add-location timezone dropdown submits the chosen IANA timezone
- onboarding creates a new operator end-to-end
- repository creates the required org unit before primary location insert
- health placeholder renders as the agreed visible fallback

Run the smallest credible suite:

```powershell
flutter analyze --fatal-infos <touched-lib-and-test-paths>
flutter test <targeted-tests>
flutter build web -t lib\main_admin.dart --dart-define=ADMIN_DEMO_AUTH=true --pwa-strategy=none
```

For docs-only framework updates, run:

```powershell
git diff --check
```

## Backend Bug Rule

UX testing may reveal backend wiring bugs.

When that happens:

1. Name the bug separately from the UX polish.
2. Confirm the failing user action.
3. Identify the exact gateway, repository, or endpoint path.
4. Fix only the broken wiring.
5. Add a focused unit or widget test.
6. Re-run the original user action in local demo or live staging when safe.
7. Report the bug as a backend fix discovered during UX QA.

Example from this branch:

- Live add-operator failed because the backend insert path did not create the
  required root org unit before inserting the primary location. The fix belonged
  in the operator repository and was covered by repository tests, not hidden as
  a copy/layout change.

## Deployment And Runtime Proof

A UX fix is not accepted until the real runtime proves it.

Before final acceptance:

- confirm branch and commit
- confirm whether the work is local-only, pushed, deployed, or merged
- rebuild the touched web bundle
- deploy only the needed service
- confirm Cloud Run service revision and 100 percent traffic when deployed
- open the real local or staging URL
- avoid stale browser cache
- verify the exact changed labels, groups, buttons, modals, or icons
- sweep adjacent routes when nav, shell, shared buttons, or shared widgets
  changed
- check browser console errors
- state which live write actions were intentionally not submitted

## Future Prompt Template

Use this template when asking an implementation agent to perform a UX adjustment
pass.

```text
Task:
Run a UX adjustment pass for <surface> on branch <branch>. Simplify the
experience and make the language human. Do not change business logic, auth,
API contracts, schema, or backend behavior unless a named bug fix is explicitly
called out and tested.

Authority:
- PROJECT_TRACKER.md
- docs/frameworks/UX_ADJUSTMENT_FRAMEWORK.md
- docs/contracts/slice_runtime_acceptance_contract.md
- <active phase doc, if this belongs to a phase>

Runtime target:
- Local URL: <local URL or require discovery>
- Staging URL: <staging URL or require discovery>
- Auth mode: <demo / live Firebase>
- Proxy/backend: <proxy URL and revision, or require discovery>

Required workflow:
1. Confirm branch, commit, origin, and backup branch posture.
2. Run the existing app/console, not a replacement UI.
3. Inventory visible screens, tabs, buttons, forms, filters, modals, and states.
4. Classify each requested change as copy, layout, navigation, styling,
   workflow, or surfaced backend bug.
5. Make small coherent UX batches.
6. Preserve route IDs, API contracts, permissions, and backend behavior.
7. Add or update tests for labels, route grouping, disabled states, form
   behavior, and any bug fix.
8. Rebuild the production-shaped web bundle or app runtime.
9. Browser-test local with a fresh origin or cache-busting query.
10. Deploy only when requested.
11. Browser-test staging read-only unless approved for specific write actions.
12. Report exact URLs, screens, tests, writes not submitted, and risks.

Allowed changes:
- visible label cleanup
- navigation grouping
- keys, tooltips, helper text, and explanatory captions
- button wording and styling consistency
- modal styling and confirmation copy
- search, dropdown search, filters, and filter buttons
- disabled, faded, or coming-soon states
- favicon/title/manifest polish
- focused tests and browser QA evidence

Blocked without approval:
- auth or role changes
- API contract changes
- migrations
- business logic changes
- hiding backend health or errors
- live write submissions
- provider/key rotations
- destructive actions
- demo auth on public staging

Final report must include:
- exact branch and commit
- local and/or staging URL tested
- screens and workflows covered
- UX changes made
- tests and browser evidence
- any backend bug fixed separately
- live actions intentionally not submitted
- remaining risks
- lessons for the next UX pass
```

## Executive Report Shape

Every completed UX adjustment pass reports:

- Exact surface tested.
- Branch and commit.
- Local and deployed URLs.
- Auth mode and proxy/backend target.
- Screens, tabs, and workflows covered.
- Copy changes.
- Navigation or information-architecture changes.
- Button, modal, icon, and visual changes.
- Keys, tooltips, filters, and support-workflow changes.
- Backend bug fixes discovered during UX QA.
- Tests and guardrails added.
- Browser evidence.
- Deployment revision when applicable.
- Live write actions intentionally not submitted.
- Remaining risks.
- Lessons to carry forward.

## Carry-Forward Lessons

- Make the interface explain the backend instead of exposing it raw.
- Keep names consistent across every tab.
- Prefer direct workflow controls over support users copying values by hand.
- Search and filter affordances matter as soon as lists can grow.
- Coming-soon controls should be visible, faded or disabled, and honest.
- A button's wording should match the same action everywhere.
- Human-readable dates and times reduce support mistakes.
- Keys and tooltips prevent backend terms from becoming product language.
- Flutter web can serve stale assets; rebuild and use fresh origins or query
  strings.
- The deployed tab title, favicon, and manifest are part of the UX.
- Live staging QA should be read-only unless a specific write action is
  approved at action time.
- If UX polish exposes a backend error, fix it as a named bug with tests.
