# Codex Prompt Generation Standard

How Codex and Claude run the execution loop in this repo.

For a compact copy/paste generator built from this standard, use
`docs/CODEX_LEAN_PROMPT_GENERATOR.md`. This file remains the authority;
the lean generator is the quick-start tool.

## Operating Loop

Every prompt cycle follows this order:

1. Codex reads tracker truth and only the active doc slice it needs.
2. Codex generates a three-block prompt.
3. Claude implements only the scoped slice.
4. Claude reports files, tests, acceptance, scope, and blockers.
5. Codex verifies against repo truth, not just the report.
6. Codex updates trackers only after verification.
7. Codex generates the next prompt unless the user pauses or pivots.

If the user pivots into architecture, workflow, or docs cleanup, pause prompt
sequencing until that cleanup is handled.

## Parallel Lanes (Worktrees)

Codex runs one lane on `master` (planning, prompts, tracker truth,
acceptance verdicts). Claude runs N parallel implementation lanes in
git worktrees (`.claude/worktrees/<lane-name>`). Each lane carries a
single slice from a single phase to acceptance, then merges to master.
Multiple phases — not just multiple slices within a phase — may be
active simultaneously across the worktree set.

**Lane identification.** Every prompt names its lane in Block 1:

```
Lane: <slice-id> — worktree <.claude/worktrees/<lane-name>> on
branch <branch-name> off master @ <short-sha>.
```

If the lane has not been created yet, the prompt says
`Lane: <slice-id> — to be created off master @ <short-sha>.` Claude
creates the worktree before starting.

**File ownership.** Each active lane has exclusive checkout of its
`Files to modify` for the slice's lifetime. Codex must verify, before
emitting a parallel prompt, that no other active lane's `Files to
modify` overlaps with this slice's set. Overlap = sequence, not
parallelize.

**Shared seams.** Some files are written by multiple slices across
lanes (e.g., `lib/screens/settings_screen.dart` registers tabs added
by `9.UX.1`, `9.UX.2`, `9.UX.4`; `lib/services/auth/auth_operations_gateway.dart`
gains methods consumed by `9.UX.1`–`9.UX.7`). The phase doc lists
**Shared seams across lanes** and the rule per file. Default rule:
serialize lanes that touch a shared seam; first lane lands the seam
extension, later lanes rebase. Phase doc may carve out additive-only
patches (e.g., new methods on a gateway interface) as parallel-safe
when the seam tolerates it.

**Walkthrough evidence per lane.** Each Claude lane captures
walkthrough evidence inside its worktree (screenshot path or text
trace committed to the lane's branch as
`docs/_walkthroughs/<slice-id>.md`, or attached to the execution
report). Codex on master inspects worktree evidence, not the master
checkout.

**Merge sequencing.** Codex declares merge order when accepting. A
lane that landed first can ship its merge to master immediately. A
lane that landed second rebases on top of the first lane's merge,
re-runs `dart analyze` + the slice's focused tests on master HEAD,
then merges. The merge order is set in the acceptance verdict, not
chosen by the lane.

**Master-side post-merge gate.** After each merge to master, Codex
runs `flutter analyze --fatal-infos` and the targeted test set for
the merged slice on master HEAD. If a regression appears that was
absent in the worktree, Codex returns `FOLLOW-UP NEEDED` to the
worktree (which still has its branch alive) for fix-and-rebase.

**Cross-lane coordination.** When a slice in lane B depends on lane
A's outcome (e.g., `9.UX.2` role editor consumes `9.UX.1`'s gateway
extension), Codex either (a) sequences A → B in one lane, or
(b) splits A into "interface land" + "implementation land" so B can
start against the interface alone. Phase docs name dependent slices
explicitly.

**Main-chat read-only.** When parallel worktrees are running, the
main Claude chat on master is read-only across all of them — it
inspects worktrees (`git worktree list`, `git -C <path> diff`,
file reads) but does not edit. Tracker / memory / coordination doc
updates on master from the main chat are still allowed (those are
not project-code edits).

## Frontend Exposure & UX Acceptance Gate

Every phase that ships operator- or admin-visible capability owes a
`Frontend Exposure` section in its phase doc. The section names:

- Operator-facing surfaces (file paths or screen names)
- Admin (11A) surfaces (or "None / covered elsewhere")
- The UX sub-slice family naming (`<phase>.UX.<n>` for backend-heavy
  phases; or "owned inline by existing slices" for UX-led phases)
- A demo-mode click path that proves the surface works

Backend-heavy phases (`9`, `7.58`, `10a`, `7.61`, `8`, `8R`, `8.5`,
`9.8`, `10b`, `11b.2`) ship a `<phase>.UX.<n>` sub-slice family
interleaved with backend slices. UX-led phases (`10.5`, `9.5`, `9.75`,
`11A`, `11b`, `12`) own their UX inside their existing sub-slice
sequence.

UX-exposing slices add an `Operator walkthrough` block in Block 3 and a
walkthrough acceptance criterion. Codex returns `FOLLOW-UP NEEDED` if
walkthrough evidence (screenshot OR text trace) is absent at review.

A phase plan that opens without a `Frontend Exposure` section is a
prompt defect. Fix the doc before the first slice ships.

## Generated Parallel Batch - 2026-04-30

Batch 1 is parallel-safe. All three lanes are additive on shared seams;
sequence is not required. The worktrees do not exist yet and should be
created off master at `4da758b`.

### 9.UX.2 - Custom Role Editor

## Block 1 - Human Context

Plain English: This lane exposes the Phase 9 role catalog in operator
Settings and adds a custom role editor. It consumes the deployed B17
`/v1/admin/auth/roles` staging route (`00018-ztq`) and only appends its
own UI/gateway seam.

Lane: `9.UX.2` - worktree `.claude/worktrees/9-ux-2` on branch
`codex/9-ux-2`, to be created off master @ `4da758b`.

Important context:
- Scope is `docs/phases/phase_9/phase_9_auth_plan.md` Frontend Exposure
  row `9.UX.2`.
- Shared seams are additive only: this lane appends its role surface and
  role gateway shape without re-ordering existing Settings tabs.

Current issue:
- Role CRUD exists behind the proxy, but operators have no Settings
  surface to view the catalog, create custom roles, or assign permission
  keys.

Human prerequisites:
- Setup/access needed: None for code + demo-mode acceptance. Live
  staging QA later needs an operator/admin identity with the relevant
  `admin.roles.*` permissions; this does not block the slice.
- Decision needed for this slice: No decision needed for this slice.

```text
## Block 2 - Tech Context

