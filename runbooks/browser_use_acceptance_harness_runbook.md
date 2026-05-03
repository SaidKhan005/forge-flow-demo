# Browser Use Acceptance Harness Runbook

Purpose: use the Browser Use plugin as repeatable acceptance evidence for any
browser-exposed Forge & Flow slice.

This is not a replacement for unit tests, proxy tests, migration lint, or perf
probes. It proves that the built UI works from a real browser origin and that
the walkthrough can be reproduced.

## When To Run

Run this harness for slices that change:

- admin console routes, dialogs, filters, tables, forms, or health panels
- operator Flutter Web routes or visible workflows
- auth, MFA, password reset, account, Settings, or permission UX
- runtime-exposed diagnostics, observability, corpus, graph, replay, or pricing
  surfaces
- mobile layout behavior, text fit, or navigation

Skip only when the slice has no browser-visible behavior. Say that explicitly
in the execution report.

## Safe Boundaries

Browser navigation and opening dialogs are safe.

Stop for action-time approval before submitting or confirming anything that
mutates live state, including onboarding, pricing caps, corpus commits,
provider rotations, feature flags, suspend/reactivate, delete, rebuild,
Firebase/Auth changes, provider calls, or cloud enforcement changes.

Do not capture secrets, passwords, OTPs, bearer tokens, private emails, or
credential material in screenshots or notes.

## Harness Steps

1. Name the browser session for the slice.
2. Open the exact QA origin and record it. `localhost` and `127.0.0.1` are
   different browser origins.
3. Capture the build/revision under test when available.
4. Sweep the routes or tabs affected by the slice.
5. For each route, record:
   - route or click path
   - expected visible signal
   - actual visible signal
   - screenshot path or DOM/text evidence
   - network/runtime errors if relevant
6. Walk one primary acceptance path end-to-end.
7. Check at least one narrow/mobile viewport for UI slices.
8. Attach the evidence summary to the slice walkthrough or execution report.

## Route Sweep Template

Use a table like this in walkthroughs:

| Surface | Path or click target | Expected signal | Evidence | Result |
| --- | --- | --- | --- | --- |
| Home | `admin_nav_item_home` | Home shell loads, no error banner | screenshot path / text | PASS |
| Operators | `admin_nav_item_operators` | operator table or empty state | screenshot path / text | PASS |
| Pricing | `admin_nav_item_pricing` | pricing tiers visible | screenshot path / text | PASS |

For admin console route IDs, prefer the `admin_nav_item_<route-id>` keys from
`lib/admin/admin_routes.dart` and `lib/admin/admin_shell.dart`.

Current side-nav route IDs:

- `home`
- `operators`
- `pricing`
- `corpus`
- `integrations`
- `health`
- `feature_flags`
- `debug`
- `observability`

## Screenshot Baselines

For stable admin or operator surfaces, keep screenshot filenames predictable:

```text
<slice-id>-<surface>-desktop.png
<slice-id>-<surface>-mobile.png
```

If storing under `.codex_appdata/`, reference the exact file path in the
walkthrough. Do not commit browser cache profiles or raw secret-bearing output.

Screenshot baselines are evidence, not golden tests. Use them to catch obvious
layout regressions, blank screens, stale shell loads, missing sections,
overflow, and broken navigation.

## Mobile Viewport Check

For visible UI work, run at least one mobile-width pass:

- confirm primary navigation remains usable
- confirm the changed text fits
- confirm buttons are reachable and not overlapping
- confirm cards/tables degrade to a readable state

If mobile cannot be verified in the current environment, record the reason and
keep the slice active if mobile behavior is part of acceptance.

## Walkthrough Evidence Block

Add a short block like this to `docs/_walkthroughs/<slice-id>.md`:

```markdown
## Browser Acceptance

- Harness: Browser Use
- Origin: <exact URL>
- Build/revision: <local build, Cloud Run revision, or N/A>
- Routes swept: <list>
- Primary path: <click path>
- Desktop evidence: <screenshot/text path>
- Mobile evidence: <screenshot/text path or explicit N/A>
- Safe-action boundary: <no live mutation, or approval reference>
- Result: PASS / FOLLOW-UP NEEDED
```

Keep evidence concise. The walkthrough should prove the slice, not become a
full browser transcript.
