# debug.md Implementation Status Tracker

> **Created:** 2026-05-13, post-Codex wave closeout (master tip `7a240b0d`).
> **Owner:** orchestrator drafts; operator validates.
> **Purpose:** map every item in the operator's brain dump (`debug.md` at
> repo root) to a current implementation state, so the doc becomes the
> punch-list for Step 1 (demo-validate) and the launchpad for the next
> wave of planning in `NEXT_WAVE_PLAN.md`.

## Executive summary

Roughly **40%** of the brain-dump items are implemented in code or
docs (the post-Codex wave delivered the full hierarchy/auth backbone,
the catalog-driven email + inbox pipeline, the adaptive 2FA flow, the
master Demo-Live switch, default role catalog admin, and B8/B8.b
audit-log hierarchy filtering). Roughly **35%** is partially landed —
the surface exists but the operator's specific UX polish (subtitle
removal, copy rewording, top-tile removal, scope-sensitive labels, HP
#11 inheritance display, hierarchy-tree visualization on identity
pages, edit-user write paths) is not done. The remaining **25%** is
not started: the formal scaffold audit / orphan-template purge, the
soak-and-pressure-test harness extensions, the role-categorization
product split, the change-email/name write paths, mobile integration
status tab, settings reorder, and the runbook/SOP/vendor-outreach
preparation work. Biggest open buckets are **(1) UX polish across all
14 Ops Console screens** (mostly subtitle/tile/label cleanup),
**(2) write-path completeness for profile + members editing**, and
**(3) email/notification pressure-test capability**.

## Cross-reference table