Authority files for this run:

- docs/phases/phase_9/phase_9_auth_plan.md - Frontend Exposure row 9.UX.2 + shared seams
- lib/services/auth/auth_operations_gateway.dart + lib/services/auth/proxy_auth_operations_gateway.dart - role catalog/client seam
- lib/screens/settings_screen.dart + lib/screens/team/team_settings_section.dart + docs/contracts/auth_permission_key_catalog.md - Settings/Team placement and admin.roles.* keys

Hard constraints
- Do not update trackers.
- Do not commit unless explicitly asked.
- Do not change MFA, org hierarchy, login, or Team member lifecycle behavior.
- Additive-safe carve-out: lib/screens/settings_screen.dart may only import/wire the 9.UX.2 Roles surface and append its own tab/section spec; do not reorder or rewrite existing Account/Team/Data/Authority/Developer/MFA/Org Hierarchy entries.
- Additive-safe carve-out: lib/services/auth/auth_operations_gateway.dart may only add/adjust role editor DTOs or methods required by 9.UX.2; keep existing role/list/grant contracts backward compatible.
- B17 /v1/admin/auth/roles is the live route source; do not invent a second role API or direct database access from Flutter.
- Run only required tests; no courtesy CLI smoke runs.

## Block 3 - Tasks

Files to modify
- lib/screens/settings/settings_custom_roles_section.dart (new)
- lib/screens/settings/settings_role_editor.dart (new)
- lib/screens/settings_screen.dart - additive 9.UX.2 wiring only
- lib/services/auth/auth_operations_gateway.dart - 9.UX.2 role DTO/method seam only
- test/settings_custom_roles_section_test.dart (new)
- test/settings_screen_widget_test.dart - Roles visibility/wiring assertions only

Implementation tasks
1. Add a Settings -> Team -> Roles surface that lists seeded and operator custom roles, shows permission key allow/deny rules, and distinguishes editable vs protected roles.
2. Add a role editor for custom-role create/edit/delete with display name, description, permission key picker, allow/deny/remove states, save/cancel, and clear error/loading states.
3. Wire role saves back into the role options used by Team member grant flows so a newly created custom role can be granted without restarting the screen.
4. Respect proxy response fields such as isSeeded/isEditable; never allow deleting seeded roles or mutating non-editable roles from the UI.
5. Consume the existing role gateway methods backed by B17 /v1/admin/auth/roles; do not add a parallel role transport.
6. Use Forge & Flow theme tokens, compact Settings layout patterns, stable widget keys, and demo fixtures so the walkthrough runs without staging access.

Required tests
- dart analyze
- flutter test test/settings_custom_roles_section_test.dart
- flutter test test/settings_screen_widget_test.dart
- flutter test test/proxy_auth_operations_gateway_test.dart

Operator walkthrough (kDemoMode = true)
1. Launch ForgeFlow, sign in as the demo operator, and open Settings -> Team -> Roles.
2. Verify the role catalog renders seeded and custom roles with permission key details.
3. Create a custom role, choose permission keys, save it, and verify it appears in the catalog.
4. Grant the new role to a demo user and verify the user-facing surface availability matches the selected permissions.

