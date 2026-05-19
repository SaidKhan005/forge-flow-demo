# Feature Implementation Lens Audit Framework

Status: Active
Created: 2026-05-08
Purpose: reusable checklist for editing, adding, or implementing Forge & Flow
features without missing hidden plumbing.

## When To Use This

Use this framework for any new feature, meaningful UX change, admin/operator
console change, proxy route change, migration, settings surface, role/access
change, integration, background worker, deploy/runtime change, or bug fix whose
blast radius is not obviously single-file.

Use the quick pass for small changes. Use the deep pass when the work touches
any of these:

- database schema or RLS
- auth, roles, permissions, sessions, MFA, password reset, or invites
- proxy routes or API contracts
- settings, hierarchy, pricing, timing, data accuracy, integrations, or support
  tooling
- mobile/operator web/admin parity
- deploy, Cloud Run, background workers, health, startup, or preview/staging
- performance, polling, caching, large lists, or route switching
- mutating workflows, audit logs, idempotency, or lifecycle actions

## Core Promise

A feature is not ready because the visible screen compiles. It is ready when the
visible surface, route contracts, data model, permission model, lifecycle model,
tests, deploy mode, and evidence all agree.

The audit asks the same question from every angle:

> What layer could make this look wired while still failing live?

## Required Output

Every lens audit produces a short note, PR comment, or execution section with:

- feature or slice name
- source commit and branch/worktree
- lenses checked
- code paths inspected
- real gaps found
- explicit non-gaps, where helpful
- tests/builds/browser checks run
- preview/deploy/database mode, if applicable
- residual risks and blocked decisions

Use this compact table when possible:

| Lens | Code or doc checked | Finding | Required action |
|---|---|---|---|
| Example | `tool/advisor_proxy/...` | Route exists but gateway calls a different path. | Reconcile route contract and add tests. |

## Pass 0 - Branch, Authority, And Scope

Before editing:

- Confirm current branch/worktree and avoid mutating unrelated work.
- Read the active prompt and `PROJECT_TRACKER.md`.
- Read the relevant contract, phase doc, runbook, and framework docs.
- Identify whether the task is docs-only, UI-only, route-only, schema-bearing,
  runtime-exposed, or deploy-exposed.
- Name files or modules likely in scope.
- Name files or modules intentionally out of scope.

Search prompts:

```powershell
git status --short --branch
rg "<feature keyword>|<route>|<model>|<permission>" PROJECT_TRACKER.md docs lib tool test db
rg --files | rg "<feature keyword>|<screen>|<gateway>|<repository>|<migration>"
```

Stop if:

- the worktree is not the intended one
- the branch is stale in a way that changes the target files
- authority docs conflict
- the feature requires live mutation, credentials, billing, provider calls, or
  cloud enforcement without explicit approval

## Lens 1 - Product And User Journey

Check whether the feature makes sense in the real workflow:

- Who uses it?
- What screen or route starts it?
- What is the before/after state?
- What states must exist: loading, empty, partial, error, forbidden, disabled,
  stale, conflict, success?
- Is this new UI, rearranged UI, or surfacing existing backend capability?
- Does the user need a confirmation, reason, scope picker, filter, search, or
  "why disabled" explanation?

Outputs:

- expected click path
- visible labels and state copy
- explicit unsupported states

## Lens 2 - Information Architecture And Navigation

Check how users reach and leave the feature:

- route path
- tab/sidebar placement
- deep links and route handoff
- selected business/location/hierarchy scope
- browser title/favicons when web-facing
- mobile responsive layout
- duplicate or competing entry points

Search prompts:

```powershell
rg "Route|Shell|Handoff|Picker|selected|tab|nav|drawer|sidebar" lib test
rg "<screen class>|<route enum>|<tab label>" lib test
```

Common failure:

- a new screen works from one button but not from deep link, refresh, browser
  back, or route switching.

## Lens 3 - Data Model, Migration, And RLS

Check whether data shape truly supports the product:

- table and columns
- nullable vs required fields
- unique constraints
- foreign keys and cascade behavior
- RLS policy and tenant context
- indexes and query shape
- triggers, generated fields, denormalized fields
- migration order, backfill, lock risk, and cutoff lint
- existing production/staging data assumptions

Search prompts:

```powershell
rg "<table>|<column>|<enum>|<constraint>" db/migrations lib test
rg "app_current_operator|app_current_location|enable row level security|policy" db/migrations
rg "on delete|cascade|set null|unique|check" db/migrations
```

Stop if:

- UI exposes a value that schema cannot store
- delete/suspend/archive semantics are undefined
- RLS uses missing or mismatched tenant context
- a migration changes runtime behavior without tests

