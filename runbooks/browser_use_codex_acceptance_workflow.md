# Browser Use Codex Acceptance Workflow

Browser Use is invoked through Codex (separately operator-driven), not through
any binary in this repo. There is no `tool/browser_use/`, no `test/e2e/`, no
harness binary, and no CI integration. This runbook describes when to ask
Codex to run a Browser Use flow against a Forge & Flow surface and how to
capture the resulting evidence into the slice's walkthrough doc.

This is not a substitute for unit tests, proxy tests, migration lint, or perf
probes. It proves the built UI works from a real browser origin and that the
walkthrough can be reproduced by a human following the same path.

## 1. When To Invoke

Ask Codex to run a Browser Use flow when a slice changes any of:

- admin console routes, dialogs, filters, tables, forms, or health panels
- operator Flutter Web routes or visible workflows
- auth, MFA, password reset, account, Settings, or permission UX
- runtime-exposed diagnostics, observability, corpus, graph, replay, or
  pricing surfaces
- mobile layout behavior, text fit, or navigation

Skip when the slice has no browser-visible behavior. Say so explicitly in the
execution report instead of inventing evidence.

Safe boundary: navigation and opening dialogs are fine. Stop for action-time
approval before submitting or confirming anything that mutates live state
(onboarding, pricing caps, corpus commits, provider rotations, feature flags,
suspend/reactivate, delete, rebuild, Firebase/Auth changes, provider calls,
cloud enforcement). Never capture secrets, passwords, OTPs, bearer tokens,
private emails, or credential material in screenshots or notes.

## 2. How To Ask Codex

Codex runs Browser Use on the operator side. Give Codex enough to act without
asking back:

- slice id and short description
- exact QA origin (`localhost` and `127.0.0.1` are different browser origins)
- build or revision under test, when known
- routes or click targets to sweep, with expected visible signals
- one primary acceptance path to walk end to end
- whether a mobile-width pass is in scope
- any safe-action boundary the operator must hold

Sample prompt shape:

```text
Run a Browser Use acceptance flow for slice <slice-id>.
Origin: <exact URL>
Build: <local build, Cloud Run revision, or N/A>
Sweep these surfaces:
  - <route or click target> → expected: <visible signal>
  - ...
Primary path: <click path>
Mobile pass: <yes/no, viewport>
Safe-action boundary: <no live mutation, or specific approval reference>
Return: route-by-route PASS/FAIL with screenshot or DOM/text evidence and a
short summary.
```

For admin console route IDs, prefer the `admin_nav_item_<route-id>` keys from
`lib/admin/admin_routes.dart` and `lib/admin/admin_shell.dart`. Current
side-nav route IDs: `home`, `operators`, `pricing`, `corpus`, `integrations`,
`health`, `feature_flags`, `debug`, `observability`.

## 3. Evidence Capture

Codex returns transcripts and screenshots. Distill them into a short Browser
Acceptance block in `docs/_walkthroughs/<slice-id>.md`:

```markdown
## Browser Acceptance

- Driver: Codex Browser Use (operator-run, out-of-repo)
- Origin: <exact URL>
- Build/revision: <local build, Cloud Run revision, or N/A>
- Routes swept: <list>
- Primary path: <click path>
- Desktop evidence: <screenshot or DOM/text path>
- Mobile evidence: <screenshot path or explicit N/A>
- Safe-action boundary: <no live mutation, or approval reference>
- Result: PASS / FOLLOW-UP NEEDED
```

For route sweeps, a small table keeps the walkthrough scannable:

| Surface | Path or click target | Expected signal | Evidence | Result |
| --- | --- | --- | --- | --- |
| Home | `admin_nav_item_home` | Home shell loads, no error banner | screenshot/text path | PASS |
| Operators | `admin_nav_item_operators` | operator table or empty state | screenshot/text path | PASS |
| Pricing | `admin_nav_item_pricing` | pricing tiers visible | screenshot/text path | PASS |

Screenshot filenames stay predictable so layout regressions are obvious:

```text
<slice-id>-<surface>-desktop.png
<slice-id>-<surface>-mobile.png
```

Screenshots are evidence, not golden tests. They catch blank screens, stale
shell loads, missing sections, overflow, broken navigation. If the artifacts
live under `.codex_appdata/` or another operator-side path, reference the
exact path in the walkthrough; never commit browser cache profiles or raw
secret-bearing output.

For visible UI work, include at least one mobile-width pass: primary nav still
usable, changed text fits, buttons reachable and not overlapping, cards/tables
degrade to a readable state. If mobile cannot be verified in the current
environment, record the reason and keep the slice active when mobile behavior
is part of acceptance.

Keep evidence concise — the walkthrough proves the slice; it is not a full
browser transcript.

## 4. What NOT To Put In This Repo

Browser Use is Codex's responsibility, not Forge & Flow's. Do not add:

- a `tool/browser_use/` binary or driver
- a `test/e2e/` folder or Playwright/Chromium harness
- CI jobs that try to run Browser Use against the repo
- mock harness scripts that pretend to do what Codex does

If a future slice genuinely needs an in-repo automated browser harness, that
is a separate operator decision and a separate phase doc — not an extension
of this runbook.