Acceptance criteria
- [ ] Role catalog and editor consume the B17 /v1/admin/auth/roles gateway shape in live mode and demo fixtures in tests.
- [ ] Seeded/non-editable role protections are enforced in UI state and tests.
- [ ] Operator walkthrough completes end-to-end in demo mode.
- [ ] Walkthrough evidence is captured at docs/_walkthroughs/9.UX.2.md or attached in the execution report.
- [ ] Brand-styling acceptance: UI uses lib/theme/app_theme.dart tokens and matches existing Settings/Team surfaces.
- [ ] Permission-gating acceptance: an actor without admin.roles.view cannot see Roles; actors missing create/edit/delete/assign keys cannot perform those mutations.

When finished, report using the standard report format. UX-exposing
slices add a Walkthrough evidence line confirming the click path was
exercised (screenshot OR text trace). Do not update trackers. Do not commit.
```

### 9.UX.5 - Active Sessions Viewer

## Block 1 - Human Context

Plain English: This lane adds the Account -> Active Sessions viewer so
operators can see signed-in devices, revoke one session, or sign out all
devices. It extends the auth operations gateway with session methods and
keeps the Settings seam additive.

Lane: `9.UX.5` - worktree `.claude/worktrees/9-ux-5` on branch
`codex/9-ux-5`, to be created off master @ `4da758b`.

Important context:
- Scope is `docs/phases/phase_9/phase_9_auth_plan.md` Frontend Exposure
  row `9.UX.5`.
- Existing session ledger revoke routes are already part of Phase 9; this
  slice adds the UX and any missing list/revoke/sign-out-all gateway seam.

Current issue:
- `auth_sessions` records are written and revocable, but operators cannot
  inspect active sessions or initiate device-level revocation from Settings.

Human prerequisites:
- Setup/access needed: None for code + demo-mode acceptance. Live staging
  QA later needs a signed-in operator with multiple recorded sessions; this
  does not block the slice.
- Decision needed for this slice: No decision needed for this slice.

```text
## Block 2 - Tech Context

Authority files for this run:

- docs/phases/phase_9/phase_9_auth_plan.md - Frontend Exposure row 9.UX.5 + shared seams
- lib/services/auth/auth_operations_gateway.dart + lib/services/auth/proxy_auth_operations_gateway.dart + lib/services/auth/auth_session_ledger_writer.dart - session gateway/revoke seam
- lib/screens/settings_screen.dart + lib/screens/settings/settings_data_sections.dart - Account tab placement and existing sign-out UX

Hard constraints
- Do not update trackers.
- Do not commit unless explicitly asked.
- Do not change login, MFA, Team, role, or org hierarchy behavior.
- Additive-safe carve-out: lib/screens/settings_screen.dart may only wire the Active Sessions surface into the Account tab/section; do not reorder or rewrite existing Settings tabs.
- Additive-safe carve-out: lib/services/auth/auth_operations_gateway.dart may only add session DTOs and the listActiveSessions, revokeSession, and signOutAll methods required by 9.UX.5.
- Flutter must not read Postgres directly; session reads/writes go through the proxy/gateway seam.
- Run only required tests; no courtesy CLI smoke runs.

## Block 3 - Tasks

Files to modify
- lib/screens/settings/settings_active_sessions_section.dart (new)
- lib/screens/settings_screen.dart - additive Account/Active Sessions wiring only
- lib/services/auth/auth_operations_gateway.dart - session DTOs + listActiveSessions/revokeSession/signOutAll only
- lib/services/auth/proxy_auth_operations_gateway.dart - session HTTP client methods only
- lib/services/auth/repository_auth_operations_gateway.dart - session method implementation only
- lib/infrastructure/persistence/postgres/repositories/auth_sessions_repository.dart - active-session read projection only
- tool/advisor_proxy/advisor_proxy.dart - /v1/auth/sessions route + session method dispatch only
- tool/advisor_proxy/proxy_bootstrap.dart - session repository binding only
- test/settings_active_sessions_section_test.dart (new)
- test/settings_screen_widget_test.dart - Account tab wiring assertions only
- test/proxy_auth_operations_gateway_test.dart - session client contract
- test/proxy_auth_operations_route_test.dart - focused route coverage
- test/auth_live_binding_test.dart - repository/session projection coverage

Implementation tasks
1. Add an Account -> Active Sessions section showing device/user-agent summary, approximate location/IP metadata when available, created/last-seen times, current-session marker, and revoked state.
2. Add revoke-one-session and sign-out-all-devices actions with confirmation, busy/error states, and optimistic refresh after success.
3. Extend AuthOperationsGateway with listActiveSessions, revokeSession, and signOutAll; bind ProxyAuthOperationsGateway to /v1/auth/sessions plus the existing revoke/revoke-all semantics.
4. Ensure sign-out-all follows the established refresh-token/session revocation behavior and does not strand AuthSessionNotifier in a stale signed-in state.
5. Use stable demo fixtures so the walkthrough can show multiple devices without staging.

Required tests
- dart analyze
- flutter test test/settings_active_sessions_section_test.dart
- flutter test test/settings_screen_widget_test.dart
- flutter test test/proxy_auth_operations_gateway_test.dart
- flutter test test/proxy_auth_operations_route_test.dart
- flutter test test/auth_live_binding_test.dart