## Lens 4 - Repository And Service Layer

Check whether repositories and services implement the contract:

- read and write methods
- transaction boundaries
- tenant wrapper or system wrapper
- validation and error mapping
- idempotency integration
- audit event insertion
- cache invalidation or version bump
- effective/inherited resolver logic
- concurrency behavior

Search prompts:

```powershell
rg "<repository>|<model>|<method>|withTenant|withSystem|idempotency|audit" lib test
rg "version|notify|cache|invalidate|effective|resolver|inherit" lib test
```

Common failure:

- schema supports a scope, but repository write methods only accept location.

## Lens 5 - Proxy, Route, And Gateway Contracts

Check every network boundary:

- proxy route method/path
- admin/operator/mobile gateway method/path
- request body keys
- response body keys
- query parameters
- auth guard
- permission check
- idempotency key on writes
- timeout/retry behavior
- plain-English errors
- CORS/origin needs for web

Search prompts:

```powershell
rg "/v1/|Idempotency-Key|permission|requirePermission|route" tool lib test
rg "<gateway class>|<route const>|<path suffix>|<error code>" lib tool test
```

Stop if:

- gateway path and proxy path differ
- client body key and proxy body key differ
- proxy can mutate without idempotency or audit where required
- an admin route bypasses the intended role gate

## Lens 6 - Auth, Roles, Permissions, And Scope

Check who can see and mutate:

- actor types: operator owner, operator admin, location manager, F&F support,
  forge admin, forbidden user
- selected business/operator/location/org-unit scope
- inherited access vs explicit grant
- permission catalog keys
- sessions, MFA, password reset, invites, lockout, revoke paths
- read-only behavior and disabled mutation states

Search prompts:

```powershell
rg "permission|role|scope_type|operator_admins|user_roles|forbidden|read-only" lib tool test db
rg "operator_owner|operator_admin|location_manager|ff_support|forge_admin" lib tool test db
```

Common failure:

- support staff can access the data in storage, but UI routing assumes one
  operator/location identity and blocks the workflow.

## Lens 7 - Lifecycle And Destructive Actions

Check object lifecycle before exposing buttons:

- create
- edit
- move/reassign
- suspend
- reactivate
- archive
- delete
- restore
- revoke
- resend
- expire

For each action, check:

- route exists
- storage supports it
- child/dependent data behavior is defined
- audit event exists
- confirmation copy exists
- role gate exists
- idempotency exists where needed
- tests cover success and forbidden paths

Search prompts:

```powershell
rg "delete|remove|suspend|reactivate|archive|restore|revoke|expire|resend|move" lib tool test db
rg "on delete|cascade|set null|archived_at|suspended_at|deleted_at" db/migrations lib test
```

Stop if:

- "delete" would cascade through important data without product approval
- "suspend" has no persisted status
- route is irreversible but UI copy implies reversible behavior

## Lens 8 - Background Workers, Deploy, Startup, And Health

Check runtime behavior beyond the request:

- startup checks
- background workers/listeners
- Cloud Run max instances and pool sizing
- health vs readiness
- preview vs staging vs production modes
- secrets and environment variables
- migrations loaded in runtime package
- failure modes when dependencies are saturated or unavailable

Search prompts:

```powershell
rg "startup|readyz|health|background|worker|listener|pool|max instances|env var" tool scripts runbooks test
rg "Secret|POSTGRES|Cloud Run|deploy|preview|staging|production" scripts runbooks docs tool
```

Stop if:

- startup binds only after DB-dependent work in a preview/staging deploy path
- background workers start in every scaled proxy instance unexpectedly
- health checks require expensive dependencies for liveness

## Lens 9 - UI State, UX, And Accessibility

Apply the UX Adjustment Framework for visible changes. Confirm:

- labels are plain English
- consistent button/action wording
- no duplicate mental models
- loading, empty, error, forbidden, and disabled states
- dialogs and confirmation copy
- mobile responsiveness
- scanability and grouping
- no fake affordances for unavailable backend work

Search prompts:

```powershell
rg "Text\\(|label|tooltip|empty|loading|error|forbidden|disabled|Dialog|Button" lib test
rg "<visible label>|<screen title>|<button text>" lib test
```

## Lens 10 - Performance And Data Loading

Apply the Performance Framework when user-facing or runtime-sensitive. Check:

- startup cost
- duplicate requests
- route switching
- cache/staleness behavior
- refresh behavior
- polling and timers
- bounded lists
- large tree/table scrolling
- repeated navigation
- bundle/build impact

Search prompts:

```powershell
rg "FutureBuilder|StreamBuilder|Timer|periodic|poll|refresh|cache|memo|inFlight" lib test
rg "ListView|DataTable|Paginated|limit|offset|page|search|filter" lib test tool
```

Evidence:

- baseline before changes
- after measurement
- JSON path for perf probe when applicable

## Lens 11 - Mobile, Operator Web, Admin, And API Parity

Check cross-surface consistency:

- mobile behavior
- operator web behavior
- admin console behavior
- proxy API behavior
- docs and runbooks
- demo/share preview vs live preview

Search prompts:

```powershell
rg "<feature keyword>" lib test tool docs
rg "operator_web|admin|mobile|sync|scope|parity" lib test docs tool
```

Common failure:

- admin supports a setting that operator web displays differently, or mobile
  sync assumes a narrower scope.

## Lens 12 - Tests, Builds, Browser Use, And Evidence

Map tests to risk:

- unit tests for pure resolver/validation
- repository tests for SQL shape and RLS behavior
- migration tests for schema and constraints
- proxy tests for routes, auth, idempotency, errors
- Flutter widget tests for visible behavior
- integration/runtime tests for live wiring
- Browser Use for real console workflows
- builds for release artifacts
- performance probes for timing-sensitive changes

Search prompts:

```powershell
rg --files test | rg "<feature|screen|route|repo|migration|auth|proxy>"
rg "<feature keyword>|<route>|<error code>" test
```

Required report:

- exact commands
- pass/fail
- not-run reason for any skipped gate
- preview URL or local URL for browser evidence when applicable

## Lens 13 - Observability, Audit, And Supportability

Check whether support can understand what happened:

- audit logs
- event type naming
- actor kind and actor user
- reason note
- correlation/request IDs
- debug/support logs
- plain-English error messages
- metrics/health producers
- export or lookup affordances

Search prompts:

```powershell
rg "audit|actor|reason|correlation|request_id|log\\(|metrics|health|support" lib tool test db
```

Common failure:

- mutation succeeds but leaves no audit trail or emits an event with ambiguous
  actor/scope.

## Lens 14 - Docs, Tracker, And Prompt Hygiene

After implementation truth exists:

- update tracker only for routing/status truth
- update contracts when rules change
- update runbooks for deploy/runtime changes
- update execution notes for evidence
- archive stale detail when needed
- generate prompts with `docs/CODEX_PROMPT_GENERATION_STANDARD.md`

Do not move tracker truth ahead of code truth.

## Quick Pass Checklist

Use for small changes:

- [ ] Branch/worktree confirmed.
- [ ] Authority docs checked.
- [ ] Code owner/seam located with `rg`.
- [ ] UI state impact checked.
- [ ] Data/schema impact checked.
- [ ] Route/gateway impact checked.
- [ ] Auth/permission impact checked.
- [ ] Lifecycle/destructive action impact checked.
- [ ] Tests identified and run or not-run reason documented.
- [ ] Docs/evidence updated if needed.

## Deep Pass Checklist

Use for features and broad changes:

- [ ] Product journey and IA.
- [ ] Route handoff and navigation.
- [ ] Data model, migration, RLS, indexes.
- [ ] Repository/service transaction behavior.
- [ ] Proxy/gateway contract.
- [ ] Auth, roles, scopes, forbidden states.
- [ ] Lifecycle and destructive actions.
- [ ] Background/deploy/startup/health.
- [ ] UX states and copy.
- [ ] Performance and loading behavior.
- [ ] Mobile/operator web/admin parity.
- [ ] Tests/builds/Browser Use evidence.
- [ ] Observability/audit/supportability.
- [ ] Docs/tracker/runbook/prompt hygiene.

## Audit Note Template

```markdown
# <Feature> Lens Audit

Status: <planned | in progress | complete>
Branch/worktree:
Source commit:
Date:

## Scope

<What changed or will change.>

## Lenses Checked

| Lens | Code/doc checked | Finding | Required action |
|---|---|---|---|

## Tests And Evidence

- Commands:
- Browser Use:
- Preview/deploy:
- Performance JSON:

## Residual Risks

- <risk or none>

## Decision Stops

- <decision needed or none>
```

## Prompt Add-On

Append this to implementation prompts when a feature needs this framework:

```text
Before editing, run the Feature Implementation Lens Audit Framework:
runbooks/feature_implementation_lens_audit_runbook.md.
Use quick pass for small changes and deep pass for feature or runtime changes.
Include the lens table in the execution note or PR comment. Do not expose UI
controls for backend capabilities that are not routed, persisted, authorized,
audited, and tested.
```