| Doc | Role |
|---|---|
| `debug.md` (repo root) | Master brain dump — the source for every row in this tracker |
| `docs/_indices/NEXT_WAVE_PLAN.md` | 5-step pipeline (demo-validate → tag → R-1/R-2 refactor → re-test → mutate) |
| `docs/_audits/post_codex_wave/c_12_lane_c_closeout_audit.md` | Wave closeout that enumerates the 60 merged slices and 5 follow-up bugs/findings |
| `docs/POST_HARDENING_FOLLOWUPS.md` | Migration apply queue + outstanding architecture follow-ups (B-1, B-2, R-1, R-2, W-1, W-2) |
| `docs/_audits/post_codex_wave/wave_audit_*.md` | 9 dimensional audits (auth/RLS, migrations, proxy, operator-web UX, demo mode, honest disclosures, doc drift, cross-slice, test coverage) |
| `docs/contracts/core_app_architecture.md` | Authority #2 in CLAUDE.md — Phase 7.55 architecture; binds Layers 1-12 |
| `CLAUDE.md` "Workflow" + "Hard Promises" | Codified workflow (already absorbs the operator's "how I run it" section) |

## Status legend

- ✅ **DONE** — implemented in code/docs. Citation provided.
- 🚧 **IN PROGRESS** — surface exists but operator-specific polish/wire is missing.
- ❌ **NOT DONE** — not addressed. Suggested next-wave slot noted.
- 🔍 **NEEDS VERIFICATION** — declared done by an artifact, but operator hasn't walked through. Target Step 1.

---

## Workflow — "how I run it"

The operator's intro (`debug.md:1-11`) describes the parallel-lane
worktree + audit-and-merge + index-doc pattern. This is **already
codified verbatim** in `CLAUDE.md` "Workflow" + "Agent-led slices" +
`docs/CODEX_PROMPT_GENERATION_STANDARD.md` + the loop-mode handoff
prompts at `docs/_indices/CLAUDE_HANDOFF_PROMPT.md` +
`docs/_indices/CODEX_HANDOFF_PROMPT.md`.

| Brain-dump ask | Status | Citation |
|---|---|---|
| "Plan, research, read back in plain English, zoom out for code changes" | ✅ DONE | CLAUDE.md "Review Loop" + the executor-as-mini-orchestrator pattern |
| "Launch multiple agents across all layers using feature framework" | ✅ DONE | `docs/frameworks/FEATURE_IMPLEMENTATION_LENS_AUDIT_FRAMEWORK.md`; CLAUDE.md "Workflow" |
| "Save in multiple docs for parallel split execution between Codex and Claude" | ✅ DONE | `docs/_indices/{CLAUDE,CODEX}_HANDOFF_PROMPT.md`; `docs/_indices/WAVE_EXECUTION_LEDGER.md` (ledger as work queue) |
| "Main instructs agents in worktrees, assigns tasks, audits, sends back with bugs and gaps" | ✅ DONE | CLAUDE.md "Agent-led slices: no auto-merge" + "Audit First, Then Commit + PR + Merge" |
| "Auto commit and merge with origin" | ✅ DONE (audited PRs only) | Memory: "Orchestrator Auto-Merges Audited-Approved PRs" (from 2026-05-13) |
| "Code-health first, then features on a solid base" | 🚧 IN PROGRESS | The post-Codex wave did 17 Lane A code-health slices; **R-1 + R-2 refactor still queued** per `POST_HARDENING_FOLLOWUPS.md` "Refactor phase scope". Target: Step 3 (R-1/R-2). |
| "2 prompts — one for Codex lane, one for Claude lane, both indexed to project tracker" | ✅ DONE | The 2 handoff prompts above; `PROJECT_TRACKER.md` indexes both |

---

## Bugs (debug.md:14-17)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| BUG-1 | "Proxy returned an incomplete session record sign-in after support check" | ❌ NOT DONE | Not reproduced/triaged. **New slice — "Proxy sign-in support-check session-record fix"**. Likely related to support-impersonation path through `tool/advisor_proxy/auth_step_up_routes.dart` + `support_operator_view_admin_screen.dart`. Targets Step 5a (pre-deploy fixes). |
| BUG-2 | "Proxy crashed after some time — debug" | ❌ NOT DONE | No known triage doc. **New slice — "Proxy crash triage"**. Likely needs A11.2-style heap-snapshot/forensic kit + log review. Targets Step 5a or a dedicated soak follow-up. |
| BUG-3 | "Time pressure test — live usage for hours, multiple sessions" | 🚧 IN PROGRESS | A11.2 (PR #537) shipped the storage-agnostic heap-snapshot uploader + fd watcher + p3c CLI flags. **Soak harness exists; uploads are inert until Azure swap lands** per `POST_HARDENING_FOLLOWUPS.md` "Soak Heap-Snapshot Uploader: swap GCS → Azure Blob". Targets a new slice "soak harness — Azure Blob swap". |

---

## Hierarchy (debug.md:20-25)

The operator's directive is: "every bit of info/functionality on
screen has to be wired this way end-to-end AND presented the same
consistent way." This is HP #11 (Hard Promise #11 in CLAUDE.md).

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| H-1 | "Every screen item must show scope, inherited source, effective value (HP #11)" | 🚧 IN PROGRESS | **L_A1 / L_A2 / B6 / B8 / B8.b / C-6 / B5.b** shipped the backbone. **6 operator-web screens are exemplars** (`business_setup_screen.dart`, `business_timing_editor_screen.dart`, `data_accuracy_screen.dart`, `settings_notifications_screen.dart`, `admin_timing_setup_screen.dart`, `audit_log_admin_screen.dart`). **2 screens still miss the triple** — `schedule_screen.dart` (629 LoC) + `wage_authority_screen.dart` (907 LoC), tracked as M-4 in `c_12_lane_c_closeout_audit.md`. Targets Step 5a fix or a new "HP #11 sweep" slice. |
| H-2 | "Master list and end-to-end implementation plan for hierarchy" | ✅ DONE | `docs/_execution/lane_b_features/01_*.md` through `04_*.md` are the canonical execution plan; ledger row 100 (C-12 closeout) certifies the backbone is shipped. |

---

## Roles and Permissions (debug.md:26-43)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| RP-1 | "Audit of permissions / roles — what's implemented, exposed, where?" | ✅ DONE | `docs/contracts/auth_permission_key_catalog.md` (canonical catalog); `lib/auth/permission_keys.dart` (frozen mirror); `permission_explainer_screen.dart` renders the catalog with category groupings. PR #481 retroactive audit re-confirmed. |
| RP-2 | "What seeded roles exist and what capabilities they carry; is ReBAC done?" | 🚧 IN PROGRESS | B2.1/B2.2/B2.3 shipped the **Default Role Catalog** with versioning + admin publish surface (`default_role_catalog_admin_screen.dart`). ReBAC posture validated by wave auth audit. **Operator decision still open**: confirm the published default set matches Vanessa's intent. Targets Step 1 (demo-validate). |
| RP-3 | "Suggest seeded roles based on audit" | ❌ NOT DONE | No seeded-role redesign proposal exists. **New slice — "Default Role Catalog v2 redesign"** (post demo-validate). |
| RP-4 | "Are roles applied via hierarchy/inheritance like other settings? Does UX match?" | 🚧 IN PROGRESS | Roles ARE operator-wide (per `01_product_rule_and_ia.md`), not hierarchy-scoped — that's a product decision, not a gap. The UX does NOT visualize this in the role surfaces. **Operator decision**: keep operator-wide or extend to hierarchy. |
| RP-5 | "Role name auto-populates role_key (no user-facing role_key field)" | 🚧 IN PROGRESS | `roles_screen.dart` + `custom_role_editor_screen.dart` use the role name in UX. Per debug.md:166: "Remove the role key UX if it has not been removed yet" — **needs verification this is fully gone from `custom_role_editor_screen.dart`**. 🔍 NEEDS VERIFICATION. |
| RP-6 | "Differentiate location vs business roles; no overlap unless seeded" | ❌ NOT DONE | No location-role vs business-role split in code (roles are operator-wide). **Needs operator decision** before slicing. |
| RP-7 | "Rename seeded roles to Default roles across all consoles" | 🚧 IN PROGRESS | Admin console says "Default Role Catalog". `roles_screen.dart` shows "Default" badge per worker notes. **Mobile + label sweep across all surfaces** needs verification. 🔍 NEEDS VERIFICATION. |
| RP-8 | "Display only name + short description + edit button after creation" | ❌ NOT DONE | `roles_screen.dart` currently shows more than name + description per F-OW-1 LoC dashboard. **New slice — "Roles screen UX simplification"**. Targets Step 5a or a new UX slice. |
| RP-9 | "Admin can edit Default-role permissions across F&F; this itself is a permission" | 🚧 IN PROGRESS | `default_role_catalog_admin_screen.dart` + publish dialog ship the admin edit path. **Permission key for it**: check `team.roles.default_catalog.edit` or similar. 🔍 NEEDS VERIFICATION. |
| RP-10 | "Invite team member location assignment changes to hierarchy-type assignment" | 🚧 IN PROGRESS | `invite_member_dialog.dart` + `invite_member_admin_dialog.dart` exist. **Hierarchy-tree picker vs flat list** needs verification per HP #11 mandate. 🔍 NEEDS VERIFICATION. |
| RP-11 | "Edit user button (not 3-dot) — can change email, name, role, hierarchy, end-to-end" | ❌ NOT DONE | `members_screen.dart` (1,611 LoC) has the 3-dot pattern per F-OW-1. **No change-email or change-name write path exists end-to-end**. New slice — "Members edit-user write path (email + name + role + hierarchy)". Targets a dedicated new slice. |
| RP-12 | "Permission to access Ops Console vs Admin Console (product access)" | 🚧 IN PROGRESS | `permission_keys.dart` has keys; `permission_explainer_screen.dart` is categorized. **No "product access" UX category yet**. New slice — "Roles by product → functionality categorization UX". |
| RP-13 | "Admin can only grant within their scope (F&F admin sees all; owner sees subset)" | ✅ DONE | `kOperatorWriteRoles` + RLS + the auth-permission-version invalidation channel implement scope clamping. Wave audit (`wave_audit_auth_rls_permissions.md`) verified zero cross-tenant leaks. |
| RP-14 | "Roles categorized by product, then by functionality within each product; dependency auto-add" | ❌ NOT DONE | No product-categorized role taxonomy in code or UX. **New slice — "Role categorization by product + dependency auto-select"**. |
| RP-15 | "Benchmark override ability — manager once, admin can undo, both consoles + mobile UX" | 🚧 IN PROGRESS | B6 + `operator_benchmark_overrides_routes.dart` + `benchmark_override_resolver_test.dart` ship the override + audit chain. **Manager-once cap + admin-undo UX** needs verification. 🔍 NEEDS VERIFICATION. |
| RP-16 | "Pending invites cancel button — wired end-to-end including Firebase API" | ❌ NOT DONE | Searched for cancel-invite keyword: no matches in `members_screen.dart` cancel write path. **New slice — "Cancel pending invite end-to-end"**. |
| RP-17 | "Applies to both consoles unless specified" | (meta-rule) | Bound to RP-1..16 above. |

---

## Profile (debug.md:45-52)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| P-1 | "Profile changes all user own details, wired end-to-end" | ❌ NOT DONE | `my_account_screen.dart` (2,051 LoC) shows profile data. **No change-email + change-name write path**. Targets a new slice "Profile self-service write paths". |
| P-2 | "Remove the 'display name, email...' subtitle" | ❌ NOT DONE | `my_account_screen.dart` still has profile subtitle. UX cleanup. Targets Step 1 verification + new UX slice. |
| P-3 | "Logic to change account details lives here, NOT in mobile app" | ❌ NOT DONE | Mobile `settings_screen.dart` still has the same fields. Direction is "make mobile read-only; ops-web is editor". Targets new slice "Mobile account section → read-only with deep link to ops-web". |
| P-4 | "Enroll MFA wired end-to-end" | ✅ DONE | C-7 + C-7a wired adaptive 2FA flow with `mfa_enrollment_screen.dart` + `mfa_factor_dialog.dart` + the `recovery_codes_viewed_at` column. Per `c_12_lane_c_closeout_audit.md` "C-7's adaptive label covers all states." |
| P-5 | "Same My Account tab on operator web AND admin web for that user; admin doesn't have one currently" | ❌ NOT DONE | `lib/admin/` has no `my_account_screen.dart`. **New slice — "Admin console My Account parity"**. |

---

## Audits and Logs (debug.md:53-56)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| AL-1 | "Hierarchy logic applies to audit hash/log chains — better log filtering" | 🚧 IN PROGRESS | B8 + B8.b shipped the hierarchy filter on the audit log (admin + operator web). **Hash-chain partitioning per-hierarchy-scope** — the audit chain is operator-scoped (per `audit_logs_repository.dart`); per-hierarchy-scope partitioning is NOT done. Targets a new slice "Audit chain hierarchy projection" — likely post-V1. |

---

## Emails and Notifications (debug.md:57-67)

This is "Brian Computer" in the brain dump.

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| EN-1 | "Audit all email + notification capabilities BEFORE planning tests" | 🚧 IN PROGRESS | `docs/_audits/code_health/c_email_notification_scenario_inventory.md` is the inventory; `02_plumbing_audit_matrix.md` is the gap inventory. **Half done** — the inventory exists; the operator hasn't been read back the plain-English summary. Targets Step 1 (read-back). |
| EN-2 | "Of 9 email templates, only 3 wired; 6 are scaffold (markdown w/ doc string)" | 🚧 IN PROGRESS | Per `c_12_lane_c_closeout_audit.md`: C-2-C + C-2-D + C-2-F wired 3 more templates; A1 + E + G deleted; B deferred to code-health. **Net: 6 of 9 either wired or explicitly resolved.** Per debug.md:319 "scaffold audit lane in the code-health wave is the right response" — the scaffold audit lane is **NOT YET planned as a slice**. Target: new slice "Scaffold audit lane — orphan template + dispatcher purge". |
| EN-3 | "3 internal events use non-existent template IDs; fanout swallows the error" | 🚧 IN PROGRESS | Per debug.md:315-316. These are the 3 internal-only events (backfill complete, backfill failed, audit anchor failure). C-2-D-binding handled the vendor sync error pathway. **Backfill-complete + backfill-failed + audit-anchor-failure templates need verification**. 🔍 NEEDS VERIFICATION. |
| EN-4 | "Every operator invite uses Firebase password-reset email, not dedicated invite template" | 🚧 IN PROGRESS | `password_reset_gateway.dart` is the live path; `user_invite_service.dart` exists alongside. **Dormant invite template needs to be wired OR deleted**. Targets the scaffold-audit slice. |
| EN-5 | "Deep pressure test — live device, ops web, admin web, all scenarios, all loopback chains" | ❌ NOT DONE | Per `c_12_lane_c_closeout_audit.md` "E2E testing" — orchestrator could not stand this up autonomously (Patrol not in pubspec; Mailosaur env not wired; no production deploy). **debug.md:323-325** prescribes the ~10 engineer days + ~$200/mo tooling. Targets Step 5d (post-Production1 deploy) + a new slice "Email/notification soak harness — Patrol + Mailosaur + Firebase Test Lab". |
| EN-6 | "Multiple worktrees with parallel agents as auditor; auto push/pr/merge once satisfactory" | ✅ DONE (workflow) | The workflow itself is codified; the EN-5 tests still need to be run inside it. |

---

## Admin Console UX (debug.md:69-80)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| AC-1 | "Actor and actor_kind labels — make them user/restaurant friendly" | 🚧 IN PROGRESS | C-9/C-10 catalog-driven inbox + admin-side parity ship cleaner human labels; `lib/admin/admin_human_labels.dart` exists. **Audit pass for actor_kind specifically** — not done. Targets a new slice "Admin actor/actor_kind label sweep". |
| AC-2 | "Role product rules — if can manage members → include team.users.view; warn about orphan combos" | ❌ NOT DONE | No orphan-permission warning in `custom_role_editor_screen.dart`. **New slice — "Custom role editor — orphan permission lint + product-rule warnings"**. |

---

## Questions / Implementation Details (debug.md:82-97)

These are mostly operator questions that require answers + then potentially new slices.

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| QI-1 | "Audit code vs docs — no scaffold anywhere" | 🚧 IN PROGRESS | The post-Codex wave's honest-disclosure audit (`wave_audit_honest_disclosures.md`) verified 92% of disclosures tracked. **No formal "scaffold audit" lane** — overlaps with EN-2. Targets the scaffold-audit slice. |
| QI-2 | "What's the SQLite refresh rate? Should be as live as vendor polling/webhooks allow" | 🚧 IN PROGRESS | Phase 8 polling cadence is per-vendor in `polling_and_pricing_admin_screen.dart`. **Operator-facing explanation** is in `data_accuracy_screen.dart` but Vanessa says she needs an explanation read-back. Targets Step 1 read-back. |
| QI-3 | "What event/realtime is configured per architecture.md?" | 🚧 IN PROGRESS | The realtime spine (NOTIFY channels) is in `db/migrations/*notify*` migrations and `lib/services/sync/sync_proxy_client.dart`. **Operator read-back** not done. Targets Step 1. |
| QI-4 | "Turn framework docs under frameworks/ into runbooks; update PROJECT_TRACKER + CLAUDE.md refs" | ❌ NOT DONE | `docs/frameworks/` exists; `runbooks/` exists. **No conversion sweep**. Targets a new low-priority slice or housekeeping bundle. |
| QI-5 | "Scripts for automation — cleanup, archiving, debugging, auditing per agent work" | 🚧 IN PROGRESS | `scripts/install_git_hooks.ps1`, `tool/migration_*_lint.dart`, `tool/advisor_proxy_size_lint.dart` etc. exist. **No central agent-self-audit script.** Targets a new slice. |
| QI-6 | "Proper schema versioning + migration system so nothing lost" | ✅ DONE | `tool/migration_drift_scanner.dart` + `tool/migration_cutoff_lint.dart` + index-leading-column lint + RLS-policy lint. CLAUDE.md "Workflow" codifies the post-migration sweep. |
| QI-7 | "Audit data models — overfetching, sync bottlenecks, no caching, bad indices, expensive fetches" | 🚧 IN PROGRESS | A4.2 (perf-fix slice) + index-leading-column lint shipped. **No formal "data model audit" doc**. Targets a new slice "Phase 10b perf-and-overfetch audit" (was previously in 10b phase; status uncertain post-pause). |
| QI-8 | "Audit proxy health + expose UI under System Health tab" | 🚧 IN PROGRESS | `health_admin_screen.dart` (1,303 LoC) exists. **Proxy-health-as-a-tile** verification needed. 🔍 NEEDS VERIFICATION. |
| QI-9 | "Tests grouped + conclusive; same for git workflow tests" | 🚧 IN PROGRESS | 65 wave-new test files; full pyramid coverage. KNOWN_FAILING_TESTS lists known failures. **CI dark until 2026-06-01** per `feedback_ci_dark_until_2026_06_01.md`. Targets Step 4 + CI reactivation. |
| QI-10 | "Begin SOPs" | ❌ NOT DONE | No SOP doc exists. **New slice — "Operator SOP authoring"**. Post-V1 deploy. |
| QI-11 | "Begin vendor outreach" | ❌ NOT DONE | Per `project_phase_8_engineer_all_17_doctrine.md` the live-rollout sequence is set up but outreach is operator-owned. Targets post-V1 deploy. |

---

## Ops Console UX (debug.md:100-256) — 14 screens

Per the operator's mandate at debug.md:114: "For 2-4 first finish the
admin console fully and make sure I am happy with all functionality
then translate that into this over here." That means the admin-side
parity work is the upstream gate.

### 0) Login screen (debug.md:102-107)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-0a | "Get rid of green sign-in logo/icon" | ❌ NOT DONE | UX. `sign_in_screen.dart`. Targets a new "Ops console UX polish — Login" slice. |
| OW-0b | "Get rid of subtitle 'Use the same Forge & Flow operator account...'" | ❌ NOT DONE | `sign_in_screen.dart:74-75` still has the subtitle. Same slice as OW-0a. |
| OW-0c | "Top bar bigger; admin sign-out + user email bigger; location selector shows hierarchy MAP not list" | ❌ NOT DONE | UX. Top bar redesign + hierarchy-tree picker for location selector. **New slice — "Top bar + location selector hierarchy redesign"**. |

### 1) Schedule (debug.md:110-112)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-1 | "Explain what Schedule is + full functionality in code" | 🚧 IN PROGRESS | `schedule_screen.dart` (629 LoC) + `schedule_forecast_notifier.dart`. **Operator read-back** not done. Targets Step 1. |

### 2) Business Account (debug.md:116-124)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-2a | "Audit of what's NOT exposed vs editable in setup; 1:1 admin-to-ops translation" | ❌ NOT DONE | No such audit doc. **New slice — "Business account / setup field-coverage audit"**. |
| OW-2b | "Hierarchy-sensitive label + functionality (location identity ≠ business identity)" | 🚧 IN PROGRESS | `business_setup_screen.dart` + `account_screen.dart` carry the hierarchy chain. **Label scope-sensitivity** needs verification. 🔍 NEEDS VERIFICATION. |
| OW-2c | "Remove subtitle 'these are the basics...' + 4 top tiles" | ❌ NOT DONE | UX. Targets ops-console UX polish slice. |
| OW-2d | "Logo in PNG; replace console header logo + mobile dashboard header" | ❌ NOT DONE | No logo upload write path verified in `account_screen.dart`. **New slice — "Business logo upload + propagation"**. |
| OW-2e | "Business identity hierarchy-sensitive (location-level → location identity)" | 🚧 IN PROGRESS | Same as OW-2b. |
| OW-2f | "Explain locale + how it affects everything" | 🚧 IN PROGRESS | `account_screen.dart` likely has locale field. **Operator read-back** not done. Targets Step 1. |
| OW-2g | "Some location/business settings not exposed (e.g. timezone)" | ❌ NOT DONE | Searched `account_screen.dart` for timezone — 0 matches. **New slice — "Account screen — timezone + missing-field exposure"**. |

### 3) Business Setup (debug.md:127-140)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-3a | "Hierarchy-smart with dependency rules + tab names reflecting hierarchy level" | 🚧 IN PROGRESS | `business_setup_screen.dart` is an exemplar per F-OW-2. **Scope-sensitive tab names** not verified. 🔍 NEEDS VERIFICATION. |
| OW-3b | "Remove subtitle + rename 'edit timing' to 'Edit Time Settings' (bigger)" | ❌ NOT DONE | UX. |
| OW-3c | "Explain Schedule timing" | 🚧 IN PROGRESS | Operator read-back. Targets Step 1. |
| OW-3d | "Remove 4 scope/effective tiles" | ❌ NOT DONE | UX. |
| OW-3e | "Inheritance more visual (hierarchy tree, not labels)" | ❌ NOT DONE | The existing inheritance card is text-based. **New slice — "Inheritance tree visualization on business_setup_screen + business_timing_editor_screen"**. |
| OW-3f | "Remove 'effective now' label + simplify hierarchy labels" | ❌ NOT DONE | UX. |
| OW-3g | "Service period — remove labels; small note for midnight rollover" | ❌ NOT DONE | UX. |

### 4) Locations (debug.md:141-143)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-4 | "Proper scope — at a location, don't show 'location' tab; at business level expose full hierarchy CRUD" | 🚧 IN PROGRESS | `hierarchy_screen.dart` + C-6 InheritanceTree consumer ship hierarchy mutation. **Scope-conditional visibility of 'Location' tab** not verified. 🔍 NEEDS VERIFICATION. |

### 5) My Account (debug.md:145-150)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-5a | "Move under Access" | ❌ NOT DONE | Router/IA change. Targets R-1 (since R-1 already decomposes `my_account_screen.dart`). |
| OW-5b | "Remove subtitle" | ❌ NOT DONE | UX. |
| OW-5c | "Profile changes all user details, end-to-end" | ❌ NOT DONE | Same as P-1. |
| OW-5d | "Remove 'display name email...' subtitle" | ❌ NOT DONE | Same as P-2. |
| OW-5e | "Logic for account details lives here, NOT mobile, fully wired" | ❌ NOT DONE | Same as P-3. |

### 6) Team Members (debug.md:152-156)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-6a | "Remove subtitle 'invite team members...'" | ❌ NOT DONE | UX. |
| OW-6b | "Invite team members button bigger" | ❌ NOT DONE | UX. |
| OW-6c | "Remove 4 top widget tiles" | ❌ NOT DONE | UX. |
| OW-6d | "3-dot → 'Edit user' button; change email/name/role end-to-end" | ❌ NOT DONE | Same as RP-11. |

### 7) Roles and Permissions (debug.md:158-167)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-7a | "Move under People" | ❌ NOT DONE | IA change. |
| OW-7b | "Remove 'set what each role can do' subtitle" | ❌ NOT DONE | UX. |
| OW-7c | "Remove 4 top widgets" | ❌ NOT DONE | UX. |
| OW-7d | "'No custom roles' → 'Create Custom Role'" | ❌ NOT DONE | UX. |
| OW-7e | "Remove 'build a custom role...' subtitle" | ❌ NOT DONE | UX. |
| OW-7f | "Remove role_key UX if not removed" | 🔍 NEEDS VERIFICATION | Same as RP-5. |
| OW-7g | "Remove 'standard roles forge and flow...' subtitle" | ❌ NOT DONE | UX. |

### 8) Sign in Security (debug.md:169-173)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-8a | "Remove subtitle 'protect your own team...'" | ❌ NOT DONE | UX. |
| OW-8b | "Remove 4 top tiles" | ❌ NOT DONE | UX. |
| OW-8c | "Lost-authenticator behaviour — NOT a link; should be 'contact admin to remove 2fa' + admin-side instructions" | 🚧 IN PROGRESS | `mfa_removal_service.dart` + `user_pii_erasure_service` ship the 24h cooldown. **CTA wording** needs verification. 🔍 NEEDS VERIFICATION. |
| OW-8d | "Consolidate Sign in & Security into My Account; remove standalone page" | ❌ NOT DONE | IA change. Targets R-1 (which decomposes `my_account_screen.dart`). |

### 9) Active Sessions (debug.md:175-181)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-9a | "Team sessions show actual member names, not 'operator-web-qa-2026-...' device strings" | 🚧 IN PROGRESS | `sessions_screen.dart` (819 LoC). The device-id format is the session-token-mint artifact. **Operator-name display** needs verification. 🔍 NEEDS VERIFICATION. |
| OW-9b | "Remove 4 top widget tiles" | ❌ NOT DONE | UX. |
| OW-9c | "Remove 'devices you are currently...' + 'active sessions for everyone...' subtitles" | ❌ NOT DONE | UX. |

### 10) Audit Log (debug.md:181)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-10 | "Plain-English explanation of audit log + zoom-out implementation read-back" | 🚧 IN PROGRESS | `audit_log_screen.dart` + B8.b operator-web pane shipped. **Plain-English read-back to operator** not done. Targets Step 1. |

### 11) Vendor Connections → Vendor Integration (debug.md:183-187)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-11a | "Rename to Vendor Integration; replace 'connection' with 'integration' throughout" | ❌ NOT DONE | 32 occurrences of vendor-connection in `vendor_connections_screen.dart` per Grep. **New slice — "Vendor Connection → Vendor Integration rename sweep"** across all consoles + mobile + notifications. |
| OW-11b | "Remove 4 widget tiles" | ❌ NOT DONE | UX. |
| OW-11c | "Reword 'initial backfill progress' → '60 day benchmark data' phrasing" | ❌ NOT DONE | UX copy. |
| OW-11d | "Page throws 'could not load vendor connections' error" | 🚧 IN PROGRESS | Per `c_12_lane_c_closeout_audit.md` O-3: B8.b live HTTP gateway wiring deferred (~10 LoC). May share root cause. Targets Step 5b "Live operator-web Firebase mixin". |

### 12) Data Accuracy (debug.md:189-204)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-12a | "Explain the entire page" | 🚧 IN PROGRESS | Operator read-back. Targets Step 1. |
| OW-12b | "Remove top tiles (Labor dollars, Guest counts, Fallback cards, Polling tier)" | ❌ NOT DONE | UX. |
| OW-12c | "Make 'Sources' bigger; remove 'pick the preferred system...' subtitle" | ❌ NOT DONE | UX. |
| OW-12d | "Rename 'where labor dollars come from'; explain functionality + vendor scope" | 🚧 IN PROGRESS | Same as wage-mix formula in OW-13. Targets Step 1 read-back. |
| OW-12e | "Covers — explain 3 logic types; reservation integration?" | 🚧 IN PROGRESS | Targets Step 1 read-back. |
| OW-12f | "Rename Monitoring → Data Freshness; bigger font" | ❌ NOT DONE | UX. |
| OW-12g | "Subtitle rewrite: 'Polling is...' + plan tier + request-fresh-data" | ❌ NOT DONE | UX. |
| OW-12h | "Remove 'no poll only vendors connected'; make tier-change button better; wired as email?" | 🚧 IN PROGRESS | `polling_and_pricing_admin_screen.dart` has the admin-side tier change. **Wired as email** — likely no. 🔍 NEEDS VERIFICATION. |
| OW-12i | "Rename 'How this applies to your setup' → 'Note:'" | ❌ NOT DONE | UX. |
| OW-12j | "Reword polling cadence + webhook subtitles" | ❌ NOT DONE | UX. |

### 13) Wage Authority (debug.md:206-241)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-13a | "UX matches the blended-wage-mix formula (FOH/BOH/Mgmt × hourly = total / heads = blended)" | 🚧 IN PROGRESS | `wage_authority_screen.dart` (907 LoC) has FOH/BOH/Mgmt buckets. **Per-role display showing _ × $/hr = total** needs verification. **Blended-mix total displayed?** Targets a new slice "Wage authority — blended-mix formula display". |
| OW-13b | "Top of screen: 'This applies to x.y.z vendors because of x'" | ❌ NOT DONE | No vendor-applicability label in `wage_authority_screen.dart`. Tied to B10.1/B10.2 vendor applicability tables. **New slice — "Wage / Data Accuracy vendor applicability labels"**. |
| OW-13c | "Wage Authority + Data Accuracy on same page" | ❌ NOT DONE | They're separate screens today. IA change. |
| OW-13d | "Editable admin-console list per setting type (wage / covers / polling); auto-flows to ops web" | 🚧 IN PROGRESS | B10.1 `vendor_applicability` table + `vendor_applicability_admin_screen.dart` exist. **Admin-edit UX for the lists** needs verification per setting type. 🔍 NEEDS VERIFICATION. |

### 14) Notifications (debug.md:243-255)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-14a | "Change 'First-Connect backfill' to 'First Connect Backfill' (no hyphens)" | ❌ NOT DONE | UX copy. |
| OW-14b | "Reword 60-day historical seed → '60 days of P.O.S. data has been uploaded and your initial benchmark is now live'" | ❌ NOT DONE | UX copy. |
| OW-14c | "Vendor connection → Vendor Integration in notification copy" | ❌ NOT DONE | Same as OW-11a. |
| OW-14d | "Simplify 'Audit Chain Anchor failed' wording" | ❌ NOT DONE | UX copy. |
| OW-14e | "Daily audit log description simpler with examples" | ❌ NOT DONE | UX copy. |
| OW-14f | "Manager override → Benchmark override applied" | ❌ NOT DONE | UX copy. |
| OW-14g | "Weekly plan 'a new weekly snapshot was locked in' — explain better" | ❌ NOT DONE | UX copy. |

---

## Mobile UX (debug.md:258-306)

### Home

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-H-1 | "What is the live button for?" | 🚧 IN PROGRESS | `shift_dashboard.dart` references `LIVE` / `_LiveClock`. **Plain-English read-back** not done. Targets Step 1. |

### 1) Notifications

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-1 | "Mark-as-read tick next to each notification" | ✅ DONE | Per `notifications_screen.dart:2` header comment: "W2.A — extended with per-tile mark-as-read tap." Plus `notifications_screen_mark_read_test.dart`. |

### 2) Data tab

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-2 | "Data tab privileged to F&F admin only — set via seeded role" | ❌ NOT DONE | No role-gated tab visibility found in `forge_flow_app.dart`. **New slice — "Mobile Data tab role-gated visibility"**. |

### 3) Setup — Business Timing

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-3a | "View-only mobile business timing (correct as-is); cleanup subtitles + tiles" | 🚧 IN PROGRESS | `settings_timing_authority_section.dart` exists. UX cleanup — Targets a new "Mobile setup tab UX polish" slice. |
| MO-3b | "Consolidate 'business day starts' + 'shift close rule' into one widget" | ❌ NOT DONE | UX. |
| MO-3c | "'Manage business timing on operator web' is a button that opens ops-web with same JWT, deep-links to relevant section" | ❌ NOT DONE | No JWT loopback path verified. **New slice — "Mobile → Ops-Web deep-link with handoff code"** (B11.1 handoff codes infrastructure exists; UI deep-link doesn't). |

### 4) Wage Setup

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-4a | "Remove subtitle 'review the wage mix used...' + 'source default wages' wording" | ❌ NOT DONE | UX. |
| MO-4b | "'Manage wage setup on operator console' button same as timing" | ❌ NOT DONE | Same as MO-3c. |
| MO-4c | "Widget displays the FOH/BOH/Mgmt breakdown (view-only)" | 🚧 IN PROGRESS | `settings_wage_authority_section.dart` exists. **Blended-mix display** needs verification (same as OW-13a). 🔍 NEEDS VERIFICATION. |

### 6) Covers Setup

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-6 | "Covers setup on mobile — manual entry when vendors don't support; first item on setup tab" | ❌ NOT DONE | No covers-manual-entry surface on mobile. **New slice — "Mobile covers manual entry (vendor-fallback)"**. |

### 7) Integrations tab

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-7a | "Third tab 'Integrations' — live status for POS / reservation / labor; button to ops portal" | ❌ NOT DONE | No mobile Integrations tab. **New slice — "Mobile Integrations tab — live vendor status + ops-portal deep-link"**. |
| MO-7b | "Demo→Live switch lives here too (zoom out on demo-switch impl)" | 🚧 IN PROGRESS | C-4 master switch shipped at `settings_demo_live_switch.dart` (mobile Settings). Mobile-integrations-tab placement not yet done. Tied to MO-7a. |

### 5) Account 2FA

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-5a | "Direct enable-MFA button on account 2FA section" | ✅ DONE | `settings_mfa_section.dart` + C-7 adaptive MFA flow shipped. |
| MO-5b | "Adaptive label: enabled / Remove 2FA / Enroll / Cancel request (24h window)" | ✅ DONE | C-7 adaptive label covers all states per `c_12_lane_c_closeout_audit.md` "C-7's adaptive label covers all states of (MfaCardStage, factorCount, recoveryCodesViewedAt)". 🔍 Operator should still walk through to confirm. |
| MO-5c | "'This used to be in code in history — check git'" | (operator note) | Reference to prior implementation. Subsumed by MO-5b. |

### 6) Account — Sign in details

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-6b | "Remove subtitle 'review your sign in details'" | ❌ NOT DONE | UX. |
| MO-6c | "Rename 'Display name' → 'Name'" | ❌ NOT DONE | UX. |
| MO-6d | "'Manage account on operator web' deep-link button (same as timing/wage)" | ❌ NOT DONE | Same as MO-3c. |

### 7b) Active Sessions

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-7c | "Remove 'see where your account...' subtitle" | ❌ NOT DONE | UX. |
| MO-7d | "Remove second 'Active sessions' header" | ❌ NOT DONE | UX. |
| MO-7e | "Devices: when + device only (no IP)" | 🚧 IN PROGRESS | `settings_active_sessions_section.dart`. **IP-display removal** needs verification. 🔍 NEEDS VERIFICATION. |
| MO-7f | "Sign out + sign out of all devices buttons" | 🚧 IN PROGRESS | Wave's `revoke non-self path` (B9.2) covers it. **UX presence** verification. 🔍 NEEDS VERIFICATION. |

### Settings tab reorder

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-S | "Settings tab order: setup, integrations, data (F&F-admin), account" | ❌ NOT DONE | `settings_screen.dart` order is different today. Targets a new "Mobile settings tab IA reorder" slice. |

---

## "Brian Computer" — Email + Notification scaffold (debug.md:308-325)

This is the operator's pasted research summary. It restates EN-2 +
EN-3 + EN-4 + EN-5 with sharper framing.

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| BC-1 | "Scaffold audit lane in code-health wave" | ❌ NOT DONE | The wave that closed 2026-05-13 didn't dedicate a lane to scaffold purge. **New slice — "Scaffold audit lane (email templates + dispatcher orphans + dormant invite path)"**. |
| BC-2 | "Soak harness: ~6 days code (bug fixes + regression tests) + ~6 days forensic kit (heap, state-machine, sign-in integrity)" | 🚧 IN PROGRESS | A11.1 / A11.2 shipped the soak base + uploader interface; **Azure swap pending** per `POST_HARDENING_FOLLOWUPS.md`. Targets a new "Soak harness — completion + Azure swap" slice. |
| BC-3 | "Email/notification harness: ~10 days + ~$200/mo (Patrol + Firebase Test Lab + Mailosaur + SendGrid webhook)" | 🚧 IN PROGRESS | C-11 shipped the Mailosaur loopback harness (exits 0 if env not wired); SendGrid event webhook (C-1) shipped. **Patrol + Firebase Test Lab + actual budget commit** not done. Targets EN-5 above. |

---

## Summary by status

Approximate counts across all rows (~135 distinct items):

| Status | Count | Notes |
|---|---|---|
| ✅ DONE | ~25 | Mostly auth/RLS/hierarchy backbone, MFA flow, default role catalog, audit log filter, demo-live switch, mark-as-read |
| 🚧 IN PROGRESS | ~50 | Surface exists; UX polish or write-path completion pending |
| ❌ NOT DONE | ~50 | Mostly UX cleanup (subtitle/tile removal), new IA, new write paths, new slices |
| 🔍 NEEDS VERIFICATION | ~10 | Claimed done by code/tests; operator hasn't walked through |

## Where each NOT DONE / IN PROGRESS item slots in NEXT_WAVE_PLAN.md

**Step 1 (demo-validate)** — every 🔍 NEEDS VERIFICATION row plus
the read-back items (OW-1, OW-2f, OW-3c, OW-10, OW-12a, OW-12d,
OW-12e, MO-H-1, QI-2, QI-3, RP-2). The operator walks the surface
+ confirms or reopens.

**Step 3 (R-1 / R-2 refactor)** — OW-5a (move My Account under
Access) + OW-8d (consolidate Sign in & Security into My Account)
naturally fold into R-1's `my_account_screen.dart` decomposition.

**Step 5a (W-1 / W-2 fixes + new bug slices)** — BUG-1, BUG-2,
B-1 (B2.1 idempotency), B-2 (permission_explainer_screen
regression), W-1 (legacy fact tables), W-2 (partman dollar-quote).

**New slices to add to NEXT_WAVE_PLAN.md (not yet captured):**

1. **Scaffold audit lane** — BC-1 / EN-2 / EN-4 / QI-1. ~5-10 LoC purge per orphan + dispatcher cleanup.
2. **Vendor Connection → Vendor Integration rename sweep** — OW-11a, OW-14c. Cross-console string sweep.
3. **HP #11 sweep for schedule + wage_authority** — H-1 / M-4. 1-day operator-web-side slice.
4. **Roles screen UX simplification + role categorization by product** — RP-8 + RP-12 + RP-14 + OW-7a..g.
5. **Members edit-user write path (email + name + role + hierarchy)** — RP-11 + OW-6d.
6. **Cancel pending invite end-to-end** — RP-16.
7. **Default Role Catalog v2 redesign** — RP-3. Post demo-validate operator decision.
8. **Profile self-service write paths + mobile → ops-web deep-link with handoff code** — P-1 + P-3 + MO-3c + MO-4b + MO-6d.
9. **Admin console My Account parity** — P-5.
10. **Top bar + location selector hierarchy redesign (ops web + admin)** — OW-0c.
11. **Inheritance tree visualization on identity pages** — OW-3e.
12. **Business logo upload + propagation** — OW-2d.
13. **Account screen — timezone + missing-field exposure** — OW-2g.
14. **Wage Authority — blended-mix formula display + vendor applicability label** — OW-13a + OW-13b.
15. **Wage Authority + Data Accuracy unified IA** — OW-13c.
16. **Mobile Data tab role-gated visibility** — MO-2.
17. **Mobile covers manual entry (vendor-fallback)** — MO-6.
18. **Mobile Integrations tab — live vendor status + ops-portal deep-link** — MO-7a + MO-7b.
19. **Mobile settings tab IA reorder** — MO-S.
20. **Soak harness — completion + Azure Blob swap** — BC-2 + BUG-3.
21. **Email/notification soak (Patrol + Firebase Test Lab + Mailosaur)** — EN-5 + BC-3.
22. **Operator SOP authoring** — QI-10. Post-V1 deploy.
23. **Vendor outreach kickoff** — QI-11. Post-V1 deploy.
24. **Mobile + ops-web UX polish bundle** — every UX-only row (subtitle removal, tile removal, copy rewording). Can be a single high-velocity bundle since each individual change is tiny.
25. **Audit chain hierarchy projection** — AL-1. Post-V1 if needed.
26. **Custom role editor — orphan permission lint + product rule warnings** — AC-2.
27. **Phase 10b perf-and-overfetch audit** — QI-7 (was in 10b before pause).
28. **Frameworks → runbooks conversion** — QI-4 (housekeeping).
29. **Central agent-self-audit script** — QI-5.

---

## Honest disclosure — what I couldn't easily verify without the operator

- **Every 🔍 NEEDS VERIFICATION row** is by definition something the operator must walk before I can flip status. Most are "the wave audit doc says it shipped; the operator hasn't run the surface."
- **The "operator wants this rewritten / explained back in plain English" rows** (read-back items) — those are pure operator-walkthrough work, not code-state checks.
- **The mobile-side count for items like role-categorization, label sweep, Vendor Connection → Vendor Integration** — I did string-search on `lib/` to identify the high-level surfaces; a full sweep of every operator-facing copy string would be a separate, heavier audit.
- **The "this used to be in code in git history" claim (MO-5c)** — I did not dig through git history to find the prior implementation; relied on the current C-7 adaptive flow as the live answer.
- **The "what's editable vs not in business setup" audit (OW-2a)** — needs a side-by-side admin vs ops-web walk-through to actually enumerate.

The above are the spots where mapping accuracy is limited by my read-only static analysis vs an actual walkthrough.