Operator walkthrough (kDemoMode = true)
1. Launch ForgeFlow, sign in as the demo operator, and open Settings -> Account -> Active Sessions.
2. Verify a device list renders with current-session and last-seen details.
3. Revoke one non-current demo device and verify it moves to revoked/removed state.
4. Use sign out all devices and verify the UI confirms all sessions are forced to re-auth.

Acceptance criteria
- [ ] Active sessions viewer reads through listActiveSessions and never directly touches storage.
- [ ] Revoke-one and sign-out-all paths call the gateway and refresh UI state after success.
- [ ] Operator walkthrough completes end-to-end in demo mode.
- [ ] Walkthrough evidence is captured at docs/_walkthroughs/9.UX.5.md or attached in the execution report.
- [ ] Brand-styling acceptance: UI uses lib/theme/app_theme.dart tokens and matches existing Account/MFA section density.
- [ ] Permission-gating acceptance: only the signed-in actor's own sessions appear; unauthenticated/no-session contexts cannot see or invoke the surface, and no cross-user revocation control is exposed.

When finished, report using the standard report format. UX-exposing
slices add a Walkthrough evidence line confirming the click path was
exercised (screenshot OR text trace). Do not update trackers. Do not commit.
```

### 11A.2 - Pricing Tier Admin

## Block 1 - Human Context

Plain English: This lane turns the Operations Console Pricing placeholder
into a live admin screen backed by `/v1/admin/pricing/*` proxy routes and
usage-cap repositories. It is independent of the Phase 9 UX lanes.

Lane: `11A.2` - worktree `.claude/worktrees/11A-2` on branch
`codex/11A-2`, to be created off master @ `4da758b`.

Important context:
- Scope is `docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md`
  sub-slice `11A.2`.
- Tier templates come from `docs/phases/phase_11a/phase_11a_decision_register.md`
  Pricing Tier Model: Pilot, Starter, Premium, Elite, Pro, Enterprise.

Current issue:
- The admin console shows a Pricing placeholder; F&F admins still lack a
  real usage-cap/tier editor over `usage_caps`.

Human prerequisites:
- Setup/access needed: None for code + demo-mode acceptance. Live staging
  walkthrough later needs `ADMIN_PROXY_BASE_URI`, a Firebase super_admin
  identity, and staging `usage_caps` rows; this does not block local/demo work.
- Decision needed for this slice: Tier-template defaults decision. If no
  new product decision is supplied before implementation, use the locked
  Pricing Tier Model as the template default source and keep Enterprise
  custom/editable rather than inventing hidden defaults.

```text
## Block 2 - Tech Context

Authority files for this run:

- docs/phases/phase_11A_operations_console/phase_11A_operations_console_plan.md - 11A.2 + Frontend Exposure
- docs/phases/phase_11a/phase_11a_decision_register.md - Pricing Tier Model + Hard Promise #9 usage_caps axes
- lib/admin/admin_routes.dart + lib/main_admin.dart + tool/advisor_proxy/advisor_proxy.dart + tool/advisor_proxy/proxy_bootstrap.dart - admin route/proxy seams

Hard constraints
- Do not update trackers.
- Do not commit unless explicitly asked.
- Admin Flutter must never access Postgres directly; all reads/writes go through /v1/admin/pricing/*.
- Do not touch operator-facing ForgeFlow/Barrio app entrypoints or Phase 9 Settings UX.
- Additive-safe carve-out: lib/admin/admin_routes.dart may only promote the Pricing route from placeholder to live and add its service lookup; do not reorder existing admin routes.
- Additive-safe carve-out: lib/main_admin.dart may only wire the pricing gateway into AdminConsoleServicesScope; do not weaken admin auth fail-closed/demo-mode behavior.
- Additive-safe carve-out: tool/advisor_proxy/advisor_proxy.dart may only add /v1/admin/pricing/* constants, dispatch, validation, CORS, and gateway interface; do not change existing /v1/admin/operators or auth routes.
- Additive-safe carve-out: tool/advisor_proxy/proxy_bootstrap.dart may only bind pricing repositories/gateway into production bindings; do not change existing auth/operator bindings.
- Tier templates must be limited to Pilot, Starter, Premium, Elite, Pro, Enterprise from the decision register.
- Run only required tests; no courtesy CLI smoke runs.

## Block 3 - Tasks

Files to modify
- lib/admin/screens/pricing_tier_admin_screen.dart (new)
- lib/admin/services/pricing_tier_admin_gateway.dart (new)
- lib/admin/models/pricing_tier_admin_models.dart (new)
- lib/admin/admin_routes.dart - Pricing route promotion only
- lib/main_admin.dart - pricing gateway wiring only
- lib/infrastructure/persistence/postgres/repositories/usage_caps_repository.dart (new)
- tool/advisor_proxy/advisor_proxy.dart - /v1/admin/pricing/* proxy routes only
- tool/advisor_proxy/proxy_bootstrap.dart - pricing repo/gateway binding only
- test/admin_pricing_tier_screen_test.dart (new)
- test/admin_pricing_tier_gateway_test.dart (new)
- test/advisor_proxy_test.dart - 11A.2 admin pricing route group only
- test/advisor_proxy_bootstrap_test.dart - pricing binding assertion only

Implementation tasks
1. Add pricing admin models/gateway with HTTP and in-memory demo implementations for listing operators, listing cap rows, editing operator subscription tier, editing cap rows, and applying tier templates.
2. Promote the Admin Console Pricing nav item from placeholder to a live screen that lists operators, current subscription tier, cap rows by usage_class, optional staff/workflow axes, monthly/per-invocation caps, and audit metadata.
3. Add inline edit/apply-template flows for Pilot, Starter, Premium, Elite, Pro, and Enterprise. Use the decision register defaults; Pro includes workflow allowance/overage rows, and Enterprise remains custom/editable.
4. Add proxy routes under /v1/admin/pricing/* with super_admin edit gating, read gating for pricing view, validation for usage_caps axes, and audit reason strings carrying actorUserId.
5. Add usage_caps repository methods through POSTGRES_ADMIN_URL/admin wrapper, preserving created_by/updated_by and never bypassing the proxy from Flutter.
6. Keep the screen visually consistent with the 11A shell and operator/location admin surface.

Required tests
- dart analyze
- flutter test test/admin_pricing_tier_screen_test.dart
- flutter test test/admin_pricing_tier_gateway_test.dart
- flutter test test/advisor_proxy_test.dart
- flutter test test/advisor_proxy_bootstrap_test.dart

Admin walkthrough (kDemoMode = true)
1. Launch the admin console in demo mode and sign in as super.admin@forgeflow.test.
2. Open Pricing, select a demo operator, and verify tier + usage-cap rows render.
3. Apply the Premium or Pro template, confirm cap rows update, then edit one usage_class cap inline.
4. Attempt the same edit as a non-super-admin/support demo identity and verify edit controls are blocked.

Acceptance criteria
- [ ] Pricing route is live in the admin nav and no longer renders the 11A.2 placeholder.
- [ ] /v1/admin/pricing/* routes cover list, tier update, cap update, and template apply without direct Flutter DB access.
- [ ] Tier templates match the decision register names and documented cap model.
- [ ] Admin walkthrough completes end-to-end in demo mode.
- [ ] Walkthrough evidence is captured at docs/_walkthroughs/11A.2.md or attached in the execution report.
- [ ] Brand-styling acceptance: UI uses lib/theme/app_theme.dart tokens and matches the 11A admin shell/operator screen.
- [ ] Permission-gating acceptance: super_admin can edit; ff_support/non-admin cannot edit; unauthenticated/non-admin callers receive 401/403 from proxy routes.

When finished, report using the standard report format. UX-exposing
slices add a Walkthrough evidence line confirming the click path was
exercised (screenshot OR text trace). Do not update trackers. Do not commit.
```

### Queued Later Batches

Do not generate these prompts yet.

Batch 2 queue:
- `9.UX.3` permission explainer
- `9.UX.6` personal audit log viewer
- `9.UX.7` self-serve password reset / recovery flow

Batch 3 queue:
- `11A.3` corpus admin
- `11A.4` integration management
- `7.58` Primary Driver audit lane. Before this slice can open, create
  `docs/phases/phase_7_58/phase_7_58_primary_driver_audit_plan.md`
  with a `Frontend Exposure` section; today the 7.58 plan is only inline
  in tracker/archive context, which would be a prompt defect.

## Lean Authority Law

`PROJECT_TRACKER.md` and `CLAUDE.md` must stay lean.

- `PROJECT_TRACKER.md` is a routing map: current phase, next slice, fetch map,
  hard gates, and pointers to active docs. It is not the full plan.
- `CLAUDE.md` is a guardrail map: durable repo rules and non-negotiables. It
  is not the place for per-slice execution detail.
- Per-slice detail, rationale, backlogs, acceptance history, and heavyweight
  context live in linked phase docs under `docs/phases/**`.
- Before generating a prompt, refactor context mentally into:
  tracker/CLAUDE = lean pointers and laws; linked phase docs = weight-bearing
  slice context.
- Do not paste phase-doc weight back into `PROJECT_TRACKER.md` or `CLAUDE.md`
  unless it is a durable routing rule, durable guardrail, or current hard gate.
- Prompt cycles may create temporary checkpoint/backlog docs for Claude's
  mega-prompt execution. Those docs carry transient weight until the phase
  slice accepts, then tracker truth is updated leanly.

## Preflight

Before every prompt, check:

1. `PROJECT_TRACKER.md` current / next slice lines.
2. The relevant section of one active planning doc under `docs/phases/**`.
3. `CLAUDE.md` only when guardrails may have changed.
4. This standard only when prompt shape is in question.

Add only when needed:

- One contract doc from `docs/contracts/` for contract-bound seams.
- `docs/DATA_ALIGNMENT_TRACKER.md` for alignment-heavy slices.
- `docs/KNOWN_FAILING_TESTS.md` for full or near-full test runs.

Read full files only for a phase primer, a new unfamiliar lane, or a disputed
authority question. Do not load archived docs unless the prompt explicitly
targets archive history.

## Phase Primer vs Slice Prompt

Use a long context block only when a phase opens or the architecture changes.
After that, generate delta prompts:

- `phase primer`: allowed to summarize goals, gates, and core docs.
- `normal slice`: human context block plus exact authority/files/tasks/tests.
- `review-fix`: finding, exact files, exact tests, no phase recap.

## Prompt Rules

Before sending the prompt:

- Omit `Slice type` for normal implementation prompts.
- Include `Slice type` only for `closeout-verification`,
  `closeout-with-blockers`, or `audit`.
- Visible authority list is 3 entries max and excludes stable docs by habit.
- `Plain English:` lives in Block 1 for the user, not in Claude's pasted
  prompt.
- Do not add a separate `Goal` section.
- Do not include optional / "only if touched" files.
- Files over 500 lines have method or region qualifiers.
- Blocks 2 and 3 together target 40 lines for review-fixes, 50 for normal
  slices.
- Deliver Block 1 separately as normal Markdown, then deliver Blocks 2 and 3
  together in one fenced `text` block for one-click Claude copy/paste.
- Never put Block 1 in Claude's paste block, and never split Blocks 2 and 3
  into separate paste blocks.
- Block 1 must include `Human prerequisites:` before the paste block. If the
  slice may require keys, accounts, cloud projects, CLI installs, dashboard
  setup, tokens, billing setup, or live-service access, name the exact human
  action needed and whether it blocks this slice or the next one. If none are
  needed, say `None for this slice`.
- Block 1 must include a `Lane:` line naming the worktree path, branch,
  and base sha (or "to be created"). Skip only if the slice runs on master
  in a non-parallel session.
- Inside `Human prerequisites:`, also include `Decision needed for this slice:`.
  This names what the user must decide now based on documented constraints,
  gates, guardrails, blockers, live-service availability, or architecture
  trade-offs. If no decision is needed, say `No decision needed for this
  slice`. Do not let Claude implicitly decide product, infrastructure, cost,
  security, or sequencing trade-offs.
- Do not restate architecture already in `CLAUDE.md`.
- Do not move per-slice detail into `PROJECT_TRACKER.md` or `CLAUDE.md`;
  reference the active phase doc instead.
- Contract-bound slices include `Routing rules to mirror`: 2 or 3 rules max.
- Move slices include Codex's import audit and analyzer-forced follow-ups.
- Use `Files to leave alone` only for real carve-outs.
- Required tests and acceptance criteria are explicit.
- Always tell Claude: no tracker updates, no commits.

Rule failure is a prompt defect. Fix it before sending.

## Ownership

Codex owns:

- Roadmap, phase breakdown, prompt scope
- Acceptance criteria and verification
- Tracker truth
- Gate truth and release-readiness judgment

Claude owns:

- Implementation inside the scoped prompt
- Localized refactors inside scope
- Requested tests and docs
- Execution report

Standing rules:

- Claude does not update trackers unless explicitly asked.
- Claude does not broaden scope or redefine architecture.
- Codex updates trackers after verification, not before.
- Tracker truth must never be ahead of repo truth.

## Slice Prompt Blocks

Codex emits three blocks:

- **Block 1 — Human Context:** plain-English summary, important context, and
  current issue. Routing rules may appear here when useful for the user. The
  user reads this and does not paste it to Claude.
- **Block 2 - Tech Context:** authority files and hard constraints.
- **Block 3 - Tasks:** files, implementation tasks, tests, acceptance.

Block 1 always includes a `Human prerequisites:` subsection so the user knows
whether keys, accounts, cloud setup, CLI installs, dashboard setup, tokens, or
live-service access are needed before the current or next slice, and what
decision the user must make now based on documented constraints, gates,
guardrails, blockers, live-service availability, or architecture trade-offs.

Blocks 2 and 3 are the full Claude contract. Do not rely on Block 1 for
instructions Claude must follow.

Deliver this as two visual parts:

1. Block 1 appears as normal Markdown for the user. It starts with
   `Plain English:` rather than a prompt-id line.
2. Blocks 2 and 3 appear together inside one fenced `text` block. This is the
   single paste payload for Claude.

Use this shape:

## Block 1 — Human Context

Plain English: [1 to 3 concise sentences; include an example when helpful]

Lane: [slice-id] — worktree [.claude/worktrees/<lane-name>] on branch
[branch-name] off master @ [short-sha].
[If the lane is not yet created, say "to be created off master @
<short-sha>" — Claude creates the worktree before starting.]

Important context:
- [only what helps the user understand the slice]

Current issue:
- [what is missing, stale, or broken]

Human prerequisites:
- Setup/access needed: [None for this slice, or exact
  keys/accounts/cloud/CLI/dashboard setup the human must handle; say whether it
  blocks this slice or a later slice]
- Decision needed for this slice: [No decision needed for this slice, or the
  exact user decision required by documented constraints, gates, guardrails,
  blockers, live-service availability, architecture, cost, security, or
  sequencing trade-offs; say whether it blocks this slice or a later slice]

Routing rules to mirror:
- [only when contract-bound and useful for the user; 2 or 3 rules max]

```text
## Block 2 - Tech Context

Authority files for this run:

- [specific runtime files / tests]
- [active phase doc section, only when needed]

Hard constraints
- Do not change business logic, target math, or labor formulas unless that is the goal.
- Do not add live vendor transport unless that is the goal.
- Do not update trackers.
- Do not commit unless explicitly asked.
- Run only required tests; no courtesy CLI smoke runs unless explicitly scoped.

## Block 3 - Tasks

Files to modify
- [file or file - region/method]

[Optional] Files to leave alone
- [omit unless there is a specific carve-out]

Implementation tasks
1. ...
2. ...

Required tests
- dart analyze
- [focused test files]

[Required for UX-exposing slices] Operator walkthrough (kDemoMode = true)
1. [exact click path that exercises the new surface]
2. [expected outcome at each step]

Acceptance criteria
- [ ] [checkable criterion]
- [ ] [for UX slices] Operator walkthrough completes end-to-end in demo mode
- [ ] [for UX slices] Permission gating verified: user without <key> cannot see surface
- [ ] [for UX slices] Brand styling matches lib/theme/app_theme.dart

When finished, report using the standard report format. UX-exposing
slices add a `Walkthrough evidence` line confirming the click path was
exercised (screenshot OR text trace).
```

Use repo-root-relative paths. Add repo root only for external handoffs.

## Visible Authority

- Codex always reads `PROJECT_TRACKER.md`; list it in Claude prompts only
  when the slice changes tracker truth or needs a live gate checked.
- Include an active phase doc/section only when the slice needs it.
- Include at most one contract doc.
- Do not load a contract doc and its plain-English companion together.
- Do not load prior-slice docs unless the current slice depends on a live
  drift table, schema delta, or constraint from that doc.
- Do not put this standard in execution prompts unless the work is workflow.

Use graphify only for unfamiliar architecture/concept orientation. For known
symbols, imports, callsites, and filenames, use `rg`; do not add graph
pre-search hints.

## File Scoping

Use narrow file targets:

- Good: `sqlite_database_seed.dart - _seedDemoDataFromReplay() only`
- Good: `shift_service.dart - getFullWeekShifts + helper only`
- Bad: `shift_service.dart` when the file is over 500 lines

For any file over 500 lines, method or region scoping is required.

## Move Slices

Structural file-move slices are mechanical: move files, rewire imports,
no behavior change. Codex pre-computes the import audit and passes it through.
Claude does not re-grep imports unless the audit is missing or analyzer output
proves it stale.

For each moved file, list same-directory relative imports and classify each
target as `MOVES` or `STAYS`, plus the implied rewrite:

```text
Implementation tasks
1. Move <file> to <new dir>. Internal imports:
   - 'sibling_a.dart'  (MOVES with this slice): keep same-dir
   - 'sibling_b.dart'  (STAYS in <old dir>):    rewrite to '../<old dir>/sibling_b.dart'
   - '../foo/bar.dart' (cross-package, unchanged)
```

When the moved target is imported by a file that otherwise stays out of
scope, name the exact import-declaration follow-up:

```text
Implementation tasks
3. Update lib/data/target_cycle_service.dart (>500-line stayer):
   - line 55: 'baseline_manager_service.dart'             -> '../services/baseline_manager_service.dart'
   - line 56: 'baseline_selection_analytics_service.dart' -> '../services/baseline_selection_analytics_service.dart'
   - body otherwise left alone
```

Stale doc-comment path strings in leave-alone files (e.g. comments
pointing at a moved file's old path) are in scope for cleanup as long as
no behavior or assertion semantics change. The slice acceptance criteria
should call this out explicitly when known stale comments exist.

## Routing Rules

Include `Routing rules to mirror` when the slice touches:

- `TargetCycle`, `WeeklyPlanSnapshot`, or `BenchmarkSelectionSummary`
- Plan / benchmark / labor ownership
- Replay-stable artifacts
- Source facts vs derived signals
- Business date, week start, or service-period resolution

Skip it for doc-only, pure UI, or read-only verification slices unless the
verification itself is contract-bound.

## Slice Types

`implementation`

- Default. Omit the `Slice type` block. Requires focused tests.

`closeout-verification`

- Read-only verification. May update doc status if requested. Does not fix
  blockers.

`closeout-with-blockers`

- Verification plus bounded fixes. Prompt names eligible files and max blast
  radius.

`audit`

- Drift check only. Produces findings or a follow-up plan. No implementation
  changes unless explicitly scoped.

## Sub-Slices

For parent slices split into `a`, `b`, `c`:

- Track acceptance at the sub-slice level.
- Do not mark the parent slice complete until the final sub-slice satisfies
  the parent acceptance criteria.
- Generate the next prompt from the latest accepted sub-slice, not from the
  original parent description.
- Keep parent gates intact. Example: `7.57.2` cannot open until all remaining
  `7.57.1*` extraction sub-slices accept.

## Review Handoff

When Claude reports:

1. Inspect the changed files directly.
2. Confirm claimed "left alone" files are actually untouched.
3. Check acceptance criteria against repo content.
4. Confirm test evidence.
4.5. For UX-exposing slices: confirm walkthrough evidence is present
   (screenshot or text trace describing each step's outcome). Absent
   walkthrough on a UX-exposing slice = `FOLLOW-UP NEEDED`.
5. Run a small targeted rerun only when needed.
6. Return findings if there are issues.
7. If clean, update trackers and generate the next prompt.

Codex verifies repo truth, not report wording.

Do not use `git stash` during verification. Prefer:

- `git diff HEAD -- <file>`
- `git status --short`
- `rg` for imports/callsites
- targeted test reruns when evidence is incomplete

Verdicts:

- `ACCEPT`
- `FOLLOW-UP NEEDED`
- `REJECT`

## Test Reruns

Codex does not rerun Claude's tests by default. Rerun only when:

- The user asks.
- The report is missing test evidence.
- The reported tests do not match the prompt.
- The diff makes the report doubtful.
- A known risky seam needs local confirmation.

Prefer the smallest targeted rerun.

## In-Session Hygiene

- For known large files, read by named region or offset/limit instead of full
  file.
- When adding to an existing test file, grep for the insertion anchor first
  and offset/limit-read a window (~50 lines) around it. Full reads of
  500+ line test files are the single most expensive avoidable cost.
- Tail test output aggressively; the final pass/fail lines are usually enough.
- Batch independent reads / greps in one tool call.
- Skip courtesy CLI smokes when analyze and focused tests cover the contract.
- Keep execution reports compact. Add reviewer notes only for real surprises.
- Do not call or acknowledge TodoWrite. The prompt's task list is the source
  of truth.

## Tracker Updates

After accepting a slice:

- Update `PROJECT_TRACKER.md` current / next / hard-gate wording.
- Update `docs/DATA_ALIGNMENT_TRACKER.md` only for alignment-heavy slices.
- Do not move tracker truth ahead of repo truth.
- Do not advance the parent phase if only a sub-slice accepted.

## Commit Cadence

- Commits happen at phase close unless the user says otherwise.
- Execution prompts should say `Do not commit unless explicitly asked`.
- Do not include commit, push, or graphify steps in execution prompts.
- If Markdown changed and `graphify-out/needs_update` appears later,
  `CLAUDE.md` owns that flag workflow.

## Report Format

Claude should report:

```text
## Execution Report - [Prompt ID]

### Files changed
- [file]: [what changed]

### Files left alone
- [optional; only if a prompt listed carve-outs or something tempting was verified]

### Tests run
- dart analyze: [result]
- [test file]: [pass count] passed

### Acceptance criteria
- [x] [criterion]

### Scope check
- No tracker changes: [yes/no]
- No other-phase work: [yes/no]
- No unauthorized commits: [yes/no]
- Links updated: [yes/no, only if docs changed]

### Blockers
- [none or blocker]

### Status
[complete / follow-up needed]
```

Do not include `Out-of-scope touched: None` or similar boilerplate. Report
out-of-scope touches only when there was something to explain.

### Report Compression Rules

The fields above are the contract. Past that, default to compression:

- **Bare filenames over decorative markdown links.** `tool/x/y.dart: added
  Z` is preferred over a `[y.dart](path:line)` link unless the user is
  reviewing in a renderer that needs the link.
- **No "Notes for reviewer" section** unless something genuinely
  surprised you (a workaround, an unexpected blocker, a non-obvious
  trade-off the diff alone does not explain).
- **No "Out of scope (not touched)" list** when the prompt's hard
  constraints already covered it. The `Scope check` yes/no flags above
  are sufficient.
- **No restating slice ID inside every section.** Once in the header
  is enough; comments, test group names, and route notes can use it
  but the report itself does not need to repeat it per bullet.
- **No restating prompt language.** "I did not call live providers, I
  did not change SQLite" wastes tokens; the constraint list above
  already promised that. Flag exceptions, not compliance.

The floor: tests run, acceptance ticked, files listed with a brief
description, links to changed files (or bare paths). Cutting below this
breaks the tracker advance loop or makes review hard.

## Do Not Cut

When making prompts shorter, never cut:

- Tracker-first phase control
- Hard constraints
- Required tests
- Explicit acceptance criteria
- Repo verification before tracker updates
- No-commit / no-tracker-change instructions for Claude
