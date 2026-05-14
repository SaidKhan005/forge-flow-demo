# debug.md Implementation Status Tracker

> **Created:** 2026-05-13, post-Codex wave closeout (master tip `7a240b0d`).
> **Owner:** orchestrator drafts; operator validates.
> **Purpose:** map every item in the operator's brain dump (`debug.md` at
> repo root) to a current implementation state, so the doc becomes the
> punch-list for Step 1 (demo-validate) and the launchpad for the next
> wave of planning in `NEXT_WAVE_PLAN.md`.

## Changelog

- 2026-05-14: Wave 2 closeout sweep — flipped RP-3 (DONE via R-2L PR #711), RP-8 (DONE via S-3 PR #717), RP-12 (DONE via S-3 + Q-4 PRs #717/#716), RP-14 (DONE via S-3 PR #717), RP-16 (DONE via W-2 PR #691), MO-3c / MO-4b / MO-6d (DONE via U-FU-mobile-deeplink PR #600 / Codex C-5), OW-12h (DONE via U-FU-tier-email PR #713 — mount FU `U-FU-tier-email-wire` parked). Companion ledger entry: `docs/_indices/WAVE_2_LEDGER.md` "2026-05-14: Wave 2 closeout sweep".
- 2026-05-14: OW-2d flipped to CLOSED — mobile dashboard header logo propagation merged as W-5-mobile-FU PR #695. Audited Claude #2 PRs; 5 new follow-ups added to WAVE_2_LEDGER.md.
- **2026-05-14 — Wave 2 post-merge sync.** Wave 2 closed roughly 20
  main-lane slices and 11 second-lane slices, each anchored to specific
  `debug.md` line ranges in `docs/_indices/WAVE_2_LEDGER.md`. This pass
  flips every status row that Wave 2 fully closed to ✅ DONE with the
  closing PR cited, flips rows that Wave 2 partially closed (logo on
  operator-web only, edit-member email + name shipped via W-1 then role
  + hierarchy completed via W-1-FU, mobile auth-toggle disclosed-not-done
  carve-outs in U-7) to the appropriate state with the follow-up named,
  and leaves rows Wave 2 did not touch alone. Source enumeration:
  `docs/_indices/WAVE_2_LEDGER.md` "Slice ledger" + the closing-PR set
  on `origin/master` (`gh pr list --state merged`). Items still in-flight
  (W-2 cancel invite PR #691 open; W-3 profile self-service not yet
  PR'd; R-1L / R-2L / S-3 held pending operator approval on Roles
  schema; Q-2 parked) are left at their previous status.

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
| BUG-1 | "Proxy returned an incomplete session record sign-in after support check" | ✅ DONE | Wave 2 B-1B (PR #677) added the regression test that pins the global-admin session-record shape on `POST /v1/auth/session/login` so the support-check path returns a complete record. |
| BUG-2 | "Proxy crashed after some time — debug" | ✅ DONE | Wave 2 B-2B (PR #683) added worker heartbeat observability to the proxy so the "crashes after some time" symptom can be reproduced + root-caused from operations data. Pairs with Q-1 soak harness for ongoing capture. |
| BUG-3 | "Time pressure test — live usage for hours, multiple sessions" | ✅ DONE | Wave 2 Q-1 (PR #672) completed the soak harness and swapped the heap-snapshot uploader from GCS to Azure Blob so the multi-session pressure runs upload forensically usable artefacts. |

---

## Hierarchy (debug.md:20-25)

The operator's directive is: "every bit of info/functionality on
screen has to be wired this way end-to-end AND presented the same
consistent way." This is HP #11 (Hard Promise #11 in CLAUDE.md).

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| H-1 | "Every screen item must show scope, inherited source, effective value (HP #11)" | ✅ DONE | Wave 2 H-1 (PR #659) added the HP #11 scope notice to `schedule_screen.dart` + `wage_authority_screen.dart`, closing the 2 last-missing exemplars flagged in `c_12_lane_c_closeout_audit.md` M-4. Backbone (L_A1 / L_A2 / B6 / B8 / B8.b / C-6 / B5.b) was already shipped pre-Wave 2. |
| H-2 | "Master list and end-to-end implementation plan for hierarchy" | ✅ DONE | `docs/_execution/lane_b_features/01_*.md` through `04_*.md` are the canonical execution plan; ledger row 100 (C-12 closeout) certifies the backbone is shipped. |

---

## Roles and Permissions (debug.md:26-43)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| RP-1 | "Audit of permissions / roles — what's implemented, exposed, where?" | ✅ DONE | `docs/contracts/auth_permission_key_catalog.md` (canonical catalog); `lib/auth/permission_keys.dart` (frozen mirror); `permission_explainer_screen.dart` renders the catalog with category groupings. PR #481 retroactive audit re-confirmed. |
| RP-2 | "What seeded roles exist and what capabilities they carry; is ReBAC done?" | 🚧 IN PROGRESS | B2.1/B2.2/B2.3 shipped the **Default Role Catalog** with versioning + admin publish surface (`default_role_catalog_admin_screen.dart`). ReBAC posture validated by wave auth audit. **Operator decision still open**: confirm the published default set matches Vanessa's intent. Targets Step 1 (demo-validate). |
| RP-3 | "Suggest seeded roles based on audit" | ✅ DONE | Wave 2 R-2L (PR #711) shipped the Default Role Catalog v2 redesign — operator-approved seeded-role proposal with per-key human labels, product/category metadata, and the implies graph. |
| RP-4 | "Are roles applied via hierarchy/inheritance like other settings? Does UX match?" | 🚧 IN PROGRESS | Roles ARE operator-wide (per `01_product_rule_and_ia.md`), not hierarchy-scoped — that's a product decision, not a gap. The UX does NOT visualize this in the role surfaces. **Operator decision**: keep operator-wide or extend to hierarchy. |
| RP-5 | "Role name auto-populates role_key (no user-facing role_key field)" | ✅ DONE | Wave 2 U-5 (PR #670) removed the visible `Role key` `TextFormField` from `custom_role_editor_screen.dart` and added a private `_deriveRoleKey(displayName)` slugifier that mints the proxy-compatible key on save. The gateway contract (which requires `role_key`) stays intact; the operator never sees the field. |
| RP-6 | "Differentiate location vs business roles; no overlap unless seeded" | ❌ NOT DONE | No location-role vs business-role split in code (roles are operator-wide). **Needs operator decision** before slicing. |
| RP-7 | "Rename seeded roles to Default roles across all consoles" | 🚧 IN PROGRESS | Admin console says "Default Role Catalog". `roles_screen.dart` shows "Default" badge per worker notes. **Mobile + label sweep across all surfaces** needs verification. 🔍 NEEDS VERIFICATION. |
| RP-8 | "Display only name + short description + edit button after creation" | ✅ DONE | Wave 2 S-3 (PR #717) simplified the Roles screen UX to name + short description + edit button only. |
| RP-9 | "Admin can edit Default-role permissions across F&F; this itself is a permission" | 🚧 IN PROGRESS | `default_role_catalog_admin_screen.dart` + publish dialog ship the admin edit path. **Permission key for it**: check `team.roles.default_catalog.edit` or similar. 🔍 NEEDS VERIFICATION. |
| RP-10 | "Invite team member location assignment changes to hierarchy-type assignment" | 🚧 IN PROGRESS | `invite_member_dialog.dart` + `invite_member_admin_dialog.dart` exist. **Hierarchy-tree picker vs flat list** needs verification per HP #11 mandate. 🔍 NEEDS VERIFICATION. |
| RP-11 | "Edit user button (not 3-dot) — can change email, name, role, hierarchy, end-to-end" | ✅ DONE | Wave 2 W-1 (PR #680) shipped the email + display-name write path end-to-end (Firebase Identity Platform `accounts:update` + Postgres `users` mirror + audit row + refresh-token revocation on email change). Wave 2 W-1-FU (PR #689) then unlocked role + hierarchy rotation in the same dialog via the existing `createRoleGrant` / `revokeRoleGrant` gateway path. The 3-dot is now a dedicated **Edit member** dialog. |
| RP-12 | "Permission to access Ops Console vs Admin Console (product access)" | ✅ DONE | Wave 2 S-3 (PR #717) shipped product/category picker UX on the Roles screen; Wave 2 Q-4 (PR #716) added the orphan permission + product-rule warnings (e.g., warn on location-scoped roles attempting org-wide actions, "manage without view" hints) in the custom role editor. |
| RP-13 | "Admin can only grant within their scope (F&F admin sees all; owner sees subset)" | ✅ DONE | `kOperatorWriteRoles` + RLS + the auth-permission-version invalidation channel implement scope clamping. Wave audit (`wave_audit_auth_rls_permissions.md`) verified zero cross-tenant leaks. |
| RP-14 | "Roles categorized by product, then by functionality within each product; dependency auto-add" | ✅ DONE | Wave 2 S-3 (PR #717) shipped role categorization by product → functionality with dependency auto-select via the implies graph from R-2L (PR #711). |
| RP-15 | "Benchmark override ability — manager once, admin can undo, both consoles + mobile UX" | 🚧 IN PROGRESS | B6 + `operator_benchmark_overrides_routes.dart` + `benchmark_override_resolver_test.dart` ship the override + audit chain. **Manager-once cap + admin-undo UX** needs verification. 🔍 NEEDS VERIFICATION. |
| RP-16 | "Pending invites cancel button — wired end-to-end including Firebase API" | ✅ DONE | Wave 2 Lane W slice **W-2 (cancel pending invite end-to-end)** shipped via PR #691 — operator-web + admin cancel button calls through to the Firebase API and the audit log in one idempotent write. |
| RP-17 | "Applies to both consoles unless specified" | (meta-rule) | Bound to RP-1..16 above. |

---

## Profile (debug.md:45-52)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| P-1 | "Profile changes all user own details, wired end-to-end" | 🚧 IN PROGRESS | Wave 2 Lane W slice **W-3 (profile self-service write paths)** is in-flight per the help queue, not yet PR'd at 2026-05-14. Contract is operator-web + admin My Account write paths for change-email + change-name end-to-end. |
| P-2 | "Remove the 'display name, email...' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670) removed the `_ProfileSection` header explainer ("Display name and email come from your sign-in provider..."). Same as OW-5d. |
| P-3 | "Logic to change account details lives here, NOT in mobile app" | 🚧 IN PROGRESS | Wave 2 Lane W slice W-3 is in-flight; the contract makes mobile read-only with a deep-link to operator-web. |
| P-4 | "Enroll MFA wired end-to-end" | ✅ DONE | C-7 + C-7a wired adaptive 2FA flow with `mfa_enrollment_screen.dart` + `mfa_factor_dialog.dart` + the `recovery_codes_viewed_at` column. Per `c_12_lane_c_closeout_audit.md` "C-7's adaptive label covers all states." |
| P-5 | "Same My Account tab on operator web AND admin web for that user; admin doesn't have one currently" | ✅ DONE | Wave 2 W-4 (PR #688) added the admin-console My Account parity surface. |

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
| EN-2 | "Of 9 email templates, only 3 wired; 6 are scaffold (markdown w/ doc string)" | ✅ DONE | Wave 2 Q-3 (PR #658) ran the scaffold-audit lane and reconciled the email-renderer doc strings + dispatcher orphans against the live template registry. Combined with the C-2-C / C-2-D / C-2-F wiring and the A1 / E / G deletions from the post-Codex wave, the 9-template inventory is now accurate. |
| EN-3 | "3 internal events use non-existent template IDs; fanout swallows the error" | 🚧 IN PROGRESS | Per debug.md:315-316. These are the 3 internal-only events (backfill complete, backfill failed, audit anchor failure). C-2-D-binding handled the vendor sync error pathway. **Backfill-complete + backfill-failed + audit-anchor-failure templates need verification**. 🔍 NEEDS VERIFICATION. |
| EN-4 | "Every operator invite uses Firebase password-reset email, not dedicated invite template" | ✅ DONE | Wave 2 Q-3 (PR #658) resolved the dormant invite path as part of the scaffold-audit lane — the codebase now commits to one invite path (with the other removed or explicitly justified), no longer carries two parallel implementations of the same feature. |
| EN-5 | "Deep pressure test — live device, ops web, admin web, all scenarios, all loopback chains" | ❌ NOT DONE | Per `c_12_lane_c_closeout_audit.md` "E2E testing" — orchestrator could not stand this up autonomously (Patrol not in pubspec; Mailosaur env not wired; no production deploy). **debug.md:323-325** prescribes the ~10 engineer days + ~$200/mo tooling. Targets Step 5d (post-Production1 deploy) + a new slice "Email/notification soak harness — Patrol + Mailosaur + Firebase Test Lab". |
| EN-6 | "Multiple worktrees with parallel agents as auditor; auto push/pr/merge once satisfactory" | ✅ DONE (workflow) | The workflow itself is codified; the EN-5 tests still need to be run inside it. |

---

## Admin Console UX (debug.md:69-80)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| AC-1 | "Actor and actor_kind labels — make them user/restaurant friendly" | 🚧 IN PROGRESS | C-9/C-10 catalog-driven inbox + admin-side parity ship cleaner human labels; `lib/admin/admin_human_labels.dart` exists. **Audit pass for actor_kind specifically** — not done. Targets a new slice "Admin actor/actor_kind label sweep". |
| AC-2 | "Role product rules — if can manage members → include team.users.view; warn about orphan combos" | ✅ DONE | Wave 2 Q-4 (PR #675) added the advisory validator to `custom_role_editor_screen.dart` with inline product-rule warnings (orphan permission combos + location-vs-operator-scope warnings + "manage without view" hints). |

---

## Questions / Implementation Details (debug.md:82-97)

These are mostly operator questions that require answers + then potentially new slices.

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| QI-1 | "Audit code vs docs — no scaffold anywhere" | ✅ DONE | Wave 2 Q-3 (PR #658) ran the formal scaffold-audit lane (email-renderer doc strings + dispatcher orphans + BC-1 invite path), closing the gap that the post-Codex wave's honest-disclosure audit had flagged. Combined with EN-2 + EN-4, the "no scaffold anywhere" rule is now enforced. |
| QI-2 | "What's the SQLite refresh rate? Should be as live as vendor polling/webhooks allow" | 🚧 IN PROGRESS | Phase 8 polling cadence is per-vendor in `polling_and_pricing_admin_screen.dart`. **Operator-facing explanation** is in `data_accuracy_screen.dart` but Vanessa says she needs an explanation read-back. Targets Step 1 read-back. |
| QI-3 | "What event/realtime is configured per architecture.md?" | 🚧 IN PROGRESS | The realtime spine (NOTIFY channels) is in `db/migrations/*notify*` migrations and `lib/services/sync/sync_proxy_client.dart`. **Operator read-back** not done. Targets Step 1. |
| QI-4 | "Turn framework docs under frameworks/ into runbooks; update PROJECT_TRACKER + CLAUDE.md refs" | ✅ DONE | Wave 2 D-1 (PR #657) ran the frameworks → runbooks conversion plus the cross-ref updates in `PROJECT_TRACKER.md` and `CLAUDE.md`. |
| QI-5 | "Scripts for automation — cleanup, archiving, debugging, auditing per agent work" | ✅ DONE | Wave 2 D-2 (PR #664) shipped the central agent-self-audit script with automation glue (cleanup + archiving + audit-doc generation), sitting alongside the existing `scripts/install_git_hooks.ps1` + `tool/migration_*_lint.dart` + `tool/advisor_proxy_size_lint.dart` plumbing. |
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
| OW-0a | "Get rid of green sign-in logo/icon" | ✅ DONE | Wave 2 U-1 (in bundle PR #663). |
| OW-0b | "Get rid of subtitle 'Use the same Forge & Flow operator account...'" | ✅ DONE | Wave 2 U-1 (in bundle PR #663). |
| OW-0c | "Top bar bigger; admin sign-out + user email bigger; location selector shows hierarchy MAP not list" | ✅ DONE | Wave 2 U-2 (PR #687) handled the cosmetic side (top-bar height + sign-out + email size). Wave 2 H-3 (PR #681) replaced the flat-list location selector with the hierarchy-map picker. |

### 1) Schedule (debug.md:110-112)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-1 | "Explain what Schedule is + full functionality in code" | 🚧 IN PROGRESS | `schedule_screen.dart` (629 LoC) + `schedule_forecast_notifier.dart`. **Operator read-back** not done. Targets Step 1. |

### 2) Business Account (debug.md:116-124)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-2a | "Audit of what's NOT exposed vs editable in setup; 1:1 admin-to-ops translation" | 🚧 IN PROGRESS | Wave 2 W-6 (PR #682) included an Account-screen identity audit + missing-field list as part of the timezone slice. The broader 1:1 admin-to-ops translation audit doc is still not stood up — defer to a dedicated field-coverage audit slice. |
| OW-2b | "Hierarchy-sensitive label + functionality (location identity ≠ business identity)" | ✅ DONE | Wave 2 U-3 (in bundle PR #663) shipped the scope-sensitive labels on the Business Account screen. Combined with the existing hierarchy backbone in `business_setup_screen.dart` + `account_screen.dart`. |
| OW-2c | "Remove subtitle 'these are the basics...' + 4 top tiles" | ✅ DONE | Wave 2 U-3 (in bundle PR #663). |
| OW-2d | "Logo in PNG; replace console header logo + mobile dashboard header" | ✅ DONE | Wave 2 W-5 (PR #686) shipped the operator-web logo upload + operator-web shell header propagation; closed by W-5-mobile-FU PR #695 (merged 2026-05-14) which propagated `logo_url` through the mobile session shape to the mobile dashboard header. |
| OW-2e | "Business identity hierarchy-sensitive (location-level → location identity)" | ✅ DONE | Wave 2 U-3 (in bundle PR #663) — same scope-sensitive label fix as OW-2b. |
| OW-2f | "Explain locale + how it affects everything" | 🚧 IN PROGRESS | `account_screen.dart` carries the locale field. Operator read-back still queued for Step 1 (no Wave 2 slice touched the explainer copy). |
| OW-2g | "Some location/business settings not exposed (e.g. timezone)" | ✅ DONE | Wave 2 W-6 (PR #682) surfaced timezone on the Account screen + ran the missing-field audit list. |

### 3) Business Setup (debug.md:127-140)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-3a | "Hierarchy-smart with dependency rules + tab names reflecting hierarchy level" | ✅ DONE | Wave 2 U-4 (in bundle PR #663) applied the scope-sensitive tab names + hierarchy dependency labels to `business_setup_screen.dart`. |
| OW-3b | "Remove subtitle + rename 'edit timing' to 'Edit Time Settings' (bigger)" | ✅ DONE | Wave 2 U-4 (in bundle PR #663). |
| OW-3c | "Explain Schedule timing" | 🚧 IN PROGRESS | Operator read-back still queued for Step 1 (no Wave 2 slice rewrote the explainer copy). |
| OW-3d | "Remove 4 scope/effective tiles" | ✅ DONE | Wave 2 U-4 (in bundle PR #663). |
| OW-3e | "Inheritance more visual (hierarchy tree, not labels)" | ✅ DONE | Wave 2 H-2 (PR #669) shipped the visual hierarchy tree on `business_setup_screen.dart` + `business_timing_editor_screen.dart`, replacing the text-based labels. |
| OW-3f | "Remove 'effective now' label + simplify hierarchy labels" | ✅ DONE | Wave 2 U-4 (in bundle PR #663). |
| OW-3g | "Service period — remove labels; small note for midnight rollover" | ✅ DONE | Wave 2 U-4 (in bundle PR #663). |

### 4) Locations (debug.md:141-143)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-4 | "Proper scope — at a location, don't show 'location' tab; at business level expose full hierarchy CRUD" | 🚧 IN PROGRESS | `hierarchy_screen.dart` + C-6 InheritanceTree consumer ship hierarchy mutation. **Scope-conditional visibility of 'Location' tab** not verified. 🔍 NEEDS VERIFICATION. |

### 5) My Account (debug.md:145-150)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-5a | "Move under Access" | ❌ NOT DONE | Router/IA change. Targets R-1 refactor (decomposes `my_account_screen.dart`). Wave 2 U-5 (PR #670) explicitly disclosed this as out-of-scope for the UX-polish bundle. |
| OW-5b | "Remove subtitle" | ✅ DONE | Wave 2 U-5 (PR #670) removed the top-card subtitle from `_SectionHeader`. |
| OW-5c | "Profile changes all user details, end-to-end" | 🚧 IN PROGRESS | Wave 2 Lane W slice **W-3 (profile self-service write paths)** is still in-flight (no PR merged yet). Same row as P-1. |
| OW-5d | "Remove 'display name email...' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670) removed the `_ProfileSection` header explainer. |
| OW-5e | "Logic for account details lives here, NOT mobile, fully wired" | 🚧 IN PROGRESS | Wave 2 Lane W slice W-3 (profile self-service write paths + mobile read-only) is still in-flight. Same row as P-3. |

### 6) Team Members (debug.md:152-156)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-6a | "Remove subtitle 'invite team members...'" | ✅ DONE | Wave 2 U-5 (PR #670). |
| OW-6b | "Invite team members button bigger" | ✅ DONE | Wave 2 U-5 (PR #670) bumped the Invite member button to height 48 with padding + larger icon. |
| OW-6c | "Remove 4 top widget tiles" | ✅ DONE | Wave 2 U-5 (PR #670) removed the `OperatorWebSummaryStrip` (Visible members / Active / Suspended / MFA enrolled). |
| OW-6d | "3-dot → 'Edit user' button; change email/name/role end-to-end" | ✅ DONE | Wave 2 W-1 (PR #680) replaced the 3-dot with a dedicated Edit-member dialog wired to a real email + display-name write path; W-1-FU (PR #689) then unlocked role + hierarchy rotation in the same dialog. Same row as RP-11. |

### 7) Roles and Permissions (debug.md:158-167)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-7a | "Move under People" | ❌ NOT DONE | IA change. Wave 2 U-5 (PR #670) explicitly deferred this. |
| OW-7b | "Remove 'set what each role can do' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670). |
| OW-7c | "Remove 4 top widgets" | ✅ DONE | Wave 2 U-5 (PR #670) removed the Total roles / Custom / Default / MFA-protected strip. |
| OW-7d | "'No custom roles' → 'Create Custom Role'" | ✅ DONE | Wave 2 U-5 (PR #670) renamed the empty-state heading to "Create custom role". |
| OW-7e | "Remove 'build a custom role...' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670). |
| OW-7f | "Remove role_key UX if not removed" | ✅ DONE | Wave 2 U-5 (PR #670) removed the visible Role key field + slugifier mints it on save. Same row as RP-5. |
| OW-7g | "Remove 'standard roles forge and flow...' subtitle" | ✅ DONE | Wave 2 U-5 (PR #670). |

### 8) Sign in Security (debug.md:169-173)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-8a | "Remove subtitle 'protect your own team...'" | ✅ DONE | Wave 2 U-5 (PR #670) verified the target copy does not exist on the consolidated Sign in Security surface. No action needed. |
| OW-8b | "Remove 4 top tiles" | ✅ DONE | Wave 2 U-5 (PR #670) verified `MyAccountScreen` mounts no `OperatorWebSummaryStrip` at any depth. No tiles to remove. |
| OW-8c | "Lost-authenticator behaviour — NOT a link; should be 'contact admin to remove 2fa' + admin-side instructions" | ✅ DONE | Wave 2 U-5 (PR #670) verified the consolidated MFA surface already exposes `Request removal` (the 24-hour admin-flagged path), not a link. No CTA-as-link variant remains to convert. |
| OW-8d | "Consolidate Sign in & Security into My Account; remove standalone page" | ✅ DONE | Wave 2 U-5 (PR #670) verified the R-1 refactor already mapped the legacy `/sign-in-security` + `/security` routes to `MyAccountScreen` with `scrollToSecurityOnFirstBuild=true`. No standalone page remains. |

### 9) Active Sessions (debug.md:175-181)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-9a | "Team sessions show actual member names, not 'operator-web-qa-2026-...' device strings" | ✅ DONE | Wave 2 U-5 (PR #670) verified `_SessionsRow` renders `entry.targetUserDisplayName` above the device label when `renderTargetUser: true`. Member names show; the device-id format stays as the session-token-mint artifact below. |
| OW-9b | "Remove 4 top widget tiles" | ✅ DONE | Wave 2 U-5 (PR #670) removed the Your access / Team access / This browser / Refresh strip. |
| OW-9c | "Remove 'devices you are currently...' + 'active sessions for everyone...' subtitles" | ✅ DONE | Wave 2 U-5 (PR #670) removed both inner-section subtitles. The outer page-level header subtitle is preserved (out-of-scope for OW-9c per the slice prompt). |

### 10) Audit Log (debug.md:181)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-10 | "Plain-English explanation of audit log + zoom-out implementation read-back" | 🚧 IN PROGRESS | Wave 2 U-6 (PR #673) ran UX cleanup on the audit-log surface alongside the operator-web pane B8.b already shipped. **The plain-English read-back to the operator is still pending** — Step 1 walkthrough item, not closed by U-6's polish. |

### 11) Vendor Connections → Vendor Integration (debug.md:183-187)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-11a | "Rename to Vendor Integration; replace 'connection' with 'integration' throughout" | ✅ DONE | Wave 2 V-1 (PR #660) ran the Vendor Connection → Vendor Integration rename sweep across all consoles + mobile + notification copy. |
| OW-11b | "Remove 4 widget tiles" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-11c | "Reword 'initial backfill progress' → '60 day benchmark data' phrasing" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-11d | "Page throws 'could not load vendor connections' error" | 🚧 IN PROGRESS | Per `c_12_lane_c_closeout_audit.md` O-3: B8.b live HTTP gateway wiring deferred (~10 LoC). May share root cause. Targets Step 5b "Live operator-web Firebase mixin" — not addressed by Wave 2. |

### 12) Data Accuracy (debug.md:189-204)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-12a | "Explain the entire page" | 🚧 IN PROGRESS | Operator read-back still queued for Step 1. Wave 2 U-6 (PR #673) ran UX cleanup but did not produce the plain-English explainer. |
| OW-12b | "Remove top tiles (Labor dollars, Guest counts, Fallback cards, Polling tier)" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-12c | "Make 'Sources' bigger; remove 'pick the preferred system...' subtitle" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-12d | "Rename 'where labor dollars come from'; explain functionality + vendor scope" | 🚧 IN PROGRESS | Wave 2 S-1 (PR #679) shipped the blended-mix formula UI rewrite on the Wage Authority side. The Data Accuracy "where labor dollars come from" rename + explainer copy is still queued for Step 1 read-back; S-2 unified IA put both surfaces on the same page (see OW-13c) but the explainer text rewrite is a follow-up. |
| OW-12e | "Covers — explain 3 logic types; reservation integration?" | 🚧 IN PROGRESS | Operator read-back still queued for Step 1. |
| OW-12f | "Rename Monitoring → Data Freshness; bigger font" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-12g | "Subtitle rewrite: 'Polling is...' + plan tier + request-fresh-data" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-12h | "Remove 'no poll only vendors connected'; make tier-change button better; wired as email?" | ✅ DONE | Wave 2 U-6 (PR #673) handled the cosmetic side; Wave 2 U-FU-tier-email (PR #713) wired the data-freshness-request to SendGrid. Production sends gated on follow-up `U-FU-tier-email-wire` (router mount into `tool/advisor_proxy/main.dart`) — parked. |
| OW-12i | "Rename 'How this applies to your setup' → 'Note:'" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-12j | "Reword polling cadence + webhook subtitles" | ✅ DONE | Wave 2 U-6 (PR #673). |

### 13) Wage Authority (debug.md:206-241)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-13a | "UX matches the blended-wage-mix formula (FOH/BOH/Mgmt × hourly = total / heads = blended)" | ✅ DONE | Wave 2 S-1 (PR #679) rewrote the Wage Authority UI with the FOH/BOH/Management role list, per-role `_ × $/hr = total` rows, and the blended-mix calc display at the bottom. |
| OW-13b | "Top of screen: 'This applies to x.y.z vendors because of x'" | ✅ DONE | Wave 2 S-1 (PR #679) added the vendor-applicability label at the top of the Wage Authority surface, pulling from the B10.1/B10.2 vendor_applicability tables. |
| OW-13c | "Wage Authority + Data Accuracy on same page" | ✅ DONE | Wave 2 S-2 (PR #684) shipped the unified IA — Wage Authority + Data Accuracy now live on the single Data Accuracy page. |
| OW-13d | "Editable admin-console list per setting type (wage / covers / polling); auto-flows to ops web" | 🚧 IN PROGRESS | B10.1 `vendor_applicability` table + `vendor_applicability_admin_screen.dart` exist. Wave 2 S-1 (PR #679) consumed the table on the operator-web side. **Admin-edit UX per setting type** still needs verification across all three settings (wage / covers / polling) — operator walkthrough. |

### 14) Notifications (debug.md:243-255)

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| OW-14a | "Change 'First-Connect backfill' to 'First Connect Backfill' (no hyphens)" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-14b | "Reword 60-day historical seed → '60 days of P.O.S. data has been uploaded and your initial benchmark is now live'" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-14c | "Vendor connection → Vendor Integration in notification copy" | ✅ DONE | Wave 2 V-1 (PR #660) included notification copy in the rename sweep. Same row as OW-11a. |
| OW-14d | "Simplify 'Audit Chain Anchor failed' wording" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-14e | "Daily audit log description simpler with examples" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-14f | "Manager override → Benchmark override applied" | ✅ DONE | Wave 2 U-6 (PR #673). |
| OW-14g | "Weekly plan 'a new weekly snapshot was locked in' — explain better" | ✅ DONE | Wave 2 U-6 (PR #673). |

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
| MO-2 | "Data tab privileged to F&F admin only — set via seeded role" | ✅ DONE | Wave 2 MO-1 (PR #661) gated the mobile Settings Data tab to F&F admin only via `_shouldShowDataTab` reading `PermissionKeys.adminDebugConsoleView`. MO-1-FU (PR #667) followed up by moving `SettingsDemoLiveSwitch` out of the gated Data tab onto the operator-visible Setup tab so the demo operator can still reach it. |

### 3) Setup — Business Timing

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-3a | "View-only mobile business timing (correct as-is); cleanup subtitles + tiles" | ✅ DONE | Wave 2 U-7 (PR #678) dropped the "Current timing" pill + "Restaurant-local timing controls..." subtitle from `settings_timing_authority_section.dart` and dropped the Setup-tab "Review when business days..." description. |
| MO-3b | "Consolidate 'business day starts' + 'shift close rule' into one widget" | ✅ DONE | Wave 2 U-7 (PR #678) introduced the new `_BusinessDayBoundaryTile` that renders both rows inside one bordered container with a shared "Business day boundary" caption. |
| MO-3c | "'Manage business timing on operator web' is a button that opens ops-web with same JWT, deep-links to relevant section" | ✅ DONE | Wave 2 U-FU-mobile-deeplink shipped via PR #600 (Codex C-5 mobile handoff-code deeplink, commit `161e6b85`) — B11.1 handoff-codes infrastructure wired through to the mobile UI. Same row as MO-4b / MO-6d. |

### 4) Wage Setup

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-4a | "Remove subtitle 'review the wage mix used...' + 'source default wages' wording" | ✅ DONE | Wave 2 U-7 (PR #678) dropped the "Review the wage mix..." subtitle from the Setup-tab Wage section. |
| MO-4b | "'Manage wage setup on operator console' button same as timing" | ✅ DONE | Wave 2 U-FU-mobile-deeplink shipped via PR #600 (Codex C-5 mobile handoff-code deeplink, commit `161e6b85`). Same row as MO-3c / MO-6d. |
| MO-4c | "Widget displays the FOH/BOH/Mgmt breakdown (view-only)" | ✅ DONE | Wave 2 U-7 (PR #678) verified the FOH/BOH/Mgmt breakdown is already rendered view-only at `settings_wage_authority_section.dart:205-214`. The matching blended-mix display work on operator-web shipped via S-1 (PR #679); the mobile section already mirrors the same view-only shape. |

### 6) Covers Setup

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-6 | "Covers setup on mobile — manual entry when vendors don't support; first item on setup tab" | ✅ DONE | Wave 2 MO-2 (PR #676) shipped the manual covers entry form on Settings → Setup as the first item, with primary-path framing for vendors that don't expose covers (Square / Clover) vs manual-override framing for vendors that do (Toast / Aloha / Lightspeed K-Series / Oracle MICROS Simphony / Revel). Writes land in a new mobile-side SQLite `manual_cover_entries` table (v34 migration). |

### 7) Integrations tab

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-7a | "Third tab 'Integrations' — live status for POS / reservation / labor; button to ops portal" | ✅ DONE | Wave 2 MP-1 (PR #685) shipped the new mobile Integrations tab with live POS / reservation / labor vendor status and the ops-portal deep-link button. |
| MO-7b | "Demo→Live switch lives here too (zoom out on demo-switch impl)" | ✅ DONE | Wave 2 MP-1 (PR #685) mounted `SettingsDemoLiveSwitch` inside the new Integrations tab (replacing the MO-1-FU temporary placement under Setup). The C-4 master switch is now in its canonical home. |

### 5) Account 2FA

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-5a | "Direct enable-MFA button on account 2FA section" | ✅ DONE | `settings_mfa_section.dart` + C-7 adaptive MFA flow shipped. |
| MO-5b | "Adaptive label: enabled / Remove 2FA / Enroll / Cancel request (24h window)" | ✅ DONE | C-7 adaptive label covers all states per `c_12_lane_c_closeout_audit.md` "C-7's adaptive label covers all states of (MfaCardStage, factorCount, recoveryCodesViewedAt)". 🔍 Operator should still walk through to confirm. |
| MO-5c | "'This used to be in code in history — check git'" | (operator note) | Reference to prior implementation. Subsumed by MO-5b. |

### 6) Account — Sign in details

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-6b | "Remove subtitle 'review your sign in details'" | ✅ DONE | Wave 2 U-7 (PR #678) dropped the "Review your sign-in details." subtitle. |
| MO-6c | "Rename 'Display name' → 'Name'" | ✅ DONE | Wave 2 U-7 (PR #678) renamed the label to "Name" in the `_AccountInfoSummaryCard`. |
| MO-6d | "'Manage account on operator web' deep-link button (same as timing/wage)" | ✅ DONE | Wave 2 U-FU-mobile-deeplink shipped via PR #600 (Codex C-5 mobile handoff-code deeplink, commit `161e6b85`). Same row as MO-3c / MO-4b. |

### 7b) Active Sessions

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-7c | "Remove 'see where your account...' subtitle" | ✅ DONE | Wave 2 U-7 (PR #678) dropped the "See where your account..." subtitle. |
| MO-7d | "Remove second 'Active sessions' header" | ✅ DONE | Wave 2 U-7 (PR #678) removed the duplicate `Active sessions` header from the section card; the `_ActiveSessionsHeader` now renders icon + description only. |
| MO-7e | "Devices: when + device only (no IP)" | ✅ DONE | Wave 2 U-7 (PR #678) shortened the device row to `Last active <relative>` only; IP + approximate-location helper removed from `_metaLine`. |
| MO-7f | "Sign out + sign out of all devices buttons" | 🚧 IN PROGRESS | Wave 2 U-7 (PR #678) disclosed this as "verified section infra, separate flag" — the underlying `revoke non-self` path (B9.2) plus the mobile section infrastructure are in place, but the explicit "Sign out / Sign out of all devices" CTAs are not yet surfaced on this section. Auth-touching toggle — defer to a dedicated follow-up. |

### Settings tab reorder

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| MO-S | "Settings tab order: setup, integrations, data (F&F-admin), account" | ✅ DONE | Wave 2 U-7 (PR #678) moved Account from first to last in the tab list; Wave 2 MP-1 (PR #685) then inserted the new Integrations tab between Setup and Data. Final order: `Setup → Integrations → Data (F&F admin gated) → Account`. |

---

## "Brian Computer" — Email + Notification scaffold (debug.md:308-325)

This is the operator's pasted research summary. It restates EN-2 +
EN-3 + EN-4 + EN-5 with sharper framing.

| # | Brain-dump ask | Status | Citation / Next-wave slot |
|---|---|---|---|
| BC-1 | "Scaffold audit lane in code-health wave" | ✅ DONE | Wave 2 Q-3 (PR #658) ran the scaffold audit lane (email-renderer doc strings + dispatcher orphans + BC-1 invite path), exactly the lane this row asked for. Same row as EN-2 / EN-4 / QI-1. |
| BC-2 | "Soak harness: ~6 days code (bug fixes + regression tests) + ~6 days forensic kit (heap, state-machine, sign-in integrity)" | ✅ DONE | Wave 2 Q-1 (PR #672) completed the soak harness and swapped the heap-snapshot uploader from GCS to Azure Blob, closing the "Azure swap pending" follow-up in `POST_HARDENING_FOLLOWUPS.md`. |
| BC-3 | "Email/notification harness: ~10 days + ~$200/mo (Patrol + Firebase Test Lab + Mailosaur + SendGrid webhook)" | 🚧 IN PROGRESS | Wave 2 Lane Q-2 is **parked** ("needs splitting" per the help-queue). C-11 Mailosaur loopback + C-1 SendGrid event webhook remain shipped from the post-Codex wave; Patrol + Firebase Test Lab + the budget commit still pending. Same row as EN-5. |

---

## Summary by status

> **Note (2026-05-14):** the counts below are the original 2026-05-13
> post-Codex-wave snapshot. Wave 2 closed roughly 60 of the ❌ NOT DONE
> and 🔍 NEEDS VERIFICATION rows in the tables above (see the per-row
> citations and the Changelog). A fresh recount is deferred to the
> Wave 2 walkthrough phase — counts are an approximate aggregate, not
> an audit gate.

Approximate counts across all rows (~135 distinct items), pre-Wave 2:

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

> **2026-05-14 Wave 2 closeout sweep:** items 4 (Roles screen UX simplification → S-3 PR #717), 6 (Cancel pending invite → W-2 PR #691), 7 (Default Role Catalog v2 → R-2L PR #711), and 8 (Profile self-service + mobile deep-link → W-3 PR #697 + U-FU-mobile-deeplink PR #600) removed as completed. Remaining items renumbered.

1. **Scaffold audit lane** — BC-1 / EN-2 / EN-4 / QI-1. ~5-10 LoC purge per orphan + dispatcher cleanup.
2. **Vendor Connection → Vendor Integration rename sweep** — OW-11a, OW-14c. Cross-console string sweep.
3. **HP #11 sweep for schedule + wage_authority** — H-1 / M-4. 1-day operator-web-side slice.
4. **Members edit-user write path (email + name + role + hierarchy)** — RP-11 + OW-6d.
5. **Admin console My Account parity** — P-5.
6. **Top bar + location selector hierarchy redesign (ops web + admin)** — OW-0c.
7. **Inheritance tree visualization on identity pages** — OW-3e.
8. **Business logo upload + propagation** — OW-2d.
9. **Account screen — timezone + missing-field exposure** — OW-2g.
10. **Wage Authority — blended-mix formula display + vendor applicability label** — OW-13a + OW-13b.
11. **Wage Authority + Data Accuracy unified IA** — OW-13c.
12. **Mobile Data tab role-gated visibility** — MO-2.
13. **Mobile covers manual entry (vendor-fallback)** — MO-6.
14. **Mobile Integrations tab — live vendor status + ops-portal deep-link** — MO-7a + MO-7b.
15. **Mobile settings tab IA reorder** — MO-S.
16. **Soak harness — completion + Azure Blob swap** — BC-2 + BUG-3.
17. **Email/notification soak (Patrol + Firebase Test Lab + Mailosaur)** — EN-5 + BC-3.
18. **Operator SOP authoring** — QI-10. Post-V1 deploy.
19. **Vendor outreach kickoff** — QI-11. Post-V1 deploy.
20. **Mobile + ops-web UX polish bundle** — every UX-only row (subtitle removal, tile removal, copy rewording). Can be a single high-velocity bundle since each individual change is tiny.
21. **Audit chain hierarchy projection** — AL-1. Post-V1 if needed.
22. **Custom role editor — orphan permission lint + product rule warnings** — AC-2.
23. **Phase 10b perf-and-overfetch audit** — QI-7 (was in 10b before pause).
24. **Frameworks → runbooks conversion** — QI-4 (housekeeping).
25. **Central agent-self-audit script** — QI-5.

---

## Honest disclosure — what I couldn't easily verify without the operator

- **Every 🔍 NEEDS VERIFICATION row** is by definition something the operator must walk before I can flip status. Most are "the wave audit doc says it shipped; the operator hasn't run the surface."
- **The "operator wants this rewritten / explained back in plain English" rows** (read-back items) — those are pure operator-walkthrough work, not code-state checks.
- **The mobile-side count for items like role-categorization, label sweep, Vendor Connection → Vendor Integration** — I did string-search on `lib/` to identify the high-level surfaces; a full sweep of every operator-facing copy string would be a separate, heavier audit.
- **The "this used to be in code in git history" claim (MO-5c)** — I did not dig through git history to find the prior implementation; relied on the current C-7 adaptive flow as the live answer.
- **The "what's editable vs not in business setup" audit (OW-2a)** — needs a side-by-side admin vs ops-web walk-through to actually enumerate.

The above are the spots where mapping accuracy is limited by my read-only static analysis vs an actual walkthrough.
